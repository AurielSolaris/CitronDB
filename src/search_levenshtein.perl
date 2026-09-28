package search_levenshtein;

require "./src/citron.perl";

my $DEFAULT_THRESHOLD = 3;

sub levenshtein {
    my ($s, $t) = @_;

    my @d;
    my $n = length($s);
    my $m = length($t);

    return $m if $n == 0;
    return $n if $m == 0;

    for my $i (0..$n) { $d[$i][0] = $i; }
    for my $j (0..$m) { $d[0][$j] = $j; }

    for my $i (1..$n) {
        for my $j (1..$m) {
            my $cost = substr($s, $i-1, 1) eq substr($t, $j-1, 1) ? 0 : 1;

            $d[$i][$j] = min(
                $d[$i-1][$j] + 1,
                $d[$i][$j-1] + 1,
                $d[$i-1][$j-1] + $cost
            );
        }
    }

    return $d[$n][$m];
}

sub min {
    my $min = $_[0];
    for my $val (@_) {
        $min = $val if $val < $min;
    }
    return $min;
}

sub search_keys {
    my ($pattern, $threshold) = @_;
    $threshold //= $DEFAULT_THRESHOLD;

    my $data = citron::list();
    my %results = ();

    foreach my $key (keys %$data) {
        if(levenshtein($key, $pattern) <= $threshold) {
            $results{$key} = $data->{$key};
        }
    }

    return \%results;
}

sub search_values {
    my ($pattern, $threshold) = @_;
    $threshold //= $DEFAULT_THRESHOLD;

    my $data = citron::list();
    my %results = ();

    foreach my $key (keys %$data) {
        if(levenshtein($data->{$key}, $pattern) <= $threshold) {
            $results{$key} = $data->{$key};
        }
    }

    return \%results;
}

sub search_pairs {
    my ($pattern, $threshold) = @_;
    $threshold //= $DEFAULT_THRESHOLD;

    my $data = citron::list();
    my %results = ();

    foreach my $key (keys %$data) {
        if(levenshtein($key, $pattern) <= $threshold || levenshtein($data->{$key}, $pattern) <= $threshold) {
            $results{$key} = $data->{$key};
        }
    }

    return \%results;
}

sub print_results {
    my ($results) = @_;

    foreach my $key (keys %$results) {
        print "$key: $results->{$key}\n";
    }
}

666;