use common::sense;
use Verbena;
use Test::More;
use Test::Exception;

is( Verbena::abs_path_to_service('/abs/olute', 'anywhere'), 'abs/olute');
is( Verbena::abs_path_to_service('abs/olute', ''), 'abs/olute');
is( Verbena::abs_path_to_service('abs/olute', 'anywhere'), 'abs/olute');
is( Verbena::abs_path_to_service('abs/olute', 'anywhere/else'), 'anywhere/abs/olute');
is( Verbena::abs_path_to_service('olute', 'anywhere/else'), 'anywhere/olute');
is( Verbena::abs_path_to_service('./olute', 'anywhere/else'), 'anywhere/olute');
is( Verbena::abs_path_to_service('../olute', 'anywhere/else'), 'olute');
is( Verbena::abs_path_to_service('this/../is/../nonsense', 'really/anywhere/else'), 'really/anywhere/nonsense');


dies_ok {
    Verbena::abs_path_to_service('../olute', 'anywhere');
} "There is no way up";

done_testing();
