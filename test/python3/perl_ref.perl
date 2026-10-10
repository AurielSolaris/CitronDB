# Reference side of the interop tests: runs operations through the Perl
# implementation so the bindings can be compared against it.
#
#   perl test/python3/perl_ref.perl <db> <ops file>
#
# Run from the project root. Each line of the ops file is tab-separated,
# hex-encoded fields: op, then its arguments. Output, one line per op that
# returns something, is hex-encoded too; "-" means missing, "!" means died.

use strict;
use warnings;
no warnings 'once';

require "./src/citron.perl";

$config::file = shift;
my $ops = shift;

citron::open_db();

open(my $in, "<:raw", $ops) or die "$ops: $!";
binmode(STDOUT);

while (my $line = <$in>) {
    $line =~ s/\r?\n\z//;
    my ($op, @args) = map { pack("H*", $_) } split(/\t/, $line, -1);

    my @out = eval {
        if ($op eq "set") {
            citron::set_data(@args);
            return ();
        }
        if ($op eq "get") {
            my ($found, $value) = citron::lookup(@args);
            return ($found ? unpack("H*", citron::to_text($value)) : "-");
        }
        if ($op eq "update") { return (citron::update_data(@args)) }
        if ($op eq "delete") { return (citron::delete_data(@args)) }
        if ($op eq "exists") { return (citron::exists_data(@args)) }
        if ($op eq "export") { return (citron::export_json(@args)) }
        if ($op eq "import") { return (citron::import_json(@args)) }
        if ($op eq "snapshot") { return (unpack("H*", citron::create_snapshot(length $args[0] ? $args[0] : undef))) }
        if ($op eq "snapshots") { return (unpack("H*", join(",", citron::list_snapshots()))) }
        if ($op eq "rollback") { return (citron::rollback(@args)) }
        if ($op eq "dropsnapshot") { return (citron::delete_snapshot(@args)) }
        die "unknown op '$op'\n";
    };
    @out = ("!") if $@;

    print "$_\n" for @out;
}
