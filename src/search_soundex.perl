package search_soundex;

require "./src/citron.perl";

sub soundex {
    my ($string) = @_;

    $string = uc($string);
    my $first = substr($string, 0, 1);

    $string =~ tr/AEHIOUWY//d;
    $string =~ tr/BFPV/1111/;
    $string =~ tr/CGJKQSXYZ/222222222/;
    $string =~ tr/DT/33/;
    $string =~ tr/L/4/;
    $string =~ tr/MN/55/;
    $string =~ tr/R/6/;

    $string =~ s/(.)\1+/$1/g;

    $string = $first . $string;
    $string =~ s/[0]//g;
    $string .= '000';

    return substr($string, 0, 4);
}

sub search_keys {
    my ($pattern) = @_;

    my $data = citron::list();
    my %results = ();
    my $pattern_soundex = soundex($pattern);

    foreach my $key (keys %$data) {
        if(soundex($key) eq $pattern_soundex) {
            $results{$key} = $data->{$key};
        }
    }

    return \%results;
}

sub search_values {
    my ($pattern) = @_;

    my $data = citron::list();
    my %results = ();
    my $pattern_soundex = soundex($pattern);

    foreach my $key (keys %$data) {
        if(soundex($data->{$key}) eq $pattern_soundex) {
            $results{$key} = $data->{$key};
        }
    }

    return \%results;
}

sub search_pairs {
    my ($pattern) = @_;

    my $data = citron::list();
    my %results = ();
    my $pattern_soundex = soundex($pattern);

    foreach my $key (keys %$data) {
        if(soundex($key) eq $pattern_soundex || soundex($data->{$key}) eq $pattern_soundex) {
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