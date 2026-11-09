"""scripts/ci/needs_verdict.py, the one rule for a summary gate's `needs.<job>.result`, and every copy of it.

Class: a summary or status poster turning "nothing judged" into a red, or into a pass. On 2026-11-09 the
cmux-next/fast-gates poster (#39743) and the `rust workspaces` summary (#39791) each read an `abandoned` dependency
as the pull request's own red, because every gate wrote its own `== success` test. Detector: this file.
`test_every_summary_step_reading_needs_results_uses_the_rule` fails when a step that reads needs results neither
carries the rule nor is listed in NOT_MERGE_GATES with its reason.
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
    ({"a": "abandoned"}, (), nv.NONE),
    ({"a": "cancelled"}, (), nv.NONE),
    ({"a": "timed_out"}, (), nv.NONE),
    ({"a": "skipped"}, (), nv.NONE),
    ({"a": ""}, (), nv.NONE),
    ({"a": "something-new"}, (), nv.NONE),
    ({"a": "success", "b": "abandoned"}, (), nv.NONE),
    ({"a": "cancelled (route x=true)"}, (), nv.NONE),
)

# Steps that read needs results but are not a merge gate's summary, each with why the rule does not apply.
NOT_MERGE_GATES = {
    ("ci-macos.yml", "macos-status"): "classic main CI only (called from ci.yml); classic is frozen",
    ("ci.yml", "macos-admission-gate"): "an admission, not a verdict: only a concluded failure declines",
    ("ci.yml", "linux-preflight"): "classic main CI only; skips feat-cmux-next",
    ("ci.yml", "ci-status"): "classic main CI only; skips feat-cmux-next",
    ("cloud-vm-image-roll.yml", "report"): "a roll's record, not a merge gate",
    ("cmux-next-fast-gates.yml", "post"): "a status poster: posts pending for no verdict (#39791)",
    ("cmux-next-media.yml", "hand-off"): "media comment, not a gate",
    ("cmux-next-media.yml", "publish"): "media comment, not a gate",
    ("cmux-next-perf-budgets.yml", "report"): "a perf report, not a merge gate",
    ("cmux-next.yml", "generated-verdict"): "its own no-verdict line (base_red_excuse GENERATED_NO_VERDICT)",
    ("cmux-next.yml", "release-compile-fast-admission"): "push-only promotion step, after the merge",
    ("cmux-vm.yml", "image-roll-settle"): "an image roll's settle, not a merge gate",
    ("nightly.yml", "prepare-nightly-variant"): "nightly, not a merge gate",
    ("nightly.yml", "publish-nightly"): "nightly, not a merge gate",
    ("nightly.yml", "report-nightly-failure"): "nightly report, not a merge gate",
    ("sdk-release-cut.yml", "summarize"): "release cut, not a merge gate",
    ("stable-next.yml", "report"): "stable release report, not a merge gate",
}


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
        full = {**os.environ, "GITHUB_STEP_SUMMARY": str(Path(tmp) / "summary"), **env}
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
                pairs = " ".join(f"'{k}={'success' if k in may_skip and v == 'skipped' else v}'"
                                 for k, v in results.items())
                done = run_bash(nv.SHELL_RULE + f"needs_verdict w {pairs}", {})
                self.assertEqual(done.returncode, nv.exit_code(state), done.stdout + done.stderr)
                self.assertEqual("::error::no verdict: w:" in done.stdout, state == nv.NONE, done.stdout)

    def test_the_python_copy_answers_the_table(self):
        for results, may_skip, state in TABLE:
            bad = {k: v for k, v in results.items() if nv.classify(v, k in may_skip) != nv.PASS}
            if not bad:
                continue
            with self.subTest(results=results):
                code = "import sys\n" + nv.PYTHON_RULE + f"exit_with_verdict({bad!r}, 'w')\n"
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
        uses = (nv.SHELL_RULE.splitlines()[0], nv.PYTHON_RULE.splitlines()[0], "web_validation.py check",
                "::error::no verdict: ", "::no verdict: ")
        listed = set()
        for workflow, job, st in summary_steps():
            if (workflow, job) in NOT_MERGE_GATES:
                listed.add((workflow, job))
                continue
            with self.subTest(workflow=workflow, job=job, step=st.get("name")):
                self.assertTrue(any(u in (st.get("run") or "") for u in uses),
                                "a summary step that reads needs results must use scripts/ci/needs_verdict.py's rule "
                                "(or be listed in NOT_MERGE_GATES with why)")
        self.assertEqual(listed, set(NOT_MERGE_GATES), "a NOT_MERGE_GATES entry that no longer exists")


class Summaries(unittest.TestCase):
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
                             ({"changes": {"result": "success", "outputs": {"required": "x"}}}, 1)):
            with self.subTest(change=change):
                done = check({**good, **change})
                self.assertEqual(done.returncode, code, done.stdout + done.stderr)
                self.assertEqual("::error::no verdict: web-validation:" in done.stdout, code == 3)


if __name__ == "__main__":
    unittest.main()
