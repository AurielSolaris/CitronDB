# Shared setup: load CitronDB and point it at a fresh database in a temp dir.
# Tests must be run from the project root: prove test/

use File::Temp qw(tempdir);

require "./src/citron.perl";

my $dir = tempdir(CLEANUP => 1);
my $n = 0;

sub fresh_db {
    $config::file = "$dir/test" . $n++ . ".citron";
    citron::open_db();
    return $config::file;
}

sub write_raw {
    my ($file, $bytes) = @_;
    open(my $fh, ">:raw", $file) or die "$file: $!";
    print $fh $bytes;
    close($fh);
}

sub read_raw {
    my ($file) = @_;
    open(my $fh, "<:raw", $file) or die "$file: $!";
    local $/;
    return scalar <$fh>;
}

# --- worker processes (test/worker.perl) ----------------------------------

use IPC::Open3;

# On Windows, arguments are joined into one command line.
sub quote_arg {
    my ($arg) = @_;
    return $arg unless $^O eq 'MSWin32';
    $arg =~ s/"/\\"/g;
    return qq("$arg");
}

# Starts a worker; returns { pid, out } where out yields its output lines.
sub start_worker {
    my (@args) = @_;
    my $pid = open3(my $in, my $out, undef, $^X, "test/worker.perl", map { quote_arg($_) } @args);
    close($in);
    return { pid => $pid, out => $out };
}

# Next output line of a worker (without the newline), or undef at the end.
sub worker_line {
    my ($worker) = @_;
    my $fh = $worker->{out};
    my $line = <$fh>;
    $line =~ s/\r?\n\z// if defined $line;
    return $line;
}

# Waits for a worker to finish; returns all its remaining output lines.
sub finish_worker {
    my ($worker) = @_;
    my @lines;
    while (defined(my $line = worker_line($worker))) {
        push @lines, $line;
    }
    waitpid($worker->{pid}, 0);
    return @lines;
}

# Kills a worker abruptly (no cleanup runs), like a crash.
sub kill_worker {
    my ($worker) = @_;
    kill('KILL', $worker->{pid});
    waitpid($worker->{pid}, 0);
    close($worker->{out});
}

1;
