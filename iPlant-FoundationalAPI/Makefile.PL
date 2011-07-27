use 5.008000;
use ExtUtils::MakeMaker;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME         => 'iPlant::FoundationalAPI',
    VERSION_FROM => 'lib/iPlant/FoundationalAPI.pm',
    PREREQ_PM    => {
        'LWP'                       => 0,
        'HTTP::Request::Common'     => 0,
        'URI::Escape'               => 0,
        'JSON::XS'                  => 0,
        'Getopt::Long::Descriptive' => 0,
        'Getopt::Long'              => 0,
        'YAML'                      => 0,
        'MIME::Base64'              => 0,
        'Net::SSL'                  => 0,
        'iPlant::SuperAuthenticate' => 0,
    },
    (   $] >= 5.005
        ? ( ABSTRACT_FROM => 'lib/iPlant/FoundationalAPI.pm',
            AUTHOR        => 'Matt Vaughn <mwvaughn@apple.com>'
            )
        : ()
    ),
);
