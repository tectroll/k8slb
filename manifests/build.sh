#!/bin/sh

cat namespace.yml config-haproxy.yml rbac.yml watcher.yml actor-haproxy.yml > k8slb-haproxy.yml
cat namespace.yml config-nginx.yml rbac.yml watcher.yml actor-nginx.yml > k8slb-nginx.yml
cat namespace.yml config-kubeproxy.yml rbac.yml watcher.yml actor-kubeproxy.yml > k8slb-kubeproxy.yml
