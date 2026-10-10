"""The bindings must behave exactly like the Perl implementation.

Runs the same operations through src/citron.perl and through the C library
(via the Python binding) and compares every result, the database files byte
for byte, and the export files byte for byte.

Needs perl on PATH (or CITRON_PERL). Run from anywhere:

    python -m unittest discover test/python3
"""

import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
BINDING = os.path.join(ROOT, "bindings", "python3")
sys.path.insert(0, BINDING)

import citron  # noqa: E402

PERL = os.environ.get("CITRON_PERL") or shutil.which("perl")


def b(text):
    return text.encode("utf-8") if isinstance(text, str) else text


# Values chosen to hit every branch of JSON::PP's decoding and re-encoding.
SAMPLES = [
    # plain strings
    "hello world", "", " ", "x", "café", "日本語", "😀", "tab\there", "new\nline",
    "\x7f", "a\x01b", "back\\slash", 'qu"ote', "42abc", "007", "+1", ".5", "1.", "-",
    "--1", "1e", "1e+", "0x10", "NaN", "Infinity", "True", "nul", "nulll",
    b"\xff\xfe raw bytes", b"caf\xe9", b"\xc3\x28", b"\xed\xa0\x80",
    # JSON scalars
    "true", "false", "null", " null ", "\t42\n", '"42"', '"02139"', '""',
    '"\\u00e9"', '"\\ud83d\\ude00"', '"\\ud83d"', '"\\ude00"', '"\\u0000x"', '"\\/"',
    '"\\b\\f\\n\\r\\t"', '"\\u001f\\u007f"', '"\\x"', '"unterminated', '"a\tb"',
    # numbers
    "0", "-0", "1", "-1", "42", "1.50", "1.0", "0.0", "-0.0", "0.1", "1e3", "1E3",
    "1e+3", "1e-5", "1e-7", "1e14", "1e15", "1e16", "1.5e15", "1.5e300", "1e100",
    "123.456e2", "0.1e1", "1e0", "-1.5", "3.14159", "0.000001", "5e-324",
    "1.7976931348623157e308", "1e400", "-1e400",
    "123456789012345678", "9223372036854775807", "9223372036854775808",
    "-9223372036854775808", "-9223372036854775809", "18446744073709551615",
    "18446744073709551616", "12345678901234567890", "99999999999999999999",
    "123456789012345678901", "-1234567890123456789", "-12345678901234567890",
    "1.23456789012345678", "9007199254740991.0", "9007199254740992.0",
    "9007199254740993e0", "-9007199254740992.0", "1.8e19", "-9.2e18",
    "9.3e18", "1.8446744073709551616e19", "-9223372036854775808e0",
    "100000000000000000000.0", "12345678901234567890.5", "-1e18", "1e19",
    # containers
    "[]", "{}", "[1,2,3]", "[ 1 , 2 ]", '{"b":1,"a":2}', '{"a":1,"a":2}',
    '{"x":[1,2,{}],"y":[],"z":{"q":null}}', '{"é":1,"e":2,"f":3}',
    '{"user":{"name":"Ada","tags":["math","code"]}}', "[1,]", "{,}", '{"a"}',
    '{"a":}', "[1 2]", "[[[[[]]]]]", "[1.50, 1e3, -0]", '{"n":123456789012345678901}',
    '{"name":"Ada","age":36,"tags":["math","code"],"address":{"city":"London"}}',
    "[" * 600 + "]" * 600, "[" * 400 + "]" * 400, "[1] x", "{} {}",
]

PATHS = ["", "a", "name", "tags", "tags.0", "tags.1", "tags.-1", "tags.-2",
         "tags.-3", "tags.2", "tags.01", "tags.x", "address.city", "address.",
         "address..city", ".", "..", "user.tags.1", "x.2", "x.2.y", "0", "é", "n"]

TOKENS = ["{", "}", "[", "]", ",", ":", '"a"', '"b"', '"é"', "1", "-0", "1.50",
          "1e3", "2E-2", "true", "false", "null", " ", "\n", '"\\u00e9"',
          '"\\ud83d\\ude00"', "x", "é", "123456789012345678901", "0.1", "-"]


def random_json(rng, depth=0):
    kind = rng.randrange(8 if depth < 4 else 5)
    if kind == 0:
        return rng.choice([True, False, None])
    if kind == 1:
        return rng.choice([0, -1, 7, 2 ** 53, 2 ** 63, 2 ** 64, -(2 ** 63) - 1, 10 ** 21])
    if kind == 2:
        return rng.choice([0.5, 1.25, -3.75, 1e-9, 1e300, 123456.789, 0.1 + 0.2])
    if kind in (3, 4):
        return "".join(rng.choice("ab é\n\"\\\x01😀/") for _ in range(rng.randrange(6)))
    if kind == 5:
        return [random_json(rng, depth + 1) for _ in range(rng.randrange(4))]
    return {rng.choice(["a", "b", "é", "", "k"]): random_json(rng, depth + 1)
            for _ in range(rng.randrange(4))}


def random_text(rng):
    if rng.random() < 0.5:
        text = json.dumps(random_json(rng), ensure_ascii=rng.random() < 0.5,
                          indent=rng.choice([None, None, 2]))
        # number spellings Python never produces
        if rng.random() < 0.3:
            text = text.replace("0.5", rng.choice(["0.50", "5e-1", "5.0E-1"]))
        return text
    return "".join(rng.choice(TOKENS) for _ in range(rng.randrange(1, 10)))


def run_perl(db, ops, workdir):
    ops_file = os.path.join(workdir, "ops.txt")
    with open(ops_file, "w", newline="\n") as f:
        for op in ops:
            f.write("\t".join(b(x).hex() for x in op) + "\n")
    result = subprocess.run(
        [PERL, os.path.join("test", "python3", "perl_ref.perl"), db, ops_file],
        cwd=ROOT, capture_output=True, check=True)
    return [line.strip().decode() for line in result.stdout.splitlines()]


def run_binding(db, ops):
    def s(x):
        return b(x).decode("utf-8", "surrogateescape")

    out = []
    with citron.open(db) as handle:
        for op, *args in ops:
            try:
                if op == "set":
                    handle.set_raw(s(args[0]), s(args[1]))
                    continue
                if op == "get":
                    text = handle.get_text(s(args[0]), s(args[1]))
                    out.append("-" if text is None else text.encode("utf-8", "surrogateescape").hex())
                elif op == "update":
                    out.append(str(int(handle.update_raw(s(args[0]), s(args[1])))))
                elif op == "delete":
                    out.append(str(int(handle.delete(s(args[0])))))
                elif op == "exists":
                    out.append(str(int(handle.exists(s(args[0])))))
                elif op == "export":
                    out.append(str(handle.export_json(s(args[0]))))
                elif op == "import":
                    out.append(str(handle.import_json(s(args[0]))))
                elif op == "snapshot":
                    name = handle.snapshot(s(args[0]) if b(args[0]) else None)
                    out.append(name.encode().hex())
                elif op == "snapshots":
                    out.append(",".join(handle.snapshots()).encode().hex())
                elif op == "rollback":
                    out.append(str(int(handle.rollback(s(args[0])))))
                elif op == "dropsnapshot":
                    out.append(str(int(handle.drop_snapshot(s(args[0])))))
            except citron.CitronError:
                out.append("!")
    return out


def snapshot_files(db):
    """{file name: bytes} of a database's snapshot folder."""
    folder = db + ".snapshots"
    if not os.path.isdir(folder):
        return {}
    return {name: read(os.path.join(folder, name)) for name in sorted(os.listdir(folder))}


def read(path):
    with open(path, "rb") as f:
        return f.read()


@unittest.skipUnless(PERL, "perl not found (set CITRON_PERL)")
class InteropTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def compare(self, ops):
        """Runs ops through both implementations and compares everything."""
        perl_db = os.path.join(self.dir, "perl.citron")
        c_db = os.path.join(self.dir, "c.citron")
        perl_out = run_perl(perl_db, [self.rename(op, "perl") for op in ops], self.dir)
        c_out = run_binding(c_db, [self.rename(op, "c") for op in ops])

        returning = [op for op in ops if op[0] != "set"]
        for op, p, c in zip(returning, perl_out, c_out):
            self.assertEqual(c, p, "%r: perl %r, c %r" % (op, p, c))
        self.assertEqual(len(c_out), len(perl_out))
        self.assertEqual(read(c_db), read(perl_db), "database files differ")
        self.assertEqual(snapshot_files(c_db), snapshot_files(perl_db), "snapshot folders differ")
        for name in os.listdir(self.dir):
            if name.startswith("perl-"):
                self.assertEqual(read(os.path.join(self.dir, "c-" + name[5:])),
                                 read(os.path.join(self.dir, name)), name + " differs")

    def rename(self, op, side):
        """Export/import files get a per-implementation name."""
        if op[0] in ("export", "import") and not op[1].startswith("shared-"):
            return (op[0], os.path.join(self.dir, side + "-" + op[1]))
        if op[0] in ("export", "import"):
            return (op[0], os.path.join(self.dir, op[1]))
        return op

    def test_samples_are_stored_identically(self):
        ops = []
        for i, value in enumerate(SAMPLES):
            ops.append(("set", "k%03d" % i, value))
            ops.append(("get", "k%03d" % i, ""))
        self.compare(ops)

    def test_get_with_paths(self):
        ops = [("set", "a", '{"name":"Ada","tags":["math","code"],"address":{"city":"London"},'
                             '"x":[0,1,{"y":[true]}],"é":"accent","n":null}'),
               ("set", "s", "plain"), ("set", "arr", '["math","code",[1,2]]'),
               ("set", "user", '{"user":{"tags":["a","b"]}}')]
        for key in ("a", "s", "arr", "user", "missing"):
            for path in PATHS:
                ops.append(("get", key, path))
        self.compare(ops)

    def test_update_delete_exists(self):
        self.compare([
            ("update", "ghost", "1"), ("exists", "ghost"), ("set", "k", "1"),
            ("update", "k", "1.50"), ("get", "k", ""), ("exists", "k"),
            ("delete", "k"), ("delete", "k"), ("exists", "k"), ("set", "", "empty key"),
            ("get", "", ""), ("set", "café", "x"), ("set", b"\xff", "raw key"),
            ("get", b"\xff", ""), ("set", "user:1", "null"), ("get", "user:1", ""),
        ])

    def test_export_and_import(self):
        source = os.path.join(self.dir, "shared-in.json")
        with open(source, "w", encoding="utf-8") as f:
            f.write('{"a":{"b":[1,2,{}],"c":[]},"é":"accent","n":1.50,"m":1e3,'
                    '"big":123456789012345678901,"dup":1,"dup":2}')
        bad = os.path.join(self.dir, "shared-bad.json")
        with open(bad, "w") as f:
            f.write("[1,2]")
        self.compare([
            ("export", "empty.json"),
            ("import", "shared-in.json"), ("import", "shared-bad.json"),
            ("import", "shared-missing.json"),
            ("set", "s", "hello"), ("set", "café", '"\\u00e9t\\u00e9"'),
            ("set", "deep", '{"x":{"y":{"z":[[],{},[1,[2]]]}}}'),
            ("export", "out.json"),
            ("get", "a", "b.2"), ("get", "big", ""), ("get", "dup", ""),
        ])

    def test_random_inputs(self):
        rng = random.Random(666)
        ops = []
        for i in range(600):
            key = "r%d" % rng.randrange(400)
            choice = rng.random()
            if choice < 0.7:
                ops.append(("set", key, random_text(rng)))
            elif choice < 0.8:
                ops.append(("update", key, random_text(rng)))
            elif choice < 0.85:
                ops.append(("delete", key))
            else:
                ops.append(("get", key, rng.choice(["", "a", "0", "b.0", "-1", "é", "k.a"])))
        ops.append(("export", "random.json"))
        self.compare(ops)

    def test_reads_files_written_by_perl(self):
        db = os.path.join(self.dir, "perl.citron")
        run_perl(db, [("set", "user:1", '{"name":"Ada","tags":["math"]}'),
                      ("set", "n", "1.50"), ("set", "s", "hello")], self.dir)
        with citron.open(db) as handle:
            self.assertEqual(handle.get("user:1", "tags.0"), "math")
            self.assertEqual(handle.list(), {"n": "1.5", "s": "hello",
                                             "user:1": '{"name":"Ada","tags":["math"]}'})
            handle.set("added", [1, 2])
        out = run_perl(db, [("get", "added", ""), ("get", "user:1", "name")], self.dir)
        self.assertEqual(out, [b"[1,2]".hex(), b"Ada".hex()])

    def test_concurrent_writers_with_perl(self):
        """Perl and C processes writing one file at once must not lose writes
        (both lock <db>.lock the same way)."""
        db = os.path.join(self.dir, "shared.citron")
        writes = 25
        procs = []
        for p in range(2):
            ops_file = os.path.join(self.dir, "ops%d.txt" % p)
            with open(ops_file, "w", newline="\n") as f:
                for i in range(writes):
                    f.write("%s\t%s\t%s\n" % (b"set".hex(), b("perl%d:%d" % (p, i)).hex(), b"1".hex()))
            procs.append(subprocess.Popen(
                [PERL, os.path.join("test", "python3", "perl_ref.perl"), db, ops_file],
                cwd=ROOT))
        for p in range(2):
            procs.append(subprocess.Popen([sys.executable, "-c", (
                "import sys; sys.path.insert(0, %r); import citron\n"
                "with citron.open(%r) as db:\n"
                "    for i in range(%d): db.set('c%d:%%d' %% i, i)\n"
            ) % (BINDING, db, writes, p)]))
        for proc in procs:
            self.assertEqual(proc.wait(), 0)

        with citron.open(db) as handle:
            self.assertEqual(len(handle), 4 * writes)

    def test_unchanged_write_is_skipped(self):
        """Setting a key to the value it already holds doesn't rewrite the
        file (so a version 1 file stays version 1)."""
        db = os.path.join(self.dir, "v1.citron")
        data = (b"CITRON" + (1).to_bytes(4, "big") + (1).to_bytes(4, "big")
                + (1).to_bytes(4, "big") + b"k" + (5).to_bytes(4, "big") + b"hello")
        for path in (db, os.path.join(self.dir, "v1-perl.citron")):
            with open(path, "wb") as f:
                f.write(data)

        ops = [("set", "k", "hello"), ("update", "k", '"hello"')]
        perl_out = run_perl(os.path.join(self.dir, "v1-perl.citron"), ops, self.dir)
        self.assertEqual(run_binding(db, ops), perl_out)
        self.assertEqual(read(db), data)
        self.assertEqual(read(os.path.join(self.dir, "v1-perl.citron")), data)

    def test_snapshots(self):
        self.compare([
            ("snapshots",), ("set", "a", "1"), ("snapshot", ""), ("set", "a", "2"),
            ("snapshot", "beforeMigration"), ("snapshot", ""), ("snapshot", "beforeMigration"),
            ("snapshot", "42"), ("snapshot", "a-b"), ("snapshot", "../x"), ("snapshots",),
            ("set", "b", '{"x":[1,2]}'), ("rollback", "1"), ("get", "a", ""), ("get", "b", ""),
            ("rollback", "beforeMigration"), ("get", "a", ""), ("rollback", "nope"),
            ("rollback", "../x"), ("dropsnapshot", "2"), ("dropsnapshot", "2"),
            ("dropsnapshot", "../x"), ("snapshot", ""), ("snapshots",),
        ])

    def test_snapshots_are_shared_with_perl(self):
        """Snapshots one implementation makes, the other lists and restores,
        and numbering carries on across both."""
        db = os.path.join(self.dir, "shared.citron")
        out = run_perl(db, [("set", "who", "perl"), ("snapshot", ""), ("snapshot", "fromPerl")], self.dir)
        self.assertEqual(out, [b"1".hex(), b"fromPerl".hex()])

        with citron.open(db) as handle:
            self.assertEqual(handle.snapshots(), ["1", "fromPerl"])
            handle["who"] = "c"
            self.assertEqual(handle.snapshot(), "2")
            self.assertEqual(handle.snapshot("fromC"), "fromC")
            self.assertTrue(handle.rollback("fromPerl"))
            self.assertEqual(handle["who"], "perl")

        out = run_perl(db, [("snapshots",), ("rollback", "fromC"), ("get", "who", ""), ("snapshot", "")],
                       self.dir)
        self.assertEqual(out, [b"1,2,fromC,fromPerl".hex(), "1", b"c".hex(), b"3".hex()])

    def test_concurrent_snapshots_with_perl(self):
        """Perl and C processes snapshotting at once never share a number."""
        db = os.path.join(self.dir, "race.citron")
        run_perl(db, [("set", "k", "v")], self.dir)
        ops_file = os.path.join(self.dir, "snap_ops.txt")
        with open(ops_file, "w", newline="\n") as f:
            f.write((b"snapshot".hex() + "\t" + "\n") * 10)
        procs = [subprocess.Popen([PERL, os.path.join("test", "python3", "perl_ref.perl"), db, ops_file],
                                  cwd=ROOT, stdout=subprocess.PIPE) for _ in range(2)]
        procs += [subprocess.Popen([sys.executable, "-c", (
            "import sys; sys.path.insert(0, %r); import citron\n"
            "with citron.open(%r) as db:\n"
            "    for _ in range(10): print(db.snapshot().encode().hex())\n"
        ) % (BINDING, db)], stdout=subprocess.PIPE) for _ in range(2)]

        names = []
        for proc in procs:
            stdout, _ = proc.communicate()
            self.assertEqual(proc.returncode, 0)
            names += [bytes.fromhex(line.decode().strip()).decode() for line in stdout.splitlines()]
        self.assertEqual(sorted(names, key=int), [str(i) for i in range(1, 41)])

    def test_reads_version_1_files(self):
        db = os.path.join(self.dir, "v1.citron")
        records = [(b"greeting", b"hello"), (b"num", b"42"), (b"bytes", b"caf\xe9")]
        data = b"CITRON" + (1).to_bytes(4, "big") + len(records).to_bytes(4, "big")
        for key, value in records:
            data += len(key).to_bytes(4, "big") + key + len(value).to_bytes(4, "big") + value
        with open(db, "wb") as f:
            f.write(data)
        perl_copy = os.path.join(self.dir, "v1-perl.citron")
        shutil.copy(db, perl_copy)

        ops = [("get", "num", ""), ("get", "bytes", ""), ("set", "x", "1")]
        perl_out = run_perl(perl_copy, ops, self.dir)
        c_out = run_binding(db, ops)
        self.assertEqual(c_out, perl_out)
        self.assertEqual(read(db), read(perl_copy), "upgrade to v2 differs")


if __name__ == "__main__":
    unittest.main()
