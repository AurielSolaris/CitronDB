use strict;
use warnings;
use Test::More;

require "./test/lib.perl";
require "./src/search_prefix.perl";

sub dies_like {
    my ($code, $re, $name) = @_;
    eval { $code->() };
    like($@, $re, $name);
}

subtest 'numbered snapshots count up and are never reused' => sub {
    fresh_db();

    is(citron::create_snapshot(), "1", "first is 1");
    is(citron::create_snapshot(), "2", "then 2");
    is(citron::create_snapshot(), "3", "then 3");

    is(citron::delete_snapshot("3"), 1, "drop the newest");
    is(citron::create_snapshot(), "4", "its number isn't reused");

    # the counter file is a convenience: lose it and numbering still moves on
    unlink(citron::snapshot_dir() . "/counter");
    is(citron::create_snapshot(), "5", "continues after the highest snapshot");

    # numbering has no upper limit (decimal strings, not machine integers)
    write_raw(citron::snapshot_dir() . "/counter", "99999999999999999999");
    is(citron::create_snapshot(), "100000000000000000000", "past 64-bit range");
    is((citron::list_snapshots())[-1], "100000000000000000000", "sorted last");
};

subtest 'named snapshots' => sub {
    fresh_db();

    is(citron::create_snapshot("beforeMigration2"), "beforeMigration2", "letters and digits");
    is(citron::create_snapshot("v2"), "v2", "digits allowed with a letter");
    is(citron::create_snapshot(), "1", "numbering is separate");

    dies_like(sub { citron::create_snapshot("v2") }, qr/Snapshot 'v2' already exists/, "no overwrite");
    dies_like(sub { citron::create_snapshot("42") }, qr/Invalid snapshot name '42'/, "digits only are reserved");
    for my $bad ("", "a-b", "a b", "../x", "x.citron", "café", "a\n") {
        dies_like(sub { citron::create_snapshot($bad) }, qr/Invalid snapshot name/, "rejects '$bad'");
    }

    is_deeply([citron::list_snapshots()], ["1", "beforeMigration2", "v2"], "numbers first, then names");
};

subtest 'listing order' => sub {
    fresh_db();
    citron::create_snapshot() for 1 .. 11;
    citron::create_snapshot("b");
    citron::create_snapshot("A");
    is_deeply([citron::list_snapshots()], [1 .. 11, "A", "b"], "numeric order, then sorted names");
};

subtest 'rollback restores that exact version' => sub {
    my $file = fresh_db();

    citron::set_data("a", "1");
    citron::create_snapshot("one");
    my $one = read_raw($file);

    citron::set_data("a", "2");
    citron::set_data("b", '{"x":[1,2]}');
    citron::create_snapshot();
    my $two = read_raw($file);

    citron::delete_data("a");
    citron::set_data("c", "3");

    is(citron::rollback("one"), 1, "rollback to a named snapshot");
    is(read_raw($file), $one, "file is byte-identical to the snapshot");
    is_deeply(citron::list(), { a => "1" }, "data matches");

    is(citron::rollback("1"), 1, "rollback to a numbered snapshot");
    is(read_raw($file), $two, "file is byte-identical");
    is(citron::get_data("b", "x.1"), 2, "values come back");

    is(citron::rollback("one"), 1, "snapshots survive a rollback");
    is_deeply([citron::list_snapshots()], ["1", "one"], "still listed");
};

subtest 'rollback of a missing or invalid snapshot' => sub {
    my $file = fresh_db();
    citron::set_data("a", "1");
    my $before = read_raw($file);

    is(citron::rollback("nope"), 0, "missing");
    is(citron::rollback("../x"), 0, "invalid name");
    is(citron::rollback(undef), 0, "no name");
    is(read_raw($file), $before, "database untouched");
};

subtest 'a corrupt snapshot is refused' => sub {
    my $file = fresh_db();
    citron::set_data("a", "1");
    citron::create_snapshot("bad");
    write_raw(citron::snapshot_path("bad"), "CITRON" . pack("N", 2) . pack("N", 1));
    my $before = read_raw($file);

    dies_like(sub { citron::rollback("bad") }, qr/Snapshot 'bad' is unusable: Corrupt/, "refused");
    is(read_raw($file), $before, "database untouched");
};

subtest 'a corrupt database is not snapshotted' => sub {
    my $file = fresh_db();
    write_raw($file, "garbage");
    dies_like(sub { citron::create_snapshot() }, qr/Not a CitronDB file/, "refused");
    is_deeply([citron::list_snapshots()], [], "nothing saved");
};

subtest 'searches and caches follow a rollback' => sub {
    fresh_db();
    citron::set_data("apple", "x");
    citron::create_snapshot();
    citron::set_data("apricot", "y");
    is_deeply([sort keys %{ search_prefix::search_keys("ap") }], ["apple", "apricot"], "before");

    citron::rollback("1");
    is_deeply([sort keys %{ search_prefix::search_keys("ap") }], ["apple"], "after");
    is(citron::exists_data("apricot"), 0, "reads too");
};

subtest 'dropping snapshots' => sub {
    fresh_db();
    citron::create_snapshot("keep");
    citron::create_snapshot("gone");
    is(citron::delete_snapshot("gone"), 1, "existing");
    is(citron::delete_snapshot("gone"), 0, "missing");
    is(citron::delete_snapshot("../x"), 0, "invalid name");
    is_deeply([citron::list_snapshots()], ["keep"], "rest kept");
};

done_testing();
