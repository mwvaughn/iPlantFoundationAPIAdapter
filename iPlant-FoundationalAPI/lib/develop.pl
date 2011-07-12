#!/usr/bin/perl

use strict;
use warnings;

use iPlant::FoundationalAPI;
use iPlant::SuperAuthenticate;

my $auth_instance = iPlant::SuperAuthenticate->new();
my $token = $auth_instance->proxy();

my $api_instance = iPlant::FoundationalAPI->new();

# Start doing work in api_instance
$api_instance->debug(0);
# Configure credentials for api_instance
$api_instance->set_credentials($auth_instance->proxied_user, $auth_instance->proxied_token);
$api_instance->application_id('wc-0.10');
$api_instance->run();
