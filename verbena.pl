use common::sense;
use lib qw(./lib);
use List::Util qw(reduce);
use Types::Standard qw(HashRef Str);
use Carp qw(confess);

use Verbena
    qw(svc_singleton svc_pos_deps svc_named_deps svc_value svc_alias resolve loc_first container_lazy svc_defer container constructor target_resolver);

my $ii = 0;

sub check_svc_type {
    my ( $svc, $type ) = @_;

	my $target = target_resolver($svc);
    return sub {
        my $resolved = $target->(@_);
        if ( !$type->check($resolved) ) {
            my ( $resolver, $path ) = @_;
            confess sprintf "Service '%s' does not conform its type: %s",
                $path,
                $type->get_message($resolved);
        }
        return $resolved;
    };
}

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
	circle => svc_alias('Circle/circle'),
	hulman => svc_defer(svc_pos_deps( ['circle'], sub { shift() })),
	makak => check_svc_type( 'inc', HashRef),
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
    { 
	Circle => container({
		circle => svc_alias('../circle'),
	}),
	Database => container( { dsn => svc_alias('../xsumba'), 
	dbh=> svc_pos_deps(
		[
			'dsn',
		],
		sub {
		}
	)
	} ) }
);

use Data::Dump qw(pp);
pp($locator);

resolve( $locator, 'makak');
my $hulman = resolve( $locator, 'hulman');
$hulman->();
__END__

resolve( $locator, 'dbh' );
__END__
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
    container_lazy(
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

