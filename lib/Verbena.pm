package Verbena;

use common::sense;

# ABSTRACT: tiny dependency injection container

use List::Util qw(reduce pairmap first pairkeys);
use Ref::Util qw(is_coderef);
use Types::Standard
    qw(HasMethods CodeRef Str ArrayRef HashRef Optional slurpy);
use Type::Params ();
use Carp qw(confess);

use Exporter 'import';
use Class::Load;

our @EXPORT_OK = qw(
    resolve
    svc_alias
    svc_value
    svc_pos_deps
    svc_named_deps
    svc_singleton   
    svc_singleton2
    svc_defer
    merge_containers
    container_lazy
    container
    constructor
    sub_containers
    target_resolver
);

my $ContainerType = HasMethods ['get_service'];
my $ServiceType   = CodeRef;
my $TargetType    = Str | $ServiceType;
my $default_max_depth = 20;

sub resolve {
    my ( $container, $path, $state_in ) = @_;

    # passing opaque context
    my ( $resolved, $state_out )
        = _resolve( $container,
        { ( $state_in ? %$state_in : () ), route => [] }, $path );
    return wantarray ? ( $resolved, $state_out ) : $resolved;
}

sub _resolve {
    my ( $container, $state, $path ) = @_;

    my $route = $state->{route};
    my $max_depth = $state->{max_depth} // $default_max_depth;

    if ( @$route > $max_depth ) {
        die "Going too deep with deps: ",
            join( ' => ', map {"'$_'"} @$route );
    }

    my $service = $container->get_service($path)
        or confess sprintf( "No service '%s' (%s)",
        $path, join( '=> ', map {"'$_'"} @$route, $path ) );

    my @new_route = ( @$route, $path );
    my ( $resolved, $state_out ) = $service->(
        \&_resolve, $container, { %$state, route => \@new_route }, $path
    );

    # route back
    return ( $resolved, { %$state_out, route => $route } );
}

sub svc_alias {
    state $params_check = Type::Params::compile(Str);

    my ($target) = $params_check->(@_);
    return target_resolver($target);
}

sub svc_defer {
    state $params_check = Type::Params::compile($TargetType);

    my ($target) = $params_check->(@_);
    my $resolver = target_resolver($target);
    return sub {
        my @args = @_;
        return sub { $resolver->(@args) };
    };
}

sub svc_pos_deps {
    state $params_check
        = Type::Params::compile( ArrayRef [$TargetType], CodeRef );
    my ( $deps, $block ) = $params_check->(@_);

    my $svc_deps = merge_services(
        map {
            target_resolver( $deps->[$_], "#$_" )
        } 0 .. (@$deps - 1)
    );

    # passing state
    return sub {
        my ( $dep_values, $new_state ) = $svc_deps->(@_);
        return ( scalar( $block->(@$dep_values) ), $new_state );
    };
}

sub svc_named_deps {
    state $params_check
        = Type::Params::compile( HashRef [$TargetType], CodeRef );
    my ( $deps, $block ) = $params_check->(@_);

    my @deps_kv = %$deps;
    my @dep_names = pairkeys @deps_kv;
    my $svc_deps = merge_services( pairmap { target_resolver( $b, "#$a" ); } @deps_kv);

    return sub {
        my ( $dep_values, $new_state ) = $svc_deps->(@_);

        return (
            scalar(
                $block->(
                    map { $dep_names[$_] => $dep_values->[$_] }
                        0 .. ( @dep_names - 1 )
                )
            ),
            $new_state
        );
    };
}

sub svc_value {
    my ($value) = @_;
    return sub {$value};
}

# merge services into one - state passing
sub merge_services {
    my (@svcs) = @_;

    return sub {
        my ( $resolve, $container, $state, $base ) = @_;
        my @resolved;
        my $current_state = $state;
        for my $svc (@svcs) {
            my ( $res, $state ) = $svc->( $resolve, $container, $current_state, $base );
            push @resolved, $res;
            $current_state = $state;
        }
        return ( \@resolved, $current_state );
    };
}

sub target_resolver {
    my ( $target, $dep_name ) = @_;

    if ( !ref $target ) {
        # string is an alias
        return sub {
            my ( $resolve, $container, $state, $base ) = @_;
            return $resolve->(
                $container, $state, abs_path_to_service( $target, $base )
            );
        };
    }
    elsif ( is_coderef($target) ) {
        my $suffix = $dep_name // '';
        return sub {
            my ( $resolve, $container, $state, $base ) = @_;
            return $target->( $resolve, $container, $state, "$base$suffix" );
        };
    }
    confess "Unknown type of dependency";
}

sub svc_singleton {
    my ($target) = @_;

    my $svc = target_resolver($target);
    my ( $resolved, $value );
    return sub {
        if ( !$resolved ) {
            $resolved = 1;
            $value    = $svc->(@_);
        }
        return $value;
    };
}

# immutable set state of nested key
sub _set_state {
    my ($data, $value, $key, @keys) = @_;
    return {
        %$data,
        $key => (
            @keys
            ? _set_state( $data->{$key} // {}, $value, @keys )
            : $value
        )
    };
}

# get the nested value from the state
# returns ($value) - unempty list or ()
sub _get_state {
    my ( $data, $key, @keys ) = @_;
    return
        exists $data->{$key}
        ? ( @keys ? _get_state( $data->{$key}, @keys ) : ( $data->{$key} ) )
        : ();
}

sub svc_singleton2 {
    my ($target, $key, $lifetime) = @_;

    $key   //= join( ' at ', (caller(0))[1,2]);
    $lifetime //= 'singleton';
    my $svc = target_resolver($target);
    return sub {
        my ($resolve, $container, $state, $base) = @_;
    
        if ( my ($stored) = _get_state( $state, 'lifetime', $lifetime, $key ) ) {
            return $stored;
        }
        # creating new state :-(
        my ($resolved, $new_state) = $svc->($resolve, $container, $state, $base);
        return ( $resolved, _set_state($new_state, $resolved, 'lifetime', $lifetime, $key));
    };
    
}

sub abs_path_to_service {
    my ( $target, $base ) = @_;

    return $1 if $target =~ m{^/(.*)};
    return reduce { _join_path( $a, $b ); } _dir($base), split m{/}, $target;
}

sub _dir {
    my ($path) = @_;
    die "No way up" if $path eq '';
    return $path =~ m{(.*)/} ? $1 : '';
}

sub _join_path {
    my ( $start, $part ) = @_;

    return
          $part eq '..' ? _dir($start)
        : $part eq '.'  ? $start
        : join( '', $start, ( $start ne '' ? '/' : '' ), $part );
}

# container created with sub_containers
sub sub_containers {
    state $params_check
        = Type::Params::compile( HashRef [$ContainerType] );

    my ($sub_containers) = $params_check->(@_);
    return bless(
        { sub_containers => $sub_containers },
        'Verbena::Container::SubContainers'
    );
}

sub container {
    state $params_check = Type::Params::compile( HashRef [$ServiceType],
        Optional [ HashRef [$ContainerType] ] );

    my ( $services, $sub_containers ) = $params_check->(@_);

    my $container
        = bless( { services => $services, }, 'Verbena::Container::Services' );
    return $sub_containers
        ? merge_containers( $container, sub_containers($sub_containers) )
        : $container;
}

sub merge_containers {
    state $params_check
        = Type::Params::compile( slurpy( ArrayRef [$ContainerType] ) );
    my ($containers) = $params_check->(@_);
    return
        bless( { containers => $containers, }, 'Verbena::Container::Merged' );
}

# lazy container - evaluated when first needed
sub container_lazy {
    state $params_check = Type::Params::compile(CodeRef);
    my ($builder) = $params_check->(@_);
    return bless( { builder => $builder, }, 'Verbena::Container::Lazy' );
}

sub constructor {
    state $params_check = Type::Params::compile( Str, Optional [Str] );

    my ( $class, $method_arg ) = $params_check->(@_);
    my $method = $method_arg // 'new';

    my $loaded;
    return sub {
        if ( !$loaded ) {
            Class::Load::load_class($class);
        }
        return $class->$method(@_);
    };
}


# Simple classes for different types of containers
{

    package Verbena::Container::SubContainers;

    use List::Util qw(pairmap);

    sub get_service {
        my ( $this, $path ) = @_;

        my @parts = split m{\/}, $path, 2;
        if ( @parts == 2 ) {
            if ( my $sub_container = $this->{sub_containers}{ $parts[0] } ) {
                return $sub_container->get_service( $parts[1] );
            }
        }
        return undef;
    }

    sub services {
        my ($this) = @_;

        return pairmap {
            my $prefix = $a;
            map { "$prefix/$_"; } $b->services;
        }
        %{ $this->{sub_containers} };
    }
}

# implementation of the containers
{

    package Verbena::Container::Services;

    sub get_service {
        my ( $this, $path ) = @_;
        return $this->{services}{$path};
    }

    sub services {
        my ($this) = @_;
        return keys %{ $this->{services} };
    }
}

{

    package Verbena::Container::Merged;

    use List::MoreUtils qw(uniq);

    sub get_service {
        my ( $this, $path ) = @_;

        for my $container ( @{ $this->{containers} } ) {
            my $service = $container->get_service($path);
            return $service if $service;
        }
        return;
    }

    sub services {
        my ($this) = @_;

        return uniq( map { $_->services } @{ $this->{containers} } );
    }
}

{

    package Verbena::Container::Lazy;

    sub _container {
        my $this = shift;
        return $this->{container} //= $this->{builder}->();
    }

    sub get_service {
        my ( $this, $path ) = @_;

        return $this->_container->get_service($path);
    }

    sub services {
        my ($this) = @_;

        return $this->_container->services;
    }
}

1;

__END__

=head1 SYNOPSIS

=head1 DESCRIPTION

=head2 Container

Container is an object with method C<< get_service($path) >> which returns
a service for given path.

All the containers returned by the functions from this library have also
method C<< services() >> which returns all available paths of the container.

=head2 Service

Service is an anonymous subroutine which returns a component of your
application addressed by a path. The service is (so far) called as

    $service->($resolve, $container, $state, $path)

The parameters are:

=over 4

=item C<< $resolve >>

The anonymous subroutine which can be used to resolve the dependencies of the service.

=item C<< $container >>

The container which was passed to resolve. 

=item C<< $state >>

The structure (opaque for most services) containing the state of resolving ().

=item C<< $path >>

The path of currently resolved. It must be noted the path is passed, it is not
part of the service. It means that the exactly the same service (the coderef)
can be used for different paths in the container.

=back

The service is supposed to return two values list C<< ($resolved, $new_state) >>


=head1 FUNCTIONS

=over 4 

=item B<< resolve( $container, $path, [ $state ] ) >>

Finds the service from a container for a path and resolve its value. 
Throws an exception if there is no such service. Called in
scalar context returns the resolved value, called in list context
returns 2 elements list (C<< $resolved, $new_state >>).

The optional argument state is a structure returned by previous resolve.

=item

=back

=head2 Functions returning containers

=over 4

=item B<< container({ $path=>$service, $path=>$service, ... }) >>

Returns a container - plain lookup of services. Given a path returns
the stored service.

=item B<< sub_container({ $name=>$container, $name=>$container, ... }) >>

Returns a container - hierarchical lookup of services. The 
C<< get_service($path) >> method splits the path on first slash (C<< / >>), 
gets container for the first part and ask it for a service passing the
second part of the original path.

=item B<< merge_containers($container, $container, ... ) >>

Returns a container containing services from a set of other containers.
The C<< get_service($path) >> method returns the service from first
container which contains the path. 

=item B<< container_lazy(&container_builder) >>

Returns a lazily evaluated container. The builder is an anonymous subroutine,
which must return a container. This builder is called once for the
first time C<< get_service($path) >> is called.

=back

=head2 Functions returning services

=over 4

=item B<svc_value($any)>

When resolved returns the value unchanged. 

=item B<< svc_alias($path) >>

When resolved returns the value of service addressed by the path.
The path may be either absolute (starting with slash) or relative.
When absolute the leading slash is removed and the path is used.
When relative then the path is "absolutized" according to the 
path of the service alias.

=item B<svc_pos_deps([ $target, ...], \&block)>

Positional dependencies. When resolved, resolve all targets first and then
calls the block with a list of resolved values. Each target can be either 
path or a service.

=item B<< svc_named_deps({ key=>$target, key=>$target }, \&block) >>

Named dependencies. When resolved, resolve all targets first and then
calls the block with a list of key value pairs, where keys are the original
keys and values are the resolved values. Each target can be either a
path or a service.

=item B<< svc_defer($target) >>

Lazily evaluated service. Returns not the resolution, but an anonymous
subroutine which, when called (everytime), resolves the target.


=back


=cut

# vim: expandtab:shiftwidth=4:tabstop=4:softtabstop=0:textwidth=78:


