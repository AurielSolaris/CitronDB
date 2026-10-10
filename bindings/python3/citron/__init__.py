"""CitronDB 🍋 for Python 3 — a ctypes binding to the CitronDB C library.

    import citron

    with citron.open("app.citron") as db:
        db.set("user:1", {"name": "Ada", "tags": ["math"]})
        db.get("user:1", "tags.0")          # 'math'
        db["count"] = 42
        "count" in db                       # True

Works on the same .citron files as the Perl implementation, at the same
time: the C library uses the same locks, atomic writes and file format.

The shared library is looked up in this order: the CITRON_LIB environment
variable, this package's directory, then bindings/c/build/ in a source
checkout (build it with `make` in bindings/c).
"""

import ctypes
import json
import os
import sys

__all__ = ["Citron", "CitronError", "open", "version"]

_MISSING = object()


class CitronError(Exception):
    """A CitronDB failure; `code` is the CITRON_E* value from citron.h."""

    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


def _library_names():
    if sys.platform == "win32":
        return ["citron.dll"]
    if sys.platform == "darwin":
        return ["libcitron.dylib"]
    return ["libcitron.so"]


def _load_library():
    candidates = []
    if os.environ.get("CITRON_LIB"):
        candidates.append(os.environ["CITRON_LIB"])

    here = os.path.dirname(os.path.abspath(__file__))
    build = os.path.join(here, "..", "..", "c", "build")
    for directory in (here, build):
        candidates += [os.path.join(directory, name) for name in _library_names()]

    for path in candidates:
        if os.path.exists(path):
            return ctypes.CDLL(os.path.abspath(path))

    raise OSError(
        "CitronDB C library not found (tried: %s). Build it with `make` in "
        "bindings/c or set CITRON_LIB." % ", ".join(candidates)
    )


_lib = _load_library()

_p = ctypes.c_void_p
_s = ctypes.c_char_p
_int = ctypes.c_int

for _name, _args in {
    "citron_open": [_s, ctypes.POINTER(_p)],
    "citron_set": [_p, _s, _s],
    "citron_update": [_p, _s, _s],
    "citron_delete": [_p, _s],
    "citron_exists": [_p, _s],
    "citron_get": [_p, _s, _s, ctypes.POINTER(_p), ctypes.POINTER(ctypes.c_size_t)],
    "citron_get_text": [_p, _s, _s, ctypes.POINTER(_p), ctypes.POINTER(ctypes.c_size_t)],
    "citron_keys": [_p, ctypes.POINTER(_p), ctypes.POINTER(ctypes.c_size_t)],
    "citron_dump": [_p, ctypes.POINTER(_p)],
    "citron_import": [_p, _s],
    "citron_export_json": [_p, _s],
    "citron_import_json": [_p, _s],
    "citron_snapshot": [_p, _s, ctypes.POINTER(_p)],
    "citron_snapshots": [_p, ctypes.POINTER(_p), ctypes.POINTER(ctypes.c_size_t)],
    "citron_rollback": [_p, _s],
    "citron_drop_snapshot": [_p, _s],
}.items():
    getattr(_lib, _name).argtypes = _args
    getattr(_lib, _name).restype = _int

_lib.citron_close.argtypes = [_p]
_lib.citron_close.restype = None
_lib.citron_errmsg.argtypes = [_p]
_lib.citron_errmsg.restype = _s
_lib.citron_version.argtypes = []
_lib.citron_version.restype = _s
_lib.citron_free.argtypes = [_p]
_lib.citron_free.restype = None
_lib.citron_free_keys.argtypes = [_p]
_lib.citron_free_keys.restype = None


def version():
    """Version of the loaded C library, e.g. '0.5.2'."""
    return _lib.citron_version().decode()


# Keys and text are UTF-8; surrogateescape lets keys that aren't valid UTF-8
# (possible in files written by other tools) round-trip.
def _bytes(text):
    return text.encode("utf-8", "surrogateescape")


def _str(data):
    return data.decode("utf-8", "surrogateescape")


def _path(path):
    return os.fsencode(path) if sys.platform != "win32" else os.fspath(path).encode("mbcs")


def _take_string(ptr, length=None):
    """Copies a library-owned string and frees it."""
    try:
        if length is None:
            return ctypes.string_at(ptr.value)
        return ctypes.string_at(ptr.value, length.value)
    finally:
        _lib.citron_free(ptr)


class Citron:
    """A handle on one database file. Not for concurrent use across threads;
    open one handle per thread instead."""

    def __init__(self, path="mainuser.citron"):
        self.path = os.fspath(path)
        self._db = None
        handle = _p()
        rc = _lib.citron_open(_path(self.path), ctypes.byref(handle))
        self._db = handle
        if rc < 0:
            message = _lib.citron_errmsg(handle).decode("utf-8", "replace")
            self.close()
            raise CitronError(message, rc)

    # --- lifecycle --------------------------------------------------------

    def close(self):
        if self._db is not None:
            _lib.citron_close(self._db)
            self._db = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def __del__(self):
        self.close()

    def _check(self, rc):
        if rc < 0:
            if self._db is None:
                raise CitronError("Database is closed", rc)
            raise CitronError(_lib.citron_errmsg(self._db).decode("utf-8", "replace"), rc)
        return rc

    def _handle(self):
        if self._db is None:
            raise CitronError("Database is closed", -4)
        return self._db

    # --- API (mirrors citron.perl) ----------------------------------------

    def set(self, key, value):
        """Inserts or replaces a key. `value` is any JSON-serialisable value."""
        self._check(_lib.citron_set(self._handle(), _bytes(key), _json_bytes(value)))

    def set_raw(self, key, text):
        """Inserts or replaces a key from raw input, like `set` in the CLI:
        valid JSON is stored as JSON, anything else as a plain string."""
        self._check(_lib.citron_set(self._handle(), _bytes(key), _bytes(text)))

    def update(self, key, value):
        """Replaces an existing key. Returns False if the key doesn't exist."""
        return bool(self._check(_lib.citron_update(self._handle(), _bytes(key), _json_bytes(value))))

    def update_raw(self, key, text):
        return bool(self._check(_lib.citron_update(self._handle(), _bytes(key), _bytes(text))))

    def delete(self, key):
        """Removes a key. Returns True if it existed."""
        return bool(self._check(_lib.citron_delete(self._handle(), _bytes(key))))

    def exists(self, key):
        return bool(self._check(_lib.citron_exists(self._handle(), _bytes(key))))

    def lookup(self, key, path=None):
        """Returns (found, value); tells a missing key apart from JSON null.
        `path` drills into the value: "address.city", "tags.0", "tags.-1"."""
        out, length = _p(), ctypes.c_size_t()
        found = self._check(_lib.citron_get(
            self._handle(), _bytes(key), None if path is None else _bytes(path),
            ctypes.byref(out), ctypes.byref(length)))
        if not found:
            return False, None
        return True, json.loads(_str(_take_string(out, length)))

    def get(self, key, path=None, default=None):
        """Returns the decoded value (optionally at a path), or `default`."""
        found, value = self.lookup(key, path)
        return value if found else default

    def get_text(self, key, path=None):
        """The value as `get` in the CLI prints it (strings unquoted), or None."""
        out, length = _p(), ctypes.c_size_t()
        found = self._check(_lib.citron_get_text(
            self._handle(), _bytes(key), None if path is None else _bytes(path),
            ctypes.byref(out), ctypes.byref(length)))
        return _str(_take_string(out, length)) if found else None

    def keys(self):
        """All keys, sorted."""
        out = _p()
        self._check(_lib.citron_keys(self._handle(), ctypes.byref(out), None))
        try:
            array = ctypes.cast(out, ctypes.POINTER(ctypes.c_char_p))
            keys = []
            i = 0
            while array[i] is not None:
                keys.append(_str(array[i]))
                i += 1
            return keys
        finally:
            _lib.citron_free_keys(out)

    def list_values(self):
        """Returns {key: decoded value} for every record."""
        out = _p()
        self._check(_lib.citron_dump(self._handle(), ctypes.byref(out)))
        return json.loads(_str(_take_string(out)))

    def list(self):
        """Returns {key: text} for every record: strings as-is, everything
        else as its stored JSON text (exactly as the Perl `list` shows it)."""
        out = _p()
        self._check(_lib.citron_dump(self._handle(), ctypes.byref(out)))
        return {key: value if isinstance(value, str) else raw
                for key, value, raw in _dump_items(_str(_take_string(out)))}

    def import_dict(self, data):
        """Merges a dict into the database in one write. Returns the count."""
        if not isinstance(data, dict):
            raise TypeError("import_dict expects a dict")
        return self._check(_lib.citron_import(self._handle(), _json_bytes(data)))

    def export_json(self, file):
        """Writes the database to a pretty-printed JSON file. Returns the count."""
        return self._check(_lib.citron_export_json(self._handle(), _path(file)))

    def import_json(self, file):
        """Merges a JSON file's top-level object into the database in one
        write. Returns the count."""
        return self._check(_lib.citron_import_json(self._handle(), _path(file)))

    # --- snapshots (mirrors citron.perl) ----------------------------------

    def snapshot(self, name=None):
        """Saves the current data as a snapshot and returns its name. Without
        a name it gets the next number ("1", "2", ...); a name must be letters
        and digits with at least one letter, and must not exist yet."""
        out = _p()
        self._check(_lib.citron_snapshot(
            self._handle(), None if name is None else _bytes(name), ctypes.byref(out)))
        return _str(_take_string(out))

    def snapshots(self):
        """All snapshot names: numbered ones in order, then named ones."""
        out = _p()
        self._check(_lib.citron_snapshots(self._handle(), ctypes.byref(out), None))
        try:
            array = ctypes.cast(out, ctypes.POINTER(ctypes.c_char_p))
            names = []
            while array[len(names)] is not None:
                names.append(_str(array[len(names)]))
            return names
        finally:
            _lib.citron_free_keys(out)

    def rollback(self, name):
        """Replaces the database with a snapshot, atomically (the snapshot is
        kept). Returns False if there's no such snapshot."""
        return bool(self._check(_lib.citron_rollback(self._handle(), _bytes(name))))

    def drop_snapshot(self, name):
        """Deletes a snapshot. Returns True if it existed."""
        return bool(self._check(_lib.citron_drop_snapshot(self._handle(), _bytes(name))))

    # --- dict-style access ------------------------------------------------

    def __getitem__(self, key):
        found, value = self.lookup(key)
        if not found:
            raise KeyError(key)
        return value

    def __setitem__(self, key, value):
        self.set(key, value)

    def __delitem__(self, key):
        if not self.delete(key):
            raise KeyError(key)

    def __contains__(self, key):
        return self.exists(key)

    def __iter__(self):
        return iter(self.keys())

    def __len__(self):
        return len(self.keys())

    def items(self):
        return self.list_values().items()

    def values(self):
        return self.list_values().values()

    def __repr__(self):
        state = "closed" if self._db is None else "open"
        return "<Citron %r (%s)>" % (self.path, state)


def _json_bytes(value):
    # NaN/Infinity aren't JSON; strict UTF-8 so lone surrogates raise.
    text = json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    return text.encode("utf-8")


_decoder = json.JSONDecoder()


def _dump_items(text):
    """Yields (key, value, raw JSON text) from citron_dump's compact object."""
    i = 1
    if text[i] == "}":
        return
    while True:
        key, i = _decoder.raw_decode(text, i)
        start = i + 1  # skip ':'
        value, i = _decoder.raw_decode(text, start)
        yield key, value, text[start:i]
        if text[i] == "}":
            return
        i += 1  # skip ','


def open(path="mainuser.citron"):  # noqa: A001 - mirrors sqlite3.connect style
    """Opens (creating if missing) a CitronDB database."""
    return Citron(path)
