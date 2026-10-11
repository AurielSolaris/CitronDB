# CitronDB 🍋 Documentation

This is the reference for CitronDB's core, the Perl implementation in `src/`, and for the bindings that use the same databases from C, Python 3 and PHP. The [README](README.MD) is the quick tour. This file covers the exact rules.

* [How the pieces fit](#how-the-pieces-fit)
* [Values](#values)
* [Paths](#paths)
* [The file and how it is written](#the-file-and-how-it-is-written)
* [Perl API reference](#perl-api-reference)
* [Snapshots](#snapshots)
* [Search and map-reduce](#search-and-map-reduce)
* [Errors](#errors)
* [Bindings](#bindings)
  * [Function map](#function-map)
  * [C](#c)
  * [Python 3](#python-3)
  * [PHP](#php)
* [Sharing one database between languages](#sharing-one-database-between-languages)
* [Writing a new binding](#writing-a-new-binding)

---

## How the pieces fit

```text
                 src/citron.perl  ← the reference implementation
                        │
          same file format, locks, values, errors
     ┌──────────────────┼──────────────────────┐
bindings/c         bindings/php           (any new binding)
 citron.c           CitronDB.php
     │               pure PHP, no Perl,
bindings/python3     no compiler, no FFI
 ctypes on the C library
```

* **Perl is the reference.** `src/citron.perl` defines what a value is, how it is stored and what every operation returns. The bindings follow Perl byte for byte; Perl is never changed to suit a binding.
* **Each binding is a native implementation of the file format.** None of them runs Perl. The C library and the PHP class each implement it from scratch; the Python package wraps the C library.
* **They share databases.** Perl, C, Python and PHP processes can open the same `.citron` file at the same time. They take the same locks and write the same bytes, so no process can tell which language wrote a record.
* **This is tested, not just intended.** `test/python3/test_interop.py` (for C and Python) and `test/php/test_interop.php` (for PHP) run the same operations through Perl and through the binding. They compare every result, the database files, the snapshot folders and the export files, byte for byte.

---

## Values

Every value is JSON. Keys are byte strings.

### The set rule

Raw input (the CLI, `set_data`, `citron_set`, `set_raw`, `setRaw`) is stored like this:

1. If the whole input parses as JSON, the JSON value is stored.
2. Otherwise the input is stored as a JSON string.

```text
citron> set count 42            → 42            (number)
citron> set zip "02139"         → "02139"       (string: quoted JSON)
citron> set greeting hello      → "hello"       (not JSON → string)
citron> set user {"b":1,"a":2}  → {"a":2,"b":1} (object, keys sorted)
citron> set broken {"a":        → "{\"a\":"     (not JSON → string)
```

The binding methods that take a native value (`set` in Python and PHP) skip the rule. They store the value as JSON directly, so the Python or PHP string `"42"` stays a string.

### Canonical form

What's stored is `JSON::PP->new->utf8->canonical->allow_nonref` output, never the input text:

| Input                          | Stored                  | Why                                                   |
| ------------------------------ | ----------------------- | ----------------------------------------------------- |
| `{"b":1, "a":2}`               | `{"a":2,"b":1}`         | keys sorted (byte order), no whitespace               |
| `{"a":1,"a":2}`                | `{"a":2}`               | on duplicate keys the last one wins                   |
| `1.50`, `1.0`, `-0.0`          | `1.5`, `1`, `0`         | decimals become doubles, printed with `%.15g`         |
| `1e3`, `1E3`, `9.3e18`         | `1000`, `1000`, `9300000000000000000` | an exponent that gives an integer in range prints as that integer |
| `-0`                           | `0`                     | integer zero has no sign                              |
| `9223372036854775807`          | `9223372036854775807`   | integers in [−2⁶³, 2⁶⁴) stay exact                    |
| `18446744073709551616`         | `1.84467440737096e+19`  | larger integers become doubles                        |
| `123456789012345678901`        | `"123456789012345678901"` | integers over 20 characters become strings          |
| `1000000000000000.0`           | `1e+15`                 | `%.15g` switches to an exponent at 10¹⁵               |
| `1e400`                        | `Inf`                   | overflow (Perl's spelling; not valid JSON for other tools) |
| `"é"`, `"\/"`             | `"é"`, `"/"`            | strings are stored as raw UTF-8, only `"`, `\` and control characters escaped |
| `"\u0001"`, tab                | `"\u0001"`, `"\t"`      | control characters as `\b \f \n \r \t` or lowercase `\u00XX` |

Strings are stored as UTF-8, read by Perl's lax rules:

* Inside a JSON string, a character is at most 4 bytes, and surrogates (`\xED\xA0\x80`) and code points up to U+1FFFFF are accepted. A `\uD800` escape that isn't followed by a low surrogate is invalid JSON, so the input becomes a plain string.
* Plain text that isn't valid UTF-8 (sequences of up to 6 bytes allowed) is read as Latin-1: `caf\xE9` is stored as `"café"`.
* JSON nests at most 512 levels deep. Deeper input isn't JSON, so it's stored as a string.

### Writing an unchanged value

Writing a key's current value again doesn't rewrite the file. Because of that, a version 1 file stays version 1 until something actually changes.

---

## Paths

`get`, `lookup` and every binding's get functions take an optional dotted path into the value:

```text
citron> set user:1 {"name":"Ada","tags":["math","code"],"address":{"city":"London"}}
citron> get user:1 address.city   → London
citron> get user:1 tags.0         → math
citron> get user:1 tags.-1        → code     (negative indexes count from the end)
citron> get user:1 tags.5         → (nil)
```

The rules, from `resolve_path` in `citron.perl`:

* The path is split on `.`. Trailing empty parts are dropped, as Perl's `split` does: `address.` is `address`, and `.` or `..` is the whole value. Empty parts elsewhere are kept and match an empty key: `a..b` is `a`, `""`, `b`.
* On an object, a part is a key. On an array, a part must be an integer (`-?[0-9]+`, so `01` is 1 and `+1` is not an index) within `-length .. length-1`.
* Anything else is "not found". It's different from a found JSON `null`; see `lookup`.
* The path is a byte string, and each byte is compared as a Latin-1 character with the keys. So a non-ASCII key such as `é` can't be reached by a path. Bindings reproduce this.

---

## The file and how it is written

### Format (version 2)

```text
"CITRON"                     6 bytes
version                      uint32, big-endian (2)
record count                 uint32
per record, sorted by key bytes:
    key length               uint32
    key                      bytes
    value length             uint32
    value                    canonical JSON, UTF-8
```

An empty file is an empty database. Version 1 files (values were raw strings) are read with each value treated as plain text (see [the set rule](#the-set-rule)). They're written back as version 2 on the next change. Files with a version above 2 are refused.

### Files next to the database

| File                          | Purpose                                                            |
| ----------------------------- | ------------------------------------------------------------------ |
| `<db>`                        | the database                                                       |
| `<db>.lock`                   | lock file: shared lock to read, exclusive lock to write            |
| `<db>.tmp`                    | the next version while it's being written; removed by `open_db`    |
| `<db>.snapshots/<name>.citron`| snapshots, each a complete database                                |
| `<db>.snapshots/counter`      | last snapshot number, as a decimal string                          |

### The rules every implementation follows

1. **Lock.** Every operation opens `<db>.lock` for appending and holds `flock(LOCK_SH)` to read or `flock(LOCK_EX)` to write. A separate lock file is used because the database itself is replaced on every write. On Windows, Perl's `flock` locks bytes `0 .. 0xFFFF0000`. The C library locks the same range, and PHP's `flock` locks from byte 0, so the ranges overlap and the locks exclude each other.
2. **Read the whole file** under the lock and parse it. If the bytes are identical to the last ones this process parsed, the parsed records are reused.
3. **Write atomically.** Write `<db>.tmp`, flush and fsync it, then rename it over `<db>`. A crash leaves either the old file or the new one. On Windows the rename is retried briefly in PHP, because a virus scanner may hold the fresh file open.
4. **Refuse bad files.** A bad header, truncated record, trailing bytes, or newer version raises an error. The file is never read as empty and then overwritten.

---

## Perl API reference

Load it from the project root and choose a file:

```perl
require "./src/citron.perl";

$config::file = "app.citron";   # default: mainuser.citron
citron::open_db();
```

All functions die with a message on I/O errors and corrupt or newer files (see [Errors](#errors)). `$value` arguments are raw input and follow [the set rule](#the-set-rule). Keys are byte strings; a Perl character string is encoded as UTF-8 first.

### Opening

| Function    | Returns | Description |
| ----------- | ------- | ----------- |
| `open_db()` | 1 if it created the file, else 0 | Removes a leftover `<db>.tmp` and creates the database (an empty version 2 file) if it's missing. Call it once before other functions. |

### Writing

| Function | Returns | Description |
| -------- | ------- | ----------- |
| `set_data($key, $value)` | 1 | Inserts or replaces. Skips the write if the key already holds this value. |
| `update_data($key, $value)` | 1, or 0 if the key doesn't exist | Replaces an existing key only. |
| `delete_data($key)` | 1 if the key existed, else 0 | |
| `import_json($file)` | number of keys imported | Merges the JSON object in `$file` in one write; existing keys are replaced. Dies if the file isn't JSON or isn't an object. Always rewrites the file. |

### Reading

| Function | Returns | Description |
| -------- | ------- | ----------- |
| `exists_data($key)` | 1 or 0 | |
| `lookup($key, $path)` | `(found, value)` | The decoded value (hashes, arrays, scalars, `JSON::PP::Boolean`), optionally at a [path](#paths). `found` is 0 for a missing key or path, so a stored `null` is `(1, undef)`. |
| `get_data($key, $path)` | value or `undef` | `lookup` without `found`. |
| `to_text($value)` | string | How `get` prints a value: strings as-is (UTF-8 bytes), everything else as canonical JSON (`null`, `true`, `1.5`, `{"a":1}`). |
| `list()` | `{ key => text }` | Every record as `to_text` would show it. |
| `list_values()` | `{ key => value }` | Every record, decoded. |
| `export_json($file)` | number of records | Writes all records as one pretty-printed JSON object (three-space indent, `"key" : value`, sorted keys, empty object `{}`), plus a newline. |
| `get_all()` / `print_data($key)` | — | Print `key: text` lines / one value (or `(nil)`). |

### Lower-level helpers

These are what the functions above are built from. They're useful to know when writing a binding:

| Function | Description |
| -------- | ----------- |
| `parse_value($input)` | The set rule: decoded JSON, or the input as a string |
| `encode_value($v)` / `decode_value($text)` | Canonical JSON encoder / decoder |
| `serialize(\%records)` / `deserialize($bytes)` | The file format; `deserialize` dies on bad files |
| `with_lock($mode, $code)` | Runs `$code` holding `LOCK_SH` or `LOCK_EX` on `<db>.lock` |
| `modify($code)` | Exclusive lock, load, `$code->(\%copy)` returns `(result, changed)`, save if changed |
| `read_only($code)` | Shared lock, load, `$code->(\%records)` |
| `resolve_path($value, $path)` | The [path](#paths) rules; returns `(found, value)` |
| `stored_to_text($text)` | `to_text(decode_value($text))`, but fast for stored strings |

`filesystem.perl` provides the file I/O: `open_file` reads a file into a buffer, and `write_file` writes the buffer atomically (temp file, `sync`, rename).

---

## Snapshots

| Function | Returns | Description |
| -------- | ------- | ----------- |
| `create_snapshot($name)` | the name | Copies the database's bytes to `<db>.snapshots/<name>.citron` under the write lock. Without a name, the snapshot gets the next number. |
| `list_snapshots()` | list of names | Numbered snapshots in numeric order, then named ones in byte order |
| `rollback($name)` | 1, or 0 if there's no such snapshot | Replaces the database with the snapshot (atomic write). The snapshot is kept. |
| `delete_snapshot($name)` | 1 if it existed, else 0 | |

Rules:

* **Names** are `[A-Za-z0-9]+`. A name you choose must contain a letter, so it can't collide with a number. Names that aren't valid (`../x`, `a-b`) are refused by `create_snapshot`, and treated as "no such snapshot" by `rollback` and `delete_snapshot`. A name that already exists is refused, never overwritten.
* **Numbers** count up from 1 with no upper limit: the counter is a decimal string incremented digit by digit. A number is never reused, even after its snapshot is deleted. The next number is one past both the counter file and the highest numbered snapshot, so losing the counter file doesn't cause reuse.
* **Checks.** A corrupt database isn't snapshotted. A corrupt snapshot is refused by `rollback` (`Snapshot 'x' is unusable: ...`) and the database is left alone.

---

## Search and map-reduce

Search (`search_*.perl`, with indexes from `search_index.perl`) and map-reduce (`mapreduce.perl`) are Perl-only for now; the bindings don't include them. They read through `citron::texts()` and `citron::list_values()`, so they see records written by any binding. See the README for the search types and built-in jobs.

---

## Errors

Perl dies with these messages; the bindings use the same text, with a code:

| Situation | Message | C code | Python | PHP |
| --------- | ------- | ------ | ------ | --- |
| I/O failure (open, read, write, rename, lock) | `Could not ...` | `CITRON_EIO` (−1) | `CitronError`, `.code == -1` | `CitronException`, `IO` |
| Bad header | `Not a CitronDB file (bad header)` | `CITRON_ECORRUPT` (−2) | `-2` | `CORRUPT` |
| Truncated file | `Corrupt CitronDB file: truncated while reading <what>` | `CITRON_ECORRUPT` | `-2` | `CORRUPT` |
| Trailing bytes | `Corrupt CitronDB file: <n> unexpected trailing bytes` | `CITRON_ECORRUPT` | `-2` | `CORRUPT` |
| Newer file | `CitronDB file version <n> is newer than supported version 2` | `CITRON_EVERSION` (−3) | `-3` | `VERSION` |
| Bad import, bad snapshot name, snapshot exists | `Invalid JSON in '<file>'`, `Invalid snapshot name ...`, `Snapshot '<name>' already exists` | `CITRON_EINVALID` (−4) | `-4` | `INVALID` |

---

## Bindings

### Function map

| Perl (`citron::`)  | C (`citron.h`)                   | Python (`citron.Citron`)         | PHP (`Citron\CitronDB`)          |
| ------------------ | -------------------------------- | -------------------------------- | -------------------------------- |
| `open_db()`        | `citron_open(path, &db)`         | `citron.open(path)`              | `CitronDB::open($path)`          |
| `set_data`         | `citron_set(db, key, text)`      | `set(key, value)`, `set_raw(key, text)` | `set($key, $value)`, `setRaw($key, $text)` |
| `update_data`      | `citron_update`                  | `update`, `update_raw`           | `update`, `updateRaw`            |
| `delete_data`      | `citron_delete`                  | `delete`, `del db[key]`          | `delete`, `unset($db[$key])`     |
| `exists_data`      | `citron_exists`                  | `exists`, `key in db`            | `exists`, `isset($db[$key])`     |
| `lookup`           | `citron_get` (JSON text)         | `lookup(key, path)`              | `lookup($key, $path)`            |
| `get_data`         | `citron_get`                     | `get(key, path, default)`, `db[key]` | `get($key, $path, $default)`, `$db[$key]` |
| `to_text(lookup)`  | `citron_get_text`                | `get_text(key, path)`            | `getText($key, $path)`           |
| —                  | `citron_get` (canonical JSON)    | —                                | `getJson($key, $path)`           |
| `list`             | —                                | `list()`                         | `list()`                         |
| `list_values`      | `citron_dump` (one JSON object)  | `list_values()`, `items()`       | `all()`, `dump()` (JSON text)    |
| sorted keys        | `citron_keys`                    | `keys()`, `len(db)`              | `keys()`, `count($db)`           |
| `import_json`      | `citron_import_json`, `citron_import` (JSON text) | `import_json(file)`, `import_dict(d)` | `importJson($file)`, `import($jsonOrArray)` |
| `export_json`      | `citron_export_json`             | `export_json(file)`              | `exportJson($file)`              |
| `modify`, `read_only` | —                             | —                                | `modify(fn (&$records))`, `read(fn ($records))` |
| `create_snapshot`  | `citron_snapshot`                | `snapshot(name=None)`            | `snapshot($name = null)`         |
| `list_snapshots`   | `citron_snapshots`               | `snapshots()`                    | `snapshots()`                    |
| `rollback`         | `citron_rollback`                | `rollback(name)`                 | `rollback($name)`                |
| `delete_snapshot`  | `citron_drop_snapshot`           | `drop_snapshot(name)`            | `dropSnapshot($name)`            |

Search and map-reduce have no binding equivalents yet.

### C

`bindings/c` is one C17 file with no dependencies. Build with `make -C bindings/c`, or compile `src/citron.c` into your program and include `include/citron.h`.

```c
#include "citron.h"

citron *db;
char *city;

if (citron_open("app.citron", &db) < 0) { /* citron_errmsg(db) */ }
citron_set(db, "user:1", "{\"name\":\"Ada\",\"address\":{\"city\":\"London\"}}");
if (citron_get_text(db, "user:1", "address.city", &city, NULL) == 1) {
    puts(city);              /* London */
    citron_free(city);
}
citron_close(db);
```

* Values in and out are text: input follows the set rule, and output is canonical JSON (`citron_get`) or display text (`citron_get_text`). Parse the JSON with your own library.
* Calls return ≥ 0 on success and a negative `CITRON_E*` on failure; `citron_errmsg(db)` has the message.
* Strings handed back are freed with `citron_free`, key and name arrays with `citron_free_keys`.
* A handle isn't thread-safe; open one per thread.

### Python 3

`bindings/python3/citron` wraps the C library with ctypes. It finds the library through `CITRON_LIB`, then the package folder, then `bindings/c/build/`.

```python
import citron

with citron.open("app.citron") as db:
    db.set("user:1", {"name": "Ada", "tags": ["math"]})   # Python value → JSON
    db.set_raw("greeting", "hello world")                  # the set rule
    db.get("user:1", "tags.0")                             # 'math'
    found, value = db.lookup("missing")                    # (False, None)
```

* `set` and `update` serialise Python values with `json.dumps`, and the C library then canonicalises them as Perl would (`1.0` → `1`).
* Errors raise `citron.CitronError`; `.code` is the C error code.
* Keys and text are UTF-8. Bytes that aren't valid UTF-8 round-trip via `surrogateescape`.

### PHP

`bindings/php` is pure PHP 8.1+. It needs no Perl, no compiled library and no FFI extension. It implements the format natively, like the C library: canonicalisation, lax UTF-8, locks, atomic writes, snapshots. It also ships a Laravel cache store.

Install with Composer (`"citrondb/citron"`, autoloaded as `Citron\`), or require the file directly:

```php
require 'bindings/php/src/CitronDB.php';

use Citron\CitronDB;
use Citron\CitronException;

$db = CitronDB::open('app.citron');

$db->set('user:1', ['name' => 'Ada', 'tags' => ['math', 'code']]);  // PHP value → JSON
$db->setRaw('greeting', 'hello world');                            // the set rule
$db->get('user:1', 'tags.-1');                                     // 'code'
$db->getJson('user:1');                                            // '{"name":"Ada","tags":["math","code"]}'
[$found, $value] = $db->lookup('missing');                         // [false, null]

$db['visits'] = 0;                                                 // ArrayAccess, Countable, IteratorAggregate
```

**PHP values.** `set` and `update` store:

* `null`, `bool`, `int`, `float`, and `string` (must be UTF-8; use `setRaw` for other bytes).
* Lists (`array_is_list`) as JSON arrays. Other arrays, `stdClass` and other objects become JSON objects; `JsonSerializable` is honoured. Use `new stdClass` for an empty object, because `[]` is an empty array.
* Floats are canonicalised from PHP's own JSON spelling, so PHP and Perl store `json_encode`'s text identically: `2.0` → `2`, `1e16` → `1e+16`, `1e21` → `1e+21`. `NAN` and `INF` are refused.

Values come back with objects as associative arrays (`CitronDB::decode($text, false)` gives `stdClass`). Integers outside PHP's range come back as floats. PHP arrays turn numeric-string keys into integers; `keys()` always returns strings.

**Atomic read-modify-write.** `modify` runs a callback under the exclusive lock with the records as `[key => stored JSON text]`, passed by reference. The file is rewritten once, and only if something changed. Values you write must come from `CitronDB::encode()` (PHP value) or `CitronDB::encodeRaw()` (the set rule):

```php
$next = $db->modify(function (array &$records) {
    $n = isset($records['counter']) ? CitronDB::decode($records['counter']) : 0;
    $records['counter'] = CitronDB::encode($n + 1);

    return $n + 1;
});
```

`read(fn (array $records) => ...)` is the shared-lock version. Writing inside `read` throws a `LogicException`.

**Errors** throw `Citron\CitronException`. The code is `CitronException::IO`, `CORRUPT`, `VERSION` or `INVALID`, the same values as the C codes.

**Laravel cache store.** With the package installed, `Citron\Laravel\CitronServiceProvider` is discovered automatically and registers a `citron` cache driver:

```php
// config/cache.php
'citron' => [
    'driver' => 'citron',
    'path' => env('CITRON_CACHE_PATH', storage_path('framework/cache/cache.citron')),
],
```

The store supports expiry, tags, atomic `add`/`increment`/`decrement`, `touch`, `flush`, and locks (`Cache::lock`). Each item is one record, `<prefix><key>` → `{"e": expiry timestamp or 0, "v": serialize(value)}`. Values whose serialized form isn't UTF-8 are stored base64-encoded under `"b"`. Expired items are skipped on read and purged on the next write. Every write is one `modify`, so concurrent PHP workers (and anything else sharing the file) stay consistent. Laravel's `cache.serializable_classes` setting limits which classes `unserialize` may create, as it does for Laravel's other stores.

---

## Sharing one database between languages

Any mix of Perl, C, Python and PHP processes can use one database at the same time:

* **Writes don't get lost.** Every write is a read-modify-write under the exclusive lock. The interop suites run Perl and binding processes writing the same file at once and count every record.
* **Readers never see a partial file.** Files are replaced by rename, and readers hold the shared lock.
* **Snapshots are shared.** A snapshot made in one language can be listed and restored in another. Numbering continues across them, and concurrent snapshotting never hands out a number twice.
* **Values look the same everywhere.** A record written by PHP's `set('n', 1.50)` and by Perl's `set n 1.50` is the same bytes.

On Windows, use a native Perl such as [Strawberry Perl](https://strawberryperl.com) on a shared database. The MSYS Perl that comes with Git Bash (`/usr/bin/perl`) emulates `flock` in a way that native programs (the C library, Python, PHP) can't see. Its locks wouldn't protect against them, nor theirs against it.

---

## Writing a new binding

A binding is a native implementation of the rules above. Port `bindings/c/src/citron.c` (or `bindings/php/src/Json.php` and `CitronDB.php`, if a high-level language is closer), and check each point:

1. **File format**: read versions 1 and 2, write version 2, records sorted by key bytes, refuse bad, truncated, trailing or newer files with the messages above.
2. **Locks**: `<db>.lock` opened for append, shared to read, exclusive to write, compatible with Perl's `flock` on your platform (on Windows, a range that overlaps bytes `0 .. 0xFFFF0000`).
3. **Writes**: `<db>.tmp`, fsync, rename. Remove a leftover `.tmp` on open. Skip writes that change nothing (but `import` always writes).
4. **Values**: a JSON parser that accepts exactly what JSON::PP accepts (512 levels, lax UTF-8 inside strings, surrogate pairs in escapes), and the canonical encoder with Perl's number rules (`normalize_number` in `citron.c`, `normalizeNumber` in `Json.php`). Plain text that isn't JSON is stored as a string, with Latin-1 fallback for invalid UTF-8.
5. **Paths**: Perl's `split` (trailing empty parts dropped), integer and negative indexes, and the path's bytes compared as Latin-1 characters.
6. **Snapshots**: names, never-reused numbering from the counter file, and checks on create and rollback.
7. **Display text**: strings unquoted, everything else canonical JSON (`to_text`). Exports are pretty-printed like JSON::PP's `pretty`, with keys read as Latin-1.

Then test it the way the existing bindings are tested. `test/python3/perl_ref.perl` runs a list of operations through `citron.perl`:

```bash
perl test/python3/perl_ref.perl <db> <ops file>
```

Each line of the ops file is tab-separated hex fields: an operation (`set`, `get`, `update`, `delete`, `exists`, `export`, `import`, `snapshot`, `snapshots`, `rollback`, `dropsnapshot`) and its arguments. It prints one hex line per result: `-` means missing and `!` means the operation died. Run the same operations through your binding, and compare the results, the database files, the snapshot folders and the exports byte for byte. `test/php/test_interop.php` is a self-contained example to copy. Add your suite to `test/bindings.t` so `prove test/` runs it.
