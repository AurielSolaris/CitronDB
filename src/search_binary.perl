package search_binary;

require "./src/citron.perl";
require "./src/search_index.perl";

# Exact match. Keys are looked up in the record hash and values in a
# value -> keys hash index, so neither walks the records.

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

    my $texts = search_index::texts();

    return search_index::results($texts, exists $texts->{$target} ? ($target) : ());
}

# Every key whose value is exactly $target.
sub search_values {
    my ($target) = @_;

    my $texts = search_index::texts();

    return search_index::results($texts, search_index::keys_with_value($target));
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