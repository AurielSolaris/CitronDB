use strict;
use warnings;
use Test::More;

# Builds the C library and runs the C and Python 3 binding tests, so
# `prove test/` covers the bindings too. The Python tests include the interop
# suite, which checks the bindings against this Perl implementation (using
# the perl running this test).

sub find_program {
    my @names = @_;
    for my $name (@names) {
        my $null = $^O eq 'MSWin32' ? 'NUL' : '/dev/null';
        return $name if system("$name --version >$null 2>&1") == 0;
    }
    return;
}

my $make = find_program('make', 'gmake', 'mingw32-make');
my $cc = $ENV{CC} || find_program('gcc', 'cc', 'clang');

plan skip_all => 'make and a C compiler are needed for the binding tests'
    unless $make && $cc;

is(system($make, '-s', '-C', 'bindings/c', "CC=$cc"), 0, 'C library builds');
is(system($make, '-s', '-C', 'bindings/c', "CC=$cc", 'test'), 0, 'C tests pass');

SKIP: {
    my $python = find_program('python3', 'python', 'py -3');
    skip 'Python 3 not found', 1 unless $python;

    local $ENV{CITRON_PERL} = $^X;
    is(system("$python -m unittest discover -s test/python3"), 0, 'Python 3 tests pass');
}

done_testing();
