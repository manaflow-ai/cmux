#!/usr/bin/env python3
"""A fix-cause:* label on a closed pull request starts no job.

The fix-cause backfill (cmuxterm-hq#7579) labels thousands of merged pull
requests, up to 250 an hour. Each label event starts every workflow whose
`pull_request_target` types include `labeled` or `unlabeled`, and those run this
repository's default-branch copy of the file. Before this guard, risk tier,
merge freeze and backend-migrations each ran a job per label, about 2 runner
minutes a label, beside nightly and pull request CI. Nothing in them reads a
fix-cause label.

So every job of such a workflow must skip for that event. The check evaluates
each job's `if:` the way Actions does, with its `needs` (a job whose needs all
skipped runs only if its condition says always() or !cancelled()). A new
labeled workflow that runs a job for the event fails here. risk tier is the one
exemption (EXEMPT): its evidence job takes no job-level if, so a skipped run never
reads as a passed required check (#38003).

An open pull request is not exempt from anything: risk tier and the
backend-migrations gate are required checks read newest-by-name, and a skipped
newest run would read as a pass. They still grade an open pull request on every
label.

`pull_request` workflows are out of scope: a label event there runs the copy of
the file in the pull request's own merge commit, so no branch's copy decides
what a label on an already merged pull request starts.

Run: python3 tests/test_ci_fix_cause_labels_start_no_jobs.py
"""

from __future__ import annotations

import json
import re
import sys
import tempfile
import unittest
from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
LABEL_ACTIONS = {"labeled", "unlabeled"}
STATUS_FUNCTIONS = ("always", "success", "failure", "cancelled")


# A small evaluator for the subset of the GitHub expression language job conditions use.

TOKEN = re.compile(
    r"\s*(?:(?P<num>-?\d+(?:\.\d+)?)|(?P<str>'(?:[^']|'')*')|(?P<op>==|!=|<=|>=|&&|\|\||[!<>()\[\],.*])"
    r"|(?P<name>[A-Za-z_][A-Za-z0-9_-]*))"
)


def tokenize(expr: str) -> list[tuple[str, str]]:
    tokens, pos, expr = [], 0, expr.strip()
    while pos < len(expr):
        match = TOKEN.match(expr, pos)
        if not match or match.end() == pos:
            raise ValueError(f"cannot read expression at {expr[pos:pos + 30]!r}")
        kind = match.lastgroup
        tokens.append((kind, match.group(kind)))
        pos = match.end()
    return tokens


def truthy(value: Any) -> bool:
    return value not in (None, False, 0, "") and value == value


def loose(value: Any) -> Any:
    return value.lower() if isinstance(value, str) else value


class Evaluator:
    def __init__(self, context: dict[str, Any], needs: dict[str, str], outputs: dict[str, dict] | None = None):
        self.context, self.needs, self.outputs = context, needs, outputs or {}

    def run(self, expr: str) -> Any:
        self.tokens, self.pos = tokenize(expr), 0
        value = self.or_()
        if self.pos != len(self.tokens):
            raise ValueError(f"trailing tokens in {expr!r}")
        return value

    def peek(self) -> str | None:
        return self.tokens[self.pos][1] if self.pos < len(self.tokens) else None

    def take(self, want: str | None = None) -> tuple[str, str]:
        token = self.tokens[self.pos]
        if want is not None and token[1] != want:
            raise ValueError(f"expected {want!r}, got {token[1]!r}")
        self.pos += 1
        return token

    def or_(self) -> Any:
        value = self.and_()
        while self.peek() == "||":
            self.take()
            right = self.and_()
            value = value if truthy(value) else right
        return value

    def and_(self) -> Any:
        value = self.compare()
        while self.peek() == "&&":
            self.take()
            right = self.compare()
            value = right if truthy(value) else value
        return value

    def compare(self) -> Any:
        value = self.unary()
        while self.peek() in ("==", "!=", "<", ">", "<=", ">="):
            op = self.take()[1]
            right = self.unary()
            a, b = loose(value), loose(right)
            value = {"==": lambda: a == b, "!=": lambda: a != b, "<": lambda: a < b,
                     ">": lambda: a > b, "<=": lambda: a <= b, ">=": lambda: a >= b}[op]()
        return value

    def unary(self) -> Any:
        if self.peek() == "!":
            self.take()
            return not truthy(self.unary())
        return self.postfix(self.primary())

    def primary(self) -> Any:
        kind, text = self.take()
        if text == "(":
            value = self.or_()
            self.take(")")
            return value
        if kind == "num":
            return float(text)
        if kind == "str":
            return text[1:-1].replace("''", "'")
        if kind != "name":
            raise ValueError(f"unexpected {text!r}")
        if text in ("true", "false"):
            return text == "true"
        if text == "null":
            return None
        if self.peek() == "(":
            self.take()
            args = []
            while self.peek() != ")":
                args.append(self.or_())
                if self.peek() == ",":
                    self.take()
            self.take(")")
            return self.call(text, args)
        if text == "needs":
            return {name: {"result": result, "outputs": self.outputs.get(name, {})} for name, result in self.needs.items()}
        return self.context.get(text)

    def postfix(self, value: Any) -> Any:
        while self.peek() in (".", "["):
            if self.take()[1] == ".":
                kind, name = self.take()
                if name == "*":
                    value = list(value.values()) if isinstance(value, dict) else value
                    continue
                if isinstance(value, list):
                    value = [item.get(name) if isinstance(item, dict) else None for item in value]
                else:
                    value = value.get(name) if isinstance(value, dict) else None
            else:
                key = self.or_()
                self.take("]")
                value = value.get(key) if isinstance(value, dict) else None
        return value

    def call(self, name: str, args: list[Any]) -> Any:
        results = list(self.needs.values())
        if name == "always":
            return True
        if name == "cancelled":
            return False
        if name == "success":
            return all(result == "success" for result in results)
        if name == "failure":
            return any(result == "failure" for result in results)
        if name in ("startsWith", "endsWith"):
            text, part = (str(arg).lower() if arg is not None else "" for arg in args)
            return text.startswith(part) if name == "startsWith" else text.endswith(part)
        if name == "contains":
            haystack, needle = args
            if isinstance(haystack, list):
                return any(loose(item) == loose(needle) for item in haystack)
            return str(loose(needle) or "") in str(loose(haystack) or "")
        if name == "fromJSON":
            return json.loads(args[0])
        if name == "toJSON":
            return json.dumps(args[0])
        if name == "format":
            return re.sub(r"\{(\d+)\}", lambda m: str(args[1 + int(m.group(1))]), args[0])
        raise ValueError(f"unknown function {name}")


def unwrap(condition: Any) -> str:
    text = str(condition).strip()
    match = re.fullmatch(r"\$\{\{(.*)\}\}", text, re.S)
    return match.group(1).strip() if match else text


def job_runs(condition: Any, context: dict[str, Any], needs: dict[str, str], outputs: dict[str, dict] | None = None) -> bool:
    expr = unwrap(condition) if condition is not None else "success()"
    if not re.search(r"\b(?:%s)\s*\(" % "|".join(STATUS_FUNCTIONS), expr):
        expr = f"success() && ({expr})"
    return truthy(Evaluator(context, needs, outputs).run(expr))


def needs_of(job: dict) -> list[str]:
    needs = job.get("needs") or []
    return [needs] if isinstance(needs, str) else list(needs)


def jobs_started(document: dict, context: dict[str, Any], outputs: dict[str, dict] | None = None) -> list[str]:
    """The jobs that would get a runner for this event, in workflow order (OUTPUTS: each job's outputs)."""
    jobs = document.get("jobs") or {}
    result: dict[str, str] = {}
    pending = list(jobs)
    while pending:
        progressed = False
        for name in list(pending):
            needs = needs_of(jobs[name])
            if any(need not in result for need in needs):
                continue
            runs = job_runs(jobs[name].get("if"), context, {need: result[need] for need in needs}, outputs)
            result[name] = "success" if runs else "skipped"
            pending.remove(name)
            progressed = True
        if not progressed:
            raise ValueError(f"needs cycle among {pending}")
    return [name for name, state in result.items() if state == "success"]


def triggers(document: dict) -> dict:
    on = document.get(True, document.get("on"))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {event: None for event in on}
    return on or {}


@lru_cache(maxsize=None)
def label_target_workflows(directory: Path = WORKFLOWS) -> dict[str, dict]:
    """Workflows whose pull_request_target types include a label action."""
    found = {}
    for path in sorted(directory.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        config = triggers(document).get("pull_request_target")
        types = (config or {}).get("types") if isinstance(config, dict) else None
        if types and LABEL_ACTIONS & set(types):
            found[path.name] = document
    return found


def event(action: str, label: str, state: str = "closed", base: str = "feat-cmux-next") -> dict[str, Any]:
    pull_request = {
        "number": 37565, "state": state, "merged": state == "closed", "draft": False,
        "base": {"ref": base}, "head": {"repo": {"full_name": "manaflow-ai/cmux"}},
        "labels": [{"name": label}],
    }
    return {
        "github": {
            "event_name": "pull_request_target", "repository": "manaflow-ai/cmux",
            "repository_owner": "manaflow-ai", "ref": "refs/heads/main",
            "event": {"action": action, "label": {"name": label}, "pull_request": pull_request},
        },
        "vars": {}, "inputs": {}, "secrets": {}, "matrix": {}, "steps": {},
    }


FIX_CAUSE_EVENTS = [
    event(action, label, base=base)
    for action in sorted(LABEL_ACTIONS)
    for label in ("fix-cause:ci-config", "fix-cause:race", "Fix-Cause:upper")
    for base in ("main", "feat-cmux-next")
]


# Workflows that keep running for the event on purpose. risk-tier's evidence job never takes a job-level if:
# a skipped job reads as a passed required risk evidence check
# (tests/test_risk_tier_history_admission.py, #38003), so it pays its one job per label.
EXEMPT = {"risk-tier.yml": "a skipped risk evidence job reads as a pass (#38003)"}


def offenders(workflows: dict[str, dict]) -> list[str]:
    problems = []
    for name, document in workflows.items():
        if name in EXEMPT:
            continue
        for context in FIX_CAUSE_EVENTS:
            started = jobs_started(document, context)
            if started:
                ev = context["github"]["event"]
                problems.append(f"{name}: {ev['action']} {ev['label']['name']!r} into "
                                f"{ev['pull_request']['base']['ref']} starts {', '.join(started)}")
                break
    return problems


MIGRATION_CHANGE = {"plan": {"migrations": "true"}}


class FixCauseLabelsStartNoJobs(unittest.TestCase):
    def test_risk_tier_still_runs_for_the_event(self):
        # The exemption is real: risk tier is never skipped, not even for a fix-cause label on a closed PR.
        context = event("labeled", "fix-cause:ci-config")
        self.assertEqual(jobs_started(label_target_workflows()["risk-tier.yml"], context), ["evidence"])

    def test_the_repository_has_label_target_workflows(self):
        # Guards the scan itself: an empty set would pass everything.
        self.assertIn("risk-tier.yml", label_target_workflows())
        self.assertIn("merge-freeze.yml", label_target_workflows())

    def test_every_label_target_workflow_skips_fix_cause_labels_on_closed_pull_requests(self):
        problems = offenders(label_target_workflows())
        self.assertEqual(problems, [], "add the fix-cause guard to these jobs' if:\n" + "\n".join(problems))

    def test_open_pull_requests_still_grade_on_a_fix_cause_label(self):
        workflows = label_target_workflows()
        context = event("labeled", "fix-cause:ci-config", state="open")
        self.assertEqual(jobs_started(workflows["risk-tier.yml"], context), ["evidence"])
        # Into main every label plans and gates, with or without a migration change: a skipped gate would
        # publish its unevaluated name, not `backend migrations applied` (RequiredCheckNamesReport below).
        into_main = event("labeled", "fix-cause:ci-config", state="open", base="main")
        self.assertIn("gate", jobs_started(workflows["backend-migrations.yml"], into_main, MIGRATION_CHANGE))
        self.assertEqual(jobs_started(workflows["backend-migrations.yml"], into_main), ["plan", "gate"])

    def test_other_labels_on_closed_pull_requests_are_unchanged(self):
        workflows = label_target_workflows()
        context = event("labeled", "risk:normal")
        self.assertEqual(jobs_started(workflows["risk-tier.yml"], context), ["evidence"])
        self.assertEqual(jobs_started(workflows["merge-freeze.yml"], context), ["check"])
        into_main = event("labeled", "risk:normal", base="main")
        self.assertEqual(jobs_started(workflows["backend-migrations.yml"], into_main, MIGRATION_CHANGE), ["plan", "gate"])

    def test_backend_migrations_skips_ignored_labels_into_feat_cmux_next(self):
        # GitHub runs main's copy for PRs into feat-cmux-next. A review bot's label there queued a second
        # plan behind the push's on the gate pool (cmux#47511 ace3ada7, about 10 more minutes).
        migrations = label_target_workflows()["backend-migrations.yml"]
        for label in ("risk:normal", "area:ios", "fix-cause:ci-config"):
            for state in ("open", "closed"):
                context = event("labeled", label, state=state)
                self.assertEqual(jobs_started(migrations, context, MIGRATION_CHANGE), [], (label, state))
        for label in ("backend:apply-migrations", "full-ci"):
            context = event("labeled", label, state="open")
            self.assertEqual(jobs_started(migrations, context, MIGRATION_CHANGE)[:1], ["plan"], label)

    def test_an_unguarded_labeled_workflow_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "new.yml").write_text(
                "on:\n  pull_request_target:\n    types: [opened, labeled]\njobs:\n"
                "  a:\n    runs-on: ubuntu-24.04\n    steps: [{run: x}]\n"
                "  b:\n    needs: a\n    if: always()\n    runs-on: ubuntu-24.04\n    steps: [{run: x}]\n",
                encoding="utf-8")
            problems = offenders(label_target_workflows(Path(directory)))
        self.assertEqual(len(problems), 1)
        self.assertIn("starts a, b", problems[0])

    def test_an_always_job_after_a_guarded_one_still_needs_the_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            guard = ("${{ !(github.event.pull_request.state == 'closed' && (github.event.action == 'labeled' || "
                     "github.event.action == 'unlabeled') && startsWith(github.event.label.name, 'fix-cause:')) }}")
            Path(directory, "new.yml").write_text(
                "on:\n  pull_request_target:\n    types: [labeled]\njobs:\n"
                f"  a:\n    if: \"{guard}\"\n    runs-on: ubuntu-24.04\n    steps: [{{run: x}}]\n"
                "  b:\n    needs: a\n    runs-on: ubuntu-24.04\n    steps: [{run: x}]\n"
                "  c:\n    needs: a\n    if: ${{ !cancelled() }}\n    runs-on: ubuntu-24.04\n    steps: [{run: x}]\n",
                encoding="utf-8")
            problems = offenders(label_target_workflows(Path(directory)))
        self.assertEqual(len(problems), 1)
        self.assertIn("starts c", problems[0])


# GitHub evaluates a job's `name:` only for a job that starts. A job skipped by its `if:` publishes its check
# run under the raw text of the name, so a required check whose name is an expression answers only from a
# job that runs. cmux#51717 gave the backend-migrations gate an expression name while #48999's skip for "no
# migration change" stood: every pull request into main without a migration then published
# "github.event_name == 'pull_request_target' && ..." (skipped), and `backend migrations applied` never
# reported (cmux#52720, run 45473955261).
REQUIRED_CHECKS = ("CLA Assistant", "CLA policy guard", "backend migrations applied")
PULL_REQUEST_BASES = ("main", "feat-cmux-next")


def pull_request_event(action: str, base: str, label: str = "risk:normal", base_changed: bool = False) -> dict:
    context = event(action, label, state="open", base=base)
    if action == "edited":
        context["github"]["event"]["changes"] = {"base": {"ref": {"from": "x"}}} if base_changed else {"body": {"from": "x"}}
    return context


def required_name_offenders(workflows: dict[str, dict], outputs: dict[str, dict] | None = None) -> list[str]:
    """Jobs whose name evaluates to a required check for some pull request event but that skip for it."""
    problems = []
    for file, document in workflows.items():
        config = triggers(document).get("pull_request_target")
        types = (config or {}).get("types") if isinstance(config, dict) else None
        types = types or ["opened", "synchronize", "reopened"]
        for job_id, job in (document.get("jobs") or {}).items():
            name = str(job.get("name") or "")
            if "${{" not in name or not any(f"'{check}'" in name for check in REQUIRED_CHECKS):
                continue
            for action in types:
                for base in PULL_REQUEST_BASES:
                    for label in ("risk:normal", "backend:apply-migrations", "fix-cause:ci-config"):
                        for base_changed in ((False, True) if action == "edited" else (False,)):
                            context = pull_request_event(action, base, label, base_changed)
                            published = Evaluator(context, {}, outputs).run(unwrap(name))
                            if published in REQUIRED_CHECKS and job_id not in jobs_started(document, context, outputs):
                                problems.append(f"{file}: {job_id} skips for {action} ({label}) into {base}, "
                                                f"so {published!r} never reports")
    return problems


def pull_request_target_workflows(directory: Path = WORKFLOWS) -> dict[str, dict]:
    found = {}
    for path in sorted(directory.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        if "pull_request_target" in triggers(document):
            found[path.name] = document
    return found


class RequiredCheckNamesReport(unittest.TestCase):
    def test_the_migrations_gate_runs_without_a_migration_change(self):
        # The plan found nothing: the gate still starts (no environment, no secrets, one echo step) so that
        # its name is evaluated and `backend migrations applied` reports.
        migrations = pull_request_target_workflows()["backend-migrations.yml"]
        for action in ("opened", "synchronize", "reopened", "labeled", "edited"):
            for base in PULL_REQUEST_BASES:
                # full-ci: a label that counts into feat-cmux-next too (ignored labels are the test below).
                context = pull_request_event(action, base, label="full-ci", base_changed=True)
                self.assertEqual(jobs_started(migrations, context), ["plan", "gate"], (action, base))

    def test_every_required_expression_name_reports_from_a_running_job(self):
        workflows = pull_request_target_workflows()
        self.assertIn("backend-migrations.yml", workflows)
        for outputs in (None, MIGRATION_CHANGE):
            problems = required_name_offenders(workflows, outputs)
            self.assertEqual(problems, [], "a skipped job publishes its raw name:\n" + "\n".join(problems))

    def test_ignored_events_into_feat_cmux_next_still_take_no_runner(self):
        # #51717's intent stands: an ignored label or a title/body edit into feat-cmux-next skips, and its
        # skipped gate publishes the raw expression, which never answers for the required check.
        migrations = pull_request_target_workflows()["backend-migrations.yml"]
        self.assertEqual(jobs_started(migrations, pull_request_event("labeled", "feat-cmux-next")), [])
        self.assertEqual(jobs_started(migrations, pull_request_event("edited", "feat-cmux-next")), [])

    def test_a_skipping_expression_named_required_job_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "new.yml").write_text(
                "on:\n  pull_request_target:\n    types: [opened]\njobs:\n"
                "  plan:\n    runs-on: ubuntu-24.04\n    steps: [{run: x}]\n"
                "  gate:\n    name: \"${{ github.event.action == 'edited' && 'x (ignored)' || 'backend migrations applied' }}\"\n"
                "    needs: plan\n    if: needs.plan.outputs.migrations == 'true'\n"
                "    runs-on: ubuntu-24.04\n    steps: [{run: x}]\n",
                encoding="utf-8")
            problems = required_name_offenders(pull_request_target_workflows(Path(directory)))
        self.assertTrue(problems)
        self.assertIn("gate skips for opened", problems[0])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
