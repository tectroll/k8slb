#!/usr/bin/perl

use strict;
use JSON;
use Data::Dumper;
use Net::IP;

use lib 'lib';
use k8slb_api;
use k8slb_db;
use k8slb_log;

my %watcherConfig = (
  logLevel => 		$ENV{LOG_LEVEL} || INFO,
  nodeSelector => 	$ENV{NODE_SELECTOR} || 'type=loadBalancer',
  delay => 		$ENV{LOOP_DELAY} || 10,
  certPath =>		$ENV{CERT_PATH} || '/etc/certs',
  forceUpdate =>	$ENV{FORCE_UPDATE} || 0,
  wipeDB =>		$ENV{WIPE_DB} || 0,
);

logLevel($watcherConfig{logLevel});

my $db;
if (! $watcherConfig{wipeDB})
{
  dbFromJSON($db, readConfig('working'));
}
info("Waiting for changes...");
while (1)
{
  debug("Checking for update...");
  my $changed = 0;
  $changed = 1 if globalsFromJSON($db, readConfig('global') );
  $changed = 1 if loadBalancersFromJSON($db, readNodes($watcherConfig{nodeSelector}) );
  $changed = 1 if servicesFromJSON($db, readServices() );
  my $serviceHash = servicesToHash($db);
  foreach my $service ( keys(%{$serviceHash}) )
  {
    $changed = 1 if podsFromJSON($db, $service, readPods($serviceHash->{$service}->{nameSpace}, $serviceHash->{$service}->{selector}));
  }
  if ($watcherConfig{forceUpdate})
  {
    $changed = 1;
    $watcherConfig{forceUpdate} = 0;
  }
  if ($changed)
  {
    writeConfig('working', dbToJSON($db));
    writeConfig('keepalived', genKeepalive($db) );
    if (proxyType() eq 'haproxy')
    {
      writeConfig('haproxy', genHAProxy($db) );
    } elsif (proxyType() eq 'nginx') {
      writeConfig('nginx', genNginx($db) );
    }
  } else {
    debug("Nothing changed");
  }
  sleep($watcherConfig{delay});
}

sub genKeepalive
{
  my ($db) = @_;

  my $globalsHash = globalsToHash($db);
  my $lbHash = loadBalancersToHash($db);

  my $output = '';
  $output .= "global_defs \{";
  my $email = '';
  if ( $globalsHash->{keepalived}->{email} )
  {
    $email = 'smtp_alert';
    $output .= "
  notification_email \{";
  $output .= "
    $globalsHash->{keepalived}->{email}
  \}";
    $output .= "
  notification_email_from $globalsHash->{keepalived}->{emailFrom}
  smtp_server $globalsHash->{keepalived}->{emailServer}
  smtp_connect_timeout $globalsHash->{keepalived}->{emailServerTimeout}";
  }
  $output .= "
  router_id \{\{ HOSTNAME \}\}
\}
";

  my $lb = 0;
  foreach my $name ( keys(%{$lbHash}) )
  { # LB for loop
    $lb++;
    $output .= "
vrrp_sync_group LB$lb \{
  group \{";
    foreach my $p ( keys(%{$globalsHash->{pools}}) )
    { # LB Pool group loop
      $output .= "
    LB$lb\_$p";
    } # LB Pool group loop
    $output .= "
  \}
  $email
\}
";
    my $rid = 0;
    foreach my $pool ( keys(%{$globalsHash->{pools}}) )
    { # LB pool instance loop
      $rid++;
      my $p = $globalsHash->{pools}->{"$pool"};
      my $interface = $p->{interface} || "\{\{ INT".uc($pool)." \}\}";
      $output .= "
vrrp_instance LB$lb\_$pool {
  state BACKUP
  priority \{\{ PRIORITY$lb \}\}
  interface $interface
  virtual_router_id $lb$rid
  authentication \{
    auth_type PASS
    auth_pass woftam
  \}
";
      my $count = 0;
      $output .= "  virtual_ipaddress \{\n";
      foreach my $ip ( @{$lbHash->{$name}->{$pool}} )
      {
        if ($count == 0)
        {
          $output .= "    $ip\n  \}\n  virtual_ipaddress_excluded \{\n";
        } else {
          $output .= "    $ip\n";
        }
      }
      $output .= "  \}
\}
";
    } # LB pool instance loop
    
  } # LB for loop

  return($output);
}

sub genHAProxy
{
  my ($hash) = @_;

  my $globalsHash = globalsToHash($db);
  my $lbHash = loadBalancersToHash($db);
  my $serviceHash = servicesToHash($db);

#debug Dumper $serviceHash;
#return('');

  my $output = "global\n";
  foreach my $o ( @{$globalsHash->{haproxy}->{global}} )
  {
    $output .= "  $o\n";
  }
  $output .= "\ndefaults\n";
  foreach my $o ( @{$globalsHash->{haproxy}->{defaults}} )
  {
    $output .= "  $o\n";
  }

  foreach my $service ( keys(%{$serviceHash}) )
  {
    if ($serviceHash->{$service}->{status})
    {
      foreach my $port ( @{$serviceHash->{$service}->{ports}} )
      {
        if ( lc($port->{protocol}) eq 'tcp' )
        {
          # Backend
          my $mode = 'tcp';
          # Try to determine mode automatically
          if ($port->{port} eq '80' || $port->{port} eq '443' || $port->{targetPort} eq '80' || $port->{targetPort} eq '443')
          {
            $mode = 'http';
          }
          my $id = "$serviceHash->{$service}->{nameSpace}\_$service";
          $output .= "\nbackend  $id\_$port->{name}_backend\n";
          $output .= "  mode  $mode\n";
          if ($mode eq 'http')
          {
            foreach my $option ( @{$hash->{globals}->{haproxy}->{httpback}} )
            {
              $output .= "  $option\n";
            }
          } else {
            foreach my $option ( @{$hash->{globals}->{haproxy}->{tcpback}} )
            {
              $output .= "  $option\n";
            }
          }
          my $backendOpt = 'check';
          if ($port->{targetPort} eq '443' || lc(substr($port->{name},0,5)) eq 'https' )
          {
            $backendOpt .= " ssl verify none";
          }
          foreach my $pod ( keys(%{$serviceHash->{$service}->{pods}}) )
          {
            $output .= "  server $pod $serviceHash->{$service}->{pods}->{$pod}:$port->{targetPort} $backendOpt\n";
          }

          # Frontend
          my $ssl = '';
          if ($port->{port} eq '443')
          {
            $ssl .= " ssl crt /etc/certs/$serviceHash->{$service}->{pool}.pem";
          }
          $output .= "\nfrontend  $id\_$port->{name}\n";
          $output .= "  mode  $mode\n";
          if ($mode eq 'http')
          {
            foreach my $option ( @{$hash->{globals}->{haproxy}->{httpfront}} )
            {
              $output .= "  $option\n";
            }
          } else {
            foreach my $option ( @{$hash->{globals}->{haproxy}->{tcpfront}} )
            {
              $output .= "  $option\n";
            }
          }
          $output .= "  bind  $serviceHash->{$service}->{status}:$port->{port}$ssl\n";
          $output .= "  default_backend  $id\_$port->{name}_backend\n";
        } else {
          error("Don't know how to handle protocol $port->{protocol} for $serviceHash->{$service}->{name}");
        }
      }
    } else {
      info("Skiping service $serviceHash->{$service}->{name}, no IP");
    }
  }
#debug $output;
  return($output);
}

sub genNginx
{
  my ($hash) = @_;

  my $globalsHash = globalsToHash($db);
  my $lbHash = loadBalancersToHash($db);
  my $serviceHash = servicesToHash($db);

  my $output = '';
  foreach my $o ( @{$globalsHash->{nginx}->{global}} )
  {
    $output .= "$o\n";
  }

  ### Begin http block ###
  $output .= "http {\n";
  foreach my $o ( @{$globalsHash->{nginx}->{http}} )
  {
    $output .= "  $o\n";
  }
  foreach my $service ( keys(%{$serviceHash}) )
  {
    if ($serviceHash->{$service}->{status})
    {
      foreach my $port ( @{$serviceHash->{$service}->{ports}} )
      {
        if ( lc($port->{protocol}) eq 'tcp' )
        {
#TODO: Allow override for choosing http vs tcp in service spec
          # Try to determine mode automatically
          if ((lc(substr($port->{name},0,4)) eq 'http') || $port->{port} eq '80' || $port->{port} eq '443' || $port->{targetPort} eq '80' || $port->{targetPort} eq '443')
          {
            my $id = "$serviceHash->{$service}->{nameSpace}\_$service";
            ### Backend ###
            $output .= "  upstream $id\_$port->{name}_backend {\n";
            foreach my $o ( @{$globalsHash->{nginx}->{upstream}} )
            {
              $output .= "    $o\n";
            }
            my $backendOpt = "max_fails=3 fail_timeout=5s";
            foreach my $pod ( keys(%{$serviceHash->{$service}->{pods}}) )
            {
              $output .= "    server $serviceHash->{$service}->{pods}->{$pod}:$port->{targetPort} $backendOpt;\n";
            }
            $output .= "  }\n";

            ### Frontend ###
            $output .= "  server {\n";
            if ($port->{port} eq '443')
            {
              $output .= "    listen $serviceHash->{$service}->{status}:$port->{port} ssl;\n"; 
              $output .= "    ssl_certificate     $watcherConfig{certPath}/$serviceHash->{$service}->{pool}.pem;\n";
              $output .= "    ssl_certificate_key $watcherConfig{certPath}/$serviceHash->{$service}->{pool}.key;\n";
            } else {
              $output .= "    listen $serviceHash->{$service}->{status}:$port->{port};\n"; 
            }
            $output .= "    location / {\n";
            foreach my $o ( @{$globalsHash->{nginx}->{proxy}} )
            {
              $output .= "    $o\n";
            }
            if ($port->{targetPort} eq '443')
            {
              $output .= "      proxy_pass https://$id\_$port->{name}_backend;\n";
            } else {
              $output .= "      proxy_pass http://$id\_$port->{name}_backend;\n";
            }
            $output .= "    }\n";
            $output .= "  }\n\n";
          }
        }
      }
    } else {
      info("Skipping service $service, no IP");
    }    
  }
  $output .= "}\n";

  ### Begin stream block ###
  $output .= "\nstream {\n";
  foreach my $o ( @{$globalsHash->{nginx}->{stream}} )
  {
    $output .= "  $o\n";
  }
  foreach my $service ( keys(%{$serviceHash}) )
  {
    if ($serviceHash->{$service}->{status})
    {
      foreach my $port ( @{$serviceHash->{$service}->{ports}} )
      {
        if ( lc($port->{protocol}) eq 'tcp' )
        {
#TODO handle TCP/UDP
        } else {
          error("Don't know how to handle protocol $port->{protocol} for $serviceHash->{$service}->{name}");
        }
      }
    }
  }
  $output .= "}\n";
#debug $output;
  return($output);
}

