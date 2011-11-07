package iPlant::SuperAuthenticate;

use 5.008000;
use strict;
use warnings;
use Carp;

require Exporter;

our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(
	
) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw( new proxy debug delegate_user delegate_token);

our $VERSION = '0.11';
use vars qw($VERSION);

use LWP;
# Emit verbose HTTP traffic logs to STDERR. Uncomment
# to see detailed (and I mean detailed) HTTP traffic
#use LWP::Debug qw/+/;
use HTTP::Request::Common qw(POST);
# For handling the JSON that comes back from iPlant services
use JSON::XS;
# A special option handler that can be dynamically configured
# It relies on GetOpt::Long, but I configure that dependency
# to pass through non-recognized options.
use Getopt::Long::Descriptive;
use Getopt::Long qw(:config pass_through);
# Used for exporting complex data structures to text. Mainly used here 
# for debugging. May be removed as a dependency later
use YAML qw(Dump);
use MIME::Base64;

use constant kExitJobError=>1;
use constant kExitError=>-1;
use constant kExitOK=>0;

my @config_files = qw(/etc/iplant.superauthenticate.json  ./iplant.superauthenticate.json );

# Never subject to configuration
my $AGENT = "iPlantRobot/$VERSION ";

# Define API endpoints
my $AUTH_ROOT = "auth-v1";
my $AUTH_END = $AUTH_ROOT;
my $TRANSPORT = 'https';

# Preloaded methods go here.

sub new {

	my $proto = shift;
	my $class = ref($proto) || $proto;
	
	my $self  = {	'hostname' => 'foundation.iplantc.org',
					'user' => '',
					'password' => '',
					'token' => ''
	};
	
	$self = _auto_config($self);
	
	bless($self, $class);
    return $self;
}

sub proxy {

	my $self = shift;
	my $passed_id = shift;
	
	my @opt_parameters = ("$0 %o");
	push(@opt_parameters, ['proxy_user=s', "iPlant username to proxy", { 'default' => 'api_sample_user' }]);
	
	my ($opt1, $usage1) = describe_options(@opt_parameters);
	my $nt = auth_post_token_delegate($self, $opt1->{'proxy_user'});
	
	if (defined($nt)) {
	
		$self->delegate_user($opt1->{'proxy_user'});
		$self->delegate_token($nt);
		
		return 1;
	
	} else {
	
		print STDERR "Error establishing proxy for " . $opt1->{'proxy_user'} . "\n";
		exit kExitError;
	
	}
}

sub auth_post_token_delegate {
	
	my ($self, $proxied_user) = @_;
	
	#print STDERR "Delegating $proxied_user\n";
	
	# Don't use the generic user agent
	my $ua = LWP::UserAgent->new;
	$ua->agent($AGENT);
	$ua->default_header( Authorization => 'Basic ' . _encode_credentials($self->user, $self->password) );
	
	
	
	my $url = "$TRANSPORT://" . $self->hostname . "/$AUTH_END/";
	# lifetime = 172800 = 2 days worth of seconds
	my %submitForm = ('username'=>$proxied_user, 'lifetime'=>172800);
	my $res = $ua->post($url, \%submitForm );
		
	my $message;
	my $mref;
	my $json = JSON::XS->new->allow_nonref;
				
	if ($res->is_success) {
		$message = $res->content;
		print STDOUT $message, "\n";
		$mref = $json->decode( $message );
		if (defined($mref->{'result'}->{'token'})) {
			return $mref->{'result'}->{'token'};
		}
	} else {
		print STDERR (caller(0))[3], " ", $res->status_line, "\n";
		return undef;
	}

}

sub user {
	my $self = shift;
	if (@_) { $self->{user} = shift }
	return $self->{user};
}

sub password {
	my $self = shift;
	if (@_) { $self->{password} = shift }
	return $self->{password};
}

sub token {
	my $self = shift;
	if (@_) { $self->{token} = shift }
	return $self->{token};
}

sub delegate_user {
	my $self = shift;
	if (@_) { $self->{delegate_user} = shift }
	return $self->{delegate_user};
}

sub delegate_token {
	my $self = shift;
	if (@_) { $self->{delegate_token} = shift }
	return $self->{delegate_token};
}

sub hostname {
	my $self = shift;
	if (@_) { $self->{hostname} = shift }
	return $self->{hostname};
}

sub _auto_config {
	
	my $self = shift;
	
	# Load config file from various paths
	# Values in subsequent files over-ride earlier values
	my $configured = 0;
	foreach my $c (@config_files) {
		
		if (-e $c) {
			open(CONFIG, $c);
			my $contents = do { local $/;  <CONFIG> };
			if (defined($contents)) {
				my $json = JSON::XS->new->allow_nonref;	
				my $mref = $json->decode( $contents );
				
				foreach my $option (keys %{ $mref }) {
					$self->{$option} = $mref->{$option};
				}
			}
		}
	}
	
	unless (($self->{'user'} ne '') and ($self->{'password'} ne '')) {
		print STDERR "SuperAuthenticate was not properly configured with a username/password\n";
		print STDERR "Please create a valid config file at one of these locations: ", join(", ", @config_files), "\n";
		exit 1;
	}
	
	return $self;

}

sub _encode_credentials {

	my ($u, $p) = @_;
	my $encoded = encode_base64("$u:$p");
	return $encoded;

}

sub debug {
	my $self = shift;
	if (@_) { $self->{debug} = shift }
	return $self->{debug};
}

1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

iPlant::SuperAuthenticate - Perl extension for blah blah blah

=head1 SYNOPSIS

  use iPlant::SuperAuthenticate;
  blah blah blah

=head1 DESCRIPTION

Stub documentation for iPlant::SuperAuthenticate, created by h2xs. It looks like the
author of the extension was negligent enough to leave the stub
unedited.

Blah blah blah.

=head2 EXPORT

None by default.



=head1 SEE ALSO

Mention other useful documentation such as the documentation of
related modules or operating system documentation (such as man pages
in UNIX), or any relevant external documentation such as RFCs or
standards.

If you have a mailing list set up for your module, mention it here.

If you have a web site set up for your module, mention it here.

=head1 AUTHOR

Matt Vaughn, E<lt>mwvaughn@apple.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2011 by Matt Vaughn

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.0 or,
at your option, any later version of Perl 5 you may have available.


=cut
