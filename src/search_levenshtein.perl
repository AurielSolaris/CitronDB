package search_levenshtein;

require "./src/citron.perl";
require "./src/search_index.perl";

my $DEFAULT_THRESHOLD = 3;

# Edit distance between $s and $t. With $max, stops as soon as the distance
# must exceed it and returns $max + 1.
sub levenshtein {
    my ($s, $t, $max) = @_;

    my $n = length($s);
    my $m = length($t);

    return $m if $n == 0;
    return $n if $m == 0;
    return $max + 1 if defined $max && abs($n - $m) > $max;

    my @s = map { ord } split(//, $s);
    my @t = map { ord } split(//, $t);

    # two rows of the distance matrix
    my @prev = (0 .. $m);

    for my $i (1 .. $n) {
        my @cur = ($i);
        my $c = $s[$i - 1];
        my $row_min = $i;

        for my $j (1 .. $m) {
            my $d = $prev[$j - 1] + ($c == $t[$j - 1] ? 0 : 1);
            $d = $prev[$j] + 1 if $prev[$j] + 1 < $d;
            $d = $cur[$j - 1] + 1 if $cur[$j - 1] + 1 < $d;
            $cur[$j] = $d;
            $row_min = $d if $d < $row_min;
        }

        return $max + 1 if defined $max && $row_min > $max;
        @prev = @cur;
    }

    return $prev[$m];
}

sub min {
    my $min = $_[0];
    for my $val (@_) {
        $min = $val if $val < $min;
    }
    return $min;
}

# Returns a sub counting the characters of a string that don't occur in
# $pattern. Each of them needs at least one edit, so the count is a lower
# bound on the distance that's far cheaper than computing it: tr counts at C
# speed. The character class is built from \x{} escapes only.
sub foreign_counter {
    my ($pattern) = @_;

    my %seen;
    my @chars = grep { !$seen{$_}++ } split(//, $pattern);

    # a hyphen is literal at the end of a tr list
    my $class = join("", map { sprintf("\\x{%x}", ord) } grep { $_ ne "-" } @chars);
    $class .= "-" if $seen{"-"};

    return eval "sub { \$_[0] =~ tr/$class//c }" || die $@;
}

# Keys whose key or value is within $threshold edits of $pattern. Only
# strings whose length is within $threshold of the pattern's can match, so
# just those length buckets are checked, each distinct string once, and only
# strings that pass the cheap lower bound get the full distance computed.
sub matching {
    my ($side, $pattern, $threshold) = @_;

    my $length = length($pattern);
    my $foreign = foreign_counter($pattern);

    my @keys;
    for my $l (($length > $threshold ? $length - $threshold : 0) .. $length + $threshold) {
        my $strings = search_index::strings_with_length($side, $l);
        for my $string (keys %$strings) {
            next if $foreign->($string) > $threshold;
            push @keys, @{ $strings->{$string} }
                if levenshtein($string, $pattern, $threshold) <= $threshold;
        }
    }
    return @keys;
}

sub search_keys {
    my ($pattern, $threshold) = @_;
    $threshold //= $DEFAULT_THRESHOLD;
    return search_index::results(search_index::texts(), matching("key", $pattern, $threshold));
}

sub search_values {
    my ($pattern, $threshold) = @_;
    $threshold //= $DEFAULT_THRESHOLD;
    return search_index::results(search_index::texts(), matching("value", $pattern, $threshold));
}

sub search_pairs {
    my ($pattern, $threshold) = @_;
    $threshold //= $DEFAULT_THRESHOLD;
    return search_index::results(search_index::texts(),
                                 matching("key", $pattern, $threshold),
                                 matching("value", $pattern, $threshold));
}

sub print_results {
    my ($results) = @_;

    foreach my $key (keys %$results) {
        print "$key: $results->{$key}\n";
    }
}

666;