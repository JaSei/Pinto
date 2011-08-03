package Pinto::Role::Configurable;

# ABSTRACT: Something that has a configuration

use Moose::Role;

use namespace::autoclean;

#-----------------------------------------------------------------------------

# VERSION

#-----------------------------------------------------------------------------

has config => (
    is       => 'ro',
    isa      => 'Pinto::Config',
    required => 1,
);

#-----------------------------------------------------------------------------

1;

__END__
