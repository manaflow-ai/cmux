#!/usr/bin/env python3
"""The repository GITHUB_TOKEN floor (scripts/ci/job_token_floor.py) and its detector.

Rule (cmuxterm-hq docs/handbook/unfloored-spender-drains-installation.md): "Every recurring spender on a shared
installation stops at a floor, as the mints do." The detector: every job of a workflow scheduled 12 or more times a
day whose steps use github.token reads job_token_floor.py first, or is named in EXEMPT with why its spend is
already bounded.
"""

from __future__ import annotations

import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import job_token_floor  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
RECURRING_RUNS_PER_DAY = 12

NIGHTLY = "the NEXT nightly train: the calls under the floor are kept for it, so it takes none"
NIGHTLY_MAIN = ("the main nightly train (hourly :17 tick since cmux#56246): these jobs run only when decide builds, "
                "at most once per NIGHTLY_PUSH_MIN_INTERVAL_HOURS, or on a manual dispatch; the floor keeps calls for it")
EXEMPT = {
    "nightly.yml:promote-nightly-next": NIGHTLY_MAIN,
    "nightly.yml:pick-nightly-app-runner": NIGHTLY_MAIN,
    "nightly.yml:pick-classic-sign-runner": NIGHTLY_MAIN,
    "nightly.yml:prepare-nightly-variant": NIGHTLY_MAIN,
    "nightly.yml:publish-nightly": NIGHTLY_MAIN,
    "storage-maintenance.yml:actions-artifacts": "its own floor: stops at 50 calls left, deletes paced 0.4 s apart",
    "ci-cla-quota-rerun.yml:cla-quota-rerun": "its own floor: the free /rate_limit on github.token (RATE_TOKEN) "
                                              "first; reads and re-runs on it only above FLOOR_MIN while the "
                                              "glaeda-route App's hour is spent",
    "ci-hosted-backlog-rescue.yml:backlog": "gated on cmux-bot's floor (app_spend_mark --floor pass); "
                                            "hosted_light_rescue.py reads the workflow token only above POOL_RESERVE",
    "ci-owned-pool-rescue.yml:rescue": "hosted_light_rescue.py reads the workflow token only above POOL_RESERVE",
    "ci-queue-janitor-watchdog.yml:watch": "one runs listing a tick to restart a stalled janitor",
    "cloud-journey-prod.yml:journey": "one gate read an hour and one issue write on a red journey",
    "cmux-next-post-merge-dispatch.yml:tick": "a dispatch path (two reads a tick); cmux#55829 moves it to the "
                                              "cmux bot App's own budget",
    "ios-appstore-upload.yml:decide": "one compare read an hour",
    "merge-freeze.yml:check": "the glaeda-route App first; github.token only on its refusal",
    "merge-freeze.yml:expire": "the glaeda-route App first; github.token only on its refusal",
    "nightly-next-canary.yml:pick": NIGHTLY,
    "nightly-next-canary.yml:canary": NIGHTLY,
    "nightly-next-canary.yml:verdict": NIGHTLY,
    "nightly-next-canary.yml:failed": NIGHTLY,
    "nightly-next-feed-watch.yml:watch": NIGHTLY,
    "nightly-next-health.yml:start": NIGHTLY,
    "nightly-next-launch-smoke.yml:pick": NIGHTLY,
    "nightly-next-launch-smoke.yml:crashed": NIGHTLY,
    "nightly-next-tick.yml:request": NIGHTLY,
    "nightly-next-tick.yml:unstick": NIGHTLY,
    "pr-media-privacy.yml:check": "git ls-remote only: git transport is not the REST hour",
    "pr-media-privacy.yml:scan": "runs only when pr-media moved (the check job's git compare)",
}


def expand(field: str, lo: int, hi: int) -> set[int]:
    values: set[int] = set()
    for part in field.split(","):
        step = 1
        if "/" in part:
            part, raw = part.split("/")
            step = int(raw)
        if part == "*":
            start, end = lo, hi
        elif "-" in part:
            start, end = map(int, part.split("-"))
        else:
            start = int(part)
            end = start if step == 1 else hi
        values.update(range(start, end + 1, step))
    return values


def runs_per_day(cron: str) -> float:
    minute, hour, dom, _month, dow = cron.split()
    runs = len(expand(minute, 0, 59)) * len(expand(hour, 0, 23))
    return runs / 7 if dow != "*" or dom != "*" else runs


def recurring_token_jobs() -> dict[str, str]:
    """`file:job` -> the job's YAML text, for jobs of frequent schedules that use github.token."""
    found = {}
    for path in sorted(WORKFLOWS.glob("*.yml")):
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        on = data.get(True) or data.get("on") or {}
        if not isinstance(on, dict) or "schedule" not in on:
            continue
        if sum(runs_per_day(entry["cron"]) for entry in on["schedule"]) < RECURRING_RUNS_PER_DAY:
            continue
        for name, job in (data.get("jobs") or {}).items():
            text = yaml.safe_dump(job)
            if "github.token" in text or "secrets.GITHUB_TOKEN" in text:
                found[f"{path.name}:{name}"] = text
    return found


class Detector(unittest.TestCase):
    def test_every_recurring_github_token_job_reads_the_floor_or_says_why_not(self):
        missing = [key for key, text in recurring_token_jobs().items()
                   if "job_token_floor.py" not in text and key not in EXEMPT]
        self.assertEqual(missing, [], "a recurring job spends github.token with no floor: add a "
                         "`job_token_floor.py WORKFLOW/JOB` step (id: job-floor) and gate its spending steps on "
                         "steps.job-floor.outputs.held != 'true', or name it in EXEMPT with why its spend is bounded")

    def test_exemptions_are_current(self):
        jobs = recurring_token_jobs()
        stale = [key for key in EXEMPT if key not in jobs or "job_token_floor.py" in jobs[key]]
        self.assertEqual(stale, [], "EXEMPT names a job that is gone, no longer recurring or now floored")

    def test_every_floored_step_is_gated(self):
        for key, text in recurring_token_jobs().items():
            if "job_token_floor.py" not in text:
                continue
            flat = " ".join(text.replace("\\\n", " ").split())  # safe_dump wraps long expressions
            with self.subTest(job=key):
                self.assertIn("id: job-floor", flat)
                self.assertIn("steps.job-floor.outputs.held != 'true'", flat)

    def test_cron_counts(self):
        self.assertEqual(runs_per_day("*/10 * * * *"), 144)
        self.assertEqual(runs_per_day("11,41 * * * *"), 48)
        self.assertEqual(runs_per_day("37 2,8,14,20 * * *"), 4)
        self.assertEqual(runs_per_day("3-59/10 * * * *"), 144)


class Floor(unittest.TestCase):
    def run_check(self, pool, floor=None, token="t"):
        lines: list[str] = []
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            env = {"JOB_TOKEN": token, "GITHUB_OUTPUT": str(output)}
            code = job_token_floor.check("wf/job", floor, env, read=lambda _t: pool, now=lambda: 1000,
                                         out=lines.append)
            written = output.read_text() if output.exists() else ""
        return code, lines, written

    def test_under_the_floor_holds_and_names_the_reset(self):
        code, lines, written = self.run_check({"limit": 1000, "used": 800, "remaining": 200, "reset": 1795600000})
        self.assertEqual(code, 0)
        self.assertIn("held=true", written)
        self.assertTrue(any(line.startswith("job-token-floor: wf/job held remaining=200 floor=300 until=")
                            for line in lines))
        self.assertTrue(any(line.startswith("::notice title=GITHUB_TOKEN floor::") for line in lines))

    def test_above_the_floor_sends_as_before(self):
        _code, lines, written = self.run_check({"limit": 1000, "used": 100, "remaining": 900, "reset": 1})
        self.assertIn("held=false", written)
        self.assertEqual(lines, ["job-token-pool: wf/job at=1000 limit=1000 used=100 remaining=900 reset=1 floor=300"])

    def test_a_failed_read_or_no_token_never_holds(self):
        for token, pool in (("t", None), ("", {"limit": 1000, "used": 1000, "remaining": 0, "reset": 1})):
            with self.subTest(token=token):
                code, lines, written = self.run_check(pool, token=token)
                self.assertEqual(code, 0)
                self.assertIn("held=false", written)
                self.assertTrue(lines[0].startswith("job-token-note: wf/job"))

    def test_the_floor_is_calls_or_a_share_never_under_the_minimum(self):
        self.assertEqual(job_token_floor.floor_calls(None, 1000), 300)
        self.assertEqual(job_token_floor.floor_calls("0.5", 1000), 500)
        self.assertEqual(job_token_floor.floor_calls("400", 1000), 400)
        self.assertEqual(job_token_floor.floor_calls("10", 1000), 200)
        self.assertEqual(job_token_floor.floor_calls(None, 15000), 4500)

    def test_no_token_is_printed(self):
        _code, lines, written = self.run_check({"limit": 1000, "used": 990, "remaining": 10, "reset": 1},
                                               token="ghs_secretvalue")
        self.assertNotIn("ghs_secretvalue", "\n".join(lines) + written)


if __name__ == "__main__":
    unittest.main()
