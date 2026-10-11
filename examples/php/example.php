<?php

// CitronDB 🍋 from PHP.
//
//   php examples/php/example.php   # from the project root

// use the binding straight from the source tree (with composer, autoload
// "citrondb/citron" instead)
require __DIR__.'/../../bindings/php/src/CitronDB.php';

use Citron\CitronDB;

$db = CitronDB::open('example.citron');

// PHP values are stored as JSON
$db->set('user:1', ['name' => 'Ada', 'age' => 36, 'tags' => ['math', 'code']]);
$db['user:2'] = ['name' => 'Grace', 'age' => 85, 'tags' => ['navy', 'cobol']];
$db['visits'] = 0;

// setRaw follows the CLI rule: JSON if it parses, otherwise a plain string
$db->setRaw('greeting', 'hello world');

// read whole values, or drill in with a path
$user = $db['user:1'];
printf("user:1 is %s, %d\n", $user['name'], $user['age']);
echo 'first tag of user:2: ', $db->get('user:2', 'tags.0'), "\n";
echo 'last tag of user:2:  ', $db->get('user:2', 'tags.-1'), "\n";
echo 'missing with default: ', $db->get('nope', default: '(nil)'), "\n";

// update only touches existing keys
$db->update('visits', $db['visits'] + 1);
echo 'visits: ', $db['visits'], "\n";
echo 'update on a missing key: ', var_export($db->update('ghost', 1), true), "\n";

// several operations as one atomic step
$db->modify(function (array &$records) {
    $visits = CitronDB::decode($records['visits']);
    $records['visits'] = CitronDB::encode($visits + 10);
});
echo 'visits after modify: ', $db['visits'], "\n";

// a missing key and a stored null are different
$db['nothing'] = null;
echo 'nothing: ', json_encode($db->lookup('nothing')), ' ghost: ', json_encode($db->lookup('ghost')), "\n";
unset($db['nothing']);

// snapshots: save the data, change it, roll back to exactly that version.
// Without a name a snapshot is numbered "1", "2", "3", ...
$db->dropSnapshot('beforeCleanup'); // so the example can run again
$db->snapshot('beforeCleanup');
$number = $db->snapshot();
printf("\nsnapshots: %s (just made %s)\n", implode(', ', $db->snapshots()), $number);

unset($db['user:2']);
echo 'after delete, user:2 exists: ', var_export(isset($db['user:2']), true), "\n";
$db->rollback('beforeCleanup');
echo 'after rollback, user:2 exists: ', var_export(isset($db['user:2']), true), "\n";

echo "\nall records:\n";
foreach ($db->list() as $key => $text) {
    echo "{$key}: {$text}\n";
}

printf("\nexported %d records to example.json\n", $db->exportJson('example.json'));
