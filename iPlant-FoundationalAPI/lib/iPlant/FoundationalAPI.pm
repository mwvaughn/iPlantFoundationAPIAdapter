package iPlant::FoundationalAPI;

use 5.010000;
use strict;
use warnings;
use Carp;

require Exporter;

our @ISA = qw(Exporter);

# This allows declaration use iPlant::FoundationalAPI ':all';
our %EXPORT_TAGS = ( 'all' => [ qw(
	
) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw( new invoke application_id set_credentials debug );

our $VERSION = '0.10';
use vars qw($VERSION);
    
use LWP;
# Emit verbose HTTP traffic logs to STDERR. Uncomment
# to see detailed (and I mean detailed) HTTP traffic
#use LWP::Debug qw/+/;
use HTTP::Request::Common qw(POST);
# Needed to emit the curl-compatible form when DEBUG is enabled
use URI::Escape;
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
use constant kMaximumSleepSeconds=>600; # 10 min

my @config_files = qw(/etc/iplant.foundationalapi.json ~/.iplant.foundationalapi.json ~/Library/Preferences/iplant.foundationalapi.json ./iplant.foundationalapi.json );

# Never subject to configuration
my $ZONE = 'iPlant Job Service';
my $AGENT = "iPlantRobot/0.1 ";

# Define API endpoints
my $APPS_ROOT = "apps-v1";
my $IO_ROOT = "io-v1";
my $AUTH_ROOT = "auth-v1";
my $AUTH_END = $AUTH_ROOT;
my $APPS_END = "$APPS_ROOT/apps/name";
my $APPS_SHARE_END = "$APPS_ROOT/apps/share/name";
my $JOB_END = "$APPS_ROOT/job";
my $JOBS_END = "$APPS_ROOT/jobs";
my $IO_END = "$IO_ROOT/io/list";
my $TRANSPORT = 'https';

sub new {

	my $proto = shift;
	my $class = ref($proto) || $proto;
	
	my $self  = {	'hostname' => 'foundation.iplantc.org',
					'iplanthome' => '/iplant/home/',
					'processors' => 1,
					'run_time' => '01:00:00',
					'user' => '',
					'password' => '',
					'token' => '',
					'credential_class' => 'self'
	};
	
	$self = _auto_config($self);
	
	bless($self, $class);
    return $self;
}

sub _auto_config {
	
	# Load config file from various paths
	# to populate user, password, token, host, processors, runtime, and so on

	my $self = shift;
	
	# Values in subsequent files over-ride earlier values
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
	
	return $self;

}

sub invoke {
	
	# This routine pops off the first term in the command line and is used to capture
	# the 'verb' being passed to scripts built with FoundationAPI
	# 
	# Subsequent terms are then handed down the chain of execution in @ARGV
	#
	# The invoke subroutine then tries to act on the detected verb
	
	my $self = shift;
	my $status = kExitError;
	
	if ($#ARGV >= 0) {
	
		my $command = shift(@ARGV);
		if ($command =~ 'run') {
			# run a job
			$status = job_run($self);
		} elsif ($command eq 'list') {
			# list a path from IO
			$status = io_list($self);
		} elsif ($command eq 'search') {
			# search and print out apps by name, id, tags, etc
			$status = apps_search($self);
		} elsif ($command eq 'authenticate') {
			$status = auth_token($self);
		}
	
	} else {
		print STDERR "$0 valid commands: run, list, search, authenticate\n";
	}
	
	exit $status;

}

sub auth_token {
	
	# Implements the verb 'authenticate'
	# Success: Prints token to STDOUT, returns 0
	# Failure: Prints HTTP status message, returns 1
	
	my $self = shift;
	
	my @opt_parameters = ("$0 %o");
	
	if ($self->credential_class ne 'proxied') {
		push(@opt_parameters, ['user=s', "iPlant username []"]);
		push(@opt_parameters, ['password=s', "iPlant password []"]);
		push(@opt_parameters, ['token=s', "iPlant password []"]);
		push(@opt_parameters, []);
		push(@opt_parameters, ["help|usage", "print usage and exit"]);
	} else {
		return kExitError;
	}
	
	my ($opt, $usage) = describe_options(@opt_parameters);
	# Exit on --help
	if ($opt->help) {
		print($usage->text);
		return kExitOK;
	}
	
	# Set up credentials
	if ($self->credential_class ne 'proxied') {
		if (_configure_auth_from_opt($self, $opt) == 0) { return kExitError };
	}
	
	return kExitOK;
	
}

sub job_run {
	
	# Implements the verb 'run'
	# 1) Shows command line params for application_id 
	# 2) Runs a job for application_id
	# 3) Helps with integration by emitting JSON dialects
	# Behavior depends on command flags passed into 'run'
	# Exits with 0 on success, 1 on failure
	
	my $self = shift;

	my $application_id = $self->application_id;
	
	unless (defined($application_id)) {
		print STDERR "You haven't defined application_id via iPlant::FoundationalAPI->application_id()\n";
		return kExitError;
	}
	
	print STDERR "Application_Id: $application_id", "\n";
	
	my $result1 = $self->_handle_input_run($application_id);
	# A positive result from _handle_input_run indicates that I have launched a job
	# Otherwise, I have performed one of the utility tasks associated with 'run'
	if ($result1 <= 0) {
		return $result1;
	}
	
	# Start polling the job. This subroutine will not return a value until
	# either an error is detected or the job finishes running
	my $result2 = $self->_poll_job_until_done_or_dead($result1);
	return $result2;
	
	return kExitOK;

}

sub _handle_input_run {
	
	# Nuts and bolts behind job_run
	
	# fetch app description hashref $A
	# use $A to configure Options
	# parse incoming command line into a hash $H
	# post $H as a form to job endpoint
	# return job ID or errorState (negative numbers) 
	
	my ($self, $application_id) = @_;
	
	my @opt_parameters;
	my @opt_flags;
	my $temp_from_self;
	
	# First, define privledged system-level options and flags
	# Please don't laugh at the need to store original param names in opt_original_names
	# Getopt::Long::Descriptive strips case out of param names
	# and the JOB APIs param names are case sensitive
	
	my %opt_original_names = ('processorcount'=>'processorCount', 'maxmemory'=>'maxMemory', 'requestedtime'=>'requestedTime', 'callbackurl'=>'callbackUrl', 'jobname'=>'jobName', 'archivepath'=>'archivePath', 'archive'=>'archive', 'user'=>'user', 'password'=>'password', 'token'=>'token');
	@opt_parameters = ("$application_id %o");
	
	# Auth parameters
	if ($self->credential_class ne 'proxied') {
		push(@opt_parameters, ['user=s', "iPlant username []"]);
		push(@opt_parameters, ['password=s', "iPlant password []"]);
		push(@opt_parameters, ['token=s', "iPlant secure token []"]);
		push(@opt_parameters, []);
	} else {
		push(@opt_parameters, ['proxy_user=s', "iPlant username to proxy [" . $self->{'user'} . "]"]);
		push(@opt_parameters, []);
	}
	
	# Intercept the authentication params to allow user to over-ride pre-configured credential info 
	# Since I configured Getopt::Long to do pass_through, the other options I define 
	# dynamically after this are handled correctly

	my ($opt1, $usage1) = describe_options(@opt_parameters);
	if ($self->credential_class ne 'proxied') {
		if (_configure_auth_from_opt($self, $opt1) == 0) { return kExitError };
	}
	
	# System level run parameters
	# Question: What happens if you pass processorCount to a serial application? Do I need to prevent that?
	$temp_from_self = $self->processors;
	push(@opt_parameters, ['processorCount=i',"Processor Count [$temp_from_self]", { default => $temp_from_self }]);
	# Is this bytes, mb, what...?
	push(@opt_parameters, ['maxMemory=s','Maximum memory required']);
	$temp_from_self = $self->run_time;
	push(@opt_parameters, ['requestedTime=s', "Estimated run time HH::MM::SS [$temp_from_self]", { default => $temp_from_self }]);
	push(@opt_parameters, ['callbackUrl=s','Callback URL']);
	push(@opt_parameters, ['jobName=s','Job name']);
	push(@opt_parameters, ['archivePath=s','Archive Path']);
	push(@opt_parameters, ['archive','Archive results [true]', { default => 1 }]);
	push(@opt_parameters, []);
	
	# Returns reference to message.result.[0] from APPS call
	# This would fail if I had not already configured the global variables
	# that hold authentication information
	my $app_json = apps_fetch_description($self, $application_id);
	if ($app_json eq kExitError) { return kExitError };
	
	# Grab the inputs and parameters arrays from the data structure
	my @app_inputs = @{ $app_json->{'inputs'} }; # array reference
		if ($self->debug) { print STDERR Dump @app_inputs, "\n" }
	my @app_params = @{ $app_json->{'parameters'} }; # array reference
		if ($self->debug) { print STDERR Dump @app_params, "\n" }

	# Start with input paths. These are just a special kind of parameter
	foreach (@app_inputs) {
		$opt_original_names{lc($_->{'id'})}=$_->{'id'};
		my $id = $_->{'id'} . "=s";
		my @p = ($id, $_->{'label'} . " [$_->{'value'}]", { default => $_->{'value'} });
		push(@opt_parameters, \@p);
	}
	push(@opt_parameters, []);
	
	# Now handle parameters.
	foreach (@app_params) {
		$opt_original_names{lc($_->{'id'})}=$_->{'id'};

		my $id = $_->{'id'};
		my $req = "="; # optional is default

		if ($_->{'type'} eq 'string') {
			$id .= $req ."s";
		} elsif ($_->{'type'} eq 'number') {
			$id .= $req ."f";
		} elsif ($_->{'enum'} eq 'enum') {
			$id .= $req ."s";
		}
		my @p = ($id, $_->{'label'} . " [$_->{'defaultValue'}]", { default => $_->{'defaultValue'} });
		push(@opt_parameters, \@p);	
	}
	
	push(@opt_parameters, []);
	push(@opt_parameters, ["help|usage", "print usage and exit"]);
	push(@opt_parameters, ["json", "print $application_id APPS.json and exit"]);
	push(@opt_parameters, ["tito", "print $application_id Tito.json and exit"]);	
	
	# Actually parse options
	#
	# Notice that I don't use GetOpt::Long - this is because it doesn't support
	# dynamically configured option lists (that I can easily discern)
	
	my ($opt, $usage) = describe_options(@opt_parameters);
	
	# Exit on --help
	if ($opt->help) {
		print($usage->text);
		return kExitOK;
	}
	
	# Exit on --json
	if ($opt->json) {
		my $json = JSON::XS->new->ascii->pretty->allow_nonref;
		my $mref = $json->encode( $app_json ); 
		print $mref, "\n";
		return kExitOK;
	}
	
	# Exit on --tito
	if ($opt->tito) {
		print STDERR "Tito mode is not supported yet\n";
		return kExitOK;
	}
	
	# Build JOB submit form
	# For now, just blast entire form set into the POST. Add smarts later if needed
	my %submitForm;
	# Manually force appName
	$submitForm{'softwareName'}=$application_id;
	
	foreach my $k (keys %opt_original_names) {
		$submitForm{ $opt_original_names{$k} } = $opt->{$k};
	}
	
	# Can print out a form that can be posted using curl
	if ($self->debug) {
		print STDERR "curl POST form\n";
		my $form = '';
		foreach my $m (keys %submitForm) {
			$form = $form . "$m=" . uri_escape($submitForm{$m}) . "&";
		}
		chop($form);
		print STDERR $form, "\n";
	}
	
	# Submit form via POST to JOB service
	my $ua = _setup_user_agent($self);
	my $job = $ua->post("$TRANSPORT://" . $self->hostname . "/$JOB_END", \%submitForm );
	
	# Interpret result
	if ($job->is_success) {
		my $message = $job->content;
		my $mref;
		my $json = JSON::XS->new->allow_nonref;
		$mref = $json->decode( $message );
		return $mref->{'result'}->{'id'};
	} else {
		print STDERR $job->status_line, "\n";
		return kExitError;
	}
	
}

sub _poll_job_until_done_or_dead {
	
	# input: JOB ID from a submission instance
	# result: exit code 0 or 1
	# error: die
	my ($self, $job_id) = @_;
	
	my $current_status = 'UNDEFINED';
	my $new_status = 0;
	my $baseline_sleeptime = 10;
	my $sleeptime = $baseline_sleeptime;
	
	# This Loop only exits on error with ascertaining job status
	# There's code inside to exit based on the actual job status
	while ($new_status ne kExitError) {
	
		$new_status = $self->job_get_status($job_id);
		
		# If status changes, reset sleep time
		if ($new_status ne $current_status) {
			$sleeptime = $baseline_sleeptime;
			$current_status = $new_status;
		}
		
		print STDERR "$JOBS_END/$job_id\t$current_status\tre-poll: $sleeptime", "s\n";
		
		# Define the statuses that will result in exit from the polling routine
		# along with their exit codes
		if ($current_status eq 'FINISHED') {
			return kExitOK;
		} elsif ($current_status eq 'FAILED') {
			return kExitJobError;
		} elsif ($current_status eq 'KILLED') {
			return kExitJobError;
		}
		
		# I didn't exit, so sleep and poll again later
		sleep $sleeptime;
		
		# Increment sleeptime to wait longer before checking again. 
		# This is a load-smoothing behavior
		$sleeptime = int(($sleeptime * 1.25) + 0.5);
		if ($sleeptime > kMaximumSleepSeconds) { $sleeptime = kMaximumSleepSeconds }
		
	}
	
	return kExitJobError;
	
}

sub job_get_status {
	
	# Return text literal status report for a job
	my ($self, $job_id) = @_;
	
	my $ua = _setup_user_agent($self);
	my $req = HTTP::Request->new(GET => "$TRANSPORT://" . $self->hostname . "/$JOB_END/$job_id");

	# Parse response
	my $message;
	my $mref;
	my $json = JSON::XS->new->allow_nonref;
	
	# Try up to 3 times to reach job status endpoint
	my $sleeptime = 30;
	for (my $x = 0; $x < 3; $x++) {
	
		# Issue the request
		my $res = $ua->request($req);
		
		if ($res->is_success) {
			$message = $res->content;
			$mref = $json->decode( $message ); 
			return $mref->{'result'}->{'status'};
		} else {
		
			print STDERR "$JOB_END/$job_id\tERROR\tre-poll: $sleeptime", "s\n";
			sleep $sleeptime;
			
			# Wait longer before checking again. This is a load-smoothing behavior
			$sleeptime = $sleeptime * 1.5;
			if ($sleeptime > kMaximumSleepSeconds) { $sleeptime = kMaximumSleepSeconds }
		}
	
	}
	
	print STDERR "$JOBS_END/$job_id was never reachable, so we must assume catastrophic failure.\n";
	return kExitError;

}

sub apps_fetch_description {
	
	# input: fully-qualified APPS API name
	# result: message body from APPS query
	# error: die
	my ($self, $app) = @_;
	
	my $ua = _setup_user_agent($self);
	my ($req, $res, $wasnt_acl);
	
	foreach my $ep ($APPS_END, $APPS_SHARE_END) {

		$wasnt_acl = 0;
		my $url = "$TRANSPORT://" . $self->hostname . "/$ep/" . $self->application_id;	
		$req = HTTP::Request->new(GET => $url);
		$res = $ua->request($req);
	
		my $message;
		my $mref;
		my $json = JSON::XS->new->allow_nonref;
			
		if ($res->is_success) {
			$message = $res->content;
			$mref = $json->decode( $message );
			$wasnt_acl = 1;
			if (defined($mref->{'result'}->[0])) {
				return $mref->{'result'}->[0];
			}
		}
	
	}
	
	print STDERR $res->status_line, "\n";
	if ($wasnt_acl) {
		print STDERR $self->application_id, " was not found\n";
	}
		
	return kExitError;
	
}

sub _apps_fetch_description {
	
	# input: fully-qualified APPS API name
	# result: message body from APPS query
	# error: die
	my ($self, $app) = @_;
	
	my $ua = _setup_user_agent($self);
	my $req = HTTP::Request->new(GET => "$TRANSPORT://" . $self->hostname . "/$APPS_SHARE_END/" . $self->application_id);	
	my $res = $ua->request($req);

	my $message;
	my $mref;
	my $json = JSON::XS->new->allow_nonref;
	
	if ($res->is_success) {
		$message = $res->content;
		$mref = $json->decode( $message ); 
		return $mref->{'result'}->[0];
	}
	else {
		print STDERR $res->status_line, "\n";
		return kExitError;
	}
}

sub apps_search {
	print STDERR "apps_search\n";
	return 0;
}

# Transport-level Methods
sub _setup_user_agent {
	
	my $self = shift;	
	my $ua = LWP::UserAgent->new;
	
	$ua->agent($AGENT);
	if (($self->user ne '') and ($self->token ne '')) {
		if ($self->debug) {
			print STDERR (caller(0))[3], ": Username/token authentication selected\n";
		}
		$ua->default_header( Authorization => 'Basic ' . _encode_credentials($self->user, $self->token) );
	} else {
		if ($self->debug) {
			print STDERR (caller(0))[3], ": Sending no authentication information\n";
		}
	}
	
	return $ua;

}

sub _encode_credentials {
	
	# u is always an iPlant username
	# p can be either a password or RSA encrypted token
	
	my ($u, $p) = @_;
	my $encoded = encode_base64("$u:$p");
	return $encoded;

}

sub _configure_auth_from_opt {
	
	# Allows user to specify username/password (unencrypted)
	# Uses this info to hit the auth-v1 endpoint
	# fetch a token and cache it as the global token
	# for this instance of the application
	
	my ($self, $opt1) = @_;
	
	if ($opt1->user and $opt1->password and not $opt1->token) {
	
		if ($self->debug) {
			print STDERR (caller(0))[3], ": Username/password authentication selected\n";
		}
		# set global.user global.password
		$self->user( $opt1->{'user'} );
		$self->password( $opt1->{'password'} );
				
		# hit auth service for a new token
		my $newToken = $self->auth_post_token();
		print "Issued-Token: ", $newToken, "\n";
		
		$self->password(undef);
		# set global.token
		$self->token( $newToken );
	
	} elsif ($opt1->user and $opt1->token and not $opt1->password) {
		
		if ($self->debug) {
			print STDERR (caller(0))[3], ": Secure token authentication selected\n";
		}
		
		$self->user( $opt1->user );	
		$self->token( $opt1->token );
	
	} else {
		if ($self->debug) {
			print STDERR (caller(0))[3], ": Defaulting to pre-configured values\n";		
		}
	}
	
	return 1;
	
}

sub auth_post_token {
	
	# Retrieve a token in user mode
	my $self = shift;
	
	# Don't use the generic user agent
	my $ua = LWP::UserAgent->new;
	$ua->agent($AGENT);
	$ua->default_header( Authorization => 'Basic ' . _encode_credentials($self->user, $self->password) );
		
	my $url = "$TRANSPORT://" . $self->hostname . "/$AUTH_END/";
	my $req = HTTP::Request->new(POST => $url);
	my $res = $ua->request($req);
	
	my $message;
	my $mref;
	my $json = JSON::XS->new->allow_nonref;
				
	if ($res->is_success) {
		$message = $res->content;
		$mref = $json->decode( $message );
		if (defined($mref->{'result'}->{'token'})) {
			return $mref->{'result'}->{'token'};
		}
	} else {
		print STDERR (caller(0))[3], " ", $res->status_line, "\n";
		return undef;
	}

}

sub io_list {

	# List iRODS directory	
	my $self = shift;
	
	# return kExitOK to allow app to exit
	my @opt_parameters = ("$0 list %o");
	
	if ($self->credential_class ne 'proxied') {
		push(@opt_parameters, ['user=s',"iPlant username"]);
		push(@opt_parameters, ['password=s',"iPlant password"]);
		push(@opt_parameters, ['token=s',"iPlant secure token"]);
		push(@opt_parameters, []);
	} else {
		push(@opt_parameters, ['proxy_user=s', "iPlant username to proxy [" . $self->{'user'} . "]"]);
		push(@opt_parameters, []);
	}
	
	push(@opt_parameters, ['path=s',"Path relative to \$IPLANT_HOME"]);
	# Eventually support a tree view of the file system, but
	# not until the service can support a depth-specified recursive walk
	# because I don't want to hit the service for each directory
	#push(@opt_parameters, ['recursive',"Return a recursive view [false]"]);
	push(@opt_parameters, []);
	push(@opt_parameters, ['help',"Print help and exit"]);

	my ($opt, $usage) = describe_options(@opt_parameters);
	if ($self->credential_class ne 'proxied') {
		if (_configure_auth_from_opt($self, $opt) == 0) { return kExitError };
	}
	
	# Exit on --help
	if ($opt->help) {
		print($usage->text);
		return kExitOK;
	}

	# Check for --path
	unless (defined($opt->path)) {
		print STDERR "Please specify iPlant Storage Architecture path using --path\n";
		return kExitError;
	}

	my $ua = _setup_user_agent($self);
	my $req = HTTP::Request->new(GET => "$TRANSPORT://" . $self->hostname . "/" . $IO_END . $opt->path);
	my $res = $ua->request($req);
	
	print "\n$TRANSPORT://" . $self->hostname . "/" . $IO_END . $opt->path, "\n";
	
	# Parse response
	my $message;
	my $mref;
	my $json = JSON::XS->new->allow_nonref;
	
	if ($res->is_success) {
		$message = $res->content;
		if ($self->debug) {
			print STDERR $message, "\n";
		}
		$mref = $json->decode( $message );
		# mref in this case is an array reference
		_display_io_list_reference($mref->{'result'});
		return kExitOK;
	}
	else {
		print STDERR $res->status_line, "\n";
		return kExitError;
	}	
	
	
}

sub _display_io_list_reference {

	# Walk the IO response object and print to screen
	my $ref = shift;
	foreach my $f (@{ $ref }) {
		# name
		print $f->{'name'};
		# append slash if folder
		if ($f->{'format'} =~ /folder/) {
			print "/";
			print "\t0";
		} else {
			# print size in kB
			print "\t", _human_readable_bytes($f->{'length'});
		}
		# updated time
		#my $updated_string = gmtime( $f->{'lastModified'} );
		#print "\t", $updated_string;
		# print file type
		print "\n";
	}

}

sub _human_readable_bytes {

	# Convert bytes to human-readable values
	my $bytes = shift;
	my $suffix = '';
	my @suffixes = qw(b K M G T P E);
	my $i_converted = 0;
	
	for (my $x = 1; $x <= $#suffixes; $x++) {
		if ($bytes / (1024 ** $x) >= 1.0) {
			$bytes = $bytes / 1024;
			$suffix = $suffixes[$x];
			$i_converted++;
		}
	}
	
	if ($i_converted) {
		$bytes = sprintf("%0.0f", $bytes);
	}
	
	return $bytes . $suffix;
}

sub __human_readable_bytes {

	# Convert bytes to human-readable values
	my $bytes = shift;
	my $suffix = '';
	my @suffixes = qw(b K M G T P E);
	my $i_converted = 1;
	
	my $x = 0;
	if ($bytes > 0) {
		$x = int( log($bytes)/log(1024) );
	}
	
	$bytes = $bytes / (1024 ** $x );
	$suffix = $suffixes[$x];
		
	if ($i_converted) {
		$bytes = sprintf("%0.0f", $bytes);
	}
	
	return $bytes . $suffix;
}

# External Utility Methods, Mostly slot-setters

sub debug {
	my $self = shift;
	if (@_) { $self->{debug} = shift }
	return $self->{debug};
}

sub application_id {
	my $self = shift;
	if (@_) { $self->{application_id} = shift }
	return $self->{application_id};
}

sub set_credentials {

	my ($self, $u, $p, $cclass) = @_;
	$self->{user} = $u;
	$self->{token} = $p;
	$self->{credential_class} = $cclass || 'self';
	return 1;
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

sub credential_class {
	my $self = shift;
	if (@_) { $self->{credential_class} = shift }
	return $self->{credential_class};
}

sub hostname {
	my $self = shift;
	if (@_) { $self->{hostname} = shift }
	return $self->{hostname};
}

sub processors {
	my $self = shift;
	if (@_) { $self->{processors} = shift }
	return $self->{processors};
}

sub run_time {
	my $self = shift;
	if (@_) { $self->{run_time} = shift }
	return $self->{run_time};
}

1;
__END__

=head1 NAME

iPlant::FoundationalAPI - Perl extension for interacting with the iPlant Foundational API.

=head1 SYNOPSIS

  use iPlant::FoundationalAPI;
  my $api_instance->new();
  $api_instance->application_id('head-1.0'); # id returned by /apps-v1/apps discovery endpoint
  $api_instance->invoke();

=head1 DESCRIPTION

This module is designed to allow calls to applications deployed in the iPlant Foundational API to be executed as though the applications were local to the user's machine. In addition, utility functions are included to allow application discovery, listing of iPlant Cloud Storage directories, and creation of JSON template code for describing a UI for the application in the iPlant Discovery Environment.

=head2 EXPORT

None by default.

=head2 Application Usage

application.pl run|search|list|authenticate --options

	search --name <name> --tag <tag> 
		--id <id> [--authentication]

	list --path <iRODS path relative to 
		$IRODS_HOME> [--authentication]

	run --options [--application-specific options] 
		[--authentication]
	
	authenticate [--authentication]
		
=head2 Authentication

iPlant offers a secure, ACL-based cyberinfrastructure, and so many interactions with its services require user authentication. Any of the commands (run|search|list) can be extended at run-time with either a combination of iPlant username (--user) and password (--password) OR your iPlant secure authentication token (--token). We recommend the latter. If you supply both sets of credentials, the secure token method takes precedence.

In addition, to faciliate scripting access (or for simple convenience), you may store your credentials in an .iplant.foundationalapi.json file. This will be read at run-time from (in order): /etc/iplant.foundationalapi.json ~/.iplant.foundationalapi.json ~/Library/Preferences/iplant.foundationalapi.json ./iplant.foundationalapi.json. If the same value is specified twice, the most recently read one takes precedence. In addition, command-line parameters (see above) take precedence over file-configured options. An example configuration file (sample.iplant.foundationalapi.json can be found associated with this module.

=head2 Commands

The first option after the name of the script (application.pl for example) is a verb indicating which mode the application should run in. This module current supports four modes: list, search, and run, authenticate.

=head3 List

Invoking "list --path <irods_path>" allows the user to list his/her own storage directory (and its subdirectories) or any other directories to which the user has been granted at least read permission. This includes other user's directories as well as any public or any-user directories in the /iplant/home/community space.

Example: application.pl list --path /vaughn

=head3 Search

The search command allows users to query the public and user-specific lists of deployed JOBS API applications by name. The result is a list of application names, short descriptions, and (most importantly) the unique token identifying that application so that it can be set via the iPlant::FoundationalAPI->application_id() method allowing execution of instances of that application on remote resources.

Search first accesses the public APPS directory, and if nothing matching the query is found, the list of applications shared with the user is queried. In the case of namespace conflict (which should be impossible), the public application will be returned.

Example: application.pl search --name "uniq-1.0"

*NOT CURRENTLY IMPLEMENTED*

=head3 Authenticate

Invoking authenticate --user <username> --password <password> with valid iPlant credentials will issue a new secure token for you and will print that token to STDOUT. It may be used in subsequent operations in lieu of your plaintext password. 

=head3 Run

This is the central function of iPlant::FoundationalAPI. When the module is configured with an appropriate $application_id to which the invoking user has access, a program built using the module first accesses the APPS API description for $application_id and uses it to dynamically configure a set of command line options. Command line options from the user are then matched against these options to build a JOBS submission. Assuming all required parameters have been specified, the submission is then POSTed to the JOBS API endpoint. The application then monitors the status of the submitted job via the JOBS API, printing the status of the job to STDERR at periodic intervals. Once the remote job reports either entered the COMPLETE or FAILED status, the application exits with status 0 or 1, respectively. These exit codes allow callers of the iPlant::FoundationalAPI to detect the final dispensation of the 'run' command and its associated job.

=head4 System Parameters for Job Submission

=over

=item --processorCount [Integer] - The number of processors for a parallel job. This can be specified by default in an .iplant.foundationalapi.json file using the token 'processors'
=item --maxMemory [xGB] - The maximum amount of memory required by your job. Default
=item --requestedTime [HH::MM:SS] - The estimated time required for the job to run. Default 01:00:00. This can be specified by default in an .iplant.foundationalapi.json file using the token 'run_time'
=item --callbackUrl [] - A URL that will be invoked upon completion of the remote job. Supplying an email address will result in an email being sent.
=item --jobName [Random string] - A human-readable name for user's remote job
=item --archive [Flag] - Pass this flag to enable archiving of the job results to your $HOME folder
=item --archivePath [/<path>] - Define a path to which the output of a remote job will be staged. Default is /<username>

=back

=head4 Utility Functions

=over

=item * application.pl run --help will print the entire list of system, authentication, and remote application-specific options (and their defaults if known) to the screen in a standard usage screen.
=item * application.pl run --json will pretty-print the APPS JSON description for $application_id to STDOUT

=back

=head1 SEE ALSO

No information here now. 

=head1 AUTHOR

Matthew W. Vaughn, E<lt>vaughn@iplantcollaborative.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2011 by Matthew W. Vaughn

See included LICENSE file

=cut
