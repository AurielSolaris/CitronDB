package search_substring;

require "./src/citron.perl";

sub search_keys {
    my ($pattern) = @_;

    my $data = citron::list();
    my %results = ();

    foreach my $key (keys %$data) {
        if(index($key, $pattern) != -1) {
            $results{$key} = $data->{$key};
        }
    }

    return \%results;
}

sub search_values {
    my ($pattern) = @_;

    my $data = citron::list();
    my %results = ();

    foreach my $key (keys %$data) {
        if(index($data->{$key}, $pattern) != -1) {
            $results{$key} = $data->{$key};
        }
    }

    return \%results;
}

sub search_pairs {
    my ($pattern) = @_;

    my $data = citron::list();
    my %results = ();

    foreach my $key (keys %$data) {
        if(index($key, $pattern) != -1 || index($data->{$key}, $pattern) != -1) {
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