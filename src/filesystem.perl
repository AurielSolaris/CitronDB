package filesystem;

my $data = '';

sub open_file {
    my ($file) = @_;

    open(FILE, "<$file")
        or die "Could not open file '$file' $!";

    $data = '';

    while(<FILE>) {
        $data .= $_;
    }

    close(FILE);
}

sub create_file {
    my ($file) = @_;

    open(FILE, ">$file")
        or die "Could not create file '$file' $!";

    close(FILE);
}

sub write_file {
    my ($file) = @_;

    open(FILE, ">$file")
        or die "Could not write to file '$file' $!";

    print FILE convert_to_hex($data);

    close(FILE);
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
    return convert_from_hex($data);
}

sub file_exists {
    my ($file) = @_;

    return -e $file;
}

666;