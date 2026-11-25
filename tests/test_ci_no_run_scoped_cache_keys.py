#!/usr/bin/env python3
"""No cache is saved under a key that names one run or one commit.

The repository's cache store holds 10 GB and evicts the least recently used entry first. A
save keyed by `github.run_id`, `run_number`, `run_attempt` or `github.sha` writes a new entry on
every run (or every commit), and nothing ever reads most of them again. On 2026-11-18 setup-zig's
own cache (`setup-zig-cache-<job>-<tarball>--<run_id>-<attempt>`, up to 2 GiB each, saved on
every branch) filled the store to 10.59 GB, and the cargo caches it evicted made the acpmux test
job build from nothing ("No cache found").

Key a cache by what is in it (a lockfile hash, a tool version, a week), save it once per key
from feat-cmux-next pushes, and restore it everywhere else (.github/actions/zig-global-cache,
.github/actions/ghostty-zig-packages). This test rejects:

- a cache save (actions/cache, actions/cache/save, WarpBuilds/cache/save or
  ./.github/actions/cache-save) whose key names the run or the commit, and
- a mlugg/setup-zig step that keeps its own per-run cache (it needs `use-cache: false`), and
- a new cache save (those, or rust-cache) that a lane branch or pull request can run: its
  entry is read only by that ref again. tests/ci_per_ref_cache_saves_baseline.txt holds the
  ones from before this rule.

ALLOWED lists the saves that stay, as `file: step name`, each with why. Shrink it; do not grow
it without a reason the review accepts.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
ACTIONS = ROOT / ".github" / "actions"

RUN_SCOPED = re.compile(r"github\.(run_id|run_number|run_attempt|sha)\b")
SAVES = (
    "actions/cache@",
    "actions/cache/save@",
    "WarpBuilds/cache@",
    "WarpBuilds/cache/save@",
    "./.github/actions/cache-save",
)
SETUP_ZIG = "mlugg/setup-zig@"

# Workflows whose schedule runs main's copy: a change here reaches production only through a
# twin PR against main, so they keep setup-zig's cache until that lands.
SETUP_ZIG_ON_MAIN: dict[str, str] = {
    "cloud-journey-prod.yml": "its schedule runs main's copy; the fix lands with a Main-Twin PR",
}

ALLOWED: dict[str, str] = {
    "ci-web.yml: Save the duration manifest":
        "a few kB of test durations; the next run restores the newest by prefix",
    "indexnow.yml: Save submitted URLs":
        "a few kB of submitted URLs, one scheduled job; the next run restores the newest by prefix",
    "base-coalesce.yml: Record this tip as tested":
        "a 41-byte marker per tip a coalesced run started on (one a window); the next push finds the newest by prefix",
    "cmux-next-web.yml: Record this push as the last covered one":
        "an empty marker per feat-cmux-next push that the next push reads to coalesce",
    "cmux-next.yml: Save the DEV compile cache (Blacksmith)":
        "per-commit compile cache for the DEV build, restored by prefix; a candidate for a stable key",
    "ios-appstore-upload.yml: Save iOS compilation cache":
        "a release upload, by hand: per-commit Xcode compilation cache; a candidate for a stable key",
    "ios-testflight.yml: Save iOS compilation cache":
        "per TestFlight upload: per-commit Xcode compilation cache; a candidate for a stable key",
    "cmux-tui-spec.yml: Save the base's last test log":
        "a few hundred kB gzipped log per feat-cmux-next push of the acpmux tests; pull requests restore the newest by prefix "
        "so their reds need no rebuild of the merge parent",
}


def _files() -> list[Path]:
    return sorted(
        [*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml"),
         *ACTIONS.glob("*/action.yml"), *ACTIONS.glob("*/action.yaml")]
    )


def _steps(doc: object):
    if not isinstance(doc, dict):
        return
    for job in (doc.get("jobs") or {}).values():
        if isinstance(job, dict):
            yield from (s for s in job.get("steps") or [] if isinstance(s, dict))
    runs = doc.get("runs")
    if isinstance(runs, dict):
        yield from (s for s in runs.get("steps") or [] if isinstance(s, dict))


def _label(path: Path) -> str:
    return path.name if path.parent == WORKFLOWS else f"{path.parent.name}/{path.name}"


def findings() -> tuple[list[str], set[str]]:
    """Returns (violations, allowed entries that matched a step)."""
    violations: list[str] = []
    used: set[str] = set()
    for path in _files():
        doc = yaml.safe_load(path.read_text())
        for step in _steps(doc):
            uses = str(step.get("uses", ""))
            inputs = step.get("with") or {}
            where = f"{_label(path)}: {step.get('name') or uses}"
            if uses.startswith(SETUP_ZIG):
                if path.name in SETUP_ZIG_ON_MAIN:
                    used.add(path.name)
                    continue
                if str(inputs.get("use-cache", "")).strip().lower() != "false":
                    violations.append(
                        f"{where}: setup-zig keeps its own per-run cache; set `use-cache: false` "
                        "and add ./.github/actions/zig-global-cache after it"
                    )
                continue
            if not uses.startswith(SAVES):
                continue
            key = str(inputs.get("key", ""))
            if not RUN_SCOPED.search(key):
                continue
            if where in ALLOWED:
                used.add(where)
                continue
            violations.append(f"{where}: cache key names the run or commit: {key}")
    return violations, used


class NoRunScopedCacheKeys(unittest.TestCase):
    def test_no_run_scoped_cache_saves(self) -> None:
        violations, _ = findings()
        self.assertEqual(violations, [], "\n" + "\n".join(violations))

    def test_allowlist_has_no_stale_entries(self) -> None:
        _, used = findings()
        stale = sorted((set(ALLOWED) | set(SETUP_ZIG_ON_MAIN)) - used)
        self.assertEqual(stale, [], f"ALLOWED entries that match no run-scoped save: {stale}")

    def test_detector_catches_both_shapes(self) -> None:
        self.assertTrue(RUN_SCOPED.search("x-${{ github.run_id }}-${{ github.run_attempt }}"))
        self.assertTrue(RUN_SCOPED.search("x-${{ github.sha }}"))
        self.assertFalse(RUN_SCOPED.search("x-${{ github.event.pull_request.base.sha_short }}"))
        self.assertFalse(RUN_SCOPED.search("x-${{ hashFiles('Cargo.lock') }}"))



# --- Per-ref saves -------------------------------------------------------------------------
# A cache entry belongs to the ref that saved it. A lane branch can read only its own entries and
# the default branch's, and a pull request only its own and its base's. So a save from a lane
# branch or a pull request is read again only by later runs of that same ref, and the same key
# saved from 18 lane branches is 18 copies (ghostty-zig-packages, 2026-11-18: 13 x 110 MB on
# macOS alone). A save must be limited to a base-branch push (its step, its job, or the
# workflow's triggers), or be a rust-cache with a `save-if` that is. PER_REF_BASELINE lists the
# saves that predate this rule. Shrink it; a new save never joins it.

BASE_REF = re.compile(
    r"refs/heads/(feat-cmux-next|main)\b|ref_name\s*==\s*'(feat-cmux-next|main)'|default_branch"
)
PR_REF = re.compile(r"github\.(base_ref|head_ref)\s*==")
PER_REF_SAVERS = SAVES + ("Swatinem/rust-cache@",)
PER_REF_BASELINE_FILE = ROOT / "tests" / "ci_per_ref_cache_saves_baseline.txt"
UNRESTRICTED_EVENTS = {
    "pull_request", "pull_request_target", "workflow_call", "workflow_dispatch", "merge_group",
    "workflow_run", "repository_dispatch",
}


def _triggers(doc: dict) -> dict:
    on = doc.get(True, doc.get("on"))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {k: None for k in on}
    return on if isinstance(on, dict) else {}


def _workflow_base_only(doc: dict) -> bool:
    """True when every trigger runs only on a base branch (a push to main or feat-cmux-next, or a schedule)."""
    triggers = _triggers(doc)
    if UNRESTRICTED_EVENTS & set(triggers):
        return False
    if "push" in triggers:
        push = triggers["push"]
        branches = push.get("branches") if isinstance(push, dict) else None
        if not branches or any(b not in ("main", "feat-cmux-next") for b in branches):
            return False
    return True


def per_ref_saves() -> list[str]:
    """Every cache save that a lane branch or pull request can run, as `path: job: step`."""
    found: list[str] = []
    for path in _files():
        doc = yaml.safe_load(path.read_text())
        if not isinstance(doc, dict):
            continue
        composite = path.parent != WORKFLOWS
        if composite:
            groups = [("", (doc.get("runs") or {}).get("steps") or [], "")]
            base_only = False
        else:
            groups = [
                (job_id, job.get("steps") or [], str(job.get("if", "")))
                for job_id, job in (doc.get("jobs") or {}).items()
                if isinstance(job, dict)
            ]
            base_only = _workflow_base_only(doc)
        for job_id, steps, job_if in groups:
            for step in steps:
                if not isinstance(step, dict):
                    continue
                uses = str(step.get("uses", ""))
                if not uses.startswith(PER_REF_SAVERS):
                    continue
                inputs = step.get("with") or {}
                condition = f"{step.get('if', '')} {job_if}"
                if uses.startswith("Swatinem/rust-cache@"):
                    save_if = str(inputs.get("save-if", ""))
                    if save_if.strip().lower() == "false":
                        continue
                    condition += f" {save_if}"
                # A same-tree receipt (scripts/ci/same_tree_reuse.py) is one JSON file of a few hundred bytes,
                # keyed by the tree it vouches for: it cannot crowd the 10 GB store, and the same pull request's
                # re-runs and re-pushes of that tree are what read it. A react shard's receipt
                # (scripts/ci/react_shard_receipt.py, a green shard's result map and summaries, a few kB) is the same.
                if str(inputs.get("path", "")).startswith(".same-tree/"):
                    continue
                # A composite that takes its condition from an input leaves the ref to its callers.
                # `github.base_ref == 'feat-cmux-next'` is true on every pull request into it, so a condition that ORs it
                # with a base push still saves per pull request (ci-web.yml's agent-pane rust-cache, 53 GB in 6 h, 2026-11-24).
                # Only the step's own gate: a job's `if:` routes pull requests in with `base_ref` and is no save gate.
                if PR_REF.search(f"{step.get('if', '')} {inputs.get('save-if', '')}"):
                    found.append(f"{_label(path)}: {job_id}: {step.get('name') or uses.split('@')[0]}")
                    continue
                if base_only or BASE_REF.search(condition) or (composite and "inputs." in condition):
                    continue
                name = step.get("name") or uses.split("@")[0]
                found.append(f"{_label(path)}: {job_id}: {name}")
    return found


def per_ref_baseline() -> list[str]:
    return [
        line.strip() for line in PER_REF_BASELINE_FILE.read_text().splitlines()
        if line.strip() and not line.startswith("#")
    ]


class NoPerRefCacheSaves(unittest.TestCase):
    def test_no_new_per_ref_save(self) -> None:
        new = sorted(set(per_ref_saves()) - set(per_ref_baseline()))
        self.assertEqual(new, [], (
            "\nthese cache saves run on lane branches or pull requests, where nothing but that ref reads "
            "them again; limit the save to a feat-cmux-next push (`if: github.event_name == 'push' && "
            "github.ref == 'refs/heads/feat-cmux-next'`, or rust-cache `save-if:`) and restore everywhere:\n"
            + "\n".join(new)
        ))

    def test_baseline_has_no_stale_entries(self) -> None:
        stale = sorted(set(per_ref_baseline()) - set(per_ref_saves()))
        self.assertEqual(stale, [], f"remove from {PER_REF_BASELINE_FILE.name}: {stale}")

    def test_detector_sees_both_shapes(self) -> None:
        self.assertTrue(BASE_REF.search("github.ref == 'refs/heads/feat-cmux-next'"))
        self.assertFalse(BASE_REF.search("github.event_name == 'push'"))
        self.assertTrue(_workflow_base_only({"on": {"push": {"branches": ["feat-cmux-next"]}, "schedule": []}}))
        self.assertFalse(_workflow_base_only({"on": {"push": {"branches": ["**"]}}}))
        self.assertFalse(_workflow_base_only({"on": ["pull_request"]}))


# --- rust-cache keys that move with the lockfile --------------------------------------------
# With `add-rust-environment-hash-key: false` (note-210) and a key that never changes, the first
# entry saved is restored forever: rust-cache skips the save when the restore was an exact match,
# so third-party crates added or bumped since rebuild on every run (run 45512288219: 70 crates
# built in the debug and release `cargo test`). The key carries a `hashFiles` of the lockfile,
# so a lockfile change makes a new entry that a base push saves.
# The two iOS ones get theirs in #55162; cloud-journey-prod runs main's copy on its schedule and needs a main twin PR. Drop the entries once they land.
LOCK_KEY_PENDING = {"first-user-journey-ios.yml", "ios-reliability-matrix.yml", "cloud-journey-prod.yml"}


def rust_cache_keys_without_lockfile() -> list[str]:
    bad: list[str] = []
    for path in _files():
        if path.name in LOCK_KEY_PENDING:
            continue
        doc = yaml.safe_load(path.read_text())
        for step in _steps(doc):
            if not str(step.get("uses", "")).startswith("Swatinem/rust-cache@"):
                continue
            inputs = step.get("with") or {}
            if str(inputs.get("add-rust-environment-hash-key", "")).lower() != "false":
                continue
            keys = f"{inputs.get('key', '')} {inputs.get('shared-key', '')}"
            if "hashFiles(" not in keys or "Cargo.lock" not in keys:
                bad.append(f"{_label(path)}: {step.get('name') or step.get('uses')}")
    return bad


class RustCacheKeyFollowsLockfile(unittest.TestCase):
    def test_every_rust_cache_key_hashes_a_lockfile(self) -> None:
        bad = rust_cache_keys_without_lockfile()
        self.assertEqual(bad, [], (
            "\nrust-cache with add-rust-environment-hash-key: false needs a key (or shared-key) that includes "
            "hashFiles('<toolchain file>', '<workspace>/Cargo.lock', '.cargo/config.toml'), or a stale entry is "
            "restored forever:\n" + "\n".join(bad)
        ))


if __name__ == "__main__":
    unittest.main(argv=sys.argv[:1] + sys.argv[1:], verbosity=1)
