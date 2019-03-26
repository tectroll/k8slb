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

use constant {
  NONE => 0,
  ERROR => 1,
  WARNING => 2,
  INFO => 3,
  DEBUG => 4
};

%logConfig = (
  logLevel => INFO,
);

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
  my ($msg) = @_;
  if ( $logConfig{logLevel} >= INFO )
  {
    doLog("INFO: $msg");
  }
}

sub warning
{
  my ($msg) = @_;
  if ( $logConfig{logLevel} >= WARNING )
  {
    doLog("WARNING: $msg");
  } 
}

sub error
{
  my ($msg) = @_;
  if ( $logConfig{logLevel} >= ERROR )
  {
    doLog("ERROR: $msg");
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
  

