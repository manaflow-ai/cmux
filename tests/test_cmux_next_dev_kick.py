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
check("permissions: {}" in text and text.count("    actions: write") == 1 and "contents:" not in text,
      "the kick needs only actions: write, on its one job")
check(text.count("permission-actions: write") == 1 and "permission-contents" not in text,
      "the cmux-bot token the kick mints may only dispatch workflows")
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
      "|| fromJSON(vars.RUNNER_POOLS).linux_4 }}" in text and "'ubuntu-24.04'" in text,
      "DEV kick reads the ephemeral_only Linux pool (it holds a write token), never a fixed Blacksmith size that can stall")

# 2026-11-24: every push's kick went red on "HTTP 403: API rate limit exceeded for installation" (runs 45381829805 to
# 45383131900) with github.token's shared hour spent elsewhere. The kick spends the cmux-bot App's hour first, falls
# back to github.token, and a kick every token was refused for is a warning: the dispatcher and the tick run on their
# own crons. Any other failure stays red. Run the kick() shell function against a fake gh to prove each outcome.
import os  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402

kick_steps = [step for job in (yaml.safe_load(text).get("jobs") or {}).values() for step in job.get("steps", [])
              if "gh workflow run" in str(step.get("run", ""))]
check(len(kick_steps) == 2 and all(s.get("env", {}).get("BOT_TOKEN") == "${{ steps.cmux-bot-token.outputs.token }}"
                                   and s.get("env", {}).get("REPO_TOKEN") == "${{ github.token }}"
                                   and "GH_TOKEN" not in s.get("env", {}) for s in kick_steps),
      "each dispatch tries the cmux-bot token, then github.token")
mint = [step for job in (yaml.safe_load(text).get("jobs") or {}).values() for step in job.get("steps", [])
        if step.get("id") == "cmux-bot-token"]
check(len(mint) == 1 and mint[0].get("continue-on-error") is True,
      "a failed mint leaves the kick on github.token, never red by itself")


def run_kick(step, answers, bot="bot"):
    """answers: token -> (exit code, output). Returns (exit code, combined output, tokens tried)."""
    with tempfile.TemporaryDirectory() as tmp:
        fake = Path(tmp, "gh")
        log = Path(tmp, "log")
        cases = "".join(f'  {tok}) echo "{out}" >&2; exit {code};;\n' for tok, (code, out) in answers.items())
        fake.write_text(f'#!/bin/bash\necho "$GH_TOKEN" >> {log}\ncase "$GH_TOKEN" in\n{cases}  *) exit 0;;\nesac\n')
        fake.chmod(0o755)
        env = {"PATH": f"{tmp}:/usr/bin:/bin", "BOT_TOKEN": bot, "REPO_TOKEN": "repo", "GH_REPO": "o/r",
               "KICK": step["env"]["KICK"]}
        proc = subprocess.run(["bash", "-c", step["run"]], env=env, capture_output=True, text=True)
        tried = log.read_text().split() if log.exists() else []
        return proc.returncode, proc.stdout + proc.stderr, tried


limit = "HTTP 403: API rate limit exceeded for installation ID 1"
for step in kick_steps:
    code, out, tried = run_kick(step, {})
    check(code == 0 and tried == ["bot"], f"{step['name']}: the cmux-bot token dispatches alone when it can ({tried})")
    code, out, tried = run_kick(step, {"bot": (1, limit)})
    check(code == 0 and tried == ["bot", "repo"] and "::warning" not in out,
          f"{step['name']}: a rate-limited cmux-bot token falls back to github.token")
    code, out, tried = run_kick(step, {"bot": (1, limit), "repo": (1, limit)})
    check(code == 0 and tried == ["bot", "repo"] and "::warning title=DEV kick skipped::" in out,
          f"{step['name']}: every token rate-limited is a skipped kick with a warning, not a red ({code}, {out!r})")
    code, out, tried = run_kick(step, {"bot": (1, "HTTP 500: Failed to run workflow dispatch")})
    check(code == 0 and tried == ["bot", "repo"] and "::warning" not in out,
          f"{step['name']}: a GitHub 5xx on the cmux-bot token falls back to github.token")
    code, out, tried = run_kick(step, {"bot": (1, "HTTP 502: Bad Gateway"), "repo": (1, "HTTP 500: Server Error")})
    check(code == 0 and "::warning title=DEV kick skipped::" in out,
          f"{step['name']}: every token answered 5xx is a skipped kick with a warning, not a red ({code}, {out!r})")
    code, out, tried = run_kick(step, {"bot": (1, "HTTP 404: workflow not found")})
    check(code != 0 and tried == ["bot"], f"{step['name']}: any other failure stays red")
    code, out, tried = run_kick(step, {"repo": (1, limit)}, bot="")
    check(code == 0 and tried == ["repo"] and "::warning" in out,
          f"{step['name']}: with no cmux-bot token the kick runs on github.token alone")

if failures:
    print("FAIL: cmux NEXT DEV kick\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: cmux NEXT DEV kick")
