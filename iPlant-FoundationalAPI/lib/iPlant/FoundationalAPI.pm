package iPlant::FoundationalAPI;

use 5.008000;
use strict;
use warnings;
use Carp;
use Mozilla::CA;
use IO::Socket::SSL;

require Exporter;

our @ISA = qw(Exporter);

# This allows declaration use iPlant::foundation-v2 ':all';
our %EXPORT_TAGS = (
    'all' => [
        qw(

            )
    ]
);

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw( new invoke application_id set_credentials debug );

our $VERSION = '2.00';
use vars qw($VERSION);

use LWP;

# Emit verbose HTTP traffic logs to STDERR. Uncomment
# to see detailed (and I mean detailed) HTTP traffic
use LWP::Debug qw/+/;
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

use constant kExitJobError        => 1;
use constant kExitError           => -1;
use constant kExitOK              => 0;
use constant kMaximumSleepSeconds => 3600;    # 20 min
use constant kMaxStatusRetries    => 12;

my @config_files
    = qw(/etc/iplant.foundation-v2.json
         ~/.iplant.foundation-v2.json
         ~/Library/Preferences/iplant.foundation-v2.json
         ./iplant.foundation-v2.json );

# Never subject to configuration
my $ZONE  = 'iPlant Job Service';
my $AGENT = "iPlantRobot/$VERSION ";
my $TRANSPORT      = 'https';

# The API version that we're currently using.
my $API_VERSION = "v2";

# Define API endpoints
my $STORAGE_SYSTEM 	= "data.iplantcollaborative.org";
my $API_ROOT		= $API_VERSION;
my $AUTH_END		= "$API_ROOT/auth";
my $APPS_END		= "$API_ROOT/apps";
my $SYSTEMS_END		=  "$API_ROOT/systems";
my $JOBS_END		= "$API_ROOT/jobs";
my $IO_END			= "$API_ROOT/files/listings/system/$STORAGE_SYSTEM";

sub new {

    my $proto = shift;
    my $class = ref($proto) || $proto;

    my $self = {
        'hostname'         => 'iplant-dev.tacc.utexas.edu',
        'iplanthome'       => '/iplant/home/',
        'processors'       => 1,
        'run_time'         => '01:00:00',
        'user'             => '',
        'password'         => '',
        'token'            => '',
        'credential_class' => 'self'
    };

    $self = _auto_config($self);

    bless( $self, $class );
    return $self;
}

sub _auto_config {

    # Load config file from various paths
    # to populate user, password, token, host, processors, runtime, and so on

    my $self = shift;

    # Values in subsequent files over-ride earlier values
    foreach my $c (@config_files) {

        if ( -e $c ) {
            open( CONFIG, $c );
            my $contents = do { local $/; <CONFIG> };
            if ( defined($contents) ) {
                my $json = JSON::XS->new->allow_nonref;
                my $mref = $json->decode($contents);

                foreach my $option ( keys %{$mref} ) {
                    $self->{$option} = $mref->{$option};
                }
            }
        }
    }

    return $self;

}

sub invoke {

    # This routine pops off the first term in the command line and is used to
    # capture the 'verb' being passed to scripts built with FoundationAPI
    #
    # Subsequent terms are then handed down the chain of execution in @ARGV
    #
    # The invoke subroutine then tries to act on the detected verb

    my $self   = shift;
    my $status = kExitError;

    if ( $#ARGV >= 0 ) {

        my $command = shift(@ARGV);
        if ( $command =~ 'run' ) {

            # run a job
            $status = job_run($self);
        }
        elsif ( $command eq 'list' ) {

            # list a path from IO
            $status = io_list($self);
        }
        elsif ( $command eq 'search' ) {

            # search and print out apps by name, id, tags, etc
            $status = apps_search($self);
        }
        elsif ( $command eq 'authenticate' ) {
            $status = auth_token($self);
        }

    }
    else {
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

    if ( $self->credential_class ne 'proxied' ) {
        push( @opt_parameters, [ 'user=s',     "iPlant username []" ] );
        push( @opt_parameters, [ 'password=s', "iPlant password []" ] );
        push( @opt_parameters, [ 'token=s',    "iPlant password []" ] );
        push( @opt_parameters, [] );
        push( @opt_parameters, [ "help|usage", "print usage and exit" ] );
    }
    else {
        return kExitError;
    }

    my ( $opt, $usage ) = describe_options(@opt_parameters);

    # Exit on --help
    if ( $opt->help ) {
        print( $usage->text );
        return kExitOK;
    }

    # Set up credentials
    if ( $self->credential_class ne 'proxied' ) {
        if ( _configure_auth_from_opt( $self, $opt ) == 0 ) {
            return kExitError;
        }
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

    my $result1 = $self->_handle_input_run();

    # A positive result from _handle_input_run indicates that I have launched
    # a job.  Otherwise, I have performed one of the utility tasks associated
    # with 'run'
    if ( $result1 <= 0 ) {
        return $result1;
    }

    # Start polling the job. This subroutine will not return a value until
    # either an error is detected or the job finishes running
    my $result2 = $self->_poll_job_until_done_or_dead($result1);
    return $result2;

    return kExitOK;

}

# Parameter field extraction subroutines for different API versions.
my %PARAM_FIELD_EXTRACTOR_FOR = (
    'v1' => sub {
        my ($param_ref) = @_;
        my $id          = $param_ref->{id};
        my $label       = $param_ref->{details}{label};
        my $default_val = $param_ref->{defaultValue};
        my $type        = $param_ref->{value}{type};
        return ( $id, $label, $default_val, $type );
    },
    'v2' => sub {
        my ($param_ref) = @_;
        my $id          = $param_ref->{id};
        my $label       = $param_ref->{details}{label};
        my $default_val = $param_ref->{value}{default};
        my $type        = $param_ref->{value}{type};
        return ( $id, $label, $default_val, $type );
    },
);

my %TYPE_SPECIFIER_FOR = (
    'string' => '=s',
    'number' => '=f',
    'enum'   => '=s',
);

sub _build_opt_spec {
    my ( $self, $param_ref, $default_type ) = @_;

    # Extract the fields we need from the parameter definition.
    my $sub_ref = $PARAM_FIELD_EXTRACTOR_FOR{$API_VERSION};
    if ( not defined $sub_ref ) {
        print {*STDERR} "no field extractor defined for $API_VERSION";
        exit kExitError;
    }
    my ( $id, $label, $default_value, $type ) = $sub_ref->($param_ref);

    # Ensure that the label is defined.
    if ( !defined $label ) {
        $label = $id;
    }

    # Use the default type if necessary.
    if ( !defined $type && defined $default_type ) {
        $type = $default_type;
    }

    # Determine the type specifier to pass to the option parser.
    my $type_specifier = $TYPE_SPECIFIER_FOR{$type} || '';

    # Build the components of the result.
    my $spec = "$id$type_specifier";
    my $help = defined $default_value ? "${label} [$default_value]" : $label;
    my $opts = { default => $default_value };

    return [ $spec, $help, $opts ];
}

sub _handle_input_run {

    # Nuts and bolts behind job_run

    # fetch app description hashref $A
    # use $A to configure Options
    # parse incoming command line into a hash $H
    # post $H as a form to job endpoint
    # return job ID or errorState (negative numbers)

    my $self = shift;
    if ( $self->debug ) { print STDERR "_handle_input_run\n" }

    my @opt_parameters;
    my @opt_flags;
    my $temp_from_self;
    my $application_id = $self->{'application_id'};

    # First, define privledged system-level options and flags.  Please don't
    # laugh at the need to store original param names in opt_original_names.
    # Getopt::Long::Descriptive strips case out of param names and the JOB
    # APIs param names are case sensitive.

    my %opt_original_names = (
        'processorcount' => 'processorCount',
        'maxmemory'      => 'maxMemory',
        'requestedtime'  => 'requestedTime',
        'callbackurl'    => 'callbackUrl',
        'jobname'        => 'jobName',
        'archivepath'    => 'archivePath',
        'archive'        => 'archive',
        'user'           => 'user',
        'password'       => 'password',
        'token'          => 'token'
    );

    @opt_parameters = ("$0 %o");

    # Allow command-line configuration of application_id
    unless ( defined( $self->{'application_id'} ) ) {
        push( @opt_parameters,
            [ 'appid=s', "iPlant Agave application ID []" ] );
        push( @opt_parameters, [] );
        my ( $opt2, $usage2 ) = describe_options(@opt_parameters);
        if ( defined( $opt2->appid ) ) {
            $application_id = $opt2->appid;
            $self->{'application_id'} = $application_id;
        }
    }

    unless ( defined($application_id) ) {
        print STDERR "You haven't specified an iPlant Agave application ID\n";
        print STDERR
            "Please either pass the --appid parameter to $0 or add the code\n";
        print STDERR
            "iPlant::foundation-v2->application_id(<app_id>) to $0\n";
        return kExitError;
    }

    print STDERR "Application_Id: $application_id", "\n";

    # Auth parameters
    if ( $self->credential_class ne 'proxied' ) {
        push( @opt_parameters, [ 'user=s',     "iPlant username []" ] );
        push( @opt_parameters, [ 'password=s', "iPlant password []" ] );
        push( @opt_parameters, [ 'token=s',    "iPlant secure token []" ] );
        push( @opt_parameters, [] );
    }
    else {
        push(
            @opt_parameters,
            [   'proxy_user=s',
                "iPlant username to proxy [" . $self->{'user'} . "]"
            ]
        );
        push( @opt_parameters, [] );
    }

    # Intercept the authentication params to allow user to over-ride
    # pre-configured credential info.  Since I configured Getopt::Long to do
    # pass_through, the other options I define dynamically after this are
    # handled correctly.

    my ( $opt1, $usage1 ) = describe_options(@opt_parameters);
    if ( $self->credential_class ne 'proxied' ) {
        if ( _configure_auth_from_opt( $self, $opt1 ) == 0 ) {
            return kExitError;
        }
    }

    # System level run parameters
    $temp_from_self = $self->processors;
    push(
        @opt_parameters,
        [   'processorCount=i',
            "Processor Count [$temp_from_self]",
            { default => $temp_from_self }
        ]
    );

    # Is this bytes, mb, what...?
    push( @opt_parameters, [ 'maxMemory=s', 'Maximum memory required' ] );
    $temp_from_self = $self->run_time;
    push(
        @opt_parameters,
        [   'requestedTime=s',
            "Estimated run time HH::MM::SS [$temp_from_self]",
            { default => $temp_from_self }
        ]
    );
    push( @opt_parameters, [ 'callbackUrl=s', 'Callback URL' ] );
    push( @opt_parameters, [ 'jobName=s',     'Job name' ] );
    push( @opt_parameters, [ 'archivePath=s', 'Archive Path' ] );
    push( @opt_parameters,
        [ 'archive', 'Archive results [true]', { default => 1 } ] );
    push( @opt_parameters, [] );

    # Returns reference to message.result.[0] from APPS call
    # This would fail if I had not already configured the global variables
    # that hold authentication information
    my $app_json = apps_fetch_description( $self, $application_id );

    if ( $app_json eq kExitError ) { return kExitError }

    # Grab the inputs and parameters arrays from the data structure
    my @app_inputs = @{ $app_json->{'inputs'} };    # array reference
    if ( $self->debug ) { print STDERR Dump @app_inputs, "\n" }
    my @app_params = @{ $app_json->{'parameters'} };    # array reference
    if ( $self->debug ) { print STDERR Dump @app_params, "\n" }

    # Most operations can be performed on both inputs and parameters.
    my @inputs_and_params = ( @app_inputs, @app_params );

    # Add the application input and parameter names to the original names hash.
    %opt_original_names = (
        %opt_original_names,
        map { ( "\L$_->{id}" => $_->{id} ) } @inputs_and_params,
    );

    # Add option specifiers for the application itself.
    push @opt_parameters,
        map { $self->_build_opt_spec( $_, 'string' ) } @inputs_and_params;

    push( @opt_parameters, [] );
    push( @opt_parameters, [ "help|usage", "print usage and exit" ] );
    push( @opt_parameters,
        [ "json", "print $application_id APPS.json and exit" ] );

    # Actually parse options
    #
    # Notice that I don't use GetOpt::Long - this is because it doesn't
    # support dynamically configured option lists (that I can easily discern)

    my ( $opt, $usage ) = describe_options(@opt_parameters);

    # Exit on --help
    if ( $opt->help ) {
        print( $usage->text );
        return kExitOK;
    }

    # Exit on --json
    if ( $opt->json ) {
        my $json = JSON::XS->new->ascii->pretty->allow_nonref;
        my $mref = $json->encode($app_json);
        print $mref, "\n";
        return kExitOK;
    }

    # Build JOB submit form For now, just blast entire form set into the
    # POST. Add smarts later if needed
    my %submitForm;

    # Manually force appName
    if ( $self->debug ) { print STDERR "setting softwareName\n" }
    $submitForm{'softwareName'} = $application_id;
	
	# This section has two purposes:
	# 1) Manually change the field names from lowercase to their expected casing
	#    (This may not be necessary under v2 but was under v1)
	# 2) Populate the submitForm hash with key-value pairs (still necessary!)
    foreach my $k ( keys %opt_original_names ) {
    	if (defined($opt->{$k})) {
			$submitForm{ $opt_original_names{$k} } = $opt->{$k};
			if ( $self->debug ) {
				print STDERR "$opt_original_names{$k} = $opt->{$k}\n";
			}
        }
    }

    # This is a temporary fix 05/31/2012 Basically, the iPlant DE mistakenly
    # expects this to be the output directory
    # /iplant/home/USER/analyses/NAME-DATE.PID-DATE2.PID2 but sets archivePath
    # to /iplant/home/USER/analyses/NAME-DATE.PID I need to over-ride
    # archivePath with the correct incorrect value
    if (defined($submitForm{'archivePath'})) {
		$submitForm{'archivePath'}
			= $self->temp_fix_archivepath( $submitForm{'archivePath'} );
		if ( $self->debug ) {
			print STDERR "archivePath: $submitForm{'archivePath'}\n";
		}
	}
	
    # Add in validation and limit on processorCount

    # If the app is defined as SERIAL hard-code the processorCount to 1
    if ( $self->debug ) { print STDERR "processorCount validation\n" }
    if ( $app_json->{'parallelism'} =~ /SERIAL/i ) {
        $submitForm{'processorCount'} = 1;
    }

    # If the app is defined as Parallel, enforce a maximum number of cores to
    # request (currently 1024)
    if ( $app_json->{'parallelism'} =~ /PARALLEL/i ) {
        if ( $submitForm{'processorCount'} > 1024 ) {

            print STDERR "You have tried to request more than 1024 CPUs, \n";
            print STDERR
                "which is the maximum currently allowed by our Agave API instance. Throttling\n";
            print STDERR
                "to 1024 CPUs and proceeding to run the application.\n";

            $submitForm{'processorCount'} = 1024;
        }
    }

    # Check that the executionSystem is available before 
    # accepting the job request. Note that we use executionSystem now 
    # instead of executionHost
    if ( $self->debug ) { print STDERR "get_system_status: executionSystem\n" }
    # executionSystem
    my $executionStatus
        = $self->get_system_status( $app_json->{'executionSystem'} );

    # Report error and fail if host not available
    unless ($executionStatus) {
        print STDERR $app_json->{'executionSystem'},
            " currently appears to be unavailable.\nPlease submit this job again later.\n";
        return kExitError;
    }
    
	# deploymentSystem
    if ( $self->debug ) { print STDERR "get_system_status: deploymentSystem\n" }
    my $storageStatus
        = $self->get_system_status( $app_json->{'deploymentSystem'} );

    # Report error and fail if host not available
    unless ($storageStatus) {
        print STDERR $app_json->{'deploymentSystem'},
            " currently appears to be unavailable.\nPlease submit this job again later.\n";
        return kExitError;
    }

    # Build the request.
    my $request = POST( "$TRANSPORT://" . $self->hostname . "/$JOBS_END/",
        \%submitForm );

    # If we're debugging, print the request content.
    if ( $self->debug ) {
        print STDERR "curl POST form\n";
        print STDERR $request->content(), "\n";
    }
	
	# This exit will stop the application right before a job is posted to the service
	#exit 1;
	
    # Submit form via POST to JOB service
    my $ua  = _setup_user_agent($self);
    my $job = $ua->request($request);

    # Interpret result
    if ( $job->is_success ) {
        my $message = $job->content;
        my $mref;
        my $json = JSON::XS->new->allow_nonref;
        $mref = $json->decode($message);
        return $mref->{'result'}->{'id'};
    }
    else {
        print STDERR $job->status_line, "\n";
        print STDERR $job->content,     "\n";
        return kExitError;
    }

}

sub temp_fix_archivepath {

    my ( $self, $orig_path ) = @_;
	
	if (defined($orig_path)) {
	
    my @z = split( "/", $orig_path );
    my $fname = pop(@z);
        
		my $analyses_path = join( "/", @z );

		my $url
			= "$TRANSPORT://" . $self->hostname . "/" . $IO_END . $analyses_path;

		print STDERR $url, "\n";

		my $ua  = _setup_user_agent($self);
		my $req = HTTP::Request->new( GET => $url );
		my $res = $ua->request($req);

		# Parse response
		my $message;
		my $mref;
		my $json = JSON::XS->new->allow_nonref;

		if ( $res->is_success ) {
			$message = $res->content;
			$mref    = $json->decode($message);

			# mref in this case is an array reference
			# Iterate over the filenames, comparing to $fname
			my $new_path = $orig_path;
			for my $i ( @{ $mref->{'result'} } ) {

				my $n = $i->{'name'};
				if ( $n =~ /^$fname\-/ ) {
					$new_path = $analyses_path . "/" . $n;
					last;
				}

			}

			return $new_path;
		}
		else {
			print STDERR $res->status_line, "\n";
			return $orig_path;
		}
	
	}
	
    return $orig_path;
}

sub get_system_status {
	
	# This assumes that the status reported by /systems is accurate. Some XSEDE systems
	# do not report transient outages

    # Return boolean 1 for up, 0 for down
    my ( $self, $exec_host ) = @_;

    my $ua = _setup_user_agent($self);
    my $req
        = HTTP::Request->new( GET => "$TRANSPORT://"
            . $self->hostname
            . "/$SYSTEMS_END/$exec_host" );

    print STDERR "Checking that $exec_host is accepting job submissions\n";

    # Parse response
    my $message;
    my $mref;
    my $json = JSON::XS->new->allow_nonref;

    # Try up to kMaxStatusRetries times to reach systems endpoint
    my $sleeptime = 5;
    for ( my $x = 0; $x < kMaxStatusRetries; $x++ ) {

        # Issue the request
        my $res = $ua->request($req);

        if ( $res->is_success ) {
            
            $message = $res->content;
            $mref    = $json->decode($message);
			print STDERR $mref->{'result'}->{'name'}, " status was ", $mref->{'result'}->{'status'}, "\n";
			
            if ( $mref->{'result'}->{'status'} =~ /UP/i ) {
                return 1;
            }
            else {
                return 0;
            }
        }
        else {

            print STDERR
                "$SYSTEMS_END/$exec_host\tERROR\tre-poll: $sleeptime", "s\n";
            sleep $sleeptime;

        # Wait longer before checking again. This is a load-smoothing behavior
            $sleeptime = $sleeptime * 1.5;
            if ( $sleeptime > kMaximumSleepSeconds ) {
                $sleeptime = kMaximumSleepSeconds;
            }
        }

    }

    print STDERR
        "$SYSTEMS_END was never reachable, so we must assume catastrophic failure.\n";
    return kExitError;

}

sub _poll_job_until_done_or_dead {

    # input: JOB ID from a submission instance
    # result: exit code 0 or 1
    # error: die
    my ( $self, $job_id ) = @_;

    my $current_status = 'UNDEFINED';
    my $new_status     = 0;
    my $new_message    = "";
    my $new_status_ref;
    my $baseline_sleeptime = 5;
    my $sleeptime          = $baseline_sleeptime;

    # This Loop only exits on error with ascertaining job status
    # There's code inside to exit based on the actual job status
    while ( $new_status ne kExitError ) {

        $new_status_ref = $self->job_get_status($job_id);

        $new_status  = $new_status_ref->[0];
        $new_message = $new_status_ref->[1];

        # If status changes, reset sleep time
        if ( $new_status ne $current_status ) {
            $sleeptime      = $baseline_sleeptime;
            $current_status = $new_status;
        }

        print STDERR
            "$JOBS_END/$job_id\t$current_status\tre-poll: $sleeptime", "s\n";

       # Define the statuses that will result in exit from the polling routine
       # along with their exit codes
        if ( $current_status eq 'FINISHED' ) {
            return kExitOK;
        }
        elsif ( $current_status eq 'FAILED' ) {
            print STDERR "\t$new_message", "s\n";
            return kExitJobError;
        }
        elsif ( $current_status eq 'KILLED' ) {
            print STDERR "\t$new_message", "s\n";
            return kExitJobError;
        }

        # I didn't exit, so sleep and poll again later
        sleep $sleeptime;

        # Increment sleeptime to wait longer before checking again.
        # This is a load-smoothing behavior
        $sleeptime = int( ( $sleeptime * 1.25 ) + 0.5 );
        if ( $sleeptime > kMaximumSleepSeconds ) {
            $sleeptime = kMaximumSleepSeconds;
        }

    }

    return kExitJobError;

}

sub job_get_status {

    # Returns an array - text literal status and message
    my ( $self, $job_id ) = @_;

    my $ua  = _setup_user_agent($self);
    
    #print STDERR "$TRANSPORT://" . $self->hostname . "/$JOBS_END/$job_id", "\n";
    #exit 1;
    
    my $req = HTTP::Request->new(
        GET => "$TRANSPORT://" . $self->hostname . "/$JOBS_END/$job_id" );

    # Parse response
    my $message;
    my $mref;
    my $json = JSON::XS->new->allow_nonref;

    # Try up to kMaxStatusRetries times to reach job status endpoint
    my $sleeptime = 30;
    for ( my $x = 0; $x < kMaxStatusRetries; $x++ ) {

        # Issue the request
        my $res = $ua->request($req);

        if ( $res->is_success ) {
            $message = $res->content;
            $mref    = $json->decode($message);
            my @payload = (
                $mref->{'result'}->{'status'},
                $mref->{'result'}->{'message'}
            );
            return \@payload;
        }
        else {

            print STDERR "$JOBS_END/$job_id\tERROR\tre-poll: $sleeptime",
                "s\n";
            sleep $sleeptime;

        # Wait longer before checking again. This is a load-smoothing behavior
            $sleeptime = $sleeptime * 1.5;
            if ( $sleeptime > kMaximumSleepSeconds ) {
                $sleeptime = kMaximumSleepSeconds;
            }
        }

    }

    print STDERR
        "$JOBS_END/$job_id was never reachable, so we must assume catastrophic failure.\n";
    return kExitError;

}

sub apps_fetch_description {

    # 03/14/12 - Updated to return more explicit error state via STDERR
    # and to handle HTTP and ACL errors differently
    #
    # 11/06/12 - Updated to only search the apps endpoint as the /share/name is
    # deprecated in the recent Agave services update

    # input: fully-qualified APPS API name
    # result: message body from APPS query
    # error: die
    my ( $self, $app ) = @_;

    my $ua = _setup_user_agent($self);
    my ( $req, $res, $fail_status );

    # Search order has been reversed to favor private over public apps
    # Use an array to allow searching multiple apps endpoints
    # As of 0.3.0 we use only one
    #
    foreach my $ep ( $APPS_END ) {

        # Null hypothesis is that there has been no failure
        $fail_status = 0;
        my $url
            = "$TRANSPORT://"
            . $self->hostname . "/$ep/"
            . $self->application_id;
        $req = HTTP::Request->new( GET => $url );
        $res = $ua->request($req);

        my $message;
        my $mref;
        my $json = JSON::XS->new->allow_nonref;

        if ( $res->is_success ) {
            $message = $res->content;
            my $fname = "appid_" . $self->application_id . ".$$.json";
            if ( $self->debug ) {
            	open(JSON, ">$fname");
            	print JSON $res->content, "\n";
            	close JSON;
            }
            
            $mref = $json->decode($message);

            # fail_status is now 1, but this will be ignored if I am
            # able to successfully return a message body
            $fail_status = 1;

            # Return the message body if we can confirm it has a known
            # slot 'available' in it.
            #if ( defined( $mref->{'result'}->[0]->{'available'} ) ) {
            #    return $mref->{'result'}->[0];
            #}
        	# Return the message body if we can confirm it has a known
            # slot 'available' in it.
            if ( defined( $mref->{'result'}->{'available'} ) ) {
                return $mref->{'result'};
            }
            
        }
        else {

            # fail_status is now 2
            # This means the HTTP action was not successful at all
            $fail_status = 2;
        }

    }

    if ( $fail_status == 1 ) {
        print STDERR "Application ", $self->application_id,
            " was not found\n";
        print STDERR
            "Either an incorrect application key has been provided\n";
        print STDERR
            "or the invoking user does not have permission to execute\n";
        print STDERR "the application.\n";
    }
    elsif ( $fail_status == 2 ) {
        print STDERR
            "An HTTP error has been returned during application auto-\n";
        print STDERR
            "configuration. This may be a temporary issue. Please try\n";
        print STDERR
            "the submission again or contact support\@iplantcollaborative.org\n";
    }

    # Only return an exit status if no message body could be returned.
    return kExitError;
}

sub apps_search {
    print STDERR "apps_search\n";
    return 0;
}

# Transport-level Methods
sub _setup_user_agent {

    my $self = shift;
    my $ua   = LWP::UserAgent->new;

    $ua->agent($AGENT);
    if ( ( $self->user ne '' ) and ( $self->token ne '' ) ) {

        $ua->default_header( Authorization => 'Basic '
                . _encode_credentials( $self->user, $self->token ) );
    }
    else {
        if ( $self->debug ) {
            print STDERR ( caller(0) )[3],
                ": Sending no authentication information\n";
        }
    }

    return $ua;

}

sub _encode_credentials {

    # u is always an iPlant username
    # p can be either a password or RSA encrypted token

    my ( $u, $p ) = @_;
    my $encoded = encode_base64("$u:$p");
    return $encoded;

}

sub _configure_auth_from_opt {

    # Allows user to specify username/password (unencrypted)
    # Uses this info to hit the auth-v1 endpoint
    # fetch a token and cache it as the global token
    # for this instance of the application

    my ( $self, $opt1 ) = @_;

    if ( $opt1->user and $opt1->password and not $opt1->token ) {

        # set global.user global.password
        $self->user( $opt1->{'user'} );
        $self->password( $opt1->{'password'} );

        # hit auth service for a new token
        my $newToken = $self->auth_post_token();
        print "Issued-Token: ", $newToken, "\n";

        $self->password(undef);

        # set global.token
        $self->token($newToken);

    }
    elsif ( $opt1->user and $opt1->token and not $opt1->password ) {

        $self->user( $opt1->user );
        $self->token( $opt1->token );

    }
    else {
        if ( $self->debug ) {
            print STDERR ( caller(0) )[3],
                ": Defaulting to pre-configured values\n";
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
    $ua->default_header( Authorization => 'Basic '
            . _encode_credentials( $self->user, $self->password ) );

    my $url = "$TRANSPORT://" . $self->hostname . "/$AUTH_END/";
    my $req = HTTP::Request->new( POST => $url );
    my $res = $ua->request($req);

    my $message;
    my $mref;
    my $json = JSON::XS->new->allow_nonref;

    if ( $res->is_success ) {
        $message = $res->content;
        $mref    = $json->decode($message);
        if ( defined( $mref->{'result'}->{'token'} ) ) {
            return $mref->{'result'}->{'token'};
        }
    }
    else {
        print STDERR ( caller(0) )[3], " ", $res->status_line, "\n";
        return undef;
    }

}

sub io_list {

    # List iRODS directory
    my $self = shift;

    # return kExitOK to allow app to exit
    my @opt_parameters = ("$0 list %o");

    if ( $self->credential_class ne 'proxied' ) {
        push( @opt_parameters, [ 'user=s',     "iPlant username" ] );
        push( @opt_parameters, [ 'password=s', "iPlant password" ] );
        push( @opt_parameters, [ 'token=s',    "iPlant secure token" ] );
        push( @opt_parameters, [] );
    }
    else {
        push(
            @opt_parameters,
            [   'proxy_user=s',
                "iPlant username to proxy [" . $self->{'user'} . "]"
            ]
        );
        push( @opt_parameters, [] );
    }

    push( @opt_parameters, [ 'path=s', "Path relative to \$IPLANT_HOME" ] );

    # Eventually support a tree view of the file system, but
    # not until the service can support a depth-specified recursive walk
    # because I don't want to hit the service for each directory
    #push(@opt_parameters, ['recursive',"Return a recursive view [false]"]);
    push( @opt_parameters, [] );
    push( @opt_parameters, [ 'help', "Print help and exit" ] );

    my ( $opt, $usage ) = describe_options(@opt_parameters);
    if ( $self->credential_class ne 'proxied' ) {
        if ( _configure_auth_from_opt( $self, $opt ) == 0 ) {
            return kExitError;
        }
    }

    # Exit on --help
    if ( $opt->help ) {
        print( $usage->text );
        return kExitOK;
    }

    # Check for --path
    unless ( defined( $opt->path ) ) {
        print STDERR
            "Please specify iPlant Data Store path using --path\n";
        return kExitError;
    }

    my $ua = _setup_user_agent($self);
    my $req
        = HTTP::Request->new( GET => "$TRANSPORT://"
            . $self->hostname . "/"
            . $IO_END
            . $opt->path );
    my $res = $ua->request($req);

    print "\n$TRANSPORT://" . $self->hostname . "/" . $IO_END . $opt->path,
        "\n";

    # Parse response
    my $message;
    my $mref;
    my $json = JSON::XS->new->allow_nonref;

    if ( $res->is_success ) {
        $message = $res->content;
        if ( $self->debug ) {
            print STDERR $message, "\n";
        }
        $mref = $json->decode($message);

        # mref in this case is an array reference
        _display_io_list_reference( $mref->{'result'} );
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
    foreach my $f ( @{$ref} ) {

        # name
        print $f->{'name'};

        # append slash if folder
        if ( $f->{'format'} =~ /folder/ ) {
            print "/";
            print "\t0";
        }
        else {

            # print size in kB
            print "\t", _human_readable_bytes( $f->{'length'} );
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
    my $bytes       = shift;
    my $suffix      = '';
    my @suffixes    = qw(b K M G T P E);
    my $i_converted = 0;

    for ( my $x = 1; $x <= $#suffixes; $x++ ) {
        if ( $bytes / ( 1024**$x ) >= 1.0 ) {
            $bytes  = $bytes / 1024;
            $suffix = $suffixes[$x];
            $i_converted++;
        }
    }

    if ($i_converted) {
        $bytes = sprintf( "%0.0f", $bytes );
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

    my ( $self, $u, $p, $cclass ) = @_;
    $self->{user}             = $u;
    $self->{token}            = $p;
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

iPlant::foundation-v2 - Perl extension for interacting with the iPlant Foundational API.

=head1 SYNOPSIS

  use iPlant::foundation-v2;
  my $api_instance->new();
  # You can use this in a script to hard-code an application ID
  # This lets you create local emulator apps that invoke remote HPC jobs
  # If you omit this, you can pass in the application ID as --appid
  $api_instance->application_id('head-1.0'); # id returned by /apps-v1/apps discovery endpoint
  $api_instance->invoke();

=head1 DESCRIPTION

This module is designed to allow calls to applications deployed in the iPlant
Foundational API to be executed as though the applications were local to the
user's machine. In addition, utility functions are included to allow
application discovery, listing of iPlant Cloud Storage directories, and
creation of JSON template code for describing a UI for the application in the
iPlant Discovery Environment.

=head2 EXPORT

None by default.

=head2 Application Usage

application.pl run|search|list|authenticate --options

	search --name <name> --tag <tag> 
		--id <id> [--authentication]

	list --path <iRODS path relative to 
		$IRODS_HOME> [--authentication]

	run --options --appid <id> [--application-specific options] 
		[--authentication]

	authenticate [--authentication]

=head2 Authentication

iPlant offers a secure, ACL-based cyberinfrastructure, and so many
interactions with its services require user authentication. Any of the
commands (run|search|list) can be extended at run-time with either a
combination of iPlant username (--user) and password (--password) OR your
iPlant secure authentication token (--token). We recommend the latter. If you
supply both sets of credentials, the secure token method takes precedence.

In addition, to faciliate scripting access (or for simple convenience), you
may store your credentials in an .iplant.foundation-v2.json file. This will
be read at run-time from (in order): /etc/iplant.foundation-v2.json
~/.iplant.foundation-v2.json
~/Library/Preferences/iplant.foundation-v2.json
./iplant.foundation-v2.json. If the same value is specified twice, the most
recently read one takes precedence. In addition, command-line parameters (see
above) take precedence over file-configured options. An example configuration
file (sample.iplant.foundation-v2.json can be found associated with this
module.

=head2 Commands

The first option after the name of the script (application.pl for example) is
a verb indicating which mode the application should run in. This module
current supports four modes: list, search, and run, authenticate.

=head3 List

Invoking "list --path <irods_path>" allows the user to list his/her own
storage directory (and its subdirectories) or any other directories to which
the user has been granted at least read permission. This includes other user's
directories as well as any public or any-user directories in the
/iplant/home/community space.

Example: application.pl list --path /vaughn

=head3 Search

The search command allows users to query the public and user-specific lists of
deployed JOBS API applications by name. The result is a list of application
names, short descriptions, and (most importantly) the unique token identifying
that application so that it can be set via the
iPlant::foundation-v2->application_id() method allowing execution of
instances of that application on remote resources.

Search first accesses the public APPS directory, and if nothing matching the
query is found, the list of applications shared with the user is queried. In
the case of namespace conflict (which should be impossible), the public
application will be returned.

Example: application.pl search --name "uniq-1.0"

*NOT CURRENTLY IMPLEMENTED*

=head3 Authenticate

Invoking authenticate --user <username> --password <password> with valid
iPlant credentials will issue a new secure token for you and will print that
token to STDOUT. It may be used in subsequent operations in lieu of your
plaintext password.

=head3 Run

This is the central function of iPlant::foundation-v2. When the module is
configured with an appropriate iPlant Agave application ID (to which the
invoking user has access), a program built using the module first accesses the
APPS API description for $application_id and uses it to dynamically configure
a set of command line options. Command line options from the user are then
matched against these options to build a JOBS submission. Assuming all
required parameters have been specified, the submission is then POSTed to the
JOBS API endpoint. The application then monitors the status of the submitted
job via the JOBS API, printing the status of the job to STDERR at periodic
intervals. Once the remote job reports either entered the COMPLETE or FAILED
status, the application exits with status 0 or 1, respectively. These exit
codes allow callers of the iPlant::foundation-v2 to detect the final
dispensation of the 'run' command and its associated job.

=head4 System Parameters for Job Submission

=over

=item --appid [String]

iPlant Agave application ID. If not specified here or in calling script, 'run'
will fail

=item --processorCount [Integer]

The number of processors for a parallel job. This can be specified by default
in an .iplant.foundation-v2.json file using the token 'processors'

=item --maxMemory [xGB]

The maximum amount of memory required by your job. Default

=item --requestedTime [HH::MM:SS]

The estimated time required for the job to run. Default 01:00:00. This can be
specified by default in an .iplant.foundation-v2.json file using the token
'run_time'

=item --callbackUrl []

A URL that will be invoked upon completion of the remote job. Supplying an
email address will result in an email being sent.

=item --jobName [Random string]

A human-readable name for user's remote job

=item --archive [Flag]

Pass this flag to enable archiving of the job results to your $HOME folder

=item --archivePath [/<path>]

Define a path to which the output of a remote job will be staged. Default is
/<username>

=back

=head4 Utility Functions

=over

=item *

application.pl run --help will print the entire list of system,
authentication, and remote application-specific options (and their defaults if
known) to the screen in a standard usage screen.

=item *

application.pl run --json will pretty-print the APPS JSON description for
$application_id to STDOUT

=back

=head1 SEE ALSO

No information here now.

=head1 AUTHOR

Matthew W. Vaughn, E<lt>vaughn@iplantcollaborative.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2011-2013 by Matthew Vaughn

See included LICENSE file

=cut
