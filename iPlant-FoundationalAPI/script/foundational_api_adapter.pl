#!perl

use warnings;
use strict;

use Carp;
use English qw(-no_match_vars);
use Getopt::Long;
use iPlant::FoundationalAPI;
use iPlant::SuperAuthenticate;

# Set the version.
my $VERSION = '0.0.1';

# Configure Getopt::Long.
Getopt::Long::Configure("pass_through");

# Variable for command-line options.
my $debug = 0;

# Load command-line options.
GetOptions( 'debug|d' => \$debug );

# Get the object instances that will be used to submit the request.
my $auth = iPlant::SuperAuthenticate->new();
my $api  = iPlant::FoundationalAPI->new();

# Either enable or disable debugging.
$api->debug($debug);

# Create the proxy token.
$auth->proxy();

# Tell the Foundational API adapter instance to use proxied authentication.
my $delegate_user  = $auth->delegate_user();
my $delegate_token = $auth->delegate_token();
$api->set_credentials( $delegate_user, $delegate_token, 'proxied' );

# Invoke the service.
my $api->invoke();

exit;
__END__

=head1 NAME

foundational_api_adapter.pl – script to submit jobs to the Foundational API.

=head1 VERSION

This documentation refers to foundational_api_adapter version 0.0.1.

=head1 USAGE

    foundational_api_adapter.pl run --appid=wc-0.11 --proxy_user=ipctest \ 
        --printLongestLine --query1=/ipctest/somefile.txt

=head1 REQUIRED ARGUMENTS

=over 2

=item command

The command to execute.  Some examples of valid commands are C<run> and
C<help>.

=item --appid

The application ID.  A list of valid application IDs can be obtained from
L<https://foundation.iplantc.org/apps-v1/apps/list>.

=item --proxy_user

The name of the user that we're performing the experiment for.

=head1 DESCRIPTION

Submits jobs to the Foundational API for execution.  See
L<iPlant::FoundationalAPI> and L<iPlant::SuperAuthenticate> for additional
information.

=head1 BUGS AND LIMITATIONS

There are no known bugs in this script. Please report problems to the iPlant
Collaborative.  Patches are welcome.
