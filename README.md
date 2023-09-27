# appd_cfg_manager
A script that does backups and migrations of AppDynamics Configuration via the AppD API and Config Exporter API

Usage: appd_cfg_manager.sh [-h] [-v] [-r "command"] -m export|import -c config_file

A script that does backups and migrations of AppDynamics Configuration.

Available options:

-h, --help        Print this help and exit<br>
-v, --verbose     Print script debug info<br>
-r, --run         Command to run the Config Exporter. Do not set if it is already running.<br>
-m, --mode        export or migrate<br>
-c, --config      Path to config file<br>

Example:

./appd_cfg_manager.sh -m export -c appd_prod.cfg -r "java -jar /opt/tools/config_exporter/config-exporter-20.6.0.3.war"<br>

Content of the config file:

appd_src_url='http://src_account.saas.appdynamics.com:443' # appd source controller url<br>
appd_src_account='src_account' # appd account<br>
appd_src_api_user='<user>' # appd api username<br>
appd_src_api_password='<password>' # appd api password<br>
appd_src_proxy='' # http proxy<br>
<br>
appd_dst_url='http://dst_account.saas.appdynamics.com:443' # migrate: appd destination controller url<br>
appd_dst_account='dst_account' # appd account<br>
appd_dst_api_user='<user>' # appd api username<br>
appd_dst_api_password='<password>' # appd api password<br>
appd_dst_proxy='' # http proxy<br>

appd_application_names='.\*' # application names regex<br>
appd_dashboard_names='.*' # dashboard names regex<br>
appd_application_config='scopes,rules,backend-detection,exit-points,info-points,
bt-config,data-collectors,call-graph-settings,error-detection,jmx-rules,appagent-properties,
service-endpoint-detection,slow-transaction-thresholds,eum-app-integration,async-config,
health-rules,actions,policies,metric-baselines,
browser-eum-config,mobile-eum-config,synthetic-jobs' # app config <br>
appd_account_config='admin-settings,http-templates,email-templates,email-sms-config,license-rules,dashboards,database,server,analytics' # account config <br>

config_exporter_url='http://localhost:8282' # config exporter url. Make sure you have an instance running or use the --run option<br>
output_dir='./output' # output dir<br>
create_app_on_export='true' # create application on export <br>
create_tier_on_export='true' # create tier on export <br>
overwrite_on_export='true' # overwrite on export <br>
