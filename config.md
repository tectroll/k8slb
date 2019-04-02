## Advanced Configuration

### Watcher

#### Environment variables
You can change the watcher's behavior by setting the following environment variables.  You can easily break things by changing these.

* LOG_LEVEL: (Default: 3) 0 - no logging, 1 - ERROR, 2 - WARNING, 3 - INFO, 4 - DEBUG
* NODE_SELECTOR: (Default: type=loadBalancer) Set the node selector.  You will need to change this in the actor manifest as well.
* LOOP_DELAY: (Default: 10) Number of seconds between polling for changes.
* CERT_PATH: (Default: /etc/certs) Set the path to SSL certificates.  You will need to change this in the actor manifest as well.
* FORCE_UPDATE: (Default: 0) Set to positive value to force watcher to update it's database
* WIPE_DB: (Default: 0) Set to positive value to wipe watcher's database and regenerate.  This can be useful if an update corrupts the databas
e causing watcher or actor to fail to launch.
* PROXY: (Default: haproxy) Sets which proxy backend to use.  You will need to change this in the actor manifest as well, and make sure the gl
obal configuration supports the backend.


### Actor

#### Environment variables
You can change the actor's behavior by setting the following environment variables.  You can easily break things by changing these.

* LOG_LEVEL: (Default: 3) 0 - no logging, 1 - ERROR, 2 - WARNING, 3 - INFO, 4 - DEBUG
* KA_OPTIONS: (Default: -P -D -l) Sets keepalived command options
* KA_WAIT: (Default: 10) Number of seconds to wait after starting keepalived before checking health
* HP_OPTIONS: (Default: -f /etc/haproxy/haproxy.cfg -p /run/haproxy.pid -sf $(cat /run/haproxy.pid)) Sets HAProxy command options.  Change -sf to -st to reduce resource usage, but this terminates connections on configuration changes.
* HP_WAIT: (Default: 1) Number of seconds to wait after starting HAProxy before checking health
* NX_OPTIONS: (Default: -c /etc/nginx/nginx.conf) Sets nginx command options
* NX_WAIT: (Default: 1) Number of seconds to wait after starting nginx before checking health
* NO_IPTABLES: (Default: 0) Set to positive value to skip adding iptable exceptions for services
* BACKUP_DIR: (Default: /tmp) Set directory to store backup configuration files
* BACKUP_ENABLE: (Default: 1) Set to positive value to keep archive of configuration files
* MAX_LOADBALANCERS: (Default: 9) Set to threshold for maximum number of load balancer nodes.  Note, going over 9 might cause problems with VR
RP virtual router id.
* LOOP_DELAY: (Default: 10) Number of seconds between polling for changes.
* PROXY: (Default: haproxy)  Sets which proxy backend to use.  You will need to change this in the watcher manifest as well, and make sure the global configuration supports the backend.
* PRIORITY#: (Default: ) Override keepalived priority for load balancer number #

### SSL Termination

#### Annotations
These are placeholder annotations for controlling SSL termination.  Note, these are not implemented yet!
* loadbalancer/mode
   * Leave blank for auto detection
   * Set to http to force layer 7 http handling in proxy
   * Set to false to force layer 4 passthrough
* loadbalancer/ssl
   * Leave blank for auto detection
   * Set to true to force SSL termination on frontend
   * Set to false to force no SSL termination on frontend
* loadbalancer/sslbackend
   * Leave blank for auto detection
   * Set to true to force SSL negotiation to backend
   * Set to false to force no SSL negotiation to backend
* loadbalancer/sslredirect
   * Set to false to disable automatic port 80 redirect for SSL termination

