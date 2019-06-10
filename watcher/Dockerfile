FROM alpine:3.9
RUN apk update && apk upgrade && apk add bash curl perl perl-data-dumper perl-json perl-net-http perl-lwp-useragent-determined perl-lwp-protocol-https perl-encode perl-net-ip perl-datetime
COPY watcher/watcher.pl /usr/local/bin/
COPY watcher/dumpdb.pl /usr/local/bin/
COPY lib /usr/local/bin/lib/
WORKDIR /usr/local/bin
CMD ["watcher.pl"]
