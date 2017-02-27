use common::sense;
use Verbena;
use Test::More;

my $res = Verbena::resolve(
    {   p1 =>
            Verbena::svc_pos( [ 'p2', 'p2', 'p3' ], sub { join( ';', @_ ) } ),
        p2 => Verbena::svc_asis('P2'),
        p3 => Verbena::svc_asis('P3'),
    },
    'p1'
);

is_deeply( $res, 'P2;P2;P3' );

done_testing();
