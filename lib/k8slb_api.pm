package k8slb_api;

BEGIN {
    use 5.004;
    use Exporter();
    use vars qw($VERSION @ISA @EXPORT %apiConfig);
    $VERSION = "0.1";
    @ISA = qw(Exporter);
    @EXPORT = qw(
             	&readConfig
             	&readEpoch
                &writeConfig
                &readService
                &readServices           
		&readNodes
		&readPod
		&readPods
		&patchService
                &writeServiceEvent
                &writePodEvent
		&serviceEndpoint
		&watcherSpec
		&getMyself
		&isConnected
    );
}

require LWP::UserAgent;
require HTTP::Request;
use Data::Dumper;
use Encode qw(encode_utf8);
use strict;
use JSON;
use k8slb_log;
use k8slb_db;
use Socket;
use DateTime;

# Configuration overrides
%apiConfig = (
  'proto' 	=> '',
  'host'  	=> $ENV{KUBERNETES_SERVICE_HOST},
  'port'  	=> $ENV{KUBERNETES_SERVICE_PORT},
  'base'  	=> '/api/v1',
  'token'	=> '',
  'agent' 	=> 'k8slb-perl/0.10',
  'nameSpace' 	=> 'k8slb-system',
  'caCert'	=> '',
);

my $connected = 0;
my $myself = undef;

# Attempt to auto config api URL
if (-e "/var/run/secrets/kubernetes.io/serviceaccount/token")
{
  # Set to pod service account
  $apiConfig{token} = `cat /var/run/secrets/kubernetes.io/serviceaccount/token`;
  chomp($apiConfig{token});
  $apiConfig{proto} = 'https' if ! $apiConfig{proto};
  $apiConfig{host} = 'kubernetes.default.svc' if ! $apiConfig{host};
  $apiConfig{port} = 443 if ! $apiConfig{port};
#  $apiConfig{caCert} = `cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt`;
#  chomp($apiConfig{caCert});
} else {
  # Set to local kubectl proxy
  $apiConfig{proto} = 'http' if ! $apiConfig{proto};
  $apiConfig{host} = 'localhost' if ! $apiConfig{host};
  $apiConfig{port} = '8001' if ! $apiConfig{port};
}

$apiConfig{apiURL} = "$apiConfig{proto}://$apiConfig{host}:$apiConfig{port}$apiConfig{base}";
info("API URL set to $apiConfig{apiURL}");
$apiConfig{servicesURL} = "$apiConfig{apiURL}/services";
$apiConfig{nodesURL} = "$apiConfig{apiURL}/nodes";
$apiConfig{configURL} = "$apiConfig{apiURL}/namespaces/$apiConfig{nameSpace}/configmaps";

# Return string of configmap of given name
sub readConfig
{
  my ($name) = @_;

  my $ua = apiConnect();
  my $response;
  if ($apiConfig{token})
  {
    $response = $ua->get("$apiConfig{configURL}/$name", Authorization => "Bearer $apiConfig{token}");
  } else {
    $response = $ua->get("$apiConfig{configURL}/$name");
  }
  if ($response->is_success)
  {
    my $data;
    eval {
      $data = decode_json($response->decoded_content);
    };
    if ($@)
    {
      error("readConfig parsing JSON: $@");
      debug($response->decoded_content);
      return('');
    }
    return($data->{data}->{config});
  } else {
    error("reading config: ".$response->message);
    debug($response->decoded_content);
  }
  return('');
}

# Return epoch of configmap of given name
sub readEpoch
{
  my ($name) = @_;

  my $ua = apiConnect();
  my $response;
  if ($apiConfig{token})
  {
    $response = $ua->get("$apiConfig{configURL}/$name", Authorization => "Bearer $apiConfig{token}");
  } else {
    $response = $ua->get("$apiConfig{configURL}/$name");
  }
  if ($response->is_success)
  {
    my $data;
    eval {
      $data = decode_json($response->decoded_content);
    };
    if ($@)
    {
      error("readEpoch parsing JSON: $@");
      debug($response->decoded_content);
      return('');
    }
    return($data->{data}->{epoch});
  } else {
    error("reading config: ".$response->message);
    debug($response->decoded_content);
  }
  return('');
}

# Takes a json string and writes to configmap of given name
# Returns a json string of the new content
sub writeConfig
{
  my ($name, $string) = @_;
  info("Writing config $name");

  my $header;
  if ($apiConfig{token})
  {
    $header = ['Content-Type' => 'application/json', 'Accept' => 'application/json', 'Connection' => 'close', 'Authorization' => "Bearer $apiConfig{token}"];
  } else {
    $header = ['Content-Type' => 'application/json', 'Accept' => 'application/json', 'Connection' => 'close'];
  }
  my $body;
  $body->{kind} = 'ConfigMap';
  $body->{apiVersion} = 'v1';
  $body->{metadata}->{name} = "$name";
  $body->{data}->{config} = $string;
  my $time = time;
  $body->{data}->{epoch} = "$time";
  my $json = encode_json($body);
  my $request = HTTP::Request->new('PUT', "$apiConfig{configURL}/$name", $header, $json);
  my $ua = apiConnect();
  my $response = $ua->request($request);
  if ($response->is_success)
  {
    return( $response->decoded_content );
  } else {
    if ($response->code eq '404')
    {
      my $request = HTTP::Request->new('POST', "$apiConfig{configURL}", $header, $json);
      my $ua = apiConnect();
      my $response = $ua->request($request);
      if ($response->is_success)
      {
        return( $response->decoded_content );
      } else {
        error("Error writing config: ".$response->status_line);
        debug($request->as_string);
        debug($response->decoded_content);
      }
    } else {
      error("Error writing config: ".$response->status_line);
      debug($request->as_string);
      debug($response->decoded_content);
    }
  }
  return('');
} 

# Returns json encoded service information
sub readService
{
  my ($namespace, $service) = @_;
  if (! $namespace || ! $service)
  {
    return('');
  }

  my $url = "$apiConfig{apiURL}/namespaces/$namespace/services/$service";

  my $ua = apiConnect();
  my $response;
  if ($apiConfig{token})
  {
    $response = $ua->get("$url", Authorization => "Bearer $apiConfig{token}");
  } else {
    $response = $ua->get("$url");
  }
  if ($response->is_success)
  {
    return($response->decoded_content);
  } else {
    error("Error reading services: ".$response->status_line);
    debug($response->decoded_content);
  }
  return('');
}

# Returns json encoded service information
sub readServices
{
  my $ua = apiConnect();

  my $response;
  if ($apiConfig{token})
  {
    $response = $ua->get("$apiConfig{servicesURL}", Authorization => "Bearer $apiConfig{token}");
  } else {
    $response = $ua->get("$apiConfig{servicesURL}");
  }
  if ($response->is_success)
  {
    return($response->decoded_content);
  } else {
    error("Error reading services: ".$response->status_line);
    debug($response->decoded_content);
  }
  return('');
}

# Returns json encoded node information
sub readNodes
{
  my ($selector) = @_;
  my $ua = apiConnect();

  my $url = $apiConfig{nodesURL};
  if ($selector)
  {
    my $u = URI->new($url);
    my %form = ();
    $form{labelSelector} = $selector;
    $u->query_form(%form);
    $url = $u->clone;
  }
  my $response;
  if ($apiConfig{token})
  {
    $response = $ua->get($url, Authorization => "Bearer $apiConfig{token}");
  } else {
    $response = $ua->get($url);
  }
  if ($response->is_success)
  {
    return($response->decoded_content);
  } else {
    error("Error reading services: ".$response->status_line);
    debug($response->decoded_content);
  }
  return('');
}

# Returns json encoded pod information
sub readPod
{
  my ($namespace, $pod) = @_;
  if (! $namespace || ! $pod)
  {
    return('');
  }

  my $url = "$apiConfig{apiURL}/namespaces/$namespace/pods/$pod";

  my $ua = apiConnect();
  my $response;
  if ($apiConfig{token})
  {
    $response = $ua->get("$url", Authorization => "Bearer $apiConfig{token}");
  } else {
    $response = $ua->get("$url");
  }
  if ($response->is_success)
  {
    return($response->decoded_content);
  } else {
    error("Error reading pods: ".$response->status_line);
    debug($response->decoded_content);
  }
  return('');
}

# Returns json encoded pod information for given namespace/selector
sub readPods
{
  my ($nameSpace, $selector) = @_;
  my $url = "$apiConfig{apiURL}/namespaces/$nameSpace/pods";
  if ($selector)
  {
    my $u = URI->new($url);
    my %form = ();
    $form{labelSelector} = $selector;
    $u->query_form(%form);
    $url = $u->clone;
  }
  my $ua = apiConnect();
  my $response;
  if ($apiConfig{token})
  {
    $response = $ua->get($url, Authorization => "Bearer $apiConfig{token}");
  } else {
    $response = $ua->get($url);
  }
  if ($response->is_success)
  {
    return($response->decoded_content);
  } else {
    error("Error reading pods: ".$response->status_line);
    debug($response->decoded_content);
  }
  return('');
}

# Patches service status with given IP at given namespace/service, used to notify kube-proxy
sub patchService
{
  my ($nameSpace, $service, $ip) = @_;
  info("Patching service $nameSpace/$service with IP $ip");
  info("Patching service with IP $ip", "$nameSpace\_$service");
  my $hostname;
  my $field;
  if (proxyType() eq 'kubeproxy')
  {
    $field = 'ip';
    $hostname = $ip;
  } else { 
    $field = 'hostname';
    $hostname = gethostbyaddr(inet_aton($ip), AF_INET);
    if (! $hostname || $hostname eq $ip)
    {
      if (ipVersion($ip) == 6)
      {
        $ip =~ s/:/\-/g;
        $hostname = "$ip.sslip.io";
      } else {
        $hostname = "$ip.sslip.io";
      }
    }
  }
  # Avoid possible conflict with kube-proxy
#  if ($nameSpace eq 'cattle-system')
#  {
#    debug("Skip patching cattle-system service");
#    return('');
#  }
  my $patch = [
   {
     op => 'replace',
     path => '/status/loadBalancer',
     value => {
       ingress => [{
         $field => "$hostname"
       }]
     }
   }
  ];
  my $json = encode_json($patch);
  my $url = "$apiConfig{apiURL}/namespaces/$nameSpace/services/$service/status";
  my $header;
  if ($apiConfig{token})
  {
    $header = ['Content-Type' => 'application/json-patch+json', 'Accept' => 'application/json', 'Connection' => 'close', 'Authorization' => "Bearer $apiConfig{token}"];
  } else {
    $header = ['Content-Type' => 'application/json-patch+json', 'Accept' => 'application/json', 'Connection' => 'close'];
  }
  my $request = HTTP::Request->new('PATCH', $url, $header, $json);
  my $ua = apiConnect();
  my $response = $ua->request($request);
  if ($response->is_success)
  {
    return( $response->decoded_content );
  } else {
    error("Error patching service: ".$response->status_line);
    debug($response->decoded_content);
  }
  return('');
}

sub writeServiceEvent
{
  my ($serviceSpec, $type, $reason, $message) = @_;

  my $header;
  if ($apiConfig{token})
  {
    $header = ['Content-Type' => 'application/json', 'Accept' => 'application/json', 'Connection' => 'close', 'Authorization' => "Bearer $apiConfig{token}"];
  } else {
    $header = ['Content-Type' => 'application/json', 'Accept' => 'application/json', 'Connection' => 'close'];
  }
  my ($namespace, $service) = split('_', $serviceSpec);
  my $serviceJson = readService($namespace, $service);
  my $serviceHash;
  eval {
    $serviceHash = decode_json($serviceJson);
  };
  my $doRef = 1;
  if (! $serviceHash->{metadata}->{name})
  {
    error("Service $serviceSpec does not exist");
    $doRef = 0;
  }
  my $body;
  $body->{kind} = 'Event';
  $body->{apiVersion} = 'v1';
  $body->{metadata}->{name} = "event-" . time;
  $body->{metadata}->{namespace} = $namespace;
  if ($doRef)
  {
    $body->{involvedObject}->{apiVersion} = $serviceHash->{apiVersion};
    $body->{involvedObject}->{kind} = $serviceHash->{kind};
    $body->{involvedObject}->{name} = $serviceHash->{metadata}->{name};
    $body->{involvedObject}->{namespace} = $serviceHash->{metadata}->{namespace};
    $body->{involvedObject}->{resourceVersion} = $serviceHash->{metadata}->{resourceVersion};
    $body->{involvedObject}->{uid} = $serviceHash->{metadata}->{uid};
  }
  $body->{type} = $type;
  $body->{reason} = $reason;
  $body->{message} = $message;
  $body->{lastTimestamp} = timeStamp();
  my $json = encode_json($body);

  my $url = "$apiConfig{apiURL}/namespaces/$namespace/events";

  my $request = HTTP::Request->new('POST', "$url", $header, $json);
  my $ua = apiConnect();
  my $response = $ua->request($request);
  if ($response->is_success)
  {
    return( $response->decoded_content );
  } else {
    if ($response->code eq '404')
    {
      my $request = HTTP::Request->new('POST', "$url", $header, $json);
      my $ua = apiConnect();
      my $response = $ua->request($request);
      if ($response->is_success)
      {
        return( $response->decoded_content );
      } else {
        error("Error writing event: ".$response->status_line);
        debug($request->as_string);
        debug($response->decoded_content);
      }
    } else {
      error("Error writing event: ".$response->status_line);
      debug($request->as_string);
      debug($response->decoded_content);
    }
  }
  return('');
}

sub writePodEvent
{
  my ($podSpec, $type, $reason, $message) = @_;

  my $header;
  if ($apiConfig{token})
  {
    $header = ['Content-Type' => 'application/json', 'Accept' => 'application/json', 'Connection' => 'close', 'Authorization' => "Bearer $apiConfig{token}"];
  } else {
    $header = ['Content-Type' => 'application/json', 'Accept' => 'application/json', 'Connection' => 'close'];
  }
  my ($namespace, $pod) = split('_', $podSpec);
  my $podJson = readPod($namespace, $pod);
  my $podHash;
  eval {
    $podHash = decode_json($podJson);
  };
  my $doRef = 1;
  if (! $podHash->{metadata}->{name})
  {
    error("Pod $podSpec does not exist");
    $doRef = 0;
  }
  my $body;
  $body->{kind} = 'Event';
  $body->{apiVersion} = 'v1';
  $body->{metadata}->{name} = "event-" . time . '-' . int(rand(10000));
  $body->{metadata}->{namespace} = $namespace;
  if ($doRef)
  {
    $body->{involvedObject}->{apiVersion} = $podHash->{apiVersion};
    $body->{involvedObject}->{kind} = $podHash->{kind};
    $body->{involvedObject}->{name} = $podHash->{metadata}->{name};
    $body->{involvedObject}->{namespace} = $podHash->{metadata}->{namespace};
    $body->{involvedObject}->{resourceVersion} = $podHash->{metadata}->{resourceVersion};
    $body->{involvedObject}->{uid} = $podHash->{metadata}->{uid};
  }
  $body->{type} = $type;
  $body->{reason} = $reason;
  $body->{message} = $message;
  $body->{lastTimestamp} = timeStamp();
  my $json = encode_json($body);

  my $url = "$apiConfig{apiURL}/namespaces/$namespace/events";

  my $request = HTTP::Request->new('POST', "$url", $header, $json);
  my $ua = apiConnect();
  my $response = $ua->request($request);
  if ($response->is_success)
  {
    return( $response->decoded_content );
  } else {
    if ($response->code eq '404')
    {
      my $request = HTTP::Request->new('POST', "$url", $header, $json);
      my $ua = apiConnect();
      my $response = $ua->request($request);
      if ($response->is_success)
      {
        return( $response->decoded_content );
      } else {
        error("Error writing event: ".$response->status_line);
        debug($request->as_string);
        debug($response->decoded_content);
      }
    } else {
      error("Error writing event: ".$response->status_line);
      debug($request->as_string);
      debug($response->decoded_content);
    }
  }
  return('');
}

# Patches Endpoints
sub serviceEndpoint
{
  my ($nameSpace, $service, $ip, $ports) = @_;

  my $ua = apiConnect();
  my $response;
  my $url = "$apiConfig{apiURL}/namespaces/$nameSpace/endpoints/$service";
  my $patch;
  $patch->{kind} = 'Endpoints';
  $patch->{apiVersion} = 'v1';
  $patch->{metadata}->{name} = $service; 
  $patch->{subsets}->[0]->{addresses}[0]->{ip} = $ip;
  my $count = 0;
  foreach my $p ( $@{$ports} )
  {
    $patch->{subsets}->[0]->{ports}[$count]->{name} = $ports->[$count]->{name};
    $patch->{subsets}->[0]->{ports}[$count]->{protocol} = $ports->[$count]->{protocol};
    $patch->{subsets}->[0]->{ports}[$count]->{port} = int($ports->[$count]->{port});
    $count++;
  }
  my $body;
  eval {
    $body = encode_json($patch);
  };
  my $header;
  if ($apiConfig{token})
  {
    $header = ['Content-Type' => 'application/json', 'Accept' => 'application/json', 'Connection' => 'close', 'Authorization' => "Bearer $apiConfig{token}"];
  } else {
    $header = ['Content-Type' => 'application/json', 'Accept' => 'application/json', 'Connection' => 'close'];
  }
  my $request = HTTP::Request->new('PUT', $url, $header, $body);
  my $ua = apiConnect();
  my $response = $ua->request($request);
  if ($response->is_success)
  {
    debug("Patched endpoint $nameSpace:$service with IP $ip");
    return( $response->decoded_content );
  } else {
    error("Error patching endpoint: ".$response->status_line);
    debug Dumper $request;
    debug($response->decoded_content);
  }
  return('');
}

# Tries to determine my pod's spec automatically
sub getMyself
{
  # Cache for speed, TODO need to expire this cache
  return($myself) if defined($myself); 

  # Easiest way would be to pass pod name from kubernetes to environment
  if ($ENV{MYSELF})
  {
    $myself = "$apiConfig{nameSpace}\_$ENV{MYSELF}";
    $connected = 1;
    return($myself);
  }   
  my $hostname = $ENV{HOSTNAME};
  my $pods = readPods($apiConfig{nameSpace});
  my $podsHash;
  eval {
    $podsHash = decode_json($pods);
  };
  foreach my $i ( @{$podsHash->{items}} )
  {
    # Watcher hostname should match pod name
    if ( $ENV{HOSTNAME} eq $i->{metadata}->{name} )
    {
      $myself = "$apiConfig{nameSpace}\_$i->{metadata}->{name}";
      $connected = 1;
      return($myself);
    }
    # Actor hostname should match node name
    if ( (substr($i->{metadata}->{name},0,5) eq 'actor') && ($ENV{HOSTNAME} eq $i->{spec}->{nodeName}) )
    {
      $myself = "$apiConfig{nameSpace}\_$i->{metadata}->{name}";
      $connected = 1;
      return($myself);
    } 
  }
  # Failed
  $myself = '';
  warning("Failed to determined pod spec, local logging only");
  return($myself);
}

sub isConnected
{
  return($connected);
}

sub apiConnect
{
  my $ua;
  if ($apiConfig{proto} eq 'https')
  {
    if ($apiConfig{caCert})
    {
      $ua = LWP::UserAgent->new(agent=>"$apiConfig{agent}", ssl_opts => { verify_hostname => 1, SSL_ca_path => $apiConfig{caCert} } );
    } else {
      $ua = LWP::UserAgent->new(agent=>"$apiConfig{agent}", ssl_opts => { verify_hostname => 0 } );
    }
  } else{
    $ua = LWP::UserAgent->new(agent=>"$apiConfig{agent}");
  }
  return($ua);
}

sub timeStamp
{
  my $dt = DateTime->now();
  return($dt->ymd.'T'.$dt->hms.'Z');
}

if (my $self = getMyself())
{
  info("My pod is $self");
}
1;
__END__

=head1 NAME

k8slb_api - k8slb API library

=head1 SYNOPSIS

Handles kubernetes API calls

=head1 DESCRIPTION

=head1 REQUIRES

LWP::UserAgent
HTTP::Request
Encode
JSON

=head1 AUTHOR
Chris Arnold <carnold@vt.edu>

=cut
  
