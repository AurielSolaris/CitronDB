<?php

namespace Citron;

use stdClass;
use UnexpectedValueException;

/**
 * JSON exactly as citron.perl handles it with JSON::PP (utf8, canonical,
 * allow_nonref). A port of the JSON code in bindings/c/src/citron.c.
 *
 * Parsed values are kept in a form that remembers what PHP values can't:
 * strings are PHP strings (UTF-8 bytes), null/true/false are themselves,
 * numbers are ['n', text], arrays ['a', list] and objects ['o', map] with
 * the map sorted by key.
 *
 * @internal
 */
final class Json
{
    private const MAX_DEPTH = 512;

    /** UTF-8 sequence length caps: JSON::PP looks at 4 bytes per character
     * inside JSON strings, plain strings go through utf8::decode whole. */
    public const UTF8_JSON_MAX = 4;

    public const UTF8_PLAIN_MAX = 6;

    /** Characters that end a run of plain string bytes. */
    private const STRING_STOP = "\"\\\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f"
        ."\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f";

    private const NUMBER = '/\G-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/';

    /** @var array<string, string>|null */
    private static ?array $escapes = null;

    private int $p = 0;

    private readonly int $n;

    private function __construct(private readonly string $s)
    {
        $this->n = strlen($s);
    }

    // --- parsing ------------------------------------------------------------

    /**
     * Parses a complete JSON document.
     *
     * @throws UnexpectedValueException if it isn't valid JSON
     */
    public static function parse(string $text): mixed
    {
        $parser = new self($text);
        $value = $parser->value(1);
        $parser->ws();

        if ($parser->p !== $parser->n) {
            throw new UnexpectedValueException('Invalid JSON');
        }

        return $value;
    }

    private static function invalid(): never
    {
        throw new UnexpectedValueException('Invalid JSON');
    }

    private function ws(): void
    {
        if ($this->p < $this->n) {
            $this->p += strspn($this->s, " \t\n\r", $this->p);
        }
    }

    private function value(int $depth): mixed
    {
        if ($depth > self::MAX_DEPTH) {
            self::invalid();
        }

        $this->ws();

        if ($this->p >= $this->n) {
            self::invalid();
        }

        return match ($this->s[$this->p]) {
            '{' => $this->object($depth),
            '[' => $this->array($depth),
            '"' => $this->string(),
            't' => $this->literal('true', true),
            'f' => $this->literal('false', false),
            'n' => $this->literal('null', null),
            default => $this->number(),
        };
    }

    private function literal(string $word, ?bool $value): ?bool
    {
        if (substr_compare($this->s, $word, $this->p, strlen($word)) !== 0) {
            self::invalid();
        }

        $this->p += strlen($word);

        return $value;
    }

    private function hex4(): int
    {
        $hex = substr($this->s, $this->p, 4);

        if (strlen($hex) !== 4 || strspn($hex, '0123456789abcdefABCDEF') !== 4) {
            self::invalid();
        }

        $this->p += 4;

        return hexdec($hex);
    }

    private function string(): string
    {
        $out = '';
        $this->p++; // opening quote

        for (;;) {
            $run = strcspn($this->s, self::STRING_STOP, $this->p);

            if ($run > 0) {
                $chunk = substr($this->s, $this->p, $run);

                if (! self::utf8Valid($chunk, self::UTF8_JSON_MAX)) {
                    self::invalid();
                }

                $out .= $chunk;
                $this->p += $run;
            }

            if ($this->p >= $this->n) {
                self::invalid();
            }

            $c = $this->s[$this->p++];

            if ($c === '"') {
                return $out;
            }

            if ($c !== '\\' || $this->p >= $this->n) {
                self::invalid(); // a control character, or a lone backslash at the end
            }

            $out .= match ($this->s[$this->p++]) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => "\x08",
                'f' => "\f",
                'n' => "\n",
                'r' => "\r",
                't' => "\t",
                'u' => self::codepoint($this->unicodeEscape()),
                default => self::invalid(),
            };
        }
    }

    private function unicodeEscape(): int
    {
        $cp = $this->hex4();

        if ($cp >= 0xDC00 && $cp <= 0xDFFF) {
            self::invalid();
        }

        if ($cp >= 0xD800 && $cp <= 0xDBFF) {
            if (substr_compare($this->s, '\\u', $this->p, 2) !== 0) {
                self::invalid();
            }

            $this->p += 2;
            $lo = $this->hex4();

            if ($lo < 0xDC00 || $lo > 0xDFFF) {
                self::invalid();
            }

            $cp = 0x10000 + (($cp - 0xD800) << 10) + ($lo - 0xDC00);
        }

        return $cp;
    }

    private function number(): string|array
    {
        if (! preg_match(self::NUMBER, $this->s, $m, 0, $this->p)) {
            self::invalid();
        }

        $this->p += strlen($m[0]);

        return self::normalizeNumber($m[0]);
    }

    private function array(int $depth): array
    {
        $items = [];
        $this->p++;
        $this->ws();

        if ($this->p < $this->n && $this->s[$this->p] === ']') {
            $this->p++;

            return ['a', $items];
        }

        for (;;) {
            $items[] = $this->value($depth + 1);
            $this->ws();

            if ($this->p >= $this->n) {
                self::invalid();
            }

            $c = $this->s[$this->p++];

            if ($c === ']') {
                return ['a', $items];
            }

            if ($c !== ',') {
                self::invalid();
            }
        }
    }

    private function object(int $depth): array
    {
        $members = [];
        $this->p++;
        $this->ws();

        if ($this->p < $this->n && $this->s[$this->p] === '}') {
            $this->p++;

            return ['o', $members];
        }

        for (;;) {
            $this->ws();

            if ($this->p >= $this->n || $this->s[$this->p] !== '"') {
                self::invalid();
            }

            $key = $this->string();
            $this->ws();

            if ($this->p >= $this->n || $this->s[$this->p++] !== ':') {
                self::invalid();
            }

            $members[$key] = $this->value($depth + 1); // a duplicate key: the last one wins
            $this->ws();

            if ($this->p >= $this->n) {
                self::invalid();
            }

            $c = $this->s[$this->p++];

            if ($c === '}') {
                ksort($members, SORT_STRING);

                return ['o', $members];
            }

            if ($c !== ',') {
                self::invalid();
            }
        }
    }

    // --- numbers ------------------------------------------------------------

    /**
     * Number text as JSON::PP writes it back after decoding (number() in
     * JSON/PP.pm). Integers that fit IV/UV stay exact, integers longer than
     * 20 characters become strings, "1.50" is printed as an NV ("1.5"), "1e3"
     * as an integer ("1000").
     */
    private static function normalizeNumber(string $lex): string|array
    {
        $hasDot = str_contains($lex, '.');
        $hasExp = strpbrk($lex, 'eE') !== false;

        if (! $hasDot && ! $hasExp) {
            $neg = $lex[0] === '-';
            $digits = $neg ? substr($lex, 1) : $lex;
            $limit = $neg ? '9223372036854775808' : '18446744073709551615';

            if (strlen($lex) > 20) {
                return $lex;
            }

            if (strlen($digits) < strlen($limit) || (strlen($digits) === strlen($limit) && strcmp($digits, $limit) <= 0)) {
                return ['n', $lex === '-0' ? '0' : $lex];
            }
        }

        $v = (float) $lex;
        $text = null;

        if ((! $hasDot && $hasExp) || ($hasDot && $hasExp && abs($v) > 9007199254740992.0)) {
            $text = self::formatIv($v);
        }

        return ['n', $text ?? self::formatNv($v)];
    }

    /** Perl's stringification of a floating point value (NV): "%.15g". */
    public static function formatNv(float $v): string
    {
        if ($v == 0) {
            return '0';
        }

        if (is_infinite($v)) {
            return $v > 0 ? 'Inf' : '-Inf';
        }

        // 15 significant digits, correctly rounded, and the decimal exponent
        [$mantissa, $exp] = explode('e', sprintf('%.14e', $v));
        $neg = $mantissa[0] === '-';
        $digits = str_replace(['-', '.'], '', $mantissa);
        $exp = (int) $exp;
        $sign = $neg ? '-' : '';

        if ($exp < -4 || $exp >= 15) {
            $frac = rtrim(substr($digits, 1), '0');

            return $sign.$digits[0].($frac === '' ? '' : '.'.$frac)
                .'e'.($exp < 0 ? '-' : '+').str_pad((string) abs($exp), 2, '0', STR_PAD_LEFT);
        }

        if ($exp < 0) {
            $text = '0.'.str_repeat('0', -$exp - 1).$digits;
        } else {
            $text = substr($digits, 0, $exp + 1).'.'.substr($digits, $exp + 1);
        }

        return $sign.rtrim(rtrim($text, '0'), '.');
    }

    /** $v as an integer if Perl would hold it as one (IV/UV): integral and
     * within [-2^63, 2^64). */
    public static function formatIv(float $v): ?string
    {
        if (! ($v >= -9223372036854775808.0 && $v < 18446744073709551616.0) || floor($v) != $v) {
            return null;
        }

        if ($v >= -9223372036854775808.0 && $v < 9223372036854775808.0) {
            return (string) (int) $v;
        }

        return sprintf('%.0f', $v); // exact: doubles this large are integers
    }

    // --- UTF-8 --------------------------------------------------------------

    /**
     * Is $s UTF-8 by Perl's lax rules (utf8::decode)? Surrogates and code
     * points above U+10FFFF are accepted, overlong forms are not. $maxLen
     * caps the bytes per character.
     */
    public static function utf8Valid(string $s, int $maxLen): bool
    {
        if (preg_match('//u', $s)) {
            return true; // strict UTF-8 is a subset
        }

        static $minCp = [0, 0, 0x80, 0x800, 0x10000, 0x200000, 0x4000000];

        for ($i = 0, $n = strlen($s); $i < $n;) {
            $c = ord($s[$i]);

            if ($c < 0x80) {
                $i++;

                continue;
            }

            [$len, $cp] = match (true) {
                $c >= 0xC2 && $c <= 0xDF => [2, $c & 0x1F],
                $c >= 0xE0 && $c <= 0xEF => [3, $c & 0x0F],
                $c >= 0xF0 && $c <= 0xF7 => [4, $c & 0x07],
                $c >= 0xF8 && $c <= 0xFB => [5, $c & 0x03],
                $c >= 0xFC && $c <= 0xFD => [6, $c & 0x01],
                default => [0, 0],
            };

            if ($len === 0 || $len > $maxLen || $n - $i < $len) {
                return false;
            }

            for ($k = 1; $k < $len; $k++) {
                $b = ord($s[$i + $k]);

                if (($b & 0xC0) !== 0x80) {
                    return false;
                }

                $cp = ($cp << 6) | ($b & 0x3F);
            }

            if ($cp < $minCp[$len]) {
                return false;
            }

            $i += $len;
        }

        return true;
    }

    /** UTF-8 for a code point (up to U+1FFFFF). */
    public static function codepoint(int $cp): string
    {
        return match (true) {
            $cp < 0x80 => chr($cp),
            $cp < 0x800 => chr(0xC0 | $cp >> 6).chr(0x80 | ($cp & 0x3F)),
            $cp < 0x10000 => chr(0xE0 | $cp >> 12).chr(0x80 | (($cp >> 6) & 0x3F)).chr(0x80 | ($cp & 0x3F)),
            default => chr(0xF0 | $cp >> 18).chr(0x80 | (($cp >> 12) & 0x3F))
                .chr(0x80 | (($cp >> 6) & 0x3F)).chr(0x80 | ($cp & 0x3F)),
        };
    }

    /** Each byte read as a Latin-1 character, as UTF-8. */
    public static function latin1(string $s): string
    {
        return preg_replace_callback('/[\x80-\xff]/', fn ($m) => self::codepoint(ord($m[0])), $s);
    }

    /** Text as UTF-8: kept if already valid, otherwise read as Latin-1 (what
     * Perl does with bytes that utf8::decode rejects). */
    public static function textUtf8(string $s): string
    {
        return self::utf8Valid($s, self::UTF8_PLAIN_MAX) ? $s : self::latin1($s);
    }

    // --- encoding -----------------------------------------------------------

    /** Canonical encoding, matching JSON::PP->canonical: sorted keys, no
     * whitespace, only quote, backslash and control characters escaped. */
    public static function encode(mixed $v): string
    {
        if ($v === null) {
            return 'null';
        }

        if (is_bool($v)) {
            return $v ? 'true' : 'false';
        }

        if (is_string($v)) {
            return self::str($v);
        }

        [$type, $x] = $v;

        if ($type === 'n') {
            return $x;
        }

        if ($type === 'a') {
            return '['.implode(',', array_map(self::encode(...), $x)).']';
        }

        $parts = [];

        foreach ($x as $key => $member) {
            $parts[] = self::str((string) $key).':'.self::encode($member);
        }

        return '{'.implode(',', $parts).'}';
    }

    public static function str(string $s): string
    {
        if (self::$escapes === null) {
            self::$escapes = ['"' => '\\"', '\\' => '\\\\'];

            for ($c = 0; $c < 0x20; $c++) {
                self::$escapes[chr($c)] = sprintf('\\u%04x', $c);
            }

            self::$escapes["\n"] = '\\n';
            self::$escapes["\r"] = '\\r';
            self::$escapes["\t"] = '\\t';
            self::$escapes["\f"] = '\\f';
            self::$escapes["\x08"] = '\\b';
        }

        return '"'.strtr($s, self::$escapes).'"';
    }

    /** JSON::PP->pretty: three-space indent, "key" : value, empty containers
     * inline. */
    public static function pretty(mixed $v, int $level): string
    {
        if (! is_array($v) || $v[0] === 'n' || $v[1] === []) {
            return self::encode($v);
        }

        $pad = str_repeat('   ', $level + 1);
        $lines = [];

        foreach ($v[1] as $key => $member) {
            $lines[] = $pad.($v[0] === 'o' ? self::str((string) $key).' : ' : '').self::pretty($member, $level + 1);
        }

        [$open, $close] = $v[0] === 'a' ? ['[', ']'] : ['{', '}'];

        return $open."\n".implode(",\n", $lines)."\n".str_repeat('   ', $level).$close;
    }

    /** Raw input -> stored JSON text: valid JSON is kept, anything else
     * becomes a JSON string. */
    public static function encodeInput(string $input): string
    {
        try {
            return self::encode(self::parse($input));
        } catch (UnexpectedValueException) {
            return self::str(self::textUtf8($input));
        }
    }

    /** How `get` prints a value: strings as-is, everything else as JSON. */
    public static function text(mixed $v): string
    {
        return is_string($v) ? $v : self::encode($v);
    }

    // --- PHP values ---------------------------------------------------------

    /**
     * A PHP value as a parsed JSON value. Lists become arrays, other arrays
     * and objects become objects (JsonSerializable is honoured). Strings
     * must be UTF-8.
     *
     * @throws CitronException for values JSON can't hold
     */
    public static function fromPhp(mixed $value, int $depth = 1): mixed
    {
        if ($depth > self::MAX_DEPTH) {
            throw new CitronException('Value is nested too deeply', CitronException::INVALID);
        }

        if ($value instanceof \JsonSerializable) {
            $value = $value->jsonSerialize();
        }

        return match (true) {
            $value === null, is_bool($value) => $value,
            is_int($value) => ['n', (string) $value],
            is_float($value) => ['n', self::floatText($value)],
            is_string($value) => self::checkUtf8($value),
            is_array($value) && array_is_list($value) => ['a', array_map(fn ($v) => self::fromPhp($v, $depth + 1), $value)],
            is_array($value), is_object($value) => self::objectFromPhp(is_object($value) ? get_object_vars($value) : $value, $depth),
            default => throw new CitronException('Value cannot be stored as JSON: '.get_debug_type($value), CitronException::INVALID),
        };
    }

    private static function objectFromPhp(array $members, int $depth): array
    {
        $out = [];

        foreach ($members as $key => $member) {
            $out[self::checkUtf8((string) $key)] = self::fromPhp($member, $depth + 1);
        }

        ksort($out, SORT_STRING);

        return ['o', $out];
    }

    /** A float's text as JSON::PP stores PHP's JSON for it (json_encode with
     * the default shortest round-trip spelling), so PHP and Perl agree. */
    private static function floatText(float $v): string
    {
        if (is_nan($v) || is_infinite($v)) {
            throw new CitronException('Value cannot be stored as JSON: NAN and INF are not JSON', CitronException::INVALID);
        }

        $precision = ini_set('serialize_precision', '-1');

        try {
            $text = json_encode($v, JSON_PRESERVE_ZERO_FRACTION);
        } finally {
            ini_set('serialize_precision', (string) $precision);
        }

        return self::normalizeNumber($text)[1];
    }

    private static function checkUtf8(string $s): string
    {
        if (! self::utf8Valid($s, self::UTF8_JSON_MAX)) {
            throw new CitronException(
                'Value cannot be stored as JSON: strings must be UTF-8 (use setRaw for other bytes)',
                CitronException::INVALID,
            );
        }

        return $s;
    }

    /**
     * A parsed JSON value as a PHP value. Objects become associative arrays,
     * or stdClass when $assoc is false. Integers outside PHP's range become
     * floats.
     */
    public static function toPhp(mixed $v, bool $assoc = true): mixed
    {
        if (! is_array($v)) {
            return $v;
        }

        [$type, $x] = $v;

        if ($type === 'n') {
            return match (true) {
                $x === 'Inf' => INF,
                $x === '-Inf' => -INF,
                (string) (int) $x === $x => (int) $x,
                default => (float) $x,
            };
        }

        $out = [];

        foreach ($x as $key => $member) {
            $out[$key] = self::toPhp($member, $assoc);
        }

        return $type === 'o' && ! $assoc ? (object) $out : $out;
    }

    // --- paths --------------------------------------------------------------

    /**
     * Walks a dotted path ("address.city", "tags.0", "tags.-1") like
     * resolve_path in citron.perl. The path is a byte string there, so each
     * byte is matched as a Latin-1 character against the keys.
     *
     * @return array{0: bool, 1: mixed} [found, value]
     */
    public static function resolve(mixed $v, ?string $path): array
    {
        if ($path === null || $path === '') {
            return [true, $v];
        }

        // Perl's split drops trailing empty fields
        $parts = explode('.', rtrim(self::latin1($path), '.'));

        if ($parts === ['']) {
            return [true, $v];
        }

        foreach ($parts as $part) {
            if (is_array($v) && $v[0] === 'o' && array_key_exists($part, $v[1])) {
                $v = $v[1][$part];
            } elseif (is_array($v) && $v[0] === 'a' && preg_match('/\A-?[0-9]+\z/', $part)
                && ($i = self::index($part)) < count($v[1]) && $i >= -count($v[1])) {
                $v = $v[1][$i < 0 ? count($v[1]) + $i : $i];
            } else {
                return [false, null];
            }
        }

        return [true, $v];
    }

    /** An index; huge ones are clamped (they're far out of range anyway). */
    private static function index(string $part): int
    {
        $digits = ltrim($part, '-');

        if (strlen(ltrim($digits, '0')) > 15) {
            return $part[0] === '-' ? PHP_INT_MIN : PHP_INT_MAX;
        }

        return (int) $part;
    }
}
