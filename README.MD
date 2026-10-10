# CitronDB 🍋

**Client Initiated Transitive Redundant Onsite Networked DataBase**

A lightweight, embeddable key-value store written in Perl.

CitronDB stores JSON values in a single `.citron` file. You talk to it with Redis-style commands; like SQLite, there's no server, just a file.

You can also embed it from **C** and **Python 3** through the bindings in `bindings/`. The Perl implementation is the reference: the bindings follow its behavior and file format, and Perl and the bindings can use the same database at the same time.

## Project Structure

```text
.
├── bindings/
│   ├── c/
│   │   ├── include/citron.h
│   │   ├── src/citron.c
│   │   └── Makefile
│   └── python3/
│       └── citron/__init__.py
├── examples/
│   ├── perl/example.perl
│   ├── c/example.c
│   └── python3/example.py
├── test/
│   ├── lib.perl
│   ├── api.t
│   ├── format.t
│   ├── concurrency.t
│   ├── cli.t
│   ├── search.t
│   ├── bindings.t
│   ├── c/test_citron.c
│   └── python3/
│       ├── test_citron.py
│       ├── test_interop.py
│       └── perl_ref.perl
└── src/
    ├── main.perl
    ├── config.perl
    ├── filesystem.perl
    ├── citron.perl
    ├── cli.perl
    ├── search_index.perl
    ├── search_binary.perl
    ├── search_regex.perl
    ├── search_fuzzy.perl
    ├── search_prefix.perl
    ├── search_suffix.perl
    ├── search_levenshtein.perl
    ├── search_soundex.perl
    ├── search_substring.perl
    └── mapreduce.perl
```

* `main.perl` — Entry point and REPL
* `config.perl` — Configuration
* `filesystem.perl` — Raw binary file I/O
* `citron.perl` — Key-value store logic and binary format
* `cli.perl` — Argument parsing
* `search_index.perl` — In-memory search indexes (hash maps, sorted arrays)
* `search_*.perl` — Search modules
* `mapreduce.perl` — Batch map-reduce jobs over stored data
* `bindings/c/` — C library (the FFI) that implements the file format natively
* `bindings/python3/` — Python 3 package built on the C library
* `examples/` — The same walkthrough in Perl, C and Python 3
* `test/` — Test suite

## How It Works

Data is stored in a custom binary format (version 2):

```text
[CITRON magic bytes]
[version - int]
[record count - int]
--- per record ---
[key length - int]
[key - bytes]
[value length - int]
[value - JSON, UTF-8]
--- repeat ---
```

All ints are 32-bit big-endian.

### Values are JSON

Anything that parses as JSON is stored as JSON; anything else is stored as a plain string.

```text
citron> set user:1 {"name":"Ada","age":36,"tags":["math","code"]}
citron> set greeting hello world        <- plain string
citron> set count 42                    <- number
citron> set zip "02139"                 <- string (quoted JSON)
```

### Stability

* **Atomic writes** — every write goes to `<db>.tmp`, is fsynced, then renamed over the database. A crash never leaves a half-written database; leftover temp files are removed on open.
* **Locking** — readers take a shared lock and writers an exclusive lock on `<db>.lock`, so multiple processes can safely use the same file.
* **Corruption detection** — a bad header, truncated records or trailing garbage raises an error instead of being read as an empty database (and then overwritten).
* **Versioning** — files from a newer CitronDB are refused. Version 1 files (plain string values) are read and upgraded to version 2 on the next write.
* **No pointless writes** — `set` or `update` with the value a key already holds doesn't rewrite the file.

### Caching

A process keeps the records it last read or wrote. Each operation still reads the file under its lock, but it only parses the file again if the bytes changed, so writes from other processes are always seen. Repeated reads and searches in one process (the REPL, a script embedding CitronDB) skip the parsing, which is most of the cost.

The default database file is:

```text
mainuser.citron
```

Use `--file=<path>` to pick another one. If the file doesn't exist, CitronDB creates it.

## Configuration

`config.perl` contains the current configuration:

| Variable        | Default           | Description             |
| --------------- | ----------------- | ----------------------- |
| `$config::file` | `mainuser.citron` | Database file           |
| `$config::port` | `666`             | Reserved for future use |
| `$config::host` | `localhost`       | Reserved for future use |

The port is `666` because why not.

## API

### `citron`

All functions die with a message on corruption or I/O errors.

| Function                    | Description                                                        |
| --------------------------- | ------------------------------------------------------------------ |
| `open_db()`                 | Creates the database if missing, removes stale temp files          |
| `set_data($key, $value)`    | Inserts or replaces a key (`$value` is JSON or plain text)         |
| `get_data($key, $path)`     | Returns the decoded value (optionally at a path), or `undef`       |
| `lookup($key, $path)`       | Returns `(found, value)`, which tells a missing key apart from JSON `null` |
| `exists_data($key)`         | Returns 1 if the key exists, else 0                                |
| `update_data($key, $value)` | Replaces an existing key; returns 0 if the key doesn't exist       |
| `delete_data($key)`         | Deletes a key; returns 1 if it existed, else 0                     |
| `list()`                    | Returns all pairs as `{ key => text }` (non-strings as JSON text)  |
| `list_values()`             | Returns all pairs as `{ key => decoded value }`                    |
| `export_json($file)`        | Writes all pairs to a JSON file; returns the count                 |
| `import_json($file)`        | Merges a JSON object into the database in one write; returns the count |
| `to_text($value)`           | Formats a value for display                                        |
| `get_all()`                 | Prints all key-value pairs                                         |
| `print_data($key)`          | Prints a value                                                     |

Embedding it in your own script:

```perl
require "./src/citron.perl";

$config::file = "app.citron";
citron::open_db();

citron::set_data("user:1", '{"name":"Ada","tags":["math"]}');
print citron::get_data("user:1", "tags.0"), "\n";   # math
```

### `filesystem`

| Function                  | Description                    |
| ------------------------- | ------------------------------ |
| `file_exists($file)`      | Checks whether a file exists   |
| `create_file($file)`      | Creates an empty file          |
| `open_file($file)`        | Reads raw binary file contents |
| `write_file($file)`       | Writes the internal buffer atomically (temp file + fsync + rename) |
| `set_data($string)`       | Sets the internal buffer       |
| `get_data()`              | Returns the internal buffer    |
| `convert_to_hex($string)` | Encodes a string as hex        |
| `convert_from_hex($hex)`  | Decodes hex                    |
| `cleanup_tmp($file)`      | Deletes a stale `.tmp` file    |

### Search Modules

All search modules expose `search_keys($pattern)`, `search_values($pattern)`, `search_pairs($pattern)`, and `print_results($results)`. Results are `{ key => text }`.

Most searches don't walk every record. `search_index.perl` builds in-memory indexes over keys and values the first time a search needs them, and keeps them until the data changes:

* **hash maps** for exact values and soundex codes: one lookup
* **sorted arrays** with binary search (a flat B-tree) for case-insensitive prefixes, and for suffixes via the reversed strings: O(log n + matches)
* **length buckets** for edit distance: only strings within the threshold's length range are compared, each distinct string once, after a cheap lower-bound filter

| Module               | Description                                       | How it runs                       |
| -------------------- | ------------------------------------------------- | --------------------------------- |
| `search_binary`      | Exact match (every key or value equal to it)      | hash lookup                       |
| `search_prefix`      | Starts with the pattern, ignoring case            | sorted index, binary search       |
| `search_suffix`      | Ends with the pattern, ignoring case              | sorted index of reversed strings  |
| `search_soundex`     | Phonetic match via American Soundex               | hash of soundex codes             |
| `search_levenshtein` | Edit distance match (default threshold: 3)        | length buckets + lower bound      |
| `search_substring`   | Partial string match                              | scan of cached text               |
| `search_regex`       | Regex pattern match                               | scan, regex compiled once         |
| `search_fuzzy`       | Pattern's characters in order, ignoring case      | scan, regex compiled once         |

Substring, regex and fuzzy matches can sit anywhere in a string, so a sorted index can't narrow them down. They scan, but over cached text, with nothing re-read or re-parsed between searches.

Search is part of the Perl implementation; the C and Python bindings don't include it yet.

### `mapreduce`

Map-reduce runs as a read-only batch job over the stored data: map each key-value pair to intermediate pairs, group by intermediate key, reduce each group.

| Function              | Description                                          |
| --------------------- | ---------------------------------------------------- |
| `run($map, $reduce)`  | Runs a map-reduce over all key-value pairs           |
| `run_job($name)`      | Runs a named built-in job                            |
| `job_names()`         | Returns available job names                          |
| `print_results($results)` | Prints results                                   |

Built-in jobs: `count` (record count), `wordcount` (word frequency across values), `sum` (sum of numeric values).

## Bindings

The C library in `bindings/c` is a native implementation of the `.citron` format. It mirrors `citron.perl`:

* the same file format, version 2, and it upgrades version 1 files the same way
* the same locks on `<db>.lock` (compatible with Perl's `flock`, on Windows too), and the same temp file + fsync + rename writes
* the same corruption and version errors
* the same values: input is canonicalised exactly as JSON::PP does it, so `1.50` → `1.5`, `1e3` → `1000`, and sorted keys. Perl and C write byte-identical files.

`test/python3/test_interop.py` runs the same operations through Perl and the bindings and checks that results, database files and exports match byte for byte. When `citron.perl` changes, the bindings follow, and this test is what catches drift.

### Building the C library

```bash
make -C bindings/c          # build/libcitron.a and build/citron.dll / libcitron.so / libcitron.dylib
make -C bindings/c test     # C tests
make -C bindings/c example  # build and run examples/c/example.c
```

It's one C17 file with no dependencies, so you can also compile `bindings/c/src/citron.c` straight into your project. Define `CITRON_SHARED` when you build or use the Windows DLL.

### C API

Include `citron.h`. Calls return `CITRON_OK` (0) or a result ≥ 0, or a negative error code: `CITRON_EIO`, `CITRON_ECORRUPT`, `CITRON_EVERSION`, `CITRON_EINVALID`, `CITRON_ENOMEM`. `citron_errmsg(db)` says what went wrong.

| Function                                      | Perl equivalent | Description                                                      |
| --------------------------------------------- | --------------- | ---------------------------------------------------------------- |
| `citron_open(path, &db)` / `citron_close(db)` | `open_db()`     | Opens (creating if missing); `path` NULL means `mainuser.citron` |
| `citron_set(db, key, value)`                  | `set_data`      | Inserts or replaces (`value` is JSON or plain text)              |
| `citron_update(db, key, value)`               | `update_data`   | Replaces an existing key; returns 0 if it doesn't exist          |
| `citron_delete(db, key)`                      | `delete_data`   | Returns 1 if the key existed, else 0                             |
| `citron_exists(db, key)`                      | `exists_data`   | Returns 1 or 0                                                   |
| `citron_get(db, key, path, &out, &len)`       | `lookup`        | Returns 1 and the value as JSON text, or 0 if missing            |
| `citron_get_text(db, key, path, &out, &len)`  | `to_text`       | Same, but strings come back unquoted                             |
| `citron_keys(db, &keys, &count)`              | `list`          | All keys, sorted, as a NULL-terminated array                     |
| `citron_dump(db, &out)`                       | `list_values`   | The whole database as one JSON object                            |
| `citron_import(db, json)`                     | —               | Merges a JSON object string in one write                         |
| `citron_export_json(db, file)`                | `export_json`   | Writes a pretty-printed JSON file; returns the count             |
| `citron_import_json(db, file)`                | `import_json`   | Merges a JSON file in one write; returns the count               |
| `citron_free(p)` / `citron_free_keys(keys)`   |                 | Free what the library returned                                   |

```c
#include "citron.h"

citron *db;
char *name;

citron_open("app.citron", &db);
citron_set(db, "user:1", "{\"name\":\"Ada\",\"tags\":[\"math\"]}");
if (citron_get_text(db, "user:1", "name", &name, NULL) == 1) {
    puts(name);                       /* Ada */
    citron_free(name);
}
citron_close(db);
```

A handle must not be used from two threads at once; open one per thread.

### Python 3

`bindings/python3/citron` is a ctypes package and needs no compiler. It loads the C library from `CITRON_LIB`, then from the package directory, then from `bindings/c/build/`.

```python
import citron

with citron.open("app.citron") as db:
    db.set("user:1", {"name": "Ada", "tags": ["math"]})   # Python values stored as JSON
    db.get("user:1", "tags.0")                             # 'math'
    db.set_raw("greeting", "hello world")                  # CLI rule: JSON if it parses, else a string
    db["count"] = 42
    "count" in db, len(db), db.keys()
```

| Method                                                     | Perl equivalent              |
| ---------------------------------------------------------- | ---------------------------- |
| `set(key, value)` / `set_raw(key, text)`                   | `set_data`                   |
| `get(key, path=None, default=None)`                        | `get_data`                   |
| `lookup(key, path=None)` → `(found, value)`                | `lookup`                     |
| `get_text(key, path=None)`                                 | `to_text(get_data(...))`     |
| `update(key, value)` / `update_raw(key, text)`             | `update_data`                |
| `delete(key)`, `exists(key)`                               | `delete_data`, `exists_data` |
| `list()`, `list_values()`, `keys()`                        | `list`, `list_values`        |
| `export_json(file)`, `import_json(file)`, `import_dict(d)` | `export_json`, `import_json` |

A `Citron` also works like a dict (`db[key]`, `del db[key]`, `in`, `len`, iteration, `items()`). Errors raise `citron.CitronError`, and its `.code` is the C error code.

## Examples

The same walkthrough in each language. Run them from the project root:

```bash
perl examples/perl/example.perl
make -C bindings/c && python examples/python3/example.py
make -C bindings/c example
```

## Usage

From the project root:

```bash
perl src/main.perl
```

Drops you into the REPL:

```text
Initiating CitronDB...
mainuser.citron
CitronDB created
CitronDB v0.5.1 — type 'help' for commands
citron>
```

Or pass a command directly:

```bash
perl src/main.perl set <key> <value>
perl src/main.perl get <key> [path]
perl src/main.perl search <string> <type>
perl src/main.perl mapreduce <job>
perl src/main.perl --file=other.citron list
```

On Windows (cmd/PowerShell), escape the quotes inside JSON on the command line: `perl src/main.perl set user:1 "{\"name\":\"Ada\"}"`. The REPL needs no escaping.

### Commands

| Command                       | Description                                              |
| ----------------------------- | -------------------------------------------------------- |
| `set <key> <value>`           | Insert or replace a key                                  |
| `get <key> [path]`            | Retrieve a value, or a field inside it (`address.city`, `tags.0`) |
| `update <key> <value>`        | Replace an existing key (error if it doesn't exist)      |
| `delete <key>`                | Delete a key (`(integer) 1` if it existed, else `0`)     |
| `exists <key>`                | `(integer) 1` if the key exists, else `0`                |
| `list`                        | Print all key-value pairs                                |
| `search <string> <type>`      | Search the database (default type: binary)               |
| `mapreduce <job>`             | Run a map-reduce job (count, wordcount, sum)             |
| `export <file.json>`          | Write the whole database to a JSON file                  |
| `import <file.json>`          | Merge a JSON object's keys into the database             |
| `help`                        | Print available commands                                 |
| `exit`                        | Exit the REPL                                            |

A missing key prints `(nil)`; errors print `(error) ...` and don't end the REPL.

## Tests

From the project root:

```bash
prove test/
```

`test/bindings.t` builds the C library and runs the C tests (`test/c`) and the Python tests (`test/python3`), including the Perl interop suite. It skips itself when `make` or a C compiler isn't available. To run the parts separately:

```bash
make -C bindings/c test
python -m unittest discover test/python3
```

## Current Limitations

CitronDB v0.5.1 is intentionally simple.

* The entire database is read before modifying it.
* The entire database is written back after modification.
* Search indexes live in memory and are rebuilt per process; they aren't stored in the file.
* There is currently no networking.
* `$host` and `$port` are reserved for future use.

That's it for now.