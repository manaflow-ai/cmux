#!/usr/bin/env python3
"""Detector: a pool-runner job never unpacks the Bun package cache archive over a runner's warm cache.

Leo, 2026-11-25: "Ok well we can't be letting important rfds like that take breaks unless I put in fleet wide
pauses, esp when this is stuff that materially improves the app"

A persistent pool runner (`cmux-linux`, the react shard runner) keeps its own `~/.bun/install/cache` across jobs.
Unpacking the 1.1 GB shared archive over it cost 30 s median per compile preflight build (27 sampled on
2026-11-27) and 400-1,096 s on the jobs cancelled at their limits on 2026-11-23
(docs/ci/cmux-next-workflow-notes/2026-11-26-bun-cache-warm.md). Fast gates, web bundles and the compile
preflight skipped it; 24 other restores in 13 workflows did not. This test fails on any job that runs on a pool
runner and restores the Bun cache (restore only, the step a pull request runs) without:
  - an earlier `bun-warm` step that honours `vars.CI_BUN_CACHE_RESTORE_WARM` (1 restores everywhere again), and
  - `steps.bun-warm.outputs.warm != 'true'` in the restore step's `if:`.
A restore-and-save `actions/cache` step on a base branch keeps restoring: it owns the shared cache's save.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
BUN_CACHE = "~/.bun/install/cache"
GUARD = "steps.bun-warm.outputs.warm != 'true'"
POOL_LABELS = ("cmux-linux", "CI_REACT_SHARD_RUNNER")


def _restore_only(uses: str) -> bool:
    name = uses.split("@", 1)[0]
    return name == "actions/cache/restore" or name.endswith("/.github/actions/cache-restore")


def unguarded(workflow: dict) -> list[str]:
    """Every pool-runner Bun cache restore in WORKFLOW that would unpack over a warm cache."""
    found = []
    for job_name, job in (workflow.get("jobs") or {}).items():
        if not any(label in str(job.get("runs-on", "")) for label in POOL_LABELS):
            continue
        warm_seen = False
        for index, step in enumerate(job.get("steps") or []):
            if step.get("id") == "bun-warm":
                warm_seen = "CI_BUN_CACHE_RESTORE_WARM" in str(step.get("env", ""))
                continue
            uses = step.get("uses") or ""
            path = str((step.get("with") or {}).get("path", "")).strip()
            if path != BUN_CACHE or not _restore_only(uses):
                continue
            if not warm_seen or GUARD not in str(step.get("if", "")):
                found.append(f"{job_name} step {index} ({step.get('name', uses)})")
    return found


class BunCacheWarmDetector(unittest.TestCase):
    def test_every_pool_runner_bun_restore_skips_a_warm_cache(self) -> None:
        misses = {}
        for path in sorted(WORKFLOWS.glob("*.yml")):
            bad = unguarded(yaml.safe_load(path.read_text()))
            if bad:
                misses[path.name] = bad
        self.assertEqual(misses, {}, "add the bun-warm step (see cmux-next-compile-preflight.yml) and its guard")

    def test_the_detector_catches_an_unguarded_restore(self) -> None:
        restore = {"name": "Restore", "uses": "actions/cache/restore@x", "with": {"path": BUN_CACHE, "key": "k"}}
        job = {"runs-on": "cmux-linux", "steps": [restore]}
        self.assertEqual(unguarded({"jobs": {"j": job}}), ["j step 0 (Restore)"])
        warm = {"id": "bun-warm", "env": {"RESTORE_ON_WARM": "${{ vars.CI_BUN_CACHE_RESTORE_WARM }}"}}
        guarded = dict(restore, **{"if": GUARD})
        self.assertEqual(unguarded({"jobs": {"j": {"runs-on": "cmux-linux", "steps": [warm, guarded]}}}), [])
        # An ephemeral runner starts empty: nothing to skip, nothing to flag.
        self.assertEqual(unguarded({"jobs": {"j": {"runs-on": "ubuntu-24.04", "steps": [restore]}}}), [])


if __name__ == "__main__":
    unittest.main()
