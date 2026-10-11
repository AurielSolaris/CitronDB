<?php

// Tests for the PHP binding's API.
//
//   php test/php/test_citron.php

declare(strict_types=1);

require __DIR__.'/harness.php';

use Citron\CitronDB;
use Citron\CitronException;

/** Runs $body with a fresh database path in a temp folder. */
function with_db(Closure $body): void
{
    $dir = temp_dir();
    try {
        $body($dir.'/test.citron');
    } finally {
        remove_tree($dir);
    }
}

test('open creates an empty database in the documented format', fn () => with_db(function ($path) {
    CitronDB::open($path);
    check_same('CITRON'.pack('NN', 2, 0), file_get_contents($path));
}));

test('open removes a temp file left by a crash', fn () => with_db(function ($path) {
    file_put_contents($path.'.tmp', 'partial');
    CitronDB::open($path);
    check(! file_exists($path.'.tmp'), 'temp file still there');
}));

test('open refuses an empty path', function () {
    check_throws(CitronException::class, fn () => CitronDB::open(''), CitronException::INVALID);
});

test('records are written sorted with big-endian lengths and canonical JSON', fn () => with_db(function ($path) {
    $db = CitronDB::open($path);
    $db->set('b', ['z' => 1, 'a' => [true, null]]);
    $db->set('a', 'héllo/🍋');

    $expected = 'CITRON'.pack('NN', 2, 2)
        .pack('N', 1).'a'.pack('N', strlen('"héllo/🍋"')).'"héllo/🍋"'
        .pack('N', 1).'b'.pack('N', strlen('{"a":[true,null],"z":1}')).'{"a":[true,null],"z":1}';
    check_same($expected, file_get_contents($path));
}));

test('CRUD', fn () => with_db(function ($path) {
    $db = CitronDB::open($path);
    $db->set('god', ['name' => 'Zeus', 'domains' => ['sky', 'thunder']]);

    check($db->exists('god'));
    check_same(['domains' => ['sky', 'thunder'], 'name' => 'Zeus'], $db->get('god'));
    check($db->update('god', 'Jupiter'));
    check(! $db->update('missing', 1));
    check(! $db->exists('missing'));
    check_same('Jupiter', $db->get('god'));
    check($db->delete('god'));
    check(! $db->delete('god'));
    check_same('fallback', $db->get('god', default: 'fallback'));
}));

test('PHP values', fn () => with_db(function ($path) {
    $db = CitronDB::open($path);
    $db->set('s', '42');
    check_same('42', $db->get('s'), 'PHP strings stay strings');
    check_same('"42"', $db->getJson('s'));
    $db->set('f', 1.5);
    check_same(1.5, $db->get('f'));
    $db->set('i', PHP_INT_MAX);
    check_same(PHP_INT_MAX, $db->get('i'));
    $db->set('list', [1, 2]);
    $db->set('map', [2 => 'b', 1 => 'a']);
    check_same('[1,2]', $db->getJson('list'));
    check_same('{"1":"a","2":"b"}', $db->getJson('map'), 'non-list arrays are objects');
    $db->set('empty', new stdClass);
    check_same('{}', $db->getJson('empty'));
    check_same([], $db->get('empty'));
    check(new stdClass == CitronDB::decode('{}', false));
    $db->set('json', new class implements JsonSerializable {
        public function jsonSerialize(): mixed
        {
            return ['ok' => true];
        }
    });
    check_same('{"ok":true}', $db->getJson('json'));
}));

test('values JSON cannot hold are refused', fn () => with_db(function ($path) {
    $db = CitronDB::open($path);
    check_throws(CitronException::class, fn () => $db->set('k', NAN), CitronException::INVALID);
    check_throws(CitronException::class, fn () => $db->set('k', INF), CitronException::INVALID);
    check_throws(CitronException::class, fn () => $db->set('k', "\xff"), CitronException::INVALID);
    check_throws(CitronException::class, fn () => $db->set('k', ["\xff" => 1]), CitronException::INVALID);
    check_throws(CitronException::class, fn () => $db->set('k', fopen('php://memory', 'r')), CitronException::INVALID);
    check(! $db->exists('k'));
}));

test('raw input is stored as JSON when it parses, and as a string otherwise', fn () => with_db(function ($path) {
    $db = CitronDB::open($path);
    $db->setRaw('json', '{"b":1,"a":[1,2]}');
    $db->setRaw('text', 'not json');
    $db->setRaw('n', '1.50');
    $db->setRaw('e', '1e3');
    $db->setRaw('q', '"02139"');
    $db->setRaw('broken', '{"half":');
    $db->setRaw('latin1', "caf\xe9");

    check_same('{"a":[1,2],"b":1}', $db->getJson('json'));
    check_same('"not json"', $db->getJson('text'));
    check_same('not json', $db->getText('text'));
    check_same('1.5', $db->getJson('n'));
    check_same(1000, $db->get('e'));
    check_same('02139', $db->get('q'));
    check_same('{"half":', $db->get('broken'));
    check_same('café', $db->get('latin1'), 'invalid UTF-8 is read as Latin-1, as Perl does');
}));

test('dotted paths drill into objects and lists', fn () => with_db(function ($path) {
    $db = CitronDB::open($path);
    $db->set('odin', ['ravens' => ['Huginn', 'Muninn'], 'realm' => ['name' => 'Asgard']]);

    check_same('Asgard', $db->get('odin', 'realm.name'));
    check_same('Muninn', $db->get('odin', 'ravens.-1'));
    check_same([false, null], $db->lookup('odin', 'ravens.5'));
    check_same('"Huginn"', $db->getJson('odin', 'ravens.0'));
    check_same('Huginn', $db->getText('odin', 'ravens.0'));
    check_same('Asgard', $db->get('odin', 'realm.name.'), 'trailing dots are ignored, as in Perl');
    check_same(null, $db->getText('missing', 'x'));
}));

test('a missing key and JSON null are different', fn () => with_db(function ($path) {
    $db = CitronDB::open($path);
    $db->set('nothing', null);
    check_same([true, null], $db->lookup('nothing'));
    check_same([false, null], $db->lookup('ghost'));
    check_same('null', $db->getText('nothing'));
}));

test('numeric string keys stay strings', fn () => with_db(function ($path) {
    $db = CitronDB::open($path);
    $db->set('123', 'numeric');
    $db->set('abc', 'text');
    $db->set('9', 'nine');

    check_same(['123', '9', 'abc'], $db->keys());
    check_same('{"123":"numeric","9":"nine","abc":"text"}', $db->dump());
}));

test('list, all and array access', fn () => with_db(function ($path) {
    $db = CitronDB::open($path);
    $db['user'] = ['name' => 'Ada'];
    $db['n'] = 1.5;
    $db['s'] = 'plain';

    check_same(['n' => '1.5', 's' => 'plain', 'user' => '{"name":"Ada"}'], $db->list());
    check_same(['n' => 1.5, 's' => 'plain', 'user' => ['name' => 'Ada']], $db->all());
    check_same(3, count($db));
    check(isset($db['n']));
    unset($db['n']);
    check(! isset($db['n']));
    check_same(['s' => 'plain', 'user' => ['name' => 'Ada']], iterator_to_array($db));
}));

test('writes from another handle are seen', fn () => with_db(function ($path) {
    $first = CitronDB::open($path);
    $second = CitronDB::open($path);
    check_same(null, $first->get('key'));
    $second->set('key', 'value');
    check_same('value', $first->get('key'));
}));

test('modify is one atomic read-modify-write', fn () => with_db(function ($path) {
    $db = CitronDB::open($path);
    $db->set('count', 1);
    $mtime = filemtime($path);

    $result = $db->modify(function (array &$records) {
        $records['count'] = CitronDB::encode(CitronDB::decode($records['count']) + 1);
        $records['raw'] = CitronDB::encodeRaw('hello');

        return 'done';
    });
    check_same('done', $result);
    check_same(2, $db->get('count'));
    check_same('hello', $db->get('raw'));

    $before = file_get_contents($path);
    $db->modify(fn (array &$records) => null);
    check_same($before, file_get_contents($path));

    check_throws(LogicException::class, fn () => $db->read(fn () => $db->set('x', 1)));
}));

test('import merges an object in one write', fn () => with_db(function ($path) {
    $db = CitronDB::open($path);
    $db->set('keep', 1);

    check_same(2, $db->import('{"a":1,"keep":2}'));
    check_same(['a' => 1, 'keep' => 2], $db->all());
    check_same(1, $db->import(['b' => [1]]));
    check_same(0, $db->import([]));
    check_throws(CitronException::class, fn () => $db->import('[1,2]'), CitronException::INVALID);
    check_throws(CitronException::class, fn () => $db->import('{"a":'), CitronException::INVALID);
    check_throws(CitronException::class, fn () => $db->import([1, 2]), CitronException::INVALID);
}));

test('export and import JSON files', fn () => with_db(function ($path) {
    $db = CitronDB::open($path);
    $file = dirname($path).'/out.json';
    check_same(0, $db->exportJson($file));
    check_same("{}\n", file_get_contents($file));

    $db->set('user', ['name' => 'Ada', 'tags' => ['math'], 'empty' => []]);
    $db->set('n', 1);
    check_same(2, $db->exportJson($file));
    check_same("{\n   \"n\" : 1,\n   \"user\" : {\n      \"empty\" : [],\n      \"name\" : \"Ada\",\n"
        ."      \"tags\" : [\n         \"math\"\n      ]\n   }\n}\n", file_get_contents($file));

    $other = CitronDB::open(dirname($path).'/other.citron');
    check_same(2, $other->importJson($file));
    check_same($db->all(), $other->all());
    check_throws(CitronException::class, fn () => $other->importJson(dirname($path).'/missing.json'), CitronException::IO);
}));

test('version 1 files are read as strings and upgraded on write', fn () => with_db(function ($path) {
    file_put_contents($path, 'CITRON'.pack('NN', 1, 1).pack('N', 1).'k'.pack('N', 5).'{"a"}');
    $db = CitronDB::open($path);
    check_same('{"a"}', $db->get('k'));
    $db->set('x', 1);
    check_same(2, unpack('N', file_get_contents($path), 6)[1]);
}));

test('corrupt and newer files are refused', fn () => with_db(function ($path) {
    $cases = [
        'CITRON'.pack('NN', 3, 0) => CitronException::VERSION,
        'CITRON'.pack('NN', 2, 1).pack('N', 10).'short' => CitronException::CORRUPT,
        'CITRON'.pack('NN', 2, 0).'x' => CitronException::CORRUPT,
        'NOTCITRON!!!!!' => CitronException::CORRUPT,
        'CITRON'.pack('NN', 0, 0) => CitronException::CORRUPT,
    ];
    foreach ($cases as $bytes => $code) {
        file_put_contents($path, $bytes);
        check_throws(CitronException::class, fn () => CitronDB::open($path), $code);
        check_same($bytes, file_get_contents($path), 'a refused file is left alone');
    }
}));

test('snapshots can be created, listed, rolled back and dropped', fn () => with_db(function ($path) {
    $db = CitronDB::open($path);
    $db->set('state', 'first');

    check_same('1', $db->snapshot());
    check_same('beforeChange', $db->snapshot('beforeChange'));
    $db->set('state', 'second');
    check_same('2', $db->snapshot());
    check_same(['1', '2', 'beforeChange'], $db->snapshots());
    check($db->rollback('1'));
    check_same('first', $db->get('state'));
    check($db->dropSnapshot('2'));
    check_same('3', $db->snapshot(), 'numbers are never reused');
    check(! $db->rollback('missing'));
    check(! $db->rollback('../x'));
    check(! $db->dropSnapshot('missing'));
    check_throws(CitronException::class, fn () => $db->snapshot('beforeChange'), CitronException::INVALID);
    check_throws(CitronException::class, fn () => $db->snapshot('42'), CitronException::INVALID);
    check_throws(CitronException::class, fn () => $db->snapshot('a-b'), CitronException::INVALID);

    file_put_contents($path.'.snapshots/bad.citron', 'garbage');
    check_throws(CitronException::class, fn () => $db->rollback('bad'), CitronException::CORRUPT);
    check_same('first', $db->get('state'), 'a corrupt snapshot leaves the database alone');
}));

test('formatNv matches Perl\'s %.15g', function () {
    $cases = [
        [1e15, '1e+15'], [123456789012345.6, '123456789012346'], [0.1, '0.1'], [1e-5, '1e-05'],
        [0.0001, '0.0001'], [-1.5, '-1.5'], [1e100, '1e+100'], [5e-324, '4.94065645841247e-324'],
        [0.30000000000000004, '0.3'], [-0.0, '0'], [INF, 'Inf'], [-INF, '-Inf'], [999999999999999.9, '1e+15'],
    ];
    foreach ($cases as [$value, $text]) {
        check_same($text, Citron\Json::formatNv($value), (string) $value);
    }
});

exit(run_tests());
