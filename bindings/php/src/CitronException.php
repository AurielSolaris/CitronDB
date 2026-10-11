<?php

namespace Citron;

use RuntimeException;

/**
 * A CitronDB failure. The code is one of the CITRON_E* values from citron.h.
 */
class CitronException extends RuntimeException
{
    /** File could not be read, written or locked. */
    public const IO = -1;

    /** Bad header, truncated records or trailing bytes. */
    public const CORRUPT = -2;

    /** File written by a newer CitronDB. */
    public const VERSION = -3;

    /** Bad argument or invalid JSON. */
    public const INVALID = -4;
}
