use strict;
use warnings;
no warnings 'once';
use Test::More;
use Time::HiRes qw(sleep);

require "./test/lib.perl";

# Recovery: rolling back to a snapshot (a commit point) restores exactly
# that state, atomically, even if the process dies part-way through.
# Snapshot semantics are in snapshot.t; this is about crashes.

srand(666);

sub snapshot_bytes {
    my ($name) = @_;
    return read_raw(citron::snapshot_path($name));
}

subtest 'rollback is atomic under a crash' => sub {
    my $file = fresh_db();

    # two very different commit points
    citron::import_json(json_file({ map { ("a$_" => "first $_") } 1 .. 2000 }));
    make_snapshot_pair();

    my %states = map { snapshot_bytes($_) => $_ } qw(first second);

    for my $round (1 .. 8) {
        my $worker = start_worker("rollback", $file, 1_000_000, "first", "second");
        my $want = 1 + int(rand(6));
        my $last;
        for (1 .. $want) {
            $last = worker_line($worker);
            die "worker ended early" unless defined $last && $last =~ /^ack (\w+)/;
        }
        sleep(rand(0.05));
        kill_worker($worker);

        citron::open_db();
        my $now = read_raw($file);
        ok(exists $states{$now}, "round $round: database is exactly one snapshot ($states{$now})")
            or diag("got " . length($now) . " bytes");
        ok(eval { citron::list(); 1 }, "round $round: readable");
    }
};

subtest 'snapshots survive a crash while being created' => sub {
    my $file = fresh_db();
    citron::set_data("k", "v");
    my $expected = read_raw($file);

    my $worker = start_worker("snapshot", $file, 1_000_000);
    my @acked;
    while (@acked < 5 + int(rand(10))) {
        my $line = worker_line($worker);
        die "worker ended early" unless defined $line && $line =~ /^ack (\d+)/;
        push @acked, $1;
    }
    kill_worker($worker);

    my @names = citron::list_snapshots();
    ok(scalar(@names) >= @acked, "every acknowledged snapshot listed");
    is_deeply([@names[0 .. $#acked]], \@acked, "numbered in order");
    is(snapshot_bytes($_), $expected, "snapshot $_ is complete") for @names;

    my $next = citron::create_snapshot();
    ok($next > $names[-1], "numbering continues after the crash ($next)");
};

subtest 'a rollback that returned is durable' => sub {
    my $file = fresh_db();
    citron::set_data("v", "old");
    citron::create_snapshot("old");
    citron::set_data("v", "new");

    citron::rollback("old");
    is_deeply([finish_worker(start_worker("get", $file, "v"))], ["value old"],
        "a fresh process sees the rolled-back state");
};

done_testing();

# --- helpers --------------------------------------------------------------

sub json_file {
    my ($data) = @_;
    my $path = "$config::file.json";
    open(my $fh, ">:raw", $path) or die;
    print $fh JSON::PP->new->encode($data);
    close($fh);
    return $path;
}

# Two snapshots of different sizes: "first" (the current data) and "second".
sub make_snapshot_pair {
    citron::create_snapshot("first");
    citron::import_json(json_file({ map { ("b$_" => "second $_") } 1 .. 500 }));
    citron::delete_data("a$_") for 1 .. 50;
    citron::create_snapshot("second");
}
