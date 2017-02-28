package Verbena;

use common::sense;

# ABSTRACT: tiny dependency injection container

use List::Util qw(reduce pairmap first pairkeys);
use Ref::Util qw(is_coderef is_arrayref is_hashref is_refref);
use Scalar::Util qw(blessed);
use Carp qw(croak);

use Exporter 'import';
use Class::Load;

our @EXPORT_OK = qw(
    resolve
    resolve_st
    init_state
    svc_alias
    svc_asis
    svc_pos
    svc_named
    svc_once   
    svc_lifecycle
    svc_defer
    constructor
    target_resolver

    get_service_from
);

my $default_max_depth = 20;

sub resolve {
    my ( $container, $target) = @_;

    if ( is_arrayref($target) ) {
        my ( $resolved, $state_out )
            = @{resolve_st( $container, init_state(), svc_pos($target) )};
        return wantarray ? @$resolved : $resolved;
    }

    # passing opaque context
    my ( $resolved, $state_out ) = @{resolve_st( $container, init_state(), $target )};
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

sub _resolve_st {
    my ($container, $state, $path, $service) = @_;

    my $route = $state->{'verbena.route'};
    my $max_depth = $state->{'verbena.max_depth'} // $default_max_depth;
    if ( @$route > $max_depth ) {
        die "Going too deep with deps: ",
            join( ' => ', map {"'$_'"} @$route );
    }

    my @new_route = ( @$route, $path );
    my $svc_ret = $service->(
        $container, { %$state, 'verbena.route' => \@new_route }, $path
    );

    # sets route back
    my ( $resolved, $state_out ) = @$svc_ret;
    return [ $resolved, { %$state_out, 'verbena.route' => $route } ];
}

sub get_service_from {
    my ($container, $path) = @_;

    return _get_service_from($container, $path, 0);
}

my $max_container_depth = 20;  # prevents infinite recursion

sub _get_service_from {
    my ($container, $path, $depth, $label ) = @_;

    $depth < $max_container_depth or croak "Too many levels to find a service";

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
            my $service = get_service_from($cont, $path, $depth + 1);
            return $service if $service;
        }
    }
    elsif (is_refref($container) && is_hashref($$container)){
        return _get_mount_service_from($$container, $path, $depth + 1);
    }
    elsif (is_coderef($container)){
        return get_service_from($container->(), $depth + 1);
    }
    else {  
        croak "Unrecognized type of container";
    }
  
    return undef; 
}

sub _get_mount_service_from {
    my ( $cont, $path, $depth ) = @_;

    my ( $first, $rest ) = $path =~ m{(.*?)/(.*)}
        or return undef;
    my $mount_container = $cont->{$first}
        or return undef;

    return get_service_from( $mount_container, $rest, $depth  );
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
            my ($res, $new_state) = @{$target->($cont, $state, $path)};
            push @resolved, $res;
            $state = $new_state;
        }

        # without block svc_pos just returns the resolved deps as an arrayref
        return [ $block ? scalar($block->(@resolved)) : \@resolved,
            $state ];
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
            my ($res, $new_state) = @{$target->($cont, $state, $path)};
            push @resolved, $name => $res;
            $state = $new_state;
        }

        # without block svc_pos just returns the resolved deps as an arrayref
        return [ $block ? scalar($block->(@resolved)) : \@resolved,
            $state ];
    };
}

sub _svc_pos_deps {
    my ($deps) = @_;

    my $i = 0;
    return map {
        my $name = ($i++);
        target_resolver($_, $name);
    } @$deps;
}

sub _svc_named_deps {
    my ($deps) = @_;

    if ( is_hashref($deps) ) {
        return pairmap { [ $a => target_resolver( $b, $a ) ]; } %$deps;
    }
    elsif ( is_arrayref($deps) ) {
        return map {
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
                croak "Invalid positional dependency $dep";
            }
            
            [$name => target_resolver( $target, $name )];
        } @$deps;
    }
    else {
        croak "Invalid dependencies of svc_named: '$deps'";
    }
}

sub svc_asis {
    my ($value) = @_;
    return sub {
        my ( $cont, $state, $path ) = @_;
        return [ $value, $state ];
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
        my ($container, $state, $path) = @_;

        if ($resolved){
            return [$value, $state];
        }

        $resolved = 1;
        my ($v, $new_state) = @{$svc->($container, $state, $path)};
        ( $resolved, $value) = (1, $v);
        return [$value, $new_state];
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

sub svc_lifecycle {
    my ($target, $lifecycle, $key_arg) = @_;

    my $svc = target_resolver($target);
    return sub {
        my ($container, $state, $path) = @_;
   
        my $key = $key_arg // $path; 
        if ( my ($stored) = _get_state( $state, 'verbena.lifecycle', $lifecycle, $key ) ) {
            return $stored;
        }
        # creating new state :-(
        my ($resolved, $new_state) = @{$svc->($container, $state, $path)};
        return [ $resolved, _set_state($new_state, $resolved, 'verbena.lifecycle', $lifecycle, $key)];
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
    my ( $class, $method_arg ) = @_;
    my $method = $method_arg // 'new';

    my $loaded;
    return sub {
        if ( !$loaded ) {
            Class::Load::load_class($class);
            $loaded = 1;
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

Verbena is a simple Dependency Injection library. Basically a service locator,
the only purpose of this library is to express dependencies between
components of your application.  

Verbena is inspired by Bread::Board but differs from Bread::Board in many ways.

=over 4

=item The resolution and service organization concerns are separated.

=item The only purpose is to express dependencies. There is no infer feature,
there is no reflection - you cannot inspect the dependencies of a service, 
for example.

=item No syntactic sugar involved. 

=item Verbena is only a bunch of function, there is no Moose or other object framework.

=back

=head2 Container

Container is a structure in which C<resolve> searches for the service by path (possibly recursively).
It can be:

=over 4

=item hashref (of services)

    {
        $path1 => $service1,
        $path2 => $service2,
        ...
    }

A simple service lookup.

=item arrayref (of containers)

    [ $container1, $container2, ... ]

The service is searched for in first container from the array. If found the
service is returned otherwise the rest of the array is tried.

=item reference to hashref (of containers)

    \ {   Database => {
            dsn     => svc_pos(...),
            storage => svc_pos(...),
        },
        REST => { ... }
    }

"Mounted" containers. Part of the path up to first slash is used to find a
container in a hash. Part of the path after the slash is used to search 
for the service in the container.

=item object

Method C<< get_service($path) >> is called to get a service. Method should
return the service or undef (container does not contain the service).

=item code reference

The subroutine is just called with C<< $path >>.

=back

=head2 Service

Service is an anonymous subroutine which returns a component of your
application addressed by a path. The service is called as

    my $ret = $service->($container, $state, $path);
    my ($value, $new_state) = @$ret;

The parameters are:

=over 4

=item C<< $container >>

The container passed to resolve. 

=item C<< $state >>

The structure (opaque for most services) containing the state of resolving ().

=item C<< $path >>

The path of the service currently resolved. It must be noted the path is passed, it is not
part of the service. It means that the exactly the same service (the coderef)
can be used for different paths in the container.

=back

The service is supposed to return two values array reference C<< ($resolved, $new_state) >>

=head1 FUNCTIONS

All functions can be imported on demand or called with qualified name.

=over 4 

=item B<< resolve( $container, $target ) >>

    $value = resolve( $container, $target);


Resolve a service from the container.

Finds the service from a container for a path and resolve its value. 
Throws an exception if there is no such service. 

The C<< $target >> can be either path or service. The resolve can also be used
to resolve more services at once:

    my ( $resolved1, $resolved2, ... ) = resolve( $container, [ $path1, $path2, ... ] );

=item B<< init_state() >>

=item B<< resolve_st($container, $state, $target) >>

Revealing the state of the resolution

    my $state = Verbena::init_state();
    (my $value1, $state) = resolve_st( $container, $state, $target1);
    ...
    (my $value2, $state) = resolve_st( $container, $state, $target2);
    ...
    

=back

=head2 Functions returning services

=over 4

=item B<< svc_asis($any) >>

When resolved returns the value passed unchanged. 

=item B<< svc_alias($path) >>

When resolved returns the value of service addressed by the path.
The path may be either absolute (starting with slash) or relative.
When absolute the leading slash is removed and the path is used.
When relative then the path is "absolutized" according to the 
path of the service alias.

=item B<< svc_pos([ $target, ...], \&block) >>

    # dbh service
    svc_pos(
        [   '../Database/dsn', '/Database/username', '../Database/auth',
            svc_asis( { RaiseError => 1, AutoCommit => 0 } )
        ],
        sub {
            DBI->connect(@_);
        }
    )

Positional dependencies. Calls the block with a list from all targets resolved.
Each target is either a string (path) or a service. 

The path can be either absolute (starting with C<<  / >>) or relative,
parent "directory" C<..> an be used in relative paths.

Block can be omitted. In such case a default block (below) is used.

    sub { return [ @_ ] }


=item B<< svc_named({ key=>$target, key=>$target }, \&block) >>

=item B<< svc_named([ $path1, $path2, ... ], \&block) >>

Named dependencies. Calls the block with a list of key value pairs, 
where values are the resolved values. Each target can be either a path or a service.

If dependencies definition (first argument) is an arrayref, each element is
converted to C<< key => target >> pair. The element can be a string ($path), 
the key is constructed as basename of the path (the part after last slash). 
The element can be also a reference to two elements array C<< [ $key, $target ] >>.

Block can be omitted. In such case a default block (below) is used.

    sub { return +{ @_ } }

=item B<< svc_defer($target) >>

Lazily evaluated service. Returns not the resolution, but an anonymous
subroutine which, when called (everytime), resolves the target.

=back

=head2 Utility functions

=over 4

=item B<< constructor($class) >>

Returns callback to be used in C<< svc_pos >> or C<< svc_named >>, basically
C<< sub { $class->new(@_) } >>. Load the class lazily (when the callback
returned is called for the first time, i.e when the service is resolved).

=item B<< get_service_from($container, $path) >>

Finds the service (anonymous sub) from a container (described above).

=back

=cut

# vim: expandtab:shiftwidth=4:tabstop=4:softtabstop=0:textwidth=78:


