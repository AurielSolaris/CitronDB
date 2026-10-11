<?php

namespace Citron;

use ArrayAccess;
use ArrayIterator;
use Closure;
use Countable;
use IteratorAggregate;
use LogicException;
use Traversable;
use UnexpectedValueException;

require_once __DIR__.'/CitronException.php';
require_once __DIR__.'/Json.php';

/**
 * CitronDB 🍋 for PHP: a native implementation of the .citron format
 * (version 2). Needs no Perl, no compiled library and no FFI.
 *
 * Mirrors src/citron.perl, the reference implementation, byte for byte (as
 * bindings/c does): the same file format, the same values (input is
 * canonicalised exactly as JSON::PP does it) and the same rules, so Perl, C,
 * Python and PHP can use one database at the same time:
 *
 *   - readers take a shared lock and writers an exclusive lock on <db>.lock
 *   - every write goes to <db>.tmp, is fsynced, then renamed over the database
 *   - corrupt files and files from a newer version are refused
 *
 * Methods that take a PHP value store it as JSON; the *Raw methods take raw
 * input and follow the `set` command's rule (anything that parses as JSON is
 * stored as JSON, anything else as a plain string).
 *
 * A handle must not be shared between threads. Open one per process; the
 * file locks keep separate handles consistent.
 *
 * @implements ArrayAccess<string, mixed>
 * @implements IteratorAggregate<string, mixed>
 */
final class CitronDB implements ArrayAccess, Countable, IteratorAggregate
{
    public const VERSION = '0.5.2';

    public const FORMAT_VERSION = 2;

    private const MAGIC = 'CITRON';

    private const HEADER_SIZE = 14; // magic + version + record count

    private readonly string $lockPath;

    /** The bytes the cached records were parsed from (null: nothing cached). */
    private ?string $raw = null;

    /** @var array<string, string> key => stored JSON text */
    private array $records = [];

    /** Lock currently held by this handle: null, LOCK_SH or LOCK_EX. */
    private ?int $held = null;

    private function __construct(private readonly string $path)
    {
        $this->lockPath = $path.'.lock';
    }

    /**
     * Opens a database, creating it if missing and removing a temp file left
     * by a crash. An existing file is read, so a corrupt one fails here.
     */
    public static function open(string $path = 'mainuser.citron'): self
    {
        if ($path === '') {
            throw new CitronException('Empty database path', CitronException::INVALID);
        }

        $db = new self($path);

        $db->withLock(LOCK_EX, function () use ($db) {
            if (file_exists($db->path.'.tmp')) {
                @unlink($db->path.'.tmp');
            }

            if (file_exists($db->path)) {
                $db->load();
            } else {
                $db->save([]);
            }
        });

        return $db;
    }

    public function path(): string
    {
        return $this->path;
    }

    // --- public API (mirrors citron.perl) -----------------------------------

    /** Inserts or replaces a key with a PHP value. */
    public function set(string $key, mixed $value): void
    {
        $this->write($key, self::encode($value), false);
    }

    /** Inserts or replaces a key with raw input (JSON or plain text). */
    public function setRaw(string $key, string $input): void
    {
        $this->write($key, Json::encodeInput($input), false);
    }

    /** Replaces an existing key. Returns false if the key does not exist. */
    public function update(string $key, mixed $value): bool
    {
        return $this->write($key, self::encode($value), true);
    }

    public function updateRaw(string $key, string $input): bool
    {
        return $this->write($key, Json::encodeInput($input), true);
    }

    /** Removes a key. Returns false if it did not exist. */
    public function delete(string $key): bool
    {
        return $this->modify(function (array &$records) use ($key) {
            if (! array_key_exists($key, $records)) {
                return false;
            }

            unset($records[$key]);

            return true;
        });
    }

    public function exists(string $key): bool
    {
        return $this->read(fn (array $records) => array_key_exists($key, $records));
    }

    /**
     * Looks up a key, optionally drilling into a dotted path ("address.city",
     * "tags.0", "tags.-1"). Returns [found, value]; a stored JSON null is
     * found. Objects come back as associative arrays.
     *
     * @return array{0: bool, 1: mixed}
     */
    public function lookup(string $key, ?string $path = null): array
    {
        [$found, $value] = $this->find($key, $path);

        return [$found, $found ? Json::toPhp($value) : null];
    }

    /** The decoded value, or $default if the key (or path) is missing. */
    public function get(string $key, ?string $path = null, mixed $default = null): mixed
    {
        [$found, $value] = $this->lookup($key, $path);

        return $found ? $value : $default;
    }

    /** The value as canonical JSON text, or null if missing. */
    public function getJson(string $key, ?string $path = null): ?string
    {
        [$found, $value] = $this->find($key, $path);

        return $found ? Json::encode($value) : null;
    }

    /** Like getJson, but strings come back unquoted (as `get` prints them). */
    public function getText(string $key, ?string $path = null): ?string
    {
        [$found, $value] = $this->find($key, $path);

        return $found ? Json::text($value) : null;
    }

    /** @return list<string> every key, sorted */
    public function keys(): array
    {
        return $this->read(fn (array $records) => array_map('strval', array_keys($records)));
    }

    /**
     * Every record in readable form: strings as-is, everything else as its
     * stored JSON text (what `list` in citron.perl returns).
     *
     * @return array<string, string>
     */
    public function list(): array
    {
        return $this->read(function (array $records) {
            $data = [];

            foreach ($records as $key => $text) {
                $data[$key] = self::storedToText($text);
            }

            return $data;
        });
    }

    /**
     * Every record, decoded (list_values in citron.perl).
     *
     * @return array<string, mixed>
     */
    public function all(): array
    {
        return $this->read(function (array $records) {
            $data = [];

            foreach ($records as $key => $text) {
                $data[$key] = self::decode($text);
            }

            return $data;
        });
    }

    /** The whole database as one compact JSON object. */
    public function dump(): string
    {
        return $this->read(function (array $records) {
            $parts = [];

            foreach ($records as $key => $text) {
                $parts[] = Json::str(Json::textUtf8((string) $key)).':'.$text;
            }

            return '{'.implode(',', $parts).'}';
        });
    }

    /**
     * Merges a JSON object (JSON text, a PHP array or an object) into the
     * database in a single write; existing keys are replaced. Returns the
     * number of keys imported.
     */
    public function import(string|array|object $object): int
    {
        if (is_string($object)) {
            try {
                $parsed = Json::parse($object);
            } catch (UnexpectedValueException) {
                throw new CitronException('Invalid JSON', CitronException::INVALID);
            }
        } else {
            $parsed = $object === [] ? ['o', []] : Json::fromPhp($object);
        }

        if (! is_array($parsed) || $parsed[0] !== 'o') {
            throw new CitronException('Import must be a JSON object at the top level', CitronException::INVALID);
        }

        return $this->importObject($parsed[1]);
    }

    /** Writes every record to $file as pretty-printed JSON. Returns the record count. */
    public function exportJson(string $file): int
    {
        [$json, $count] = $this->read(function (array $records) {
            $lines = [];

            foreach ($records as $key => $text) {
                // keys are byte strings in citron.perl, so JSON::PP reads
                // their bytes as Latin-1
                $lines[] = '   '.Json::str(Json::latin1((string) $key)).' : '.Json::pretty(self::parseStored($text, $key), 1);
            }

            return [$lines === [] ? "{}\n" : "{\n".implode(",\n", $lines)."\n}\n", count($lines)];
        });

        error_clear_last();
        if (@file_put_contents($file, $json) !== strlen($json)) {
            throw new CitronException("Could not write '{$file}'".self::reason(), CitronException::IO);
        }

        return $count;
    }

    /** Merges the JSON object in $file into the database. Returns the record count. */
    public function importJson(string $file): int
    {
        error_clear_last();
        $content = @file_get_contents($file);

        if ($content === false) {
            throw new CitronException("Could not read '{$file}'".self::reason(), CitronException::IO);
        }

        try {
            $parsed = Json::parse($content);
        } catch (UnexpectedValueException) {
            throw new CitronException("Invalid JSON in '{$file}'", CitronException::INVALID);
        }

        if (! is_array($parsed) || $parsed[0] !== 'o') {
            throw new CitronException("'{$file}' must contain a JSON object at the top level", CitronException::INVALID);
        }

        return $this->importObject($parsed[1]);
    }

    /**
     * Read-modify-write under an exclusive lock: several operations as one
     * atomic step. $callback gets the records by reference as
     * [key => stored JSON text]; values written to it must come from
     * encode() or encodeRaw(). Its return value is passed back. The file is
     * only rewritten when the records changed.
     *
     * @template T
     *
     * @param  Closure(array<string, string>&): T  $callback
     * @return T
     */
    public function modify(Closure $callback): mixed
    {
        return $this->change($callback, false);
    }

    /**
     * Runs $callback on the records ([key => stored JSON text]) under a
     * shared lock.
     *
     * @template T
     *
     * @param  Closure(array<string, string>): T  $callback
     * @return T
     */
    public function read(Closure $callback): mixed
    {
        return $this->withLock(LOCK_SH, fn () => $callback($this->load()));
    }

    // --- snapshots (mirrors citron.perl) ------------------------------------

    /*
     * A snapshot is a full copy of the database file in "<db>.snapshots/",
     * stored as "<name>.citron". Unnamed snapshots are numbered 1, 2, 3, ...
     * from a counter that never goes down; named ones use letters and digits
     * with at least one letter.
     */

    /** Saves the current data as a snapshot. Returns the snapshot's name. */
    public function snapshot(?string $name = null): string
    {
        if ($name !== null && ! (self::isSnapshotName($name) && preg_match('/[A-Za-z]/', $name))) {
            throw new CitronException(
                "Invalid snapshot name '{$name}': use letters and digits, with at least one letter",
                CitronException::INVALID,
            );
        }

        return $this->withLock(LOCK_EX, function () use ($name) {
            $records = $this->load(); // refuses a corrupt database
            $raw = $this->raw !== '' ? $this->raw : self::serialize($records);

            $dir = $this->snapshotDir();

            if (! @mkdir($dir) && ! is_dir($dir)) {
                throw new CitronException("Could not create '{$dir}'", CitronException::IO);
            }

            if ($name !== null) {
                if (file_exists($this->snapshotPath($name))) {
                    throw new CitronException("Snapshot '{$name}' already exists", CitronException::INVALID);
                }
            } else {
                $name = $this->nextSnapshotNumber();
            }

            self::writeAtomic($this->snapshotPath($name), $raw);

            return $name;
        });
    }

    /** @return list<string> numbered snapshots in order, then named ones */
    public function snapshots(): array
    {
        return $this->withLock(LOCK_SH, fn () => $this->snapshotNames());
    }

    /**
     * Replaces the database with a snapshot (the snapshot is kept). Returns
     * false if there is no such snapshot. A corrupt snapshot is refused and
     * the database left untouched.
     */
    public function rollback(string $name): bool
    {
        if (! self::isSnapshotName($name)) {
            return false;
        }

        return $this->withLock(LOCK_EX, function () use ($name) {
            $path = $this->snapshotPath($name);

            if (! file_exists($path)) {
                return false;
            }

            $raw = self::readFile($path);

            try {
                $records = self::deserialize($raw);
            } catch (CitronException $e) {
                throw new CitronException("Snapshot '{$name}' is unusable: ".$e->getMessage(), $e->getCode(), $e);
            }

            self::writeAtomic($this->path, $raw);
            [$this->raw, $this->records] = [$raw, $records];

            return true;
        });
    }

    /** Deletes a snapshot. Returns false if it did not exist. */
    public function dropSnapshot(string $name): bool
    {
        if (! self::isSnapshotName($name)) {
            return false;
        }

        return $this->withLock(LOCK_EX, function () use ($name) {
            $path = $this->snapshotPath($name);

            if (! file_exists($path)) {
                return false;
            }

            error_clear_last();
            if (! @unlink($path)) {
                throw new CitronException("Could not delete '{$path}'".self::reason(), CitronException::IO);
            }

            return true;
        });
    }

    private function snapshotDir(): string
    {
        return $this->path.'.snapshots';
    }

    private function snapshotPath(string $name): string
    {
        return $this->snapshotDir()."/{$name}.citron";
    }

    private static function isSnapshotName(string $name): bool
    {
        return preg_match('/\A[A-Za-z0-9]+\z/', $name) === 1;
    }

    private static function isNumber(string $name): bool
    {
        return preg_match('/\A[0-9]+\z/', $name) === 1;
    }

    /** Numbers first (by value), then names sorted. */
    private static function snapshotOrder(string $x, string $y): int
    {
        $xn = self::isNumber($x);
        $yn = self::isNumber($y);

        if ($xn !== $yn) {
            return $xn ? -1 : 1;
        }

        if ($xn && strlen($x) !== strlen($y)) {
            return strlen($x) <=> strlen($y);
        }

        return strcmp($x, $y) <=> 0;
    }

    /** @return list<string> */
    private function snapshotNames(): array
    {
        $dir = $this->snapshotDir();

        if (! is_dir($dir)) {
            return [];
        }

        error_clear_last();
        $files = @scandir($dir);

        if ($files === false) {
            throw new CitronException("Could not read '{$dir}'".self::reason(), CitronException::IO);
        }

        $names = [];

        foreach ($files as $file) {
            if (preg_match('/\A([A-Za-z0-9]+)\.citron\z/', $file, $m)) {
                $names[] = $m[1];
            }
        }

        usort($names, self::snapshotOrder(...));

        return $names;
    }

    /** Next number: past the counter and past any numbered snapshot (in case
     * the counter file was lost). Saves the new counter. */
    private function nextSnapshotNumber(): string
    {
        $counter = $this->snapshotDir().'/counter';
        $last = '0';

        if (file_exists($counter)) {
            $last = self::readFile($counter);

            if (! self::isNumber($last)) {
                throw new CitronException("Corrupt snapshot counter '{$counter}'", CitronException::CORRUPT);
            }

            $last = ltrim(substr($last, 0, -1), '0').substr($last, -1);
        }

        foreach ($this->snapshotNames() as $name) {
            if (self::isNumber($name) && self::snapshotOrder($name, $last) > 0) {
                $last = $name;
            }
        }

        // add one to a decimal string of any length
        $i = strlen($last) - 1;
        while ($i >= 0 && $last[$i] === '9') {
            $last[$i] = '0';
            $i--;
        }
        $next = $i < 0 ? '1'.$last : substr_replace($last, (string) ((int) $last[$i] + 1), $i, 1);

        self::writeAtomic($counter, $next);

        return $next;
    }

    // --- values -------------------------------------------------------------

    /**
     * A PHP value as stored JSON text: canonical, exactly as JSON::PP writes
     * it. Lists become arrays; other arrays and objects become objects.
     */
    public static function encode(mixed $value): string
    {
        return Json::encode(Json::fromPhp($value));
    }

    /** Raw input as stored JSON text: valid JSON is kept, anything else
     * becomes a JSON string (the `set` command's rule). */
    public static function encodeRaw(string $input): string
    {
        return Json::encodeInput($input);
    }

    /** Decodes stored JSON text; objects become associative arrays unless
     * $assoc is false (then stdClass). */
    public static function decode(string $text, bool $assoc = true): mixed
    {
        // Stored text is canonical, so PHP's decoder reads it the same way
        // whenever it accepts it (not for Perl's lax UTF-8, for example).
        $value = json_decode($text, $assoc, 100000);

        if ($value !== null || $text === 'null') {
            return $value;
        }

        try {
            return Json::toPhp(Json::parse($text), $assoc);
        } catch (UnexpectedValueException) {
            throw new CitronException('Corrupt CitronDB value: not JSON', CitronException::CORRUPT);
        }
    }

    /** Readable form of a stored value: strings as-is, everything else as
     * JSON (stored_to_text in citron.perl). */
    private static function storedToText(string $text): string
    {
        if ($text === '' || $text[0] !== '"') {
            return $text;
        }

        if (! str_contains($text, '\\')) {
            return substr($text, 1, -1);
        }

        return Json::text(Json::parse($text));
    }

    /** @return array{0: bool, 1: mixed} [found, parsed value] */
    private function find(string $key, ?string $path): array
    {
        $text = $this->read(fn (array $records) => $records[$key] ?? null);

        if ($text === null) {
            return [false, null];
        }

        return Json::resolve(self::parseStored($text, $key), $path);
    }

    private static function parseStored(string $text, string|int $key): mixed
    {
        try {
            return Json::parse($text);
        } catch (UnexpectedValueException) {
            throw new CitronException("Corrupt CitronDB file: value of '{$key}' is not JSON", CitronException::CORRUPT);
        }
    }

    /** @param array<string, mixed> $members parsed object members */
    private function importObject(array $members): int
    {
        $encoded = [];

        foreach ($members as $key => $value) {
            $encoded[$key] = Json::encode($value);
        }

        // citron.perl rewrites the file even when nothing changed
        return $this->change(function (array &$records) use ($encoded) {
            foreach ($encoded as $key => $text) {
                $records[$key] = $text;
            }

            return count($encoded);
        }, true);
    }

    // --- file format --------------------------------------------------------

    /** @param array<string, string> $records */
    private static function serialize(array $records): string
    {
        ksort($records, SORT_STRING);

        $binary = self::MAGIC.pack('NN', self::FORMAT_VERSION, count($records));

        foreach ($records as $key => $value) {
            $key = (string) $key;
            $binary .= pack('N', strlen($key)).$key.pack('N', strlen($value)).$value;
        }

        return $binary;
    }

    /** @return array<string, string> */
    private static function deserialize(string $binary): array
    {
        $total = strlen($binary);

        if ($total === 0) {
            return [];
        }

        if ($total < self::HEADER_SIZE || ! str_starts_with($binary, self::MAGIC)) {
            throw new CitronException('Not a CitronDB file (bad header)', CitronException::CORRUPT);
        }

        $offset = strlen(self::MAGIC);

        $take = function (int $len, string $what) use ($binary, $total, &$offset): string {
            if ($offset + $len > $total) {
                throw new CitronException("Corrupt CitronDB file: truncated while reading {$what}", CitronException::CORRUPT);
            }

            $chunk = substr($binary, $offset, $len);
            $offset += $len;

            return $chunk;
        };
        $int = fn (string $what): int => unpack('N', $take(4, $what))[1];

        $version = $int('version');

        if ($version > self::FORMAT_VERSION) {
            throw new CitronException(
                "CitronDB file version {$version} is newer than supported version ".self::FORMAT_VERSION,
                CitronException::VERSION,
            );
        }

        if ($version < 1) {
            throw new CitronException("Corrupt CitronDB file: invalid version {$version}", CitronException::CORRUPT);
        }

        $records = [];
        $count = $int('record count');

        for ($i = 0; $i < $count; $i++) {
            $key = $take($int('key length'), 'key');
            $value = $take($int('value length'), 'value');

            // v1 stored raw strings; v2 stores JSON
            $records[$key] = $version === 1 ? Json::str(Json::textUtf8($value)) : $value;
        }

        if ($offset !== $total) {
            throw new CitronException(
                'Corrupt CitronDB file: '.($total - $offset).' unexpected trailing bytes',
                CitronException::CORRUPT,
            );
        }

        return $records;
    }

    // --- storage ------------------------------------------------------------

    /**
     * Runs $callback while holding a lock on "<db>.lock". A separate lock file
     * is used because writes replace the database file via rename. On Windows
     * PHP's flock() locks from byte 0, overlapping the range Perl and the C
     * library lock, so all of them exclude each other.
     */
    private function withLock(int $mode, Closure $callback): mixed
    {
        if ($this->held !== null) {
            if ($mode === LOCK_EX && $this->held === LOCK_SH) {
                throw new LogicException('Cannot write to CitronDB inside a read callback');
            }

            return $callback();
        }

        error_clear_last();
        $handle = @fopen($this->lockPath, 'a');

        if ($handle === false) {
            throw new CitronException("Could not open lock file '{$this->lockPath}'".self::reason(), CitronException::IO);
        }

        if (! flock($handle, $mode)) {
            fclose($handle);

            throw new CitronException("Could not lock '{$this->lockPath}'", CitronException::IO);
        }

        $this->held = $mode;

        try {
            return $callback();
        } finally {
            $this->held = null;
            flock($handle, LOCK_UN);
            fclose($handle);
        }
    }

    /**
     * The records as [key => stored JSON text]. Parsing is skipped when the
     * file's bytes are identical to the last ones parsed, so writes by other
     * processes are always seen.
     *
     * @return array<string, string>
     */
    private function load(): array
    {
        $raw = file_exists($this->path) ? self::readFile($this->path) : '';

        if ($raw !== $this->raw) {
            $this->records = self::deserialize($raw);
            $this->raw = $raw;
        }

        return $this->records;
    }

    /** @param array<string, string> $records */
    private function save(array $records): void
    {
        ksort($records, SORT_STRING);

        $raw = self::serialize($records);
        self::writeAtomic($this->path, $raw);

        [$this->raw, $this->records] = [$raw, $records];
    }

    private function change(Closure $callback, bool $alwaysSave): mixed
    {
        return $this->withLock(LOCK_EX, function () use ($callback, $alwaysSave) {
            $records = $this->load();
            $before = $records;

            $result = $callback($records);

            if ($alwaysSave || $records !== $before) {
                $this->save($records);
            }

            return $result;
        });
    }

    /** Writing the value a key already holds is skipped (so a version 1 file
     * stays version 1), as in citron.perl. */
    private function write(string $key, string $encoded, bool $onlyExisting): bool
    {
        return $this->modify(function (array &$records) use ($key, $encoded, $onlyExisting) {
            if ($onlyExisting && ! array_key_exists($key, $records)) {
                return false;
            }

            $records[$key] = $encoded;

            return true;
        });
    }

    private static function readFile(string $path): string
    {
        error_clear_last();
        $data = @file_get_contents($path);

        if ($data === false) {
            throw new CitronException("Could not open file '{$path}'".self::reason(), CitronException::IO);
        }

        return $data;
    }

    /** Writes "<path>.tmp", fsyncs it, then renames it over $path (same as
     * write_file in filesystem.perl). */
    private static function writeAtomic(string $path, string $data): void
    {
        $tmp = $path.'.tmp';
        error_clear_last();
        $handle = @fopen($tmp, 'wb');

        if ($handle === false) {
            throw new CitronException("Could not write to file '{$tmp}'".self::reason(), CitronException::IO);
        }

        $ok = fwrite($handle, $data) === strlen($data) && fflush($handle) && fsync($handle);
        $ok = fclose($handle) && $ok;

        if (! $ok) {
            @unlink($tmp);

            throw new CitronException("Could not write to file '{$tmp}'", CitronException::IO);
        }

        if (! self::replaceFile($tmp, $path)) {
            @unlink($tmp);

            throw new CitronException("Could not rename '{$tmp}' to '{$path}'".self::reason(), CitronException::IO);
        }
    }

    /**
     * Renames $from over $to. On Windows the rename fails while another
     * process (often a virus scanner looking at the fresh file) briefly has
     * either file open, so it is retried for up to about half a second.
     */
    private static function replaceFile(string $from, string $to): bool
    {
        for ($attempt = 1; ; $attempt++) {
            error_clear_last();
            if (@rename($from, $to)) {
                return true;
            }

            if (PHP_OS_FAMILY !== 'Windows' || $attempt === 10) {
                return false;
            }

            usleep(10_000 * $attempt);
        }
    }

    /** ": <reason>" from the last PHP warning, if any. */
    private static function reason(): string
    {
        $error = error_get_last()['message'] ?? '';
        $reason = preg_replace('/^.*?\):\s*/', '', $error);

        return $reason === '' ? '' : ': '.$reason;
    }

    // --- array-style access -------------------------------------------------

    public function offsetExists(mixed $offset): bool
    {
        return $this->exists((string) $offset);
    }

    public function offsetGet(mixed $offset): mixed
    {
        return $this->get((string) $offset);
    }

    public function offsetSet(mixed $offset, mixed $value): void
    {
        if ($offset === null) {
            throw new LogicException('CitronDB needs a key: $db[$key] = $value');
        }

        $this->set((string) $offset, $value);
    }

    public function offsetUnset(mixed $offset): void
    {
        $this->delete((string) $offset);
    }

    public function count(): int
    {
        return $this->read(fn (array $records) => count($records));
    }

    public function getIterator(): Traversable
    {
        return new ArrayIterator($this->all());
    }
}
