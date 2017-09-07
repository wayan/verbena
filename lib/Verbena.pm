package Verbena;

use common::sense;

# ABSTRACT: tiny dependency injection container

use List::Util qw(reduce pairmap first pairkeys);
use Ref::Util qw(is_coderef is_arrayref is_hashref is_refref);
use Scalar::Util qw(blessed);
use Carp qw(confess);

use Exporter 'import';
use Class::Load;

our @EXPORT_OK = qw(
    resolve
    svc_alias
    svc_asis
    svc_pos
    svc_named
    svc_defer
    constructor
    svc_dep
    get_service_from
);

my $MAX_STACK_DEPTH = 20;

sub extract {
    my ($container, $target, $opts) = @_;

    return _extract( $container, is_path($target) ? $target : 'anon',
        $target, $opts, [] );
}

sub extract_no_state {
    my ($container, $target, $opts) = @_;

    my $code = _extract( $container, is_path($target) ? $target : 'anon',
        $target, $opts, [] );
    return sub {
        my ($state) = @_;
        my ($new_state, $value) = @{$code->($state // {} )};
        return $value;
    };
}

*is_service = \&is_coderef;

sub is_path {
    my ($candidate) = @_;

    return !ref($candidate) || (blessed($candidate) && $candidate->isa('Verbena::Path'));
}

sub _extract {
    my ( $container, $path, $target,  $opts, $stack ) = @_;

    my $max_stack_depth = $opts && $opts->{max_stack_depth} || $MAX_STACK_DEPTH;
    if ( @$stack > $max_stack_depth ) {
        confess "Dependencies are too deep: " . _dump_stack($stack);
    }

    my @new_stack = (@$stack, $path);
    if ( is_service($target) ) {
        return $target->( $container, $path, $opts, \@new_stack );
    }
    elsif ( is_path($target)){
        my $service = get_service_from( $container, $path, $opts );
        if ( !$service ) {
            confess sprintf( "No service '%s' (%s)",
                $path, _dump_stack( \@new_stack ) );
        }
        return $service->( $container, $path, $opts, \@new_stack );
    }
    else {
        die "Invalid type of target";
    }
}

sub _dump_stack {
    my ($stack) = @_;

    join ' => ', map { "'$_'" } @$stack;
}

sub svc_singleton {
    my ($target) = @_;

    my $svc = svc_dep($target);
    sub {
        my ($container, $path) = @_;
        my $code = $svc->(@_);
        my $the_path = "$path";
        sub {
            my ($state) = @_;

            if ( exists( $state->{$the_path} ) ) {
                return [ $state->{$the_path}, $state ];
            }

            my ($value, $new_state) = @{$code->($state)};
            return [ $value, { %$new_state, $the_path => $value} ];
        };
    };
}

sub resolve {
    my ( $container, $target, $opts) = @_;

    my $code = _extract($container, $target, $target, $opts, []);
    my ($value, $state) = @{$code->({})};
    return $value;
}

sub get_service_from {
    my ($container, $path) = @_;

    return _get_service_from($container, $path, 0);
}

my $max_container_depth = 20;  # prevents infinite recursion

sub _get_service_from {
    my ($container, $path, $depth ) = @_;

    $depth < $max_container_depth or confess "Too many levels to find a service";

    if (blessed($container )){
        return $container->get_service($path);
    }

    elsif (is_hashref($container)){
        if (exists( $container->{$path})){
            my $service = $container->{$path};
            is_service($service) or confess "Invalid service $service, coderef is expected";
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
        confess "Unrecognized type of container";
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

sub svc_asis {
    my ($value) = @_;

    return sub {
        return sub { my ($state) = @_; return [ $value, $state ] };
    };
}

sub svc_alias {
    my ($target) = @_;

    is_path($target)
        or confess "Invalid target for the svc_alias";
    return svc_dep($target);
}

sub svc_defer {
    my ($target) = @_;

    my $svc = svc_dep($target);
    return sub {
        my ($container, $path, $stack) = @_;
        return sub {
            my ($state) = @_;
            return [
                sub {
                    my $code = $svc->($container, $path, []);
                    my ( $value, $new_state ) = @{$code->($state)};
                    return $value;
                },
                $state
            ];
        };
    };
}

sub svc_pos {
    my ($deps, $block) = @_;

    !$block || is_coderef($block)
        or confess "Invalid block arg for svc_pos";

    my $i = 0;
    my @services = map { svc_dep($_, $i++); } @$deps;
    return sub {
        my @args = @_;
        my @codes = map { $_->(@args) } @services;

        return sub {
            my ($state) = @_;

            my @resolved;
            for my $code (@codes) {
                my ( $res, $new_state ) = @{ $code->( $state ) };
                push @resolved, $res;
                $state = $new_state;
            }

            # without block svc_pos just returns the resolved deps as an arrayref
            my $value = $block ? $block->(@resolved) : \@resolved;
            return [ $value, $state ];
        };
    };
}


# svc_named can work also with arrayref [ 'path', 'path', [ name => 'target' ], ...  ]
sub svc_named {
    my ( $deps, $block ) = @_;

    !$block || is_coderef($block)
        or confess "Invalid block arg for svc_named";

    my (@names, @services);

    if ( is_hashref($deps) ) {
        @names = keys %$deps;
        @services = map { svc_dep( $deps->{$_}, $_ ); } @names;
    }
    elsif ( is_arrayref($deps) ) {
        for my $dep ( @$deps){
            if (! ref($dep)){
                my ($name) = $dep =~ m{(?:.*/)?(.*)};
                push @names, $name;
                push @services, svc_dep($dep, $name);
            }
            elsif (is_arrayref($dep)){
                my ($name, $target) = @$dep;
                push @names, $name;
                push @services, svc_dep($target, $name);
            }
            else {
                confess "Invalid named dependency $dep";
            }
        }
    }
    else {
        confess "Invalid dependencies of svc_named: '$deps'";
    }

    return sub {
        my @args = @_;
        my @codes = map { $_->(@args) } @services;

        return sub {
            my ($state) = @_;
            my @resolved;
            my $i = 0;
            for my $code (@codes) {
                my ( $res, $new_state ) = @{ $code->( $state ) };
                push @resolved, $names[$i++] => $res;
                $state = $new_state;
            }

            # without block svc_named just returns the resolved deps as an hashref
            my $value = $block ? $block->(@resolved) : +{ @resolved };
            return [ $value, $state ];
        };
    };
}

sub svc_dep {
    my ( $target, $dep_name ) = @_;

    if ( is_path($target)  ) {
        # $target is a path
        return sub {
            my ( $container, $base, $opts, $stack ) = @_;
            my $path = abs_path_to_service( $target, $base );
            return _extract( $container, $path, $path, $opts, $stack);
        };
    }
    elsif ( is_service($target) ) {
        return sub {
            my ( $container, $base, $opts, $stack ) = @_;
            my $path = [ ref($base) ? @$base : $base, $dep_name // 'anon' ];
            return _extract( $container, $path, $target, $opts, $stack );
        };
    }
    confess "Unknown type of dependency '$target'";
}

sub abs_path_to_service {
    my ( $target, $base ) = @_;

    return $1 if $target =~ m{^/(.*)};

    my $bbase = ref($base)? $base->[0]: $base;
    return reduce { _join_path( $a, $b ); } _dir($bbase), split m{/}, $target;
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

{
    package Verbena::Path;
    # path with the dependencies

    use overload '""' => sub {
            return shift()->to_string();
        },
        fallback => 1;

    sub new {
        my ($base, $dep_name) = @_;
        return bless([ $base, $dep_name], __PACKAGE__);
    }

    sub to_string {
        my $this = shift;
        return join('#', @$this);
    }
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
application addressed by a path. The service is called with two sets
of parameters

    my $ret = $service->($container, $path, $stack)->($state);
    my ($value, $new_state) = @$ret;

The parameters are:

=over 4

=item C<< $container >>

The container passed to resolve.

=item C<< $path >>

The path of the service currently resolved. It must be noted the path is passed, it is not
part of the service. It means that the exactly the same service (the coderef)
can be used for different paths in the container.

=item C<< $state >>

The structure (opaque for most services) containing the state of resolving ().

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


