"""Tests for the Python binding's API.

    python -m unittest discover test/python3
"""

import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "bindings", "python3"))

import citron  # noqa: E402


class CitronTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "test.citron")
        self.db = citron.open(self.path)

    def tearDown(self):
        self.db.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_open_creates_the_file(self):
        self.assertTrue(os.path.exists(self.path))
        with open(self.path, "rb") as f:
            self.assertEqual(f.read(), b"CITRON\0\0\0\x02\0\0\0\0")

    def test_open_removes_stale_temp_file(self):
        with open(self.path + ".tmp", "wb") as f:
            f.write(b"half-written")
        citron.open(self.path).close()
        self.assertFalse(os.path.exists(self.path + ".tmp"))

    def test_set_get_python_values(self):
        value = {"name": "Ada", "age": 36, "tags": ["math", "code"], "ok": True, "x": None}
        self.db.set("user:1", value)
        self.assertEqual(self.db.get("user:1"), value)
        self.db.set("s", "42")
        self.assertEqual(self.db.get("s"), "42", "Python strings stay strings")
        self.db.set("f", 1.5)
        self.assertEqual(self.db.get("f"), 1.5)

    def test_set_raw_follows_cli_rules(self):
        self.db.set_raw("n", "42")
        self.db.set_raw("s", "hello world")
        self.db.set_raw("q", '"02139"')
        self.db.set_raw("broken", '{"half":')
        self.assertEqual(self.db.get("n"), 42)
        self.assertEqual(self.db.get("s"), "hello world")
        self.assertEqual(self.db.get("q"), "02139")
        self.assertEqual(self.db.get("broken"), '{"half":')

    def test_paths(self):
        self.db.set("u", {"address": {"city": "London"}, "tags": ["a", "b"]})
        self.assertEqual(self.db.get("u", "address.city"), "London")
        self.assertEqual(self.db.get("u", "tags.0"), "a")
        self.assertEqual(self.db.get("u", "tags.-1"), "b")
        self.assertIsNone(self.db.get("u", "tags.5"))
        self.assertEqual(self.db.get("u", "nope", default="d"), "d")

    def test_missing_vs_null(self):
        self.db.set("nothing", None)
        self.assertEqual(self.db.lookup("nothing"), (True, None))
        self.assertEqual(self.db.lookup("ghost"), (False, None))
        self.assertTrue(self.db.exists("nothing"))
        self.assertFalse(self.db.exists("ghost"))

    def test_update_and_delete(self):
        self.assertFalse(self.db.update("ghost", 1))
        self.assertFalse(self.db.exists("ghost"))
        self.db.set("k", 1)
        self.assertTrue(self.db.update("k", 2))
        self.assertEqual(self.db.get("k"), 2)
        self.assertTrue(self.db.delete("k"))
        self.assertFalse(self.db.delete("k"))

    def test_get_text(self):
        self.db.set("s", "plain")
        self.db.set("o", {"b": 1, "a": [1.5]})
        self.assertEqual(self.db.get_text("s"), "plain")
        self.assertEqual(self.db.get_text("o"), '{"a":[1.5],"b":1}')
        self.assertIsNone(self.db.get_text("ghost"))

    def test_dict_interface(self):
        self.db["a"] = 1
        self.db["b"] = [2]
        self.assertEqual(self.db["a"], 1)
        self.assertIn("a", self.db)
        self.assertEqual(len(self.db), 2)
        self.assertEqual(list(self.db), ["a", "b"])
        self.assertEqual(dict(self.db.items()), {"a": 1, "b": [2]})
        del self.db["a"]
        with self.assertRaises(KeyError):
            self.db["a"]
        with self.assertRaises(KeyError):
            del self.db["a"]

    def test_list_and_list_values(self):
        self.db.set("s", "hi")
        self.db.set("o", {"x": 1})
        self.db.set_raw("f", "1.5e+15")
        self.assertEqual(self.db.list(), {"s": "hi", "o": '{"x":1}', "f": "1.5e+15"})
        self.assertEqual(self.db.list_values(), {"s": "hi", "o": {"x": 1}, "f": 1.5e15})

    def test_unicode_keys_and_values(self):
        self.db.set("café", "été 😀")
        self.assertEqual(self.db.get("café"), "été 😀")
        self.assertEqual(self.db.keys(), ["café"])

    def test_import_and_export(self):
        self.assertEqual(self.db.import_dict({"a": 1, "b": {"c": []}}), 2)
        out = os.path.join(self.dir, "out.json")
        self.assertEqual(self.db.export_json(out), 2)
        with open(out, encoding="utf-8") as f:
            self.assertEqual(json.load(f), {"a": 1, "b": {"c": []}})

        other = citron.open(os.path.join(self.dir, "other.citron"))
        self.assertEqual(other.import_json(out), 2)
        self.assertEqual(other.get("b", "c"), [])
        other.close()

    def test_import_rejects_non_objects(self):
        bad = os.path.join(self.dir, "bad.json")
        with open(bad, "w") as f:
            f.write("[1, 2]")
        with self.assertRaises(citron.CitronError) as cm:
            self.db.import_json(bad)
        self.assertIn("must contain a JSON object", str(cm.exception))
        with self.assertRaises(TypeError):
            self.db.import_dict([1])

    def test_rejects_values_json_cannot_represent(self):
        with self.assertRaises(ValueError):
            self.db.set("nan", float("nan"))
        with self.assertRaises(TypeError):
            self.db.set("obj", object())

    def test_corrupt_files_are_refused(self):
        bad = os.path.join(self.dir, "bad.citron")
        with open(bad, "wb") as f:
            f.write(b"NOT A DB AT ALL")
        with self.assertRaises(citron.CitronError) as cm:
            citron.open(bad)
        self.assertEqual(cm.exception.code, -2)
        with open(bad, "rb") as f:
            self.assertEqual(f.read(), b"NOT A DB AT ALL", "corrupt file left untouched")

    def test_truncated_and_trailing_bytes(self):
        self.db.set("k", "value")
        with open(self.path, "rb") as f:
            good = f.read()
        for data, message in ((good[:-2], "truncated"), (good + b"xx", "trailing")):
            with open(self.path, "wb") as f:
                f.write(data)
            with self.assertRaises(citron.CitronError) as cm:
                self.db.get("k")
            self.assertIn(message, str(cm.exception))

    def test_newer_version_is_refused(self):
        with open(self.path, "wb") as f:
            f.write(b"CITRON\0\0\0\x09\0\0\0\0")
        with self.assertRaises(citron.CitronError) as cm:
            self.db.keys()
        self.assertEqual(cm.exception.code, -3)

    def test_closed_handle(self):
        self.db.close()
        with self.assertRaises(citron.CitronError):
            self.db.get("k")
        self.db.close()  # closing twice is fine

    def test_context_manager(self):
        with citron.open(self.path) as db:
            db.set("k", 1)
        self.assertEqual(self.db.get("k"), 1)

    def test_version(self):
        self.assertEqual(citron.version(), "0.5.1")


if __name__ == "__main__":
    unittest.main()
