package search_prefix;

require "./src/citron.perl";
require "./src/search_index.perl";

# Case-insensitive prefix match, answered from sorted indexes with binary
# search instead of testing every record.

sub matching {
    my ($side, $prefix) = @_;

    my $texts = search_index::texts();

    return search_index::keys_with_prefix($side, $prefix)
        if search_index::usable_for($prefix);

    my $re = qr/^\Q$prefix\E/i;
    return grep { ($side eq "key" ? $_ : $texts->{$_}) =~ $re } keys %$texts;
}

sub search_keys {
    my ($prefix) = @_;
    return search_index::results(search_index::texts(), matching("key", $prefix));
}

sub search_values {
    my ($prefix) = @_;
    return search_index::results(search_index::texts(), matching("value", $prefix));
}

sub search_pairs {
    my ($prefix) = @_;
    return search_index::results(search_index::texts(),
                                 matching("key", $prefix), matching("value", $prefix));
}

sub print_results {
    my ($results) = @_;

    foreach my $key (keys %$results) {
        print "$key: $results->{$key}\n";
    }
}

666;