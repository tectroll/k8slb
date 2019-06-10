FROM alpine:3.9
RUN apk update && apk upgrade && apk add bash iptables ip6tables keepalived haproxy curl perl perl-data-dumper perl-json perl-net-http perl-lwp-useragent-determined perl-lwp-protocol-https perl-encode perl-net-ip perl-datetime
COPY actor/actor.pl /usr/local/bin/
COPY watcher/dumpdb.pl /usr/local/bin/
COPY lib /usr/local/bin/lib/
WORKDIR /usr/local/bin
CMD actor.pl
#CMD /bin/bash
