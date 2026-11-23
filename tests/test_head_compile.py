#!/usr/bin/env python3
"""scripts/ci/head_compile.py: the feat-cmux-next head compiles, and a red head names the merge that broke it.

2026-11-22 the head broke four times from merges that each passed alone (a stale Cargo.lock, a second
Supervisor::signal_due, a committed generated settings file, and #51052 calling qos helpers the #51319 revert
removed). Each test builds a scratch repository and replays that shape: two pull requests squash-merged one after
another, a check that passes on each alone, and fails on the head. No network, no compiler: the "compile" is a
small script that fails where the real one did.
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "head_compile.py"


def load():
    spec = importlib.util.spec_from_file_location("head_compile", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SUPERVISOR = "cmux-tui/crates/cmux-tui-core/src/apps/supervisor.rs"
# The replayed compiler: two definitions of one fn in the file is the E0201 the crate failed with.
DUPLICATE_FN = r"""
import re, sys
text = open(sys.argv[1]).read()
names = re.findall(r"fn (\w+)", text)
dupes = sorted({n for n in names if names.count(n) > 1})
if dupes:
    print(f"error[E0201]: duplicate definitions with name `{dupes[0]}`")
    sys.exit(1)
"""


class Repo:
    def __init__(self, root: Path):
        self.root = root
        root.mkdir(parents=True)
        self.git("init", "-q", "--initial-branch=feat-cmux-next")

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
             "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0", *args],
            cwd=self.root, check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, message: str, files: dict[str, str]) -> str:
        for path, text in files.items():
            full = self.root / path
            full.parent.mkdir(parents=True, exist_ok=True)
            full.write_text(text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")


class HeadCompileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.hc = load()
        self.repo = Repo(Path(self.tmp.name) / "repo")
        self.check = Path(self.tmp.name) / "check.py"
        self.check.write_text(DUPLICATE_FN)
        self.base = self.repo.commit("base", {SUPERVISOR: "impl Supervisor {\n    fn tick() {}\n}\n",
                                              "README.md": "hi\n"})

    def signal_due_merges(self) -> tuple[str, str, str]:
        """#50100 and #50234 each add Supervisor::signal_due on the same base; squash-merged in that order."""
        one = "impl Supervisor {\n    fn tick() {}\n    fn signal_due() {}\n}\n"
        both = "impl Supervisor {\n    fn tick() {}\n    fn signal_due() {}\n    fn signal_due() {}\n}\n"
        first = self.repo.commit("Supervisor: the signal tell (#50100)", {SUPERVISOR: one})
        docs = self.repo.commit("docs: a typo (#50150)", {"README.md": "hello\n"})
        second = self.repo.commit("Extensions can be signal sources (#50234)", {SUPERVISOR: both})
        return first, docs, second

    def run_check(self, base: str, head: str, *extra: str) -> tuple[int, dict]:
        out = Path(self.tmp.name) / "verdict.json"
        cmd = f"{sys.executable} -I {self.check} {{tree}}/{SUPERVISOR}"
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "run", "--repo", str(self.repo.root), "--base", base, "--head", head,
             "--check", cmd, "--json", str(out), *extra],
            capture_output=True, text=True)
        self.assertIn(result.returncode, (0, 1), result.stdout + result.stderr)
        return result.returncode, json.loads(out.read_text())

    def test_a_red_head_names_the_merge_that_broke_it(self):
        _first, _docs, second = self.signal_due_merges()
        code, verdict = self.run_check(self.base, second)
        self.assertEqual(code, 1)
        self.assertEqual(verdict["verdict"], "fail")
        self.assertEqual(verdict["culprit"]["sha"], second)
        self.assertEqual(verdict["culprit"]["pr"], 50234)
        self.assertIn("duplicate definitions with name `signal_due`", verdict["errors"])

    def test_a_one_merge_range_names_it_without_a_probe(self):
        first, _docs, second = self.signal_due_merges()
        code, verdict = self.run_check(second + "~1", second)
        self.assertEqual(code, 1)
        self.assertEqual(verdict["culprit"]["pr"], 50234)
        self.assertEqual(verdict["probes"], [])

    def test_each_merge_alone_is_green(self):
        first, docs, _second = self.signal_due_merges()
        code, verdict = self.run_check(self.base, docs)
        self.assertEqual((code, verdict["verdict"]), (0, "pass"))

    def test_bisect_probes_only_commits_that_touch_compile_inputs(self):
        # A docs-only merge cannot break a compile: it is never probed, never named.
        _first, docs, second = self.signal_due_merges()
        code, verdict = self.run_check(self.base, second)
        self.assertNotIn(docs, verdict["probes"])
        self.assertNotIn(docs, [c["sha"] for c in verdict["candidates"]])

    def test_a_long_range_bisects_instead_of_probing_every_merge(self):
        files = {}
        for n in range(12):
            files = {f"cmux-tui/crates/x/src/f{n}.rs": f"fn f{n}() {{}}\n"}
            self.repo.commit(f"x: f{n} (#600{n:02d})", files)
        bad = self.repo.commit("x: the break (#60099)", {SUPERVISOR: "fn a() {}\nfn a() {}\n"})
        for n in range(3):
            self.repo.commit(f"x: after {n} (#601{n:02d})", {f"cmux-tui/crates/x/src/g{n}.rs": "fn g() {}\n"})
        head = self.repo.git("rev-parse", "HEAD")
        code, verdict = self.run_check(self.base, head, "--parallel", "4")
        self.assertEqual(verdict["culprit"]["sha"], bad)
        self.assertLessEqual(len(verdict["probes"]), 8, "16 candidates bisect in a few rounds, not one probe each")

    def test_a_head_already_red_is_not_bisected_again(self):
        # While the head stays red, each push would bisect the same range again: --no-bisect names the merges only.
        _first, _docs, second = self.signal_due_merges()
        code, verdict = self.run_check(self.base, second, "--no-bisect")
        self.assertEqual((code, verdict["probes"], verdict["culprit"]), (1, [], None))
        self.assertEqual(len(verdict["suspects"]), 2)

    def test_a_check_with_no_verdict_is_never_red(self):
        # A busy fleet or a lost runner answers 75: no verdict, so no merge is blamed and the run is not red.
        head = self.repo.commit("x (#70000)", {SUPERVISOR: "fn b() {}\n"})
        out = Path(self.tmp.name) / "v.json"
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "run", "--repo", str(self.repo.root), "--base", self.base,
             "--head", head, "--check", "exit 75", "--json", str(out)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(out.read_text())["verdict"], "none")

    def test_plan_reads_which_checks_a_change_needs(self):
        plan = self.hc.plan
        self.assertEqual(plan(["README.md", "docs/x.md"]), set())
        self.assertEqual(plan(["cmux-tui/Cargo.lock"]), {"app", "linux"})
        self.assertEqual(plan(["cmux-tui/crates/acpmux/src/qos.rs"]), {"app", "linux"})
        self.assertEqual(plan(["Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Schema/X.generated.swift"]), {"app"})
        self.assertEqual(plan(["ghostty-next"]), {"app", "linux"})
        self.assertEqual(plan(["scripts/ci/head_compile.py"]), {"app", "linux"})

    def test_the_pr_number_comes_from_the_squash_subject(self):
        self.assertEqual(self.hc.pr_of("acpmux: the daemon outranks the work (RFD 0049 R3) (#51052)"), 51052)
        self.assertEqual(self.hc.pr_of('Revert "Agent chat: no wait" (#51319)'), 51319)
        self.assertIsNone(self.hc.pr_of("cmux-app-ffi: Cargo.lock in sync"))


if __name__ == "__main__":
    unittest.main()
