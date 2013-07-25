#!/usr/bin/env perl

use strict;
use warnings;
use iPlant::FoundationalAPI;

my $api_instance = iPlant::FoundationalAPI->new();
$api_instance->debug(0);
$api_instance->application_id('dnalc-tophat-sanger-2.0.8');
$api_instance->invoke();
