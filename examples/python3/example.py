"""CitronDB 🍋 from Python 3.

    make -C bindings/c                  # build the C library once
    python examples/python3/example.py  # from the project root
"""

import os
import sys

# use the binding straight from the source tree
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "bindings", "python3"))

import citron  # noqa: E402

with citron.open("example.citron") as db:
    # Python values are stored as JSON
    db.set("user:1", {"name": "Ada", "age": 36, "tags": ["math", "code"]})
    db["user:2"] = {"name": "Grace", "age": 85, "tags": ["navy", "cobol"]}
    db["visits"] = 0

    # set_raw follows the CLI rule: JSON if it parses, otherwise a plain string
    db.set_raw("greeting", "hello world")

    # read whole values, or drill in with a path
    user = db["user:1"]
    print("user:1 is %s, %d" % (user["name"], user["age"]))
    print("first tag of user:2:", db.get("user:2", "tags.0"))
    print("last tag of user:2: ", db.get("user:2", "tags.-1"))
    print("missing with default:", db.get("nope", default="(nil)"))

    # update only touches existing keys
    db.update("visits", db["visits"] + 1)
    print("visits:", db["visits"])
    print("update on a missing key:", db.update("ghost", 1))

    # a missing key and a stored null are different
    db["nothing"] = None
    print("nothing:", db.lookup("nothing"), "ghost:", db.lookup("ghost"))
    del db["nothing"]

    print("\nall records:")
    for key, text in db.list().items():
        print("%s: %s" % (key, text))

    print("\nexported %d records to example.json" % db.export_json("example.json"))
