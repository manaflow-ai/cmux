#!/usr/bin/env python3
"""scripts/ci/react_shard_receipt.py: the react-apps-check shard's same-input key, its green-only receipt, and the
fail-open lookup (ci-web.yml react-apps-check-shard)."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import react_shard_receipt as r  # noqa: E402


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "ci@example.test")
        git(self.repo, "config", "user.name", "ci")
        (self.repo / "a.txt").write_text("base\n")
        (self.repo / "webviews").mkdir()
        (self.repo / "webviews" / "package.json").write_text("{}\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "base")
        (self.repo / "b.txt").write_text("head\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "head")
        self.handoff = self.root / "handoff"
        self.handoff.mkdir()
        (self.handoff / "manifest.json").write_text('{"x.test.ts": 3}\n')
        self.cwd = Path.cwd()
        import os
        os.chdir(self.repo)

    def tearDown(self) -> None:
        import os
        os.chdir(self.cwd)
        self.tmp.cleanup()

    def results(self, found: dict) -> Path:
        out = self.root / "results"
        (out / "raw-logs").mkdir(parents=True, exist_ok=True)
        (out / "runner").mkdir(exist_ok=True)
        (out / "runner" / "run-webviews-tests.sh").write_text("#!/bin/sh\n")
        (out / "raw-logs" / "summary").write_text("PASS x.test.ts log\n")
        (out / "raw-logs" / "x.test.ts.log").write_text("big log\n")
        (out / r.RESULTS).write_text(json.dumps(found))
        return out


class KeyTest(Fixture):
    def test_key_is_stable_and_covers_every_input(self) -> None:
        k = r.key("2", self.handoff, "cfg")
        self.assertTrue(k.startswith("react-shard-receipt-v1-shard2-"))
        self.assertEqual(k, r.key("2", self.handoff, "cfg"))
        self.assertNotEqual(k, r.key("3", self.handoff, "cfg"))
        self.assertNotEqual(k, r.key("2", self.handoff, "cfg2"))
        (self.handoff / "base-reds.json").write_text("[]\n")
        with_reds = r.key("2", self.handoff, "cfg")
        self.assertNotEqual(k, with_reds)
        (self.handoff / "manifest.json").write_text('{"x.test.ts": 4}\n')
        self.assertNotEqual(with_reds, r.key("2", self.handoff, "cfg"))

    def test_key_follows_the_tree_and_the_merge_parent(self) -> None:
        k = r.key("1", self.handoff, "cfg", scoped=False)
        (self.repo / "b.txt").write_text("changed\n")
        git(self.repo, "commit", "-q", "-am", "next")
        self.assertNotEqual(k, r.key("1", self.handoff, "cfg", scoped=False))

    def commit(self, path: str, text: str) -> None:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", f"edit {path}")

    def recommit(self, path: str, text: str) -> None:
        """Replace HEAD by a commit on the same parent that also writes `path` (a re-push of the same pull request)."""
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "--amend", "-m", "pushed again")

    def test_same_input_tree_hits_an_input_change_runs(self) -> None:
        self.commit("webviews/src/a.ts", "one\n")
        k = r.key("1", self.handoff, "cfg")
        self.recommit("Packages/other/x.swift", "unrelated\n")  # no input changed: same key
        self.assertEqual(k, r.key("1", self.handoff, "cfg"))
        self.recommit("notes/doc.md", "docs\n")
        self.assertEqual(k, r.key("1", self.handoff, "cfg"))
        self.assertNotEqual(k, r.key("1", self.handoff, "cfg", scoped=False))
        self.recommit("webviews/src/a.ts", "two\n")  # an input changed: another key
        self.assertNotEqual(k, r.key("1", self.handoff, "cfg"))

    def test_a_hit_reuses_the_earlier_green_and_a_store_error_runs(self) -> None:
        self.commit("webviews/src/a.ts", "one\n")
        k = r.key("1", self.handoff, "cfg")
        receipt = self.root / "receipt"
        r.write(k, self.results({"x.test.ts": True}), receipt, "https://example.test/run/9")
        self.recommit("Packages/other/x.swift", "unrelated\n")
        k2 = r.key("1", self.handoff, "cfg")
        self.assertEqual(k2, k)
        self.assertEqual(r.check(k2, receipt, self.root / "out"), (True, "https://example.test/run/9"))
        # a store error: an unreadable receipt, or one that is not a receipt, is a miss, never an exception or a hit
        (receipt / r.RECEIPT).write_text("{not json")
        self.assertEqual(r.check(k2, receipt, self.root / "out2"), (False, ""))
        self.assertEqual(r.check(k2, self.root / "no-store", self.root / "out3"), (False, ""))

    def test_input_list_failure_keys_the_whole_tree(self) -> None:
        import unittest.mock
        self.commit("webviews/src/a.ts", "one\n")
        whole = r.key("1", self.handoff, "cfg", scoped=False)
        with unittest.mock.patch.object(r, "input_tree", side_effect=RuntimeError("boom")):
            self.assertEqual(r.key("1", self.handoff, "cfg"), whole)

    def test_no_parent_or_handoff_gives_no_key(self) -> None:
        with self.assertRaises(RuntimeError):
            r.key("1", self.root / "missing", "cfg")
        with self.assertRaises(RuntimeError):
            r.key("1", self.handoff, "cfg", rev="HEAD~1")  # the root commit has no first parent

    def test_cli_key_fails_open(self) -> None:
        import contextlib
        import io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(r.main(["key", "--shard", "1", "--handoff", str(self.root / "missing"), "--config", "c"]), 0)
        self.assertIn("key=\n", out.getvalue())


class ReceiptTest(Fixture):
    def test_green_round_trip(self) -> None:
        k = r.key("1", self.handoff, "cfg")
        receipt = self.root / "receipt"
        r.write(k, self.results({"x.test.ts": True}), receipt, "https://example.test/run/1")
        self.assertFalse((receipt / "results" / "raw-logs" / "x.test.ts.log").exists())
        target = self.root / "restored"
        (target / "raw-logs").mkdir(parents=True)
        (target / "raw-logs" / "stale").write_text("stale\n")
        hit, run = r.check(k, receipt, target)
        self.assertTrue(hit)
        self.assertEqual(run, "https://example.test/run/1")
        self.assertEqual(json.loads((target / r.RESULTS).read_text()), {"x.test.ts": True})
        self.assertTrue((target / "runner" / "run-webviews-tests.sh").is_file())
        self.assertTrue((target / "raw-logs" / "summary").is_file())
        self.assertFalse((target / "raw-logs" / "stale").exists())

    def test_a_red_or_empty_result_writes_no_receipt(self) -> None:
        k = r.key("1", self.handoff, "cfg")
        for found in ({"x.test.ts": True, "y.test.ts > t": False}, {}):
            with self.assertRaises(RuntimeError):
                r.write(k, self.results(found), self.root / "receipt", "")

    def test_another_key_or_a_tampered_receipt_misses(self) -> None:
        k = r.key("1", self.handoff, "cfg")
        receipt = self.root / "receipt"
        r.write(k, self.results({"x.test.ts": True}), receipt, "")
        target = self.root / "restored"
        self.assertEqual(r.check(k + "0", receipt, target), (False, ""))
        (receipt / "results" / r.RESULTS).write_text('{"x.test.ts": false}')
        self.assertEqual(r.check(k, receipt, target), (False, ""))
        self.assertFalse(target.exists())
        self.assertEqual(r.check(k, self.root / "none", target), (False, ""))


if __name__ == "__main__":
    unittest.main()
