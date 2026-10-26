#!/usr/bin/env python3
"""rust_panic_ratchet.py merging a Linux and a macOS clippy run (Q10), and rust-panic-macos.sh's guards.

Two runs merge by workspace file:line:column: a line both runs see counts once, a macOS-only line is
added and listed in the "only the macos run" table, an absolute path from another checkout names the
same file, two runs with one label or a merged --update-baseline are refused, and one unfinished run
fails the merge. One run gives the same report and exit code as before (the CI step is unchanged).

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the ratchet:
  python3 -I scripts/cmux-next/tests/test_rust_panic_merge.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]


def load_ratchet():
    spec = importlib.util.spec_from_file_location("rust_panic_ratchet", SCRIPTS / "rust_panic_ratchet.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def artifact(crate, kind="lib"):
    return {"reason": "compiler-artifact", "package_id": f"path+file:///w/cmux-tui/crates/{crate}#0.1.0",
            "target": {"kind": [kind]}}


def hit(crate, file_name, line, lint="unwrap_used", column=5):
    return {"reason": "compiler-message", "package_id": f"path+file:///w/cmux-tui/crates/{crate}#0.1.0",
            "target": {"kind": ["lib"]},
            "message": {"code": {"code": f"clippy::{lint}"},
                        "spans": [{"is_primary": True, "file_name": file_name, "line_start": line,
                                   "column_start": column}]}}


def finished(success=True):
    return {"reason": "build-finished", "success": success}


class MergeTests(unittest.TestCase):
    def setUp(self):
        self.ratchet = load_ratchet()
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.baseline = self.dir / "baseline.json"
        self.baseline.write_text(json.dumps({"crates": {
            "cmux-pty": {lint: 0 for lint in self.ratchet.LINTS} | {"unwrap_used": 2},
        }}))
        self.ratchet.BASELINE = str(self.baseline)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, items):
        path = self.dir / name
        path.write_text("".join(json.dumps(item) + "\n" for item in items))
        return str(path)

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        old = sys.argv
        sys.argv = ["rust_panic_ratchet.py", "--repo", str(self.dir), *argv]
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    rc = self.ratchet.main()
                except SystemExit as exit_:
                    rc = exit_.code
        finally:
            sys.argv = old
        return rc, out.getvalue(), err.getvalue()

    def linux_mac(self):
        linux = self.write("linux.jsonl", [
            artifact("cmux-pty"),
            hit("cmux-pty", "crates/cmux-pty/src/lib.rs", 10),
            hit("cmux-pty", "crates/cmux-pty/src/linux.rs", 4),
            finished(),
        ])
        mac = self.write("mac.jsonl", [
            artifact("cmux-pty"),
            hit("cmux-pty", "crates/cmux-pty/src/lib.rs", 10),
            hit("cmux-pty", "/Users/fleet/w/cmux-tui/crates/cmux-pty/src/macos.rs", 7, lint="indexing_slicing"),
            finished(),
        ])
        return linux, mac

    def test_merge_dedupes_shared_lines_and_lists_macos_only_hits(self):
        linux, mac = self.linux_mac()
        rc, out, err = self.run_main("--clippy-json", f"linux={linux}", "--clippy-json", f"macos={mac}",
                                     "--report", "md")
        self.assertEqual(rc, 1, err)  # the macOS-only indexing hit is above the Linux baseline
        self.assertIn("| cmux-pty | 2 | 0 | 0 | 0 | 0 | 0 | 1 |", out)
        macos_table = out.split("### Hits only the macos run saw (1)")[1].split("###")[0]
        self.assertIn("| cmux-pty | index | crates/cmux-pty/src/macos.rs:7:5 |", macos_table)
        self.assertNotIn("lib.rs", macos_table)
        linux_table = out.split("### Hits only the linux run saw (1)")[1]
        self.assertIn("crates/cmux-pty/src/linux.rs:4:5", linux_table)
        self.assertIn("3 distinct", err)

    def test_merged_json_report_names_only_in_hits(self):
        linux, mac = self.linux_mac()
        _, out, _ = self.run_main("--clippy-json", f"linux={linux}", "--clippy-json", f"macos={mac}",
                                  "--report", "json")
        row = json.loads(out)["cmux-pty"]
        self.assertEqual(row["counts"], {"unwrap_used": 2, "indexing_slicing": 1})
        self.assertEqual(row["only_in"]["macos"], [{"loc": "crates/cmux-pty/src/macos.rs:7:5",
                                                    "lint": "indexing_slicing"}])

    def test_label_defaults_to_file_stem_and_duplicates_are_refused(self):
        linux, mac = self.linux_mac()
        rc, out, _ = self.run_main("--clippy-json", linux, "--clippy-json", mac, "--report", "md")
        self.assertEqual(rc, 1)
        self.assertIn("### Hits only the mac run saw (1)", out)
        rc, _, err = self.run_main("--clippy-json", f"x={linux}", "--clippy-json", f"x={mac}")
        self.assertEqual(rc, 2)
        self.assertIn("labelled 'x'", err)

    def test_merged_run_never_writes_the_baseline(self):
        linux, mac = self.linux_mac()
        before = self.baseline.read_text()
        rc, _, err = self.run_main("--clippy-json", linux, "--clippy-json", mac, "--update-baseline")
        self.assertEqual(rc, 2)
        self.assertIn("take one --clippy-json run", err)
        self.assertEqual(self.baseline.read_text(), before)

    def test_one_unfinished_run_fails_the_merge(self):
        linux, _ = self.linux_mac()
        mac = self.write("mac.jsonl", [artifact("cmux-pty"), finished(success=False)])
        rc, _, err = self.run_main("--clippy-json", linux, "--clippy-json", f"macos={mac}")
        self.assertEqual(rc, 2)
        self.assertIn("the macos clippy run did not finish", err)

    def test_single_run_is_unchanged(self):
        linux, _ = self.linux_mac()
        rc, out, err = self.run_main("--clippy-json", linux, "--report", "md")
        self.assertEqual(rc, 0, err)
        self.assertNotIn("###", out)
        self.assertNotIn("merged", err)
        checked, counts, files, done, hits = self.ratchet.read_clippy(linux)
        self.assertEqual(checked, {"cmux-pty"})
        self.assertTrue(done)
        self.assertEqual(counts["cmux-pty"]["unwrap_used"], 2)
        self.assertEqual(sorted(hits[("cmux-pty", "unwrap_used")]),
                         ["crates/cmux-pty/src/lib.rs:10:5", "crates/cmux-pty/src/linux.rs:4:5"])
        self.assertEqual(files["cmux-pty"]["crates/cmux-pty/src/lib.rs"], 1)

    def test_lib_and_bin_view_of_one_line_counts_once(self):
        path = self.write("one.jsonl", [
            artifact("cmux-pty"), artifact("cmux-pty", "bin"),
            hit("cmux-pty", "crates/cmux-pty/src/lib.rs", 10),
            hit("cmux-pty", "crates/cmux-pty/src/lib.rs", 10),
            finished(),
        ])
        _, counts, _, _, _ = self.ratchet.read_clippy(path)
        self.assertEqual(counts["cmux-pty"]["unwrap_used"], 1)


class MacosStepGuardTests(unittest.TestCase):
    SCRIPT = SCRIPTS / "rust-panic-macos.sh"

    def run_script(self, env):
        return subprocess.run(["bash", str(self.SCRIPT)], env=env, capture_output=True, text=True, timeout=30,
                              cwd=tempfile.gettempdir())

    def test_refuses_outside_a_fleet_step(self):
        env = {k: v for k, v in os.environ.items() if k != "CMUX_CI_STEP_KEY"}
        result = self.run_script(env)
        self.assertEqual(result.returncode, 2)
        self.assertIn("runs only as a fleet step", result.stderr)

    @unittest.skipIf(sys.platform == "darwin", "the Linux refusal")
    def test_refuses_on_linux(self):
        result = self.run_script(dict(os.environ, CMUX_CI_STEP_KEY="probe"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("is the macOS run", result.stderr)


if __name__ == "__main__":
    unittest.main()
