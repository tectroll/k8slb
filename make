#!/bin/sh

# Sanity checks
perl -c watcher/watcher.pl
if [ $? -ne 0 ]; then
  echo "ERROR: Watcher failed"
  exit
fi
perl -c actor/actor.pl 
if [ $? -ne 0 ]; then
  echo "ERROR: Actor failed"
  exit
fi

docker build -t tectroll/k8slb-watcher:latest -f watcher/Dockerfile .
if [ $? -ne 0 ]; then
  echo "ERROR: watcher docker image failed"
  exit
fi
docker push tectroll/k8slb-watcher:latest

docker build -t tectroll/k8slb-actor:latest -f actor/Dockerfile .
if [ $? -ne 0 ]; then
  echo "ERROR: actor docker image failed"
  exit
fi
docker push tectroll/k8slb-actor:latest

echo "COMPLETE"