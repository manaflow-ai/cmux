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
import json
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

SECRET_JOBS = ("apple-delivery", "apple-api", "apple-post-release", "alert")


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
        for job in ("apple-delivery", "apple-api", "apple-post-release"):
            block = self.jobs[job]
            with self.subTest(job=job):
                self.assertIn("scripts/ci/billing_nightly.py config --environment billing-nightly", block)
                names = re.search(r"billing_nightly\.py config --environment billing-nightly ([A-Z_ ]+)\n", block).group(1).split()
                for name in names:
                    self.assertRegex(block, rf"HAS_{name}: \$\{{\{{ (secrets|vars)\.{name} != '' \}}\}}")
                # Each later step runs only when the configuration is present.
                steps = block.split("      - name: ")[1:]
                for step in steps:
                    if step.startswith(("Checkout", "Check configuration")):
                        continue
                    self.assertRegex(step, r"if: (\$\{\{ \()?steps\.config\.outputs\.ready == 'true'", step.splitlines()[0])

    def test_delivery_covers_both_environments_of_the_app_store_app(self) -> None:
        block = self.jobs["apple-delivery"]
        self.assertIn("environment: [Sandbox, Production]", block)
        self.assertIn("--bundle-id com.cmux.app", block)
        self.assertIn("https://cmux.com/api/cron/apple-notifications/health", block)
        self.assertTrue(CHECK.is_file())

    def test_post_release_check_runs_only_on_request(self) -> None:
        self.assertRegex(self.on, r"post_release_check:\n\s+description: .+\n\s+type: boolean\n\s+default: false")
        block = self.jobs["apple-post-release"]
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.post_release_check", block)
        self.assertIn("apple-nightly-check.ts post-release", block)
        self.assertIn("--bundle-id com.cmux.app", block)

    def test_secret_jobs_run_on_a_literal_runner(self) -> None:
        for job in SECRET_JOBS:
            with self.subTest(job=job):
                runs_on = re.search(r"^    runs-on: (.*)$", self.jobs[job], re.MULTILINE).group(1)
                self.assertNotIn("vars.", runs_on)

    def test_storekit_dispatches_feat_cmux_next(self) -> None:
        block = self.jobs["storekit"]
        # Only a missing file skips; any other API error fails the job.
        self.assertIn('grep -q "HTTP 404"', block)
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

    def run_config(self, env: dict[str, str], rule) -> tuple[int, str, str, str]:
        with tempfile.NamedTemporaryFile("r", suffix=".out") as output, \
                tempfile.NamedTemporaryFile("r", suffix=".md") as summary, \
                mock.patch.dict(os.environ, {**env, "GITHUB_OUTPUT": output.name, "GITHUB_STEP_SUMMARY": summary.name,
                                             "GITHUB_REPOSITORY": "manaflow-ai/cmux"}), \
                mock.patch.object(nightly, "_environment_rule", side_effect=rule), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            code = nightly.config("billing-nightly", ["A"])
            return code, output.read(), summary.read(), out.getvalue()

    def test_config_skips_green_while_secrets_are_missing(self) -> None:
        code, output, summary, _ = self.run_config({"HAS_A": "false"}, AssertionError("not read"))
        self.assertEqual((code, output), (0, "ready=false\n"))
        self.assertIn("`A`", summary)

    def test_config_is_ready_only_when_the_environment_allows_main_alone(self) -> None:
        main_only = lambda _env: ({"custom_branch_policies": True, "protected_branches": False}, [["main", "branch"]])
        self.assertEqual(self.run_config({"HAS_A": "true"}, main_only)[:2], (0, "ready=true\n"))
        for policy, rules in ((None, None),
                              ({"custom_branch_policies": False, "protected_branches": True}, None),
                              ({"custom_branch_policies": True, "protected_branches": False}, [["main", "branch"], ["*", "branch"]]),
                              ({"custom_branch_policies": True, "protected_branches": False}, [["main", "tag"]]),
                              ({"custom_branch_policies": True, "protected_branches": False}, [])):
            with self.subTest(policy=policy, rules=rules):
                code, output, _, out = self.run_config({"HAS_A": "true"}, lambda _env, p=policy, r=rules: (p, r))
                self.assertEqual((code, output), (1, "ready=false\n"))
                self.assertIn("::error::", out)

    def test_config_fails_closed_when_the_rule_cannot_be_read(self) -> None:
        import subprocess
        def broken(_env):
            raise subprocess.CalledProcessError(1, ["gh"])
        code, output, _, _ = self.run_config({"HAS_A": "true"}, broken)
        self.assertEqual((code, output), (1, "ready=false\n"))

    def test_gh_retries_a_transient_failure(self) -> None:
        import subprocess
        calls = []
        def run(argv, **_kw):
            calls.append(argv)
            if len(calls) == 1:
                raise subprocess.CalledProcessError(1, argv, output="", stderr="HTTP 502: Bad Gateway")
            return subprocess.CompletedProcess(argv, 0, stdout=" ok \n", stderr="")
        with mock.patch.object(nightly.subprocess, "run", side_effect=run), mock.patch.object(nightly.time, "sleep"):
            self.assertEqual(nightly._gh("api", "x"), "ok")
        self.assertEqual(len(calls), 2)

    def test_gh_failure_names_gh_stderr(self) -> None:
        import subprocess
        def run(argv, **_kw):
            raise subprocess.CalledProcessError(1, argv, output="", stderr="HTTP 403: API rate limit exceeded")
        with mock.patch.object(nightly.subprocess, "run", side_effect=run), mock.patch.object(nightly.time, "sleep"):
            with self.assertRaises(subprocess.CalledProcessError) as caught:
                nightly._gh("api", "x")
        self.assertIn("rate limit exceeded", str(caught.exception))

    def test_red_jobs(self) -> None:
        needs = {"suite": {"result": "success"}, "apple-api": {"result": "failure"},
                 "storekit": {"result": "skipped"}, "apple-delivery": {"result": "cancelled"}}
        self.assertEqual(nightly.red_jobs(needs), ["apple-api", "apple-delivery"])

    def test_alert_plan_follows_state_changes(self) -> None:
        self.assertEqual(nightly.plan_alert(True, ""), {"issue": "create", "slack": "red"})
        self.assertEqual(nightly.plan_alert(True, "12"), {"issue": "edit", "slack": ""})
        self.assertEqual(nightly.plan_alert(False, "12"), {"issue": "close", "slack": "green"})
        self.assertEqual(nightly.plan_alert(False, ""), {"issue": "", "slack": ""})

    def run_alert(self, needs: dict, open_issue: str, slack: bool = True, notify=None):
        calls: list[tuple[str, ...]] = []
        def gh(*args: str, tries: int = 3) -> str:
            calls.append(args)
            if args[0] == "issue" and args[1] != "list":
                self.assertEqual(tries, 1, f"a write is never retried: {args[:2]}")
            return open_issue if args[:2] == ("issue", "list") else ""
        posted: list[str] = []
        with mock.patch.dict(os.environ, {"NEEDS": json.dumps(needs), "RUN_URL": "https://run"}), \
                mock.patch.object(nightly, "_gh", side_effect=gh), \
                mock.patch.object(nightly, "_notify", side_effect=notify or posted.append), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            code = nightly.alert("Billing nightly is red", "billing-nightly.yml", slack=slack)
        return code, calls, posted, out.getvalue()

    def test_alert_searches_the_exact_title(self) -> None:
        _, calls, _, _ = self.run_alert({"suite": {"result": "success"}}, "")
        search = calls[0]
        self.assertEqual(search[:5], ("issue", "list", "--state", "open", "--search"))
        self.assertIn('select(.title == "Billing nightly is red")', search[-1])

    def test_red_night_opens_an_issue_posts_and_fails(self) -> None:
        code, calls, posted, out = self.run_alert({"suite": {"result": "failure"}, "storekit": {"result": "success"}}, "")
        self.assertEqual(code, 1)
        self.assertEqual(calls[1][:4], ("issue", "create", "--title", "Billing nightly is red"))
        self.assertEqual(len(posted), 1)
        self.assertIn("suite", posted[0])
        self.assertIn("::error::", out)

    def test_later_red_rewrites_the_open_issue_quietly(self) -> None:
        code, calls, posted, _ = self.run_alert({"apple-api": {"result": "cancelled"}}, "77")
        self.assertEqual(code, 1)
        self.assertEqual(calls[1][:3], ("issue", "edit", "77"))
        self.assertEqual(posted, [])

    def test_green_night_closes_the_issue_and_says_so(self) -> None:
        code, calls, posted, _ = self.run_alert({"suite": {"result": "success"}, "storekit": {"result": "skipped"}}, "77")
        self.assertEqual(code, 0)
        self.assertEqual(calls[1][:3], ("issue", "close", "77"))
        self.assertEqual(len(posted), 1)

    def test_no_slack_skips_the_post(self) -> None:
        _, _, posted, _ = self.run_alert({"suite": {"result": "failure"}}, "", slack=False)
        self.assertEqual(posted, [])

    def test_a_slack_failure_never_changes_the_verdict(self) -> None:
        import urllib.error
        def boom(*_args, **_kwargs):
            raise urllib.error.URLError("down")
        with mock.patch.dict(os.environ, {"CMUX_NOTIFY_TOKEN": "t", "CMUX_NOTIFY_URL": "https://notify",
                                          "CMUX_NOTIFY_CHANNEL": "C"}), \
                mock.patch.object(nightly.urllib.request, "urlopen", side_effect=boom), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            nightly._notify("hello")
        self.assertIn("::warning::", out.getvalue())
        with mock.patch.dict(os.environ, {"CMUX_NOTIFY_TOKEN": ""}), contextlib.redirect_stdout(io.StringIO()) as out:
            nightly._notify("hello")
        self.assertIn("::warning::", out.getvalue())

    def test_issue_body_lists_every_job(self) -> None:
        body = nightly.issue_body({"suite": {"result": "failure"}, "storekit": {"result": "success"}},
                                  "https://run", "billing-nightly.yml",
                                  datetime(2026, 11, 16, 9, 41, tzinfo=timezone.utc))
        self.assertIn("| suite | failure |", body)
        self.assertIn("| storekit | success |", body)
        self.assertIn("https://run", body)


if __name__ == "__main__":
    unittest.main()
