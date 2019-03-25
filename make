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

docker build -t docker.cs.vt.edu/carnold/library/watcher -f watcher/Dockerfile .
if [ $? -ne 0 ]; then
  echo "ERROR: watcher docker image failed"
  exit
fi
docker push docker.cs.vt.edu/carnold/library/watcher

docker build -t docker.cs.vt.edu/carnold/library/actor -f actor/Dockerfile .
if [ $? -ne 0 ]; then
  echo "ERROR: actor docker image failed"
  exit
fi
docker push docker.cs.vt.edu/carnold/library/actor

echo "COMPLETE"
