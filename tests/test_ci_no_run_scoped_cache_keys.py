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
- a mlugg/setup-zig step that keeps its own per-run cache (it needs `use-cache: false`).

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
    "cmux-next-web.yml: Record this push as the last covered one":
        "an empty marker per feat-cmux-next push that the next push reads to coalesce",
    "cmux-next.yml: Save the DEV compile cache (Blacksmith)":
        "per-commit compile cache for the DEV build, restored by prefix; a candidate for a stable key",
    "ios-appstore-upload.yml: Save iOS compilation cache":
        "a release upload, by hand: per-commit Xcode compilation cache; a candidate for a stable key",
    "ios-testflight.yml: Save iOS compilation cache":
        "per TestFlight upload: per-commit Xcode compilation cache; a candidate for a stable key",
    "seed-derived-data.yml: Save seed":
        "the DerivedData seed in the R2 store (not the GitHub store), restored by prefix",
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


if __name__ == "__main__":
    unittest.main(argv=sys.argv[:1] + sys.argv[1:], verbosity=1)
