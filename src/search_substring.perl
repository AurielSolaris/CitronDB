package search_substring;

require "./src/citron.perl";
require "./src/search_index.perl";

# Partial match. A substring can sit anywhere, so this scans, but over the
# cached texts: nothing is read or parsed again between searches.

sub matching {
    my ($side, $pattern) = @_;

    my $texts = search_index::texts();

    return grep { index($_, $pattern) != -1 } keys %$texts if $side eq "key";
    return grep { index($texts->{$_}, $pattern) != -1 } keys %$texts;
}

sub search_keys {
    my ($pattern) = @_;
    return search_index::results(search_index::texts(), matching("key", $pattern));
}

sub search_values {
    my ($pattern) = @_;
    return search_index::results(search_index::texts(), matching("value", $pattern));
}

sub search_pairs {
    my ($pattern) = @_;
    return search_index::results(search_index::texts(),
                                 matching("key", $pattern), matching("value", $pattern));
}

sub print_results {
    my ($results) = @_;

    foreach my $key (keys %$results) {
        print "$key: $results->{$key}\n";
    }
}

666;