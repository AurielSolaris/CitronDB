# CitronDB 🍋

**Client Initiated Transitive Redundant Onsite Networked DataBase**

A lightweight, embeddable key-value store written in Perl.

CitronDB stores JSON values in a single `.citron` file. You talk to it with Redis-style commands; like SQLite, there's no server, just a file.

## Project Structure

```text
.
├── test/
│   ├── lib.perl
│   ├── api.t
│   ├── format.t
│   ├── concurrency.t
│   └── cli.t
└── src/
    ├── main.perl
    ├── config.perl
    ├── filesystem.perl
    ├── citron.perl
    ├── cli.perl
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
* `search_*.perl` — Search modules
* `mapreduce.perl` — Batch map-reduce jobs over stored data
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

All search modules expose `search_keys($pattern)`, `search_values($pattern)`, `search_pairs($pattern)`, and `print_results($results)`.

| Module                  | Description                                      |
| ----------------------- | ------------------------------------------------ |
| `search_binary`         | Exact match via binary search                    |
| `search_substring`      | Partial string match                             |
| `search_regex`          | Regex pattern match                              |
| `search_fuzzy`          | Character sequence match                         |
| `search_prefix`         | Matches strings that start with the pattern      |
| `search_suffix`         | Matches strings that end with the pattern        |
| `search_levenshtein`    | Edit distance match (default threshold: 3)       |
| `search_soundex`        | Phonetic match via Soundex                       |

### `mapreduce`

Map-reduce runs as a read-only batch job over the stored data: map each key-value pair to intermediate pairs, group by intermediate key, reduce each group.

| Function              | Description                                          |
| --------------------- | ---------------------------------------------------- |
| `run($map, $reduce)`  | Runs a map-reduce over all key-value pairs           |
| `run_job($name)`      | Runs a named built-in job                            |
| `job_names()`         | Returns available job names                          |
| `print_results($results)` | Prints results                                   |

Built-in jobs: `count` (record count), `wordcount` (word frequency across values), `sum` (sum of numeric values).

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
CitronDB v0.4 — type 'help' for commands
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

## Current Limitations

CitronDB v0.4 is intentionally simple.

* The entire database is read before modifying it.
* The entire database is written back after modification.
* There is currently no networking.
* `$host` and `$port` are reserved for future use.

That's it for now.