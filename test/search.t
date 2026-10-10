use strict;
use warnings;
use utf8;
use Test::More;

require "./test/lib.perl";
require "./src/search_binary.perl";
require "./src/search_regex.perl";
require "./src/search_fuzzy.perl";
require "./src/search_prefix.perl";
require "./src/search_suffix.perl";
require "./src/search_levenshtein.perl";
require "./src/search_soundex.perl";
require "./src/search_substring.perl";

sub keys_of { [sort keys %{ $_[0] }] }

sub fixture {
    fresh_db();
    citron::set_data("apple", "red fruit");
    citron::set_data("apply", "verb");
    citron::set_data("banana", "yellow fruit");
    citron::set_data("Robert", "Rupert");
    citron::set_data("user:1", '{"name":"Ada","tags":["math"]}');
    citron::set_data("user:2", '{"name":"Grace"}');
    citron::set_data("n", "42");
    citron::set_data("f", "1.50");
    citron::set_data("same1", "twin");
    citron::set_data("same2", "twin");
    citron::set_data("esc", "line\nbreak \"quoted\"");
    citron::set_data("café", "été");
    citron::set_data("nothing", "null");
    return $config::file;
}

subtest 'list gives readable text' => sub {
    fixture();
    my $list = citron::list();
    is($list->{"apple"}, "red fruit", "string");
    is($list->{"user:1"}, '{"name":"Ada","tags":["math"]}', "object as JSON");
    is($list->{"n"}, "42", "number");
    is($list->{"f"}, "1.5", "canonical number");
    is($list->{"esc"}, "line\nbreak \"quoted\"", "escaped string is unescaped");
    is($list->{"nothing"}, "null", "null");
    my $cafe = "café";
    utf8::encode($cafe);
    my $ete = "été";
    utf8::encode($ete);
    is($list->{$cafe}, $ete, "UTF-8 key and value as bytes");
};

subtest 'binary (exact match)' => sub {
    fixture();
    is_deeply(keys_of(search_binary::search_keys("apple")), ["apple"], "key");
    is_deeply(keys_of(search_binary::search_keys("appl")), [], "no partial key");
    is_deeply(keys_of(search_binary::search_values("twin")), ["same1", "same2"], "every equal value");
    is_deeply(keys_of(search_binary::search_values("42")), ["n"], "number value");
    is_deeply(keys_of(search_binary::search_pairs("apple")), ["apple"], "pairs");
    is_deeply(search_binary::search_pairs("apple"), { apple => "red fruit" }, "results hold text");
};

subtest 'substring' => sub {
    fixture();
    is_deeply(keys_of(search_substring::search_keys("ppl")), ["apple", "apply"], "keys");
    is_deeply(keys_of(search_substring::search_values("fruit")), ["apple", "banana"], "values");
    is_deeply(keys_of(search_substring::search_pairs("Ada")), ["user:1"], "inside JSON");
};

subtest 'regex' => sub {
    fixture();
    is_deeply(keys_of(search_regex::search_keys('^user:\d$')), ["user:1", "user:2"], "keys");
    is_deeply(keys_of(search_regex::search_values('fruit$')), ["apple", "banana"], "values");
    is_deeply(keys_of(search_regex::search_pairs('^appl')), ["apple", "apply"], "pairs");
};

subtest 'prefix and suffix (case-insensitive)' => sub {
    fixture();
    is_deeply(keys_of(search_prefix::search_keys("APP")), ["apple", "apply"], "prefix keys");
    is_deeply(keys_of(search_prefix::search_values("Red")), ["apple"], "prefix values");
    is_deeply(keys_of(search_prefix::search_pairs("rob")), ["Robert"], "prefix pairs");
    is_deeply(keys_of(search_prefix::search_keys("a.")), [], "pattern is literal");
    is_deeply(keys_of(search_suffix::search_keys("LY")), ["apply"], "suffix keys");
    is_deeply(keys_of(search_suffix::search_values("FRUIT")), ["apple", "banana"], "suffix values");
};

subtest 'fuzzy (characters in order)' => sub {
    fixture();
    is_deeply(keys_of(search_fuzzy::search_keys("apl")), ["apple", "apply"], "keys");
    is_deeply(keys_of(search_fuzzy::search_values("yfr")), ["banana"], "values");
    is_deeply(keys_of(search_fuzzy::search_pairs("BNN")), ["banana"], "case-insensitive");
    is_deeply(keys_of(search_fuzzy::search_keys("a.")), [], "metacharacters are literal");
};

subtest 'soundex' => sub {
    fixture();
    is(search_soundex::soundex("Robert"), "R163", "Robert");
    is(search_soundex::soundex("Rupert"), "R163", "Rupert");
    is_deeply(keys_of(search_soundex::search_keys("Rupert")), ["Robert"], "keys");
    is_deeply(keys_of(search_soundex::search_values("Robert")), ["Robert"], "values");
};

subtest 'levenshtein' => sub {
    fixture();
    is(search_levenshtein::levenshtein("kitten", "sitting"), 3, "kitten/sitting");
    is(search_levenshtein::levenshtein("", "abc"), 3, "empty");
    is(search_levenshtein::levenshtein("abc", "abc"), 0, "equal");
    is(search_levenshtein::levenshtein("flaw", "lawn"), 2, "flaw/lawn");
    is_deeply(keys_of(search_levenshtein::search_keys("aple")), ["apple", "apply"], "keys");
    is_deeply(keys_of(search_levenshtein::search_keys("aple", 1)), ["apple"], "threshold");
    is_deeply(keys_of(search_levenshtein::search_values("verbs")), ["apply"], "values");
    is_deeply(keys_of(search_levenshtein::search_pairs("n", 0)), ["n"], "pairs");
};

subtest 'indexes follow writes' => sub {
    fixture();
    is_deeply(keys_of(search_prefix::search_keys("app")), ["apple", "apply"], "before");

    citron::set_data("appendix", "x");
    citron::delete_data("apply");
    is_deeply(keys_of(search_prefix::search_keys("app")), ["appendix", "apple"], "after set and delete");

    citron::update_data("apple", "twin");
    is_deeply(keys_of(search_binary::search_values("twin")), ["apple", "same1", "same2"],
        "after update");
    is_deeply(keys_of(search_suffix::search_values("fruit")), ["banana"], "old value gone");
};

subtest 'indexes see writes by other processes' => sub {
    my $file = fixture();
    is_deeply(keys_of(search_soundex::search_keys("Rupert")), ["Robert"], "before");

    # another process rewrites the file behind this one's back
    my $other = "$file.other";
    {
        local $config::file = $other;
        citron::open_db();
        citron::set_data("Rupert", "x");
    }
    write_raw($file, read_raw($other));

    is_deeply(keys_of(search_soundex::search_keys("Robert")), ["Rupert"], "after");
    is_deeply(citron::list(), { Rupert => "x" }, "list too");
};

subtest 'list returns a copy' => sub {
    fixture();
    my $list = citron::list();
    $list->{apple} = "changed";
    delete $list->{banana};
    is(citron::list()->{apple}, "red fruit", "changes don't leak into the cache");
    is_deeply(keys_of(search_binary::search_keys("banana")), ["banana"], "or into searches");
};

subtest 'searching an empty database' => sub {
    fresh_db();
    for my $module (qw(search_binary search_substring search_regex search_prefix search_suffix
                       search_fuzzy search_soundex search_levenshtein)) {
        no strict 'refs';
        is_deeply(&{"${module}::search_pairs"}("x"), {}, "$module finds nothing");
    }
};

done_testing();
