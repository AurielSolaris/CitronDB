package filesystem;

use IO::Handle;

my $data = '';

sub open_file {
    my ($file) = @_;

    open(FILE, "<:raw", $file)
        or die "Could not open file '$file' $!";

    $data = '';

    while(<FILE>) {
        $data .= $_;
    }

    close(FILE);
}

sub create_file {
    my ($file) = @_;

    open(FILE, ">:raw", $file)
        or die "Could not create file '$file' $!";

    close(FILE);
}

sub write_file {
    my ($file) = @_;

    my $tmp = "$file.tmp";

    open(FILE, ">:raw", $tmp)
        or die "Could not write to file '$tmp' $!";

    print FILE $data;

    FILE->sync()
        or die "Could not sync file '$tmp' $!";

    close(FILE);

    rename($tmp, $file)
        or die "Could not rename '$tmp' to '$file' $!";
}

sub cleanup_tmp {
    my ($file) = @_;

    my $tmp = "$file.tmp";
    unlink($tmp) if -e $tmp;
}

sub convert_to_hex {
    my ($string) = @_;

    return unpack("H*", $string);
}

sub convert_from_hex {
    my ($hex) = @_;

    return pack("H*", $hex);
}

sub set_data {
    my ($new_data) = @_;

    $data = $new_data;
}

sub get_data {
    return $data;
}

sub file_exists {
    my ($file) = @_;

    return -e $file;
}

666;