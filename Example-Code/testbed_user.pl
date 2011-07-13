#!/usr/bin/perl

use strict;
use warnings;
use iPlant::FoundationalAPI;

my $api_instance = iPlant::FoundationalAPI->new();

# Set debug to zero
$api_instance->debug(0);

# Example of hard-coding application ID so we can implement 'run' command
# $api_instance->application_id('wc-0.10');

$api_instance->invoke();

=head1 NAME testbed_user.pl

Learn to use the interface:

perl testbed_user.pl run|list|authenticate|search --user <u> --password <p> --token <t> --appid <id> --help

=cut