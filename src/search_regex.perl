package search_regex;

require "./src/citron.perl";
require "./src/search_index.perl";

# Regex match. An arbitrary regex can't use an index, so this scans the
# cached texts with the pattern compiled once.

sub matching {
    my ($side, $pattern) = @_;

    my $texts = search_index::texts();
    my $re = qr/$pattern/;

    return grep { $_ =~ $re } keys %$texts if $side eq "key";
    return grep { $texts->{$_} =~ $re } keys %$texts;
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