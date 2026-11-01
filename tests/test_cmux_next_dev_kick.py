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
check(text.count("gh workflow run") == 1 and "cmux-next.yml" not in text.replace("cmux-next-dev-", ""),
      "the kick starts no DEV build itself")

check("!startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER ||" in text and
      "|| vars.LINUX_RUNNER ||" not in text and
      "vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-4vcpu-ubuntu-2404' || 'blacksmith-2vcpu-ubuntu-2404'" in text and
      "'ubuntu-24.04'" in text,
      "DEV kick honors a non-Blacksmith LINUX_RUNNER, else the 2-vCPU Blacksmith size (4 while overflow is saved)")

if failures:
    print("FAIL: cmux NEXT DEV kick\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: cmux NEXT DEV kick")
