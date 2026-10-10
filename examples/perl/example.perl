# CitronDB 🍋 from Perl.
#
#   perl examples/perl/example.perl      (from the project root)

use strict;
use warnings;
no warnings 'once';

require "./src/citron.perl";

$config::file = "example.citron";
citron::open_db();

# values are JSON; anything that isn't JSON is stored as a plain string
citron::set_data("user:1", '{"name":"Ada","age":36,"tags":["math","code"]}');
citron::set_data("user:2", '{"name":"Grace","age":85,"tags":["navy","cobol"]}');
citron::set_data("greeting", "hello world");
citron::set_data("visits", "0");

# read whole values, or drill in with a path
my $user = citron::get_data("user:1");
print "user:1 is $user->{name}, $user->{age}\n";
print "first tag of user:2: ", citron::get_data("user:2", "tags.0"), "\n";
print "last tag of user:2:  ", citron::get_data("user:2", "tags.-1"), "\n";

# update only touches existing keys
citron::update_data("visits", citron::get_data("visits") + 1);
print "visits: ", citron::get_data("visits"), "\n";
print "update on a missing key: ", citron::update_data("ghost", "1"), "\n";

# a missing key and a stored null are different
citron::set_data("nothing", "null");
my ($found) = citron::lookup("nothing");
print "nothing exists: ", citron::exists_data("nothing"), ", found: $found\n";

citron::delete_data("nothing");

print "\nall records:\n";
citron::get_all();

citron::export_json("example.json");
print "\nexported to example.json\n";
