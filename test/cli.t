use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use IPC::Open3;

# End-to-end tests through main.perl, as a user would run it.

my $dir = tempdir(CLEANUP => 1);
my $db = "$dir/cli.citron";

# On Windows, arguments are joined into one command line, so quotes inside
# JSON must be escaped or they get stripped.
sub win_quote {
    my ($arg) = @_;
    return $arg unless $^O eq 'MSWin32';
    $arg =~ s/"/\\"/g;
    return qq("$arg");
}

sub citron {
    my $pid = open3(my $in, my $out, undef, $^X, "src/main.perl", map { win_quote($_) } "--file=$db", @_);
    close($in);

    my $text = do { local $/; <$out> };
    waitpid($pid, 0);
    $text =~ s/\r\n/\n/g;

    # drop the startup banner
    $text =~ s/\A.*?CitronDB (?:created|already exists)\n//s;
    return $text;
}

is(citron("set", "user:1", '{"name":"Ada","tags":["math"]}'), "OK\n", "set");
is(citron("get", "user:1"), qq({"name":"Ada","tags":["math"]}\n), "get prints JSON");
is(citron("get", "user:1", "name"), "Ada\n", "get with path");
is(citron("get", "user:1", "tags.0"), "math\n", "get with array path");
is(citron("get", "missing"), "(nil)\n", "get missing key");
is(citron("exists", "user:1"), "(integer) 1\n", "exists");
like(citron("update", "ghost", "x"), qr/^\(error\) no such key 'ghost'/, "update missing key");
is(citron("update", "user:1", "replaced"), "OK\n", "update existing key");
is(citron("delete", "user:1"), "(integer) 1\n", "delete existing key");
is(citron("delete", "user:1"), "(integer) 0\n", "delete missing key");
like(citron("set", "lonely"), qr/^\(error\) usage: set/, "set without value");

citron("set", "a", "1");
citron("set", "b", '{"x":2}');
is(citron("export", "$dir/out.json"), "Exported 2 records to $dir/out.json\n", "export");
citron("delete", "a");
is(citron("import", "$dir/out.json"), "Imported 2 records from $dir/out.json\n", "import");
is(citron("get", "a"), "1\n", "imported value");

open(my $fh, ">:raw", $db) or die;
print $fh "garbage";
close($fh);
like(citron("get", "a"), qr/\(error\) Not a CitronDB file/, "corrupt file reported, not overwritten");

done_testing();
