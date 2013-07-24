#!/usr/bin/env perl

use strict;
use warnings;
use iPlant::FoundationalAPI;

my $api_instance = iPlant::FoundationalAPI->new();
$api_instance->debug(0);
$api_instance->application_id('dnalc-fastqc-sanger-0.10.1');
$api_instance->invoke();
