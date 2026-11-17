#!/usr/bin/env python3
"""The Billing nightly (.github/workflows/billing-nightly.yml) stays wired.

It runs billing.yml in full on main every night, checks Apple's notification
delivery and the App Store Server API with secrets only main's own definition
can read, dispatches the StoreKit suite on feat-cmux-next, and alerts on red.
scripts/ci/billing_nightly.py's decisions are pinned here too.

Runs with plain python3 (no PyYAML).
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import re
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/billing-nightly.yml"
LANE_WORKFLOW = ROOT / ".github/workflows/billing.yml"
SCRIPT = ROOT / "scripts/ci/billing_nightly.py"
CHECK = ROOT / "web/scripts/billing/apple-nightly-check.ts"

spec = importlib.util.spec_from_file_location("billing_nightly", SCRIPT)
assert spec and spec.loader
nightly = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = nightly
spec.loader.exec_module(nightly)

SECRET_JOBS = ("apple-delivery", "apple-api", "alert")


def jobs_text() -> dict[str, str]:
    text = WORKFLOW.read_text(encoding="utf-8")
    body = text[text.index("\njobs:\n") + len("\njobs:\n"):]
    blocks: dict[str, str] = {}
    current = None
    for line in body.splitlines():
        header = re.fullmatch(r"  ([a-z][a-z0-9-]*):", line)
        if header:
            current = header.group(1)
            blocks[current] = ""
        elif current:
            blocks[current] += line + "\n"
    return blocks


class Workflow(unittest.TestCase):
    def setUp(self) -> None:
        self.text = WORKFLOW.read_text(encoding="utf-8")
        self.on = self.text[self.text.index("\non:\n"):self.text.index("\npermissions:")]
        self.jobs = jobs_text()

    def test_runs_nightly_and_on_dispatch_only(self) -> None:
        self.assertRegex(self.on, r'schedule:\n    - cron: "[0-9]+ [0-9]+ \* \* \*"')
        self.assertIn("workflow_dispatch:", self.on)
        # A pull request or push must never run code with the Apple key.
        self.assertNotRegex(self.on, r"pull_request|push:")

    def test_suite_is_the_whole_billing_lane(self) -> None:
        self.assertIn("uses: ./.github/workflows/billing.yml", self.jobs["suite"])
        self.assertRegex(LANE_WORKFLOW.read_text(encoding="utf-8"), r"\n  workflow_call:\n")

    def test_every_job_runs_only_from_main(self) -> None:
        for job, block in self.jobs.items():
            with self.subTest(job=job):
                self.assertRegex(block, re.compile(r"^    if: .*github\.ref == 'refs/heads/main'", re.MULTILINE))

    def test_secrets_stay_in_the_environment_jobs(self) -> None:
        for job, block in self.jobs.items():
            with self.subTest(job=job):
                if "secrets." in block:
                    self.assertIn(job, SECRET_JOBS)
                    self.assertIn("    environment: billing-nightly\n", block)
                    self.assertNotIn("contents: write", block)

    def test_apple_jobs_skip_until_configured(self) -> None:
        for job in ("apple-delivery", "apple-api"):
            block = self.jobs[job]
            with self.subTest(job=job):
                self.assertIn("scripts/ci/billing_nightly.py config", block)
                names = re.search(r"billing_nightly\.py config ([A-Z_ ]+)\n", block).group(1).split()
                for name in names:
                    self.assertRegex(block, rf"HAS_{name}: \$\{{\{{ (secrets|vars)\.{name} != '' \}}\}}")
                # Each later step runs only when the configuration is present.
                steps = block.split("      - name: ")[1:]
                for step in steps:
                    if step.startswith(("Checkout", "Check configuration")):
                        continue
                    self.assertIn("if: steps.config.outputs.ready == 'true'", step, step.splitlines()[0])

    def test_delivery_covers_both_environments_of_the_app_store_app(self) -> None:
        block = self.jobs["apple-delivery"]
        self.assertIn("environment: [Sandbox, Production]", block)
        self.assertIn("--bundle-id com.cmux.app", block)
        self.assertIn("https://cmux.com/api/cron/apple-notifications/health", block)
        self.assertTrue(CHECK.is_file())

    def test_storekit_dispatches_feat_cmux_next(self) -> None:
        block = self.jobs["storekit"]
        self.assertIn("gh workflow run billing-nightly.yml -R \"$GITHUB_REPOSITORY\" --ref feat-cmux-next", block)
        self.assertNotIn("secrets.", block.replace("secrets.GITHUB_TOKEN", ""))

    def test_alert_needs_every_job(self) -> None:
        needs = re.search(r"^    needs: \[([^\]]*)\]", self.jobs["alert"], re.MULTILINE)
        self.assertEqual({n.strip() for n in needs.group(1).split(",")}, set(self.jobs) - {"alert"})
        self.assertIn("always()", self.jobs["alert"])
        self.assertIn("issues: write", self.jobs["alert"])


class Script(unittest.TestCase):
    def test_missing_config_names_what_is_absent(self) -> None:
        env = {"HAS_A": "true", "HAS_B": "false"}
        self.assertEqual(nightly.missing_config(env, ["A", "B", "C"]), ["B", "C"])

    def test_config_writes_ready(self) -> None:
        for env, ready in (({"HAS_A": "true"}, "true"), ({"HAS_A": "false"}, "false")):
            with tempfile.NamedTemporaryFile("r", suffix=".out") as output, \
                    tempfile.NamedTemporaryFile("r", suffix=".md") as summary, \
                    mock.patch.dict(os.environ, {**env, "GITHUB_OUTPUT": output.name,
                                                 "GITHUB_STEP_SUMMARY": summary.name}), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(nightly.config(["A"]), 0)
                self.assertEqual(output.read(), f"ready={ready}\n")
                if ready == "false":
                    self.assertIn("`A`", summary.read())

    def test_red_jobs(self) -> None:
        needs = {"suite": {"result": "success"}, "apple-api": {"result": "failure"},
                 "storekit": {"result": "skipped"}, "apple-delivery": {"result": "cancelled"}}
        self.assertEqual(nightly.red_jobs(needs), ["apple-api", "apple-delivery"])

    def test_alert_plan_follows_state_changes(self) -> None:
        self.assertEqual(nightly.plan_alert(True, ""), {"issue": "create", "slack": "red"})
        self.assertEqual(nightly.plan_alert(True, "12"), {"issue": "edit", "slack": ""})
        self.assertEqual(nightly.plan_alert(False, "12"), {"issue": "close", "slack": "green"})
        self.assertEqual(nightly.plan_alert(False, ""), {"issue": "", "slack": ""})

    def test_issue_body_lists_every_job(self) -> None:
        body = nightly.issue_body({"suite": {"result": "failure"}, "storekit": {"result": "success"}},
                                  "https://run", "billing-nightly.yml",
                                  datetime(2026, 11, 16, 9, 41, tzinfo=timezone.utc))
        self.assertIn("| suite | failure |", body)
        self.assertIn("| storekit | success |", body)
        self.assertIn("https://run", body)


if __name__ == "__main__":
    unittest.main()
