#!/usr/bin/env python3
"""The Rust panic ratchet charges a change only its own files' hits when the base clippy run did not finish.

A base that does not compile (feat-cmux-next after #53965, acpmux missing a struct field) gives no base counts to
compare, so every count over the baseline was charged to whatever PR ran: its own fix (#54392) too, red on 18
crates it never touched. With the base run broken, a crate over the baseline is the change's only when one of its
hits is in a file the change touched.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load():
    spec = importlib.util.spec_from_file_location("rust_panic_ratchet_base_broken",
                                                  ROOT / "scripts/cmux-next/rust_panic_ratchet.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def artifact(crate):
    return {"reason": "compiler-artifact", "package_id": f"path+file:///w/cmux-tui/crates/{crate}#{crate}@0.1.0",
            "target": {"kind": ["lib"]}}


def hit(crate, file_name, line, lint="indexing_slicing"):
    return {"reason": "compiler-message", "package_id": f"path+file:///w/cmux-tui/crates/{crate}#{crate}@0.1.0",
            "target": {"kind": ["lib"]},
            "message": {"code": {"code": f"clippy::{lint}"},
                        "spans": [{"is_primary": True, "file_name": file_name, "line_start": line,
                                   "column_start": 1}]}}


class RatchetCase(unittest.TestCase):
    def setUp(self):
        self.ratchet = load()
        self.ratchet.changed_files.cache_clear()
        self.ratchet.changed_lines.cache_clear()
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        self.baseline = {"crates": {"alpha": {lint: 0 for lint in self.ratchet.LINTS}}}
        baseline = self.tmp / "baseline.json"
        baseline.write_text(json.dumps(self.baseline))
        patch = unittest.mock.patch.object(self.ratchet, "BASELINE", str(baseline))
        patch.start()
        self.addCleanup(patch.stop)

    def write(self, name, items, success):
        path = self.tmp / name
        path.write_text("\n".join(json.dumps(i) for i in [*items, {"reason": "build-finished", "success": success}]))
        return str(path)


class BaseBrokenRatchet(RatchetCase):
    def run_ratchet(self, head_items, changed, reasonless=()):
        head = self.write("head.jsonl", [artifact("alpha"), *head_items], True)
        base = self.write("base.jsonl", [artifact("alpha")], False)
        err = io.StringIO()
        with unittest.mock.patch.object(self.ratchet, "changed_files", lambda root: frozenset(changed)), \
                unittest.mock.patch.object(sys, "argv", ["ratchet", "--clippy-json", head,
                                                         "--base-clippy-json", base, "--repo", str(self.tmp)]), \
                unittest.mock.patch.object(self.ratchet, "allow_without_reason", lambda root: list(reasonless)), \
                contextlib.redirect_stderr(err):
            code = self.ratchet.main()
        return code, err.getvalue()

    def test_base_drift_in_files_the_change_never_touched_is_the_base_s(self):
        code, err = self.run_ratchet([hit("alpha", "crates/alpha/src/drift.rs", 3)],
                                     {"crates/acpmux/src/cli/gh_shim.rs"})
        self.assertEqual(code, 0, err)
        self.assertIn("no hit is on a line this change added or edited", err)

    def test_a_hit_in_a_touched_file_is_still_the_change_s(self):
        code, err = self.run_ratchet([hit("alpha", "/w/cmux-tui/crates/alpha/src/own.rs", 3),
                                      hit("alpha", "crates/alpha/src/drift.rs", 4)],
                                     {"crates/alpha/src/own.rs"})
        self.assertEqual(code, 1, err)
        self.assertIn("rust-panic-ratchet: RED", err)

    def test_no_known_changed_files_charges_the_change_as_before(self):
        code, err = self.run_ratchet([hit("alpha", "crates/alpha/src/drift.rs", 3)], set())
        self.assertEqual(code, 1, err)


    # A reasonless allow the base already had (#55909's cmux-layout-reducer-ffi) charged every PR, since the
    # scan walks the whole tree: only one in a file the change touched is the change's.
    BAD = "cmux-tui/crates/alpha/src/lib.rs:510: allow(cast_possible_truncation) needs reason = \"...\""

    def test_a_reasonless_allow_in_an_untouched_file_is_the_base_s(self):
        code, err = self.run_ratchet([], {"crates/beta/src/other.rs"}, [self.BAD])
        self.assertEqual(code, 0, err)
        self.assertIn("the base's red, not this change's", err)

    def test_a_reasonless_allow_in_a_touched_file_is_the_change_s(self):
        code, err = self.run_ratchet([], {"crates/alpha/src/lib.rs"}, [self.BAD])
        self.assertEqual(code, 1, err)
        self.assertIn("needs reason", err)

    def test_a_reasonless_allow_with_no_known_changed_files_still_fails(self):
        code, err = self.run_ratchet([], set(), [self.BAD])
        self.assertEqual(code, 1, err)


class UntouchedIsBase(RatchetCase):
    """--untouched-is-base: cmux-tui-clippy-changed.py asks this before it lints the base a second time (run
    45929462416 spent ~5 min linting base 0a1088f4 only to excuse 20 crates the change never touched)."""

    def judge(self, head_items, changed, *extra):
        head = self.write("head.jsonl", [artifact("alpha"), *head_items], True)
        err = io.StringIO()
        with unittest.mock.patch.object(self.ratchet, "changed_files", lambda root: frozenset(changed)), \
                unittest.mock.patch.object(sys, "argv", ["ratchet", "--clippy-json", head, "--repo", str(self.tmp),
                                                         *extra]), \
                unittest.mock.patch.object(self.ratchet, "allow_without_reason", lambda root: []), \
                contextlib.redirect_stderr(err):
            code = self.ratchet.main()
        return code, err.getvalue()

    def test_drift_in_untouched_files_needs_no_base_run(self):
        code, err = self.judge([hit("alpha", "crates/alpha/src/drift.rs", 3)], {"crates/beta/src/x.rs"},
                               "--untouched-is-base")
        self.assertEqual(code, 0, err)
        self.assertIn("the base was not linted, and no hit is on a line this change added or edited", err)

    def test_a_hit_in_a_touched_file_still_needs_the_base_run(self):
        code, err = self.judge([hit("alpha", "crates/alpha/src/own.rs", 3)], {"crates/alpha/src/own.rs"},
                               "--untouched-is-base")
        self.assertEqual(code, 1, err)

    def test_without_the_flag_drift_is_still_red(self):
        code, err = self.judge([hit("alpha", "crates/alpha/src/drift.rs", 3)], {"crates/beta/src/x.rs"})
        self.assertEqual(code, 1, err)

    def test_diff_base_names_the_files_git_diff_against_that_commit_names(self):
        import subprocess
        repo = self.tmp / "repo"
        git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        (repo / "cmux-tui/crates/alpha/src").mkdir(parents=True)
        (repo / "cmux-tui/crates/alpha/src/old.rs").write_text("1\n")
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run([*git, "add", "."], check=True)
        subprocess.run([*git, "commit", "-qm", "base"], check=True)
        base = subprocess.run([*git, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
        (repo / "cmux-tui/crates/alpha/src/new.rs").write_text("2\n")
        subprocess.run([*git, "add", "."], check=True)
        subprocess.run([*git, "commit", "-qm", "change"], check=True)
        self.ratchet.DIFF_BASE = base
        self.addCleanup(setattr, self.ratchet, "DIFF_BASE", None)
        self.assertEqual(self.ratchet.changed_files(str(repo)), frozenset({"crates/alpha/src/new.rs"}))


class PerChangedLine(RatchetCase):
    """A hit is the change's only when it is on a line the change added or edited: #63818 edited acpmux's
    protocol/mod.rs and was charged with the unwrap already at its line 840 (unwrap_used 111 > 109)."""

    def judge(self, head_items, changed, lines):
        head = self.write("head.jsonl", [artifact("alpha"), *head_items], True)
        err = io.StringIO()
        with unittest.mock.patch.object(self.ratchet, "changed_files", lambda root: frozenset(changed)), \
                unittest.mock.patch.object(self.ratchet, "changed_lines", lambda root: lines), \
                unittest.mock.patch.object(sys, "argv", ["ratchet", "--clippy-json", head, "--repo", str(self.tmp),
                                                         "--untouched-is-base"]), \
                unittest.mock.patch.object(self.ratchet, "allow_without_reason", lambda root: []), \
                contextlib.redirect_stderr(err):
            code = self.ratchet.main()
        return code, err.getvalue()

    def test_an_old_hit_in_a_touched_file_is_the_base_s(self):
        code, err = self.judge([hit("alpha", "/w/cmux-tui/crates/alpha/src/mod.rs", 840)],
                               {"crates/alpha/src/mod.rs"}, {"crates/alpha/src/mod.rs": frozenset({12, 13})})
        self.assertEqual(code, 0, err)
        self.assertIn("no hit is on a line this change added or edited", err)

    def test_a_hit_on_a_line_the_change_edited_is_the_change_s(self):
        code, err = self.judge([hit("alpha", "/w/cmux-tui/crates/alpha/src/mod.rs", 840),
                                hit("alpha", "crates/alpha/src/mod.rs", 13)],
                               {"crates/alpha/src/mod.rs"}, {"crates/alpha/src/mod.rs": frozenset({12, 13})})
        self.assertEqual(code, 1, err)
        self.assertIn("crates/alpha/src/mod.rs:13", err)

    def test_without_line_ranges_the_file_rule_still_charges_a_touched_file(self):
        code, err = self.judge([hit("alpha", "crates/alpha/src/mod.rs", 840)], {"crates/alpha/src/mod.rs"}, None)
        self.assertEqual(code, 1, err)

    def test_changed_lines_reads_head_line_numbers_of_added_and_edited_lines(self):
        import subprocess
        repo = self.tmp / "repo"
        git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        src = repo / "cmux-tui/crates/alpha/src"
        src.mkdir(parents=True)
        (src / "a.rs").write_text("".join(f"{n}\n" for n in range(1, 11)))
        (src / "gone.rs").write_text("x\n")
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run([*git, "add", "."], check=True)
        subprocess.run([*git, "commit", "-qm", "base"], check=True)
        base = subprocess.run([*git, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
        body = [f"{n}\n" for n in range(1, 11)]
        body[1] = "edited\n"          # line 2 edited
        body.insert(5, "added\n")     # new line 6; old 6..10 move to 7..11
        del body[-1]                  # old line 10 removed: nothing new to charge
        (src / "a.rs").write_text("".join(body))
        (src / "gone.rs").unlink()
        subprocess.run([*git, "add", "-A"], check=True)
        subprocess.run([*git, "commit", "-qm", "change"], check=True)
        self.ratchet.DIFF_BASE = base
        self.addCleanup(setattr, self.ratchet, "DIFF_BASE", None)
        self.assertEqual(self.ratchet.changed_lines(str(repo)), {"crates/alpha/src/a.rs": frozenset({2, 6})})


class RecordBase(RatchetCase):
    def test_record_base_writes_the_runs_counts_up_and_down_and_keeps_unchecked_rows(self):
        baseline = Path(self.ratchet.BASELINE)
        rows = {"alpha": {lint: 0 for lint in self.ratchet.LINTS}, "gone": {"unwrap_used": 4}}
        rows["alpha"]["unwrap_used"] = 9
        baseline.write_text(json.dumps({"crates": rows}))
        head = self.write("head.jsonl", [artifact("alpha"), artifact("fresh"),
                                         hit("alpha", "crates/alpha/src/a.rs", 1),
                                         hit("fresh", "crates/fresh/src/f.rs", 2, "string_slice")], True)
        err = io.StringIO()
        with unittest.mock.patch.object(sys, "argv", ["ratchet", "--clippy-json", head, "--repo", str(self.tmp),
                                                      "--record-base"]), contextlib.redirect_stderr(err):
            code = self.ratchet.main()
        self.assertEqual(code, 0, err.getvalue())
        crates = json.loads(baseline.read_text())["crates"]
        self.assertEqual(crates["alpha"]["indexing_slicing"], 1)
        self.assertEqual(crates["alpha"]["unwrap_used"], 0)
        self.assertEqual(crates["fresh"]["string_slice"], 1)
        self.assertEqual(crates["gone"]["unwrap_used"], 4)
        self.assertIn("over the baseline before: 2 crates in a deny lint (alpha, fresh)", err.getvalue())
        self.assertIn("after: 0", err.getvalue())


class ExampleMessages(RatchetCase):
    def test_example_units_hits_are_not_counted(self):
        # cmux-tui-clippy-changed.py adds --examples so cargo unifies features as its --all-targets run did and
        # replays that run; an example's hits are not production code.
        example = hit("alpha", "crates/alpha/examples/e.rs", 3)
        example["target"] = {"kind": ["example"]}
        path = self.write("head.jsonl", [artifact("alpha"), hit("alpha", "crates/alpha/src/a.rs", 1), example], True)
        checked, counts, _files, finished, _hits = self.ratchet.read_clippy(path)
        self.assertEqual(checked, {"alpha"})
        self.assertTrue(finished)
        self.assertEqual(dict(counts["alpha"]), {"indexing_slicing": 1})


if __name__ == "__main__":
    unittest.main()
