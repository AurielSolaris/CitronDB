package search_suffix;

require "./src/citron.perl";
require "./src/search_index.perl";

# Case-insensitive suffix match, answered from sorted indexes of the
# reversed strings with binary search instead of testing every record.

sub matching {
    my ($side, $suffix) = @_;

    my $texts = search_index::texts();

    return search_index::keys_with_suffix($side, $suffix)
        if search_index::usable_for($suffix);

    my $re = qr/\Q$suffix\E$/i;
    return grep { ($side eq "key" ? $_ : $texts->{$_}) =~ $re } keys %$texts;
}

sub search_keys {
    my ($suffix) = @_;
    return search_index::results(search_index::texts(), matching("key", $suffix));
}

sub search_values {
    my ($suffix) = @_;
    return search_index::results(search_index::texts(), matching("value", $suffix));
}

sub search_pairs {
    my ($suffix) = @_;
    return search_index::results(search_index::texts(),
                                 matching("key", $suffix), matching("value", $suffix));
}

sub print_results {
    my ($results) = @_;

    foreach my $key (keys %$results) {
        print "$key: $results->{$key}\n";
    }
}

666;