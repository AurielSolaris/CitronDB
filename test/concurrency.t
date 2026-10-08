use strict;
use warnings;
use Test::More;

require "./test/lib.perl";

# Several processes writing at once must not lose each other's writes.
my $file = fresh_db();
my $procs = 4;
my $writes = 15;

my @pids;
for my $p (1 .. $procs) {
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        citron::set_data("p$p:$_", $_) for 1 .. $writes;
        exit 0;
    }

    push @pids, $pid;
}

waitpid($_, 0) for @pids;

is(scalar keys %{ citron::list() }, $procs * $writes, "no lost writes across $procs processes");

done_testing();
