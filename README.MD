# CitronDB

A lightweight flat-file key-value store written in Perl.

CitronDB stores key-value data in a `.citron` file and currently uses hex encoding for storage.

## Project Structure

```text
.
└── src/
    ├── main.perl
    ├── config.perl
    ├── filesystem.perl
    └── citron.perl
```

* `main.perl` — Entry point
* `config.perl` — Configuration
* `filesystem.perl` — File I/O and hex encoding
* `citron.perl` — Key-value store logic

## How It Works

Data is currently serialized as:

```text
key=value;key2=value2;
```

The serialized data is then hex-encoded before being written to disk.

The default database file is:

```text
mainuser.citron
```

If the file doesn't exist, CitronDB creates it.

This is **obfuscation, not encryption**.

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

| Function                  | Description                  |
| ------------------------- | ---------------------------- |
| `file_exists($file)`      | Checks whether a file exists |
| `create_file($file)`      | Creates an empty file        |
| `open_file($file)`        | Reads file contents          |
| `write_file($file)`       | Writes the internal buffer   |
| `set_data($string)`       | Sets the internal buffer     |
| `get_data()`              | Returns the decoded buffer   |
| `convert_to_hex($string)` | Encodes a string as hex      |
| `convert_from_hex($hex)`  | Decodes hex                  |

## Usage

From the project root:

```bash
perl src/main.perl
```

Example:

```text
Initiating CitronDB...
mainuser.citron
CitronDB created
This is a test string
Test Set Value
test2: This is a test value 2
test: This is a test value
```

On subsequent runs:

```text
Initiating CitronDB...
mainuser.citron
CitronDB already exists
```

## Current Limitations

CitronDB v0.1 is intentionally simple.

* The entire database is read before modifying it.
* The entire database is written back after modification.
* There is currently no networking.
* `$host` and `$port` are reserved for future use.
* The storage format is very basic.

That's it for now.
