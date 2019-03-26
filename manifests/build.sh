#!/bin/sh

cat namespace.yml config-haproxy.yml rbac.yml watcher-haproxy.yml actor-haproxy.yml > k8slb-haproxy.yml
cat namespace.yml config-nginx.yml rbac.yml watcher-nginx.yml actor-nginx.yml > k8slb-nginx.yml
cat namespace.yml config-kubeproxy.yml rbac.yml watcher-kubeproxy.yml actor-kubeproxy.yml > k8slb-kubeproxy.yml
