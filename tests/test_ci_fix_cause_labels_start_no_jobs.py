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
labeled workflow that runs a job for the event fails here.

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
    def __init__(self, context: dict[str, Any], needs: dict[str, str]):
        self.context, self.needs = context, needs

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
            return {name: {"result": result, "outputs": {}} for name, result in self.needs.items()}
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


def job_runs(condition: Any, context: dict[str, Any], needs: dict[str, str]) -> bool:
    expr = unwrap(condition) if condition is not None else "success()"
    if not re.search(r"\b(?:%s)\s*\(" % "|".join(STATUS_FUNCTIONS), expr):
        expr = f"success() && ({expr})"
    return truthy(Evaluator(context, needs).run(expr))


def needs_of(job: dict) -> list[str]:
    needs = job.get("needs") or []
    return [needs] if isinstance(needs, str) else list(needs)


def jobs_started(document: dict, context: dict[str, Any]) -> list[str]:
    """The jobs that would get a runner for this event, in workflow order."""
    jobs = document.get("jobs") or {}
    result: dict[str, str] = {}
    pending = list(jobs)
    while pending:
        progressed = False
        for name in list(pending):
            needs = needs_of(jobs[name])
            if any(need not in result for need in needs):
                continue
            runs = job_runs(jobs[name].get("if"), context, {need: result[need] for need in needs})
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


def offenders(workflows: dict[str, dict]) -> list[str]:
    problems = []
    for name, document in workflows.items():
        for context in FIX_CAUSE_EVENTS:
            started = jobs_started(document, context)
            if started:
                ev = context["github"]["event"]
                problems.append(f"{name}: {ev['action']} {ev['label']['name']!r} into "
                                f"{ev['pull_request']['base']['ref']} starts {', '.join(started)}")
                break
    return problems


class FixCauseLabelsStartNoJobs(unittest.TestCase):
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
        self.assertIn("gate", jobs_started(workflows["backend-migrations.yml"], context))

    def test_other_labels_on_closed_pull_requests_are_unchanged(self):
        workflows = label_target_workflows()
        context = event("labeled", "risk:normal")
        self.assertEqual(jobs_started(workflows["risk-tier.yml"], context), ["evidence"])
        self.assertEqual(jobs_started(workflows["merge-freeze.yml"], context), ["check"])
        self.assertEqual(jobs_started(workflows["backend-migrations.yml"], context), ["plan", "gate"])
        approved = event("labeled", "test-integrity-approved", state="open")
        self.assertEqual(jobs_started(workflows["test-integrity.yml"], approved), ["deleted-or-weakened-tests"])

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


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
