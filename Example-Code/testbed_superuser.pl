#!/usr/bin/perl

use strict;
use warnings;
use iPlant::FoundationalAPI;
use iPlant::SuperAuthenticate;

my $auth_instance = iPlant::SuperAuthenticate->new();
my $api_instance = iPlant::FoundationalAPI->new();

# Make proxied user request
my $token = $auth_instance->proxy();

# Set debug to zero
$api_instance->debug(0);
# Configure credentials for api_instance
$api_instance->set_credentials($auth_instance->delegate_user, $auth_instance->delegate_token, 'proxied');

# Hard-set the APPS application ID
# $api_instance->application_id('wc-0.10');
$api_instance->invoke();

=head1 NAME testbed_user.pl

Learn to use the interface

1) Drop a copy of iplant.superauthenticate.json into either /etc or the same directory as testbed_superuser.pl
2) Configure it so that its credentials are those of the ipcservices superuser
3) perl testbed_superuser.pl run|list|authenticate|search --proxy_user <u> --help

If the module is properly configured and super-credentials are availble, the following will work:

perl testbed_superuser.pl run --proxy_user vaughn --help --appid wc-0.10
Application_Id: wc-0.10
testbed_superuser.pl [long options...]
	--appid                 iPlant HPC application ID []
	                      
	--proxy_user            iPlant username to proxy [vaughn]
	                      
	--processorCount        Processor Count [1]
	--maxMemory             Maximum memory required
	--requestedTime         Estimated run time HH::MM::SS [01:00:00]
	--callbackUrl           Callback URL
	--jobName               Job name
	--archivePath           Archive Path
	--archive               Archive results [true]
	                      
	--query1                FASTQ file #1 [/vaughn/read.1.fq]
	                      
	--printLongestLine      Print the length of the longest line [false]
	                      
	--usage --help          print usage and exit
	--json                  print wc-0.10 APPS.json and exit
	--tito                  print wc-0.10 Tito.json and exit

And so will this:

perl testbed_superuser.pl list --proxy_user vaughn --path /vaughn/

This will not (circular logic):

perl testbed_superuser.pl authenticate --proxy_user vaughn

=cut