use strict;
use warnings;
use Test::More;

require "./test/lib.perl";

# Concurrency: processes sharing one database can't silently lose each
# other's writes, and readers never see a half-written file. Workers are
# separate processes (test/worker.perl) taking the same locks as any user.

sub all_acked {
    my (@lines) = @_;
    my @errors = grep { /^error/ } @lines;
    diag($_) for @errors;
    return !@errors;
}

subtest 'writers to different keys lose nothing' => sub {
    my $file = fresh_db();
    my ($procs, $writes) = (4, 25);

    my @workers = map { start_worker("write", $file, "p$_:", $writes) } 1 .. $procs;
    ok(all_acked(finish_worker($_)), "writer finished cleanly") for @workers;

    my $data = citron::list();
    is(scalar keys %$data, $procs * $writes, "no lost writes across $procs processes");
    my @wrong = grep { my ($i) = /(\d+)$/; $data->{$_} ne $i } keys %$data;
    is_deeply(\@wrong, [], "every value correct");
};

subtest 'writers to the same keys interleave whole writes' => sub {
    my $file = fresh_db();
    my @keys = qw(hot cold);

    my @workers = map { start_worker("overwrite", $file, "w$_", 20, @keys) } 1 .. 4;
    ok(all_acked(finish_worker($_)), "writer finished cleanly") for @workers;

    my $data = citron::list();
    is_deeply([sort keys %$data], [sort @keys], "only the shared keys");
    like($data->{$_}, qr/^w[1-4]:19$/, "$_ holds some writer's last write") for @keys;
};

subtest 'readers never see a partial file' => sub {
    my $file = fresh_db();
    citron::set_data("seed", "x");

    my @readers = map { start_worker("read", $file, 150) } 1 .. 3;
    my @writers = map { start_worker("write", $file, "w$_:", 40) } 1 .. 3;

    ok(all_acked(finish_worker($_)), "writer finished cleanly") for @writers;
    for my $reader (@readers) {
        my @lines = finish_worker($reader);
        ok(all_acked(@lines) && $lines[-1] eq "ack 149", "reader read 150 times without an error");
    }
    is(scalar keys %{ citron::list() }, 1 + 3 * 40, "all writes landed");
};

subtest 'concurrent snapshots get unique numbers' => sub {
    my $file = fresh_db();
    citron::set_data("k", "v");

    my @workers = map { start_worker("snapshot", $file, 5) } 1 .. 4;
    my @names;
    for my $worker (@workers) {
        my @lines = finish_worker($worker);
        ok(all_acked(@lines), "snapshotter finished cleanly");
        push @names, map { /^ack (\d+)/ ? $1 : () } @lines;
    }

    is_deeply([sort { $a <=> $b } @names], [1 .. 20], "20 snapshots numbered 1 to 20, none shared");
    is_deeply([citron::list_snapshots()], [1 .. 20], "all listed");
};

subtest 'rollbacks racing with writers leave a valid database' => sub {
    my $file = fresh_db();
    citron::set_data("base", "1");
    citron::create_snapshot("a");
    citron::set_data("extra", "2");
    citron::create_snapshot("b");

    my @workers = (start_worker("rollback", $file, 30, "a", "b"),
                   map { start_worker("write", $file, "w$_:", 20) } 1 .. 2);
    ok(all_acked(finish_worker($_)), "worker finished cleanly") for @workers;

    my $data = eval { citron::list() };
    ok($data, "database readable") or diag($@);
    is($data->{base}, "1", "snapshot data present");
};

done_testing();
