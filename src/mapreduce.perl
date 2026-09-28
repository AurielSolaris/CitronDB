package mapreduce;

require "./src/citron.perl";

sub run {
    my ($map, $reduce) = @_;

    my $data = citron::list();

    my %groups = ();

    foreach my $key (keys %$data) {
        foreach my $pair ($map->($key, $data->{$key})) {
            push @{$groups{$pair->[0]}}, $pair->[1];
        }
    }

    my %results = ();

    foreach my $key (keys %groups) {
        $results{$key} = $reduce->($key, $groups{$key});
    }

    return \%results;
}

sub count_map {
    my ($key, $value) = @_;

    return ["records", 1];
}

sub wordcount_map {
    my ($key, $value) = @_;

    my @pairs = ();

    foreach my $word (split(/\s+/, $value)) {
        push @pairs, [$word, 1] if $word ne '';
    }

    return @pairs;
}

sub sum_map {
    my ($key, $value) = @_;

    return () unless $value =~ /^-?\d+(\.\d+)?$/;

    return ["sum", $value];
}

sub sum_reduce {
    my ($key, $values) = @_;

    my $total = 0;
    $total += $_ foreach @$values;

    return $total;
}

my %jobs = (
    count     => [\&count_map, \&sum_reduce],
    wordcount => [\&wordcount_map, \&sum_reduce],
    sum       => [\&sum_map, \&sum_reduce],
);

sub run_job {
    my ($name) = @_;

    my $job = $jobs{$name};
    return undef unless $job;

    return run($job->[0], $job->[1]);
}

sub job_names {
    return sort keys %jobs;
}

sub print_results {
    my ($results) = @_;

    foreach my $key (sort keys %$results) {
        print "$key: $results->{$key}\n";
    }
}

666;
