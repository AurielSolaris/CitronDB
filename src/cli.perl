package cli;

my $args = {};
my $positional = [];
my $arg_count = scalar @ARGV;

for (my $i = 0; $i < $arg_count; $i++) {
    my $arg = $ARGV[$i];

    if ($arg =~ /^--(\w+)=(.*)$/) {
        my ($key, $value) = ($1, $2);
        $args->{$key} = $value;
    } elsif ($arg =~ /^--(\w+)$/) {
        $args->{$1} = 1;
    } else {
        push @$positional, $arg;
    }
}

sub arguments {
    my $index = $_[0];
    return $positional->[$index];
}
sub flag {
    my ($key) = $_[0];
    return $args->{$key};
}

666;