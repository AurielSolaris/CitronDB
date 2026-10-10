package search_fuzzy;

require "./src/citron.perl";
require "./src/search_index.perl";

# Characters of the pattern in order, anything in between, ignoring case.
# Scans the cached texts with the regex built once per search.

sub fuzzy_regex {
    my ($pattern) = @_;

    my $regex = join('.*', map { quotemeta($_) } split(//, $pattern));
    return qr/$regex/i;
}

sub fuzzy_match {
    my ($string, $pattern) = @_;

    return $string =~ fuzzy_regex($pattern);
}

sub matching {
    my ($side, $pattern) = @_;

    my $texts = search_index::texts();
    my $re = fuzzy_regex($pattern);

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