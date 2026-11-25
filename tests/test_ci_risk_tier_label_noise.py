#!/usr/bin/env python3
"""A label the grade never reads costs risk tier one GitHub API call, not a full grade.

GitHub runs pull_request_target workflows from main's copy, so risk-tier.yml grades every pull request into
feat-cmux-next, and its types include labeled and unlabeled. cmux-bot's triage labels (area:, harness:, model:,
kind:) started 547 of the 700 newest risk tier runs in the hour 18:52-19:52Z on 2026-11-22 (1,350 runs that
hour). Every sampled run found the glaeda-route App's hour spent (core remaining=0) and graded on GITHUB_TOKEN:
about six calls a run (the files pages, the pull request, its labels; comments and reviews on high), and the
repository's GITHUB_TOKEN hour ran dry within minutes. The grade reads only risk:* labels.

The job still runs for every label (a skipped newest `risk evidence` run reads as a pass,
tests/test_ci_fix_cause_labels_start_no_jobs.py). For a label the grade never reads it reads this head's earlier
risk evidence check runs once and passes only when the newest of them, cancelled ones aside, passed. Anything else
grades in full.

This test runs the job's steps in order, with their `if:` conditions, against a fake gh that counts every call,
and pins the count per run.

Run: python3 tests/test_ci_risk_tier_label_noise.py
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "risk-tier.yml"
sys.path.insert(0, str(ROOT / "tests"))
from test_ci_fix_cause_labels_start_no_jobs import job_runs, unwrap  # noqa: E402

RUN_ID = "4242"
HEAD = "a" * 40

# Logs one JSON line per call (token, argv). `api .../check-runs` answers CHECK_RUNS through the call's own --jq,
# as gh does; FAIL_CHECKS=1 refuses it. Everything else answers empty.
FAKE_GH = textwrap.dedent("""\
    #!/usr/bin/env python3
    import json, os, subprocess, sys
    args = sys.argv[1:]
    with open(os.environ["FAKE_GH_LOG"], "a") as log:
        log.write(json.dumps({"token": os.environ.get("GH_TOKEN"), "args": args}) + "\\n")
    if args[:1] == ["api"] and "/check-runs" in args[1]:
        if os.environ.get("FAIL_CHECKS") == "1":
            sys.exit(1)
        jq = args[args.index("--jq") + 1]
        done = subprocess.run(["jq", "-r", jq], input=os.environ["CHECK_RUNS"], text=True, capture_output=True)
        sys.stdout.write(done.stdout)
        sys.exit(done.returncode)
    if args[:2] == ["pr", "view"]:
        print("risk:normal")
    """)

# Stands in for the base's risk_tier.py: a grade's reads (the files page, the pull request, its labels).
FAKE_RISK_TIER = textwrap.dedent("""\
    import os, subprocess, sys
    for endpoint in ("repos/o/r/pulls/7/files", "repos/o/r/pulls/7", "repos/o/r/issues/7/labels"):
        subprocess.run(["gh", "api", endpoint], check=True)
    open(sys.argv[sys.argv.index("--github-output") + 1], "a").write("tier=normal\\nlabel=risk:normal\\nready=true\\n")
    open(sys.argv[sys.argv.index("--summary") + 1], "a").write("## Risk tier: normal\\n")
    """)
GRADE_CALLS = 3


def check_run(id_: int, status: str = "completed", conclusion: str | None = "success", run: str = "100") -> dict:
    return {"id": id_, "status": status, "conclusion": conclusion, "app": {"slug": "github-actions"},
            "details_url": f"https://github.com/o/r/actions/runs/{run}/job/{id_}"}


def outputs_of(path: Path) -> dict[str, str]:
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)


class LabelNoise(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not shutil.which("jq"):
            raise unittest.SkipTest("jq is not installed")
        cls.steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["evidence"]["steps"]

    def run_job(self, action: str, label: str | None = None, runs: list[dict] | None = None, *,
                attempt: str = "1", fail_checks: bool = False) -> tuple[list[dict], list[str]]:
        """(the gh calls, the names of the steps that ran) for one run of the evidence job."""
        root = Path(tempfile.mkdtemp(prefix="risk-tier-label-noise-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        (root / "scripts" / "ci").mkdir(parents=True)
        (root / "scripts" / "ci" / "risk_tier.py").write_text(FAKE_RISK_TIER)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text(FAKE_GH)
        (bin_dir / "gh").chmod(0o755)
        log = root / "gh.log"
        log.touch()
        event = {"action": action, "pull_request": {"number": 7, "deletions": 0, "head": {"sha": HEAD}}}
        if label is not None:
            event["label"] = {"name": label}
        context = {"github": {"event": event, "run_attempt": attempt, "run_id": RUN_ID},
                   "vars": {"GLAEDA_ROUTE_APP_ID": ""}, "steps": {}}
        ran = []
        for step in self.steps:
            if not job_runs(step.get("if"), context, {}):
                if step.get("id"):
                    context["steps"][step["id"]] = {"outputs": {}, "outcome": "skipped"}
                continue
            ran.append(step["name"])
            if "run" not in step:
                continue  # checkout: git, no REST call
            output, summary = root / f"out-{len(ran)}", root / "summary"
            output.touch()
            env = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "GH_"))}
            env.update(PATH=f"{bin_dir}:{os.environ['PATH']}", FAKE_GH_LOG=str(log), GH_TOKEN="workflow",
                       READ_TOKEN="", REPO="o/r", NUMBER="7", HEAD_SHA=HEAD, RUN_ID=RUN_ID,
                       LABEL_NAME=label or "", LABEL="risk:normal", RUNNER_TEMP=str(root), GITHUB_OUTPUT=str(output),
                       GITHUB_STEP_SUMMARY=str(summary), CHECK_RUNS=json.dumps({"check_runs": runs or []}),
                       FAIL_CHECKS="1" if fail_checks else "0", PROBE="probe")
            done = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step["run"]],
                                  cwd=root, env=env, capture_output=True, text=True, timeout=60)
            if not step.get("continue-on-error"):
                self.assertEqual(done.returncode, 0, f"{step['name']}: {done.stdout}{done.stderr}")
            if step.get("id"):
                context["steps"][step["id"]] = {"outputs": outputs_of(output),
                                                "outcome": "success" if done.returncode == 0 else "failure"}
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        return [c for c in calls if c["args"][:2] != ["api", "rate_limit"]], ran

    def assert_graded(self, calls: list[dict], ran: list[str], extra: int) -> None:
        self.assertIn("Grade the pull request", ran)
        self.assertGreaterEqual(len(calls), GRADE_CALLS + extra)

    # ---- the case this is for: cmux-bot's triage labels

    def test_a_triage_label_on_a_passed_head_costs_one_call(self) -> None:
        for action in ("labeled", "unlabeled"):
            for label in ("area: localization", "harness:claude", "model:claude-fable-5-2", "kind: perf"):
                with self.subTest(action=action, label=label):
                    calls, ran = self.run_job(action, label, [check_run(10)])
                    self.assertEqual(len(calls), 1, calls)
                    self.assertIn("/check-runs", calls[0]["args"][1])
                    self.assertNotIn("Grade the pull request", ran)
                    self.assertNotIn("Set the risk label", ran)
                    self.assertNotIn("Hold only an unowned takeback", ran)

    def test_cancelled_runs_are_passed_over(self) -> None:
        # A burst of triage labels cancels its own runs; the pass under them stands.
        runs = [check_run(10), check_run(11, conclusion="cancelled", run="101"),
                check_run(12, conclusion="cancelled", run="102")]
        calls, _ = self.run_job("labeled", "area: ci", runs)
        self.assertEqual(len(calls), 1)

    def test_this_run_is_not_its_own_evidence(self) -> None:
        calls, ran = self.run_job("labeled", "area: ci", [check_run(10, status="in_progress", conclusion=None,
                                                                    run=RUN_ID)])
        self.assert_graded(calls, ran, extra=1)

    # ---- everything else grades in full

    def test_a_head_with_no_pass_to_carry_is_graded(self) -> None:
        cases = {
            "no run yet": [],
            "a grade in flight": [check_run(10), check_run(11, status="in_progress", conclusion=None, run="101")],
            "a grade queued": [check_run(10), check_run(11, status="queued", conclusion=None, run="101")],
            "a red": [check_run(10), check_run(11, conclusion="failure", run="101")],
            "a skip": [check_run(10, conclusion="skipped")],
            "another app's check of that name": [{**check_run(10), "app": {"slug": "someone-else"}}],
        }
        for name, runs in cases.items():
            with self.subTest(name):
                calls, ran = self.run_job("labeled", "area: ci", runs)
                self.assert_graded(calls, ran, extra=1)

    def test_an_unreadable_list_is_graded(self) -> None:
        calls, ran = self.run_job("labeled", "area: ci", [check_run(10)], fail_checks=True)
        self.assert_graded(calls, ran, extra=1)

    def test_a_re_run_is_graded(self) -> None:
        calls, ran = self.run_job("labeled", "area: ci", [check_run(10)], attempt="2")
        self.assert_graded(calls, ran, extra=0)
        self.assertFalse(any("/check-runs" in c["args"][1] for c in calls))

    def test_the_labels_the_grade_reads_are_graded(self) -> None:
        for label in ("risk:human-ok", "risk:waived", "risk:normal", "Risk:High"):
            with self.subTest(label=label):
                calls, ran = self.run_job("labeled", label, [check_run(10)])
                self.assert_graded(calls, ran, extra=0)
                self.assertFalse(any("/check-runs" in c["args"][1] for c in calls))

    def test_other_events_are_graded_without_the_extra_read(self) -> None:
        for action in ("opened", "synchronize", "reopened", "edited", "ready_for_review"):
            with self.subTest(action=action):
                calls, ran = self.run_job(action, None, [check_run(10)])
                self.assert_graded(calls, ran, extra=0)
                self.assertFalse(any("/check-runs" in c["args"][1] for c in calls))

    # ---- the shape that keeps the count honest

    def test_the_job_never_skips_and_a_triage_label_never_cancels_a_grade(self) -> None:
        job = yaml.safe_load(WORKFLOW.read_text())["jobs"]["evidence"]
        self.assertNotIn("if", job)
        group = unwrap(job["concurrency"]["group"].split("}}", 1)[1] + "}}")
        self.assertIn("'-label'", group)
        self.assertEqual(job["permissions"].get("checks"), "read")

    def test_every_step_that_spends_the_api_waits_for_the_carry(self) -> None:
        # A new reader added after the carry step must skip when the verdict was carried, or this count creeps.
        names = [s["name"] for s in self.steps]
        carry = names.index("Carry the head's verdict over a label the grade never reads")
        self.assertEqual(carry, 0)
        for step in self.steps[1:]:
            with self.subTest(step=step["name"]):
                condition = str(step.get("if", ""))
                gated = "steps.carry.outputs.carried != 'true'" in condition
                probe = "steps.glaeda-token.outputs.token" in condition  # the mint itself waits for the carry
                self.assertTrue(gated or probe, condition)


if __name__ == "__main__":
    unittest.main()
