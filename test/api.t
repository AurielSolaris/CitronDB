use strict;
use warnings;
use utf8;
use Test::More;

require "./test/lib.perl";

subtest 'set / get / exists' => sub {
    fresh_db();

    citron::set_data("name", "Ada");
    is(citron::get_data("name"), "Ada", "plain text is stored as a string");
    is(citron::exists_data("name"), 1, "exists after set");
    is(citron::exists_data("nope"), 0, "missing key does not exist");
    is(citron::get_data("nope"), undef, "missing key returns undef");

    my ($found) = citron::lookup("nope");
    ok(!$found, "lookup reports missing key");

    citron::set_data("name", "Grace");
    is(citron::get_data("name"), "Grace", "set overwrites (upsert)");

    citron::set_data("nothing", "null");
    ($found, my $value) = citron::lookup("nothing");
    ok($found && !defined $value, "JSON null is distinct from a missing key");
};

subtest 'update only touches existing keys' => sub {
    fresh_db();

    is(citron::update_data("ghost", "x"), 0, "update on missing key fails");
    is(citron::exists_data("ghost"), 0, "and does not create it");

    citron::set_data("k", "1");
    is(citron::update_data("k", "2"), 1, "update on existing key succeeds");
    is(citron::get_data("k"), 2, "value updated");
};

subtest 'writing an unchanged value skips the write' => sub {
    my $file = fresh_db();

    # a version 1 file would be upgraded by any real write
    my $v1 = "CITRON" . pack("N", 1) . pack("N", 1) . pack("N", 1) . "k" . pack("N", 5) . "hello";
    write_raw($file, $v1);

    is(citron::update_data("k", '"hello"'), 1, "update reports success");
    citron::set_data("k", "hello");
    is(read_raw($file), $v1, "file untouched");

    citron::set_data("k", "bye");
    isnt(read_raw($file), $v1, "a real change is written");
    is(citron::get_data("k"), "bye", "and read back");
};

subtest 'delete reports whether a key existed' => sub {
    fresh_db();

    citron::set_data("k", "v");
    is(citron::delete_data("k"), 1, "delete existing key");
    is(citron::delete_data("k"), 0, "delete missing key");
    is(citron::exists_data("k"), 0, "key gone");
};

subtest 'JSON values' => sub {
    fresh_db();

    citron::set_data("user:1", '{"name":"Ada","age":36,"tags":["math","code"],"address":{"city":"London"}}');
    citron::set_data("n", "42");
    citron::set_data("f", "true");
    citron::set_data("s", '"42"');
    citron::set_data("broken", '{"half":');

    my $user = citron::get_data("user:1");
    is_deeply($user, { name => "Ada", age => 36, tags => ["math", "code"], address => { city => "London" } },
        "objects round-trip");

    is(citron::get_data("n") + 0, 42, "numbers parse as numbers");
    is(citron::to_text(citron::get_data("s")), "42", "quoted JSON string stays a string");
    is(citron::to_text(citron::get_data("f")), "true", "booleans print as true");
    is(citron::get_data("broken"), '{"half":', "invalid JSON is stored as a plain string");
    is(citron::to_text($user), '{"address":{"city":"London"},"age":36,"name":"Ada","tags":["math","code"]}',
        "objects print as canonical JSON");
};

subtest 'paths' => sub {
    fresh_db();

    citron::set_data("user:1", '{"name":"Ada","tags":["math","code"],"address":{"city":"London"}}');

    is(citron::get_data("user:1", "name"), "Ada", "top-level field");
    is(citron::get_data("user:1", "address.city"), "London", "nested field");
    is(citron::get_data("user:1", "tags.1"), "code", "array index");
    is(citron::get_data("user:1", "tags.-1"), "code", "negative array index");

    my ($found) = citron::lookup("user:1", "address.zip");
    ok(!$found, "missing field");
    ($found) = citron::lookup("user:1", "tags.5");
    ok(!$found, "out-of-range index");
    ($found) = citron::lookup("user:1", "name.first");
    ok(!$found, "path into a string");
};

subtest 'unicode' => sub {
    fresh_db();

    my $lemon = "citron 🍋";
    utf8::encode($lemon); # command-line input arrives as UTF-8 bytes

    citron::set_data("fruit", $lemon);
    is(citron::to_text(citron::get_data("fruit")), $lemon, "unicode plain text round-trips");

    citron::set_data("obj", '{"emoji":"' . $lemon . '"}');
    is(citron::to_text(citron::get_data("obj", "emoji")), $lemon, "unicode inside JSON round-trips");
};

subtest 'list returns readable text for search modules' => sub {
    fresh_db();

    citron::set_data("a", "hello");
    citron::set_data("b", '{"x":1}');

    is_deeply(citron::list(), { a => "hello", b => '{"x":1}' }, "list");
    is_deeply(citron::list_values(), { a => "hello", b => { x => 1 } }, "list_values");
};

subtest 'export / import' => sub {
    my $src = fresh_db();
    citron::set_data("a", "hello");
    citron::set_data("b", '{"x":[1,2]}');

    my $path = "$src.export.json";
    is(citron::export_json($path), 2, "exported 2 records");

    fresh_db();
    citron::set_data("a", "old");
    citron::set_data("keep", "me");
    is(citron::import_json($path), 2, "imported 2 records");

    is(citron::get_data("a"), "hello", "import replaces existing keys");
    is_deeply(citron::get_data("b"), { x => [1, 2] }, "import preserves JSON");
    is(citron::get_data("keep"), "me", "import keeps other keys");

    write_raw("$src.bad.json", "[1,2,3]");
    eval { citron::import_json("$src.bad.json") };
    like($@, qr/JSON object/, "import rejects non-object JSON");

    write_raw("$src.bad2.json", "{nope");
    eval { citron::import_json("$src.bad2.json") };
    like($@, qr/Invalid JSON/, "import rejects malformed JSON");
};

done_testing();
