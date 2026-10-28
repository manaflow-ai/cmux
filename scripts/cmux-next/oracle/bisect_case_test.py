#!/usr/bin/env python3
"""Tests for bisect_case.py: a planted divergence in a batch, the end checks, skips, merges and determinism.

Run: python3 -I scripts/cmux-next/oracle/bisect_case_test.py (stdlib unittest, git 2.30+). Not in CI (spec rule 1).
Each test builds a throwaway repository whose commits carry the case's value in value.txt, and a fake oracle.py
that answers `diff --base G --head H` the way the real one does (comparison.json, divergence.json, exit codes):
the case diverges when value.txt differs between G and H. The fleet run of the task (a planted divergence in an app
build) uses the real oracle.py through the same command.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from typing import Dict, List, Optional

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "bisect_case.py"
sys.path.insert(0, str(HERE))

import bisect_case as bc  # noqa: E402

CASE = "daemon-ops/planted"
ENV = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin:/usr/local/bin",
       "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid", "GIT_COMMITTER_NAME": "t",
       "GIT_COMMITTER_EMAIL": "t@example.invalid", "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z",
       "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z"}

FAKE_ORACLE = textwrap.dedent('''
    import json, subprocess, sys
    from pathlib import Path
    args = sys.argv[1:]
    assert args[0] == "diff", args
    opt = {args[i]: args[i + 1] for i in range(1, len(args) - 1) if args[i].startswith("--")}
    out = Path(opt["--out"])
    def real_queued_diff_head_not_built(base, head, out):
        """The real oracle.py diff on the VM when the head's build fails: linux_run.sh dies before a run dir."""
        import argparse, types
        sys.path.insert(0, ORACLE_DIR)
        import oracle
        base_dir = out / "base-run"
        base_dir.mkdir()
        (base_dir / "receipt.json").write_text("{}")
        def popen(command, **kw):
            built = command[3] == base
            text = f"{base_dir}\\n" if built else f"linux_run: build of {command[3]} gave no binary\\n"
            return types.SimpleNamespace(communicate=lambda: (text, None), returncode=0 if built else 1)
        oracle.subprocess.Popen = popen
        oracle.resolve_commit = lambda ref: ref
        oracle.queued_run_args = lambda args: []
        oracle.read_receipt = lambda directory: {"arm_exercised": None}
        oracle.merge_runs = lambda dirs, require_complete: (None, [])
        def native_plan(args, shas, out):
            """linux_run.sh overlay when the base already has head's oracle: build the base as it is (overlay.py)."""
            path = out / "overlay.json"
            path.write_text(json.dumps({"mode": "native", "facets": "v1", "buildSha": shas[0]}))
            return path
        oracle.queued_overlay = native_plan
        args = argparse.Namespace(suite=[opt["--suite"]], fresh=False, run_id=None, base=base, product="daemon")
        sides = tuple(oracle.Side(label, None, None, {}, ref, None) for label, ref in (("base", base), ("head", head)))
        try:
            return oracle.queued_diff(args, sides, [], out)
        except oracle.UsageError as error:
            print(error); return 2
    def show(sha, name):
        p = subprocess.run(["git", "show", f"{sha}:{name}"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        return p.stdout.strip() if p.returncode == 0 else None
    base, head, case = opt["--base"], opt["--head"], opt["--filter"]
    with open(out.parent.parent / "calls.txt", "a") as f:
        f.write(head + "\\n")
    if show(head, "broken.txt") is not None:
        print("build failed"); sys.exit(3)
    if show(head, "nobuild.txt") is not None:
        sys.exit(real_queued_diff_head_not_built(base, head, out))
    if show(head, "crash.txt") is not None:
        print("bad input"); sys.exit(2)
    if show(head, "weird.txt") is not None:
        (out / "comparison.json").write_text("[]"); sys.exit(1)
    a, b = show(base, "value.txt"), show(head, "value.txt")
    nondet = show(base, "nondet.txt") is not None
    flaky = show(head, "flaky.txt") is not None
    divergent = (a != b) or nondet
    doc = {"divergences": [{"journey": case, "step": "call", "checkpoint": "settled", "pointer": "/value", "a": a, "b": b}]
           if divergent else []}
    (out / "divergence.json").write_text(json.dumps(doc))
    comparison = {"divergent": [case] if divergent and not flaky else [], "explained": [],
                  "flaky_excluded": [case] if flaky else [], "not_comparable": {}, "refused": None,
                  "compared": 0 if flaky else 1, "ok": not divergent or flaky,
                  "divergence": str(out / "divergence.json")}
    (out / "comparison.json").write_text(json.dumps(comparison))
    sys.exit(1 if comparison["divergent"] else 0)
''')


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, stdout=subprocess.PIPE, text=True, env=ENV).stdout


class Batch:
    """A repository with a base commit and one commit per entry of `values` (value.txt, plus marker files)."""

    def __init__(self, root: Path, values: List[str], markers: Optional[Dict[int, List[str]]] = None,
                 base_markers: Optional[List[str]] = None) -> None:
        self.root = root
        self.repo = root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        (self.repo / "value.txt").write_text("v0\n")
        for name in base_markers or ():
            (self.repo / name).write_text("x\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "base")
        self.base = git(self.repo, "rev-parse", "HEAD").strip()
        self.shas: List[str] = []
        for i, value in enumerate(values, 1):
            (self.repo / "value.txt").write_text(value + "\n")
            (self.repo / "n.txt").write_text(f"{i}\n")
            for name in (markers or {}).get(i, ()):
                (self.repo / name).write_text("x\n")
            for name in ("broken.txt", "flaky.txt", "crash.txt", "nobuild.txt", "weird.txt"):
                if name not in (markers or {}).get(i, ()) and (self.repo / name).exists():
                    (self.repo / name).unlink()
            git(self.repo, "add", "-A")
            git(self.repo, "commit", "-q", "-m", f"c{i}")
            self.shas.append(git(self.repo, "rev-parse", "HEAD").strip())
        self.oracle = root / "fake_oracle.py"
        self.oracle.write_text(f"ORACLE_DIR = {str(HERE)!r}\n" + FAKE_ORACLE)

    def run(self, *extra: str, out: str = "out", good: Optional[str] = None, bad: Optional[str] = None) -> tuple:
        target = self.root / out
        proc = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--repo", str(self.repo), "--oracle", str(self.oracle), "--product",
             "daemon", "--case", CASE, "--good", good or self.base, "--bad", bad or self.shas[-1], "--out", str(target),
             "--json", *extra],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=ENV)
        result = json.loads(proc.stdout) if proc.stdout.strip().startswith("{") else None
        return proc, result

    def calls(self, out: str = "out") -> List[str]:
        return (self.root / out / "calls.txt").read_text().split()


class JudgeTest(unittest.TestCase):
    def test_verdicts(self) -> None:
        base = {"divergent": [], "explained": [], "flaky_excluded": [], "not_comparable": {}, "refused": None,
                "compared": 1, "ok": True}
        cases = [
            (1, {**base, "divergent": ["s/c"], "ok": False}, bc.BAD),
            (0, base, bc.GOOD),
            (0, {**base, "explained": ["s/c"]}, bc.GOOD),
            (0, {**base, "compared": 0, "flaky_excluded": ["s/c"]}, bc.SKIP),
            (3, {**base, "refused": "host-mismatch: os", "ok": False}, bc.SKIP),
            (3, None, bc.SKIP),
            (0, {**base, "not_comparable": {"s/c": "no baseline"}}, bc.SKIP),
            (0, {**base, "compared": 0, "ok": False}, bc.SKIP),
            (2, None, bc.STOP),
            (4, {**base, "ok": False}, bc.STOP),
        ]
        for code, comparison, expected in cases:
            with self.subTest(code=code, comparison=comparison):
                self.assertEqual(bc.judge(code, comparison, "s/c")[0], expected)


class BisectTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def batch(self, *args, **kw) -> Batch:
        sub = self.root / f"b{len(list(self.root.iterdir()))}"
        sub.mkdir()
        return Batch(sub, *args, **kw)

    def test_planted_divergence_is_named_and_the_checkout_is_untouched(self) -> None:
        # 10 commits; c6 changes the case's value and it stays changed.
        b = self.batch(["v0"] * 5 + ["v1"] * 5)
        head_before = git(b.repo, "rev-parse", "HEAD").strip()
        status_before = git(b.repo, "status", "--porcelain")
        proc, result = b.run()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(result["status"], "culprit")
        self.assertEqual(result["culprit"], {"sha": b.shas[5], "subject": "c6"})
        self.assertEqual(result["steps"][0]["sha"], b.shas[-1])  # the bad end first
        self.assertEqual(result["steps"][1]["sha"], b.base)  # then good against good
        culprit_step = next(s for s in result["steps"] if s["sha"] == b.shas[5])
        self.assertEqual(culprit_step["first_divergence"], {"step": "call", "checkpoint": "settled", "pointer": "/value"})
        self.assertLessEqual(len(result["steps"]), 2 + 4)  # log2(10) steps after the end checks
        self.assertEqual(git(b.repo, "rev-parse", "HEAD").strip(), head_before)
        self.assertEqual(git(b.repo, "status", "--porcelain"), status_before)
        self.assertEqual(git(b.repo, "worktree", "list", "--porcelain").count("worktree "), 1)
        self.assertNotIn("BISECT", " ".join(p.name for p in (b.repo / ".git").iterdir()))
        log = (b.root / "out" / "bisect.log").read_text()
        self.assertIn("git bisect start '--no-checkout' '--first-parent'", log)
        self.assertIn(f"# first bad commit: [{b.shas[5]}] c6", log)
        self.assertEqual(json.loads((b.root / "out" / "bisect.json").read_text())["culprit"]["sha"], b.shas[5])

    def test_deterministic(self) -> None:
        b = self.batch(["v0"] * 3 + ["v1"] * 7)
        _, first = b.run(out="one")
        _, second = b.run(out="two")
        strip = lambda r: [(s["sha"], s["verdict"], s["reason"]) for s in r["steps"]]  # noqa: E731
        self.assertEqual(strip(first), strip(second))
        self.assertEqual(first["culprit"], second["culprit"])
        self.assertEqual(b.calls("one"), b.calls("two"))

    def test_every_position(self) -> None:
        for k in (1, 2, 7, 10):
            with self.subTest(first_bad=k):
                b = self.batch(["v0"] * (k - 1) + ["v1"] * (11 - k))
                proc, result = b.run()
                self.assertEqual((proc.returncode, result["culprit"]["sha"]), (0, b.shas[k - 1]), proc.stderr)

    def test_one_commit_batch_needs_no_git_bisect(self) -> None:
        b = self.batch(["v1"])
        proc, result = b.run()
        self.assertEqual((proc.returncode, result["culprit"]["sha"], len(result["steps"])), (0, b.shas[0], 2))
        self.assertFalse((b.root / "out" / "bisect.log").exists())

    def test_not_reproducible(self) -> None:
        b = self.batch(["v0"] * 4 + ["v1", "v0"])  # a change and its revert: the batch head matches
        proc, result = b.run()
        self.assertEqual(proc.returncode, 1)
        self.assertEqual((result["status"], result["culprit"], len(result["steps"])), ("not-reproducible", None, 1))
        self.assertIn("matches at the bad end", result["reason"])

    def test_not_deterministic(self) -> None:
        b = self.batch(["v0"] * 4, base_markers=["nondet.txt"])
        proc, result = b.run()
        self.assertEqual(proc.returncode, 3)
        self.assertEqual(result["status"], "not-deterministic")
        no_check = b.run("--no-check-good", out="nocheck")[1]
        self.assertNotIn(b.base, [s["sha"] for s in no_check["steps"]])

    def test_skipped_commit_next_to_the_culprit_leaves_candidates(self) -> None:
        b = self.batch(["v0"] * 4 + ["v1"] * 4, markers={4: ["broken.txt"]})
        proc, result = b.run()
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertEqual(result["status"], "inconclusive")
        self.assertEqual({c["sha"] for c in result["candidates"]}, {b.shas[3], b.shas[4]})
        self.assertIn("skipped commits", result["reason"])

    def test_skipped_commit_away_from_the_culprit_is_harmless(self) -> None:
        b = self.batch(["v0"] * 6 + ["v1"] * 4, markers={2: ["flaky.txt"], 5: ["broken.txt"]})
        proc, result = b.run()
        self.assertEqual((proc.returncode, result["culprit"]["sha"]), (0, b.shas[6]), proc.stderr)

    def test_oracle_failure_stops(self) -> None:
        b = self.batch(["v0"] * 4 + ["v1"] * 4, markers={i: ["crash.txt"] for i in range(2, 7)})
        proc, result = b.run()
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertEqual(result["status"], "inconclusive")
        self.assertIn("stopped: oracle diff exited 2", result["reason"])

    def test_commit_that_does_not_build_is_skipped_by_the_real_queued_diff(self) -> None:
        # nobuild.txt runs oracle.py's own queued_diff with a head whose linux_run.sh build dies (no run dir).
        b = self.batch(["v0"] * 6 + ["v1"] * 4, markers={i: ["nobuild.txt"] for i in (3, 4, 5)})
        proc, result = b.run()
        self.assertEqual((proc.returncode, result["status"], result["culprit"]["sha"]), (0, "culprit", b.shas[6]),
                         proc.stderr)
        skipped = [s for s in result["steps"] if s["verdict"] == "skip"]
        self.assertTrue(skipped)
        self.assertEqual({s["exit"] for s in skipped}, {3})
        adjacent = self.batch(["v0"] * 6 + ["v1"] * 4, markers={6: ["nobuild.txt"]})
        proc, result = adjacent.run()
        self.assertEqual((proc.returncode, result["status"]), (3, "inconclusive"), proc.stderr)
        self.assertEqual({c["sha"] for c in result["candidates"]}, {adjacent.shas[5], adjacent.shas[6]})

    def test_step_that_raises_stops_instead_of_blaming_the_commit(self) -> None:
        # weird.txt writes a comparison.json that is not an object: judging it raises inside the step.
        b = self.batch(["v0"] * 6 + ["v1"] * 2, markers={i: ["weird.txt"] for i in range(2, 7)})
        proc, result = b.run()
        self.assertEqual((proc.returncode, result["status"], result["culprit"]), (3, "inconclusive", None), proc.stderr)
        self.assertIn("a step failed: AttributeError", result["reason"])

    def test_bad_end_untestable(self) -> None:
        b = self.batch(["v0", "v1"], markers={2: ["broken.txt"]})
        proc, result = b.run()
        self.assertEqual((proc.returncode, result["status"]), (3, "inconclusive"))
        self.assertIn("bad end could not be tested", result["reason"])

    def test_first_parent_names_the_merge(self) -> None:
        b = self.batch(["v0"] * 3)
        git(b.repo, "checkout", "-q", "-b", "side")
        for i, value in enumerate(("v0", "v1", "v1"), 1):
            (b.repo / "value.txt").write_text(value + "\n")
            (b.repo / "side.txt").write_text(f"{i}\n")
            git(b.repo, "add", "-A")
            git(b.repo, "commit", "-q", "-m", f"side{i}")
        side_culprit = git(b.repo, "rev-parse", "HEAD~1").strip()
        git(b.repo, "checkout", "-q", "main")
        (b.repo / "main.txt").write_text("m\n")
        git(b.repo, "add", "-A")
        git(b.repo, "commit", "-q", "-m", "main4")
        git(b.repo, "merge", "-q", "--no-ff", "-m", "merge side", "side")
        head = git(b.repo, "rev-parse", "HEAD").strip()
        proc, result = b.run(bad=head)
        self.assertEqual((proc.returncode, result["culprit"]), (0, {"sha": head, "subject": "merge side"}), proc.stderr)
        proc, result = b.run("--all-parents", bad=head, out="all")
        self.assertEqual((proc.returncode, result["culprit"]["sha"]), (0, side_culprit), proc.stderr)

    def test_usage_errors(self) -> None:
        b = self.batch(["v0", "v1"])
        for extra, kw, needle in (((), {"good": "HEAD", "bad": "HEAD"}, "same commit"),
                                  ((), {"good": "HEAD", "bad": "HEAD~1"}, "not an ancestor")):
            with self.subTest(needle=needle):
                proc, _ = b.run(*extra, **kw)
                self.assertEqual(proc.returncode, 2)
                self.assertIn(needle, proc.stderr)
        proc = subprocess.run([sys.executable, "-I", str(SCRIPT), "--repo", str(b.repo), "--oracle", str(b.oracle),
                               "--case", "nocase", "--good", b.base, "--bad", b.shas[-1], "--product", "daemon"],
                              check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=ENV)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("SUITE/CASE", proc.stderr)
        proc, _ = b.run(out=str(Path(b.repo / "inside")))
        self.assertEqual(proc.returncode, 2)

    def test_default_product_from_the_suite_map(self) -> None:
        self.assertEqual(bc.default_product(bc.DEFAULT_MAP, "daemon-ops"), "daemon")
        self.assertEqual(bc.default_product(bc.DEFAULT_MAP, "ax"), "app")
        with self.assertRaises(bc.UsageError):
            bc.default_product(bc.DEFAULT_MAP, "no-such-suite")


if __name__ == "__main__":
    unittest.main()
