#!/usr/bin/env python3
"""Every feat-cmux-next merge starts the DEV dispatcher at once (GitHub's cron
fired only every 15-25 minutes), and the kick starts only the dispatcher: no
path filter that would skip a web-only merge, no build of its own, and nothing
that cancels a run."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
text = (ROOT / ".github/workflows/cmux-next-dev-kick.yml").read_text()
failures = []


def check(ok, message):
    if not ok:
        failures.append(message)


check("on:\n  push:\n    branches: [feat-cmux-next]\n\n" in text, "the kick runs on every feat-cmux-next push")
check("paths" not in text, "a path filter would skip web-only merges")
check("cancel-in-progress: true" not in text, "a kick never cancels anything")
check("permissions: {}" in text and text.count("actions: write") == 1 and "contents:" not in text,
      "the kick needs only actions: write, on its one job")
check('gh workflow run cmux-next-dev-daily-dispatch.yml --repo "$GH_REPO" --ref main' in text,
      "the kick starts the dispatcher on main, which spaces DEV builds")
check(text.count("gh workflow run") == 2 and "cmux-next.yml" not in text.replace("cmux-next-dev-", ""),
      "the kick starts no DEV build itself")
# Landing to the nightly-next feed (2026-11-14): 86dc299b landed 04:29:21 and the tick heard of it only from the
# 5-minute cron or 15-26 min later, when cmux-next (04:44) and cmux-tui artifacts (04:55) finished. The kick wakes
# the tick at landing; the tick's rolling rule still starts nothing beside a running build.
check('gh workflow run nightly-next-tick.yml --repo "$GH_REPO" --ref main' in text,
      "every landing wakes the nightly-next tick on main at once")
import yaml  # noqa: E402

tick_steps = [step for job in (yaml.safe_load(text).get("jobs") or {}).values() for step in job.get("steps", [])
              if "nightly-next-tick.yml" in str(step.get("run", ""))]
check(len(tick_steps) == 1 and "sha=" not in str(tick_steps[0].get("run")),
      "the kick asks the tick for the newest buildable commit (no sha), so the rolling rule applies")
check(len(tick_steps) == 1 and "!cancelled()" in str(tick_steps[0].get("if", "")),
      "a failed DEV dispatch still wakes the tick")

check("vars.LINUX_RUNNER" not in text and "32vcpu" not in text and
      "|| fromJSON(vars.RUNNER_POOLS).linux }}" in text and "'ubuntu-24.04'" in text,
      "DEV kick reads the reconciled Linux pool, never a fixed Blacksmith size that can stall")

if failures:
    print("FAIL: cmux NEXT DEV kick\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: cmux NEXT DEV kick")
