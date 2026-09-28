package search_regex;

require "./src/citron.perl";

sub search_keys {
    my ($pattern) = @_;

    my $data = citron::list();
    my %results = ();

    foreach my $key (keys %$data) {
        if($key =~ /$pattern/) {
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
        if($data->{$key} =~ /$pattern/) {
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
        if($key =~ /$pattern/ || $data->{$key} =~ /$pattern/) {
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