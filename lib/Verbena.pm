package Verbena;

use common::sense;

# ABSTRACT: tiny dependency injection container

use List::Util qw(reduce pairmap first);
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
    svc_defer
    loc_first
    container_lazy
    container
    constructor
    sub_containers
    target_resolver
);

my $ContainerType = HasMethods ['fetch'];
my $ServiceType   = CodeRef;
my $TargetType    = Str | $ServiceType;

sub resolve {
    my ( $container, $path, $status ) = @_;

    # passing opaque context
    return _resolve( $container, { route => [] }, $path );
}

sub _resolve {
    my ( $container, $status, $path ) = @_;

    my $route = $status->{route};
    if ( @$route > 10 ) {
        die "Going too deep with deps: ", join( '=> ', map {"'$_'"} @$route );
    }

    my $service = $container->fetch($path)
        or confess sprintf("No service '%s' (%s)", $path, join('=> ', map { "'$_'"} @$route, $path));

    my @new_route = ( @$route, $path );
    my $resolver = sub {
        my ($path) = @_;
        return _resolve( $container, { %$status, route => \@new_route },
            $path );
    };
    return $service->( $resolver, $path );
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

    my $i         = 0;
    my @resolvers = map {
        my $idx = $i++;
        target_resolver( $_, "#$idx" )
    } @$deps;

    return sub {
        my @args = @_;
        return $block->( map { $_->(@args) } @resolvers );
    };
}

sub svc_named_deps {
    state $params_check
        = Type::Params::compile( HashRef [$TargetType], CodeRef );
    my ( $deps, $block ) = $params_check->(@_);

    my @resolvers
        = pairmap { ( $a => target_resolver( $b, "#$a" ) ); } %$deps;

    return sub {
        my @args = @_;
        return $block->( pairmap { ( $a => $b->(@args) ); } @resolvers );
    };
}

sub svc_value {
    my ($value) = @_;
    return sub {$value};
}

sub target_resolver {
    my ( $target, $dep_name ) = @_;

    if ( !ref $target ) {
        return sub {
            my ( $resolver, $base ) = @_;
            return $resolver->( abs_path_to_service( $target, $base ) );
        };
    }
    elsif ( is_coderef($target) ) {
        my $suffix = $dep_name // '';
        return sub {
            my ( $resolver, $base ) = @_;
            return $target->( $resolver, "$base$suffix" );
        };
    }
    confess "Unknown type of dependency";
}

sub svc_singleton {
    my ($target) = @_;

    my $resolver = target_resolver($target);
    my ( $resolved, $value );
    return sub {
        if ( !$resolved ) {
            $resolved = 1;
            $value    = $resolver->(@_);
        }
        return $value;
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

    my ( $services, $sub_containers ) = @_;

    my $container
        = bless( { services => $services, }, 'Verbena::Container::Services' );
    return $sub_containers
        ? loc_first(
        $container,
        bless(
            { sub_containers => $sub_containers, },
            'Verbena::Container::SubContainers'
        ),
        )
        : $container;
}

sub loc_first {
    state $params_check
        = Type::Params::compile( slurpy( ArrayRef [$ContainerType] ) );
    my ($locators) = $params_check->(@_);
    return
        bless( { locators => $locators, }, 'Verbena::Container::FirstFrom' );
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

    sub fetch {
        my ( $this, $path ) = @_;

        my @parts = split m{\/}, $path, 2;
        if ( @parts == 2 ) {
            if ( my $sub_container = $this->{sub_containers}{ $parts[0] } ) {
                return $sub_container->fetch( $parts[1] );
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

    sub fetch {
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

    sub fetch {
        my ( $this, $path ) = @_;

        for my $locator ( @{ $this->{locators} } ) {
            my $service = $locator->fetch($path);
            return $service if $service;
        }
        return;
    }

    sub services {
        my ($this) = @_;

        return uniq( map { $_->services } @{ $this->{locators} } );
    }
}

{

    package Verbena::Container::Lazy;

    sub _container {
        my $this = shift;
        return $this->{container} //= $this->{builder}->();
    }

    sub fetch {
        my ( $this, $path ) = @_;

        return $this->_container->fetch($path);
    }

    sub services {
        my ($this) = @_;

        return $this->_container->services;
    }
}

1;

# vim: expandtab:shiftwidth=4:tabstop=4:softtabstop=0:textwidth=78:
