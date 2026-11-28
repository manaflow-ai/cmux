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
and a stale entry is harmless). The other branch is read with `git show` at origin's current tip,
fetched fresh on every run into a private ref (refs/cmux-owned-pool-sources/<branch>), never from
a remote-tracking ref a reused checkout may hold from an earlier fetch: a cmux-ci fast-checks run
read a stale origin/main from its warm disk and failed with "owned_pool_rescue.py defines no
WATCHED_WORKFLOW_PATHS". Under GitHub Actions, in a checkout that is already shallow and blob-less,
the fetch is one shallow, blob-less fetch, then the files it reads, and the test fails if it still
cannot read the branch. Any other checkout (a full-history CI checkout too: other tests clone it)
gets a plain fetch of that branch, never made shallow or partial by it, and off CI a fetch that
fails (offline, no origin) only skips that branch.

Which branch the tree is: CMUX_OWNED_POOL_BRANCH when set; under Actions the
branch the event targets (GITHUB_BASE_REF for a pull request, else
GITHUB_REF_NAME, a merge queue's gh-readonly-queue/<branch>/... included, and
main for any other branch), unless HEAD is not GITHUB_SHA: then the event's ref
says nothing about the tree. cmux-ci fast checks dispatch on main and check out
a snapshot of any branch, so a feat-cmux-next tree was judged as main and its own
rescue (which has no WATCHED_WORKFLOW_PATHS) was read as main's. Such a tree, and
any tree off CI, is the branch whose freshly fetched tip changes the fewest paths
under .github/workflows and scripts/ci against it (a snapshot has no history to
count commits in), skipped when neither branch can be fetched. (Both branches
carry a cmux-next.yml, so no single file tells them apart.)

With both trees read, it also holds the two copies of each workflow both branches carry (a twin) to one
set of runner labels and one GITHUB_TOKEN floor per job (scripts/ci/workflow_twins.py; the jobs that already
differed are scripts/ci/workflow_twins_known_drift.tsv, and a new one fails): cmux#63743 moved main's
ui-proof-stale-sweep.yml and feat-cmux-next's copy stayed on cmux-linux with no floor.
"""

from __future__ import annotations

import functools
import json
import os
import re
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
import workflow_twins  # noqa: E402  (main and feat-cmux-next copies of one workflow agree)
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

FEAT = "feat-cmux-next"
BRANCHES = {"main": "origin/main", FEAT: "origin/feat-cmux-next"}
ON_CI = os.environ.get("GITHUB_ACTIONS") == "true"


# The checkout every git() call runs in; FetchLeavesTheCheckoutAlone points it at a fixture.
REPO = ROOT


def git(*args: str, stdin: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(REPO), *args], input=stdin, capture_output=True, text=True)


def event_describes_tree() -> bool:
    """Whether the Actions event's ref is this tree's: a pull request's base always is; otherwise HEAD is GITHUB_SHA."""
    if os.environ.get("GITHUB_BASE_REF"):
        return True
    head = git("rev-parse", "HEAD").stdout.strip()
    return bool(head) and head == os.environ.get("GITHUB_SHA")


def nearest_branch() -> str | None:
    """The branch whose fresh tip changes the fewest workflow and CI script paths against HEAD; None when neither fetches.

    Compares trees only, so it needs no blobs.
    """
    changed = {}
    for name in BRANCHES:
        fresh = fetch_tip(name)
        if fresh is None:
            continue
        diff = git("diff", "--no-renames", "--name-only", fresh, "HEAD", "--", sources.WORKFLOWS_DIR, "scripts/ci")
        if diff.returncode == 0:
            changed[name] = len(diff.stdout.splitlines())
    return min(changed, key=changed.get) if changed else None


@functools.cache
def branch() -> str | None:
    """main or feat-cmux-next: the branch this tree is (or is going into), or None when it cannot be told."""
    named = os.environ.get("CMUX_OWNED_POOL_BRANCH")
    if named:
        return named
    if ON_CI and event_describes_tree():
        ref = os.environ.get("GITHUB_BASE_REF") or os.environ.get("GITHUB_REF_NAME") or ""
        if ref.startswith("gh-readonly-queue/"):
            ref = ref[len("gh-readonly-queue/"):].rsplit("/pr-", 1)[0]
        if ref in BRANCHES:
            return ref
        # A dispatch on a topic branch: judged as main's, the rescue's home.
        print(f"owned pool sources: {ref or 'no ref'} is neither branch; checking it as main", file=sys.stderr)
        return "main"
    nearest = nearest_branch()
    if nearest is None and ON_CI:
        print("owned pool sources: neither branch could be fetched; checking the tree as main", file=sys.stderr)
        return "main"
    return nearest


def on_feat() -> bool:
    return branch() == FEAT


def other_ref() -> str:
    return BRANCHES["main"] if on_feat() else BRANCHES[FEAT]


def has_ref(ref: str) -> bool:
    return git("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").returncode == 0


# Where fetch() puts origin's fresh tip of a branch. Not refs/remotes/origin/*: those may be left
# over from an earlier fetch (a warm checkout, a developer's clone) and name an old commit.
PRIVATE_REFS = "refs/cmux-owned-pool-sources/"


@functools.cache
def is_shallow() -> bool:
    return git("rev-parse", "--is-shallow-repository").stdout.strip() == "true"


@functools.cache
def is_partial() -> bool:
    """Whether this checkout is a partial clone (actions/checkout's filter: blob:none), whose blobs come on demand."""
    if git("config", "--get", "extensions.partialClone").stdout.strip():
        return True
    promisors = git("config", "--get-regexp", r"^remote\..*\.promisor$").stdout.splitlines()
    return any(line.split()[-1] == "true" for line in promisors if line.split())


def already_shallow_and_partial() -> bool:
    """Whether a shallow blob-less fetch leaves this checkout as it was: already shallow and a partial clone."""
    return is_shallow() and is_partial()


@functools.cache
def fetch_tip(name: str) -> str | None:
    """origin's current tip of branch name, as a private ref; None when it cannot be fetched. Once per run.

    Under Actions, in a checkout that is already shallow and blob-less, the tip comes at depth 1 with
    no blobs (fetch() adds the ones the test reads). Anywhere else it is a plain fetch of that one
    branch: --depth would make a full checkout shallow, and --filter would make it a partial clone.
    The checkout is the job's own, shared with every test running beside this one: a --depth=1
    fetch into car guards' full blob-less checkout wrote .git/shallow under
    test_cmux_next_guards_notices_pair.py, whose `git clone --shared` of it then fell back to
    upload-pack and died on a missing blob ("could not fetch ... from promisor remote", cmux#40871).
    """
    private = PRIVATE_REFS + name
    git("update-ref", "-d", private)
    if ON_CI and already_shallow_and_partial():
        git("fetch", "--no-tags", "--depth=1", "--filter=blob:none", "origin", f"+refs/heads/{name}:{private}")
    else:
        git("fetch", "--no-tags", "origin", f"+refs/heads/{name}:{private}")
    return private if has_ref(private) else None


@functools.cache
def fetch(ref: str) -> str | None:
    """fetch_tip() of the branch ref names, with the blobs of the files the detector reads; None when either fails."""
    name = next((name for name, known in BRANCHES.items() if known == ref), None)
    if name is None:
        return None
    private = fetch_tip(name)
    if private is None:
        return None
    if ON_CI and is_partial():
        # A tip whose files cannot all be read is no tip: a missing blob would read as a missing file.
        listing = git("ls-tree", private, f"{sources.WORKFLOWS_DIR}/", "scripts/ci/")
        if listing.returncode != 0:
            return None
        blobs = [line.split()[2] for line in listing.stdout.splitlines() if line.split()[1:2] == ["blob"]]
        if blobs and git("-c", "fetch.negotiationAlgorithm=noop", "fetch", "--no-tags", "--filter=blob:none",
                         "--stdin", "origin", stdin="\n".join(blobs) + "\n").returncode != 0:
            return None
    return private


class OwnedPoolSources(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        # RUNNER_POOLS is the Blacksmith route set, not an owned mini pool. The
        # policy validator also inspects its JSON members, so exclude that
        # routing variable from this guard's owned marker before scanning both
        # branch trees.
        policy_variables = sources.policy_variables
        sources.policy_variables = lambda source: policy_variables(source) - {"RUNNER_POOLS"}
        cls.addClassCleanup(setattr, sources, "policy_variables", policy_variables)
        cls.branch = branch()
        if cls.branch is None:
            raise unittest.SkipTest("cannot tell whether this tree is main or feat-cmux-next (a ref is missing); "
                                    "set CMUX_OWNED_POOL_BRANCH")
        cls.ref = other_ref()
        fresh = fetch(cls.ref)
        cls.other = sources.Tree(ROOT, fresh) if fresh is not None else None
        here = sources.Tree(ROOT)
        cls.trees = [here] + ([cls.other] if cls.other is not None else [])
        rescue_tree = cls.rescue_tree = cls.other if on_feat() else here
        source = rescue_tree.read(sources.RESCUE_SCRIPT) if rescue_tree is not None else None
        cls.watched = sources.watched_paths(source) if source is not None else None
        cls.unrescued = sources.unrescued_paths(source) if source is not None else frozenset()
        if on_feat():
            # feat-cmux-next's own copy may acknowledge a feat-only unrescued workflow while main takes no merges.
            # An unrescued entry changes no behaviour (the rescue acts only on watched paths), so either copy
            # may hold it; watched paths still come from main's copy, the one that runs.
            own = here.read(sources.RESCUE_SCRIPT)
            if own is not None and sources.UNRESCUED_NAME in own:
                cls.unrescued = cls.unrescued | sources.unrescued_paths(own)
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
        # A stale watch for a route that moved from an owned marker to a
        # declared Blacksmith pool is harmless: the rescue never sees an
        # owned label in that workflow. Keep the warning above for visibility,
        # but do not fail the source guard on this mechanical route migration.
        pool_only_stale = {
            path for path in stale & on_main
            if any("fromJSON(vars.RUNNER_POOLS)." in (tree.read(path) or "") for tree in self.trees)
        }
        self.assertFalse(sorted((stale & on_main) - set(self.unrescued) - pool_only_stale),
                         f"{sources.RESCUE_SCRIPT} watches workflows that take no owned pool on main or "
                         f"feat-cmux-next any more; remove them")
        self.assertFalse(self.watched & self.unrescued, "a workflow is both watched and left to a person")

    def test_twin_workflows_share_runner_and_floor(self) -> None:
        # scripts/ci/workflow_twins.py: a workflow both branches hold runs each job on one runner and reads one
        # token floor; cmux#63743 moved main's ui-proof-stale-sweep.yml and feat-cmux-next's copy stayed behind.
        if self.other is None:
            self.skipTest(f"{self.ref} is not available, so no twin was compared")
        lines = workflow_twins.drift(sources.Tree(ROOT), self.other)
        self.assertFalse(lines, "\n".join([workflow_twins.HINT] + lines))

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


def _sweep(runs_on: str, floor: bool, floor_dir: str = "floor/", jobs: tuple[str, ...] = ("sweep",)) -> str:
    """A ui-proof-stale-sweep.yml-shaped workflow: one runner, the token floor read or not."""
    text = ['on:', '  schedule:', '    - cron: "17 * * * *"', '  workflow_dispatch:', 'jobs:']
    for job in jobs:
        text += [f'  {job}:', f'    runs-on: {runs_on}', '    steps:', '      - uses: actions/checkout@v6']
        if floor:
            text += ['      - id: job-floor',
                     f'        run: python3 -I {floor_dir}scripts/ci/job_token_floor.py ui-proof-stale-sweep/{job}']
        text += ['      - run: python3 -I scripts/ci/ui_proof_verdict.py sweep']
    return "\n".join(text) + "\n"


JIT = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-secret-jit-x64' }}"


class WorkflowTwins(unittest.TestCase):
    """scripts/ci/workflow_twins.py: a workflow on both branches runs on one runner and reads one token floor."""

    def tree(self, workflows: dict[str, str]) -> sources.Tree:
        root = Path(tempfile.mkdtemp(prefix="workflow-twins-"))
        self.addCleanup(shutil.rmtree, root, True)
        (root / sources.WORKFLOWS_DIR).mkdir(parents=True)
        for name, text in workflows.items():
            (root / sources.WORKFLOWS_DIR / name).write_text(text, encoding="utf-8")
        return sources.Tree(root)

    def test_cmux_63743s_drift_is_named(self) -> None:
        # main took the secret JIT label and the floor (cmux#63743); feat-cmux-next's copy kept cmux-linux, no floor.
        main = self.tree({"ui-proof-stale-sweep.yml": _sweep(JIT, True)})
        feat = self.tree({"ui-proof-stale-sweep.yml": _sweep("cmux-linux", False)})
        lines = workflow_twins.drift(feat, main, known=set())
        self.assertEqual(len(lines), 1, lines)
        self.assertIn("ui-proof-stale-sweep.yml job sweep", lines[0])
        self.assertIn("runs-on", lines[0])
        self.assertIn("floor", lines[0])
        self.assertIn("cmux-gcp-secret-jit-x64", lines[0])

    def test_matching_copies_pass_wherever_each_checks_out_the_floor(self) -> None:
        main = self.tree({"ui-proof-stale-sweep.yml": _sweep(JIT, True, floor_dir="floor/")})
        feat = self.tree({"ui-proof-stale-sweep.yml": _sweep(JIT, True, floor_dir="")})
        self.assertEqual(workflow_twins.drift(feat, main, known=set()), [])
        self.assertEqual(workflow_twins.drift(main, feat, known=set()), [])

    def test_a_floor_for_another_tag_is_drift(self) -> None:
        main = self.tree({"a.yml": _sweep(JIT, True)})
        feat = self.tree({"a.yml": _sweep(JIT, True).replace("ui-proof-stale-sweep/sweep", "other/sweep")})
        self.assertEqual(len(workflow_twins.drift(feat, main, known=set())), 1)

    def test_two_workflows_on_one_path_are_no_twin(self) -> None:
        # main's nightly.yml is classic's build and feat-cmux-next's is NEXT's: other job ids, never compared.
        main = self.tree({"nightly.yml": _sweep("cmux-linux", False, jobs=("build", "sign"))})
        feat = self.tree({"nightly.yml": _sweep(JIT, True, jobs=("build", "notarize"))})
        self.assertEqual(workflow_twins.drift(feat, main, known=set()), [])

    def test_a_path_on_one_branch_only_is_no_twin(self) -> None:
        main = self.tree({"a.yml": _sweep(JIT, True)})
        feat = self.tree({"b.yml": _sweep("cmux-linux", False)})
        self.assertEqual(workflow_twins.drift(feat, main, known=set()), [])

    def test_each_branchs_clauses_around_the_labels_are_its_own(self) -> None:
        # feat-cmux-next's fork-PR fallback and main's overflow variable land on the same labels: one runner.
        feat_on = ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == "
                   "'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && "
                   "'ubuntu-24.04' || 'cmux-linux' }}")
        main_on = ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_OVERFLOW_LINUX || "
                   "'cmux-linux' }}")
        main = self.tree({"a.yml": _sweep(main_on, False)})
        feat = self.tree({"a.yml": _sweep(feat_on, False)})
        self.assertEqual(workflow_twins.drift(feat, main, known=set()), [])

    def test_known_drift_passes_and_an_entry_that_agrees_again_is_named_not_failed(self) -> None:
        main = self.tree({"a.yml": _sweep(JIT, True)})
        feat = self.tree({"a.yml": _sweep("cmux-linux", True)})
        known = {(f"{sources.WORKFLOWS_DIR}/a.yml", "sweep")}
        self.assertEqual(workflow_twins.drift(feat, main, known=known), [])
        self.assertEqual(workflow_twins.agreed(feat, main, known=known), [])
        same = self.tree({"a.yml": _sweep(JIT, True)})
        self.assertEqual(workflow_twins.drift(same, main, known=known), [])
        self.assertEqual(workflow_twins.agreed(same, main, known=known), [f"{sources.WORKFLOWS_DIR}/a.yml\tsweep"])

    def test_the_known_drift_file_reads_back(self) -> None:
        rows = workflow_twins.known_drift()
        self.assertTrue(all(path.startswith(f"{sources.WORKFLOWS_DIR}/") for path, _ in rows), rows)
        self.assertNotIn((f"{sources.WORKFLOWS_DIR}/ui-proof-stale-sweep.yml", "sweep"), rows,
                         "cmux#63743's twin is fixed here; it is no known drift")


# A main twin is a workflow both branches carry because main's copy is the one that runs (a schedule fires the
# default branch's copy) while it reads feat-cmux-next's scripts. Its header says so ("main twin", "Main-Twin").
# 2026-11-28: cmux#63743 moved main's ui-proof-stale-sweep.yml onto the secret JIT label and added its GITHUB_TOKEN
# floor, and feat-cmux-next's copy (cmux#63625) kept `runs-on: cmux-linux` with no floor, so a dispatch on
# feat-cmux-next ran the sweep where main's guards refuse it. The twins must agree job by job on where a job runs
# and whether it reads the floor; anything else may differ (the pre-push gate, scripts/cmux-next/prepush-gate.py,
# judges their steps and schedules).
TWIN_MARK = re.compile(r"(?i)\bmain[- ]twin\b")


def declares_twin(text: str) -> bool:
    """Whether a workflow's header (its comment lines before `jobs:`) calls it a main twin: a step named for the
    pre-push gate's main-twin test (ci-guards.yml) is no twin."""
    for line in text.splitlines():
        if line.startswith("jobs:"):
            return False
        if line.lstrip().startswith("#") and TWIN_MARK.search(line):
            return True
    return False


def twin_jobs(text: str) -> dict[str, tuple[str, bool]]:
    """{job: (its runs-on, whether it runs job_token_floor.py)} of a workflow's TEXT."""
    import yaml  # noqa: PLC0415
    document = yaml.safe_load(text) or {}
    jobs = document.get("jobs") if isinstance(document, dict) else None
    found = {}
    for name, job in (jobs or {}).items():
        if isinstance(job, dict):
            runs_on = job.get("runs-on")
            found[str(name)] = (json.dumps(runs_on, sort_keys=True) if not isinstance(runs_on, str)
                                else " ".join(runs_on.split()), "job_token_floor.py" in yaml.safe_dump(job))
    return found


def twin_drift(here: str, there: str) -> list[str]:
    """How two copies of a main twin differ in where a job runs or whether it reads the floor."""
    mine, theirs = twin_jobs(here), twin_jobs(there)
    drift = []
    for job in sorted(set(mine) & set(theirs)):
        (runs_here, floor_here), (runs_there, floor_there) = mine[job], theirs[job]
        if runs_here != runs_there:
            drift.append(f"job {job} runs-on {runs_here!r} here, {runs_there!r} on the other branch")
        if floor_here != floor_there:
            drift.append(f"job {job} {'reads' if floor_here else 'does not read'} the GITHUB_TOKEN floor here "
                         f"(scripts/ci/job_token_floor.py), the other branch's copy "
                         f"{'does' if floor_there else 'does not'}")
    return drift


class MainTwinsAgree(unittest.TestCase):
    """Both copies of a main twin run each job on the same runner, with the same GITHUB_TOKEN floor."""

    @classmethod
    def setUpClass(cls) -> None:
        if branch() is None:
            raise unittest.SkipTest("cannot tell whether this tree is main or feat-cmux-next; set "
                                    "CMUX_OWNED_POOL_BRANCH")
        cls.ref = other_ref()
        fresh = fetch(cls.ref)
        if fresh is None:
            if ON_CI:
                raise AssertionError(f"{cls.ref} is not available, so the main twins were not compared")
            raise unittest.SkipTest(f"{cls.ref} is not available")
        cls.here, cls.other = sources.Tree(ROOT), sources.Tree(ROOT, fresh)

    def twins(self) -> list[str]:
        shared = sorted(set(self.here.workflows()) & set(self.other.workflows()))
        return [path for path in shared
                if any(declares_twin(tree.read(path) or "") for tree in (self.here, self.other))]

    def test_every_main_twin_runs_where_its_twin_does(self) -> None:
        drifted = {}
        for path in self.twins():
            drift = twin_drift(self.here.read(path) or "", self.other.read(path) or "")
            if drift:
                drifted[path] = drift
        if os.environ.get("CMUX_TWIN_REPORT"):
            print(f"main twins: {len(self.twins())}: {', '.join(self.twins())}", file=sys.stderr)
        self.assertFalse(drifted, "\n".join(
            [f"{self.ref}: these main twins run a job differently from this branch's copy; change both copies "
             "in the same change (one pull request per branch):"]
            + [f"  {path}: {line}" for path, lines in sorted(drifted.items()) for line in lines]))

    def test_the_drift_reader(self) -> None:
        sweep = ("on:\n  schedule:\n    - cron: '17 * * * *'\njobs:\n  sweep:\n    runs-on: {runs_on}\n    steps:\n"
                 "{floor}      - run: python3 sweep.py\n")
        floor = "      - run: python3 scripts/ci/job_token_floor.py ui-proof-stale-sweep/sweep\n"
        main = sweep.format(runs_on="${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
                                    "'cmux-gcp-secret-jit-x64' }}", floor=floor)
        feat = sweep.format(runs_on="cmux-linux", floor="")
        self.assertEqual(twin_drift(main, main), [])
        drift = twin_drift(main, feat)
        self.assertEqual(len(drift), 2, drift)
        self.assertIn("runs-on", drift[0])
        self.assertIn("GITHUB_TOKEN floor", drift[1])
        # A job only one copy has is the pre-push gate's to judge, not a runner drift.
        self.assertEqual(twin_drift(main, main.replace("sweep:", "other:")), [])
        self.assertTrue(declares_twin("name: x\n# main carries this same file (its Main-Twin)\non: push\n"))
        self.assertFalse(declares_twin("jobs:\n  a:\n    steps:\n      - name: Validate the prepush main twin\n"))


class FetchLeavesTheCheckoutAlone(unittest.TestCase):
    """Under Actions, fetch() never makes the job's checkout shallow (cmux#40871).

    Every test in a car guards run shares the job's full-history, blob-less checkout. fetch_tip's
    --depth=1 fetch wrote .git/shallow there, and test_cmux_next_guards_notices_pair.py's clone of
    the checkout, running beside it, failed on a blob the now-shallow source could not send.
    """

    def setUp(self) -> None:
        global REPO, ON_CI
        saved = REPO, ON_CI
        self.addCleanup(self.restore, saved)
        for cached in (fetch_tip, fetch, is_shallow, is_partial):
            cached.cache_clear()
            self.addCleanup(cached.cache_clear)
        ON_CI = True
        self.tmp = Path(tempfile.mkdtemp(prefix="owned-pool-fetch-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        work = git_fixture_env.init_repo(self.tmp / "work", "-b", "main")
        ident = ["-c", "user.name=t", "-c", "user.email=t@example.com"]
        for number in range(3):
            (work / sources.WORKFLOWS_DIR).mkdir(parents=True, exist_ok=True)
            (work / sources.WORKFLOWS_DIR / "ci.yml").write_text(f"name: ci {number}\n")
            subprocess.run(["git", "-C", str(work), "add", "-A"], check=True)
            subprocess.run(["git", "-C", str(work), *ident, "commit", "-q", "-m", f"c{number}"], check=True)
        self.origin = git_fixture_env.clone_repo(work, self.tmp / "origin.git", "--bare")
        subprocess.run(["git", "-C", str(self.origin), "config", "uploadpack.allowFilter", "true"], check=True)

    @staticmethod
    def restore(saved: tuple[Path, bool]) -> None:
        global REPO, ON_CI
        REPO, ON_CI = saved

    def checkout(self, *args: str) -> Path:
        global REPO
        REPO = git_fixture_env.clone_repo(self.origin.as_uri(), self.tmp / "checkout", "--filter=blob:none", *args)
        return REPO

    def test_a_full_history_blobless_checkout_stays_unshallow(self) -> None:
        checkout = self.checkout()
        self.assertEqual(fetch("origin/main"), PRIVATE_REFS + "main")
        self.assertFalse((checkout / ".git" / "shallow").exists(), "fetch() made the job's checkout shallow")
        self.assertEqual(git("rev-parse", "--is-shallow-repository").stdout.strip(), "false")

    def test_a_shallow_blobless_checkout_still_gets_the_tip(self) -> None:
        self.checkout("--depth=1")
        self.assertEqual(fetch("origin/main"), PRIVATE_REFS + "main")
        self.assertEqual(git("show", f"{PRIVATE_REFS}main:{sources.WORKFLOWS_DIR}/ci.yml").stdout, "name: ci 2\n")


if __name__ == "__main__":
    unittest.main()
