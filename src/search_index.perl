package search_index;

# In-memory indexes over the database, so searches don't have to walk every
# record. They're built lazily from citron::texts() the first time a search
# needs them and rebuilt only when the data changes (tracked by the cache
# generation), so a long-running process (the REPL, an embedding script)
# pays for each index once.
#
#   exact   hash maps: value -> keys, soundex code -> keys
#   sorted  arrays searched with binary search: case-insensitive prefixes,
#           and suffixes via the reversed strings
#   length  buckets: string length -> keys, for edit-distance searches
#
# Every index is built over keys ("key") and values ("value").

require "./src/citron.perl";

my $generation = -1;
my %built;

# Current readable texts ({ key => text }), resetting the indexes if the
# data changed since they were built.
sub texts {
    my ($texts, $gen) = citron::texts();

    if ($gen != $generation) {
        %built = ();
        $generation = $gen;
    }

    return $texts;
}

# The strings an index covers: [string, key] pairs for keys or values.
sub entries {
    my ($texts, $side) = @_;

    return map { [$_, $_] } keys %$texts if $side eq "key";
    return map { [$texts->{$_}, $_] } keys %$texts;
}

# --- hash maps ------------------------------------------------------------

# { string => [keys] } with strings mapped through $transform.
sub hash_index {
    my ($name, $side, $transform) = @_;

    my $texts = texts();
    return $built{"$name:$side"} //= do {
        my %index;
        push @{ $index{ $transform->($_->[0]) } }, $_->[1] for entries($texts, $side);
        \%index;
    };
}

# Keys whose value is exactly $value.
sub keys_with_value {
    my ($value) = @_;
    my $index = hash_index("exact", "value", sub { $_[0] });
    return @{ $index->{$value} || [] };
}

# Keys whose key or value has soundex code $code.
sub keys_with_soundex {
    my ($side, $code, $soundex) = @_;
    my $index = hash_index("soundex", $side, $soundex);
    return @{ $index->{$code} || [] };
}

# { string => [keys] } for the keys or values that are $length characters
# long. Grouped by string so equal values are only compared once.
sub strings_with_length {
    my ($side, $length) = @_;

    my $texts = texts();
    my $index = $built{"length:$side"} //= do {
        my %index;
        push @{ $index{ length $_->[0] }{ $_->[0] } }, $_->[1] for entries($texts, $side);
        \%index;
    };
    return $index->{$length} || {};
}

# --- sorted arrays --------------------------------------------------------

# Strings mapped through $transform, sorted, so a prefix of the transformed
# strings is a contiguous range. Each entry is "string\0<index>" so Perl's
# built-in sort (no comparator block, much faster) orders them; `keys` maps
# the index back to the record key.
sub sorted_index {
    my ($name, $side, $transform) = @_;

    my $texts = texts();
    return $built{"$name:$side"} //= do {
        my @keys;
        my @entries;
        for my $entry (entries($texts, $side)) {
            for my $string ($transform->($entry->[0])) {
                push @entries, $string . "\0" . pack("N", scalar @keys);
                push @keys, $entry->[1];
            }
        }
        { entries => [sort @entries], keys => \@keys };
    };
}

# Keys of the entries whose string starts with $prefix.
sub range {
    my ($index, $prefix) = @_;

    my $entries = $index->{entries};
    my ($low, $high) = (0, scalar @$entries);

    # first entry ge $prefix
    while ($low < $high) {
        my $mid = int(($low + $high) / 2);
        if ($entries->[$mid] lt $prefix) {
            $low = $mid + 1;
        } else {
            $high = $mid;
        }
    }

    # Every entry whose string starts with $prefix starts with it too, so
    # they're all in this run; the check drops the rare entry where the
    # prefix only matched across the "\0" separator.
    my @keys;
    for (my $i = $low; $i < @$entries && index($entries->[$i], $prefix) == 0; $i++) {
        next unless index(substr($entries->[$i], 0, -5), $prefix) == 0;
        push @keys, $index->{keys}[ unpack("N", substr($entries->[$i], -4)) ];
    }
    return @keys;
}

# Keys whose key or value starts with $prefix, ignoring case (same as
# /^\Q$prefix\E/i).
sub keys_with_prefix {
    my ($side, $prefix) = @_;
    return range(sorted_index("prefix", $side, sub { lc $_[0] }), lc $prefix);
}

# Keys whose key or value ends with $suffix, ignoring case (same as
# /\Q$suffix\E$/i, where $ also matches before a final newline).
sub keys_with_suffix {
    my ($side, $suffix) = @_;

    my $index = sorted_index("suffix", $side, sub {
        my $s = lc $_[0];
        return $s =~ /\n\z/ ? (scalar reverse($s), scalar reverse(substr($s, 0, -1)))
                            : (scalar reverse($s));
    });

    my %seen;
    return grep { !$seen{$_}++ } range($index, scalar reverse(lc $suffix));
}

# Indexes compare with lc and cmp, which match /i only for byte strings.
# Searches fall back to scanning for character (UTF-8 flagged) patterns.
sub usable_for {
    my ($pattern) = @_;
    return !utf8::is_utf8($pattern);
}

# { key => text } for the given keys.
sub results {
    my ($texts, @keys) = @_;
    return { map { $_ => $texts->{$_} } @keys };
}

666;
