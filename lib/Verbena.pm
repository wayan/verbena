package Verbena;

use common::sense;

# ABSTRACT: tiny dependency injection container

use List::Util qw(reduce pairmap first);
use Ref::Util qw(is_coderef);
use Types::Standard qw(HasMethods CodeRef Str ArrayRef HashRef slurpy);
use Type::Params ();

use Exporter 'import';

our @EXPORT_OK = qw(
    resolve
    svc_alias
    svc_value
    svc_pos_deps
    svc_named_deps
    svc_singleton
    svc_defer
    loc_nested
    loc_set
    loc_first
    loc_lazy
);

my $ServiceLocatorType = HasMethods ['fetch'];
my $ServiceType        = CodeRef;
my $TargetType         = Str | $ServiceType;

sub resolve {
    my ( $service_locator, $path ) = @_;

    # passing opaque context
    return _resolve( $service_locator, [], $path );
}

sub _resolve {
    my ( $service_locator, $paths, $path ) = @_;

    if ( @$paths > 10 ) {
        die "Going too deep with deps: ", join( '=> ', map {"'$_'"} @$paths );
    }

    my $service = $service_locator->fetch($path)
        or die "No service '$path'";

    my @new_paths = ( @$paths, $path );
    my $resolver = sub {
        my ($path) = @_;
        return _resolve( $service_locator, \@new_paths, $path );
    };
    return $service->( $resolver, $path );
}

sub svc_alias {
    state $params_check = Type::Params::compile(Str);

    my ($target) = $params_check->(@_);
    return _target_resolver(svc_alias => $target);
}

sub svc_defer {
    state $params_check = Type::Params::compile($TargetType);

    my ($target) = $params_check->(@_);
    my $resolver = _target_resolver(svc_alias => $target);
    return sub {
        my @args = @_;
        sub { $resolver->(@args) };
    };
}

sub svc_pos_deps {
    state $params_check
        = Type::Params::compile( ArrayRef [$TargetType], CodeRef );
    my ( $deps, $block ) = $params_check->(@_);

    my $i         = 0;
    my @resolvers = map {
        my $idx = $i++;
        _target_resolver( $idx, $_ )
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

    my @resolvers = pairmap { ($a => _target_resolver( $a, $b )); } %$deps;

    return sub {
        my @args = @_;
        return $block->( pairmap { ( $a => $b->(@args) ); } @resolvers);
    };
}

sub svc_value {
    my ($value) = @_;
    return sub {$value};
}

sub _target_resolver {
    my ($dep_name, $target) = @_;

    if ( !ref $target ) {
        return sub {
            my ($resolver, $base) = @_;
            return $resolver->( abs_path_to_service( $target, $base ) );
        }
    }
    elsif ( is_coderef($target) ) {
        return sub {
            my ($resolver, $base) = @_;
            return $target->( $resolver, "$base#$dep_name" );
        };
    }
    die "Invalid type of dependency";
}

sub svc_singleton {
    my ($code) = @_;

    my ( $resolved, $value );
    return sub {
        if ( !$resolved ) {
            $resolved = 1;
            $value    = $code->(@_);
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

sub loc_nested {
    state $params_check = Type::Params::compile( HashRef [$ServiceType],
        HashRef [$ServiceLocatorType] );
    my ( $services, $locators ) = $params_check->(@_);

    return bless(
        {   services => $services,
            locators => $locators,
        },
        'Verbena::ServiceLocator::Nested'
    );
}

{

    package Verbena::ServiceLocator::Nested;

    use List::Util qw(pairmap);

    sub fetch {
        my ( $this, $path ) = @_;

        my @parts = split m{\/}, $path, 2;
        return @parts == 1
            ? $this->{services}{ $parts[0] }
            : do {
            my $inner = $this->{locators}{ $parts[0] };
            $inner ? $inner->fetch( $parts[1] ) : undef;
            };
    }

    sub services {
        my ($this) = @_;

        return keys %{ $this->{services} }, pairmap {
            my $prefix = $a;
            map { "$prefix/$_"; } $b->services;
        }
        %{ $this->{locators} };
    }
}

sub loc_set {
    state $params_check = Type::Params::compile( HashRef [$ServiceType] );

    my ( $services, $locators ) = $params_check->(@_);
    return bless( { services => $services, }, 'Verbena::ServiceLocator::Set' );
}

{

    package Verbena::ServiceLocator::Set;

    sub fetch {
        my ( $this, $path ) = @_;

        return $this->{services}{$path};
    }

    sub services {
        my ($this) = @_;
        return keys %{ $this->{services} };
    }
}

sub loc_first {
    state $params_check
        = Type::Params::compile( slurpy( ArrayRef [$ServiceLocatorType] ) );
    my ($locators) = $params_check->(@_);
    return bless( { locators => $locators, },
        'Verbena::ServiceLocator::FirstFrom' );
}
{

    package Verbena::ServiceLocator::FirstFrom;

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

sub loc_lazy {
    state $params_check = Type::Params::compile(CodeRef);
    my ($builder) = $params_check->(@_);
    return bless( { builder => $builder, }, 'Verbena::ServiceLocator::Lazy' );
}

{

    package Verbena::ServiceLocator::Lazy;

    sub _locator {
        my $this = shift;
        return $this->{locator} //= $this->{builder}->();
    }

    sub fetch {
        my ( $this, $path ) = @_;

        return $this->_locator->fetch($path);
    }

    sub services {
        my ($this) = @_;

        return $this->_locator->services;
    }
}

1;

# vim: expandtab:shiftwidth=4:tabstop=4:softtabstop=0:textwidth=78:
