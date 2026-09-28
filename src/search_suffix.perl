package search_suffix;

require "./src/citron.perl";

sub search_keys {
    my ($suffix) = @_;

    my $data = citron::list();
    my %results = ();

    foreach my $key (keys %$data) {
        if($key =~ /\Q$suffix\E$/i) {
            $results{$key} = $data->{$key};
        }
    }

    return \%results;
}

sub search_values {
    my ($suffix) = @_;

    my $data = citron::list();
    my %results = ();

    foreach my $key (keys %$data) {
        if($data->{$key} =~ /\Q$suffix\E$/i) {
            $results{$key} = $data->{$key};
        }
    }

    return \%results;
}

sub search_pairs {
    my ($suffix) = @_;

    my $data = citron::list();
    my %results = ();

    foreach my $key (keys %$data) {
        if($key =~ /\Q$suffix\E$/i || $data->{$key} =~ /\Q$suffix\E$/i) {
            $results{$key} = $data->{$key};
        }
    }

    return \%results;
}

sub print_results {
    my ($results) = @_;

    foreach my $key (keys %$results) {
        print "$key: $results->{$key}\n";
    }
}

666;