use common::sense;

use lib qw(./lib);
use List::Util qw(reduce);
use Types::Standard qw(HashRef Str);
use Carp qw(confess);

use Verbena
    qw(svc_singleton svc_pos_deps svc_named_deps svc_value svc_alias resolve merge_containers container_lazy svc_defer container constructor target_resolver);

my $ii = 0;

sub check_svc_type {
    my ( $target, $type ) = @_;

    my $svc = target_resolver($target);
    return sub {
        my ( $resolved, $new_state ) = $svc->(@_);
        if ( !$type->check($resolved) ) {
            my ( $resolve, $container, $state, $path ) = @_;
            confess sprintf "Service '%s' does not conform its type: %s",
                $path,
                $type->get_message($resolved);
        }
        return ( $resolved, $new_state );
    };
}

package My::ContainerWithLogger {
    use Moose;

    has container => (
        is       => 'ro',
        required => 1,
        handles  => [ 'get_service', 'services' ]
    );

    around get_service => sub {
        my $orig = shift;
        my $svc  = $orig->(@_);
        return sub {
            my ( $resolve, $container, $state, $path ) = @_;
            warn sprintf "Resolving route(%s)\n",
                join( '=>', map {"'$_'"} @{ $state->{route} } );
            $svc->(@_);
        };
    };
}

package My::Class {
    use Moose;

    sub BUILDARGS {
        my ( $class, $n ) = @_;
        return { n => $n };
    }
}

my $container = container(
    {   incr  => Verbena::svc_singleton2('inc'),
        inc   => sub { ++$ii },
        sumba => svc_pos_deps(
            [ 'inc', 'inc', 'inc', 'inc' ],
            sub {
                return reduce { $a + $b } 0, @_;
            }
        ),
        circle => svc_alias('Circle/circle'),
        hulman => svc_defer( svc_pos_deps( ['circle'], sub { shift() } ) ),
        makak  => check_svc_type(
            svc_pos_deps(
                ['inc'],
                sub {
                    my $inc = shift;
                    { inc => $inc };
                }
            ),
            HashRef
        ),
        dsn => svc_value('dbi:somewhere'),
        dst => svc_value('dbi:anywhere'),
        sum => svc_pos_deps(
            [ 'dsn', 'dst' ],
            sub {
                my ( $dsn, $dst ) = @_;
                return $dsn . $dst;
            }
        ),
        myc => svc_pos_deps(
            [ svc_value('100') ],
            constructor('My::Class'),
        ),
        xyz  => svc_alias('yz'),
        yz   => svc_alias('xyz'),
        biak => svc_defer(
            svc_pos_deps(
                [ 'inc', 'inc' ],
                sub {
                    my ( $s1, $s2 ) = @_;
                    return $s1 + $s2,;
                }
            )
        ),
        dbh => svc_alias('Database/dbh'),
    },
    {   Circle   => container( { circle => svc_alias('../circle'), } ),
        Database => container(
            {   dsn => svc_alias('../xsumba'),
                dbh => svc_pos_deps(
                    [ 'dsn', ],
                    sub {
                    }
                )
            }
        )
    }
);

use Data::Dump qw(pp);
pp($container);

my $container2 = My::ContainerWithLogger->new( container => $container );
my ( $resolved, $state ) = resolve( $container2, 'incr' );
pp($state);
resolve( $container2, 'makak' );

__END__

my $biak = resolve( $container2, 'biak' );
warn $biak->();
warn $biak->();
warn $biak->();
my $hulman = resolve( $container2, 'hulman');
$hulman->();
__END__

resolve( $container, 'dbh' );
__END__
warn resolve( $container, 'inc');
warn resolve( $container, 'inc');
warn resolve( $container, 'inc');
warn resolve( $container, 'incr');
warn resolve( $container, 'incr');
warn resolve( $container, 'incr');

warn "B $biak";
warn $biak->();
warn $biak->();

warn resolve( $container, 'Database/dsn' );
warn resolve( merge_containers( container( { sumba => svc_value(245), } ), $container ),
    'Database/dsn', );
my $koko = merge_containers(
    container( { sumba => svc_value(245), } ),
    $container,
    container_lazy(
        sub {
            container( { sumbawa => svc_alias('sumba'), } );
        }
    ),
);
pp($koko);
pp(+{map { $_=>$koko->get_service($_) } $koko->services});
__END__
warn $_ for $koko->services;
warn $_ for $koko->services;

warn resolve( $koko, 'myc' );

# warn Verbena::resolve( $container, 'xyz',);

