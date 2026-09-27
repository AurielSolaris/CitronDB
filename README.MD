# CitronDB 🍋

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
    └── cli.perl
```

* `main.perl` — Entry point and REPL
* `config.perl` — Configuration
* `filesystem.perl` — Raw binary file I/O
* `citron.perl` — Key-value store logic and binary format
* `cli.perl` — Argument parsing

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

| Function                 | Description                         |
| ------------------------ | ----------------------------------- |
| `set_data($key, $value)` | Inserts or updates a key-value pair |
| `get_data($key)`         | Retrieves a value                   |
| `print_data($key)`       | Prints a value                      |

### `filesystem`

| Function                  | Description                    |
| ------------------------- | ------------------------------ |
| `file_exists($file)`      | Checks whether a file exists   |
| `create_file($file)`      | Creates an empty file          |
| `open_file($file)`        | Reads raw binary file contents |
| `write_file($file)`       | Writes the internal buffer     |
| `set_data($string)`       | Sets the internal buffer       |
| `get_data()`              | Returns the internal buffer    |
| `convert_to_hex($string)` | Encodes a string as hex        |
| `convert_from_hex($hex)`  | Decodes hex                    |

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
CitronDB v0.1 — type 'help' for commands
citron> 
```

Or pass a command directly:

```bash
perl src/main.perl set <key> <value>
perl src/main.perl get <key>
```

## Current Limitations

CitronDB v0.1 is intentionally simple.

* The entire database is read before modifying it.
* The entire database is written back after modification.
* There is currently no networking.
* `$host` and `$port` are reserved for future use.

That's it for now.