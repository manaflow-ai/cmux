#!/usr/bin/env python3
"""Report-only lints of the Rust panic ratchet (scripts/cmux-next/rust_panic_ratchet.py, task p10-stability-114).

CI runs `--flags` and the compare mode; the lab adds `--report-flags` and `--tracked-report`. These tests
pin that CI sees nothing of the report tier: `--flags` prints the same lints as before, the compare mode
gives the same result and output for a lab run (report-only hits included) as for a CI run, and it never
opens rust-panic-report-baseline.json. The tracked report counts the report-only lints and the
`reason = "INVARIANT: ..."` allowances per crate, skips build-script output, exits 0 and writes its own
baseline only when asked.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the ratchet:
  python3 -I scripts/cmux-next/tests/test_rust_panic_ratchet_report.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
CI_FLAGS = (
    "-W clippy::unwrap_used -W clippy::expect_used -W clippy::panic -W clippy::unreachable -W clippy::todo "
    "-W clippy::unimplemented -W clippy::indexing_slicing -W clippy::string_slice -W clippy::panic_in_result_fn "
    "-W clippy::arithmetic_side_effects -W clippy::cast_possible_truncation"
)


def load_ratchet():
    spec = importlib.util.spec_from_file_location("rust_panic_ratchet", SCRIPTS / "rust_panic_ratchet.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def artifact(crate):
    return {"reason": "compiler-artifact", "package_id": f"path+file:///w/cmux-tui/crates/{crate}#0.1.0",
            "target": {"kind": ["lib"]}}


def message(crate, lint, file_name, line):
    return {"reason": "compiler-message", "package_id": f"path+file:///w/cmux-tui/crates/{crate}#0.1.0",
            "target": {"kind": ["lib"]},
            "message": {"code": {"code": f"clippy::{lint}"}, "level": "warning", "message": lint,
                        "spans": [{"is_primary": True, "file_name": file_name, "line_start": line,
                                   "column_start": 5}]}}


FINISHED = {"reason": "build-finished", "success": True}


class ReportTierTest(unittest.TestCase):
    def setUp(self):
        self.ratchet = load_ratchet()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        src = self.root / "cmux-tui" / "crates" / "alpha" / "src"
        src.mkdir(parents=True)
        (src / "lib.rs").write_text(
            '#[allow(clippy::expect_used, reason = "INVARIANT: the table is built with every key")]\n'
            "fn a() {}\n"
            '#[allow(clippy::unwrap_used, reason = r#"INVARIANT: checked above"#)]\n'
            "fn b() {}\n"
            '#[allow(clippy::unwrap_used, reason = "the parser rejected empty input")]\n'
            "fn c() {}\n"
            '#[allow(clippy::arithmetic_side_effects, reason = "INVARIANT: not a deny lint")]\n'
            "fn d() {}\n"
        )
        tests_dir = self.root / "cmux-tui" / "crates" / "alpha" / "tests"
        tests_dir.mkdir()
        (tests_dir / "t.rs").write_text('#[allow(clippy::unwrap_used, reason = "INVARIANT: test only")]\nfn t() {}\n')
        (self.root / "cmux-tui" / "crates" / "beta" / "src").mkdir(parents=True)
        (self.root / "cmux-tui" / "crates" / "beta" / "src" / "lib.rs").write_text("fn e() {}\n")
        self.baseline = self.root / "rust-panic-baseline.json"
        self.report_baseline = self.root / "rust-panic-report-baseline.json"
        self.ratchet.BASELINE = str(self.baseline)
        self.ratchet.REPORT_BASELINE = str(self.report_baseline)
        self.ratchet.write_baseline({"alpha": {"unwrap_used": 1}, "beta": {}})

    def tearDown(self):
        self.tmp.cleanup()

    def write_jsonl(self, name, items):
        path = self.root / name
        path.write_text("".join(json.dumps(item) + "\n" for item in items))
        return str(path)

    def ci_items(self):
        return [artifact("alpha"), artifact("beta"),
                message("alpha", "unwrap_used", "crates/alpha/src/lib.rs", 10),
                message("beta", "arithmetic_side_effects", "crates/beta/src/lib.rs", 1), FINISHED]

    def report_hits(self):
        return [
            message("alpha", "undocumented_unsafe_blocks", "crates/alpha/src/lib.rs", 20),
            message("alpha", "undocumented_unsafe_blocks", "crates/alpha/src/lib.rs", 30),
            message("beta", "large_futures", "crates/beta/src/lib.rs", 2),
            message("beta", "await_holding_invalid_type", "crates/beta/src/lib.rs", 3),
            message("alpha", "undocumented_unsafe_blocks", "/w/target/debug/build/alpha-1/out/bindings.rs", 1),
        ]

    def lab_items(self):
        return self.report_hits() + self.ci_items()

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", ["rust_panic_ratchet.py", "--repo", str(self.root), *argv]), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = self.ratchet.main()
        return code, out.getvalue(), err.getvalue()

    def test_ci_flags_unchanged_and_report_flags_extend_them(self):
        code, out, _ = self.run_main("--flags")
        self.assertEqual((code, out.strip()), (0, CI_FLAGS))
        for lint in self.ratchet.REPORT_LINTS:
            self.assertNotIn(lint, out)
        code, out, _ = self.run_main("--report-flags")
        self.assertEqual(code, 0)
        self.assertEqual(out.strip(), CI_FLAGS + " -W clippy::undocumented_unsafe_blocks -W clippy::large_futures"
                                                 " -W clippy::await_holding_invalid_type")

    def test_compare_ignores_report_lints_and_never_reads_report_baseline(self):
        self.report_baseline.write_text("not json: the compare mode must never open this file")
        real_open = open

        def guarded_open(path, *args, **kwargs):
            if os.fspath(path) == str(self.report_baseline):
                raise AssertionError("compare mode opened the report baseline")
            return real_open(path, *args, **kwargs)

        ci = self.write_jsonl("ci.jsonl", self.ci_items())
        lab = self.write_jsonl("lab.jsonl", self.lab_items())
        with mock.patch("builtins.open", guarded_open):
            ci_result = self.run_main("--clippy-json", ci, "--report", "json")
            lab_result = self.run_main("--clippy-json", lab, "--report", "json")
        self.maxDiff = None
        self.assertEqual(ci_result, lab_result)
        self.assertEqual(ci_result[0], 0)
        self.assertIn("2 crates checked", ci_result[2])

    def test_compare_red_stays_red_with_report_hits(self):
        items = [message("alpha", "unwrap_used", "crates/alpha/src/lib.rs", 11)] + self.ci_items()
        ci = self.write_jsonl("ci.jsonl", items)
        lab = self.write_jsonl("lab.jsonl", self.report_hits() + items)
        self.assertEqual(self.run_main("--clippy-json", ci), self.run_main("--clippy-json", lab))
        self.assertEqual(self.run_main("--clippy-json", lab)[0], 1)

    def test_tracked_report_counts_and_writes_its_own_baseline(self):
        lab = self.write_jsonl("lab.jsonl", self.lab_items())
        before = self.baseline.read_text()
        code, out, _ = self.run_main("--clippy-json", lab, "--tracked-report", "json", "--update-report-baseline")
        self.assertEqual(code, 0)
        rows = json.loads(out)
        self.assertEqual(rows["alpha"]["counts"], {"undocumented_unsafe_blocks": 2, "large_futures": 0,
                                                   "await_holding_invalid_type": 0, "invariant_allows": 2})
        self.assertEqual(rows["beta"]["counts"], {"undocumented_unsafe_blocks": 0, "large_futures": 1,
                                                  "await_holding_invalid_type": 1, "invariant_allows": 0})
        written = json.loads(self.report_baseline.read_text())
        self.assertEqual(written["totals"], {"undocumented_unsafe_blocks": 2, "large_futures": 1,
                                             "await_holding_invalid_type": 1, "invariant_allows": 2})
        self.assertEqual(self.baseline.read_text(), before, "the CI baseline must not change")

    def test_tracked_report_md_shows_delta_and_never_fails(self):
        self.ratchet.write_report_baseline({"alpha": {"undocumented_unsafe_blocks": 5}, "beta": {}})
        lab = self.write_jsonl("lab.jsonl", [message("alpha", "unwrap_used", "crates/alpha/src/lib.rs", 99)]
                               + self.lab_items())
        code, out, _ = self.run_main("--clippy-json", lab, "--tracked-report", "md")
        self.assertEqual(code, 0)
        self.assertIn("| alpha | 2 (-3) | 0 | 0 | 2 (+2) |", out)
        self.assertIn("| **total** | 2 | 1 | 1 | 2 | |", out)

    def test_tracked_report_refuses_a_partial_build(self):
        lab = self.write_jsonl("lab.jsonl", self.lab_items()[:-1])
        code, _, err = self.run_main("--clippy-json", lab, "--tracked-report", "md", "--update-report-baseline")
        self.assertEqual(code, 2)
        self.assertIn("did not finish", err)
        self.assertFalse(self.report_baseline.exists())

    def test_tracked_report_merges_runs_but_writes_its_baseline_from_one(self):
        linux = self.write_jsonl("linux.jsonl", self.lab_items())
        # The macOS checkout names a file by an absolute path: the same line counts once.
        macos = self.write_jsonl("macos.jsonl", [
            message("alpha", "undocumented_unsafe_blocks", "/Users/m/src/cmux-tui/crates/alpha/src/lib.rs", 20),
            message("alpha", "undocumented_unsafe_blocks", "crates/alpha/src/lib.rs", 40),
        ] + self.ci_items())
        code, out, _ = self.run_main("--clippy-json", f"linux={linux}", "--clippy-json", f"macos={macos}",
                                     "--tracked-report", "json")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["alpha"]["counts"]["undocumented_unsafe_blocks"], 3)
        with self.assertRaises(SystemExit):
            self.run_main("--clippy-json", f"linux={linux}", "--clippy-json", f"macos={macos}",
                          "--tracked-report", "md", "--update-report-baseline")
        self.assertFalse(self.report_baseline.exists())

    def test_update_report_baseline_needs_tracked_report(self):
        lab = self.write_jsonl("lab.jsonl", self.lab_items())
        with self.assertRaises(SystemExit):
            self.run_main("--clippy-json", lab, "--update-report-baseline")

    def test_lab_clippy_conf_is_not_the_workspace_one(self):
        repo = SCRIPTS.parents[1]
        conf = repo / "cmux-tui" / "lab" / "clippy" / "clippy.toml"
        lab = tomllib.loads(conf.read_text())
        self.assertEqual([entry["path"] for entry in lab["await-holding-invalid-types"]],
                         ["cmux_tui_core::lock_rank::RankedGuard"])
        self.assertEqual(lab["future-size-threshold"], 16384)
        self.assertFalse((repo / "cmux-tui" / ".clippy.toml").exists())
        workspace_conf = repo / "cmux-tui" / "clippy.toml"
        workspace = tomllib.loads(workspace_conf.read_text()) if workspace_conf.exists() else {}
        # The lab keys never reach the `clippy -D warnings` CI run.
        self.assertNotIn("await-holding-invalid-types", workspace)
        self.assertNotIn("future-size-threshold", workspace)
        # CLIPPY_CONF_DIR replaces the workspace file: the lab run keeps every workspace setting. The lab's
        # disallowed-methods is a superset (task 206 adds the blocking calls and may word a reason for its
        # cmux_blocking wrapper), so for that key every workspace path must be there; the rest repeat as is.
        for key, value in workspace.items():
            if key == "disallowed-methods":
                lab_paths = {entry["path"] for entry in lab.get(key, [])}
                for entry in value:
                    self.assertIn(entry["path"], lab_paths,
                                  f"lab/clippy/clippy.toml must keep cmux-tui/clippy.toml's {key} rule {entry['path']}")
                continue
            self.assertEqual(lab.get(key), value, f"lab/clippy/clippy.toml must repeat cmux-tui/clippy.toml's {key}")


if __name__ == "__main__":
    unittest.main()
