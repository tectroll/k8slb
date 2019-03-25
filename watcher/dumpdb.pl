#!/usr/bin/perl

use strict;
use Data::Dumper;

use lib 'lib';
use k8slb_api;
use k8slb_db;

my $db;
dbFromJSON($db, readConfig('working'));
print Dumper $db;
print "\n### Keepalived ###\n" . readConfig('keepalived');
print "\n### HAProxy ###\n" . readConfig('haproxy');
#print "\n### Nginx: ###\n" . readConfig('nginx');
