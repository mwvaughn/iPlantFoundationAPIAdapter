#!/usr/bin/perl

use strict;
use warnings;

use iPlant::SuperAuthenticate;

my $auth_instance = iPlant::SuperAuthenticate->new();
my $token = $auth_instance->proxy();

print STDERR $auth_instance->delegate_user, ":", $auth_instance->delegate_token, "\n";
