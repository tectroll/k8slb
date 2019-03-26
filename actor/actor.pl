#!/usr/bin/perl

#TODO: 
# Get certs from k8s secrets

use strict;
use Data::Dumper;

use lib 'lib';
use k8slb_log;
use k8slb_api;
use k8slb_db;

my %actorConfig = (
  logLevel		=> $ENV{LOG_LEVEL} || INFO,
  proxy			=> proxyType(),

  kaCurrent		=> "/etc/keepalived/keepalived.conf",
  kaCmd			=> "/usr/sbin/keepalived",
  kaOptions		=> $ENV{KA_OPTIONS} || "-P -D -l",
  kaWait		=> $ENV{KA_WAIT} || 10,
  kaPID			=> "/var/run/keepalived/keepalived.pid",
  kaReload		=> "HUP",
  kaStop		=> "TERM",

  hpCurrent             => "/etc/haproxy/haproxy.cfg",
  hpCmd                 => "/usr/sbin/haproxy",
  hpOptions             => $ENV{HP_OPTIONS} || "-f /etc/haproxy/haproxy.cfg -p /run/haproxy.pid -sf \$(cat /run/haproxy.pid)",
  hpWait                => $ENV{HP_WAIT} || 1,
  hpPID                 => "/run/haproxy.pid",

  nxCurrent		=> "/etc/nginx/nginx.conf",
  nxCmd			=> "/usr/sbin/nginx",
  nxOptions		=> $ENV{NX_OPTIONS} || "-c /etc/nginx/nginx.conf",
  nxWait		=> $ENV{NX_WAIT} || 1,
  nxTest		=> "/usr/sbin/nginx -c /etc/nginx/nginx.conf -t",
  nxPID			=> "/var/run/nginx.pid",
  nxReload		=> "HUP",
  nxStop		=> "TERM",
 
  iptablesSkip		=> $ENV{NO_IPTABLES} || 0,
  iptablesCmd		=> $ENV{IPTABLES_CMD} || "/sbin/iptables",
  ip6tablesCmd		=> $ENV{IP6TABLES_CMD} || "/sbin/ip6tables",

  backupDir 		=> $ENV{BACKUP_DIR} || "/tmp",
  archiveBackups	=> $ENV{BACKUP_ENABLE} || 1,
  cpCmd			=> "/bin/cp -f",
  maxLB			=> $ENV{MAX_LOADBALANCERS} || 9,
  loopDelay		=> $ENV{LOOP_DELAY} || 10,
);

logLevel($actorConfig{logLevel});

# Globals
my $kaEpoch = '';
my $hpEpoch = '';
my $nxEpoch = '';
my $hostname = getHostname();

# Set kernel variables
system("/sbin/sysctl net.ipv4.ip_nonlocal_bind=1");
system("/sbin/sysctl net.ipv6.ip_nonlocal_bind=1");

while (1)
{
  debug("Checking for update...");
  kaUpdate();
  if ($actorConfig{proxy} eq 'nginx')
  {
    nxUpdate();
  } elsif ($actorConfig{proxy} eq 'haproxy') {
    hpUpdate();
  }
  sleep($actorConfig{loopDelay});
}

sub getHostname
{
  if ($ENV{K8SLB_NODE_NAME})
  {
    return($ENV{K8SLB_NODE_NAME});
  }
  if ($ENV{HOSTNAME})
  {
    return($ENV{HOSTNAME});
  }
  my $hostname = `hostname`;
  chomp($hostname);
  return($hostname);
}

sub kaUpdate
{
  my $kaNew = readEpoch('keepalived');
  if ($kaEpoch ne $kaNew)
  {
    info("New keepalived config found");
    kaBackup($kaEpoch, $kaNew);
    $kaEpoch = $kaNew;
    $kaNew = readConfig('keepalived');
    my $db;
    dbFromJSON($db, readConfig('working'));
    my $globalsHash = globalsToHash($db);
    foreach my $pool ( keys(%{$globalsHash->{pools}}) )
    {
      my $dev = devFromIP($globalsHash->{pools}->{"$pool"}->{network});
      debug("Determined device $dev for pool $pool");
      my $p = uc($pool);
      $kaNew =~ s/\{\{ INT$p \}\}/$dev/g;
    }
    $kaNew =~ s/\{\{ HOSTNAME \}\}/$hostname/g;
    my @loadBalancers = sort( keys(%{loadBalancersToHash($db)}) );
    foreach my $l (1..$actorConfig{maxLB})
    {
      my $priority = $ENV{"PRIORITY$l"} || 50;
      if ($loadBalancers[$l-1] eq $hostname)
      {
        $priority = 100;
      }
      $kaNew =~ s/\{\{ PRIORITY$l \}\}/$priority/g;
    }
#  debug Dumper $kaNew;
    if ( open(KA, "> $actorConfig{kaCurrent}") )
    {
      print KA $kaNew;
      close(KA);
      my $pid = kaCheck();
      if ($pid > 0)
      {
        info("Keepalived appears to be running $pid, reloading");
        kill($actorConfig{kaReload}, $pid);
        kaWait();
        my $newpid = kaCheck();
        if ($newpid)
        {
          info("Reload of keepalived appears successful");
        } else {
          error("Keepalived did not reload successfully, reverting to old config");
          kaRestore($kaNew);
        }
      } else {
        warning("Keepalived does not appear to be running, starting");
        kaStart();
        kaWait();
        my $newpid = kaCheck();
        if ($newpid)
        {
          info("Start of keepalived appears successful $newpid");
        } else {
          error("Keepalived did not start successfully, reverting to old config");
          kaRestore($kaNew);
        }
      }
    } else {
      error("Can't write to keepalived config $actorConfig{kaCurrent} $@");
    }
  } else {
    debug("No change to keepalived");
  }
}

# Make a backup of the currently running keepalived config
sub kaBackup
{
  my ($old, $epoch) = @_;
  
  if (! $actorConfig{archiveBackups})
  {
    system("rm -f \"$actorConfig{backupDir}/keepalive.$old\"");
  }

  system("$actorConfig{cpCmd} $actorConfig{kaCurrent} \"$actorConfig{backupDir}/keepalive.$epoch\"");
}

sub kaRestore
{
  my ($epoch) = @_;
  if (-e "$actorConfig{backupDir}/keepalive.$epoch")
  {
    system("$actorConfig{cpCmd} \"$actorConfig{backupDir}/keepalive.$epoch\" $actorConfig{kaCurrent}");
  } else {
    error("Error restoring keepalived config, file does not exist");
  }
  kaStart();
  kaWait();
  my $pid = kaCheck();
  if ($pid)
  {
    info("Restore of keepalived config appears successful");
  } else {
    error("Restore of keepalived config failed, aborting");
  }
}

sub kaWait
{
  info("Waiting $actorConfig{kaWait} seconds for keepalived to settle...");
  sleep($actorConfig{kaWait});
}

sub kaCheck
{
  if ( -e $actorConfig{kaPID} )
  {
    my $pid = `cat $actorConfig{kaPID}`;
    chomp($pid);
    if (-e "/proc/$pid")
    {
      return($pid);
    } else {
      return(0);
    }
  }
  return(0);
}
   
sub kaStart
{
  system("$actorConfig{kaCmd} $actorConfig{kaOptions}");
}

sub hpUpdate
{
  my $hpNew = readEpoch('haproxy');
  if ($hpEpoch ne $hpNew)
  {
    info("New haproxy config found");
    hpBackup($hpEpoch, $hpNew);
    $hpEpoch = $hpNew;
    $hpNew = readConfig('haproxy');
#debug Dumper $hpNew;
    if ( open(HP, "> $actorConfig{hpCurrent}") )
    {
      print HP $hpNew;
      close(HP);
      my $pid = hpCheck();
      if ($pid > 0)
      {
        info("HAProxy appears to be running $pid, reloading");
        hpStart();
        hpWait();
        my $newpid = hpCheck();
        if ($newpid)
        {
          info("Reload of HAProxy appears successful");
        } else {
          error("HAProxy did not reload successfully, reverting to old config");
          hpRestore($hpNew);
        }
      } else {
        warning("HAProxy does not appear to be running, starting");
        hpStart();
        hpWait();
        my $newpid = hpCheck();
        if ($newpid)
        {
          info("Start of HAProxy appears successful $newpid");
        } else {
          error("HAProxy did not start successfully, reverting to old config");
          hpRestore($hpNew);
        }
      }
      iptablesUpdate();
    } else {
      error("Can't write to HAProxy config $actorConfig{hpCurrent} $@");
    }
  } else {
    debug("No change to HAProxy");
  }
}

# Make a backup of the currently running haproxy config
sub hpBackup
{
  my ($old, $epoch) = @_;
 
  if (! $actorConfig{archiveBackups})
  {
    system("rm -f \"$actorConfig{backupDir}/haproxy.$old\"");
  }

  system("$actorConfig{cpCmd} $actorConfig{hpCurrent} \"$actorConfig{backupDir}/haproxy.$epoch\"");
}

sub hpRestore
{
  my ($epoch) = @_;
  if (-e "$actorConfig{backupDir}/haproxy.$epoch")
  {
    system("$actorConfig{cpCmd} \"$actorConfig{backupDir}/haproxy.$epoch\" $actorConfig{hpCurrent}");
  } else {
    error("Error restoring haproxy config, file does not exist");
  }
  hpStart();
  hpWait();
  my $pid = hpCheck();
  if ($pid)
  {
    info("Restore of HAProxy config appears successful");
  } else {
    error("Restore of HAProxy config failed, aborting");
  }
}

sub hpWait
{
  info("Waiting $actorConfig{hpWait} seconds for haproxy to settle...");
  sleep($actorConfig{hpWait});
}

sub hpCheck
{
  if ( -e $actorConfig{hpPID} )
  {
    my $pid = `cat $actorConfig{hpPID}`;
    chomp($pid);
    if (-e "/proc/$pid")
    {
      return($pid);
    } else {
      return(0);
    }
  }
  return(0);
}

sub hpStart
{
  system("$actorConfig{hpCmd} $actorConfig{hpOptions}");
}

sub nxUpdate
{
  my $nxNew = readEpoch('nginx');
  if ($nxEpoch ne $nxNew)
  {
    info("New nginx config found");
    nxBackup($nxEpoch, $nxNew);
    $nxEpoch = $nxNew;
    $nxNew = readConfig('nginx');
#debug Dumper $nxNew;
    if ( open(NX, "> $actorConfig{nxCurrent}") )
    {
      print NX $nxNew;
      close(NX);
      my $pid = nxCheck();
      if ($pid > 0)
      {
        info("Nginx appears to be running $pid, reloading");
        my $rc = system($actorConfig{nxTest});
        if ($rc)
        {
          error("Nginx config failed test $rc, aborting update");
          return('');
        }
        kill($actorConfig{nxReload}, $pid);
        nxWait();
        my $newpid = nxCheck();
        if ($newpid)
        {
          info("Reload of nginx appears successful");
        } else {
          error("nginx did not reload successfully, reverting to old config");
          nxRestore($nxNew);
        }
      } else {
        warning("nginx does not appear to be running, starting");
        nxStart();
        nxWait();
        my $newpid = nxCheck();
        if ($newpid)
        {
          info("Start of nginx appears successful $newpid");
        } else {
          error("nginx did not start successfully, reverting to old config");
          nxRestore($nxNew);
        }
      }
      iptablesUpdate();
    } else {
      error("Can't write to nginx config $actorConfig{nxCurrent} $@");
    }
  } else {
    debug("No change to nginx");
  }
}

# Make a backup of the currently running nginx config
sub nxBackup
{
  my ($old, $epoch) = @_;
 
  if (! $actorConfig{archiveBackups})
  {
    system("rm -f \"$actorConfig{backupDir}/nginx.$old\"");
  }

  system("$actorConfig{cpCmd} $actorConfig{nxCurrent} \"$actorConfig{backupDir}/nginx.$epoch\"");
}

sub nxRestore
{
  my ($epoch) = @_;
  if (-e "$actorConfig{backupDir}/nginx.$epoch")
  {
    system("$actorConfig{cpCmd} \"$actorConfig{backupDir}/nginx.$epoch\" $actorConfig{nxCurrent}");
  } else {
    error("Error restoring nginx config, file does not exist");
  }
  nxStart();
  nxWait();
  my $pid = nxCheck();
  if ($pid)
  {
    info("Restore of nginx config appears successful");
  } else {
    error("Restore of nginx config failed, aborting");
  }
}

sub nxWait
{
  info("Waiting $actorConfig{nxWait} seconds for nginx to settle...");
  sleep($actorConfig{nxWait});
}

sub nxCheck
{
  if ( -e $actorConfig{nxPID} )
  {
    my $pid = `cat $actorConfig{nxPID}`;
    chomp($pid);
    if (-e "/proc/$pid")
    {
      return($pid);
    } else {
      return(0);
    }
  }
  return(0);
}

sub nxStart
{
  system("$actorConfig{nxCmd} $actorConfig{nxOptions}");
}

sub iptablesUpdate
{
  return(0) if ($actorConfig{noIptables});
  my $db;
  dbFromJSON($db, readConfig('working'));
  my $rules = iptablesRules($db);
  iptablesReconcile($rules);
  $rules = ip6tablesRules($db);
  ip6tablesReconcile($rules);
}

sub iptablesReconcile
{
  my ($rules) = @_;
  my $current = `$actorConfig{iptablesCmd} -S INPUT | grep k8slb-system`;
  my @current = split("\n", $current);

  foreach my $nRule ( @{$rules} )
  {
    my $found = 0;
    foreach my $cRule ( @current )
    {
      if (substr($cRule, 3) eq $nRule)
      {
        $found = 1;
      }
    }
    if (! $found)
    {
      info("Adding iptable rule $nRule");
      system("$actorConfig{iptablesCmd} -I $nRule");
    }
  }
  foreach my $cRule ( @current )
  {
    my $found = 0;
    my $rule = substr($cRule, 3);
    foreach my $nRule ( @{$rules} )
    {
      if ($rule eq $nRule)
      {
        $found = 1;
      }
    }
    if (! $found)
    {
      debug("Removing iptable rule $rule");
      system("$actorConfig{iptablesCmd} -D $rule");
    }
  }
}

sub ip6tablesReconcile
{
  my ($rules) = @_;
  my $current = `$actorConfig{ip6tablesCmd} -S INPUT | grep k8slb-system`;
  my @current = split("\n", $current);

  foreach my $nRule ( @{$rules} )
  {
    my $found = 0;
    foreach my $cRule ( @current )
    {
      if (substr($cRule, 3) eq $nRule)
      {
        $found = 1;
      }
    }
    if (! $found)
    {
      info("Adding ip6table rule $nRule");
      system("$actorConfig{ip6tablesCmd} -I $nRule");
    }
  }
  foreach my $cRule ( @current )
  {
    my $found = 0;
    my $rule = substr($cRule, 3);
    foreach my $nRule ( @{$rules} )
    {
      if ($rule eq $nRule)
      {
        $found = 1;
      }
    }
    if (! $found)
    {
      debug("Removing ip6table rule $rule");
      system("$actorConfig{ip6tablesCmd} -D $rule");
    }
  }
}

