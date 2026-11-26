#!/usr/bin/env python3
"""scripts/ci/warm-verdict-worker.py and scripts/measure/warm-verdict-replay.py: routing, budgets, timing, and one
verdict on a throwaway repository (git only; no cargo, bun or network)."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, rel: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


w = load("warm_verdict_worker", "scripts/ci/warm-verdict-worker.py")
replay = load("warm_verdict_replay", "scripts/measure/warm-verdict-replay.py")


class Classify(unittest.TestCase):
    def test_rust_workspace_and_manifests(self):
        k = w.classify(["cmux-tui/crates/a/src/lib.rs"])
        self.assertTrue(k["rust_ws"])
        self.assertFalse(k["manifests"])
        self.assertTrue(w.classify(["cmux-tui/Cargo.lock"])["manifests"])

    def test_other_rust_workspace(self):
        k = w.classify(["workers/cmux-vm/cli/src/main.rs", "docs/x.md"])
        self.assertFalse(k["rust_ws"])
        self.assertEqual(k["other_rust"], ["workers/cmux-vm/cli/src/main.rs"])

    def test_web_packages(self):
        k = w.classify(["webviews/src/a.tsx", "webviews/package.json", "web/app/page.ts", "webviews/README.md"])
        self.assertEqual(sorted(k["web_ts"]), ["web", "webviews"])
        self.assertEqual(k["web_deps"], ["webviews"])

    def test_swift(self):
        k = w.classify(["Packages/macOS/CmuxNext/Sources/X/A.swift", "Packages/macOS/Foo/Package.swift", "a.py"])
        self.assertEqual(len(k["swift"]), 2)

    def test_docs_need_nothing(self):
        k = w.classify(["docs/a.md", "plans/b.md"])
        self.assertEqual((k["rust_ws"], k["other_rust"], k["web_ts"], k["swift"]), (False, [], [], []))


class Budget(unittest.TestCase):
    def test_python_seconds_parse(self):
        out = ("==> tests/test_a.py ok in 1.5s\nnoise\n==> tests/test_b.py FAILED (exit 1) in 178.0s\n"
               "==> 2 tests in 179.0s (jobs=8, serial=0); 1 failed\n")
        self.assertEqual(w.python_seconds(out), {"tests/test_a.py": 1.5, "tests/test_b.py": 178.0})

    def test_split_by_budget_runs_unknown(self):
        now, later = w.split_by_budget(["a", "b", "c"], {"a": 1.0, "b": 99.0}, 20.0)
        self.assertEqual(now, ["a", "c"])
        self.assertEqual(later, ["b"])


class Timing(unittest.TestCase):
    def test_verdict_word(self):
        ok, bad = {"exit": 0}, {"exit": 1}
        self.assertEqual(w.verdict_word([ok], []), "pass")
        self.assertEqual(w.verdict_word([ok], ["Pkg:Tests"]), "pass-linux")
        self.assertEqual(w.verdict_word([ok, bad], []), "fail")

    def test_percentiles(self):
        vals = [float(i) for i in range(1, 21)]
        self.assertEqual(replay.pct(vals, 50), 10.0)
        self.assertEqual(replay.pct(vals, 90), 18.0)
        self.assertEqual(replay.pct([], 50), 0.0)
        self.assertEqual(replay.pct([7.0], 90), 7.0)

    def test_run_bounds_a_command(self):
        res = w.run([sys.executable, "-c", "import time; time.sleep(5)"], ROOT, 1)
        self.assertEqual(res["exit"], 124)
        self.assertLess(res["s"], 4)


class InPlace(unittest.TestCase):
    """The tree is cloned once; a later head is checked out in place, fetched only when missing."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        src = Path(self.tmp.name) / "src"
        src.mkdir()
        g = lambda *a: subprocess.run(["git", "-C", str(src), *a], check=True, capture_output=True, text=True).stdout
        g("init", "-q", "-b", "main")
        g("config", "user.email", "t@example.invalid")
        g("config", "user.name", "t")
        (src / "docs").mkdir()
        (src / "docs/a.md").write_text("a\n")
        g("add", ".")
        g("commit", "-q", "-m", "one")
        self.base = g("rev-parse", "HEAD").strip()
        (src / "docs/a.md").write_text("b\n")
        g("commit", "-qam", "two")
        self.head = g("rev-parse", "HEAD").strip()
        self.src = src

    def test_verdict_on_a_docs_change(self):
        worker = w.Worker(Path(self.tmp.name) / "state", str(self.src), jobs=2)
        v = worker.verdict(self.head)
        self.assertEqual(v["base"], self.base)
        self.assertEqual(v["verdict"], "pass")
        self.assertFalse(v["fetched"])  # the --shared clone already holds it
        self.assertEqual(v["files"], 1)
        self.assertEqual(set(v["phases"]) >= {"fetch", "checkout", "route"}, True)
        json.dumps(v)
        clone = worker.tree / ".git"
        v2 = worker.verdict(self.base, self.base)  # back in place, same clone
        self.assertTrue(clone.exists())
        self.assertEqual(v2["files"], 0)


if __name__ == "__main__":
    unittest.main()
