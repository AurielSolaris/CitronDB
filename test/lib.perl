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

1;
