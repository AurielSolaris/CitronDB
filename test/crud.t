use strict;
use warnings;
use Test::More;

require "./test/lib.perl";

# CRUD consistency: every operation against every kind of key state, so a
# missing key, a key holding JSON null, a falsy value and a normal value
# never get confused. Each row: what the operation returns and what state
# the key is in afterwards.

my %setup = (
    missing => sub { },
    null    => sub { citron::set_data("k", "null") },
    false   => sub { citron::set_data("k", "false") },
    zero    => sub { citron::set_data("k", "0") },
    empty   => sub { citron::set_data("k", "") },
    value   => sub { citron::set_data("k", '{"a":1}') },
);

# State of "k" as [found, readable text].
sub state_of {
    my ($found, $value) = citron::lookup("k");
    return [$found ? 1 : 0, $found ? citron::to_text($value) : undef];
}

my %text = (missing => undef, null => "null", false => "false", zero => "0", empty => "", value => '{"a":1}');

for my $state (sort keys %setup) {
    my $present = $state eq "missing" ? 0 : 1;
    my $before = [$present, $text{$state}];

    subtest "key is $state" => sub {
        fresh_db();
        $setup{$state}->();

        is_deeply(state_of(), $before, "lookup reports found=$present");
        is(citron::exists_data("k"), $present, "exists");
        is(defined citron::get_data("k") ? 1 : 0, ($state eq "missing" || $state eq "null") ? 0 : 1,
            "get_data is undef only for missing and null");
        is(scalar(grep { $_ eq "k" } keys %{ citron::list() }), $present, "list");

        # update: replaces only an existing key
        fresh_db();
        $setup{$state}->();
        is(citron::update_data("k", "2"), $present, "update returns $present");
        is_deeply(state_of(), $present ? [1, "2"] : [0, undef], "update result");

        # delete: removes only an existing key
        fresh_db();
        $setup{$state}->();
        is(citron::delete_data("k"), $present, "delete returns $present");
        is_deeply(state_of(), [0, undef], "gone after delete");
        is(citron::delete_data("k"), 0, "second delete returns 0");

        # set: always creates or replaces
        fresh_db();
        $setup{$state}->();
        citron::set_data("k", "3");
        is_deeply(state_of(), [1, "3"], "set always writes");

        # other keys never affected
        fresh_db();
        citron::set_data("other", "x");
        $setup{$state}->();
        citron::update_data("k", "2");
        citron::delete_data("k");
        is(citron::get_data("other"), "x", "other keys untouched");
    };
}

subtest 'paths distinguish missing from null' => sub {
    fresh_db();
    citron::set_data("k", '{"a":null,"b":[null]}');

    my ($found, $value) = citron::lookup("k", "a");
    ok($found && !defined $value, "field holding null is found");
    ($found) = citron::lookup("k", "zzz");
    ok(!$found, "missing field is not");
    ($found, $value) = citron::lookup("k", "b.0");
    ok($found && !defined $value, "array element holding null is found");
    ($found) = citron::lookup("k", "b.1");
    ok(!$found, "past the end is not");
};

subtest 'keys are exact' => sub {
    fresh_db();
    citron::set_data("k", "1");
    citron::set_data("K", "2");
    citron::set_data("k ", "3");
    citron::set_data("", "4");
    is(citron::get_data("k"), 1, "k");
    is(citron::get_data("K"), 2, "case matters");
    is(citron::get_data("k "), 3, "trailing space matters");
    is(citron::get_data(""), 4, "empty key is a key");
    is(citron::exists_data("k  "), 0, "no fuzzy matching");
};

done_testing();
