"""scripts/ci/needs_verdict.py, the one rule for a summary gate's `needs.<job>.result`, and every copy of it.

Class: a summary or status poster turning "nothing judged" into a red, or into a pass. On 2026-11-09 the
cmux-next/fast-gates poster (#39743) and the `rust workspaces` summary (#39791) each read an `abandoned` dependency
as the pull request's own red, because every gate wrote its own `== success` test. Detector: this file.
`test_every_summary_step_reading_needs_results_uses_the_rule` fails when a step that reads needs results neither
carries the rule nor is listed (NOT_MERGE_GATES, MARKER_STEPS) with its reason, or carries the rule but still compares
a result with success itself; `test_no_summary_job_is_skipped_or_fed_by_a_needs_result` fails when a summary job's
`if:` or `with:` reads a needs result (JOB_IF_READS lists the route skips, with why).
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))

import needs_verdict as nv  # noqa: E402

WORKFLOWS = ROOT / ".github/workflows"
NEEDS_RESULT = re.compile(r"needs\.[\w-]+\.result|toJSON\(needs\)")
# A hand-written verdict: a result compared with success (`== success`, `!= "success"`, `not in {"success", ...}`).
SUCCESS_TEST = re.compile(r"""[!=]=\s*["']?success\b|\bsuccess["']?\s*[!=]=|\bin\s*[{(\[]\s*["']success["']""")

# (results, may_skip, state): the table every copy of the rule answers the same way.
TABLE = (
    ({"a": "success"}, (), nv.PASS),
    ({"a": "success", "b": "success"}, (), nv.PASS),
    ({"a": "skipped"}, ("a",), nv.PASS),
    ({"a": "failure"}, (), nv.FAIL),
    ({"a": "failure", "b": "abandoned"}, (), nv.FAIL),
    ({"a": "cancelled", "b": "failure"}, (), nv.FAIL),
    ({"a": "invalid route web=None"}, (), nv.FAIL),
    ({"a": "failure (route x=true)"}, (), nv.FAIL),
    ({"a": "invalid: not among the needs"}, (), nv.FAIL),  # a required job missing from needs is a config red
    ({"a": "success", "b": "invalid: not among the needs"}, ("b",), nv.FAIL),
    ({"a": "abandoned"}, (), nv.NONE),
    ({"a": "cancelled"}, (), nv.NONE),
    ({"a": "timed_out"}, (), nv.NONE),
    ({"a": "skipped"}, (), nv.NONE),
    ({"a": ""}, (), nv.NONE),
    ({"a": "something-new"}, (), nv.NONE),
    ({"a": "success", "b": "abandoned"}, (), nv.NONE),
    ({"a": "cancelled (route x=true)"}, (), nv.NONE),
    ({"a": "abandoned", "b": "failure", "c": "skipped"}, ("b", "c"), nv.FAIL),  # a failure wins over no verdict
    ({"a": "success", "b": "failure"}, ("b",), nv.FAIL),  # may skip, never may fail
)

# Steps that read needs results but are not a merge gate's summary, each with why the rule does not apply.
NOT_MERGE_GATES = {
    ("ci-macos.yml", "macos-status"): "classic main CI only (called from ci.yml); classic is frozen",
    ("ci.yml", "macos-admission-gate"): "an admission, not a verdict: only a concluded failure declines",
    ("ci.yml", "linux-preflight"): "classic main CI only; skips feat-cmux-next",
    ("ci.yml", "ci-status"): "classic main CI only; skips feat-cmux-next",
    ("cloud-chat-proof.yml", "verdict"): "a workflow_dispatch proof run on feat-cmux-next, not a merge gate",
    ("cloud-vm-image-roll.yml", "report"): "a roll's record, not a merge gate",
    ("cmux-next-fast-gates.yml", "post"): "a status poster: posts pending for no verdict (#39791)",
    ("cmux-next-media.yml", "hand-off"): "media comment, not a gate",
    ("cmux-next-media.yml", "publish"): "media comment, not a gate",
    ("cmux-next-perf-budgets.yml", "report"): "a perf report, not a merge gate",
    ("cmux-next.yml", "compile-status-handoff"): "a status poster: cmux-next/compile carries the fallback's verdict; "
                                                 "no fallback run posts error with the no-verdict marker (exit 3)",
    ("cmux-next.yml", "generated-verdict"): "its own no-verdict line (base_red_excuse GENERATED_NO_VERDICT)",
    ("cmux-next.yml", "release-compile-fast-admission"): "push-only promotion step, after the merge",
    ("cmux-vm.yml", "image-roll-settle"): "an image roll's settle, not a merge gate",
    ("nightly.yml", "prepare-nightly-variant"): "nightly, not a merge gate",
    ("nightly.yml", "publish-nightly"): "nightly, not a merge gate",
    ("nightly.yml", "report-nightly-failure"): "nightly report, not a merge gate",
    ("sdk-release-cut.yml", "summarize"): "release cut, not a merge gate",
    ("stable-next.yml", "report"): "stable release report, not a merge gate",
}


# Summary steps that read a verdict from a job's output as well as its result, so they print the rule's marker
# themselves instead of calling it; each still never turns "nothing judged" into a pass or the PR's own red.
MARKER_STEPS = {
    ("cmux-next.yml", "fast-tier"): "the fleet's own verdict output (pass/fail) decides, its result alone does not",
    ("cmux-next.yml", "crash-ends-app"): "the compile's crash_gate output decides; its result only says why it is empty",
}
# Summary jobs whose job-level `if:` reads a needs result (the gate is skipped, so it reads as passed), with why that
# skip is a route and not a verdict.
JOB_IF_READS = {
    ("cmux-next.yml", "crash-ends-app"): "a skipped compile is a route that asked for no app build; the compile's own "
                                         "check says so",
}


def summary_jobs():
    """(workflow file, job id, job) for every job with a step that reads a needs result, or a `with:` that does."""
    for path in sorted(WORKFLOWS.glob("*.yml")):
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        for job_id, job in (doc.get("jobs") or {}).items():
            if NEEDS_RESULT.search(json.dumps(job.get("with") or {})) or any(
                    NEEDS_RESULT.search(json.dumps(step.get("env") or {})) or NEEDS_RESULT.search(step.get("run") or "")
                    for step in job.get("steps") or []):
                yield path.name, job_id, job


def summary_steps():
    """(workflow file, job id, step) for every step that reads a needs result."""
    for path in sorted(WORKFLOWS.glob("*.yml")):
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        for job_id, job in (doc.get("jobs") or {}).items():
            for step in job.get("steps") or []:
                if NEEDS_RESULT.search(json.dumps(step.get("env") or {})) or NEEDS_RESULT.search(step.get("run") or ""):
                    yield path.name, job_id, step


def step(workflow: str, job: str, name: str) -> dict:
    doc = yaml.safe_load((WORKFLOWS / workflow).read_text(encoding="utf-8"))
    return next(s for s in doc["jobs"][job]["steps"] if s.get("name") == name)


def run_bash(body: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as tmp:
        # A CI run's own push event never reaches a step under test: superseded_push would read the live branch head.
        full = {**os.environ, "GITHUB_STEP_SUMMARY": str(Path(tmp) / "summary"), "GITHUB_EVENT_NAME": "", **env}
        return subprocess.run(["bash", "-e", "-c", body], env=full, capture_output=True, text=True, stdin=subprocess.DEVNULL)


class Rule(unittest.TestCase):
    def test_the_table(self):
        for results, may_skip, state in TABLE:
            with self.subTest(results=results, may_skip=may_skip):
                self.assertEqual(nv.judge(results, may_skip)[0], state)

    def test_the_command_line_marks_no_verdict_and_exits_by_state(self):
        for results, may_skip, state in TABLE:
            with self.subTest(results=results):
                args = ["--what", "w", *(f"{k}={v}" for k, v in results.items())]
                if may_skip:
                    args += ["--may-skip", ",".join(may_skip)]
                done = subprocess.run([sys.executable, str(ROOT / "scripts/ci/needs_verdict.py"), *args],
                                      capture_output=True, text=True, stdin=subprocess.DEVNULL)
                self.assertEqual(done.returncode, nv.exit_code(state), done.stdout + done.stderr)
                self.assertEqual("::error::no verdict: w:" in done.stdout, state == nv.NONE, done.stdout)

    def test_the_shell_copy_answers_the_table(self):
        for results, may_skip, state in TABLE:
            with self.subTest(results=results):
                pairs = " ".join(f"'{k}{'?' if k in may_skip else ''}={v}'" for k, v in results.items())
                done = run_bash(nv.SHELL_RULE + f"needs_verdict w {pairs}", {})
                self.assertEqual(done.returncode, nv.exit_code(state), done.stdout + done.stderr)
                self.assertEqual("::error::no verdict: w:" in done.stdout, state == nv.NONE, done.stdout)

    def test_the_python_copy_answers_the_table(self):
        for results, may_skip, state in TABLE:
            with self.subTest(results=results):
                code = "import sys\n" + nv.PYTHON_RULE + f"exit_with_verdict({results!r}, 'w', {set(may_skip)!r})\n"
                done = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                                      stdin=subprocess.DEVNULL)
                self.assertEqual(done.returncode, nv.exit_code(state), done.stdout + done.stderr)
                self.assertEqual("::error::no verdict: w:" in done.stdout, state == nv.NONE, done.stdout)


class Copies(unittest.TestCase):
    def test_every_copy_in_a_workflow_is_the_rule_verbatim(self):
        shell_head = nv.SHELL_RULE.splitlines()[0]
        python_head = nv.PYTHON_RULE.splitlines()[0]
        seen = 0
        for workflow, job, st in summary_steps():
            body = st.get("run") or ""
            for head, rule in ((shell_head, nv.SHELL_RULE), (python_head, nv.PYTHON_RULE)):
                if head in body:
                    seen += 1
                    with self.subTest(workflow=workflow, job=job):
                        start = body.index(head)
                        copy = body[start:start + len(rule)]
                        self.assertEqual(copy, rule, "copy needs_verdict.py's rule verbatim")
        self.assertGreaterEqual(seen, 8)

    def test_every_summary_step_reading_needs_results_uses_the_rule(self):
        uses = (nv.SHELL_RULE.splitlines()[0], nv.PYTHON_RULE.splitlines()[0], "web_validation.py check")
        listed, marked = set(), set()
        for workflow, job, st in summary_steps():
            if (workflow, job) in NOT_MERGE_GATES:
                listed.add((workflow, job))
                continue
            body = st.get("run") or ""
            with self.subTest(workflow=workflow, job=job, step=st.get("name")):
                if (workflow, job) in MARKER_STEPS:
                    marked.add((workflow, job))
                    self.assertIn("::error::no verdict: ", body)
                    continue
                self.assertTrue(any(u in body for u in uses),
                                "a summary step that reads needs results must use scripts/ci/needs_verdict.py's rule "
                                "(or be listed in NOT_MERGE_GATES with why)")
                own = body.replace(nv.SHELL_RULE, "").replace(nv.PYTHON_RULE, "")
                left = [line.strip() for line in own.splitlines() if SUCCESS_TEST.search(line)]
                self.assertEqual(left, [], "a step on the rule still compares a result with success itself: give the "
                                           "rule every result (and the jobs that may skip) instead")
        self.assertEqual(listed, set(NOT_MERGE_GATES), "a NOT_MERGE_GATES entry that no longer exists")
        self.assertEqual(marked, set(MARKER_STEPS), "a MARKER_STEPS entry that no longer exists")

    def test_a_step_calls_the_rule_once(self):
        """A second call lets the first one's no verdict end the step before the second sees a failure, and a failure
        always wins (cmux#39857 review: test-ios with detect-ios-changes abandoned and runner failed said no verdict)."""
        calls = 0
        for workflow, job, st in summary_steps():
            body = st.get("run") or ""
            own = body.replace(nv.SHELL_RULE, "").replace(nv.PYTHON_RULE, "")
            count = len(re.findall(r"^\s*(?:needs_verdict\s|.*\bexit_with_verdict\()", own, re.M))
            if count:
                calls += 1
                with self.subTest(workflow=workflow, job=job, step=st.get("name")):
                    self.assertEqual(count, 1, "call the rule once, with every result and the jobs that may skip")
        self.assertGreaterEqual(calls, 8)

    def test_no_summary_job_is_skipped_or_fed_by_a_needs_result(self):
        """A summary whose job-level `if:` reads a needs result is skipped, which reads as a pass, on exactly the
        results it should judge; one whose `with:` passes needs results judges them where this file cannot see."""
        seen = set()
        for workflow, job_id, job in summary_jobs():
            if (workflow, job_id) in NOT_MERGE_GATES:
                continue
            with self.subTest(workflow=workflow, job=job_id):
                self.assertFalse(NEEDS_RESULT.search(json.dumps(job.get("with") or {})),
                                 "a summary's `with:` reads needs results: judge them in this job with the rule")
                if NEEDS_RESULT.search(str(job.get("if") or "")):
                    seen.add((workflow, job_id))
                    self.assertIn((workflow, job_id), JOB_IF_READS,
                                  "a summary's job-level `if:` reads a needs result, so it is skipped (read as "
                                  "passed) on a result it should judge: use always() and judge it with the rule")
        self.assertEqual(seen, set(JOB_IF_READS), "a JOB_IF_READS entry that no longer reads a needs result")


def rule_jobs():
    """(workflow, job id, step name) of every step that calls the rule."""
    for workflow, job, st in summary_steps():
        body = st.get("run") or ""
        if nv.SHELL_RULE.splitlines()[0] in body or nv.PYTHON_RULE.splitlines()[0] in body:
            yield workflow, job, st["name"]


WEB_SCOPE = {"result": "success", "outputs": {name: "true" for name in (
    "db", "diff_sidecar", "instant", "production_build", "react_apps", "typecheck", "unit_tests")}}
# For every rule job: the step's env with one needed job abandoned and another failed. The failure wins: exit 1.
MIXED = {
    ("rust-workspaces.yml", "summary", "Every planned workspace passed"): {"PLAN": "abandoned", "WORKSPACES": "failure"},
    ("ios-e2e.yml", "ios-e2e-status", "Aggregate"): {
        "IS_FORK": "false", "RUN_E2E": "", "RUN_CLIENTS": "", "BACKEND_TAG": "", "ROUTE_RESULT": "abandoned",
        "BACKEND_RESULT": "failure", "MAC_IOS_RESULT": "skipped"},
    ("test-ios.yml", "ios-tests", "Check iOS test routing"): {"IOS_NEEDS": json.dumps({
        "detect-ios-changes": {"result": "abandoned"}, "runner": {"result": "failure"},
        "package-conventions-lint": {"result": "skipped"}, "mobile-core-package": {"result": "skipped"},
        "ios-simulator-build": {"result": "skipped"}})},
    ("ci-guards.yml", "guard-status", "Check routed guard jobs"): {
        "GUARD_INPUTS": json.dumps({"submodule_forward_only": "true", "linux_guard_tests": "true",
                                    "linux_guard_test_groups": '["release-notary"]', "linux_guard_history": "false",
                                    "linux_guard_cli": "false", "linux_guard_source": "false"}),
        "GUARD_NEEDS": json.dumps({"workflow-guard-submodule-forward-only": {"result": "abandoned"},
                                   "workflow-guard-tests": {"result": "failure"},
                                   **{job: {"result": "skipped"} for job in (
                                       "workflow-guard-history", "workflow-guard-cli-scripts",
                                       "workflow-guard-source-lints")}})},
    ("ci-web.yml", "react-apps-check", "Check webview test shards"): {
        "WEB_INPUTS": json.dumps({"web": "true"}),
        "WEB_NEEDS": json.dumps({"web-subarea-scope": WEB_SCOPE, "react-apps-check-shard": {"result": "abandoned"},
                                 "react-doctor": {"result": "failure"}, "react-apps-base-check": {"result": "skipped"}})},
    ("ci-web.yml", "web-status", "Check routed web jobs"): {
        "WEB_INPUTS": json.dumps({"web": "true", "macos": "false", "agent_session_web": "false"}),
        "WEB_NEEDS": json.dumps({"web-subarea-scope": {"result": "abandoned"}, "web-tests": {"result": "failure"},
                                 **{job: {"result": "skipped"} for job in (
                                     "web-typecheck", "web-production-build", "web-instant-navigation",
                                     "react-apps-check", "diff-sidecar-check", "web-db-migrations")}})},
}
# Rule jobs that judge one result, so no two can disagree.
SINGLE_RESULT = {
    ("backend-migrations.yml", "gate", "Plan succeeded"): "the plan job alone",
    ("cmux-tui.yml", "valgrind-leak-check", "Require every Valgrind shard"): "the shard matrix's one result",
}


class Summaries(unittest.TestCase):
    def test_every_rule_job_lets_a_failure_win_over_no_verdict(self):
        self.assertEqual(set(rule_jobs()), set(MIXED) | set(SINGLE_RESULT),
                         "give a new rule job a MIXED row (one result abandoned, one failed) or a SINGLE_RESULT reason")
        for (workflow, job, name), env in MIXED.items():
            with self.subTest(workflow=workflow, job=job):
                done = run_bash(step(workflow, job, name)["run"], env)
                self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
                self.assertIn("::error::summary red: ", done.stdout)
                self.assertNotIn("no verdict", done.stdout)

    def test_the_marker_steps_read_their_job_output_by_the_rule(self):
        """MARKER_STEPS read a verdict output beside the result. A failed result is a red whatever the output says, one
        that judged nothing is no verdict (exit 3); the crash gate leaves a failed compile to the compile's own red."""
        cases = {
            ("cmux-next.yml", "fast-tier", "Report the build fleet's fast tier verdict"): [
                ({"VERDICT": "pass", "RESULT": "success"}, 0), ({"VERDICT": "fail", "RESULT": "failure"}, 1),
                ({"VERDICT": "pass", "RESULT": "failure"}, 1), ({"VERDICT": "", "RESULT": "failure"}, 1),
                ({"VERDICT": "fail", "RESULT": "cancelled"}, 1), ({"VERDICT": "", "RESULT": "cancelled"}, 3),
                ({"VERDICT": "pass", "RESULT": "abandoned"}, 3), ({"VERDICT": "", "RESULT": ""}, 3),
                ({"VERDICT": "unavailable", "RESULT": "success"}, 3)],
            ("cmux-next.yml", "crash-ends-app", "Read the crash gate result"): [
                ({"OUTCOME": "success", "COMPILE": "success"}, 0), ({"OUTCOME": "failure", "COMPILE": "success"}, 1),
                ({"OUTCOME": "", "COMPILE": "success"}, 1), ({"OUTCOME": "", "COMPILE": "failure"}, 0),
                ({"OUTCOME": "", "COMPILE": "cancelled"}, 3), ({"OUTCOME": "", "COMPILE": "abandoned"}, 3),
                ({"OUTCOME": "", "COMPILE": ""}, 3)],
        }
        self.assertEqual({key[:2] for key in cases}, set(MARKER_STEPS), "give a new MARKER_STEPS job its table here")
        for (workflow, job, name), rows in cases.items():
            body = step(workflow, job, name)["run"]
            for env, code in rows:
                with self.subTest(workflow=workflow, job=job, env=env):
                    done = run_bash(body, env)
                    self.assertEqual(done.returncode, code, done.stdout + done.stderr)
                    self.assertEqual("::error::no verdict: " in done.stdout, code == 3, done.stdout)

    def test_rust_workspaces(self):
        body = step("rust-workspaces.yml", "summary", "Every planned workspace passed")["run"]
        for plan, workspaces, code in (("success", "success", 0), ("success", "skipped", 0),
                                       ("success", "failure", 1), ("failure", "skipped", 1),
                                       ("abandoned", "skipped", 3), ("success", "cancelled", 3), ("", "", 3)):
            with self.subTest(plan=plan, workspaces=workspaces):
                done = run_bash(body, {"PLAN": plan, "WORKSPACES": workspaces})
                self.assertEqual(done.returncode, code, done.stdout + done.stderr)
                self.assertEqual("::error::no verdict: rust workspaces:" in done.stdout, code == 3)

    def test_valgrind_and_the_migration_plan(self):
        cases = (("success", 0), ("failure", 1), ("abandoned", 3), ("cancelled", 3), ("skipped", 3))
        for workflow, job, name, var in (("cmux-tui.yml", "valgrind-leak-check", "Require every Valgrind shard",
                                          "SHARD_RESULT"),
                                         ("backend-migrations.yml", "gate", "Plan succeeded", "RESULT")):
            body = step(workflow, job, name)["run"]
            for result, code in cases:
                with self.subTest(workflow=workflow, result=result):
                    self.assertEqual(run_bash(body, {var: result}).returncode, code)

    def test_ios_e2e(self):
        body = step("ios-e2e.yml", "ios-e2e-status", "Aggregate")["run"]
        base = {"IS_FORK": "false", "RUN_E2E": "true", "RUN_CLIENTS": "true", "BACKEND_TAG": "t",
                "ROUTE_RESULT": "success", "BACKEND_RESULT": "success", "MAC_IOS_RESULT": "success"}
        for change, code in (({}, 0), ({"ROUTE_RESULT": "abandoned"}, 3), ({"ROUTE_RESULT": "failure"}, 1),
                             ({"RUN_E2E": "false", "BACKEND_RESULT": "skipped"}, 0),
                             ({"BACKEND_RESULT": "failure", "MAC_IOS_RESULT": "cancelled"}, 1),
                             ({"MAC_IOS_RESULT": "abandoned"}, 3), ({"RUN_CLIENTS": "false", "MAC_IOS_RESULT": "skipped"}, 0)):
            with self.subTest(change=change):
                self.assertEqual(run_bash(body, {**base, **change}).returncode, code)

    def test_ios_tests(self):
        body = step("test-ios.yml", "ios-tests", "Check iOS test routing")["run"]
        good = {"detect-ios-changes": {"result": "success"}, "ios-unit": {"result": "success"},
                "ios-lint": {"result": "skipped"}}
        for change, code in (({}, 0), ({"ios-unit": {"result": "failure"}}, 1),
                             ({"ios-unit": {"result": "abandoned"}}, 3), ({"ios-unit": {"result": "cancelled"}}, 3),
                             ({"detect-ios-changes": {"result": "abandoned"}}, 3),
                             ({"detect-ios-changes": {"result": "failure"}}, 1)):
            with self.subTest(change=change):
                done = run_bash(body, {"IOS_NEEDS": json.dumps({**good, **change})})
                self.assertEqual(done.returncode, code, done.stdout + done.stderr)

    def test_web_validation(self):
        good = {"changes": {"result": "success", "outputs": {"required": "true"}},
                **{job: {"result": "success"} for job in ("build", "tests", "database")}}

        def check(needs):
            return subprocess.run([sys.executable, str(ROOT / "scripts/ci/web_validation.py"), "check"],
                                  env={**os.environ, "WEB_VALIDATION_NEEDS": json.dumps(needs),
                                       "GITHUB_EVENT_NAME": "push"},
                                  capture_output=True, text=True, stdin=subprocess.DEVNULL)

        for change, code in (({}, 0), ({"build": {"result": "failure"}}, 1), ({"build": {"result": "abandoned"}}, 3),
                             ({"changes": {"result": "abandoned"}}, 3), ({"changes": {"result": "failure"}}, 1),
                             ({"changes": {"result": "success", "outputs": {"required": "x"}}}, 1),
                             ({"database": None}, 1)):  # a required job missing from needs is a config red
            with self.subTest(change=change):
                done = check({k: v for k, v in {**good, **change}.items() if v is not None})
                self.assertEqual(done.returncode, code, done.stdout + done.stderr)
                self.assertEqual("::error::no verdict: web-validation:" in done.stdout, code == 3)


# The summary steps that read a push's Mac job from a per-branch concurrency group, whose waiting job a newer push
# replaces (needs_verdict.SUPERSEDED_RULE), each with the env that makes it judge nothing on a cancelled result and the
# exit code of its no verdict.
SUPERSEDED_STEPS = {
    ("cmux-next.yml", "crash-ends-app", "Read the crash gate result"): ({"OUTCOME": "", "COMPILE": "cancelled"}, 3),
    ("cmux-next.yml", "fast-tier", "Report the build fleet's fast tier verdict"): ({"VERDICT": "", "RESULT": "cancelled"}, 3),
    ("cmux-next.yml", "generated-verdict", "Read the generated files verdict of the shared build"): (
        {"HOST": "swift-test", "HOST_RESULT": "cancelled", "VERDICT": ""}, 1),
}
OLD, NEW = "a" * 40, "b" * 40
# The rule's definition or a call of it, not other tools that share the word (cmux_tui_superseded_push.py).
SUPERSEDED_CALL = re.compile(r"(?<![\w./-])superseded_push(?:\(\)| )")


def fake_git(tmp: str, head: str | None) -> str:
    """A PATH whose `git ls-remote` answers HEAD for the ref (or fails, for None), and logs its arguments."""
    bin_dir = Path(tmp) / "bin"
    bin_dir.mkdir()
    answer = f'printf "%s\\t%s\\n" {head} "${{@: -1}}"' if head else "exit 128"
    (bin_dir / "git").write_text(f'#!/bin/bash\necho "$@" >> {tmp}/git.log\n{answer}\n')
    (bin_dir / "git").chmod(0o755)
    return f"{bin_dir}:{os.environ['PATH']}"


class Superseded(unittest.TestCase):
    def test_every_copy_is_verbatim_and_listed(self):
        first = nv.SUPERSEDED_RULE.splitlines()[0]
        carrying = set()
        for path in sorted(WORKFLOWS.glob("*.yml")):
            for job_id, job in (yaml.safe_load(path.read_text(encoding="utf-8")).get("jobs") or {}).items():
                for st in job.get("steps") or []:
                    body = st.get("run") or ""
                    if SUPERSEDED_CALL.search(body):
                        carrying.add((path.name, job_id, st.get("name")))
                        with self.subTest(job=job_id):
                            self.assertIn(first, body, "call superseded_push only beside its verbatim copy")
                            self.assertIn(nv.SUPERSEDED_RULE, body, "the copy drifted from needs_verdict.SUPERSEDED_RULE")
        self.assertEqual(carrying, set(SUPERSEDED_STEPS))

    def test_a_cancel_by_a_newer_push_is_no_red_and_anything_else_stays_no_verdict(self):
        push = {"GITHUB_EVENT_NAME": "push", "GITHUB_SHA": OLD, "GITHUB_REF": "refs/heads/feat-cmux-next",
                "GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_SERVER_URL": "https://github.com"}
        for (workflow, job, name), (env, no_verdict) in SUPERSEDED_STEPS.items():
            body = step(workflow, job, name)["run"]
            for event, head, code in (("push", NEW, 0), ("push", OLD, no_verdict), ("push", None, no_verdict),
                                      ("pull_request", NEW, no_verdict), ("workflow_dispatch", NEW, no_verdict)):
                with self.subTest(job=job, event=event, head=head), tempfile.TemporaryDirectory() as tmp:
                    done = run_bash(body, {**env, **push, "GITHUB_EVENT_NAME": event, "PATH": fake_git(tmp, head)})
                    self.assertEqual(done.returncode, code, done.stdout + done.stderr)
                    self.assertEqual("superseded::" in done.stdout, code == 0, done.stdout)
                    if code == 0:
                        self.assertIn(NEW, done.stdout)
                        self.assertIn("ls-remote https://github.com/manaflow-ai/cmux.git refs/heads/feat-cmux-next",
                                      (Path(tmp) / "git.log").read_text())

    def test_only_a_cancelled_result_asks(self):
        """A failure, or a result that is not a cancel, never reads the branch head: a red stays a red."""
        push = {"GITHUB_EVENT_NAME": "push", "GITHUB_SHA": OLD, "GITHUB_REF": "refs/heads/feat-cmux-next",
                "GITHUB_REPOSITORY": "manaflow-ai/cmux"}
        rows = {"crash-ends-app": [({"OUTCOME": "", "COMPILE": "abandoned"}, 3), ({"OUTCOME": "failure", "COMPILE": "cancelled"}, 1)],
                "fast-tier": [({"VERDICT": "", "RESULT": "abandoned"}, 3), ({"VERDICT": "fail", "RESULT": "cancelled"}, 1)],
                "generated-verdict": [({"HOST": "swift-test", "HOST_RESULT": "failure", "VERDICT": ""}, 1),
                                      ({"HOST": "swift-test", "HOST_RESULT": "cancelled", "VERDICT": "stale"}, 1)]}
        for (workflow, job, name) in SUPERSEDED_STEPS:
            body = step(workflow, job, name)["run"]
            for env, code in rows[job]:
                with self.subTest(job=job, env=env), tempfile.TemporaryDirectory() as tmp:
                    done = run_bash(body, {**env, **push, "PATH": fake_git(tmp, NEW)})
                    self.assertEqual(done.returncode, code, done.stdout + done.stderr)
                    self.assertFalse((Path(tmp) / "git.log").exists(), "read the branch head for a result that is not a cancel")


if __name__ == "__main__":
    unittest.main()
