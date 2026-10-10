package search_soundex;

require "./src/citron.perl";
require "./src/search_index.perl";

# Phonetic match. Records are indexed by soundex code (code -> keys), so a
# search is one hash lookup.

# American Soundex: first letter, then up to three digits. Letters with the
# same code collapse when adjacent or separated by H/W (not by vowels), and
# the first letter's own code isn't repeated. Non-letters are ignored;
# strings without letters have no code ("").
sub soundex {
    my ($string) = @_;

    (my $letters = uc $string) =~ tr/A-Z//cd;
    return "" if $letters eq "";

    my $first = substr($letters, 0, 1);

    (my $codes = $letters) =~ tr/AEIOUYHWBFPVCGJKQSXZDTLMNR/000000xx111122222222334556/;
    $codes =~ tr/x//d;
    $codes =~ tr/0-6//s;
    $codes = substr($codes, 1) unless $first eq "H" || $first eq "W";
    $codes =~ tr/0//d;

    return $first . substr($codes . "000", 0, 3);
}

sub matching {
    my ($side, $pattern) = @_;

    my $code = soundex($pattern);
    return () if $code eq "";

    return search_index::keys_with_soundex($side, $code, \&soundex);
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