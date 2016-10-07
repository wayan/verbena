use common::sense;
use lib qw(./lib);
use List::Util qw(reduce);

use Verbena
    qw(svc_singleton svc_pos_deps svc_named_deps svc_value svc_alias resolve loc_first loc_lazy svc_defer container constructor);

my $ii = 0;

package My::Class {
    use Moose;

    sub BUILDARGS {
        my ( $class, $n ) = @_;
        return { n => $n };
    }
}

my $locator = container(
    {   incr  => svc_singleton( 'inc' ),
        inc   => sub                { ++$ii },
        sumba => svc_pos_deps(
            [ 'inc', 'inc', 'inc', 'inc' ],
            sub {
                return reduce { $a + $b } 0, @_;
            }
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
    },
    { Database => container( { dsn => svc_alias('../sumba'), } ) }
);

use Data::Dump qw(pp);
pp($locator);

my $biak = resolve( $locator, 'biak' );
warn resolve( $locator, 'inc');
warn resolve( $locator, 'inc');
warn resolve( $locator, 'inc');
warn resolve( $locator, 'incr');
warn resolve( $locator, 'incr');
warn resolve( $locator, 'incr');

warn "B $biak";
warn $biak->();
warn $biak->();
warn $biak->();

warn resolve( $locator, 'Database/dsn' );
warn resolve( loc_first( container( { sumba => svc_value(245), } ), $locator ),
    'Database/dsn', );
my $koko = loc_first(
    container( { sumba => svc_value(245), } ),
    $locator,
    loc_lazy(
        sub {
            container( { sumbawa => svc_alias('sumba'), } );
        }
    ),
);
pp($koko);
pp(+{map { $_=>$koko->fetch($_) } $koko->services});
__END__
warn $_ for $koko->services;
warn $_ for $koko->services;

warn resolve( $koko, 'myc' );

# warn Verbena::resolve( $locator, 'xyz',);

