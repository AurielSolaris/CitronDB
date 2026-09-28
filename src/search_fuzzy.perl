package search_fuzzy;

require "./src/citron.perl";

sub fuzzy_match {
    my ($string, $pattern) = @_;

    my @chars = split(//, $pattern);
    my $regex = join('.*', map { quotemeta($_) } @chars);

    return $string =~ /$regex/i;
}

sub search_keys {
    my ($pattern) = @_;

    my $data = citron::list();
    my %results = ();

    foreach my $key (keys %$data) {
        if(fuzzy_match($key, $pattern)) {
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
        if(fuzzy_match($data->{$key}, $pattern)) {
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
        if(fuzzy_match($key, $pattern) || fuzzy_match($data->{$key}, $pattern)) {
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