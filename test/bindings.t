use strict;
use warnings;
use Test::More;

# Builds the C library and runs the C, Python 3 and PHP binding tests, so
# `prove test/` covers the bindings too. The Python and PHP tests include the
# interop suites, which check the bindings against this Perl implementation
# (using the perl running this test).

sub find_program {
    my @names = @_;
    for my $name (@names) {
        my $null = $^O eq 'MSWin32' ? 'NUL' : '/dev/null';
        return $name if system("$name --version >$null 2>&1") == 0;
    }
    return;
}

local $ENV{CITRON_PERL} = $^X;

my $make = find_program('make', 'gmake', 'mingw32-make');
my $cc = $ENV{CC} || find_program('gcc', 'cc', 'clang');

SKIP: {
    skip 'make and a C compiler are needed for the C and Python 3 tests', 3
        unless $make && $cc;

    is(system($make, '-s', '-C', 'bindings/c', "CC=$cc"), 0, 'C library builds');
    is(system($make, '-s', '-C', 'bindings/c', "CC=$cc", 'test'), 0, 'C tests pass');

    my $python = find_program('python3', 'python', 'py -3');
    skip 'Python 3 not found', 1 unless $python;

    is(system("$python -m unittest discover -s test/python3"), 0, 'Python 3 tests pass');
}

SKIP: {
    # The PHP binding is pure PHP: it needs no compiler.
    my $php = find_program('php');
    skip 'PHP not found', 3 unless $php;

    is(system($php, 'test/php/test_citron.php'), 0, 'PHP tests pass');
    is(system($php, 'test/php/test_interop.php'), 0, 'PHP interop tests pass');
    is(system($php, 'test/php/test_laravel.php'), 0, 'PHP Laravel store tests pass (or skip)');
}

done_testing();
