#!/usr/bin/env python3
"""A pull request description edit or a comment starts no runner unless a job reads what changed.

Leo, 2026-11-17, quoting an agent who said "Every edit or comment re-runs several of those checks, so
that alone added hundreds of jobs. I've told it to stop editing descriptions.": "why should it do that".

`pull_request` / `pull_request_target` with `edited` in its types starts a run for every title, body or
base change, and `issue_comment`, `pull_request_review`, `pull_request_review_comment` and
`discussion_comment` start one for every comment, review or edit of one, bots' status comments included.
Each run that starts a job takes a runner from the same capped pool the nightly waits on.

This test simulates each such workflow on those events (job `if:`, `needs:` and the status functions, read
the way GitHub reads them) and fails when:

- a workflow listens to `edited` but is not in EDIT_READS, which names the edit fields (title, body,
  base) whose change re-runs it, and why;
- a job starts on an edit that changes only fields its entry does not name;
- a skipped edit's run shares a concurrency group with a push's or a read edit's run (it would cancel the
  real run, or replace it while pending);
- a job that publishes a ruleset-required context (REQUIRED_CONTEXTS) is skipped by any edit its workflow
  listens to: GitHub reads the newest suite of a workflow for a required context, so a suite whose job
  was skipped (or renamed) leaves the context "expected" and blocks the merge (cmux#13871). Such a
  workflow either runs on every edit or drops `edited`;
- a job starts on an ordinary comment or review (one that is not a command) unless COMMENT_REACTS says
  why, or a command in COMMENT_COMMANDS no longer starts its job, or an ordinary comment shares the
  command's concurrency group.

A job skipped by an edit keeps its check name and reads as a pass to a newest-by-name merge gate, so an
entry that skips edits says why that is harmless (advisory, warn-only, or the answer cannot change).

One copy serves main and feat-cmux-next: entries are keyed by workflow and event (a pull_request_target
workflow always runs from the default branch's copy), and an entry whose workflow is absent here is the
other branch's.

Run: python3 tests/test_ci_edit_events_start_no_runner.py
Handbook: cmuxterm-hq docs/handbook/edit-or-comment-reruns-every-check.md
"""

from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
REPOSITORY = "manaflow-ai/cmux"
BASES = ("feat-cmux-next", "main")
FIELDS = ("title", "body", "base")
ALL = frozenset(FIELDS)

# Required by a repository ruleset (main: CLA Assistant, CLA policy guard, backend migrations applied;
# feat-cmux-next: the two below; scripts/ci/required_status_checks.py keeps the copy).
REQUIRED_CONTEXTS_BY_BASE = {
    "main": frozenset({"CLA Assistant", "CLA policy guard", "backend migrations applied"}),
    "feat-cmux-next": frozenset({"clippy (changed cmux-tui packages)", "React Doctor (changed React projects)"}),
}
REQUIRED_CONTEXTS = frozenset().union(*REQUIRED_CONTEXTS_BY_BASE.values())

# (workflow, event) pairs that listen to `edited`: the edit fields whose change re-runs them, and why.
EDIT_READS: dict[tuple[str, str], tuple[frozenset[str], str]] = {
    ("backend-migrations.yml", "pull_request_target"): (ALL, "publishes the required `backend migrations "
        "applied` in every suite, and a retarget (main <-> feat-cmux-next) re-judges it"),
    ("cloud-resume-matrix.yml", "pull_request"): (frozenset({"body"}), "opt-in by the `resume-matrix: run` or "
        "`resume-matrix: full` body line (its plan job skips an edit that leaves the body alone); advisory, no "
        "required context"),
    ("cloud-wake-echo.yml", "pull_request"): (frozenset({"body"}), "opt-in by the `wake-echo: run` body line (its "
        "job skips an edit that leaves the body alone); advisory, no required context"),
    ("gallery-advisory.yml", "pull_request"): (frozenset({"body"}), "reads the `Gallery:` and `Visual-change:` "
        "body lines (its jobs skip a body edit that touches neither); advisory, warn-only"),
    ("classic-api-guard.yml", "pull_request"): (frozenset({"body", "base"}), "this copy starts on its "
        "own only into main, into feat-cmux-next through pr-router.yml: re-runs when the `Classic API change:` line or the base moves; "
        "into feat-cmux-next a skip reads the same as a warning"),
    ("classic-api-guard.yml", "pull_request_target"): (ALL, "fails a pull request into main that lacks the "
        "line; a skip under its name would read as a pass"),
    ("classic-frozen-guard.yml", "pull_request_target"): (ALL, "fails a frozen change; a skip under its name "
        "would read as a pass"),
    ("pr-router.yml", "pull_request"): (frozenset({"body", "base"}), "routes a body edit for the size "
        "budget's `size:` line and the classic API guard's `Classic API change:` line, and a base change for the "
        "guard (callees cmux-next-size-budget.yml, classic-api-guard.yml; each callee's own job `if:` skips the "
        "edits it does not read); a skip after a title edit is unchanged since the budget landed"),
    ("language-boundaries.yml", "pull_request_target"): (ALL, "keeps its old edit behavior: it runs on every "
        "edit until a change carrying Leo's label gates it (only his label lets this check change)"),
    ("pr-body-checks.yml", "pull_request"): (ALL, "the description lints read the body, the perf section the "
        "title too"),
    ("pr-checks.yml", "pull_request"): (frozenset({"body"}), "its advisory job's PR size step reads the `Size:` "
        "line and UI review its section (the pick step runs only what the edit moved); none of its steps fails a "
        "pull request"),
}

# A comment event whose jobs may start on any comment or review, and why.
COMMENT_REACTS: dict[tuple[str, str], str] = {}

# A comment that is a command for its workflow: (event, body, author type). It must still start a job.
COMMENT_COMMANDS: dict[str, tuple[str, str, str]] = {}

COMMENT_EVENTS = ("issue_comment", "pull_request_review", "pull_request_review_comment", "discussion_comment")
ORDINARY_COMMENTS = ("Thanks, this looks good to me.", "<!-- pr-status -->\nCI: 12 of 40 checks passed")


# ---------------------------------------------------------------------------------------------------
# A small evaluator for GitHub's expression language (docs: "Evaluate expressions in workflows").

class ExpressionError(ValueError):
    pass


_TOKEN = re.compile(r"""
    (?P<space>\s+)
  | (?P<string>'(?:[^']|'')*')
  | (?P<number>-?(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?))
  | (?P<op>==|!=|<=|>=|&&|\|\||[!<>()\[\].,*])
  | (?P<name>[A-Za-z_][A-Za-z0-9_-]*)
""", re.VERBOSE)


def _tokens(expression: str) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    position = 0
    while position < len(expression):
        match = _TOKEN.match(expression, position)
        if not match:
            raise ExpressionError(f"cannot read {expression[position:position + 20]!r} in {expression!r}")
        position = match.end()
        kind = match.lastgroup or ""
        if kind != "space":
            out.append((kind, match.group()))
    return out


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


def _number(value: Any) -> float:
    if value is None:
        return 0.0
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return 0.0
        try:
            return float(int(text, 16)) if text.lower().startswith("0x") else float(text)
        except ValueError:
            return math.nan
    return math.nan


def truthy(value: Any) -> bool:
    if value is None or value is False:
        return False
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value != 0 and not math.isnan(value)
    if isinstance(value, str):
        return value != ""
    return True


def _equal(left: Any, right: Any) -> bool:
    if isinstance(left, str) and isinstance(right, str):
        return left.lower() == right.lower()
    if isinstance(left, (dict, list)) or isinstance(right, (dict, list)):
        return left is right
    if type(left) is type(right):
        return left == right
    return _number(left) == _number(right)


def _lookup(value: Any, key: Any) -> Any:
    if isinstance(value, dict):
        if isinstance(key, str):
            for name, item in value.items():
                if str(name).lower() == key.lower():
                    return item
        return None
    if isinstance(value, list):
        if isinstance(key, str):
            return None
        index = _number(key)
        if math.isnan(index) or not index.is_integer() or not 0 <= int(index) < len(value):
            return None
        return value[int(index)]
    return None


class _Filtered(list):
    """The result of `.*`: the next property applies to each element."""


class _Parser:
    def __init__(self, expression: str, context: dict[str, Any], status: dict[str, bool]):
        self.items = _tokens(expression)
        self.position = 0
        self.context = context
        self.status = status
        self.expression = expression

    def peek(self) -> tuple[str, str] | None:
        return self.items[self.position] if self.position < len(self.items) else None

    def take(self, text: str | None = None) -> tuple[str, str]:
        token = self.peek()
        if token is None or (text is not None and token[1] != text):
            raise ExpressionError(f"expected {text or 'a token'} in {self.expression!r}")
        self.position += 1
        return token

    def parse(self) -> Any:
        value = self.parse_or()
        if self.peek() is not None:
            raise ExpressionError(f"trailing {self.peek()} in {self.expression!r}")
        return value

    def parse_or(self) -> Any:
        value = self.parse_and()
        while self.peek() and self.peek()[1] == "||":
            self.take()
            right = self.parse_and()
            value = value if truthy(value) else right
        return value

    def parse_and(self) -> Any:
        value = self.parse_compare()
        while self.peek() and self.peek()[1] == "&&":
            self.take()
            right = self.parse_compare()
            value = right if truthy(value) else value
        return value

    def parse_compare(self) -> Any:
        value = self.parse_unary()
        while self.peek() and self.peek()[1] in ("==", "!=", "<", ">", "<=", ">="):
            operator = self.take()[1]
            right = self.parse_unary()
            if operator == "==":
                value = _equal(value, right)
            elif operator == "!=":
                value = not _equal(value, right)
            else:
                a, b = _number(value), _number(right)
                value = {"<": a < b, ">": a > b, "<=": a <= b, ">=": a >= b}[operator]
        return value

    def parse_unary(self) -> Any:
        if self.peek() and self.peek()[1] == "!":
            self.take()
            return not truthy(self.parse_unary())
        return self.parse_postfix(self.parse_primary())

    def parse_primary(self) -> Any:
        kind, text = self.take()
        if text == "(":
            value = self.parse_or()
            self.take(")")
            return value
        if kind == "string":
            return text[1:-1].replace("''", "'")
        if kind == "number":
            return float(int(text, 16)) if text.lower().startswith("0x") else float(text)
        if kind != "name":
            raise ExpressionError(f"unexpected {text!r} in {self.expression!r}")
        lowered = text.lower()
        if lowered in ("true", "false"):
            return lowered == "true"
        if lowered == "null":
            return None
        if self.peek() and self.peek()[1] == "(":
            self.take("(")
            arguments: list[Any] = []
            while not (self.peek() and self.peek()[1] == ")"):
                arguments.append(self.parse_or())
                if self.peek() and self.peek()[1] == ",":
                    self.take(",")
            self.take(")")
            return self.call(lowered, arguments)
        return _lookup(self.context, lowered)

    def parse_postfix(self, value: Any) -> Any:
        while self.peek() and self.peek()[1] in (".", "["):
            if self.take()[1] == ".":
                token = self.take()
                if token[1] == "*":
                    value = _Filtered(value.values() if isinstance(value, dict) else
                                      value if isinstance(value, list) else [])
                    continue
                key: Any = token[1]
            else:
                key = self.parse_or()
                self.take("]")
            if isinstance(value, _Filtered):
                value = _Filtered(item for item in (_lookup(element, key) for element in value) if item is not None)
            else:
                value = _lookup(value, key)
        return value

    def call(self, name: str, arguments: list[Any]) -> Any:
        if name in self.status:
            return self.status[name]
        if name == "contains":
            haystack, needle = arguments
            if isinstance(haystack, list):
                return any(_equal(item, needle) for item in haystack)
            return _text(needle).lower() in _text(haystack).lower()
        if name == "startswith":
            return _text(arguments[0]).lower().startswith(_text(arguments[1]).lower())
        if name == "endswith":
            return _text(arguments[0]).lower().endswith(_text(arguments[1]).lower())
        if name == "format":
            pattern, rest = _text(arguments[0]), arguments[1:]
            return re.sub(r"\{(\d+)\}", lambda m: _text(rest[int(m.group(1))]), pattern)
        if name == "join":
            separator = _text(arguments[1]) if len(arguments) > 1 else ","
            items = arguments[0] if isinstance(arguments[0], list) else [arguments[0]]
            return separator.join(_text(item) for item in items)
        if name == "tojson":
            return json.dumps(arguments[0])
        if name == "fromjson":
            text = _text(arguments[0])
            if not text:
                raise ExpressionError(f"fromJSON of an empty value in {self.expression!r}")
            return json.loads(text)
        if name == "hashfiles":
            return ""
        raise ExpressionError(f"unknown function {name}() in {self.expression!r}")


STATUS_FUNCTION = re.compile(r"\b(always|success|failure|cancelled)\s*\(", re.IGNORECASE)


def evaluate(expression: str, context: dict[str, Any], status: dict[str, bool] | None = None) -> Any:
    return _Parser(expression, context, status or {}).parse()


def _spans(text: str) -> list[tuple[int, int]]:
    """Each `${{ ... }}` span in TEXT, reading string literals so a `}}` inside one does not end it."""
    spans: list[tuple[int, int]] = []
    position = 0
    while True:
        start = text.find("${{", position)
        if start < 0:
            return spans
        index = start + 3
        while index < len(text):
            if text[index] == "'":
                index = text.find("'", index + 1)
                while index >= 0 and text[index + 1:index + 2] == "'":
                    index = text.find("'", index + 2)
                if index < 0:
                    raise ExpressionError(f"unterminated string in {text!r}")
            elif text.startswith("}}", index):
                break
            index += 1
        else:
            raise ExpressionError(f"unterminated ${{{{ in {text!r}")
        spans.append((start, index + 2))
        position = index + 2


def interpolate(text: Any, context: dict[str, Any]) -> str:
    text = _text(text)
    out, last = [], 0
    for start, end in _spans(text):
        out.append(text[last:start])
        out.append(_text(evaluate(text[start + 3:end - 2], context)))
        last = end
    out.append(text[last:])
    return "".join(out)


def condition(raw: Any) -> str:
    """A job `if:` as an expression: GitHub accepts it with or without one enclosing `${{ }}`."""
    text = _text(raw).strip()
    spans = _spans(text) if "${{" in text else []
    if len(spans) == 1 and spans[0] == (0, len(text)):
        return text[3:-2].strip()
    if spans:
        return "'" + interpolate(text, {}).replace("'", "''") + "'"
    return text or "success()"


# ---------------------------------------------------------------------------------------------------
# Events and the run of one workflow on one of them.

_IDS = iter(range(100, 10**9))


def pr_event(action: str, base: str, changes: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "action": action,
        "number": 7,
        "changes": changes or {},
        "pull_request": {
            "number": 7, "title": "cmux: a change", "body": "## Changelog\n- A change.", "draft": False,
            "state": "open", "labels": [], "user": {"login": "someone", "type": "User"},
            "base": {"ref": base, "sha": "b" * 40, "repo": {"full_name": REPOSITORY}},
            "head": {"ref": "lane/x", "sha": "c" * 40, "repo": {"full_name": REPOSITORY}},
        },
        "repository": {"name": REPOSITORY.split("/")[1], "full_name": REPOSITORY},
    }


EDIT_CHANGES = {
    "title": {"title": {"from": "an older title"}},
    "body": {"body": {"from": "an older description"}},
    "base": {"base": {"ref": {"from": "main"}, "sha": {"from": "d" * 40}}},
}


def comment_event(event_name: str, body: str, author_type: str, base: str, action: str) -> dict[str, Any]:
    event = pr_event(action, base)
    user = {"login": "cmux-bot[bot]" if author_type == "Bot" else "someone", "type": author_type}
    event["comment"] = {"id": next(_IDS), "body": body, "user": user, "author_association": "MEMBER"}
    event["issue"] = {"number": 7, "title": "cmux: a change", "pull_request": {"url": "https://example"},
                      "user": user, "body": ""}
    event["review"] = {"id": next(_IDS), "body": body, "state": "commented", "user": user}
    event["discussion"] = {"number": 7}
    return event


def github_context(event_name: str, event: dict[str, Any]) -> dict[str, Any]:
    return {
        "github": {
            "event_name": event_name, "event": event, "repository": REPOSITORY,
            "repository_owner": REPOSITORY.split("/")[0], "run_id": str(next(_IDS)), "run_number": "5",
            "run_attempt": "1", "sha": "e" * 40, "workflow_sha": "f" * 40,
            "ref": "refs/pull/7/merge" if event_name == "pull_request" else
            f"refs/heads/{event['pull_request']['base']['ref']}",
            "head_ref": "lane/x", "base_ref": event["pull_request"]["base"]["ref"], "actor": "someone",
            "triggering_actor": "someone", "workflow": "w", "token": "",
        },
        "vars": {}, "secrets": {}, "inputs": {}, "env": {}, "matrix": {}, "strategy": {},
    }


def triggers(document: dict[str, Any]) -> dict[str, Any]:
    on = document.get("on", document.get(True))
    if isinstance(on, str):
        return {on: {}}
    if isinstance(on, list):
        return {name: {} for name in on}
    return {name: (config or {}) for name, config in (on or {}).items()} if isinstance(on, dict) else {}


def run(document: dict[str, Any], context: dict[str, Any]) -> dict[str, str]:
    """Each job's result on this event: 'success' when it starts (takes a runner), else 'skipped'."""
    jobs: dict[str, Any] = document.get("jobs") or {}
    results: dict[str, str] = {}

    def resolve(name: str, trail: tuple[str, ...] = ()) -> str:
        if name in results:
            return results[name]
        if name in trail:
            raise ExpressionError(f"needs cycle through {name}")
        body = jobs.get(name) or {}
        needs = body.get("needs") or []
        needs = [needs] if isinstance(needs, str) else list(needs)
        upstream = {need: resolve(need, trail + (name,)) for need in needs}
        status = {"always": True, "cancelled": False, "failure": False,
                  "success": all(result == "success" for result in upstream.values())}
        expression = condition(body.get("if"))
        if not STATUS_FUNCTION.search(expression):
            expression = f"success() && ({expression})"
        scope = dict(context, needs={need: {"result": result, "outputs": {}} for need, result in upstream.items()})
        results[name] = "success" if truthy(evaluate(expression, scope, status)) else "skipped"
        return results[name]

    for name in jobs:
        resolve(name)
    return results


def job_name(name: str, body: dict[str, Any], context: dict[str, Any]) -> str:
    return interpolate(body.get("name") or name, context)


def groups(document: dict[str, Any], body: dict[str, Any] | None, context: dict[str, Any]) -> str | None:
    concurrency = (body if body is not None else document).get("concurrency")
    if concurrency is None:
        return None
    group = concurrency.get("group") if isinstance(concurrency, dict) else concurrency
    return interpolate(group, context)


def pr_events(config: dict[str, Any]) -> list[str]:
    return [name for name in ("pull_request", "pull_request_target")
            if isinstance(config.get(name), dict) and "edited" in (config[name].get("types") or [])]


def bases(config: dict[str, Any], event_name: str) -> list[str]:
    listed = (config.get(event_name) or {}).get("branches")
    if not listed:
        return list(BASES)
    return [base for base in BASES if base in listed] or [str(listed[0])]


def check_edits(name: str, event_name: str, document: dict[str, Any], failures: list[str]) -> None:
    config = triggers(document)
    reads = EDIT_READS[(name, event_name)][0]
    jobs: dict[str, Any] = document.get("jobs") or {}
    for base in bases(config, event_name):
        push = github_context(event_name, pr_event("synchronize", base))
        pushed = run(document, push)
        edits = {field: github_context(event_name, pr_event("edited", base, EDIT_CHANGES[field])) for field in FIELDS}
        for field, edit in edits.items():
            where = f"{name} ({event_name} into {base}), an edit of the {field} only"
            ran = run(document, edit)
            for job, result in ran.items():
                body = jobs.get(job) or {}
                if pushed.get(job) == "success" and result != "success" and \
                        job_name(job, body, push) in REQUIRED_CONTEXTS_BY_BASE.get(base, REQUIRED_CONTEXTS):
                    failures.append(f"{where}: job {job} publishes the required {job_name(job, body, push)!r} "
                                    "but skips; the newest suite would lack it and block the merge (cmux#13871): "
                                    "run it on every edit or drop `edited`")
                if field in reads:
                    continue
                if result == "success":
                    failures.append(f"{where}: job {job} starts a runner; gate it with a job-level if on "
                                    "github.event.changes, drop `edited`, or name the field in EDIT_READS")
                elif pushed.get(job) == "success":
                    mine = groups(document, body, edit)
                    if mine is not None and mine in {groups(document, body, other)
                                                     for other in [push, *(edits[f] for f in reads)]}:
                        failures.append(f"{where}: job {job}'s concurrency group {mine!r} is the real run's")
            if field in reads or any(result == "success" for result in ran.values()):
                continue
            mine = groups(document, None, edit)
            if mine is not None and mine in {groups(document, None, other) for other in [push, *(edits[f] for f in reads)]}:
                failures.append(f"{where}: the workflow's concurrency group {mine!r} is the real run's; "
                                "give a skipped edit a group of its own")


def check_comments(name: str, document: dict[str, Any], failures: list[str]) -> None:
    config = triggers(document)
    command = COMMENT_COMMANDS.get(name)
    for event_name in COMMENT_EVENTS:
        if event_name not in config or (name, event_name) in COMMENT_REACTS:
            continue
        actions = (config[event_name] or {}).get("types") or ["created"]
        for base in BASES:
            for action in actions:
                for body in ORDINARY_COMMENTS:
                    for author in ("User", "Bot"):
                        context = github_context(event_name, comment_event(event_name, body, author, base, action))
                        started = [job for job, result in run(document, context).items() if result == "success"]
                        if started:
                            failures.append(f"{name}: an ordinary {event_name} ({action}, {author}, into {base}) "
                                            f"starts {', '.join(started)}; gate the job on the command text "
                                            "or say why in COMMENT_REACTS")
                        if command and command[0] == event_name:
                            real = github_context(event_name, comment_event(event_name, command[1], command[2],
                                                                            base, "created"))
                            mine = groups(document, None, context)
                            if mine is not None and mine == groups(document, None, real):
                                failures.append(f"{name}: an ordinary {event_name} shares the command's "
                                                f"concurrency group {mine!r}; it would cancel the command's run")
    if command:
        event_name, body, author = command
        started = False
        for base in BASES:
            context = github_context(event_name, comment_event(event_name, body, author, base, "created"))
            started = started or any(result == "success" for result in run(document, context).values())
        if not started:
            failures.append(f"{name}: its command {body!r} starts no job; fix the gate or COMMENT_COMMANDS")


def main() -> int:
    failures: list[str] = []
    edited: set[tuple[str, str]] = set()
    commented: set[str] = set()
    present = {path.name for path in WORKFLOWS.glob("*.y*ml")}
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            continue
        config = triggers(document)
        try:
            for event_name in pr_events(config):
                edited.add((path.name, event_name))
                if (path.name, event_name) not in EDIT_READS:
                    failures.append(f"{path.name} ({event_name}) re-runs on every title, body and base edit: drop "
                                    "`edited`, or name the fields it reads in EDIT_READS and gate its jobs")
                else:
                    check_edits(path.name, event_name, document, failures)
            if any(event in config for event in COMMENT_EVENTS):
                commented.add(path.name)
                check_comments(path.name, document, failures)
        except ExpressionError as error:
            failures.append(f"{path.name}: {error}")
    # An entry whose workflow is here but listens to no `edited` at all is stale; one whose workflow is absent,
    # or listens through the other event, is the other branch's.
    listening = {name for name, _ in edited}
    for name, event in sorted(set(EDIT_READS) - edited):
        if name in present and name not in listening:
            failures.append(f"{name} ({event}) is in EDIT_READS but no longer listens to `edited`: drop the entry")
    for name in sorted((set(COMMENT_COMMANDS) & present) - commented):
        failures.append(f"{name} is in COMMENT_COMMANDS but no longer listens to comments: drop the entry")
    for name, event in sorted(set(COMMENT_REACTS)):
        if name in present and name not in commented:
            failures.append(f"{name} is in COMMENT_REACTS but no longer listens to {event}: drop the entry")
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if failures:
        return 1
    print(f"{len(edited)} workflow events listen to edits and {len(commented)} workflows to comments; "
          "an edit or comment none of them reads starts no runner")
    return 0


if __name__ == "__main__":
    sys.exit(main())
