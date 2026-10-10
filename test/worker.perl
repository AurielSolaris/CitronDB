# A separate process for the durability, recovery and concurrency tests:
# they start workers, let them run, and sometimes kill them mid-operation.
# Run from the project root:
#
#   perl test/worker.perl <mode> <db> [args...]
#
# Workers print one line per finished operation ("ack ..."), flushed
# immediately, so a test knows exactly which operations completed before a
# kill. Errors are printed as "error: ..." instead of dying.

use strict;
use warnings;
no warnings 'once';

require "./src/citron.perl";

$| = 1;

my ($mode, $db, @args) = @ARGV;
$config::file = $db;

my %modes = (
    # set <prefix><i> = <i> for i in 0..count-1
    write => sub {
        my ($prefix, $count) = @_;
        for my $i (0 .. $count - 1) {
            citron::set_data("$prefix$i", $i);
            print "ack $i\n";
        }
    },

    # set the same keys over and over: <key> = "<tag>:<i>"
    overwrite => sub {
        my ($tag, $count, @keys) = @_;
        for my $i (0 .. $count - 1) {
            citron::set_data($_, "$tag:$i") for @keys;
            print "ack $i\n";
        }
    },

    # read everything repeatedly; any error means a reader saw a bad file
    read => sub {
        my ($count) = @_;
        for my $i (0 .. $count - 1) {
            citron::list();
            print "ack $i\n";
        }
    },

    # merge a JSON file in one write
    import => sub {
        my ($file) = @_;
        print "ack ", citron::import_json($file), "\n";
    },

    # numbered snapshots
    snapshot => sub {
        my ($count) = @_;
        print "ack ", citron::create_snapshot(), "\n" for 1 .. $count;
    },

    # roll back to each named snapshot in turn
    rollback => sub {
        my ($count, @names) = @_;
        for my $i (0 .. $count - 1) {
            my $name = $names[$i % @names];
            citron::rollback($name) or die "no snapshot '$name'\n";
            print "ack $name\n";
        }
    },

    # print a value, to check what a fresh process sees
    get => sub {
        my ($key) = @_;
        my ($found, $value) = citron::lookup($key);
        print $found ? "value " . citron::to_text($value) . "\n" : "missing\n";
    },
);

my $run = $modes{$mode} or die "unknown mode '$mode'\n";
eval { $run->(@args); 1 } or print "error: $@";
