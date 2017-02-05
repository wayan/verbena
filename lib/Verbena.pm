package Verbena;

use common::sense;

# ABSTRACT: tiny dependency injection container

use List::Util qw(reduce pairmap first pairkeys);
use Ref::Util qw(is_coderef is_arrayref is_hashref is_refref);
use Scalar::Util qw(blessed);
use Types::Standard
    qw(HasMethods CodeRef Str ArrayRef HashRef Optional Tuple slurpy);
use Type::Params ();
use Carp qw(croak);

use Exporter 'import';
use Class::Load;

our @EXPORT_OK = qw(
    resolve
    svc_alias
    svc_asis
    svc_pos
    svc_named
    svc_once   
    svc_singleton2
    svc_defer
    container_lazy
    container
    constructor
    mount_containers
    target_resolver
);

my $default_max_depth = 20;

sub resolve {
    my ( $container, $target) = @_;

    if ( is_arrayref($target) ) {
        my ( $resolved, $state_out )
            = _resolve_st( $container, init_state(), svc_pos($target) );
        return wantarray ? @$resolved : $resolved;
    }

    # passing opaque context
    my ( $resolved, $state_out ) = resolve_st( $container, init_state(), $target );
    return $resolved;
}

sub resolve_st {
    my ( $container, $state, $target ) = @_;

    if ( !ref $target ) {

        # target is a path
        my $service = get_service_from( $container, $target );
        if (!$service){
            my $route = $state->{'verbena.route'};
            croak sprintf( "No service '%s' (%s)",
            $target, join( '=> ', map {"'$_'"} @$route, $target ) );
        }
        return _resolve_st( $container, $state, $target, $service );
    }
    elsif ( is_coderef($target) ) {

        # target is a svc
        # then the service path is anonymous
        return _resolve_st( $container, $state, '#anon', $target );
    }
    else {
        croak "Invalid type of target to resolve '$target'";
    }
}

sub init_state { {} }

sub _method_to_fn {
    my ($fn) = @_;

    return sub {
        my $this = shift;
        return $fn->( $$this, @_ );
    };
}

sub _resolve_st {
    my ($container, $state, $path, $service) = @_;

    my $route = $state->{'verbena.route'};
    my $max_depth = $state->{'verbena.max_depth'} // $default_max_depth;
    if ( @$route > $max_depth ) {
        die "Going too deep with deps: ",
            join( ' => ', map {"'$_'"} @$route );
    }

    my @new_route = ( @$route, $path );
    my ( $resolved, $state_out ) = $service->(
        $container, { %$state, 'verbena.route' => \@new_route }, $path
    );

    # route back
    return ( $resolved, { %$state_out, 'verbena.route' => $route } );
}

sub get_service_from {
    my ($container, $path) = @_;

    return _get_service_from($container, $path, 0);
}

my $max_depth = 20;  # prevents infinite recursion

sub _get_service_from {
    my ($container, $path, $depth, $label ) = @_;

    $depth < $max_depth or croak "Too many levels to find a service";

    if (blessed($container )){
        return $container->get_service($path);
    }

    elsif (is_hashref($container)){
        if (exists( $container->{$path})){
            my $service = $container->{$path};
            is_coderef($service) or croak "Invalid service $service, coderef is expected";
            return $service;
        }
    }
    elsif (is_arrayref($container)){
        for my $cont (@$container){ 
            my $service = get_service_from($cont, $path);
            return $service if $service;
        }
    }
    elsif (is_refref($container) && is_hashref($$container)){
        return get_mount_service_from($$container, $path);
    }
    elsif (is_coderef($container)){
        return get_service_from($container->());
    }
    else {  
        croak "Unrecognized type of container";
    }
  
    return undef; 
}

sub get_mount_service_from {
    my ( $cont, $path ) = @_;

    my ( $first, $rest ) = $path =~ m{(.*?)/(.*)}
        or return undef;
    my $mount_container = $cont->{$first}
        or return undef;

    return get_service_from( $mount_container, $rest );
}

sub svc_alias {
    my ($target) = @_;
    return target_resolver($target);
}

sub svc_defer {
    my ($target) = @_;
    my $resolver = target_resolver($target);
    return sub {
        my @args = @_;
        return sub { $resolver->(@args) };
    };
}

sub svc_pos {
    my ($deps, $block) = @_;

    !$block || is_coderef($block)
        or croak "Invalid block arg for svc_pos";

    my @targets = _svc_pos_deps($deps);
    return sub {
        my ($cont, $state, $path) = @_;

        my @resolved;
        for my $target ( @targets ){
            my ($res, $new_state) = $target->($cont, $state, $path);
            push @resolved, $res;
            $state = $new_state;
        }

        # without block svc_pos just returns the resolved deps as an arrayref
        return ( $block ? scalar($block->(@resolved)) : \@resolved,
            $state );
    };
}

# svc_named can work also with arrayref [ 'path', 'path', [ name => 'target' ], ...  ]
sub svc_named {
    my ($deps, $block) = @_;

    !$block || is_coderef($block)
        or croak "Invalid block arg for svc_named";

    my @targets = _svc_named_deps($deps);
    return sub {
        my ($cont, $state, $path) = @_;

        my @resolved;
        for my $elem ( @targets ){
            my ($name, $target) = @$elem;
            my ($res, $new_state) = $target->($cont, $state, $path);
            push @resolved, $name => $res;
            $state = $new_state;
        }

        # without block svc_pos just returns the resolved deps as an arrayref
        return ( $block ? scalar($block->(@resolved)) : \@resolved,
            $state );
    };
}

sub _svc_pos_deps {
    my ($deps) = @_;

    my $i = 0;
    return map {
        my $name = '#'. ($i++);
        target_resolver($_, $name);
    } @$deps;
}

sub _svc_named_deps {
    my ($deps) = @_;

    if ( is_hashref($deps) ) {
        return pairmap { [ $a => target_resolver( $b, "#$a" ) ]; } %$deps;
    }
    elsif ( is_arrayref($deps) ) {
        my $i = 0;
        return map {
            my $ii = $i++;
            my $dep = $_;

            my ($name, $target);
            if (! ref($dep)){
                ($name) = $dep =~ m{(?:.*/)?(.*)};
                $target = $dep;
            }
            elsif (is_arrayref($dep)){
                ($name, $target) = @$dep;
            }
            else {
                croak "Unrecognized dep";
            }
            
            [$name => target_resolver( $target, "#$name" )];
        } @$deps;
    }
    else {
        croak "Invalid dependencies for svc_named";
    }
}

sub svc_asis {
    my ($value) = @_;
    return sub {    
        my ($cont, $state, $path) = @_;
        return ($value, $state);
    };
}

sub target_resolver {
    my ( $target, $dep_name ) = @_;

    if ( !ref $target ) {
        # $target is a path
        return sub {
            my (  $container, $state, $base ) = @_;
            return resolve_st(
                $container, $state, abs_path_to_service( $target, $base )
            );
        };
    }
    elsif ( is_coderef($target) ) {
        return sub {
            my ( $container, $state, $base ) = @_;

            $dep_name //= 'anon';
            $dep_name =~ s{/}{-}g;
            return $target->( $container, $state, "$base#$dep_name" );
        };
    }
    croak "Unknown type of dependency '$target'";
}

# target is resolved once only
sub svc_once {
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
    my ($target, $key, $lifecycle) = @_;

    $key   //= join( ' at ', (caller(0))[1,2]);
    $lifecycle //= 'singleton';
    my $svc = target_resolver($target);
    return sub {
        my ($resolve, $container, $state, $base) = @_;
    
        if ( my ($stored) = _get_state( $state, 'lifecycle', $lifecycle, $key ) ) {
            return $stored;
        }
        # creating new state :-(
        my ($resolved, $new_state) = $svc->($resolve, $container, $state, $base);
        return ( $resolved, _set_state($new_state, $resolved, 'lifecycle', $lifecycle, $key));
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

1;

__END__

=head1 SYNOPSIS

    use Verbena qw(resolve container svc_pos svc_asis);
    use DBI;

    my $c = container({
        dsn => svc_asis('dsn:Oracle:...'),
        username => svc_asis('someuser'),
        password => svc_asis('somepwd'),
        dbh => svc_pos(['dsn', 'username', 'password'],
            sub {
                my ($dsn, $username, $password) = @_;
                return DBI->connect($dsn, $username, $password);
            }),
    });

    my $dbh = resolve($c, 'dbh');

=head1 DESCRIPTION

Verbena is a simple Dependency Injection library. It was inspired by
Bread::Board. It is also basically a service locator. 
Differs from Bread::Board by many ways.

=over 4

=item Verbena is Moose less.

=item No syntactic sugar involved.

=back

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

=item B<svc_asis($any)>

When resolved returns the value unchanged. 

=item B<< svc_alias($path) >>

When resolved returns the value of service addressed by the path.
The path may be either absolute (starting with slash) or relative.
When absolute the leading slash is removed and the path is used.
When relative then the path is "absolutized" according to the 
path of the service alias.

=item B<svc_pos([ $target, ...], \&block)>

Positional dependencies. When resolved, resolve all targets first and then
calls the block with a list of resolved values. Each target can be either 
path or a service.

=item B<< svc_named({ key=>$target, key=>$target }, \&block) >>

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


