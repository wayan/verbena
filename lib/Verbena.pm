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
        ? merge_containers(
        $container,
        bless(
            { sub_containers => $sub_containers, },
            'Verbena::Container::SubContainers'
        ),
        )
        : $container;
}

sub merge_containers {
    state $params_check
        = Type::Params::compile( slurpy( ArrayRef [$ContainerType] ) );
    my ($containers) = $params_check->(@_);
    return
        bless( { containers => $containers, }, 'Verbena::Container::FirstFrom' );
}

# lazy container - evaluated when first needed
sub container_lazy {
    state $params_check = Type::Params::compile(CodeRef);
    my ($builder) = $params_check->(@_);
    return bless( { builder => $builder, }, 'Verbena::Container::Lazy' );
}

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

    package Verbena::Container::FirstFrom;

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

# vim: expandtab:shiftwidth=4:tabstop=4:softtabstop=0:textwidth=78:
