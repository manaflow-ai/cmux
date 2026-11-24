#!/usr/bin/env python3
"""Tests for ci-queue-janitor-watchdog.yml's alert step, run with a fake `gh` (no network).

A stale janitor snapshot is not proof of no runners: cmux#47855 paged
"Runner label starved: cmux-fleet-linux-x64" while that label had 64 runners
online and 82 busy, and the sweep itself waited 77 minutes for one. The step
reads the label's live roster (scripts/ci/janitor_watchdog_roster.py) first.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/ci-queue-janitor-watchdog.yml"
STEP = "Open the starved-label issue when the newest sweep snapshot is stale"
LABEL = "cmux-fleet-linux-x64"
REPO = "manaflow-ai/cmux"
TITLE = f"Runner label starved: {LABEL}"
WATCHDOG_LEAD = "No queue janitor sweep has published a macos-pool-load snapshot for"

FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state = Path(os.environ["FAKE_GH_STATE"])
args = sys.argv[1:]
with open(state / "calls.jsonl", "a") as log:
    log.write(json.dumps({"args": args, "token": os.environ.get("GH_TOKEN", "")}) + "\n")
if args[:1] == ["api"]:
    path = args[1].split("?")[0]
    if path.endswith("/actions/artifacts"):
        print(os.environ["FAKE_NEWEST"])
        sys.exit(0)
    if "runner" in path:
        if os.environ.get("FAKE_ROSTER_FAIL"):
            print("HTTP 403: Resource not accessible by integration", file=sys.stderr)
            sys.exit(1)
        roster = json.loads((state / "roster.json").read_text())
        if path.endswith("/runner-groups"):
            print(json.dumps({"runner_groups": [{"id": int(key)} for key in roster["groups"]]}))
        elif "/runner-groups/" in path:
            print(json.dumps({"runners": roster["groups"][path.split("/")[-2]]}))
        else:
            print(json.dumps({"runners": roster["repo"]}))
        sys.exit(0)
if args[:2] == ["issue", "list"]:
    print((state / "issues.json").read_text())
    sys.exit(0)
sys.exit(0)
'''


def runner(ident: int, *, status: str = "online", busy: bool = False, label: str = LABEL) -> dict:
    return {"id": ident, "name": f"r{ident}", "os": "Linux", "status": status, "busy": busy,
            "labels": [{"name": "self-hosted"}, {"name": label}]}


def step_script() -> str:
    workflow = yaml.safe_load(WORKFLOW.read_text())
    steps = workflow["jobs"]["watch"]["steps"]
    return next(step["run"] for step in steps if step.get("name") == STEP)


class WatchdogStepTests(unittest.TestCase):
    def setUp(self) -> None:
        if shutil.which("bash") is None or shutil.which("date") is None:
            self.skipTest("bash and date are required")
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        self.bin = bin_dir
        self.summary = self.tmp / "summary.md"
        self.write_issues([])

    def write_issues(self, issues: list) -> None:
        (self.tmp / "issues.json").write_text(json.dumps(issues))

    def run_step(self, *, repo_runners=(), groups=None, age_seconds=9159, route_token="route-token",
                 roster_fail=False, label=LABEL) -> subprocess.CompletedProcess:
        (self.tmp / "roster.json").write_text(json.dumps({"repo": list(repo_runners), "groups": groups or {}}))
        newest = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=age_seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")
        env = {
            "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}",
            "HOME": str(self.tmp),
            "GH_TOKEN": "workflow-token",
            "GH_REPO": REPO,
            "LABEL": label,
            "STALE_SECONDS": "1800",
            "ROUTE_TOKEN": route_token,
            "GITHUB_STEP_SUMMARY": str(self.summary),
            "FAKE_GH_STATE": str(self.tmp),
            "FAKE_NEWEST": newest,
        }
        if roster_fail:
            env["FAKE_ROSTER_FAIL"] = "1"
        return subprocess.run(["bash", "-c", step_script()], cwd=ROOT, env=env, capture_output=True, text=True,
                              timeout=60, check=False)

    def calls(self) -> list[dict]:
        path = self.tmp / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def issue_writes(self, verb: str) -> list[list[str]]:
        return [call["args"] for call in self.calls() if call["args"][:2] == ["issue", verb]]

    def body_of(self, args: list[str]) -> str:
        return args[args.index("--body") + 1]

    def test_a_saturated_label_with_a_stale_snapshot_is_not_filed_as_starved(self) -> None:
        # cmux#47855: the label's runners were online and busy; the sweep only waited behind its queue.
        busy = [runner(i, busy=True) for i in range(1, 4)] + [runner(9, status="offline")]
        done = self.run_step(groups={"7": busy})
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.issue_writes("create"), [])
        self.assertEqual(self.issue_writes("comment"), [])
        self.assertIn(f"Runner label saturated: {LABEL}", done.stdout)
        self.assertIn("3 online (3 busy, 0 idle), 1 offline or booting", self.summary.read_text())

    def test_the_roster_is_read_with_the_routing_token(self) -> None:
        self.run_step(repo_runners=[runner(1, busy=True)])
        roster_calls = [call for call in self.calls() if call["args"][:1] == ["api"] and "runner" in call["args"][1]]
        self.assertTrue(roster_calls)
        self.assertEqual({call["token"] for call in roster_calls}, {"route-token"})

    def test_an_online_runner_on_another_label_does_not_make_this_one_saturated(self) -> None:
        done = self.run_step(repo_runners=[runner(1, label="blacksmith-4vcpu-ubuntu-2404")],
                             groups={"7": [runner(2, status="offline")]})
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        [create] = self.issue_writes("create")
        self.assertIn(TITLE, create)
        self.assertIn(f"no runner carrying `{LABEL}` is online", self.body_of(create))

    def test_an_unreadable_roster_keeps_the_alert_and_names_it_unknown(self) -> None:
        done = self.run_step(roster_fail=True)
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        [create] = self.issue_writes("create")
        self.assertIn(TITLE, create)
        self.assertIn("unknown", self.body_of(create))

    def test_no_routing_token_keeps_the_alert_and_names_the_roster_unknown(self) -> None:
        done = self.run_step(route_token="")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        [create] = self.issue_writes("create")
        self.assertIn("no routing token was minted", self.body_of(create))

    def test_a_jit_sweep_label_reads_no_roster_and_names_the_variable(self) -> None:
        # The sweep runs on the one-job repair VM cmux-gcp-repair-jit-x64 by default (GitHub-hosted Ubuntu starts
        # nothing in manaflow-ai). A JIT label has no standing roster: the scaler mints a VM per queued job, so an
        # idle roster read would always say starved; the alert names the variable instead.
        done = self.run_step(label="cmux-gcp-repair-jit-x64", repo_runners=[runner(1)])
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertEqual([call for call in self.calls() if call["args"][:1] == ["api"] and "runner" in call["args"][1]], [])
        [create] = self.issue_writes("create")
        body = self.body_of(create)
        self.assertIn("Runner label starved: cmux-gcp-repair-jit-x64", create)
        self.assertIn("one-job JIT label", body)
        self.assertIn("CI_QUEUE_JANITOR_ON_FLEET=1", body)
        self.assertNotIn("roster", body)

    def test_a_fresh_snapshot_reads_no_roster_and_files_nothing(self) -> None:
        done = self.run_step(age_seconds=60, repo_runners=[runner(1)])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual([call for call in self.calls() if "runner" in " ".join(call["args"])], [])
        self.assertEqual(self.issue_writes("create"), [])

    def test_saturation_closes_only_the_starved_issue_this_watchdog_filed(self) -> None:
        if shutil.which("jq") is None:
            self.skipTest("jq is required")
        self.write_issues([
            {"number": 11, "title": TITLE, "body": f"{WATCHDOG_LEAD} 9159s (newest: x)."},
            {"number": 12, "title": TITLE, "body": "`cmux-fleet-linux-x64`: 2 job(s) queued (the sweep's own alert)"},
        ])
        done = self.run_step(repo_runners=[runner(1, busy=True)])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual([args[2] for args in self.issue_writes("close")], ["11"])


class ClassifyTests(unittest.TestCase):
    def setUp(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("janitor_watchdog_roster",
                                                      ROOT / "scripts/ci/janitor_watchdog_roster.py")
        assert spec and spec.loader
        self.roster = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.roster)

    def test_an_idle_online_runner_is_saturated_not_starved(self) -> None:
        self.assertEqual(self.roster.classify(LABEL, [runner(1)])[0], "saturated")

    def test_only_offline_runners_is_starved(self) -> None:
        self.assertEqual(self.roster.classify(LABEL, [runner(1, status="offline")])[0], "starved")

    def test_no_runner_at_all_is_starved(self) -> None:
        self.assertEqual(self.roster.classify(LABEL, [])[0], "starved")

    def test_a_runner_in_both_listings_counts_once(self) -> None:
        pages = {f"repos/{REPO}/actions/runners": {"runners": [runner(1, busy=True)]},
                 "orgs/manaflow-ai/actions/runner-groups": {"runner_groups": [{"id": 7}]},
                 "orgs/manaflow-ai/actions/runner-groups/7/runners": {"runners": [runner(1, busy=True)]}}
        found = self.roster.roster(lambda path: pages[path.split("?")[0]], REPO)
        self.assertEqual(len(found), 1)

    def test_a_failed_read_is_unknown(self) -> None:
        def fail(path: str):
            raise RuntimeError("HTTP 403")
        state, detail = self.roster.verdict({"LABEL": LABEL, "GH_REPO": REPO}, fetch=fail)
        self.assertEqual(state, "unknown")
        self.assertIn("HTTP 403", detail)


if __name__ == "__main__":
    unittest.main()
