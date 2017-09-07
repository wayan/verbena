use common::sense;
use Verbena;
use Test::More;

my $i = 12;
my $container = {
    p1 => Verbena::svc_pos( [ 'p2', 'p2', 'p2' ], sub { [ @_ ] } ),
    p2 => Verbena::svc_singleton(Verbena::svc_pos([], sub { return $i++; })),
};

my $code = Verbena::extract($container, 'p1');
{
    my ( $value, $new_state ) = @{ $code->( {} ) };
    is_deeply( $value, [ 12, 12, 12 ] );
    is( $new_state->{'p2'}, '12' );
}

{
    my ( $value, $new_state ) = @{ $code->( { 'p2' => 34 } ) };
    is_deeply( $value, [ 34, 34, 34 ] );
    is( $new_state->{'p2'}, '34' );
}

done_testing();
