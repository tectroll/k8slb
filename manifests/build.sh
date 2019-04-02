#!/bin/sh

source ../VERSION

cat namespace.yml config-haproxy.yml rbac.yml > k8slb-haproxy.yml
sed "s/:latest/:$VERSION/" watcher-haproxy.yml >> k8slb-haproxy.yml
sed "s/:latest/:$VERSION/" actor-haproxy.yml >> k8slb-haproxy.yml

cat namespace.yml config-nginx.yml rbac.yml > k8slb-nginx.yml
sed "s/:latest/:$VERSION/" watcher-nginx.yml >> k8slb-nginx.yml
sed "s/:latest/:$VERSION/" actor-nginx.yml >> k8slb-nginx.yml

cat namespace.yml config-kubeproxy.yml rbac.yml > k8slb-kubeproxy.yml
sed "s/:latest/:$VERSION/" watcher-kubeproxy.yml >> k8slb-kubeproxy.yml
sed "s/:latest/:$VERSION/" actor-kubeproxy.yml >> k8slb-kubeproxy.yml

