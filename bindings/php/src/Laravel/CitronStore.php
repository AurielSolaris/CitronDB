<?php

namespace Citron\Laravel;

use Citron\CitronDB;
use Illuminate\Cache\TaggableStore;
use Illuminate\Contracts\Cache\LockProvider;
use Illuminate\Support\InteractsWithTime;

/**
 * Laravel cache store backed by a CitronDB file.
 *
 * Each item is one CitronDB record under "<prefix><key>" holding
 * {"e": expiry timestamp (0 = forever), "v": serialized value}. Values whose
 * serialized form isn't valid UTF-8 are kept base64-encoded under "b"
 * instead, since CitronDB values are JSON. Expired items are skipped on read
 * and purged on the next write. Every write is one atomic CitronDB
 * read-modify-write, so add(), increment() and locks are safe across processes.
 */
class CitronStore extends TaggableStore implements LockProvider
{
    use InteractsWithTime;

    /**
     * @param  array<int, class-string>|bool|null  $serializableClasses
     */
    public function __construct(
        protected CitronDB $db,
        protected string $prefix = '',
        protected array|bool|null $serializableClasses = null,
    ) {}

    /**
     * Retrieve an item from the cache by key.
     *
     * @param  string  $key
     */
    public function get($key): mixed
    {
        return $this->many([$key])[$key];
    }

    /**
     * Retrieve multiple items from the cache by key. Missing items are null.
     *
     * @param  array<int, string>  $keys
     * @return array<string, mixed>
     */
    public function many(array $keys): array
    {
        $now = $this->currentTime();

        return $this->db->read(function (array $records) use ($keys, $now) {
            $values = [];

            foreach ($keys as $key) {
                $payload = $this->livePayload($records, $key, $now);
                $values[$key] = $payload === null ? null : $this->unserializePayload($payload);
            }

            return $values;
        });
    }

    /**
     * Store an item in the cache for a given number of seconds.
     *
     * @param  string  $key
     * @param  int  $seconds
     */
    public function put($key, $value, $seconds): bool
    {
        return $this->putMany([$key => $value], $seconds);
    }

    /**
     * Store multiple items in the cache for a given number of seconds.
     *
     * @param  array<string, mixed>  $values
     * @param  int  $seconds
     */
    public function putMany(array $values, $seconds): bool
    {
        $expiration = $this->expiration($seconds);

        return $this->modify(function (array &$records) use ($values, $expiration) {
            foreach ($values as $key => $value) {
                $records[$this->prefix.$key] = $this->encodePayload($value, $expiration);
            }

            return true;
        });
    }

    /**
     * Store an item in the cache if the key doesn't exist (or has expired).
     *
     * @param  string  $key
     * @param  int  $seconds
     */
    public function add($key, $value, $seconds): bool
    {
        $expiration = $this->expiration($seconds);

        return $this->modify(function (array &$records, int $now) use ($key, $value, $expiration) {
            if ($this->livePayload($records, $key, $now) !== null) {
                return false;
            }

            $records[$this->prefix.$key] = $this->encodePayload($value, $expiration);

            return true;
        });
    }

    /**
     * Increment the value of an item in the cache, keeping its expiry.
     *
     * @param  string  $key
     * @param  int  $value
     */
    public function increment($key, $value = 1): int
    {
        return $this->modify(function (array &$records, int $now) use ($key, $value) {
            $payload = $this->livePayload($records, $key, $now);

            $newValue = ((int) ($payload === null ? 0 : $this->unserializePayload($payload))) + $value;

            $records[$this->prefix.$key] = $this->encodePayload($newValue, $payload['e'] ?? 0);

            return $newValue;
        });
    }

    /**
     * Decrement the value of an item in the cache.
     *
     * @param  string  $key
     * @param  int  $value
     */
    public function decrement($key, $value = 1): int
    {
        return $this->increment($key, $value * -1);
    }

    /**
     * Store an item in the cache indefinitely.
     *
     * @param  string  $key
     */
    public function forever($key, $value): bool
    {
        return $this->put($key, $value, 0);
    }

    /**
     * Adjust the expiration time of a cached item.
     *
     * @param  string  $key
     * @param  int  $seconds
     */
    public function touch($key, $seconds): bool
    {
        $expiration = $this->expiration($seconds);

        return $this->modify(function (array &$records, int $now) use ($key, $expiration) {
            $payload = $this->livePayload($records, $key, $now);

            if ($payload === null) {
                return false;
            }

            $records[$this->prefix.$key] = CitronDB::encode([...$payload, 'e' => $expiration]);

            return true;
        });
    }

    /**
     * Remove an item from the cache.
     *
     * @param  string  $key
     */
    public function forget($key): bool
    {
        return $this->modify(function (array &$records) use ($key) {
            if (! array_key_exists($this->prefix.$key, $records)) {
                return false;
            }

            unset($records[$this->prefix.$key]);

            return true;
        });
    }

    /**
     * Remove every item under this store's prefix.
     */
    public function flush(): bool
    {
        return $this->db->modify(function (array &$records) {
            foreach (array_keys($records) as $key) {
                if (str_starts_with((string) $key, $this->prefix)) {
                    unset($records[$key]);
                }
            }

            return true;
        });
    }

    /**
     * Get a lock instance.
     *
     * @param  string  $name
     * @param  int  $seconds
     * @param  string|null  $owner
     */
    public function lock($name, $seconds = 0, $owner = null): CitronLock
    {
        return new CitronLock($this, $name, $seconds, $owner);
    }

    /**
     * Restore a lock instance using the owner identifier.
     *
     * @param  string  $name
     * @param  string  $owner
     */
    public function restoreLock($name, $owner): CitronLock
    {
        return $this->lock($name, 0, $owner);
    }

    /**
     * Remove an item only if it currently holds the given value.
     */
    public function forgetIfValue(string $key, mixed $expected): bool
    {
        return $this->modify(function (array &$records, int $now) use ($key, $expected) {
            $payload = $this->livePayload($records, $key, $now);

            if ($payload === null || $this->unserializePayload($payload) !== $expected) {
                return false;
            }

            unset($records[$this->prefix.$key]);

            return true;
        });
    }

    /**
     * Extend an item's expiration only if it currently holds the given value.
     */
    public function touchIfValue(string $key, mixed $expected, int $seconds): bool
    {
        $expiration = $this->expiration($seconds);

        return $this->modify(function (array &$records, int $now) use ($key, $expected, $expiration) {
            $payload = $this->livePayload($records, $key, $now);

            if ($payload === null || $this->unserializePayload($payload) !== $expected) {
                return false;
            }

            $records[$this->prefix.$key] = CitronDB::encode([...$payload, 'e' => $expiration]);

            return true;
        });
    }

    public function getPrefix(): string
    {
        return $this->prefix;
    }

    public function getDatabase(): CitronDB
    {
        return $this->db;
    }

    /**
     * Runs a CitronDB read-modify-write, purging this store's expired items
     * first. The callback receives the records and the current time.
     *
     * @template T
     *
     * @param  \Closure(array<string, string>&, int): T  $callback
     * @return T
     */
    protected function modify(\Closure $callback): mixed
    {
        $now = $this->currentTime();

        return $this->db->modify(function (array &$records) use ($callback, $now) {
            foreach ($records as $key => $text) {
                if (str_starts_with((string) $key, $this->prefix) && $this->isExpired(CitronDB::decode($text), $now)) {
                    unset($records[$key]);
                }
            }

            return $callback($records, $now);
        });
    }

    /**
     * The decoded payload for a key, or null if it is missing or expired.
     *
     * @param  array<string, string>  $records
     * @return array{e: int, v?: string, b?: string}|null
     */
    protected function livePayload(array $records, string $key, int $now): ?array
    {
        $text = $records[$this->prefix.$key] ?? null;

        if ($text === null) {
            return null;
        }

        $payload = CitronDB::decode($text);

        return $this->isExpired($payload, $now) ? null : $payload;
    }

    protected function isExpired(mixed $payload, int $now): bool
    {
        return ! is_array($payload)
            || ! isset($payload['e'])
            || ($payload['e'] !== 0 && $payload['e'] <= $now);
    }

    protected function encodePayload(mixed $value, int $expiration): string
    {
        $serialized = serialize($value);

        return CitronDB::encode(preg_match('//u', $serialized)
            ? ['e' => $expiration, 'v' => $serialized]
            : ['b' => base64_encode($serialized), 'e' => $expiration]);
    }

    /**
     * @param  array{e: int, v?: string, b?: string}  $payload
     */
    protected function unserializePayload(array $payload): mixed
    {
        $serialized = $payload['v'] ?? base64_decode($payload['b'] ?? '', true);

        if (! is_string($serialized)) {
            return null;
        }

        return $this->serializableClasses !== null
            ? unserialize($serialized, ['allowed_classes' => $this->serializableClasses])
            : unserialize($serialized);
    }

    /**
     * The expiry timestamp for a lifetime in seconds; 0 means forever.
     */
    protected function expiration(int $seconds): int
    {
        return $seconds > 0 ? $this->availableAt($seconds) : 0;
    }
}
