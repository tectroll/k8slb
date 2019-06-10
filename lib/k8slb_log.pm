package k8slb_log;

BEGIN {
    use 5.004;
    use Exporter();
    use vars qw($VERSION @ISA @EXPORT %logConfig);
    $VERSION = "0.1";
    @ISA = qw(Exporter);
    @EXPORT = qw(
                            &logLevel
                            &debug
                            &info
                            &warning
                            &error
                            &doLog
                            DEBUG
                            INFO
                            WARNING
                            ERROR
                            NONE
    );
}

use strict;
use k8slb_api;

use constant {
  NONE => 0,
  ERROR => 1,
  WARNING => 2,
  INFO => 3,
  DEBUG => 4
};

%logConfig = (
  logLevel => INFO,
  backoffTime => 5,  # number of seconds to backoff from error logging
  backoffMaxTime => 3600,
);

my %errorHistory = ();
my %warningHistory = ();

sub logLevel
{
  my ($level) = @_;
  $logConfig{logLevel} = $level;
}

sub debug
{
  my ($msg) = @_;
  if ( $logConfig{logLevel} >= DEBUG )
  {
    doLog("DEBUG: $msg");
  }
}

sub info
{
  my ($msg, $service) = @_;
  if ( $logConfig{logLevel} >= INFO )
  {
    doLog("INFO: $msg");
    if (isConnected())
    {
      if ($service)
      {
        writeServiceEvent($service, "Normal", "INFO", $msg);
      } else {
        writePodEvent(getMyself(), "Normal", "INFO", $msg);
      }
    }
  }
}

sub warning
{
  my ($msg, $service) = @_;
  if ( $logConfig{logLevel} >= WARNING )
  {
    my $waitTime = $logConfig{backoffTime} * $warningHistory{$msg}->{logCount};
    if ( (time - $warningHistory{$msg}->{lastLog}) > ($logConfig{backoffMaxTime} * 2) )
    {
      $warningHistory{$msg}->{logCount} = 0;
    }
    if ($waitTime > $logConfig{backoffMaxTime})
    {
      $waitTime = $logConfig{backoffMaxTime};
    }
    if ( (time - $warningHistory{$msg}->{lastLog}) >= $waitTime )
    {
      $warningHistory{$msg}->{lastLog} = time;
      $warningHistory{$msg}->{logCount} += 1;
      if ($warningHistory{$msg}->{failCount} > 2)
      {
        $msg .= " (repeated $warningHistory{$msg}->{failCount} times)";
      }
      doLog("WARNING: $msg");
      if (isConnected())
      {
        if ($service)
        {
          writeServiceEvent($service, "Warning", "WARNING", $msg);
        } else {
          writePodEvent(getMyself(), "Warning", "WARNING", $msg);
        }
      }
    }
    $warningHistory{$msg}->{failCount} += 1;
    $warningHistory{$msg}->{lastFail} = time;
  }
}

sub error
{
  my ($msg, $service) = @_;
  if ( $logConfig{logLevel} >= ERROR )
  {
    my $waitTime = $logConfig{backoffTime} * $errorHistory{$msg}->{logCount};
    if ( (time - $errorHistory{$msg}->{lastLog}) > ($logConfig{backoffMaxTime} * 2) )
    {
      $errorHistory{$msg}->{logCount} = 0;
    }
    if ($waitTime > $logConfig{backoffMaxTime})
    {
      $waitTime = $logConfig{backoffMaxTime};
    }
    if ( (time - $errorHistory{$msg}->{lastLog}) >= $waitTime )
    {
      $errorHistory{$msg}->{lastLog} = time;
      $errorHistory{$msg}->{logCount} += 1;
      if ($errorHistory{$msg}->{failCount} > 2)
      {
        $msg .= " (repeated $errorHistory{$msg}->{failCount} times)";
      }
      doLog("ERROR: $msg");
      if (isConnected())
      {
        if ($service)
        {
          writeServiceEvent($service, "Warning", "ERROR", $msg);
        } else {
          writePodEvent(getMyself(), "Warning", "ERROR", $msg);
        } 
      }
    }
    $errorHistory{$msg}->{failCount} += 1;
    $errorHistory{$msg}->{lastFail} = time;
  }
}

sub doLog
{
  my ($msg) = @_;
  print("$msg\n");
  $|++;
#  system("echo \"$msg\"");
}

1;
__END__
  
=head1 NAME
  
k8slb_log - k8slb Logging library
  
=head1 SYNOPSIS
  
Handles logging and debuging

=head1 DESCRIPTION
  
=head1 REQUIRES

=head1 AUTHOR
Chris Arnold <carnold@vt.edu>
  
=cut
  

