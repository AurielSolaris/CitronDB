# CitronDB 🍋

**Client Initiated Transitive Redundant Onsite Networked DataBase**

A lightweight flat-file key-value store written in Perl.

CitronDB stores key-value data in a `.citron` file using a custom binary format.

## Project Structure

```text
.
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

## How It Works

Data is stored in a custom binary format:

```text
[CITRON magic bytes]
[version - int]
[record count - int]
--- per record ---
[key length - int]
[key - hex]
[value length - int]
[value - hex]
--- repeat ---
```

The default database file is:

```text
mainuser.citron
```

If the file doesn't exist, CitronDB creates it.

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

| Function                    | Description                         |
| --------------------------- | ----------------------------------- |
| `set_data($key, $value)`    | Inserts a key-value pair            |
| `get_data($key)`            | Retrieves a value                   |
| `update_data($key, $value)` | Updates an existing key-value pair  |
| `delete_data($key)`         | Deletes a key-value pair            |
| `list()`                    | Returns all key-value pairs         |
| `get_all()`                 | Prints all key-value pairs          |
| `print_data($key)`          | Prints a value                      |

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
CitronDB v0.3 — type 'help' for commands
citron>
```

Or pass a command directly:

```bash
perl src/main.perl set <key> <value>
perl src/main.perl get <key>
perl src/main.perl search <string> <type>
perl src/main.perl mapreduce <job>
```

### Commands

| Command                       | Description                                              |
| ----------------------------- | -------------------------------------------------------- |
| `set <key> <value>`           | Insert a key-value pair                                  |
| `get <key>`                   | Retrieve a value                                         |
| `update <key> <value>`        | Update an existing key-value pair                        |
| `delete <key>`                | Delete a key-value pair                                  |
| `list`                        | Print all key-value pairs                                |
| `search <string> <type>`      | Search the database (default type: binary)               |
| `mapreduce <job>`             | Run a map-reduce job (count, wordcount, sum)             |
| `help`                        | Print available commands                                 |
| `exit`                        | Exit the REPL                                            |

## Current Limitations

CitronDB v0.3 is intentionally simple.

* The entire database is read before modifying it.
* The entire database is written back after modification.
* There is currently no networking.
* `$host` and `$port` are reserved for future use.

That's it for now.