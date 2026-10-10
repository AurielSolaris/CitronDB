# Writes a fixture database with a release's own code, for test/compat.t.
# Run it from a checkout of that release (its src/ must be in the current
# directory):
#
#   git worktree add /tmp/v0.4 764ff6a
#   cd /tmp/v0.4 && perl /path/to/test/fixtures/generate.perl v0.4.citron
#
# v0.3.citron came from b7bd320 (format 1), v0.4.citron from 764ff6a
# (format 2). v0.5 and v0.5.1 write the same bytes as v0.4.

no warnings;
require "./src/citron.perl";

$config::file = shift;
open(my $fh, ">:raw", $config::file) or die;
close($fh);

citron::open_db() if defined &citron::open_db;
citron::set_data("name", "Ada Lovelace");
citron::set_data("greeting", "hello world");
citron::set_data("count", "42");
citron::set_data("quoted", '"02139"');
citron::set_data("user:1", '{"name":"Ada","tags":["math","code"]}');
citron::set_data("unicode", "caf\xc3\xa9 \xf0\x9f\x8d\x8b");
citron::set_data("empty", "");
citron::set_data("deleted", "gone");
citron::delete_data("deleted") if defined &citron::delete_data;
