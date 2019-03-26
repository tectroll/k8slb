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
                &readServices           
		&readNodes
		&readPods
		&patchService
		&serviceEndpoint
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
        $ip =~ s/:/\./g;
        $hostname = "$ip.ip6.name";
      } else {
        $hostname = "$ip.xip.io";
      }
    }
  }
  # Avoid possible conflict with kube-proxy
  if ($nameSpace eq 'cattle-system')
  {
    debug("Skip patching cattle-system service");
    return('');
  }
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
  
