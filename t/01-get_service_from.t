use common::sense;
use Verbena;
use Test::More;

sub _resolve {
    my ( $container, $path ) = @_;
    my $service = Verbena::get_service_from( $container, $path );
    return $service && $service->();
}

is( _resolve(
        {   x => sub {'first'},
            y => sub {'second'}
        },
        'x',
    ),
    'first',
    'Hash source',
);

is( _resolve(
        [   { x => sub {'a'}, },
            { y => sub {'b'}, },
            { x => sub {'A'},
              y => sub {'B'}
            }
        ],
        'y',
    ),
    'b',
    'First occurence',
);

is( _resolve(
        \{  p1 => {
                'p2' => sub {'nested'}
            }
        },
        'p1/p2',
    ),
    'nested',
    'Nestef hash search',
);

is( _resolve(
        [   { 'p1/p2' => sub {'plain'}, },
            \{  p1 => {
                    'p2' => sub {'nested'}
                }
            },
        ],
        'p1/p2',
    ),
    'plain',
    'Nested hash search rewritten by plain',
);
is( _resolve(
        [   \{  p1 => {
                    'p2' => sub {'nested'}
                }
            },
            { 'p1/p2' => sub {'plain'}, },
        ],
        'p1/p2',
    ),
    'nested',
    'Plain search rewritten by nested hash search',
);

done_testing();
