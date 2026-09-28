package search_prefix;

require "./src/citron.perl";

sub search_keys {
    my ($prefix) = @_;

    my $data = citron::list();
    my %results = ();

    foreach my $key (keys %$data) {
        if($key =~ /^\Q$prefix\E/i) {
            $results{$key} = $data->{$key};
        }
    }

    return \%results;
}

sub search_values {
    my ($prefix) = @_;

    my $data = citron::list();
    my %results = ();

    foreach my $key (keys %$data) {
        if($data->{$key} =~ /^\Q$prefix\E/i) {
            $results{$key} = $data->{$key};
        }
    }

    return \%results;
}

sub search_pairs {
    my ($prefix) = @_;

    my $data = citron::list();
    my %results = ();

    foreach my $key (keys %$data) {
        if($key =~ /^\Q$prefix\E/i || $data->{$key} =~ /^\Q$prefix\E/i) {
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