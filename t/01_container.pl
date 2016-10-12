use common::sense;
use Test::More;

use Verbena qw(container sub_containers container_lazy);

sub _svc_value {
    my ($v) = @_;
    return sub {$v};
}

subtest 'plain container' => sub {
    my $c = container(
        {   'p1/p2' => _svc_value('a'),
            y       => _svc_value('b'),
        }
    );

    ok( $c->get_service('p1/p2') );
    ok( !$c->get_service('p1/p2/p3') );
    is_deeply(
        [ sort { $a cmp $b } $c->services ],
        [ sort { $a cmp $b } 'p1/p2', 'y' ]
    );
};

subtest 'sub containers' => sub {
    my $c1 = container(
        {   'p1/p2' => _svc_value('foo'),
            y       => _svc_value('bar'),
        }
    );
    my $c2 = container( { 'a' => _svc_value('baz'), } );
    my $c = sub_containers(
        {   p  => $c1,
            qq => $c2,
        }
    );

    ok( $c->get_service('p/p1/p2') );
    ok( $c->get_service('p/y') );
    ok( $c->get_service('qq/a') );
    ok( !$c->get_service('p1/p2/p3') );
    is_deeply(
        [ sort { $a cmp $b } $c->services ],
        [ sort { $a cmp $b } 'p/p1/p2', 'p/y', 'qq/a' ]
    );
};

done_testing();

# vim: expandtab:shiftwidth=4:tabstop=4:softtabstop=0:textwidth=78:
