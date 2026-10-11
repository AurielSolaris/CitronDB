<?php

// A small test runner, so the PHP tests need nothing but PHP. Its output is
// indented so that it doesn't read as TAP when test/bindings.t runs it.
//
//   test('name', function () { check_same($expected, $actual); });
//   exit(run_tests());

declare(strict_types=1);

require_once __DIR__.'/../../bindings/php/src/CitronDB.php';

const ROOT = __DIR__.'/../..';

$GLOBALS['tests'] = [];

function test(string $name, Closure $body): void
{
    $GLOBALS['tests'][$name] = $body;
}

final class CheckFailed extends Exception {}

function check(bool $ok, string $message = 'check failed'): void
{
    if (! $ok) {
        throw new CheckFailed($message);
    }
}

function show(mixed $value): string
{
    return is_string($value) ? '"'.addcslashes($value, "\0..\37\"\\\177..\377").'"' : var_export($value, true);
}

function check_same(mixed $expected, mixed $actual, string $message = ''): void
{
    if ($expected !== $actual) {
        throw new CheckFailed(($message === '' ? '' : $message.': ').'expected '.show($expected).', got '.show($actual));
    }
}

/** Checks that $body throws $class (and, if given, with $code). */
function check_throws(string $class, Closure $body, ?int $code = null): void
{
    try {
        $body();
    } catch (Throwable $e) {
        check($e instanceof $class, 'expected '.$class.', got '.get_class($e).': '.$e->getMessage());
        if ($code !== null) {
            check_same($code, $e->getCode(), 'error code');
        }

        return;
    }

    throw new CheckFailed('expected '.$class.', nothing was thrown');
}

function temp_dir(): string
{
    $dir = sys_get_temp_dir().DIRECTORY_SEPARATOR.'citron-php-'.bin2hex(random_bytes(6));
    mkdir($dir);

    return $dir;
}

function remove_tree(string $path): void
{
    if (is_dir($path) && ! is_link($path)) {
        foreach (scandir($path) as $name) {
            if ($name !== '.' && $name !== '..') {
                remove_tree($path.DIRECTORY_SEPARATOR.$name);
            }
        }
        @rmdir($path);
    } elseif (file_exists($path)) {
        @unlink($path);
    }
}

function run_tests(): int
{
    $failed = 0;
    $skipped = 0;

    foreach ($GLOBALS['tests'] as $name => $body) {
        try {
            $body();
            echo "    ok - {$name}\n";
        } catch (SkipTest $e) {
            $skipped++;
            echo "    ok - {$name} # skip {$e->getMessage()}\n";
        } catch (Throwable $e) {
            $failed++;
            echo "    not ok - {$name}\n";
            echo '      '.str_replace("\n", "\n      ", get_class($e).': '.$e->getMessage())."\n";
            if (! $e instanceof CheckFailed) {
                echo '      at '.$e->getFile().':'.$e->getLine()."\n";
            }
        }
    }

    $total = count($GLOBALS['tests']);
    echo '    '.($failed ? "FAILED: {$failed} of {$total}" : "passed: {$total}").($skipped ? ", skipped: {$skipped}" : '')."\n";

    return $failed ? 1 : 0;
}

final class SkipTest extends Exception {}

function skip(string $why): never
{
    throw new SkipTest($why);
}
