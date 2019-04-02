#!/bin/sh

source ./VERSION

echo Making version $VERSION...

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

docker build -t tectroll/k8slb-watcher:$VERSION -f watcher/Dockerfile .
if [ $? -ne 0 ]; then
  echo "ERROR: watcher docker image failed"
  exit
fi
docker push tectroll/k8slb-watcher:$VERSION

docker build -t tectroll/k8slb-actor:$VERSION -f actor/Dockerfile .
if [ $? -ne 0 ]; then
  echo "ERROR: actor docker image failed"
  exit
fi
docker push tectroll/k8slb-actor:$VERSION

cd manifests
./build.sh

echo "COMPLETE"
