use strict;
use warnings;
no warnings 'once';
use Test::More;
use Time::HiRes qw(sleep);

require "./test/lib.perl";

# Durability: a write that returned has reached the file, and a crash (the
# process killed at any moment) never leaves a damaged database. Crashes
# are simulated by killing worker processes with SIGKILL / TerminateProcess,
# so no cleanup code runs. Power loss can't be simulated here; it's what the
# fsync before each rename is for.

srand(666);

subtest 'acknowledged writes survive a crash' => sub {
    for my $round (1 .. 8) {
        my $file = fresh_db();
        my $worker = start_worker("write", $file, "k", 1_000_000);

        # let it finish a random number of writes, then kill it mid-stream
        my $want = 5 + int(rand(40));
        my $acked = 0;
        while ($acked < $want) {
            my $line = worker_line($worker);
            die "worker ended early" unless defined $line;
            $acked++ if $line =~ /^ack /;
        }
        kill_worker($worker);

        citron::open_db();   # what a restart does: removes the stale temp file
        ok(!-e "$file.tmp", "round $round: no temp file left after restart");

        my $data = eval { citron::list() };
        ok($data, "round $round: database readable after the crash") or diag($@);

        my @missing = grep { !defined $data->{"k$_"} || $data->{"k$_"} ne $_ } 0 .. $acked - 1;
        is_deeply(\@missing, [], "round $round: all $acked acknowledged writes present");
        cmp_ok(scalar keys %$data, "<=", $acked + 1, "round $round: at most the in-flight write extra");
    }
};

subtest 'a multi-key write is all or nothing' => sub {
    my $json = "$config::file.import.json";
    open(my $fh, ">:raw", $json) or die;
    print $fh "{", join(",", map { qq("i$_":$_) } 1 .. 3000), "}";
    close($fh);

    for my $round (1 .. 6) {
        my $file = fresh_db();
        citron::set_data("original", "kept");

        my $worker = start_worker("import", $file, $json);
        sleep(rand(0.4));
        kill_worker($worker);

        citron::open_db();
        my $data = citron::list();
        my $imported = grep { /^i/ } keys %$data;
        ok($imported == 0 || $imported == 3000, "round $round: import fully applied or not at all ($imported)");
        is($data->{original}, "kept", "round $round: existing data intact");
    }
};

subtest 'data written by one process is seen after a restart' => sub {
    my $file = fresh_db();

    my @lines = finish_worker(start_worker("write", $file, "r", 3));
    is($lines[-1], "ack 2", "writer finished");

    # a brand new process, like reopening after a restart
    is_deeply([finish_worker(start_worker("get", $file, "r2"))], ["value 2"], "fresh process reads it");
    is(citron::get_data("r1"), 1, "and so does this one");
};

subtest 'stale temp files from a crash are ignored and removed' => sub {
    my $file = fresh_db();
    citron::set_data("k", "v");

    write_raw("$file.tmp", "CITRON half-written garbage");
    is(citron::get_data("k"), "v", "reads ignore the temp file");

    citron::open_db();
    ok(!-e "$file.tmp", "open removes it");
    is(citron::get_data("k"), "v", "data intact");
};

done_testing();
