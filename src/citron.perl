package citron;

require "./src/filesystem.perl";
require "./src/config.perl";

my $arr = {};

sub serialize {
    my ($arr) = @_;

    my $string = '';

    foreach my $key (keys %$arr) {
        $string .= "$key=$arr->{$key};";
    }

    return $string;
}

sub deserialize {
    my ($string) = @_;

    my %arr = ();

    my @pairs = split(/;/, $string);

    foreach my $pair (@pairs) {
        next if $pair eq '';

        my ($key, $value) = split(/=/, $pair, 2);

        $arr{$key} = $value;
    }

    return \%arr;
}

sub set_data {
    my ($key, $value) = @_;

    # Read the current database contents first
    filesystem::open_file($config::file);

    my $current_data = filesystem::get_data();

    if ($current_data ne '') {
        $arr = deserialize($current_data);
    }

    # Update the requested value
    $arr->{$key} = $value;

    # Serialize and write the updated database
    filesystem::set_data(serialize($arr));
    filesystem::write_file($config::file);
}

sub get_data {
    my ($key) = @_;

    # Read the database
    filesystem::open_file($config::file);

    my $current_data = filesystem::get_data();

    if ($current_data eq '') {
        return undef;
    }

    # Deserialize the database
    $arr = deserialize($current_data);

    return $arr->{$key};
}

sub print_data {
    my ($key) = @_;

    my $value = get_data($key);

    print "$value\n";
}

666;