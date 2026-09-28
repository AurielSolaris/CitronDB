package search_binary;

require "./src/citron.perl";

sub binary_search {
    my ($sorted_keys, $target) = @_;

    my $low = 0;
    my $high = $#$sorted_keys;

    while($low <= $high) {
        my $mid = int(($low + $high) / 2);
        my $cmp = $sorted_keys->[$mid] cmp $target;

        if($cmp == 0) {
            return $mid;
        } elsif($cmp < 0) {
            $low = $mid + 1;
        } else {
            $high = $mid - 1;
        }
    }

    return -1;
}

sub search_keys {
    my ($target) = @_;

    my $data = citron::list();
    my %results = ();

    my @sorted_keys = sort keys %$data;

    my $index = binary_search(\@sorted_keys, $target);

    if($index != -1) {
        my $key = $sorted_keys[$index];
        $results{$key} = $data->{$key};
    }

    return \%results;
}

sub search_values {
    my ($target) = @_;

    my $data = citron::list();
    my %results = ();

    my @sorted_keys = sort { $data->{$a} cmp $data->{$b} } keys %$data;

    my $low = 0;
    my $high = $#sorted_keys;

    while($low <= $high) {
        my $mid = int(($low + $high) / 2);
        my $key = $sorted_keys[$mid];
        my $cmp = $data->{$key} cmp $target;

        if($cmp == 0) {
            $results{$key} = $data->{$key};
            last;
        } elsif($cmp < 0) {
            $low = $mid + 1;
        } else {
            $high = $mid - 1;
        }
    }

    return \%results;
}

sub search_pairs {
    my ($target) = @_;

    my $key_results = search_keys($target);
    my $value_results = search_values($target);

    my %results = (%$key_results, %$value_results);

    return \%results;
}

sub print_results {
    my ($results) = @_;

    foreach my $key (keys %$results) {
        print "$key: $results->{$key}\n";
    }
}

666;