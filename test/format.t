use strict;
use warnings;
use Test::More;

require "./test/lib.perl";

sub record { my ($k, $v) = @_; pack("N", length $k) . $k . pack("N", length $v) . $v }

subtest 'open_db' => sub {
    my $file = fresh_db();
    ok(-e $file, "creates the database file");
    is(read_raw($file), "CITRON" . pack("N", 2) . pack("N", 0), "empty v2 header");

    write_raw("$file.tmp", "half-written");
    citron::open_db();
    ok(!-e "$file.tmp", "removes stale temp file");
};

subtest 'empty file is treated as an empty database' => sub {
    my $file = fresh_db();
    write_raw($file, "");
    is_deeply(citron::list(), {}, "no records");
    citron::set_data("k", "v");
    is(citron::get_data("k"), "v", "writable");
};

subtest 'corruption is reported, never silently overwritten' => sub {
    my $file = fresh_db();

    write_raw($file, "NOTCITRON-garbage");
    eval { citron::set_data("k", "v") };
    like($@, qr/Not a CitronDB file/, "bad magic dies");
    is(read_raw($file), "NOTCITRON-garbage", "file left untouched");

    my $good = "CITRON" . pack("N", 2) . pack("N", 2) . record("a", '"1"') . record("b", '"2"');

    write_raw($file, substr($good, 0, length($good) - 2));
    eval { citron::list() };
    like($@, qr/truncated/, "truncated file dies");

    write_raw($file, $good . "xx");
    eval { citron::list() };
    like($@, qr/trailing bytes/, "trailing garbage dies");

    write_raw($file, "CITRON" . pack("N", 99) . pack("N", 0));
    eval { citron::list() };
    like($@, qr/newer than supported/, "future version dies");

    write_raw($file, "CITRON" . pack("N", 2) . pack("N", 5000) . record("a", '"1"'));
    eval { citron::list() };
    like($@, qr/truncated/, "record count larger than data dies");
};

subtest 'v1 files are migrated' => sub {
    my $file = fresh_db();

    write_raw($file, "CITRON" . pack("N", 1) . pack("N", 2) . record("name", "Ada") . record("n", "42"));

    is(citron::get_data("name"), "Ada", "v1 value readable");
    is(citron::to_text(citron::get_data("n")), "42", "v1 values are read as strings");
    ok(!ref citron::get_data("n"), "not a JSON structure");

    citron::set_data("x", "y");
    is(unpack("N", substr(read_raw($file), 6, 4)), 2, "rewritten as v2 on next write");
    is(citron::get_data("name"), "Ada", "data intact after migration");
};

subtest 'writes are atomic and leave no temp file' => sub {
    my $file = fresh_db();
    citron::set_data("k", "v");
    ok(!-e "$file.tmp", "no temp file after write");
};

done_testing();
