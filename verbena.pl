use common::sense;
use lib qw(./lib);
use List::Util qw(reduce);

use Verbena
    qw(loc_nested svc_singleton svc_pos_deps svc_named_deps svc_value svc_alias resolve loc_set loc_first loc_lazy svc_defer);

my $ii = 0;

my $locator = loc_nested(
    {   incr  => svc_singleton( sub { ++$ii } ),
        inc   => sub            { ++$ii },
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
    { Database => loc_nested( { dsn => svc_alias('../sumba'), }, {} ) }
);

use Data::Dump qw(pp);
pp($locator);

my $biak = resolve( $locator, 'biak' );
warn "B $biak";
warn $biak->();
warn $biak->();
warn $biak->();

warn resolve( $locator, 'Database/dsn' );
warn resolve(
    loc_first( loc_set( { sumba => svc_value(245), } ), $locator ),
    'Database/dsn',
);
my $koko = loc_first(
    loc_set( { sumba => svc_value(245), } ),
    $locator,
    loc_lazy(
        sub {
            loc_set( { sumbawa => svc_alias('sumba'), } );
        }
    ),
);
pp($koko);
warn $_ for $koko->services;
warn $_ for $koko->services;

# warn Verbena::resolve( $locator, 'xyz',);

