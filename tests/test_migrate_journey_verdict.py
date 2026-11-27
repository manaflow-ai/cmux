#!/usr/bin/env python3
"""scripts/cmux-next/migrate-journey-ci.sh ends with its own verdict, and a staging failure never hides a CLI red.

The migrate journey ran its cases one after another against staging, and staging's slow or failed creates
(cloud.machine.create_overdue, an unreachable Cloud API) plus their retries ran it past the job's 50-minute
timeout: 13 of 15 runs before 2026-11-27 ended cancelled, with no verdict at all (run 45899973376). The script
now runs the cases side by side, bounds every attempt by MIGRATE_JOURNEY_END_BY, and names each case pass, red,
timeout or staging. This runs it on local repos with a stub `cmux` and pins:
- every case passing exits 0; a staging failure that passes on retry exits 0;
- a case staging failed twice beside passes exits 0, warns and is `staging` in verdict.json;
- a CLI failure exits 1, including a capacity-sounding message at any step but `create-machine`;
- staging stopping every case exits 4, not 0: nothing was verified;
- an apply that hangs ends at the budget as `timeout` and exits 1, well before the job would be cancelled;
- migrate-journey-pr.yml sets the budget at least 3 minutes inside the migrate job's timeout-minutes.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cmux-next" / "migrate-journey-ci.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "migrate-journey-pr.yml"

# The stub CLI: `migrate plan` reads one project; `migrate apply` plays the outcome STUB_PLAN names for this
# case (by its HOME's folder) and attempt, as the real apply's JSON events on stderr.
STUB = r'''#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
home = os.environ["HOME"]
case = os.path.basename(home).removeprefix("home-")
if args[:2] == ["migrate", "plan"]:
    print(json.dumps({"projects": [{"path": "."}], "source": {"kind": "devcontainer"}}))
    sys.exit(0)
counter = os.path.join(home, "attempts")
n = int(open(counter).read()) if os.path.exists(counter) else 0
open(counter, "w").write(str(n + 1))
plan = json.loads(os.environ["STUB_PLAN"]).get(case, ["pass"])
outcome = plan[min(n, len(plan) - 1)]
def failed(step, detail):
    print(json.dumps({"event": "failed", "step": step, "detail": detail, "project": "."}), file=sys.stderr)
    sys.exit(1)
if outcome == "pass":
    os.makedirs(os.path.join(home, ".cmux", "migrate"), exist_ok=True)
    ledger = {"projects": {".": {"started_ms": 1000, "first_chat_ms": 451000}}}
    json.dump(ledger, open(os.path.join(home, ".cmux", "migrate", "ledger.json"), "w"))
    print(json.dumps({"events": [], "failed": 0}))
    print(json.dumps({"event": "done", "step": "create-machine", "detail": "machine vm_x"}), file=sys.stderr)
elif outcome == "overdue":
    failed("create-machine", 'running (status): failed: Some(CloudMachineError { code: "cloud.machine.create_overdue", message: "the machine\'s create did not settle within 300 s" })')
elif outcome == "unreachable":
    failed("create-machine", "create machine:  could not reach the Cloud API: error sending request for url (https://cloud-api-staging.example/v1/ops)")
elif outcome == "bad_config":
    failed("create-machine", "create machine: the Cloud API answered HTTP 400: machine config: unknown key `imagee`")
elif outcome == "reply_ratelimit":
    failed("reply", "the agent's reply never came: 429 too many requests from the model stub")
elif outcome == "hang":
    time.sleep(600)
'''


def git_repo(path: Path) -> str:
    path.mkdir(parents=True)
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
    subprocess.run(["git", "init", "-q", "-b", "main", str(path)], check=True, env=env)
    (path / "README.md").write_text("x\n")
    subprocess.run(["git", "-C", str(path), "add", "."], check=True, env=env)
    subprocess.run(["git", "-C", str(path), "commit", "-qm", "x"], check=True, env=env)
    return f"file://{path}"


class Verdicts(unittest.TestCase):
    def run_script(self, plan: dict, budget_s: int = 600) -> tuple[int, dict, str, float]:
        tmp = Path(tempfile.mkdtemp(prefix="migrate-verdict-"))
        stub = tmp / "cmux"
        stub.write_text(STUB)
        stub.chmod(0o755)
        repos = [git_repo(tmp / "repos" / name) for name in ("try-node", "try-python")]
        env = {k: v for k, v in os.environ.items() if not k.startswith(("MIGRATE_", "GITHUB_"))}
        env.update({
            "CMUX_PATH": str(stub), "TARGET": "staging", "RUNNER_TEMP": str(tmp / "runner"),
            "GITHUB_STEP_SUMMARY": str(tmp / "summary.md"),
            "CMUX_DOGFOOD_STACK_EMAIL": "e", "CMUX_DOGFOOD_STACK_PASSWORD": "p",
            "MIGRATE_REPOS": " ".join(repos), "MIGRATE_T3_REPO": repos[0],
            "MIGRATE_JOURNEY_END_BY": str(int(time.time()) + budget_s),
            "MIGRATE_JOURNEY_STAGGER_S": "0", "MIGRATE_JOURNEY_RETRY_BACKOFF_S": "0",
            "MIGRATE_JOURNEY_RETRY_MIN_S": "1", "MIGRATE_JOURNEY_MIN_ATTEMPT_S": "1",
            "STUB_PLAN": json.dumps(plan),
        })
        started = time.monotonic()
        done = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=120)
        verdict = json.loads((tmp / "runner" / "migrate-journey" / "verdict.json").read_text())
        return done.returncode, verdict, done.stdout + done.stderr, time.monotonic() - started

    def results(self, verdict: dict) -> dict:
        return {row["name"]: row["result"] for row in verdict["cases"]}

    def test_every_case_passing_exits_zero(self) -> None:
        rc, verdict, _, _ = self.run_script({})
        self.assertEqual(rc, 0)
        self.assertEqual(verdict["verdict"], "pass")
        self.assertEqual(set(self.results(verdict).values()), {"pass"})
        self.assertEqual({row["first_chat_ms"] for row in verdict["cases"]}, {450000})

    def test_a_staging_failure_that_passes_on_retry_passes(self) -> None:
        rc, verdict, _, _ = self.run_script({"try-node": ["overdue", "pass"]})
        self.assertEqual(rc, 0)
        node = next(row for row in verdict["cases"] if row["name"] == "try-node")
        self.assertEqual((node["result"], node["attempts"]), ("pass", 2))

    def test_staging_beside_passes_passes_and_names_the_case(self) -> None:
        rc, verdict, log, _ = self.run_script({"try-python": ["unreachable", "overdue"]})
        self.assertEqual(rc, 0, log)
        self.assertEqual(verdict["verdict"], "pass")
        self.assertEqual(self.results(verdict)["try-python"], "staging")
        self.assertIn("staging, not the CLI", log)

    def test_a_cli_failure_at_create_is_red(self) -> None:
        rc, verdict, _, _ = self.run_script({"try-python": ["bad_config"]})
        self.assertEqual(rc, 1)
        self.assertEqual(self.results(verdict)["try-python"], "red")

    def test_capacity_words_past_create_machine_are_still_red(self) -> None:
        rc, verdict, _, _ = self.run_script({"t3code": ["reply_ratelimit"]})
        self.assertEqual(rc, 1)
        self.assertEqual(self.results(verdict)["t3code"], "red")

    def test_staging_and_a_red_is_red(self) -> None:
        rc, verdict, _, _ = self.run_script({"try-node": ["overdue"], "try-python": ["bad_config"]})
        self.assertEqual(rc, 1)
        self.assertEqual(verdict["verdict"], "red")

    def test_staging_stopping_every_case_exits_four(self) -> None:
        plan = {name: ["overdue"] for name in ("try-node", "try-python", "t3code")}
        rc, verdict, log, _ = self.run_script(plan)
        self.assertEqual(rc, 4, log)
        self.assertEqual(verdict["verdict"], "staging_unavailable")
        self.assertIn("staging unavailable", log)

    def test_a_hang_ends_at_the_budget_as_red(self) -> None:
        rc, verdict, _, wall = self.run_script({"try-node": ["hang"]}, budget_s=6)
        self.assertEqual(rc, 1)
        self.assertEqual(self.results(verdict)["try-node"], "timeout")
        self.assertLess(wall, 60)


class Deadline(unittest.TestCase):
    def test_the_budget_ends_inside_the_job_timeout(self) -> None:
        import yaml

        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["migrate"]
        runs = [str(step.get("run", "")) for step in job["steps"]]
        deadline = next((r for r in runs if "MIGRATE_JOURNEY_END_BY=" in r), "")
        found = re.search(r"\+ (\d+) \* 60", deadline)
        self.assertIsNotNone(found, "the migrate job sets no MIGRATE_JOURNEY_END_BY of now + N * 60")
        self.assertLessEqual(int(found.group(1)), int(job["timeout-minutes"]) - 3)
        self.assertEqual(runs.index(deadline), 0, "the deadline is the job's first step, so it counts from the start")


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
