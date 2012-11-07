use 5.006;
use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name        => 'iPlant::FoundationalAPI',
    license            => 'bsd',
    dist_author        => 'Matt Vaughn <mwvaughn@apple.com>',
    dist_version_from  => 'lib/iPlant/FoundationalAPI.pm',
    build_requires     => { 'Test::More' => 0, },
    configure_requires => { 'Module::Build' => 0.38 },
    requires           => {
        'LWP'                       => 0,
        'HTTP::Request::Common'     => 0,
        'URI::Escape'               => 0,
        'JSON::XS'                  => 0,
        'Getopt::Long::Descriptive' => 0,
        'Getopt::Long'              => 0,
        'IO::Socket::SSL'           => 1.76,
        'MIME::Base64'              => 0,
        'Mozilla::CA'               => 20120309,
        'Net::SSL'                  => 0,
        'YAML'                      => 0,
        'iPlant::SuperAuthenticate' => 0,
    },
    add_to_cleanup     => ['iPlant::FoundationalAPI-*'],
    create_makefile_pl => 'traditional',
);

$builder->create_build_script();
