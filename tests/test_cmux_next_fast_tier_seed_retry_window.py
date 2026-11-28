#!/usr/bin/env python3
"""A failed fast-tier seed round holds its pools until the next retry window.

A failed seed saves no archive, so the pools stayed due and every feat-cmux-next push started another round:
98 seed jobs on 690 pushes (controller timing feed, 11-27 21:29Z..11-28 11:30Z), 745 of 959 Blacksmith macOS
minutes failed. The due job now claims one round per window and package inputs in the Actions cache; a
claimed window gives the seed job no pools. Checks the wiring, and runs the window arithmetic of the due step.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-fast-tier-seed.yml"
FAILURES: list[str] = []


def check(ok: bool, message: str) -> None:
    if not ok:
        FAILURES.append(message)


def window(retry: str, inputs: str, now: int) -> str:
    script = (
        'retry="${RETRY_MINUTES:-60}"\n'
        '[[ "$retry" =~ ^[0-9]+$ && "$retry" -gt 0 ]] || retry=60\n'
        'echo "window=${inputs:-any}-$(( NOW / (retry * 60) ))"\n'
    )
    env = {"PATH": "/usr/bin:/bin", "RETRY_MINUTES": retry, "inputs": inputs, "NOW": str(now)}
    return subprocess.run(["bash", "-euo", "pipefail", "-c", script], env=env, check=True,
                          capture_output=True, text=True).stdout.strip()


def main() -> int:
    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    due = doc["jobs"]["due"]
    steps = {s.get("id"): s for s in due["steps"] if s.get("id")}
    run = steps["due"]["run"]
    check('retry="${RETRY_MINUTES:-60}"' in run and "window=${inputs:-any}-" in run,
          "the due step no longer writes the window this test runs")
    tried, claim = steps.get("tried"), next((s for s in due["steps"] if s.get("name") == "Claim this window's seed round"), None)
    check(tried is not None and tried.get("with", {}).get("lookup-only") is True, "the window lookup must be lookup-only")
    check(claim is not None and claim["with"]["key"] == tried["with"]["key"], "the claim saves the key the lookup reads")
    check(tried.get("continue-on-error") is True, "a failed lookup must seed, not fail the due job")
    check("steps.tried.outputs.cache-hit != 'true'" in claim["if"], "only an unclaimed window claims")
    check(due["outputs"]["pools"] == "${{ steps.tried.outputs.cache-hit != 'true' && steps.due.outputs.pools || '[]' }}",
          "a claimed window must give the seed job no pools")
    check(due["env"]["RETRY_MINUTES"] == "${{ vars.NEXT_FAST_TIER_SEED_RETRY_MINUTES }}", "RETRY_MINUTES reads its var")

    t = 1_764_000_000
    check(window("", "abc", t) == f"window=abc-{t // 3600}", "default window is 60 minutes")
    check(window("", "abc", t) == window("60", "abc", t + 1), "pushes a second apart share a window")
    check(window("", "abc", t) != window("", "def", t), "new package inputs get their own window")
    check(window("", "", t) == f"window=any-{t // 3600}", "unread inputs use 'any'")
    check(window("junk", "abc", t) == window("", "abc", t), "a bad var falls back to 60")
    check(window("0", "abc", t) == window("", "abc", t), "zero falls back to 60")
    check(window("15", "abc", t) == f"window=abc-{t // 900}", "the var sets the window")

    for failure in FAILURES:
        print(f"FAIL: {failure}")
    print("ok" if not FAILURES else f"{len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
