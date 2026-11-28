#!/usr/bin/env python3
"""A pull request head that changes no cmux-tui tree-key input builds no cmux-tui artifacts.

interim-coord, 2026-11-21 21:34Z: "have the musl builds path-filtered on PRs and main, and run the full
set only on merge queue or nightly."

1. scripts/ci/cmux_tui_branch_inputs.py, run in a blob:none depth-1 partial clone (what push-gate's
   checkout makes), answers unchanged=true for a branch whose tree key equals its merge base's with
   feat-cmux-next, even after feat-cmux-next moved its own tree on; unchanged=true too for a branch that
   changes a tree-key input after feat-cmux-next moved its tree key (no route reads that head's tree;
   BASE-MOVED); unchanged=false for a branch cut from the current base that changes a tree-key input, one
   that carries Cmux-Daemon-Tests: run, a trunk ref, one it cannot read, and a base-moved one with
   CMUX_TUI_BRANCH_BASE_MOVED_GATE=0.
2. push-gate runs it after the superseded check, from a blob:none checkout, and tree-preflight stops on
   its unchanged=true; a skipped or failed gate still builds.

Run: python3 tests/test_cmux_tui_branch_inputs.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"
SCRIPTS = ("cmux_tui_branch_inputs.py", "cmux_tui_tree_key.py", "cmux_tui_superseded_push.py")
INPUTS = "tree cmux-tui\nblob scripts/ci/cargo-groups.sh\n"
ENV = {**{k: v for k, v in os.environ.items() if not k.startswith("GIT_")},
       "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
       "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True,
                          env=ENV).stdout.strip()


def write(repo: Path, path: str, text: str) -> None:
    (repo / path).parent.mkdir(parents=True, exist_ok=True)
    (repo / path).write_text(text)


class BranchInputsScriptTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = Path(tempfile.mkdtemp())
        upstream, seed = cls.tmp / "upstream.git", cls.tmp / "seed"
        git(cls.tmp, "init", "--quiet", "--bare", "-b", "feat-cmux-next", str(upstream))
        git(upstream, "config", "uploadpack.allowFilter", "true")
        git(upstream, "config", "uploadpack.allowAnySHA1InWant", "true")
        cls.url = upstream.resolve().as_uri()
        git(cls.tmp, "init", "--quiet", "-b", "feat-cmux-next", str(seed))
        write(seed, "scripts/cmux-next/cmux-tui-tree-inputs.txt", INPUTS)
        write(seed, "scripts/ci/cargo-groups.sh", "groups\n")
        write(seed, "cmux-tui/src/lib.rs", "fn a() {}\n")
        write(seed, "docs/readme.md", "hi\n")
        git(seed, "add", "-A")
        git(seed, "commit", "--quiet", "-m", "base")
        cls.heads: dict[str, str] = {}

        def branch(name: str, path: str, text: str, message: str = "change") -> None:
            git(seed, "checkout", "--quiet", "-b", name, "feat-cmux-next")
            write(seed, path, text)
            git(seed, "commit", "--quiet", "-am", message)
            cls.heads[name] = git(seed, "rev-parse", "HEAD")
            git(seed, "checkout", "--quiet", "feat-cmux-next")

        branch("fix/docs", "docs/readme.md", "docs only\n")
        branch("fix/code", "cmux-tui/src/lib.rs", "fn b() {}\n")
        branch("fix/script", "scripts/ci/cargo-groups.sh", "other groups\n")
        branch("fix/trailer", "docs/readme.md", "docs\n", "docs\n\nCmux-Daemon-Tests: run")
        # feat-cmux-next-* heads: the superseded check keeps them as integration refs.
        branch("feat-cmux-next-docs", "docs/readme.md", "integration docs\n")
        branch("feat-cmux-next-code", "cmux-tui/src/lib.rs", "fn integration() {}\n")
        # feat-cmux-next moves its own tree on after the branches were cut.
        write(seed, "cmux-tui/src/lib.rs", "fn base_moved() {}\n")
        git(seed, "commit", "--quiet", "-am", "base moves")
        # Cut from the moved base: its merge keeps its own key, so the route reads its tree.
        branch("fix/code-fresh", "cmux-tui/src/lib.rs", "fn fresh() {}\n")
        branch("fix/trailer-code", "cmux-tui/src/lib.rs", "fn c() {}\n", "code\n\nCmux-Daemon-Tests: run")
        # feat-cmux-next moves on with a change outside the tree-key inputs: the fresh branch still builds.
        write(seed, "docs/readme.md", "base docs\n")
        git(seed, "commit", "--quiet", "-am", "base docs")
        git(seed, "push", "--quiet", cls.url, "--all")

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_gate(self, ref: str, sha: str, base: str = "feat-cmux-next", **env: str) -> tuple[str, str]:
        """push-gate's checkout: a blob:none depth-1 partial clone of SHA, with the three scripts beside it."""
        clone = Path(tempfile.mkdtemp(dir=self.tmp))
        git(clone, "init", "--quiet")
        git(clone, "remote", "add", "origin", self.url)
        git(clone, "config", "remote.origin.promisor", "true")
        git(clone, "config", "remote.origin.partialclonefilter", "blob:none")
        git(clone, "fetch", "--quiet", "--depth=1", "--filter=blob:none", "origin", sha)
        for name in SCRIPTS:
            write(clone, f"scripts/ci/{name}", (ROOT / "scripts/ci" / name).read_text())
        output = clone / "out"
        result = subprocess.run([sys.executable, str(clone / "scripts/ci/cmux_tui_branch_inputs.py"),
                                 "--ref", ref, "--sha", sha, "--base", base],
                                capture_output=True, text=True, env={**ENV, **env, "GITHUB_OUTPUT": str(output)},
                                timeout=120, check=True)
        return output.read_text().strip(), result.stdout

    def test_a_docs_only_branch_is_unchanged_though_the_base_moved(self) -> None:
        out, log = self.run_gate("refs/heads/fix/docs", self.heads["fix/docs"])
        self.assertEqual(out, "unchanged=true", log)

    def test_a_branch_cut_from_the_current_tree_that_changes_a_tree_input_builds(self) -> None:
        out, log = self.run_gate("refs/heads/fix/code-fresh", self.heads["fix/code-fresh"])
        self.assertEqual(out, "unchanged=false", log)
        self.assertIn("differs", log)

    def test_a_tree_input_change_on_a_base_that_moved_its_tree_builds_nothing(self) -> None:
        for name in ("fix/code", "fix/script"):
            with self.subTest(branch=name):
                out, log = self.run_gate(f"refs/heads/{name}", self.heads[name])
                self.assertEqual(out, "unchanged=true", log)
                self.assertIn("moved its tree key", log)
                self.assertIn("Update the branch", log)

    def test_the_base_moved_gate_has_its_own_undo(self) -> None:
        out, log = self.run_gate("refs/heads/fix/code", self.heads["fix/code"], CMUX_TUI_BRANCH_BASE_MOVED_GATE="0")
        self.assertEqual(out, "unchanged=false", log)
        self.assertIn("differs", log)

    def test_the_daemon_tests_trailer_builds(self) -> None:
        for name in ("fix/trailer", "fix/trailer-code"):
            with self.subTest(branch=name):
                out, log = self.run_gate(f"refs/heads/{name}", self.heads[name])
                self.assertEqual(out, "unchanged=false", log)

    def test_a_feat_cmux_next_prefixed_head_that_changes_no_tree_input_is_unchanged(self) -> None:
        out, log = self.run_gate("refs/heads/feat-cmux-next-docs", self.heads["feat-cmux-next-docs"])
        self.assertEqual(out, "unchanged=true", log)

    def test_a_feat_cmux_next_prefixed_head_that_changes_a_tree_input_builds_though_the_base_moved(self) -> None:
        # Only the unchanged-key rule: BASE-MOVED never skips an integration-prefixed head.
        out, log = self.run_gate("refs/heads/feat-cmux-next-code", self.heads["feat-cmux-next-code"])
        self.assertEqual(out, "unchanged=false", log)
        self.assertIn("differs", log)

    def test_trunk_refs_build(self) -> None:
        for ref in ("refs/heads/feat-cmux-next", "refs/heads/main", "refs/heads/nightly-next",
                    "refs/heads/release-next", "refs/heads/cmux-tui-pin-abc"):
            with self.subTest(ref=ref):
                out, _ = self.run_gate(ref, self.heads["fix/docs"])
                self.assertEqual(out, "unchanged=false")

    def test_a_read_failure_builds(self) -> None:
        # No feat-cmux-next to find a merge base on: the run builds as before.
        out, log = self.run_gate("refs/heads/fix/docs", self.heads["fix/docs"], base="no-such-branch")
        self.assertEqual(out, "unchanged=false", log)
        self.assertIn("could not tell", log)


class BranchInputsWiringTest(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]

    def test_push_gate_runs_it_after_the_superseded_check_from_a_partial_clone(self) -> None:
        gate = self.jobs["push-gate"]
        ids = [step.get("id") for step in gate["steps"]]
        self.assertLess(ids.index("stale"), ids.index("inputs"))
        step = gate["steps"][ids.index("inputs")]
        self.assertIn("scripts/ci/cmux_tui_branch_inputs.py", step["run"])
        self.assertIn("steps.stale.outputs.stale != 'true'", step["if"])
        self.assertIn("vars.CMUX_TUI_BRANCH_INPUT_GATE", step["if"])
        self.assertEqual(step["env"]["CMUX_TUI_BRANCH_BASE_MOVED_GATE"], "${{ vars.CMUX_TUI_BRANCH_BASE_MOVED_GATE }}")
        checkout = gate["steps"][0]["with"]
        self.assertEqual(checkout["filter"], "blob:none")
        for name in SCRIPTS:
            self.assertIn(f"scripts/ci/{name}", checkout["sparse-checkout"])
        self.assertEqual(gate["outputs"]["inputs_unchanged"], "${{ steps.inputs.outputs.unchanged }}")
        self.assertEqual(gate.get("continue-on-error"), True)
        # feat-cmux-next-* heads take the gate; trunk refs and pins never do.
        self.assertNotIn("'refs/heads/feat-cmux-next-'", gate["if"])
        for ref in ("refs/heads/main", "refs/heads/feat-cmux-next", "refs/heads/nightly-next", "refs/heads/release-next"):
            self.assertIn(f"github.ref != '{ref}'", gate["if"])
        self.assertIn("!startsWith(github.ref, 'refs/heads/cmux-tui-pin-')", gate["if"])

    def test_preflight_stops_only_on_unchanged_true(self) -> None:
        condition = self.jobs["tree-preflight"]["if"]
        self.assertIn("needs.push-gate.outputs.inputs_unchanged != 'true'", condition)
        self.assertNotIn("needs.push-gate.result", condition)


if __name__ == "__main__":
    unittest.main()
