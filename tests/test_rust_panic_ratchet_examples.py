#!/usr/bin/env python3
"""The Rust panic ratchet never counts an example target's hits.

cmux-tui-clippy-changed.py asks its ratchet run for `--examples` so cargo resolves features with the
dev-dependencies, as the clippy run's `--all-targets` does, and the ratchet run then finds the clippy run's lib and
bin units fresh. Example code is not production code, so its messages must not reach the counts; the lib and bin
messages of the same run still do.
"""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load():
    spec = importlib.util.spec_from_file_location("rust_panic_ratchet_examples",
                                                  ROOT / "scripts/cmux-next/rust_panic_ratchet.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def item(reason, kind, file_name="", line=1):
    entry = {"reason": reason, "package_id": "path+file:///w/cmux-tui/crates/alpha#alpha@0.1.0",
             "target": {"kind": [kind]}}
    if reason == "compiler-message":
        entry["message"] = {"code": {"code": "clippy::unwrap_used"},
                            "spans": [{"is_primary": True, "file_name": file_name, "line_start": line,
                                       "column_start": 1}]}
    return entry


class ExampleTargets(unittest.TestCase):
    def test_example_hits_are_skipped_and_lib_hits_counted(self):
        ratchet = load()
        items = [item("compiler-message", "lib", "crates/alpha/src/lib.rs", 3),
                 item("compiler-artifact", "lib"),
                 item("compiler-message", "example", "crates/alpha/examples/demo.rs", 5),
                 item("compiler-artifact", "example"),
                 {"reason": "build-finished", "success": True}]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "clippy.jsonl"
            path.write_text("\n".join(json.dumps(i) for i in items))
            checked, counts, files, finished, hits = ratchet.read_clippy(str(path))
        self.assertTrue(finished)
        self.assertEqual(checked, {"alpha"})
        self.assertEqual(counts["alpha"]["unwrap_used"], 1)
        self.assertEqual(hits[("alpha", "unwrap_used")], ["crates/alpha/src/lib.rs:3:1"])
        self.assertNotIn("crates/alpha/examples/demo.rs", files["alpha"])


if __name__ == "__main__":
    unittest.main()
