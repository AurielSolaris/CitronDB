use strict;
use warnings;
use Test::More;

require "./test/lib.perl";

# Compatibility: databases written by older releases stay readable, and are
# upgraded safely. The fixtures were written by those releases' own code
# (see test/fixtures/generate.perl): v0.3 used format 1 (plain strings),
# v0.4 introduced format 2 (JSON), which v0.5.x still writes.

sub fixture {
    my ($name) = @_;
    my $file = fresh_db();
    write_raw($file, read_raw("test/fixtures/$name.citron"));
    return $file;
}

my $unicode = "caf\xc3\xa9 \xf0\x9f\x8d\x8b";

subtest 'v0.3 (format 1) is readable' => sub {
    my $file = fixture("v0.3");
    is(unpack("N", substr(read_raw($file), 6, 4)), 1, "fixture is format 1");

    is_deeply(citron::list(), {
        name     => "Ada Lovelace",
        greeting => "hello world",
        count    => "42",
        quoted   => '"02139"',
        "user:1" => '{"name":"Ada","tags":["math","code"]}',
        unicode  => $unicode,
        empty    => "",
    }, "every record, values as the strings they were stored as");

    ok(!ref citron::get_data("user:1"), "format 1 values stay strings, never reparsed as JSON");
    is(citron::to_text(citron::get_data("count")), "42", "numbers too");
};

subtest 'v0.3 is upgraded on the next write without losing data' => sub {
    my $file = fixture("v0.3");
    my $before = citron::list();

    citron::set_data("added", "1");
    is(unpack("N", substr(read_raw($file), 6, 4)), 2, "now format 2");
    my $after = citron::list();
    delete $after->{added};
    is_deeply($after, $before, "same data after the upgrade");
};

subtest 'v0.3 can be snapshotted and rolled back as-is' => sub {
    my $file = fixture("v0.3");
    my $bytes = read_raw($file);

    citron::create_snapshot("old");
    citron::set_data("x", "1");
    citron::rollback("old");
    is(read_raw($file), $bytes, "restores the original format 1 bytes");
    is(citron::get_data("name"), "Ada Lovelace", "still readable");
};

subtest 'v0.4 (format 2) is readable' => sub {
    fixture("v0.4");
    is_deeply(citron::list(), {
        name     => "Ada Lovelace",
        greeting => "hello world",
        count    => "42",
        quoted   => "02139",
        "user:1" => '{"name":"Ada","tags":["math","code"]}',
        unicode  => $unicode,
        empty    => "",
    }, "every record");
    is_deeply(citron::get_data("user:1"), { name => "Ada", tags => ["math", "code"] }, "JSON values");
    is(citron::get_data("count") + 0, 42, "numbers");
};

subtest 'this version writes the same bytes as v0.4' => sub {
    my $file = fresh_db();
    citron::set_data("name", "Ada Lovelace");
    citron::set_data("greeting", "hello world");
    citron::set_data("count", "42");
    citron::set_data("quoted", '"02139"');
    citron::set_data("user:1", '{"name":"Ada","tags":["math","code"]}');
    citron::set_data("unicode", $unicode);
    citron::set_data("empty", "");
    citron::set_data("deleted", "gone");
    citron::delete_data("deleted");

    is(read_raw($file), read_raw("test/fixtures/v0.4.citron"), "byte-identical, so older v0.4+ releases can read it");
};

subtest 'files from a newer format are refused, not damaged' => sub {
    my $file = fresh_db();
    my $future = "CITRON" . pack("N", 3) . pack("N", 0) . "new things";
    write_raw($file, $future);

    eval { citron::set_data("k", "v") };
    like($@, qr/version 3 is newer than supported version 2/, "refused");
    is(read_raw($file), $future, "untouched");
};

done_testing();
