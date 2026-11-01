#!/usr/bin/env python3
"""A newer push to a pull request cancels that pull request's older run.

tests/test_ci_required_checks_are_bounded.py only asks that a pull_request
workflow *has* a concurrency group. A group keyed by the commit, or one with
`cancel-in-progress: false`, passes that check and still leaves every
superseded run holding a runner until it finishes. Nothing goes red when that
happens, so it is checked here.

For every workflow triggered by `pull_request` or `pull_request_target`, this
evaluates its `concurrency:` (the workflow's, or else every job's that can run
on that event) the way GitHub does, for two synchronize runs of one pull
request and one run of another, and requires:

- the two runs of one pull request share a group,
- the two pull requests do not, and
- cancel-in-progress is true for that event.

A pull request event whose `types:` filter leaves out `synchronize` (a
labeled-only tour) gets no run from a push, so it is not judged either.

Push, schedule and dispatch runs are not judged: workflows that also run on a
push to feat-cmux-next or main keep their own policy there, usually
`cancel-in-progress: ${{ github.event_name == 'pull_request' }}`.

A workflow that must not cancel a superseded pull request run goes in ALLOWED
with the reason. Entries that stop being needed fail the test.

Run: python3 tests/test_ci_pr_runs_cancel_superseded.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
PR_EVENTS = ("pull_request", "pull_request_target")

# Workflows whose superseded pull request runs are deliberately not cancelled.
ALLOWED = {
    # Debounce runs supersede themselves and exit 0 (next_batch.py
    # `superseded`); a cancel would read as a red run. The batch job is never
    # cancelled. See OWN_SUPERSESSION in test_ci_required_checks_are_bounded.py.
    "cmux-next-batch.yml": "debounce runs supersede themselves; the batch is never cancelled",
    # Serialised per pull request so two signature events never write the CLA
    # ledger from different snapshots (comment on the CLAAssistant job).
    "cla.yml": "one ledger writer at a time per pull request",
    # A required check that also runs on metadata edits; a cancelled run would
    # leave a cancelled required verdict (test_cla_guard_metadata_routing.py
    # asserts it has no concurrency).
    "cla-policy-guard.yml": "metadata events must not cancel required verdicts",
    # The apply jobs migrate the staging and production databases; a cancel
    # could stop one between applying a migration and recording it.
    "backend-migrations.yml": "applies database migrations; never cancelled mid-apply",
    # Deploys preview, staging and production backends; deploy workflows
    # serialise instead of cancelling.
    "backend.yml": "deploy workflow",
    # Writes to the nightly R2 bucket; serialising is the safe answer there.
    "repair-nightly-appcast-content-types.yml": "writes nightly R2 objects; serialised",
}


# --- A small evaluator for GitHub Actions expressions -----------------------

_TOKEN = re.compile(
    r"\s*(?:"
    r"(?P<str>'(?:[^']|'')*')"
    r"|(?P<num>-?\d+(?:\.\d+)?)"
    r"|(?P<op>==|!=|<=|>=|&&|\|\||[!<>(),\[\].*])"
    r"|(?P<name>[A-Za-z_][A-Za-z0-9_-]*)"
    r")"
)


class ExpressionError(ValueError):
    pass


def _tokens(text: str) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    pos = 0
    text = text.strip()
    while pos < len(text):
        match = _TOKEN.match(text, pos)
        if not match or match.end() == pos:
            raise ExpressionError(f"cannot tokenize {text[pos:]!r}")
        kind = match.lastgroup or ""
        out.append((kind, match.group(kind)))
        pos = match.end()
    return out


def _truthy(value: Any) -> bool:
    return value not in (None, False, 0, "") and value == value


def _text(value: Any) -> str:
    if value is None:
        return ""
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, (dict, list)):
        return json.dumps(value)
    return str(value)


def _equal(left: Any, right: Any) -> bool:
    if isinstance(left, str) and isinstance(right, str):
        return left.lower() == right.lower()
    if type(left) is not type(right) and None not in (left, right):
        try:
            return float(_text(left) or 0) == float(_text(right) or 0)
        except ValueError:
            return False
    return left == right


def _call(name: str, args: list[Any]) -> Any:
    lowered = name.lower()
    if lowered == "format":
        template = _text(args[0])
        return re.sub(r"\{(\d+)\}", lambda m: _text(args[int(m.group(1)) + 1]), template)
    if lowered == "contains":
        haystack, needle = args
        if isinstance(haystack, list):
            return any(_equal(item, needle) for item in haystack)
        return _text(needle).lower() in _text(haystack).lower()
    if lowered == "startswith":
        return _text(args[0]).lower().startswith(_text(args[1]).lower())
    if lowered == "endswith":
        return _text(args[0]).lower().endswith(_text(args[1]).lower())
    if lowered == "fromjson":
        return json.loads(_text(args[0]))
    if lowered == "tojson":
        return json.dumps(args[0])
    if lowered in ("success", "always"):
        return True
    if lowered in ("failure", "cancelled"):
        return False
    raise ExpressionError(f"unsupported function {name}()")


class _Parser:
    def __init__(self, text: str, context: dict[str, Any]) -> None:
        self.tokens = _tokens(text)
        self.pos = 0
        self.context = context

    def peek(self) -> str | None:
        return self.tokens[self.pos][1] if self.pos < len(self.tokens) else None

    def take(self, expected: str | None = None) -> tuple[str, str]:
        if self.pos >= len(self.tokens):
            raise ExpressionError("unexpected end of expression")
        token = self.tokens[self.pos]
        if expected is not None and token[1] != expected:
            raise ExpressionError(f"expected {expected!r}, got {token[1]!r}")
        self.pos += 1
        return token

    def parse(self) -> Any:
        value = self.or_()
        if self.pos != len(self.tokens):
            raise ExpressionError(f"trailing tokens from {self.peek()!r}")
        return value

    def or_(self) -> Any:
        value = self.and_()
        while self.peek() == "||":
            self.take()
            right = self.and_()
            value = value if _truthy(value) else right
        return value

    def and_(self) -> Any:
        value = self.compare()
        while self.peek() == "&&":
            self.take()
            right = self.compare()
            value = right if _truthy(value) else value
        return value

    def compare(self) -> Any:
        value = self.unary()
        while self.peek() in ("==", "!=", "<", ">", "<=", ">="):
            op = self.take()[1]
            right = self.unary()
            if op == "==":
                value = _equal(value, right)
            elif op == "!=":
                value = not _equal(value, right)
            else:
                a, b = float(_text(value) or 0), float(_text(right) or 0)
                value = {"<": a < b, ">": a > b, "<=": a <= b, ">=": a >= b}[op]
        return value

    def unary(self) -> Any:
        if self.peek() == "!":
            self.take()
            return not _truthy(self.unary())
        return self.postfix()

    def postfix(self) -> Any:
        value = self.primary()
        while self.peek() in (".", "["):
            if self.take()[1] == ".":
                key = self.take()[1]
            else:
                key = _text(self.or_())
                self.take("]")
            value = value.get(key) if isinstance(value, dict) else None
        return value

    def primary(self) -> Any:
        kind, text = self.take()
        if text == "(":
            value = self.or_()
            self.take(")")
            return value
        if kind == "str":
            return text[1:-1].replace("''", "'")
        if kind == "num":
            return float(text)
        if kind == "name":
            if text == "true":
                return True
            if text == "false":
                return False
            if text == "null":
                return None
            if self.peek() == "(":
                self.take()
                args: list[Any] = []
                while self.peek() != ")":
                    args.append(self.or_())
                    if self.peek() == ",":
                        self.take()
                self.take(")")
                return _call(text, args)
            return self.context.get(text)
        raise ExpressionError(f"unexpected token {text!r}")


def evaluate(expression: str, context: dict[str, Any]) -> Any:
    return _Parser(expression, context).parse()


def resolve(value: Any, context: dict[str, Any]) -> Any:
    """A workflow field: a literal, one `${{ }}`, or a string with several."""
    if not isinstance(value, str):
        return value
    whole = re.fullmatch(r"\s*\$\{\{(.*?)\}\}\s*", value, re.S)
    if whole and value.count("${{") == 1:
        return evaluate(whole.group(1), context)
    return re.sub(r"\$\{\{(.*?)\}\}", lambda m: _text(evaluate(m.group(1), context)), value, flags=re.S)


def condition(value: Any, context: dict[str, Any]) -> bool:
    if value is None:
        return True
    if isinstance(value, bool):
        return value
    text = str(value).strip()
    whole = re.fullmatch(r"\$\{\{(.*?)\}\}", text, re.S) if text.count("${{") == 1 else None
    if text.count("${{") > 1:
        return _truthy(resolve(text, context))
    return _truthy(evaluate(whole.group(1) if whole else text, context))


# --- The rule ---------------------------------------------------------------


def load(path: Path) -> dict:
    parsed = yaml.safe_load(path.read_text(encoding="utf-8"))
    return parsed if isinstance(parsed, dict) else {}


def triggers(workflow: dict) -> dict[str, Any]:
    on = workflow.get("on", workflow.get(True, {}))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {name: None for name in on}
    return dict(on or {})


def pr_context(workflow: dict, event: str, number: int, run: int) -> dict[str, Any]:
    """The contexts of a `synchronize` run of pull request `number`."""
    base = "feat-cmux-next"
    ref = f"refs/pull/{number}/merge" if event == "pull_request" else f"refs/heads/{base}"
    sha = f"{number:04d}{run:036d}"
    pull_request = {
        "number": number,
        "head": {"sha": sha, "ref": f"topic-{number}", "repo": {"full_name": "manaflow-ai/cmux", "fork": False}},
        "base": {"ref": base, "sha": "b" * 40},
        "draft": False,
        "labels": [],
        "body": "",
        "title": f"PR {number}",
    }
    return {
        "github": {
            "event_name": event,
            "event": {"action": "synchronize", "number": number, "pull_request": pull_request},
            "ref": ref,
            "ref_name": f"{number}/merge" if event == "pull_request" else base,
            "head_ref": f"topic-{number}",
            "base_ref": base,
            "sha": sha,
            "run_id": 1000 + run + number * 10,
            "run_number": run,
            "run_attempt": 1,
            "workflow": workflow.get("name") or "workflow",
            "repository": "manaflow-ai/cmux",
            "repository_owner": "manaflow-ai",
            "actor": "someone",
        },
        "inputs": {},
        "vars": {},
        "env": {},
        "needs": {},
        "steps": {},
        "runner": {},
        "matrix": {},
        "secrets": {},
    }


def problem(concurrency: Any, workflow: dict, event: str) -> str | None:
    """Why `concurrency` does not cancel a superseded run of one PR, or None."""
    if not concurrency:
        return "no concurrency group"
    if isinstance(concurrency, str):
        concurrency = {"group": concurrency, "cancel-in-progress": False}
    first, again, other = (
        pr_context(workflow, event, 101, 1),
        pr_context(workflow, event, 101, 2),
        pr_context(workflow, event, 202, 1),
    )
    try:
        groups = [_text(resolve(concurrency.get("group"), c)) for c in (first, again, other)]
        cancels = _truthy(resolve(concurrency.get("cancel-in-progress", False), again))
    except (ExpressionError, KeyError, IndexError, TypeError, ValueError) as error:
        return f"cannot evaluate its concurrency: {error}"
    if groups[0] != groups[1]:
        return f"two pushes to one pull request get different groups ({groups[0]!r} vs {groups[1]!r})"
    if groups[0] == groups[2]:
        return f"every pull request shares one group ({groups[0]!r}), so one PR's push cancels or queues another's"
    if not cancels:
        return f"cancel-in-progress is false for {event} events"
    return None


def jobs_on(workflow: dict, event: str) -> dict[str, dict]:
    """Jobs whose `if` does not rule out a synchronize run of `event`."""
    context = pr_context(workflow, event, 101, 1)
    out: dict[str, dict] = {}
    for job_id, job in (workflow.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        try:
            runs = condition(job.get("if"), context)
        except (ExpressionError, KeyError, IndexError, TypeError, ValueError):
            runs = True
        if runs or "needs." in str(job.get("if", "")):
            out[job_id] = job
    return out


# Activity types a push to a pull request's head produces. GitHub's default
# pull_request types (opened, synchronize, reopened) include it.
PUSH_TYPES = {"synchronize"}


def push_starts_a_run(trigger: Any) -> bool:
    """False when the event's `types:` filter leaves out every push activity type.

    A workflow that runs only on `labeled` (cmux-next-media.yml) gets no run
    from a push, so there is no superseded push run to cancel.
    """
    if not isinstance(trigger, dict) or "types" not in trigger:
        return True
    types = trigger.get("types")
    types = [types] if isinstance(types, str) else list(types or [])
    return bool(PUSH_TYPES & set(types))


def workflow_problem(workflow: dict) -> str | None:
    for event in PR_EVENTS:
        if event not in triggers(workflow):
            continue
        if not push_starts_a_run(triggers(workflow)[event]):
            continue
        reason = problem(workflow.get("concurrency"), workflow, event)
        if reason is None:
            continue
        jobs = jobs_on(workflow, event)
        job_reasons = {job_id: problem(job.get("concurrency"), workflow, event) for job_id, job in jobs.items()}
        if jobs and all(r is None for r in job_reasons.values()):
            continue
        bad_jobs = ", ".join(f"{j}: {r}" for j, r in job_reasons.items() if r)
        return f"{event}: {reason}" + (f" (jobs: {bad_jobs})" if workflow.get("jobs") and not workflow.get("concurrency") else "")
    return None


def self_check() -> list[str]:
    """The evaluator agrees with GitHub on the shapes the workflows use."""
    failures = []
    on = {"on": {"pull_request": None, "push": None}}
    cases = {
        "keyed by PR, cancels on PR": ({"group": "w-${{ github.event.pull_request.number || github.ref }}", "cancel-in-progress": "${{ github.event_name == 'pull_request' }}"}, True),
        "keyed by merge ref": ({"group": "w-${{ github.ref }}", "cancel-in-progress": True}, True),
        "keyed by sha": ({"group": "w-${{ github.sha }}", "cancel-in-progress": True}, False),
        "keyed by run": ({"group": "w-${{ github.run_id }}", "cancel-in-progress": True}, False),
        "never cancels": ({"group": "w-${{ github.ref }}", "cancel-in-progress": False}, False),
        "one global group": ({"group": "w", "cancel-in-progress": True}, False),
        "cancels only pushes": ({"group": "w-${{ github.ref }}", "cancel-in-progress": "${{ github.event_name == 'push' }}"}, False),
        "format and fallbacks": ({"group": "${{ github.event_name == 'push' && format('w-push-{0}', github.ref) || format('w-pr-{0}', github.event.pull_request.number) }}", "cancel-in-progress": "${{ github.event_name != 'push' }}"}, True),
    }
    for name, (concurrency, ok) in cases.items():
        verdict = problem(concurrency, on, "pull_request") is None
        if verdict != ok:
            failures.append(f"self-check {name!r}: expected {'pass' if ok else 'fail'}")
    if workflow_problem({"on": {"pull_request": {"types": ["labeled"]}}, "concurrency": {"group": "w-${{ github.run_id }}"}}) is not None:
        failures.append("self-check: a labeled-only workflow gets no push run to cancel")
    if workflow_problem({"on": {"pull_request": {"types": ["labeled", "synchronize"]}}, "concurrency": {"group": "w-${{ github.run_id }}"}}) is None:
        failures.append("self-check: a workflow whose types include synchronize is still judged")
    # pull_request_target runs carry the base branch in github.ref.
    if problem({"group": "w-${{ github.ref }}", "cancel-in-progress": True}, on, "pull_request_target") is None:
        failures.append("self-check: a github.ref group must not count as per-PR for pull_request_target")
    return failures


def main() -> int:
    failures = self_check()
    checked = 0
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        workflow = load(path)
        if not any(event in triggers(workflow) for event in PR_EVENTS):
            continue
        checked += 1
        reason = workflow_problem(workflow)
        if path.name in ALLOWED:
            if reason is None:
                failures.append(f"{path.name} now cancels superseded runs; remove its ALLOWED entry")
            continue
        if reason:
            failures.append(f"{path.relative_to(ROOT)}: {reason}")
    for name, why in sorted(ALLOWED.items()):
        if not why.strip() or not (WORKFLOWS / name).exists():
            failures.append(f"ALLOWED names {name}, which no longer exists or has no reason")
    if failures:
        print("superseded pull request runs that keep running:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(f"{checked} pull request workflows cancel a superseded run ({len(ALLOWED)} allowed exceptions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
