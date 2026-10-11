<?php

namespace Citron\Laravel;

use Illuminate\Cache\Lock;

/**
 * Atomic lock stored as a CitronStore item. Acquire, release and refresh each
 * run inside one exclusive CitronDB transaction.
 */
class CitronLock extends Lock
{
    /**
     * @param  string  $name
     * @param  int  $seconds
     * @param  string|null  $owner
     */
    public function __construct(protected CitronStore $store, $name, $seconds, $owner = null)
    {
        parent::__construct($name, $seconds, $owner);
    }

    /**
     * Attempt to acquire the lock.
     */
    public function acquire(): bool
    {
        return $this->store->add($this->name, $this->owner, $this->seconds);
    }

    /**
     * Release the lock if it is owned by this lock's owner.
     */
    public function release(): bool
    {
        return $this->store->forgetIfValue($this->name, $this->owner);
    }

    /**
     * Release the lock regardless of ownership.
     */
    public function forceRelease(): void
    {
        $this->store->forget($this->name);
    }

    /**
     * Extend the lock if it is still owned by this lock's owner.
     *
     * @param  int|null  $seconds
     */
    public function refresh($seconds = null): bool
    {
        return $this->store->touchIfValue($this->name, $this->owner, $seconds ?? $this->seconds);
    }

    /**
     * Returns the owner value written into the driver for this lock.
     */
    protected function getCurrentOwner(): mixed
    {
        return $this->store->get($this->name);
    }
}
