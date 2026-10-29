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
neither (only a warning for a workflow main does not have: main's list cannot
change in the commit that moves a feat-cmux-next-only workflow off the minis,
and a stale entry is harmless). The other branch is read with `git show`; under GitHub Actions the
test fetches it (one shallow, blob-less fetch, then the files it reads) and
fails if it still cannot read it. Off CI a missing ref only skips that branch.

Which branch the tree is: CMUX_OWNED_POOL_BRANCH when set; under Actions the
branch the event targets (GITHUB_BASE_REF for a pull request, else
GITHUB_REF_NAME, a merge queue's gh-readonly-queue/<branch>/... included, and
main for any other branch); off CI the branch with fewer commits between it and
HEAD, skipped when either ref is missing. (Both branches carry a cmux-next.yml,
so no file tells them apart.)
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import owned_pool_sources as sources  # noqa: E402

FEAT = "feat-cmux-next"
BRANCHES = {"main": "origin/main", FEAT: "origin/feat-cmux-next"}
ON_CI = os.environ.get("GITHUB_ACTIONS") == "true"


def git(*args: str, stdin: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(ROOT), *args], input=stdin, capture_output=True, text=True)


def branch() -> str | None:
    """main or feat-cmux-next: the branch this tree is (or is going into), or None when it cannot be told."""
    named = os.environ.get("CMUX_OWNED_POOL_BRANCH")
    if named:
        return named
    if ON_CI:
        ref = os.environ.get("GITHUB_BASE_REF") or os.environ.get("GITHUB_REF_NAME") or ""
        if ref.startswith("gh-readonly-queue/"):
            ref = ref[len("gh-readonly-queue/"):].rsplit("/pr-", 1)[0]
        if ref in BRANCHES:
            return ref
        # A dispatch on a topic branch: judged as main's, the rescue's home.
        print(f"owned pool sources: {ref or 'no ref'} is neither branch; checking it as main", file=sys.stderr)
        return "main"
    ahead = {}
    for name, ref in BRANCHES.items():
        counted = git("rev-list", "--count", f"{ref}..HEAD")
        if counted.returncode != 0:
            return None
        ahead[name] = int(counted.stdout.strip() or 0)
    return min(ahead, key=ahead.get)


def on_feat() -> bool:
    return branch() == FEAT


def other_ref() -> str:
    return BRANCHES["main"] if on_feat() else BRANCHES[FEAT]


def has_ref(ref: str) -> bool:
    return git("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").returncode == 0


def fetch(ref: str) -> None:
    """The other branch's tip with no blobs, then the blobs of the files the detector reads, in two requests."""
    name = next((name for name, known in BRANCHES.items() if known == ref), None)
    if name is None:
        return
    git("fetch", "--no-tags", "--depth=1", "--filter=blob:none", "origin",
        f"+refs/heads/{name}:refs/remotes/{ref}")
    listing = git("ls-tree", ref, f"{sources.WORKFLOWS_DIR}/", "scripts/ci/")
    blobs = [line.split()[2] for line in listing.stdout.splitlines() if line.split()[1:2] == ["blob"]]
    if blobs:
        git("-c", "fetch.negotiationAlgorithm=noop", "fetch", "--no-tags", "--filter=blob:none", "--stdin",
            "origin", stdin="\n".join(blobs) + "\n")


class OwnedPoolSources(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.branch = branch()
        if cls.branch is None:
            raise unittest.SkipTest("cannot tell whether this tree is main or feat-cmux-next (a ref is missing); "
                                    "set CMUX_OWNED_POOL_BRANCH")
        cls.ref = other_ref()
        if not has_ref(cls.ref) and ON_CI:
            fetch(cls.ref)
        cls.other = sources.Tree(ROOT, cls.ref) if has_ref(cls.ref) else None
        here = sources.Tree(ROOT)
        cls.trees = [here] + ([cls.other] if cls.other is not None else [])
        rescue_tree = cls.rescue_tree = cls.other if on_feat() else here
        source = rescue_tree.read(sources.RESCUE_SCRIPT) if rescue_tree is not None else None
        cls.watched = sources.watched_paths(source) if source is not None else None
        cls.unrescued = sources.unrescued_paths(source) if source is not None else frozenset()
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
                missing = {path: why for path, why in owned.items()
                           if path not in self.watched and path not in self.unrescued}
                self.assertFalse(missing, "\n".join(
                    [f"{tree}: these workflows can take an owned pool but main's {sources.RESCUE_SCRIPT} does not "
                     "watch them, so a refused or stuck job of theirs is never moved; add each to "
                     "SIDE_WORKFLOW_PATHS on main (a feat-cmux-next-only one too), or to UNRESCUED_WORKFLOW_PATHS "
                     "with why a person re-runs it:"]
                    + [f"  {path}: {why}" for path, why in sorted(missing.items())]))

    def test_every_nightly_sign_verify_and_dmg_job_on_blacksmith_macos_is_rescued(self) -> None:
        # Run 40585960129 (2026-10-28): nightly-next's signer-verify sat on blacksmith-6vcpu-macos-26 for hours, and
        # being outside the rescue's table it also held the run's stalled final-DMG verify. The jobs are read from
        # each branch's nightly.yml, never listed here, so a new or renamed one fails until the rescue covers it.
        source = self.rescue_tree.read(sources.RESCUE_SCRIPT) if self.rescue_tree is not None else None
        if source is None:
            self.skipTest(f"main's {sources.RESCUE_SCRIPT} is not readable here ({self.ref} missing)")
        table = sources.sign_table(source)
        for tree in self.trees:
            text = tree.read(sources.NIGHTLY_WORKFLOW)
            if text is None:
                continue
            with self.subTest(tree=str(tree)):
                self.assertTrue(sources.sign_stall_candidates(text), f"{tree}: no sign or verify job found; "
                                "the detector no longer matches nightly.yml")
                missing = sources.uncovered_sign_jobs(text, table)
                self.assertFalse(missing, "\n".join(
                    [f"{tree}: these nightly.yml jobs can queue on a Blacksmith macOS label, but main's "
                     f"{sources.RESCUE_SCRIPT} cannot move them off a stalled one; add each to "
                     f"{sources.SIGN_TABLE_NAME} with the runs-on expression that gives its re-run another label:"]
                    + [f"  {job}: {why}" for job, why in sorted(missing.items())]))

    def test_the_sign_stall_detector(self) -> None:
        table = {"signer-verify": ("needs.pick.outputs.alternate",)}
        workflow = textwrap.dedent("""
            jobs:
              signer-verify:
                runs-on: ${{ github.run_attempt > 1 && needs.pick.outputs.alternate || 'blacksmith-6vcpu-macos-26' }}
              signer-dmg-image:
                runs-on: ${{ vars.MACOS_RUNNER_26 || 'macos-26' }}
              verify-final-dmg-nightly:
                runs-on: ${{ needs.pick.outputs.runner || 'blacksmith-12vcpu-macos-26' }}
              pick-nightly-sign-runner:
                runs-on: ${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-6vcpu-macos-26' || 'blacksmith-4vcpu-ubuntu-2404' }}
              build-nightly-app:
                runs-on: blacksmith-6vcpu-macos-26
              signer-build:
                runs-on: blacksmith-8vcpu-ubuntu-2404
        """)
        self.assertEqual(sorted(sources.sign_stall_candidates(workflow)),
                         ["signer-dmg-image", "signer-verify", "verify-final-dmg-nightly"])
        self.assertEqual(sources.uncovered_sign_jobs(workflow, {**table, "verify-final-dmg-nightly": ("x",)}), {
            "signer-dmg-image": f"not in {sources.SIGN_TABLE_NAME}",
            "verify-final-dmg-nightly": "its runs-on takes none of its alternate-label expressions on a re-run"})
        self.assertEqual(sources.sign_table(
            'A = "x"\nB = ("y "\n     "z")\nNIGHTLY_SIGN_ALTERNATES: dict = {"j": ("J", (A, B)), "k": ("K", (A,))}\n'),
            {"j": ("x", "y z"), "k": ("x",)})

    def test_every_watched_workflow_is_owned_on_some_branch(self) -> None:
        if self.watched is None or self.other is None:
            self.skipTest("both branches are needed to call an entry stale")
        found = set().union(*(set(owned) for owned in self.owned.values()))
        stale = (self.watched | self.unrescued) - found
        # A feat-cmux-next-only workflow moved off the minis leaves its entry in main's list, which no
        # commit can change together with it (the entry cannot go first either: main's own run would
        # find the workflow owned and unwatched). A stale entry only watches a run with no owned job.
        on_main = set(self.rescue_tree.workflows())
        feat_only = sorted(stale - on_main)
        if feat_only:
            print(f"::warning title=owned pool sources::{sources.RESCUE_SCRIPT} on main lists "
                  f"feat-cmux-next-only workflows that take no owned pool any more; remove them in a pull "
                  f"request to main: {feat_only}", file=sys.stderr)
        # An UNRESCUED entry makes the rescue do nothing, so a stale one changes no behaviour, and it is how a
        # workflow that only feat-cmux-next is about to make owned gets named on main first: main's list must
        # name it before that pull request's guard can pass, while neither branch owns it yet (release.yml's
        # signing picker, cmux#27066). So only a stale WATCHED entry fails; a stale unrescued one warns.
        waiting = sorted((stale & on_main) & set(self.unrescued))
        if waiting:
            print(f"::warning title=owned pool sources::{sources.RESCUE_SCRIPT} on main leaves to a person "
                  f"workflows that take no owned pool yet: {waiting}; remove any that will not", file=sys.stderr)
        self.assertFalse(sorted((stale & on_main) - set(self.unrescued)),
                         f"{sources.RESCUE_SCRIPT} watches workflows that take no owned pool on main or "
                         f"feat-cmux-next any more; remove them")
        self.assertFalse(self.watched & self.unrescued, "a workflow is both watched and left to a person")

    def test_the_markers_come_from_the_pool_code(self) -> None:
        # Both branches' policies: feat-cmux-next's drifted_runner_variables() also names LINUX_RUNNER and the
        # hosted-Mac fallbacks in a no-hosted-Mac guard, which once made ~130 workflows look owned on every PR.
        for tree in self.trees:
            with self.subTest(tree=str(tree)):
                markers = sources.Markers(tree)
                self.assertEqual(markers.literal, "glaeda-")
                for variable in ("CI_PR_POOL_OWNED", "CI_SIDE_LANE_RUNNER", "CI_LIGHT_LANE_RUNNER",
                                 "CI_SEED_TRUSTED_POOL", "CI_NIGHTLY_TRUSTED_RUNNER"):
                    self.assertIn(variable, markers.variables)
                for hosted in ("LINUX_RUNNER", "MACOS_RUNNER_15", "MACOS_RUNNER_26", "NIGHTLY_NEXT_TRAIN_RUNNER"):
                    self.assertNotIn(hosted, markers.variables)

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

    def scratch_tree(self, workflows: dict[str, str]) -> sources.Tree:
        """A tree holding these workflows and this checkout's pool code (the markers' source)."""
        root = Path(tempfile.mkdtemp(prefix="owned-pool-sources-"))
        self.addCleanup(shutil.rmtree, root, True)
        for path in (sources.POOL_SCRIPT, sources.POLICY_SCRIPT):
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / path, root / path)
        for name, text in workflows.items():
            (root / sources.WORKFLOWS_DIR).mkdir(parents=True, exist_ok=True)
            (root / sources.WORKFLOWS_DIR / name).write_text(textwrap.dedent(text), encoding="utf-8")
        return sources.Tree(root)

    def test_a_runs_on_is_followed_into_what_it_reads(self) -> None:
        owned = sources.owned_workflows(self.scratch_tree({
            # seed-derived-data.yml: the matrix comes from a job whose env reads the trusted pool variable.
            "matrix.yml": """
                on: push
                jobs:
                  decide:
                    runs-on: ubuntu-24.04
                    outputs:
                      matrix: ${{ steps.pick.outputs.matrix }}
                    steps:
                      - id: pick
                        env:
                          POOL: ${{ vars.CI_SEED_TRUSTED_POOL }}
                        run: echo "matrix=[\"$POOL\"]" >> "$GITHUB_OUTPUT"
                  seed:
                    needs: decide
                    strategy:
                      matrix: ${{ fromJSON(needs.decide.outputs.matrix) }}
                    runs-on: ${{ matrix.pool }}
                    steps:
                      - run: true
            """,
            # main-compile-probe.yml: a dispatch input whose default is an owned label.
            "input.yml": """
                on:
                  workflow_dispatch:
                    inputs:
                      runner:
                        default: glaeda-root-std-xcode-26.6
                jobs:
                  compile:
                    runs-on: ${{ inputs.runner }}
                    steps:
                      - run: true
            """,
            # A reusable workflow whose runs-on is an input with no owned default, and its two callers.
            "reusable.yml": """
                on:
                  workflow_call:
                    inputs:
                      runner:
                        type: string
                        default: ubuntu-24.04
                jobs:
                  build:
                    runs-on: ${{ inputs.runner }}
                    steps:
                      - run: true
            """,
            "caller.yml": """
                on: push
                jobs:
                  build:
                    uses: ./.github/workflows/reusable.yml
                    with:
                      runner: glaeda-side-light-xcode-26.6
            """,
            "plain-caller.yml": """
                on: push
                jobs:
                  build:
                    uses: ./.github/workflows/reusable.yml
                    with:
                      runner: blacksmith-6vcpu-macos-26
            """,
            "plain.yml": """
                on: push
                jobs:
                  decide:
                    runs-on: ubuntu-24.04
                    outputs:
                      runner: ${{ steps.pick.outputs.runner }}
                    steps:
                      - id: pick
                        env:
                          RUNNER: ${{ vars.MACOS_RUNNER_26 }}
                        run: echo "runner=$RUNNER" >> "$GITHUB_OUTPUT"
                  build:
                    needs: decide
                    runs-on: ${{ needs.decide.outputs.runner }}
                    steps:
                      - run: true
            """,
        }))
        paths = {path.rsplit("/", 1)[-1]: why for path, why in owned.items()}
        self.assertEqual(sorted(paths), ["caller.yml", "input.yml", "matrix.yml"], owned)
        self.assertIn("vars.CI_SEED_TRUSTED_POOL", paths["matrix.yml"])
        self.assertIn("input runner", paths["input.yml"])
        self.assertIn("reusable.yml", paths["caller.yml"])

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
