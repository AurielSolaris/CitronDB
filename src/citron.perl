package citron;

require "./src/filesystem.perl";
require "./src/config.perl";

my $arr = {};
my $VERSION = 1;
my $MAGIC = "CITRON";

sub serialize {
    my ($arr) = @_;

    my $count = scalar keys %$arr;
    my $binary = '';

    $binary .= pack("H*", unpack("H*", $MAGIC));
    $binary .= pack("N", $VERSION);
    $binary .= pack("N", $count);

    foreach my $key (keys %$arr) {
        my $value = $arr->{$key};
        my $key_hex = unpack("H*", $key);
        my $value_hex = unpack("H*", $value);

        $binary .= pack("N", length($key));
        $binary .= pack("H*", $key_hex);
        $binary .= pack("N", length($value));
        $binary .= pack("H*", $value_hex);
    }

    return $binary;
}

sub deserialize {
    my ($binary) = @_;

    my %arr = ();
    my $offset = 0;

    my $magic = substr($binary, $offset, length($MAGIC));
    $offset += length($MAGIC);

    return \%arr if $magic ne $MAGIC;

    my $version = unpack("N", substr($binary, $offset, 4));
    $offset += 4;

    my $count = unpack("N", substr($binary, $offset, 4));
    $offset += 4;

    for (my $i = 0; $i < $count; $i++) {
        my $key_len = unpack("N", substr($binary, $offset, 4));
        $offset += 4;

        my $key = substr($binary, $offset, $key_len);
        $offset += $key_len;

        my $value_len = unpack("N", substr($binary, $offset, 4));
        $offset += 4;

        my $value = substr($binary, $offset, $value_len);
        $offset += $value_len;

        $arr{$key} = $value;
    }

    return \%arr;
}

sub set_data {
    my ($key, $value) = @_;

    filesystem::open_file($config::file);

    my $current_data = filesystem::get_data();

    if ($current_data ne '') {
        $arr = deserialize($current_data);
    }

    $arr->{$key} = $value;

    filesystem::set_data(serialize($arr));
    filesystem::write_file($config::file);
}

sub get_data {
    my ($key) = @_;

    filesystem::open_file($config::file);

    my $current_data = filesystem::get_data();

    if ($current_data eq '') {
        return undef;
    }

    $arr = deserialize($current_data);

    return $arr->{$key};
}

sub print_data {
    my ($key) = @_;

    my $value = get_data($key);

    print "$value\n";
}

666;