## Layer 4 Load Balancer for Kubernetes Cluster
This project aims to implement a load balancer for kubernetes, specifically for the Rancher v2 UI.  It will be based on Keepalived and HAProxy with custom written perl code to glue the pieces (K8s, Keepalived, HAProxy) together.

### Requirements
Requires linux based Kubernetes nodes.  It is created for and tested with CentOS 7, but should work with others.

### Installation
The load balancer contains two components: watcher and actor.  Watcher is a deployment that runs on a single node, it watches for changes in Kubernetes configuration and "publishes" changes to the actors.  The actor component is a daemonset with default node selector of type=loadBalancer, and is actually responsible for configuring the IP and proxying your services.  You need to label the nodes you want to act as load Balancers.
These instructions are specific to RKE launched Kubernetes, but could be applied to other K8s.

#### Configuring load balancer nodes
k8slb system uses the default node selector of "type=loadBalancer", you need to the label the nodes you want to act as load balancers:

`kubectl label nodes <lb-node-names-list> type=loadBalancer`

RKE deploys nginx-ingress controller on every node, listening on ports 80 and 443.  If you plan to load balance ports 80 or 443, then you will need to reconfigure the default nginx-ingress.  I suggest limiting the nginx-ingress to nodes other than the load balancer nodes.  Example:

`kubectl label nodes <ingress-node-names-list> type=ingress`

`kubectl edit daemonset/nginx-ingress-controller -n ingress-nginx`

    hostNetwork: true
    nodeSelector:
      type: ingress
    restartPolicy: Always

k8slb system can use three different proxy back-ends to host the: haproxy, nginx, already existing kube-proxy.  Haproxy is the default, it offers the best options with minimum configuration.  Nginx offers similar options with advanced configuration.  kube-proxy works with no additional configuration, but very few options such as IPv4 only, no load balancing, no service checks.

Download the k8slb manifest 

HAProxy - [k8slb-haproxy.yml](../manifests/k8slb-haproxy.yml)

Nginx - [k8slb-nginx.yml](../manifests/k8slb-nginx.yml)

Kube-proxy - [k8slb-kubeproxy.yml](../manifests/k8slb-kubeproxy.yml)

Edit the file to match your environment.  Specifically, the IP pool(s) and email notifications.

Apply the manifest to install the load balancer.

`kubectl apply -f k8slb.yml`

### Usage
k8slb system provides your kubernetes services a floating IP.  It does not use kubernetes service IP, but does it's own proxying to offer you more flexability.  It can be used to externally access kubernetes pods, externally terminate SSL connections to kubernetes pods, load balance traffic to multiple pods, even simulate a dual stack IPv4/IPv6 service.  IPs can be set statically or dynamically.

#### Pools
Changes to the IP pools are made by editing the k8slb.yml manifest and applying the changes.  Pools are configured in JSON format.  The manifest comes with a "default" pool.  The default pool is used when no pool is specified with the loadBalancer/pool annotation.  

##### Fields
* "network"  This field is required. It specifies the full range of valid IPs for this pool, including the static and dynamic IPs.  Statically assigned IPs for this pool must fall within this range.  Can be specified as a CIDR or as a start-stop range.
* "range" This field is required. It specifies the range of IPs to assign dynamically.  Can be specified as a CIDR or as a start-stop range.
* "interface" This field is optional.  If interface is specified, then it forces all loadBalancers to use that network interface for this pool.  If interface is blank or missing, then each load balancer will attempt to automatically detect which network interface to use for the pool.  

##### Pool Examples
Two pools, a default pool using private IPs, automatically detecting interface and a pool for external IPs 

     "pools": {
       "default": {
         "network": "192.168.10.0/24",
         "range": "192.168.10.200-192.168.10.254"
       },
       "external": {
         "network": "1.2.3.0/22",
         "range": "1.2.3.50-1.2.3.74",
         "interface": "em1"
       }
     }

Two pools, a default pool for IPv4 addresses and a pool for IPv6 addresses

    "pools": {
      "default": {
        "network": "1.2.3.0/22",
        "range": "1.2.3.50-1.2.3.74",
        "interface": "eth0"
      },
      "ipv6": {
        "network": "2001:468::/64",
        "range": "2001:468:101::/96",
        "interface": "eth0"
      }
    }

#### Services
Services are configured using kubernetes services API, with type of LoadBalancer.
##### Fields
* "spec:type = LoadBalancer"  This field is required, it tells the k8slb-system to set up an IP for the service
* "spec:ports = [array of ports]"  This field is required, it tells the k8slb-system which port(s) to forward to the service
* "spec:selector = \<label>"  This field is required, it tells the k8slb-system which pod(s) to forward the traffic to
* "spec:loadBalancerIP = \<IP>"  This field is optional.  If set the system will attempt to assign IP to this service statically

You create services as yaml file manifests, and apply them using kubectl.

#### Service Examples
Provide external access to a simple http kubernetes pod (label "app: myapp") with a dynamically assigned IP from the "default" pool.  This is the most basic example of a load balancer service.  Create a file myapp-loadbalancer.yml with the following:

    apiVersion: v1
    kind: Service
    metadata:
      name:  myapp-loadbalancer
      namespace: default
    spec:
      ports:
        - name: http
          port: 80
          protocol: TCP
          targetPort: 80
      selector:
        app: myapp
      type: LoadBalancer

Create the service by applying the manifest:

`kubectl apply -f myapp-loadbalancer.yml`

Found out the external IP, by listing the services:

`kubectl get services -n default`

This example takes it a step further by adding SSL termination.  The SSL cert is loaded from /etc/certs/default.pem on the load balancer nodes.

    apiVersion: v1
    kind: Service
    metadata:
      name:  myapp-loadbalancer
      namespace: default
    spec:
      ports:
        - name: https
          port: 443
          protocol: TCP
          targetPort: 80
      selector:
        app: myapp
      type: LoadBalancer

Here is an example of self-hosting rancher UI using k8slb and a static IP from IP pool called external.  Note, this does not use the nginx-ingress controller, but directly proxies to the rancher pods.  Also provides SSL termination.

    apiVersion: v1
    kind: Service
    metadata:
      name:  rancher-loadbalancer
      namespace: cattle-system
      annotations:
        loadbalancer/pool: external
    spec:
      loadBalancerIP: 1.2.3.4
      ports:
        - name: https
          port: 443
          protocol: TCP
          targetPort: 443
      selector:
        app: rancher
      type: LoadBalancer

Here is an example of simulating a dual stack application.  It creates two loadBalancer services pointing to the same pods, one with IPv4 and the other with IPv6.

    apiVersion: v1
    kind: Service
    metadata:
      name:  myapp-loadbalancer
      namespace: default
      annotations:
        loadbalancer/pool: external
    spec:
      loadBalancerIP: 1.2.3.4
      ports:
        - name: http
          port: 80
          protocol: TCP
          targetPort: 80
      selector:
        app: myapp
      type: LoadBalancer
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name:  myapp-loadbalancer6
      namespace: default
      annotations:
        loadbalancer/pool: ipv6
    spec:
      loadBalancerIP: 2001:468:201::4
      ports:
        - name: http
          port: 80
          protocol: TCP
          targetPort: 80
      selector:
        app: myapp
      type: LoadBalancer


### SSL Termination
By default, the system will automatically enable SSL termination to services if one or more of the following is true:
* listens to port 443 publicly 
* port name starts with "https"

By default, each pool uses its own wildcard certificate for the SSL termination, located under /etc/certs
* HAProxy: /etc/certs/\<poolname>.pem  Format is cert bundle supported by HAProxy http://cbonte.github.io/haproxy-dconv/1.9/configuration.html#5.1-crt
* Nginx: /etc/certs/\<poolname>.pem & /etc/certs/\<poolname>.key
* Kube-proxy: no support for SSL termination

To change the default behavior of SSL termination, see [Advanced Configuration](config.md)

