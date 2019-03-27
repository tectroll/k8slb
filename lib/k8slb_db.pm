package k8slb_db;

BEGIN {
    use 5.004;
    use Exporter();
    use vars qw($VERSION @ISA @EXPORT %dbConfig);
    $VERSION = "0.1";
    @ISA = qw(Exporter);
    @EXPORT = qw(
			&proxyType
			&dbFromJSON
			&dbToJSON
                        &globalsToHash
                        &globalsFromJSON
			&loadBalancersToHash
			&loadBalancersFromJSON
			&servicesToHash
			&servicesFromJSON
			&podsFromJSON
			&ipByService
			&ipByLoadBalancer
                        &ipAssign
		        &ipUnassign
			&iptablesRules
			&ip6tablesRules
			&ipVersion
			&devFromIP
                        FREE
                        ASSIGNED
                        INVALID
    );
}

use strict;
use JSON;
use Data::Dumper;
use Net::IP qw(:PROC);
use k8slb_log;
use k8slb_api;

use constant {
  FREE => 0,
  ASSIGNED => 1,
  INVALID => 2,
};

%dbConfig = (
);

# Valid proxies are: 'haproxy', 'nginx', 'kubeproxy'
sub proxyType
{
  return( $ENV{PROXY} || 'haproxy' );
}

# Restores a complete DB from JSON string
sub dbFromJSON
{
  my ($db, $json) = @_;
  return(0) if ! $json;

  eval {
    $db = decode_json( $json );
  };
  if ($@)
  {
    error("dbFromJSON parsing JSON: $@");
    return(0);
  }
  $_[0] = $db;
  return(1);
}

# Dumps complete DB into JSON string
sub dbToJSON
{
  my ($db) = @_;
  return('') if ! $db;

  my $json;
  eval {
    $json = encode_json($db);
  };
  if ($@)
  {
    error("dbToJSON encoding JSON: $@");
    return('');
  }
  return($json);
}

# Return a reference to a hash of load balancer information
# Example:
# $ip = $ref->{"name"}->{"default"}[0]
sub loadBalancersToHash
{
  my ($db) = @_;
  return(undef) if ! $db;

  foreach my $lb ( keys(%{$db->{loadBalancers}}) )
  {
    foreach my $p ( keys(%{$db->{globals}->{pools}}) )
    {
      $db->{loadBalancers}->{$lb}->{$p} = ipByLoadBalancer($db, $lb, $p); 
    }
  }
  my $hash = $db->{loadBalancers};
  return( $hash );
}

# Merge load balancer information from JSON string into DB
# Returns 0 if no change in DB
# Returns 1 if DB is changed
sub loadBalancersFromJSON
{
  my ($db, $json) = @_;
  return(0) if ! $json;

  my $changed = 0;
  my $nodesHash;
  eval {
    $nodesHash = decode_json($json);
  };
  error("loadBalancersFromJSON parsing json $@") if $@;
  # lb removed?
  foreach my $node ( keys( %{$db->{loadBalancers}} ) )
  {
    my $found = 0;
    foreach my $n (@{$nodesHash->{items}})
    {
      if ($n->{metadata}->{name} eq $node)
      {
        $found = 1;
      }
    }
    if (! $found)
    {
      info("load balancer $node removed");
      delete $db->{loadBalancers}->{$node};
      $changed = 1;
    }
  }
  my $count = 0;
  # lb added?
  foreach my $node (@{$nodesHash->{items}})
  {
    my $name = $node->{metadata}->{name};
    if ( ! $db->{loadBalancers}->{$name} )
    {
      info("loadbalancer $name added");
      $db->{loadBalancers}->{$name} = {};
      $changed = 1;
    } 
    $count++;
  } 
  if (! $count)
  {
    error("No load balancer nodes found, be sure to taint load balancer nodes");
  } else {
#TODO rebalance IPs if changed
  }
  if ($changed)
  {
    $_[0] = $db;
    return(1); 
  } else {
    return(0);
  } 
}

sub globalsToHash
{
  my ($db) = @_;
  return(undef) if ! $db;

  my $hash = $db->{globals};
  return($hash);
}

# Merge load balancer information from JSON string into DB
# Returns 0 if no change in DB
# Returns 1 if DB is changed
sub globalsFromJSON
{
  my ($db, $json) = @_;
  return(0) if ! $json;

  my $changed = 0;
  my $globalHash;
  eval {
    $globalHash = decode_json($json);
  };
  error("globalsFromJSON parsing json $@") if $@;
  if ( ! genericCompare($db->{globals}->{keepalived}, $globalHash->{keepalived}) )
  {
    info("keepalived globals changed");
    $db->{globals}->{keepalived} = $globalHash->{keepalived};
    $changed = 1;
  }
  my $proxy = proxyType();
  if ($proxy eq 'haproxy')
  {
    if ( ! genericCompare($db->{globals}->{haproxy}, $globalHash->{haproxy}) )
    {
      info("haproxy globals changed");
      $db->{globals}->{haproxy} = $globalHash->{haproxy};
      $changed = 1;
    }
  }
  if ($proxy eq 'nginx')
  {
    if ( ! genericCompare($db->{globals}->{nginx}, $globalHash->{nginx}) )
    {
      info("nginx globals changed");
      $db->{globals}->{nginx} = $globalHash->{nginx};
      $changed = 1;
    } 
  }
  my $poolHash = $globalHash->{pools};
  if (ref($poolHash) ne 'HASH') 
  {
    error("poolFromJSON pools misconfigured");
    debug(Dumper $poolHash);
    return(0);
  }
  # pool removed?
  foreach my $pool ( keys(%{$db->{globals}->{pools}} ) )
  {
    my $found = 0;
    foreach my $p ( keys(%{$poolHash}) )
    {
      if ($p eq $pool)
      {
        $found = 1;
      }
    }
    if (! $found)
    {
      info("pool $pool removed");
      delete $db->{globals}->{pools}->{$pool};
      $changed = 1;
#TODO unassign pool IPs
    }
  }
  # pool added/changed?
  foreach my $pool ( keys(%{$poolHash}) )
  {
    my $found = 0;
    foreach my $p ( keys(%{$db->{globals}->{pools}}) )
    {
      if ($p eq $pool)
      {
        $found = 1;
        if ( ref($poolHash->{$pool}) ne 'HASH' )
        {
          error("poolFromJSON pool $pool misconfigured");
          debug(Dumper $poolHash->{$pool});
        } else {
          if ($db->{globals}->{pools}->{$pool}->{network} ne $poolHash->{$pool}->{network})
          {
            info("Pool $pool network changed");
            $db->{globals}->{pools}->{$pool}->{network} = $poolHash->{$pool}->{network};
#TODO check IPs
          }
          if ($db->{globals}->{pools}->{$pool}->{range} ne $poolHash->{$pool}->{range})
          {
            info("Pool $pool range changed");
            $db->{globals}->{pools}->{$pool}->{range} = $poolHash->{$pool}->{range};
#TODO check IPs
          }
          if ($db->{globals}->{pools}->{$pool}->{interface} ne $poolHash->{$pool}->{interface})
          {
            info("Pool $pool interface changed");
            $db->{globals}->{pools}->{$pool}->{interface} = $poolHash->{$pool}->{interface};
            $changed = 1;
          }
        }
      }
    }
    if (! $found)
    {
      info("New pool $pool found");
      if ( ref($poolHash->{$pool}) eq 'HASH' )
      {
        $db->{globals}->{pools}->{$pool} = $poolHash->{$pool};
        $changed = 1;
      } else {
        error("Pool $pool misconfigured");
        debug(Dumper $poolHash->{$pool});
      }
    }
  }
  if ($changed)
  {
    $_[0] = $db;
    return(1);       
  } else {
    return(0);
  }
}

sub servicesToHash
{
  my ($db) = @_;
  return(undef) if ! $db;
  my $hash = $db->{services};
  foreach my $s ( keys(%{$hash}) )
  {
#TODO Support for multiple IPs
    $hash->{$s}->{status} = ipByService($db, $s);
  }
  return($hash);
}

# Merge load balancer information from JSON string into DB
# Returns 0 if no change in DB
# Returns 1 if DB is changed
sub servicesFromJSON
{
  my ($db, $json) = @_;
  return(0) if ! $json;

  my $changed = 0;
  my $servicesHash;
  eval {
    $servicesHash = decode_json($json);
  };
  error("servicesFromJSON parsing json $@") if $@;
  # service removed/changed?
  foreach my $service ( keys(%{$db->{services}} ) )
  {
    my $found = 0;
    foreach my $s ( @{$servicesHash->{items}} )
    {
      if ("$s->{metadata}->{namespace}_$s->{metadata}->{name}" eq $service)
      {
        $found = 1;

        my $serv = serviceConvert($s);

        if ( ! genericCompare($db->{services}->{$service}->{options}, $serv->{options}) )
        {
          $db->{services}->{$service}->{options} = $serv->{options};
          info("Service $service options changed");
          $changed = 1;
        }
        if ($db->{services}->{$service}->{selector} ne $serv->{selector})
        {
          info("Service $service selector changed");
          $db->{services}->{$service}->{selector} = $serv->{selector};
          $changed = 1;
        }
        if ($db->{services}->{$service}->{pool} ne $serv->{pool})
        {
          info("Service $service pool changed");
          $changed = 1 if ipUnassign($db, $service);
          $db->{services}->{$service}->{pool} = $serv->{pool};
          $changed = 1 if ipAssign($db, $service);
        }
        if ($db->{services}->{$service}->{requestIP} ne $serv->{requestIP})
        {
          info("Service $service requested IP changed");
          $changed = 1 if ipUnassign($db, $service);
          $db->{services}->{$service}->{requestIP} = $serv->{requestIP};
          $changed = 1 if ipAssign($db, $service);
        }
        foreach my $port ( @{$db->{services}->{$service}->{ports}} )
        {
          $port->{port} = "$port->{port}";
          $port->{targetPort} = "$port->{targetPort}";
        }
        if ( ! genericCompare($db->{services}->{$service}->{ports}, $serv->{ports}) )
        {
          $db->{services}->{$service}->{ports} = $serv->{ports};
          info("Service $service ports changed");
          $changed = 1 if ipAssign($db, $service);
        }
        if ( ! ipByService($db, $service) )
        {
          $changed = 1 if ipAssign($db, $service);
        }
        last;
      }
    }
    if (! $found)
    {
      info("service $service removed");
      ipUnassign($db, $service, 1);
      delete $db->{services}->{$service};
      $changed = 1;
    }
  }
  # service added?
  foreach my $service ( @{$servicesHash->{items}} )
  {
    my $found = 0;
    if ($service->{spec}->{type} eq 'LoadBalancer')
    {
      foreach my $s ( keys(%{$db->{services}}) )
      {
        if ($s eq "$service->{metadata}->{namespace}_$service->{metadata}->{name}")
        {
          $found = 1;
          last;
        }
      }
      if (! $found)
      {
        info("New service $service->{metadata}->{name} found");
        $db->{services}->{"$service->{metadata}->{namespace}_$service->{metadata}->{name}"} = serviceConvert($service);
        ipAssign($db,"$service->{metadata}->{namespace}_$service->{metadata}->{name}");
        $changed = 1;
      }
    }
  }
  if ($changed)
  {
    #debug Dumper $db;
    $_[0] = $db;
    return(1);       
  } else {
    return(0);
  }
}

sub podsFromJSON
{
  my ($db, $service, $json) = @_;
  my $serviceHash = $db->{services}->{$service};
  if (ref($serviceHash) eq 'HASH')
  {
    my $podHash;
    eval {
      $podHash = decode_json($json);
    };
    if ($@)
    {
      error("podsFromJSON parsing JSON: $@");
      return(0);
    }
    my $changed = 0;
    foreach my $old ( keys(%{$serviceHash->{pods}}) )
    {
      my $found = 0;
      foreach my $new (@{$podHash->{items}})
      {
        if ($old eq $new->{metadata}->{name})
        {
          $found = 1;
          if ($serviceHash->{pods}->{$old} ne $new->{status}->{podIP})
          {
            # this will probably never happen?
            info("Pod $old IP changed for service $service");
            $db->{services}->{$service}->{pods}->{$old} = $new->{status}->{podIP};
            $changed = 1;
          }
          last;
        }
      }
      if (! $found)
      {
        info("Pod $old removed from service $service");
        delete $db->{services}->{$service}->{pods}->{$old};
        $changed = 1;
      }  
    }
    foreach my $new (@{$podHash->{items}})
    {
      my $found = 0;
      foreach my $old ( keys(%{$serviceHash->{pods}}) )
      {
        if ($old eq $new->{metadata}->{name})
        {
          $found = 1;
          last;
        }
      }
      if (! $found)
      {
        my $name = $new->{metadata}->{name};
        info("Pod $name added to service $service");
        $db->{services}->{$service}->{pods}->{$name} = $new->{status}->{podIP};
        $changed = 1;
      }
    } 
    if ($changed)
    {
      $_[0] = $db;
      return(1);
    } else {
      return(0);
    }
  } else {
    error("podsFromJSON service $service not found");
  }
}

# Takes hash from service JSON and converts to locally used hash
sub serviceConvert
{
  my ($service) = @_;
  my %hash;
  $hash{nameSpace} = $service->{metadata}->{namespace};
  $hash{name} = $service->{metadata}->{name};
  if ($service->{metadata}->{annotations}->{"loadbalancer/pool"})
  {
    $hash{pool} = $service->{metadata}->{annotations}->{"loadbalancer/pool"};
  } else {
    $hash{pool} = 'default';
  }
  foreach my $anno ( keys(%{$service->{metadata}->{annotations}}) )
  {
    if ( lc(substr($anno,0,12)) eq 'loadbalancer')
    {
      my ($lb,$option) = split('/', $anno);
      $option = lc($option);
      $hash{options}->{$option} = $service->{metadata}->{annotations}->{$anno};
    }
  }
  if ($service->{spec}->{loadBalancerIP})
  {
    $hash{requestIP} = $service->{spec}->{loadBalancerIP};
  }
  my $selector = '';
  if ($service->{spec}->{selector})
  {
    my @selector;
    foreach my $sel ( sort(keys(%{$service->{spec}->{selector}})) )
    {
      $selector[$#selector + 1] = "$sel=$service->{spec}->{selector}->{$sel}";
    }
    $selector = join(',', @selector);
  }
  $hash{selector} = $selector;
  my @ports;
  foreach my $port ( @{$service->{spec}->{ports}} )
  {
    my %portHash;
    $portHash{protocol} = "$port->{protocol}";
    $portHash{targetPort} = "$port->{targetPort}";
    $portHash{port} = "$port->{port}";
    $portHash{name} = "$port->{name}";
    push(@ports, \%portHash);
  }
  $hash{ports} = \@ports;
  return( \%hash );
}

# returns the IP assigned to service
sub ipByService
{
  my ($db, $service) = @_;
  return '' if ! $service;
  foreach my $ip ( keys(%{$db->{ips}}) )
  {
    foreach my $p ( @{$db->{ips}->{$ip}->{ports}} )
    {
      if ($p->{service} eq $service)
      {
        return($ip);
      } 
    }
  } 
  return('');
}

# returns the IP assigned to load balancer/pool
sub ipByLoadbalancer
{
  my ($db, $lb, $pool) = @_;
  return '' if ! $lb;
  return '' if ! $pool;
  my @ips;
  foreach my $ip ( keys(%{$db->{ips}}) )
  {
    if ($lb eq $db->{ips}->{$ip}->{loadBalancer} && $pool eq $db->{ips}->{$ip}->{pool})
    {
      push(@ips, $ip);
    } 
  }
  return(\@ips);
}


# returns an array of IPs assigned to loadBalancer
sub ipByLoadBalancer
{
  my ($db, $lb, $pool) = @_;
  my @results;
  return \@results if ! $lb;
  foreach my $ip ( keys(%{$db->{ips}}) )
  {
    if (($db->{ips}->{$ip}->{loadBalancer} eq $lb) && ($db->{ips}->{$ip}->{pool} eq $pool))
    {
      push(@results, $ip);
    }
  } 
  return(\@results);
}


# Might have to optimize this to handle very large DBs
sub lowestLoadBalancer
{
  my ($db, $pool) = @_;

  my $lowest = 1024;
  my $result = '';
  my $lbHash = $db->{loadBalancers};
  if ( ref($lbHash) eq 'HASH' )
  {
    foreach my $lb ( keys(%{$lbHash}) )
    {
      my $count = scalar @{ipByLoadBalancer($db, $lb, $pool)};
      if ($count < $lowest)
      {
        $result = $lb;
        $lowest = $count;
      }
    }
  } else {
    error("No loadbalancers found");
    return($result);
  }
  return($result);
}

sub ipInRange
{
  my ($ip, $range) = @_;
  return 0 if ! $range;

  my $ipLeft = new Net::IP($ip);
  my $ipRight = new Net::IP($range);
  return 0 if (! $ipLeft || ! $ipRight);
  if ($ipLeft->overlaps($ipRight) == $IP_A_IN_B_OVERLAP)
  {
    return(1);
  } else {
    return(0);
  }
}

# Might have to optimize this to handle very large IP pools
sub nextIP
{
  my ($db, $pool) = @_;
  return 0 if ! $pool;

  my $poolHash = $db->{globals}->{pools}->{$pool};
  if ( ref($poolHash) eq 'HASH' )
  {
    if (ipVersion($poolHash->{range}) == 6)
    {
      my $poolObj = new Net::IP($poolHash->{range});
      my $count = 0;
      while ($count < 128)
      {
        $poolObj += int(rand($poolObj->size()));
        my $ip = $poolObj->ip();
        if (! $db->{ips}->{$ip})
        {
          return($ip);
        }
        $count++; 
      }
      error("Out of dynamic IPs for pool $pool");
      return(0);
    } else {
      my $ipObj = new Net::IP($poolHash->{range});
      if ($ipObj)
      {
        while (++$ipObj)
        {
          my $ip = $ipObj->ip();
          if ( ! defined($db->{ips}->{$ip}) )
          {
            return($ip);
          }  
        }
        warning("Out of dynamic IPs for pool $pool");
        return(0);
      } else {
        error("Problem with pool $pool IP range");
        return(0);
      }
    }
  } else {
    error("nextIP pool $pool doesn't exist");
  }
  return(0);
}

sub ipAssign 
{
  my ($db, $service) = @_;
  my $serviceHash = $db->{services}->{$service};
  if (ref($serviceHash) eq 'HASH')
  {
    my $poolHash = $db->{globals}->{pools}->{$serviceHash->{pool}};
    if (ref($poolHash) eq 'HASH')
    {
      my $ip = ipByService($db, $service);
      if ($ip)
      {
        info("Service $service already has an IP, updating ports");

        my $count = 0;
        foreach my $p ( @{$db->{ips}->{$ip}->{ports}} )
        {
          if ($p->{service} eq $service)
          {
            delete($db->{ips}->{$ip}->{ports}->[$count]);
          }
          $count++;
        }
      } else {
        $ip = $serviceHash->{requestIP};
      }
      if (! $ip)
      {
        $ip = nextIP($db, $serviceHash->{pool});
        info("Assigning dynamic IP $ip to service $service");
      }
      if ($ip)
      {
        if (ipInRange($ip, $poolHash->{network}))
        {
          info("Assigning IP $ip to service $service");
          if ($db->{ips}->{$ip})
          {
            foreach my $port ( @{$serviceHash->{ports}} )
            {
              foreach my $p ( @{$db->{ips}->{$ip}->{ports}} )
              {
                if ($port->{protocol} eq $p->{protocol} && $port->{port} eq $p->{port})
                {
                  error("Can't assign $ip/$port to $service, already assigned to $p->{service}");
                  return(0);
                }
              }
              my $newPort = { %$port };
              $newPort->{port} = "$newPort->{port}";
              $newPort->{service} = $service;
              push(@{$db->{ips}->{$ip}->{ports}}, $newPort);
            }
          } else {
            my %hash;
            my @ports;
            my $count = 0;
            foreach my $port ( @{$serviceHash->{ports}} )
            {
              my $newPort = { %$port };
              $newPort->{port} = "$newPort->{port}";
              $newPort->{service} = $service;
              push(@ports, $newPort);
            }
            $hash{ports} = \@ports;
            $hash{loadBalancer} = lowestLoadBalancer($db, $serviceHash->{pool});
            $hash{pool} = $serviceHash->{pool};
            $db->{ips}->{$ip} = \%hash;
          }
          @_[0] = $db;
          patchService($serviceHash->{nameSpace}, $serviceHash->{name}, $ip); 
          serviceEndpoint($serviceHash->{nameSpace}, $serviceHash->{name}, $ip, $serviceHash->{ports});
          return(1);
        } else {
          error("IP $ip not valid for $serviceHash->{pool}");
        }
      } else {
        error("Failed to assign IP to $service");
        return(0);
      }
    } else {
      error("Pool $serviceHash->{pool} doesn't exist");
      return(0);
    }
  } else {
    error("Service $service doesn't exist");
    return(0);
  }
  return(0);
}
 
sub ipUnassign
{
  my ($db, $service, $nopatch) = @_;
  info("Unassign IP from service $service");
  my $ip = ipByService($db, $service);
  if ($ip)
  {
    delete $db->{ips}->{$ip};
    @_[0] = $db;
    if (! $nopatch)
    {
      patchService($db->{services}->{$service}->{nameSpace}, $db->{services}->{$service}->{name}, ''); 
    }
    return(1);
  } else {
    info("$service doesn't appear to have an IP");
  }
  return(0);
}

# Return array reference to a list of INPUT iptables rules
sub iptablesRules
{
  my ($db) = @_;
  my @rules;
  foreach my $ip ( keys(%{$db->{ips}}) )
  {
    next if (ipVersion($ip) != 4);
    foreach my $port ( @{$db->{ips}->{$ip}->{ports}} )
    {
#TODO add support for restricting source address
      if ( lc($port->{protocol}) eq 'udp' )
      {
        push(@rules, "INPUT -d $ip/32 -p udp -m udp --dport $port->{port} -m comment --comment k8slb-system -j ACCEPT");
      } else {
        push(@rules, "INPUT -d $ip/32 -p tcp -m tcp --dport $port->{port} -m comment --comment k8slb-system -j ACCEPT");
      }  
    }
  }
  return(\@rules);
}

# Return array reference to a list of INPUT iptables rules
sub ip6tablesRules
{
  my ($db) = @_;
  my @rules;
  foreach my $ip ( keys(%{$db->{ips}}) )
  {
    next if (ipVersion($ip) != 6);
    foreach my $port ( @{$db->{ips}->{$ip}->{ports}} )
    {
#TODO add support for restricting source address
      if ( lc($port->{protocol}) eq 'udp' )
      {
        push(@rules, "INPUT -d $ip/128 -p udp -m udp --dport $port->{port} -m comment --comment k8slb-system -j ACCEPT");
      } else {
        push(@rules, "INPUT -d $ip/128 -p tcp -m tcp --dport $port->{port} -m comment --comment k8slb-system -j ACCEPT");
      }
    }
  }
  return(\@rules);
}


sub ipVersion
{
  my ($ip) = @_;
  $ip =~ s/(\/|-).*//;
  return ip_get_version($ip);
}

# Generically compare two data structures of any type
sub genericCompare
{
  my ($left, $right) = @_;

  $Data::Dumper::Sortkeys = 1;
  my $lj = Dumper($left);
  my $rj = Dumper($right);
  return( $lj eq $rj );
}

# Try to automatically determine device from IP address
sub devFromIP
{
  my ($ip) = @_;
  $ip =~ s/(\/|-).*//;
  return(undef) if ! $ip;
  my $interfaces = '';
  if (ipVersion($ip) == 6)
  {
    $interfaces = `ip -6 route list`;
  } else {
    $interfaces = `ip route list`;
  }
  foreach my $i (split("\n", $interfaces))
  {
    my @result = split(' ', $i);
    my $range = $result[0];
    if (ipInRange($ip, $range) )
    {
      if ( $i =~ / dev (.+?) / )
      {
        info("Determined device $1 for ip $ip");
        return($1);
      }
    }
  }
}

1;
__END__
  
=head1 NAME
  
k8slb_db - k8slb database library
  
=head1 SYNOPSIS
  
Handles storing and retrieving Load balancers, Pools, and IPs for k8slb

=head1 DESCRIPTION
  
=head1 REQUIRES
Net::IP
Data::Dumper

=head1 AUTHOR
Chris Arnold <carnold@vt.edu>
  
=cut
  

