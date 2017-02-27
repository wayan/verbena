use common::sense;
use Verbena;
use Test::More;

my $i   = 0;
my $svc = sub {
    my ( $container, $state, $path ) = @_;
    return ( ++$i, $state );
};

my $c = {
    once  => Verbena::svc_once($svc),
    value => $svc
};

is( Verbena::resolve( $c, 'once' ),  1 );
is( Verbena::resolve( $c, 'value' ), 2 );
is( Verbena::resolve( $c, 'once' ),  1 );
is( Verbena::resolve( $c, 'value' ), 3 );
done_testing();
