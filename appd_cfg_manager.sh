#!/usr/bin/env bash

# filename          : appd_cfg_manager.sh
# description       : A script that does backups and migrations of AppDynamics Configuration.
#   Wrapper arround the Config Exporter API
# author            : Alexander Agbidinoukoun
# email             : aagbidin@cisco.com
# date              : 2023/04/07
# version           : 0.1
# usage             : ./appd_cfg_manager.sh [-h] [-v] [-r "command"] -m export|migrate -c config_file
# notes             : 
#   0.1: first release
# 
#==============================================================================


set -Euo pipefail
trap cleanup SIGINT SIGTERM EXIT

PREV_IFS=$IFS

#
# Prerequisites
#

# is jq installed?
if ! command -v jq >/dev/null; then
  echo "Please install jq to use this tool (sudo yum install -y jq)"
  exit 1
fi

#
# Global Variables
#

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
log_file=$(echo ${BASH_SOURCE[0]} | sed 's/sh$/log/')
timestamp=$(date +%Y%m%d%H%M%S)
run_wait=10 # time to wait after running the config exporter
output_name_mode='name' # id|name

#
# Template Functions
#

usage() {
  cat << EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-r "command"] -m export|import -c config_file

A script that does backups and migrations of AppDynamics Configuration.

Available options:

-h, --help        Print this help and exit
-v, --verbose     Print script debug info
-r, --run         Command to run the Config Exporter. Do not set if it is already running.
-m, --mode        export or migrate
-c, --config      Path to config file

EOF
  exit
}

setup_colors() {
  if [ -t 2 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != "dumb" ]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[0;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

log() {
  echo >&2 -e "${1-}" >> ${log_file}
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  local date=`date '+%Y-%m-%d %H:%M:%S'`
  msg "${date}: ${RED}ERROR:${NOFORMAT} $msg"
  log "${date}: ERROR: $msg"
  exit $code
}

warn() {
  local msg=$1
  local date=`date '+%Y-%m-%d %H:%M:%S'`
  msg "${date}: ${YELLOW}WARN:${NOFORMAT} $msg"
  log "${date}: WARN: $msg"
}

info() {
  local msg=$1
  local date=`date '+%Y-%m-%d %H:%M:%S'`
  msg "${date}: ${GREEN}INFO:${NOFORMAT} $msg"
  log "${date}: INFO: $msg"
}

parse_params() {
  # default values of variables set from params

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -c | --config)
      config="${2-}"
      shift
      ;;
    -m | --mode)
      mode="${2-}"
      shift
      ;;
    -r | --run)
      run="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [ -z "${config-}" ] &&  warn "Missing required parameter: config" && usage
  [ -z "${mode-}" ] && warn "Missing required parameter: mode" && usage

  #[ ${#args[@]} -eq 0 ] && die "Missing script arguments"

  return 0
}

setup_colors

parse_params "$@"

#
# Start script logic here
#

#
# Utility Functions
#

my_curl() {
  auth=$1; shift

  x_csrf_header=''
  [ ! -z "${x_csrf_token-}" ] && x_csrf_header="-H X-CSRF-TOKEN:$x_csrf_token"

  if [ "$auth" == "true" -a ! -z "${appd_oauth_token-}" ]; then
    curl -s -H "Authorization:Bearer $appd_oauth_token" ${appd_proxy} "$@"
  elif [ "$auth" == "true" -a ! -z "${appd_api_password-}" ]; then
    curl -s -u "${appd_api_user}@${appd_account}:${appd_api_password}" ${appd_proxy} --cookie $appd_cookie_path $x_csrf_header "$@"
  else
    curl -s "$@"
  fi
}

get_appd_oauth_token() {
  # curl request
  response=`my_curl true -X POST -H "Content-Type: application/vnd.appd.cntrl+protobuf;v=1" \
  -d "grant_type=client_credentials&client_id=${appd_api_user}@${appd_account}&client_secret=${appd_api_secret}" \
  ${appd_url}/controller/api/oauth/access_token`

  # validate response
  [ -z "`echo $response | grep access_token`" ] && die "Could not retrieve oauth token: $response"

  # extract token from response
  echo -n $response | sed 's/[[:blank:]]//g' | sed -E 's/^.*"access_token":"([^"]*)".*$/\1/'
}

get_appd_cookie() {

  # curl request
  my_curl true --cookie-jar $appd_cookie_path ${appd_url}/controller/auth?action=login
  
  x_csrf_token="`grep X-CSRF-TOKEN $appd_cookie_path | sed 's/^.*X-CSRF-TOKEN[[:blank:]]*\(.*\)$/\1/'`"

  # validate response
  [ -z "$x_csrf_token" ] && warn "Could not retrieve AppDynamics login cookie"
}

get_entities_info() {

  url=$1
  regex=$2
  auth=$3

  response=`my_curl $auth $url`
  infos=`jq -r ".[] | select(.name | test(\"$regex\")) | .name,.id" <<<$response`

  app_infos=""
  last_info='id'

  PREV_IFS=$IFS
  IFS=$'\n'
  for info in ${infos}; do
    if [ `echo ${info} | grep -E '^[0-9]+$'` ] ; then  # app id
      app_infos+="=${info},"
      last_info='id'
    else
      if [ $last_info == 'id' ]; then # app name
        app_infos+="${info}"
      else # app name with space
        app_infos+=" ${info}"
      fi
      last_info='name'
    fi
  done
  IFS=$PREV_IFS

  echo -n ${app_infos}
}

get_applications_info() {
  controller_id=$1
  regex=$2
  get_entities_info "${config_exporter_url}/api/controllers/${controller_id}/applications" "$regex" false
}


get_dashboards_info() {
  controller_url=$1
  get_entities_info "${controller_url}/controller/restui/dashboards/getAllDashboardsByType/false" "$appd_dashboard_names" true
}

get_controller_id() {
  regex=$1
  response=`my_curl false "${config_exporter_url}/api/controllers"`
  id=`jq -r ".[] | select(.url | test(\"$regex\")) | .id" <<<$response`
  echo $id
}

set_appd_env() {
  target=$1

  if [ $target == 'source' ] ; then
    appd_url=$appd_src_url
    appd_account=$appd_src_account
    appd_api_user=$appd_src_api_user
    appd_api_password=$appd_src_api_password
    appd_proxy=$appd_src_proxy
  else
    appd_url=$appd_dst_url
    appd_account=$appd_dst_account
    appd_api_user=$appd_dst_api_user
    appd_api_password=$appd_dst_api_password
    appd_proxy=$appd_dst_proxy
  fi
}

init() {
  # source config file
  [ ! -r $config ] && die "$config is not readable"
  . $config

  # check required config entries
  [ -z "${appd_src_url-}" ] && die "Missing required config entry: appd_src_url"
  [ -z "${appd_src_account-}" ] && die "Missing required config entry: appd_src_account"
  [ -z "${appd_src_api_user-}" ] && die "Missing required config entry: appd_src_api_user"
  [ -z "${appd_src_api_password-}" ] && die "Missing required config entry: appd_src_api_password"
  [ -z "${appd_application_names-}" ] && die "Missing required config entry: appd_application_names"
  [ -z "${appd_dashboard_names-}" ] && die "Missing required config entry: appd_dashboard_names"
  [ -z "${output_dir-}" ] && die "Missing required config entry: output_dir"
  [ -z "${appd_application_config-}" ] && [ -z "${appd_account_config-}" ] && die "Missing required config entry: appd_application_config or appd_account_config"
  [ -z "${config_exporter_url-}" ] && die "Missing required config entry: config_exporter_url"
  
  if [ $mode == "migrate" ]; then
    [ -z "${appd_dst_url-}" ] && die "Missing required config entry: appd_dst_url"
    [ -z "${appd_dst_account-}" ] && die "Missing required config entry: appd_dst_account"
    [ -z "${appd_dst_api_user-}" ] && die "Missing required config entry: appd_dst_api_user"
    [ -z "${appd_dst_api_password-}" ] && die "Missing required config entry: appd_dst_api_password"
  fi

  # proxy
  [ ! -z "${appd_src_proxy-}" ] && appd_src_proxy="--proxy ${appd_src_proxy}"
  [ ! -z "${appd_dst_proxy-}" ] && appd_dst_proxy="--proxy ${appd_dst_proxy}"

  # clean config
  [ ! -z "${appd_application_config-}" ] && appd_application_config=`echo "$appd_application_config" | tr '\n' ' ' | sed 's/ //g'`
  [ ! -z "${appd_account_config-}" ] && appd_account_config=`echo "$appd_account_config" | tr '\n' ' ' | sed 's/ //g'`

  # display key config
  info "Running AppDynamics Config Manager mode: ${mode}"
  info "Using AppDynamics Source URL: ${appd_src_url}"
  [ -z "${appd_dst_url}" ] && info "Using AppDynamics Destination URL: ${appd_dst_url}"
  info "Using output directory: ${output_dir}"
  info "Using application name regex: ${appd_application_names}"
  info "Using dashboard name regex: ${appd_dashboard_names}"

  # create output dir if it does not exist
  if [ ! -d ${output_dir} ]; then 
    mkdir ${output_dir}
    [ $? -ne 0 ] && die "Could not create output directory: ${output_dir}"
  fi
  
  # launch config exporter
  if [ ! -z "${run-}" ]; then
    info "Starting Config Exporter with command: ${run}"
    eval "nohup ${run} > /dev/null 2>&1 &"
    [ $? -ne 0 ] && die "Config Exporter command failed"
    pid=$!

    info "Waiting for Config Exporter to load..."
    for i in `seq 1 $run_wait`; do
      echo -n "."
      sleep 1
    done
    echo
    info "Config Exporter started (pid = $pid)."
    fi
  return 0
}

cleanup() {
  trap - SIGINT SIGTERM EXIT
  # stop config exporter
  [ ! -z "${pid-}" ] && info "Stopping Config Exporter (pid = $pid)." && kill $pid
  # delete temporary file
  info "Cleaning up temporary files" 
  [ ! -z "${appd_cookie_path-}" ] && [ -f "$appd_cookie_path" ] && rm "$appd_cookie_path"
  [ ! -z "${json_config_path-}" ] && [ -f "$json_config_path" ] && rm "$json_config_path"
  info "Done."
}

#
# Export functions
#

export_dashboard() {
  name=$1
  id=$2
  
  [ $output_name_mode == "name" ] && output_file=${output_dir}/dashboards/${name}.json || output_file=${output_dir}/dashboards/${id}.json
  
  info "Exporting dashboard ${name}"
  my_curl true -o "${output_file}" "${appd_src_url}/CustomDashboardImportExportServlet?dashboardId=${id}"
}

export_dashboards() {

  info "Exporting dashboards"

  mkdir ${output_dir}/dashboards

  # retrieve dashboard names & ids from dashboard regex
  info "Retrieving AppDynamics dashboards details"
  dashboards_info=`get_dashboards_info $appd_src_url`
  info "Matched dashboards: $dashboards_info"

  # loop over all dashboards
  PREV_IFS=$IFS
  IFS=','
  for info in ${dashboards_info}; do
    IFS=$PREV_IFS
    name=`echo ${info} | cut -d '=' -f 1`
    id=`echo ${info} | cut -d '=' -f 2`
    export_dashboard "$name" $id
    IFS=','
  done
  IFS=$PREV_IFS

  return 0
}

export_config_entity() {
  name=$1
  id=$2
  entity=$3
  
  [ $output_name_mode == "name" ] && output_file="${output_dir}/${name}/${entity}.json" || output_file="${output_dir}/${id}/${entity}.json"

  info "Exporting ${entity}"
  my_curl false -o "${output_file}" "${config_exporter_url}/api/controllers/${appd_src_id}/files/${entity}?applicationId=${id}"
  
  validate_config_output "$output_file"
  [ $? -ne 0 ] && warn "There was an issue exporting ${entity} for application $name ($id)" && return 1

  return 0
}

validate_config_output() {
  file=$1
  grep controllerUrl "$file" > /dev/null 2>&1
  return $?
}

export_account_config() {

  info "Exporting account level configuration"
  mkdir ${output_dir}/account

  # loop over all account config
  PREV_IFS=$IFS
  IFS=','
  for entity in ${appd_account_config}; do
    IFS=$PREV_IFS
    if [ $entity == "dashboards" ]; then
      export_dashboards
    elif [ $entity == "server" ]; then
      application_config="health-rules,actions,policies,metric-baselines"
      applications_info=`get_applications_info $appd_src_id "Server & Infrastructure Monitoring"`
      export_application_config "$applications_info"  "$application_config"
    elif [ $entity == "analytics" ]; then
      application_config="health-rules,actions,policies,metric-baselines,analytics-searches,analytics-metrics"
      applications_info=`get_applications_info $appd_src_id "AppDynamics Analytics"`
      export_application_config "$applications_info" "$application_config"
    elif [ $entity == "database" ]; then
      application_config="health-rules,actions,policies,metric-baselines,db-collectors"
      applications_info=`get_applications_info $appd_src_id "Database Monitoring"`
      export_application_config "$applications_info" "$application_config"
    else
      export_config_entity account account $entity
    fi
  IFS=','
  done 
  IFS=$PREV_IFS

  return 0
}

export_application_config() {
  applications_info=$1
  application_config=$2

  # loop over all applications
  PREV_IFS=$IFS
  IFS=','
  for info in ${applications_info}; do
    IFS=$PREV_IFS
    name=`echo ${info} | cut -d '=' -f 1`
    id=`echo ${info} | cut -d '=' -f 2`
    info "Exporting configuration for application $name ($id)"
    [ $output_name_mode == "name" ] && mkdir "${output_dir}/${name}" || mkdir ${output_dir}/${id}

    # loop over config entities
    IFS=','
    for entity in ${application_config}; do
      IFS=$PREV_IFS
      export_config_entity "$name" $id $entity
      IFS=','
    done 
    IFS=','
  done
  IFS=$PREV_IFS

  return 0
}

export_config() {
  info "Export Configuration: Start"
    # create timestamp dir
    mkdir ${output_dir}/${timestamp}
    output_dir="${output_dir}/${timestamp}"

    # set default connection variables
    set_appd_env 'source'

    # if required, retrieve appd cookie and store it
    config_requiring_cookie='dashboard'
    if [ ! -z "${appd_account_config-}" -a ! -z "`echo ${appd_account_config-} | grep -E $config_requiring_cookie`" ]; then
      info "Retrieving AppDynamics login cookie at ${appd_url}"
      appd_cookie_path=${output_dir}/.appd_cookie
      get_appd_cookie
    fi
    
    # retrieve source controller id
    info "Retrieving Source Controller id"
    appd_src_id=`get_controller_id ${appd_url}`
    [ -z "$appd_src_id" ] && die "Could not retrieve the controller id via the Config Exporter API. Is ${appd_url} configured?"
    
    # export application config
    if [ ! -z "${appd_application_config-}" ]; then
      # retrieve application names & ids from application regex
      info "Retrieving AppDynamics application details"
      applications_info=`get_applications_info $appd_src_id "$appd_application_names"`
      info "Matched applications: $applications_info"
      info "Exporting AppDynamics application configuration"
      export_application_config "$applications_info" "$appd_application_config"
    fi

    # export account config
    if [ ! -z "${appd_account_config-}" ]; then
      info "Exporting AppDynamics account configuration"
      export_account_config
    fi

    info "Export Configuration: Completed"
}


#
# Migrate Functions
#

APPD_APP_CONFIG_MAP='
scopes=CONFIG20_SCOPES,
rules=CONFIG20_RULES,
backend-detection=BACKEND_DETECTION,
exit-points=CUSTOM_EXIT_POINTS,
info-points=INFORMATION_POINTS,
health-rules=HEALTH_RULES,
actions=ACTIONS,
policies=POLICIES,
metric-baselines=METRIC_BASELINES,
bt-config=BT_CONFIG,
data-collectors=DATA_COLLECTORS,
call-graph-settings=CALL_GRAPH_SETTINGS,
error-detection=ERROR_DETECTION,
jmx-rules=JMX_RULES,
appagent-properties=APPAGENT_PROPERTIES,
service-endpoint-detection=SERVICE_ENDPOINT_DETECTION,
slow-transaction-thresholds=SLOW_TRANSACTION_THRESHOLDS,
eum-app-integration=EUM_APP_INTEGRATION,
async-config=ASYNC_CONFIG,
db-collectors=DB_COLLECTORS,
analytics-searches=ANALYTICS_SEARCH,
analytics-metrics=ANALYTICS_METRICS,
browser-eum-config=EUM_BROWSER_CONFIG,
mobile-eum-config=EUM_MOBILE_CONFIG,
synthetic-jobs=EUM_SYNTHETIC_JOBS'

get_migration_json_template() {
  src_controller_id=$1
  dst_controller_id=$2
  app_config=$3

  # loop over config entities and convert to migration json config
  app_config_json=''
  PREV_IFS=$IFS
  IFS=','
  for entity in $app_config; do
    IFS=$PREV_IFS
    entity_conv=`echo $APPD_APP_CONFIG_MAP | grep $entity | sed -E "s/^.*${entity}=([^,]+).*$/\1/"`
    [ -z "$entity_conv" -o ! -z "`echo $entity_conv | grep '='`" ] && die "Could not convert app config entity '$entity'."
    app_config_json="${app_config_json}, \"$entity_conv\""
    IFS=','
  done
  IFS=$PREV_IFS

  # clean result
  app_config_json=`echo $app_config_json | sed -E 's/^, (.*)$/\1/'`

echo -n "{
  \"srcControllerId\":$src_controller_id,
  \"destControllerId\":$dst_controller_id,
  \"srcApplicationId\":%srcApplicationId%,
  \"destApplicationId\":%destApplicationId%,
  \"configNames\":[$app_config_json],
  \"properties\":{
    \"overwrite\": ${overwrite_on_export},
    \"createTier\": ${create_tier_on_export}
  }
}"
}

get_dst_id_from_src_app() {
  name=$1
  applications_info=$2

  id=`echo $applications_info | sed -E "s/^.*${name}=([^,]+),.*$/\1/"`
  # check if id is correct
  if [ -z "`echo $id | grep ','`" ]; then
    echo $id
  else
     echo ''
  fi
}


migrate_application_config() {

  # get json migration template
  json_config_path=${output_dir}/.json_config
  json_temp=`get_migration_json_template $src_appd_id $dst_appd_id "$appd_application_config"`

  # loop over all source applications
  PREV_IFS=$IFS
  IFS=','
  for info in ${src_applications_info}; do
    IFS=$PREV_IFS
    src_name=`echo ${info} | cut -d '=' -f 1`
    src_id=`echo ${info} | cut -d '=' -f 2`
    info "Migrating configuration for application $src_name ($src_id)"

    # get application id on destination
    dst_id=`get_dst_id_from_src_app $src_name "$dst_applications_info"`
    # debug
    dst_id='4252'
    # fixme: auto create application on destination
    [ -z "$dst_id" ] && warn "Could not migrate application: $src_name not found on destination. Please create the application first." && continue
    info "Found matching application $src_name ($dst_id) on destination"
    
    # create json file
    echo "$json_temp" | sed "s/%srcApplicationId%/$src_id/" | sed "s/%destApplicationId%/$dst_id/" > $json_config_path

    # migrate application
    my_curl false -H "Content-Type: application/json" --data @${json_config_path} "${config_exporter_url}/api/rest/app-config"

    IFS=','
  done
  IFS=$PREV_IFS

  return 0
}

migrate_config() {
  info "Migrate Configuration: Start"
    # create timestamp dir
    mkdir ${output_dir}/${timestamp}
    output_dir="${output_dir}/${timestamp}"
  
    # retrieve source controller id
    info "Retrieving Source Controller id"
    src_appd_id=`get_controller_id ${appd_src_url}`
    [ -z "$src_appd_id" ] && die "Could not retrieve the controller id via the Config Exporter API. Is ${appd_src_url} configured?"
    # retrieve destination controller id
    info "Retrieving Destination Controller id"
    dst_appd_id=`get_controller_id ${appd_dst_url}`
    [ -z "$dst_appd_id" ] && die "Could not retrieve the controller id via the Config Exporter API. Is ${appd_dst_url} configured?"

    # migrate application config
    if [ ! -z "${appd_application_config-}" ]; then
      # retrieve source application names & ids from application regex
      info "Retrieving Source AppDynamics application details"
      src_applications_info=`get_applications_info $src_appd_id "$appd_application_names"`
      info "Matched applications: $src_applications_info"
      # retrieve destination application names & ids from application regex
      info "Retrieving Destination AppDynamics application details"
      dst_applications_info=`get_applications_info $dst_appd_id "$appd_application_names"`
      info "Matched applications: $dst_applications_info"

      info "Migrating AppDynamics application configuration"
      migrate_application_config "$src_applications_info" "$dst_applications_info" "$appd_application_config"
    fi

    # migrate account config
    if [ ! -z "${appd_account_config-}" ]; then
      die "Migrate Account Config is not yet implemented." #FIXME
    fi

    info "Migrate Configuration: Completed"
}

#
# Main
#

init

if [ $mode == "export" ]; then
  export_config
elif [ $mode == "migrate" ]; then
  migrate_config
else
  die "Unknown mode: $mode"
fi
