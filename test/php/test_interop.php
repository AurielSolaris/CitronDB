<?php

// The PHP binding must behave exactly like the Perl implementation.
//
// Runs the same operations through src/citron.perl and through the PHP
// binding and compares every result, the database files byte for byte, the
// snapshot folders and the export files. The same checks as
// test/python3/test_interop.py does for the C library.
//
// Needs perl on PATH (or CITRON_PERL; on Windows use Strawberry Perl, not
// the MSYS perl that comes with Git Bash). Run from anywhere:
//
//   php test/php/test_interop.php

declare(strict_types=1);

require __DIR__.'/harness.php';

use Citron\CitronDB;
use Citron\CitronException;

const PERL_REF = 'test/python3/perl_ref.perl';

function perl(): string
{
    return getenv('CITRON_PERL') ?: 'perl';
}

function have_perl(): bool
{
    static $ok = null;
    if ($ok === null) {
        exec(escapeshellarg(perl()).' -MJSON::PP -e 1 2>&1', $out, $status);
        $ok = $status === 0;
    }

    return $ok;
}

// Values chosen to hit every branch of JSON::PP's decoding and re-encoding.
function samples(): array
{
    return [
        // plain strings
        'hello world', '', ' ', 'x', 'café', '日本語', '😀', "tab\there", "new\nline",
        "\x7f", "a\x01b", 'back\\slash', 'qu"ote', '42abc', '007', '+1', '.5', '1.', '-',
        '--1', '1e', '1e+', '0x10', 'NaN', 'Infinity', 'True', 'nul', 'nulll',
        "\xff\xfe raw bytes", "caf\xe9", "\xc3\x28", "\xed\xa0\x80", "\xf8\x88\x80\x80\x80", "\xc0\xaf",
        // JSON scalars
        'true', 'false', 'null', ' null ', "\t42\n", '"42"', '"02139"', '""',
        '"\\u00e9"', '"\\ud83d\\ude00"', '"\\ud83d"', '"\\ude00"', '"\\u0000x"', '"\\/"',
        '"\\b\\f\\n\\r\\t"', '"\\u001f\\u007f"', '"\\x"', '"unterminated', "\"a\tb\"",
        "\"\xed\xa0\x80\"", "\"\xf4\x90\x80\x80\"", "\"\xf8\x88\x80\x80\x80\"", "\"caf\xe9\"",
        // numbers
        '0', '-0', '1', '-1', '42', '1.50', '1.0', '0.0', '-0.0', '0.1', '1e3', '1E3',
        '1e+3', '1e-5', '1e-7', '1e14', '1e15', '1e16', '1.5e15', '1.5e300', '1e100',
        '123.456e2', '0.1e1', '1e0', '-1.5', '3.14159', '0.000001', '5e-324',
        '1.7976931348623157e308', '1e400', '-1e400',
        '123456789012345678', '9223372036854775807', '9223372036854775808',
        '-9223372036854775808', '-9223372036854775809', '18446744073709551615',
        '18446744073709551616', '12345678901234567890', '99999999999999999999',
        '123456789012345678901', '-1234567890123456789', '-12345678901234567890',
        '1.23456789012345678', '9007199254740991.0', '9007199254740992.0',
        '9007199254740993e0', '-9007199254740992.0', '1.8e19', '-9.2e18',
        '9.3e18', '1.8446744073709551616e19', '-9223372036854775808e0',
        '100000000000000000000.0', '12345678901234567890.5', '-1e18', '1e19',
        '0.30000000000000004', '123456.789', '1e-9', '0.0001', '0.00001', '999999999999999.9',
        '1e15', '123456789012345.6', '-0e0', '-0.0e1', '18446744073709549568e0',
        // containers
        '[]', '{}', '[1,2,3]', '[ 1 , 2 ]', '{"b":1,"a":2}', '{"a":1,"a":2}',
        '{"x":[1,2,{}],"y":[],"z":{"q":null}}', '{"é":1,"e":2,"f":3}',
        '{"user":{"name":"Ada","tags":["math","code"]}}', '[1,]', '{,}', '{"a"}',
        '{"a":}', '[1 2]', '[[[[[]]]]]', '[1.50, 1e3, -0]', '{"n":123456789012345678901}',
        '{"name":"Ada","age":36,"tags":["math","code"],"address":{"city":"London"}}',
        '{"1":1,"10":2,"2":3,"-1":4,"01":5,"":6}',
        str_repeat('[', 600).str_repeat(']', 600), str_repeat('[', 400).str_repeat(']', 400),
        str_repeat('[', 512).str_repeat(']', 512), str_repeat('[', 513).str_repeat(']', 513),
        '[1] x', '{} {}',
    ];
}

const PATHS = ['', 'a', 'name', 'tags', 'tags.0', 'tags.1', 'tags.-1', 'tags.-2',
    'tags.-3', 'tags.2', 'tags.01', 'tags.x', 'address.city', 'address.',
    'address..city', '.', '..', 'user.tags.1', 'x.2', 'x.2.y', '0', 'é', 'n',
    '.name', 'tags.-0', 'tags.99999999999999999999', 'tags.+1', "caf\xe9"];

const TOKENS = ['{', '}', '[', ']', ',', ':', '"a"', '"b"', '"é"', '1', '-0', '1.50',
    '1e3', '2E-2', 'true', 'false', 'null', ' ', "\n", '"\\u00e9"',
    '"\\ud83d\\ude00"', 'x', 'é', '123456789012345678901', '0.1', '-'];

function pick(array $items): mixed
{
    return $items[mt_rand(0, count($items) - 1)];
}

function random_json(int $depth = 0): mixed
{
    $kind = mt_rand(0, $depth < 4 ? 7 : 4);

    return match ($kind) {
        0 => pick([true, false, null]),
        1 => pick([0, -1, 7, 2 ** 53, PHP_INT_MAX, PHP_INT_MIN, 18446744073709551615.0, 1e21]),
        2 => pick([0.5, 1.25, -3.75, 1e-9, 1e300, 123456.789, 0.1 + 0.2]),
        3, 4 => implode('', array_map(fn () => pick(['a', 'b', ' ', 'é', "\n", '"', '\\', "\x01", '😀', '/']), range(1, mt_rand(1, 6)))),
        5 => array_map(fn () => random_json($depth + 1), range(1, mt_rand(1, 3))),
        default => (object) array_combine(
            $keys = array_map(fn () => pick(['a', 'b', 'é', '', 'k', '1']), range(1, mt_rand(1, 3))),
            array_map(fn () => random_json($depth + 1), $keys),
        ),
    };
}

function random_text(): string
{
    if (mt_rand(0, 1)) {
        $flags = JSON_PRESERVE_ZERO_FRACTION | (mt_rand(0, 1) ? JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES : 0)
            | (mt_rand(0, 2) === 0 ? JSON_PRETTY_PRINT : 0);
        $text = json_encode(random_json(), $flags);
        // number spellings PHP never produces
        if (mt_rand(0, 9) < 3) {
            $text = str_replace('0.5', pick(['0.50', '5e-1', '5.0E-1']), $text);
        }

        return $text;
    }

    return implode('', array_map(fn () => pick(TOKENS), range(1, mt_rand(1, 9))));
}

function run_perl(string $db, array $ops, string $workdir): array
{
    $file = $workdir.'/ops.txt';
    file_put_contents($file, implode('', array_map(fn ($op) => implode("\t", array_map('bin2hex', $op))."\n", $ops)));
    $cmd = escapeshellarg(perl()).' '.escapeshellarg(PERL_REF).' '.escapeshellarg($db).' '.escapeshellarg($file);
    $proc = proc_open($cmd, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, ROOT);
    $out = stream_get_contents($pipes[1]);
    $err = stream_get_contents($pipes[2]);
    $status = proc_close($proc);
    check_same(0, $status, "perl failed: {$err}");

    $lines = explode("\n", str_replace("\r", '', $out));
    array_pop($lines); // after the last newline

    return $lines;
}

function run_binding(string $path, array $ops): array
{
    $out = [];
    $db = CitronDB::open($path);
    foreach ($ops as $op) {
        [$name, $args] = [$op[0], array_slice($op, 1)];
        try {
            $result = match ($name) {
                'set' => $db->setRaw($args[0], $args[1]),
                'get' => ($text = $db->getText($args[0], $args[1])) === null ? '-' : bin2hex($text),
                'update' => (string) (int) $db->updateRaw($args[0], $args[1]),
                'delete' => (string) (int) $db->delete($args[0]),
                'exists' => (string) (int) $db->exists($args[0]),
                'export' => (string) $db->exportJson($args[0]),
                'import' => (string) $db->importJson($args[0]),
                'snapshot' => bin2hex($db->snapshot($args[0] === '' ? null : $args[0])),
                'snapshots' => bin2hex(implode(',', $db->snapshots())),
                'rollback' => (string) (int) $db->rollback($args[0]),
                'dropsnapshot' => (string) (int) $db->dropSnapshot($args[0]),
            };
            if ($name !== 'set') {
                $out[] = $result;
            }
        } catch (CitronException) {
            $out[] = '!';
        }
    }

    return $out;
}

/** A command running $code in a PHP process with $db open as $db. */
function php_child(string $dir, string $code, string $db): string
{
    $script = $dir.'/child-'.bin2hex(random_bytes(4)).'.php';
    file_put_contents($script, '<?php require '.var_export(ROOT.'/bindings/php/src/CitronDB.php', true).";\n"
        .'$db = Citron\CitronDB::open('.var_export($db, true).");\n".$code."\n");

    return escapeshellarg(PHP_BINARY).' '.escapeshellarg($script);
}

function snapshot_files(string $db): array
{
    $dir = $db.'.snapshots';
    if (! is_dir($dir)) {
        return [];
    }
    $files = [];
    foreach (array_diff(scandir($dir), ['.', '..']) as $name) {
        $files[$name] = file_get_contents($dir.'/'.$name);
    }

    return $files;
}

/** Runs ops through both implementations and compares everything. */
function compare(array $ops): void
{
    $dir = temp_dir();
    try {
        $side = function (array $op, string $side) use ($dir): array {
            if ($op[0] === 'export' || $op[0] === 'import') {
                return [$op[0], $dir.'/'.(str_starts_with($op[1], 'shared-') ? '' : $side.'-').$op[1]];
            }

            return $op;
        };
        $perlDb = $dir.'/perl.citron';
        $phpDb = $dir.'/php.citron';
        $perlOut = run_perl($perlDb, array_map(fn ($op) => $side($op, 'perl'), $ops), $dir);
        $phpOut = run_binding($phpDb, array_map(fn ($op) => $side($op, 'php'), $ops));

        $returning = array_values(array_filter($ops, fn ($op) => $op[0] !== 'set'));
        foreach ($returning as $i => $op) {
            check_same($perlOut[$i] ?? null, $phpOut[$i] ?? null, show($op));
        }
        check_same(count($perlOut), count($phpOut), 'result count');
        check(file_get_contents($phpDb) === file_get_contents($perlDb), 'database files differ');
        check(snapshot_files($phpDb) === snapshot_files($perlDb), 'snapshot folders differ');
        foreach (scandir($dir) as $name) {
            if (str_starts_with($name, 'perl-')) {
                check_same(file_get_contents($dir.'/'.$name), @file_get_contents($dir.'/php-'.substr($name, 5)), $name);
            }
        }
    } finally {
        remove_tree($dir);
    }
}

function needs_perl(): void
{
    if (! have_perl()) {
        skip('perl with JSON::PP not found (set CITRON_PERL)');
    }
}

test('samples are stored identically', function () {
    needs_perl();
    $ops = [];
    foreach (samples() as $i => $value) {
        $key = sprintf('k%03d', $i);
        $ops[] = ['set', $key, $value];
        $ops[] = ['get', $key, ''];
        $ops[] = ['update', $key, $value];
    }
    compare($ops);
});

test('get with paths', function () {
    needs_perl();
    $ops = [['set', 'a', '{"name":"Ada","tags":["math","code"],"address":{"city":"London"},'
        .'"x":[0,1,{"y":[true]}],"é":"accent","n":null,"caf\u00e9":1}'],
        ['set', 's', 'plain'], ['set', 'arr', '["math","code",[1,2]]'],
        ['set', 'user', '{"user":{"tags":["a","b"]}}'], ['set', 'tags', '{"tags":[1,2,3]}']];
    foreach (['a', 's', 'arr', 'user', 'tags', 'missing'] as $key) {
        foreach (PATHS as $path) {
            $ops[] = ['get', $key, $path];
        }
    }
    compare($ops);
});

test('update, delete, exists', function () {
    needs_perl();
    compare([
        ['update', 'ghost', '1'], ['exists', 'ghost'], ['set', 'k', '1'],
        ['update', 'k', '1.50'], ['get', 'k', ''], ['exists', 'k'],
        ['delete', 'k'], ['delete', 'k'], ['exists', 'k'], ['set', '', 'empty key'],
        ['get', '', ''], ['set', 'café', 'x'], ['set', "\xff", 'raw key'],
        ['get', "\xff", ''], ['set', 'user:1', 'null'], ['get', 'user:1', ''],
        ['set', '10', 'a'], ['set', '9', 'b'], ['set', '-1', 'c'], ['set', '01', 'd'],
        ['get', '10', ''], ['exists', '9'], ['delete', '01'],
    ]);
});

test('export and import', function () {
    needs_perl();
    compare([
        ['export', 'empty.json'],
        ['set', 's', 'hello'], ['set', 'café', '"\\u00e9t\\u00e9"'],
        ['set', "caf\xe9", 'latin-1 key'], ['set', 'q', "\"quote\\\" and \\u0001\""],
        ['set', 'deep', '{"x":{"y":{"z":[[],{},[1,[2]]]}}}'], ['set', 'n', '1.50'],
        ['export', 'out.json'],
        ['import', 'out.json'], ['import', 'missing.json'],
        ['get', 'deep', 'x.y.z.2.1.0'],
    ]);
});

test('import of objects, bad files and duplicate keys', function () {
    needs_perl();
    $dir = temp_dir();
    try {
        $files = [
            'in.json' => '{"a":{"b":[1,2,{}],"c":[]},"é":"accent","n":1.50,"m":1e3,'
                .'"big":123456789012345678901,"dup":1,"dup":2}',
            'bad.json' => '[1,2]', 'broken.json' => '{"a":', 'empty.json' => '{}',
        ];
        $results = [];
        foreach (['perl', 'php'] as $side) {
            foreach ($files as $name => $content) {
                file_put_contents("{$dir}/{$name}", $content);
            }
            $ops = [];
            foreach (array_keys($files) as $name) {
                $ops[] = ['import', "{$dir}/{$name}"];
            }
            $ops = array_merge($ops, [['get', 'a', 'b.2'], ['get', 'big', ''], ['get', 'dup', ''],
                ['get', 'n', ''], ['get', 'm', ''], ['export', "{$dir}/{$side}-out.json"]]);
            $db = "{$dir}/{$side}.citron";
            $results[$side] = $side === 'perl' ? run_perl($db, $ops, $dir) : run_binding($db, $ops);
        }
        check_same($results['perl'], $results['php']);
        check(file_get_contents("{$dir}/php.citron") === file_get_contents("{$dir}/perl.citron"), 'database files differ');
        check_same(file_get_contents("{$dir}/perl-out.json"), file_get_contents("{$dir}/php-out.json"));
    } finally {
        remove_tree($dir);
    }
});

test('random inputs', function () {
    needs_perl();
    mt_srand(666);
    $ops = [];
    for ($i = 0; $i < 600; $i++) {
        $key = 'r'.mt_rand(0, 399);
        $choice = mt_rand(0, 99);
        $ops[] = match (true) {
            $choice < 70 => ['set', $key, random_text()],
            $choice < 80 => ['update', $key, random_text()],
            $choice < 85 => ['delete', $key],
            default => ['get', $key, pick(['', 'a', '0', 'b.0', '-1', 'é', 'k.a', '1'])],
        };
    }
    $ops[] = ['export', 'random.json'];
    compare($ops);
});

test('number formatting matches Perl across magnitudes', function () {
    needs_perl();
    mt_srand(15);
    $ops = [];
    for ($i = 0; $i < 400; $i++) {
        $mantissa = mt_rand(1, PHP_INT_MAX) / PHP_INT_MAX * 10;
        $exp = mt_rand(-30, 30);
        $sign = mt_rand(0, 3) === 0 ? '-' : '';
        $spellings = [
            $sign.sprintf('%.17f', $mantissa).'e'.$exp,
            $sign.sprintf('%.'.mt_rand(1, 20).'f', $mantissa * 10 ** mt_rand(0, 12)),
            $sign.mt_rand(1, 999).'e'.mt_rand(0, 25),
            $sign.mt_rand(0, 99).'.'.str_pad((string) mt_rand(0, 99999), mt_rand(5, 25), '0', STR_PAD_LEFT),
        ];
        foreach ($spellings as $j => $text) {
            $ops[] = ['set', "n{$i}_{$j}", $text];
            $ops[] = ['get', "n{$i}_{$j}", ''];
        }
    }
    compare($ops);
});

test('PHP values are stored as Perl stores their JSON', function () {
    needs_perl();
    $values = [
        null, true, false, 0, -1, PHP_INT_MAX, PHP_INT_MIN, 1.5, 2.0, -0.0, 0.1 + 0.2, 1e15, 1e16, 1e21,
        1e300, 5e-324, 18446744073709549568.0, 9007199254740993.0, 123456789012345.67, 1e-5,
        '', 'hello', '42', 'é😀', "\x00\x1f\x7f", [], [1, [2, []]], ['b' => 1, 'a' => [true]],
        [3 => 'x', 1 => 'y'], ['10' => 1, '9' => 2], new stdClass, (object) ['' => null, 'k' => (object) []],
    ];
    $dir = temp_dir();
    try {
        $db = CitronDB::open("{$dir}/php.citron");
        $ops = [];
        foreach ($values as $i => $value) {
            $db->set("v{$i}", $value);
            // what Perl stores for the JSON text PHP would hand it
            $ops[] = ['set', "v{$i}", json_encode($value, JSON_PRESERVE_ZERO_FRACTION | JSON_UNESCAPED_UNICODE)];
        }
        run_perl("{$dir}/perl.citron", $ops, $dir);
        check(file_get_contents("{$dir}/php.citron") === file_get_contents("{$dir}/perl.citron"), 'database files differ');
    } finally {
        remove_tree($dir);
    }
});

test('reads files written by Perl, and Perl reads PHP\'s', function () {
    needs_perl();
    $dir = temp_dir();
    try {
        $path = "{$dir}/perl.citron";
        run_perl($path, [['set', 'user:1', '{"name":"Ada","tags":["math"]}'], ['set', 'n', '1.50'], ['set', 's', 'hello']], $dir);
        $db = CitronDB::open($path);
        check_same('math', $db->get('user:1', 'tags.0'));
        check_same(['n' => '1.5', 's' => 'hello', 'user:1' => '{"name":"Ada","tags":["math"]}'], $db->list());
        $db->set('added', [1, 2]);
        check_same([bin2hex('[1,2]'), bin2hex('Ada')], run_perl($path, [['get', 'added', ''], ['get', 'user:1', 'name']], $dir));
    } finally {
        remove_tree($dir);
    }
});

test('concurrent writers with Perl lose nothing', function () {
    needs_perl();
    $dir = temp_dir();
    try {
        $db = "{$dir}/shared.citron";
        $writes = 25;
        $procs = [];
        $spawn = function (string $cmd) use (&$procs) {
            $procs[] = proc_open($cmd, [1 => ['file', PHP_OS_FAMILY === 'Windows' ? 'NUL' : '/dev/null', 'w']], $pipes, ROOT);
        };
        for ($p = 0; $p < 2; $p++) {
            $ops = '';
            for ($i = 0; $i < $writes; $i++) {
                $ops .= bin2hex('set')."\t".bin2hex("perl{$p}:{$i}")."\t".bin2hex('1')."\n";
            }
            file_put_contents("{$dir}/ops{$p}.txt", $ops);
            $spawn(escapeshellarg(perl()).' '.PERL_REF.' '.escapeshellarg($db).' '.escapeshellarg("{$dir}/ops{$p}.txt"));
        }
        for ($p = 0; $p < 2; $p++) {
            $spawn(php_child($dir, "for (\$i = 0; \$i < {$writes}; \$i++) \$db->set(\"php{$p}:\$i\", \$i);", $db));
        }
        foreach ($procs as $proc) {
            check_same(0, proc_close($proc), 'writer exit status');
        }
        check_same(4 * $writes, count(CitronDB::open($db)));
    } finally {
        remove_tree($dir);
    }
});

test('unchanged write is skipped', function () {
    needs_perl();
    $dir = temp_dir();
    try {
        $data = 'CITRON'.pack('NN', 1, 1).pack('N', 1).'k'.pack('N', 5).'hello';
        file_put_contents("{$dir}/php.citron", $data);
        file_put_contents("{$dir}/perl.citron", $data);
        $ops = [['set', 'k', 'hello'], ['update', 'k', '"hello"']];
        check_same(run_perl("{$dir}/perl.citron", $ops, $dir), run_binding("{$dir}/php.citron", $ops));
        check(file_get_contents("{$dir}/php.citron") === $data, 'PHP rewrote the file');
        check(file_get_contents("{$dir}/perl.citron") === $data, 'Perl rewrote the file');
    } finally {
        remove_tree($dir);
    }
});

test('snapshots', function () {
    needs_perl();
    compare([
        ['snapshots'], ['set', 'a', '1'], ['snapshot', ''], ['set', 'a', '2'],
        ['snapshot', 'beforeMigration'], ['snapshot', ''], ['snapshot', 'beforeMigration'],
        ['snapshot', '42'], ['snapshot', 'a-b'], ['snapshot', '../x'], ['snapshots'],
        ['set', 'b', '{"x":[1,2]}'], ['rollback', '1'], ['get', 'a', ''], ['get', 'b', ''],
        ['rollback', 'beforeMigration'], ['get', 'a', ''], ['rollback', 'nope'],
        ['rollback', '../x'], ['dropsnapshot', '2'], ['dropsnapshot', '2'],
        ['dropsnapshot', '../x'], ['snapshot', ''], ['snapshots'],
    ]);
});

test('snapshots are shared with Perl', function () {
    needs_perl();
    $dir = temp_dir();
    try {
        $path = "{$dir}/shared.citron";
        check_same([bin2hex('1'), bin2hex('fromPerl')], run_perl($path, [['set', 'who', 'perl'], ['snapshot', ''], ['snapshot', 'fromPerl']], $dir));
        $db = CitronDB::open($path);
        check_same(['1', 'fromPerl'], $db->snapshots());
        $db['who'] = 'php';
        check_same('2', $db->snapshot());
        check_same('fromPHP', $db->snapshot('fromPHP'));
        check($db->rollback('fromPerl'));
        check_same('perl', $db['who']);
        check_same([bin2hex('1,2,fromPHP,fromPerl'), '1', bin2hex('php'), bin2hex('3')],
            run_perl($path, [['snapshots'], ['rollback', 'fromPHP'], ['get', 'who', ''], ['snapshot', '']], $dir));
    } finally {
        remove_tree($dir);
    }
});

test('concurrent snapshots with Perl never share a number', function () {
    needs_perl();
    $dir = temp_dir();
    try {
        $db = "{$dir}/race.citron";
        run_perl($db, [['set', 'k', 'v']], $dir);
        file_put_contents("{$dir}/snap_ops.txt", str_repeat(bin2hex('snapshot')."\t\n", 10));
        $procs = [];
        for ($i = 0; $i < 2; $i++) {
            $procs[] = proc_open(escapeshellarg(perl()).' '.PERL_REF.' '.escapeshellarg($db).' '.escapeshellarg("{$dir}/snap_ops.txt"),
                [1 => ['pipe', 'w']], $pipes, ROOT);
            $outs[] = $pipes[1];
        }
        $child = php_child($dir, 'for ($i = 0; $i < 10; $i++) echo bin2hex($db->snapshot()), "\n";', $db);
        for ($i = 0; $i < 2; $i++) {
            $procs[] = proc_open($child, [1 => ['pipe', 'w']], $pipes, ROOT);
            $outs[] = $pipes[1];
        }
        $names = [];
        foreach ($procs as $i => $proc) {
            foreach (array_filter(explode("\n", stream_get_contents($outs[$i]))) as $line) {
                $names[] = (int) hex2bin(trim($line));
            }
            check_same(0, proc_close($proc));
        }
        sort($names);
        check_same(range(1, 40), $names);
    } finally {
        remove_tree($dir);
    }
});

test('reads version 1 files', function () {
    needs_perl();
    $dir = temp_dir();
    try {
        $data = 'CITRON'.pack('NN', 1, 3);
        foreach (['greeting' => 'hello', 'num' => '42', 'bytes' => "caf\xe9"] as $key => $value) {
            $data .= pack('N', strlen($key)).$key.pack('N', strlen($value)).$value;
        }
        file_put_contents("{$dir}/php.citron", $data);
        file_put_contents("{$dir}/perl.citron", $data);
        $ops = [['get', 'num', ''], ['get', 'bytes', ''], ['set', 'x', '1']];
        check_same(run_perl("{$dir}/perl.citron", $ops, $dir), run_binding("{$dir}/php.citron", $ops));
        check(file_get_contents("{$dir}/php.citron") === file_get_contents("{$dir}/perl.citron"), 'upgrade to v2 differs');
    } finally {
        remove_tree($dir);
    }
});

test('reads the fixtures written by v0.3 and v0.4 like Perl does', function () {
    needs_perl();
    foreach (['v0.3', 'v0.4'] as $version) {
        $fixture = ROOT."/test/fixtures/{$version}.citron";
        $dir = temp_dir();
        try {
            copy($fixture, "{$dir}/perl.citron");
            copy($fixture, "{$dir}/php.citron");
            $db = CitronDB::open("{$dir}/php.citron");
            $ops = [];
            foreach ($db->keys() as $key) {
                $ops[] = ['get', $key, ''];
            }
            $ops[] = ['export', "{$dir}/out.json"];
            check_same(run_perl("{$dir}/perl.citron", $ops, $dir), run_binding("{$dir}/php.citron", $ops), $version);
        } finally {
            remove_tree($dir);
        }
    }
});

exit(run_tests());
