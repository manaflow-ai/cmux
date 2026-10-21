#!/usr/bin/env python3
"""The owned-pool rescue watches every workflow that can take an owned pool, on main and on feat-cmux-next.

ci-owned-pool-rescue.yml and scripts/ci/owned_pool_rescue.py run from main for
both branches, and the rescue acts only on the workflow files it lists
(owned_pool_rescue.WATCHED_WORKFLOW_PATHS). Run 39638669325
(cmux-next-base-autofix.yml, a feat-cmux-next push, 2026-10-21) had its Mac job
refused by a mini at job start, and nothing re-ran it: the workflow exists only
on feat-cmux-next and main's list did not name it.

scripts/ci/owned_pool_sources.py finds the owned workflows from their jobs'
runs-on. This test reads them from the working tree and from the other branch
(origin/feat-cmux-next on main, origin/main on feat-cmux-next), and the list
from main's copy of the rescue (the working tree on main, origin/main on
feat-cmux-next, since that is the copy that runs). It fails when an owned
workflow of either branch is not listed, and when a listed one is owned in
neither. The other branch is read with `git show`; under GitHub Actions the
test fetches it (one shallow, blob-less fetch, then the files it reads) and
fails if it still cannot read it. Off CI a missing ref only skips that branch.

The tree is feat-cmux-next's when it has .github/workflows/cmux-next.yml, a
workflow only that branch carries; CMUX_OWNED_POOL_OTHER_REF names the other
ref explicitly.
"""

from __future__ import annotations

import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import owned_pool_sources as sources  # noqa: E402

FEAT_ONLY_WORKFLOW = ".github/workflows/cmux-next.yml"
BRANCHES = {"origin/main": "main", "origin/feat-cmux-next": "feat-cmux-next"}
ON_CI = os.environ.get("GITHUB_ACTIONS") == "true"


def on_feat() -> bool:
    return (ROOT / FEAT_ONLY_WORKFLOW).is_file()


def other_ref() -> str:
    return os.environ.get("CMUX_OWNED_POOL_OTHER_REF") or ("origin/main" if on_feat() else "origin/feat-cmux-next")


def git(*args: str, stdin: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(ROOT), *args], input=stdin, capture_output=True, text=True)


def has_ref(ref: str) -> bool:
    return git("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").returncode == 0


def fetch(ref: str) -> None:
    """The other branch's tip with no blobs, then the blobs of the files the detector reads, in two requests."""
    branch = BRANCHES.get(ref)
    if branch is None:
        return
    git("fetch", "--no-tags", "--depth=1", "--filter=blob:none", "origin",
        f"+refs/heads/{branch}:refs/remotes/{ref}")
    listing = git("ls-tree", ref, f"{sources.WORKFLOWS_DIR}/", "scripts/ci/")
    blobs = [line.split()[2] for line in listing.stdout.splitlines() if line.split()[1:2] == ["blob"]]
    if blobs:
        git("-c", "fetch.negotiationAlgorithm=noop", "fetch", "--no-tags", "--filter=blob:none", "--stdin",
            "origin", stdin="\n".join(blobs) + "\n")


class OwnedPoolSources(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.ref = other_ref()
        if not has_ref(cls.ref) and ON_CI:
            fetch(cls.ref)
        cls.other = sources.Tree(ROOT, cls.ref) if has_ref(cls.ref) else None
        here = sources.Tree(ROOT)
        cls.trees = [here] + ([cls.other] if cls.other is not None else [])
        rescue_tree = cls.other if on_feat() else here
        source = rescue_tree.read(sources.RESCUE_SCRIPT) if rescue_tree is not None else None
        cls.watched = sources.watched_paths(source) if source is not None else None
        cls.owned = {str(tree): sources.owned_workflows(tree) for tree in cls.trees}

    def test_the_other_branch_is_read(self) -> None:
        if self.other is None:
            message = f"{self.ref} is not available, so its workflows were not checked"
            if ON_CI:
                self.fail(f"{message}; the guard job must be able to fetch it")
            self.skipTest(message)

    def test_every_owned_workflow_is_watched(self) -> None:
        if self.watched is None:
            self.skipTest(f"main's {sources.RESCUE_SCRIPT} is not readable here ({self.ref} missing)")
        for tree, owned in self.owned.items():
            with self.subTest(tree=tree):
                missing = {path: why for path, why in owned.items() if path not in self.watched}
                self.assertFalse(missing, "\n".join(
                    [f"{tree}: these workflows can take an owned pool but main's {sources.RESCUE_SCRIPT} does not "
                     "watch them, so a refused or stuck job of theirs is never moved; add each to "
                     "SIDE_WORKFLOW_PATHS on main (a feat-cmux-next-only one too):"]
                    + [f"  {path}: {why}" for path, why in sorted(missing.items())]))

    def test_every_watched_workflow_is_owned_on_some_branch(self) -> None:
        if self.watched is None or self.other is None:
            self.skipTest("both branches are needed to call an entry stale")
        found = set().union(*(set(owned) for owned in self.owned.values()))
        stale = sorted(self.watched - found)
        self.assertFalse(stale, f"{sources.RESCUE_SCRIPT} watches workflows that take no owned pool on main or "
                                f"feat-cmux-next any more; remove them: {stale}")

    def test_the_markers_come_from_the_pool_code(self) -> None:
        markers = sources.Markers(sources.Tree(ROOT))
        self.assertEqual(markers.literal, "glaeda-")
        for variable in ("CI_PR_POOL_OWNED", "CI_SIDE_LANE_RUNNER", "CI_LIGHT_LANE_RUNNER", "CI_SEED_TRUSTED_POOL",
                         "CI_NIGHTLY_TRUSTED_RUNNER"):
            self.assertIn(variable, markers.variables)
        self.assertNotIn("LINUX_RUNNER", markers.variables)
        self.assertNotIn("MACOS_RUNNER_26", markers.variables)

    def test_a_runs_on_is_owned_by_a_label_a_pool_variable_or_a_picker_output(self) -> None:
        markers = sources.Markers(sources.Tree(ROOT))
        owned = (
            "${{ vars.CI_PR_POOL_OWNED == '1' && 'glaeda-session-std-xcode-26.6' || 'blacksmith-6vcpu-macos-26' }}",
            "${{ github.run_attempt <= 2 && vars.CI_SIDE_LANE_RUNNER || 'blacksmith-6vcpu-macos-26' }}",
            "${{ fromJSON(needs.runner.outputs.runs_on) }}",
        )
        for runs_on in owned:
            self.assertTrue(markers.owned_runs_on(runs_on, {"runner"}), runs_on)
        for runs_on in ("blacksmith-4vcpu-ubuntu-2404", "${{ vars.LINUX_RUNNER || 'ubuntu-24.04' }}",
                        "${{ vars.MACOS_RUNNER_26 || 'macos-26' }}", "${{ needs.plan.outputs.runner }}"):
            self.assertFalse(markers.owned_runs_on(runs_on, {"runner"}), runs_on)

    def test_run_39638669325s_workflow_is_watched(self) -> None:
        # The base autofix's Mac exports take glaeda-session-std-xcode-26.6 on feat-cmux-next.
        if self.watched is None:
            self.skipTest("main's rescue is not readable here")
        self.assertIn(".github/workflows/cmux-next-base-autofix.yml", self.watched)
        feat = sources.Tree(ROOT) if on_feat() else self.other if self.ref == "origin/feat-cmux-next" else None
        if feat is None:
            self.skipTest("feat-cmux-next's workflows are not readable here")
        self.assertIn(".github/workflows/cmux-next-base-autofix.yml", self.owned[str(feat)])

if __name__ == "__main__":
    unittest.main()
