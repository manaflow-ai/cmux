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
`cancel-in-progress: ${{ github.event_name == 'pull_request' }}`. But a pull
request run that cancels must never share a group with one of them (a push to
main or feat-cmux-next, a schedule, a dispatch), or the pull request run would
cancel it: that is checked here too.

A workflow that must not cancel a superseded pull request run goes in ALLOWED
with the reason. Entries that stop being needed fail the test.

The same fan-out comes from a title or description edit and from a comment
(pattern pr-edit-fans-out-ci in cmuxterm-hq docs/handbook: 130 HOLD-line body
edits queued about a dozen Blacksmith jobs each; Leo, 2026-11-17: "why is there
so much stuck in blacksmith queue?"). So, with the same evaluator:

- A workflow with `edited` in its pull request types that never reads the
  description (no `pull_request.body`/`.title`/`changes.body`/`changes.title`,
  and not in READS_DESCRIPTION) starts no job on a title-only or body-only
  edit, runs it in a concurrency group of its own (so it never cancels or
  replaces a push's run), and publishes each skipped job under another name
  (a skipped job reads as success for a required or newest-by-name check).
  `edited` stays for a base change, which re-judges the diff.
- A workflow triggered by `issue_comment` starts no job for an ordinary
  comment: every job's `if:` admits only the comment it serves, before a
  runner is taken.

A merged or closed pull request's run is the same waste, and a push never
replaces it. A closed-cancel twin (CLOSED_TWINS) ends it: a workflow on
`pull_request: types: [closed]` whose concurrency group, on that closed event,
is the group its target gives the pull request's synchronize runs, with
cancel-in-progress. Its group is checked against the target's, so a change to
either one's group that stops them matching goes red here; a `no-janitor` label
must keep the run (a group of its own).

Run: python3 tests/test_ci_pr_runs_cancel_superseded.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

import yaml
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import gh_expressions  # noqa: E402  (finds each ${{ }}: a regex cuts at a }} in a string)


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
PR_EVENTS = ("pull_request", "pull_request_target")

# Workflows whose superseded pull request runs are deliberately not cancelled.
ALLOWED = {
    # Debounce runs supersede themselves and exit 0 (next_batch.py
    # `superseded`); a cancel would read as a red run. The batch job is never
    # cancelled. See OWN_SUPERSESSION in test_ci_required_checks_are_bounded.py.
    "cmux-next-batch.yml": "debounce runs supersede themselves; the batch is never cancelled",
    # Deploys preview, staging and production backends; deploy workflows
    # serialise instead of cancelling. A pull request run also applies its
    # migrations to the shared development database (migrations-development)
    # before its preview deploy, so a workflow-level cancel could stop one
    # mid-apply. Its test jobs (api-workerd, test) cancel per pull request at
    # job level instead (backend_test_job_problems below).
    "backend.yml": "deploy workflow; PR runs apply migrations to the shared development database",
    # Opt-in measurements (a marker line in the body): a new head runs beside the one running, never cancelled
    # (cloud-resume-matrix.yml's header), so an hour of samples on staging machines is not thrown away mid-cell.
    "cloud-resume-matrix.yml": "opt-in resume measurement; a new head runs beside the running one, never cancelled",
    "cloud-wake-echo.yml": "opt-in wake measurement, as cloud-resume-matrix.yml: a new head runs beside the running one",
    # Its 3 min `changed` gate has no group on purpose: a push that measures nothing must not cancel the head still
    # being measured. The measuring `report` job cancels per pull request (its job concurrency).
    "chat-open-perf-report.yml": "the push gate has no group so a no-measure push never cancels a running report",
}


# Closed-cancel twins: each ends its target's run for a pull request when that
# pull request closes, by joining the target's per-pull-request group.
CLOSED_TWINS = {
    "cmux-next-pr-closed-cancel.yml": "cmux-next.yml",
    "cmux-next-pr-autofix-closed-cancel.yml": "cmux-next-pr-autofix.yml",
    # The CI run of a merged PR held 15 Linux jobs after the merge (run 44326505154).
    "ci-pr-closed-cancel.yml": "ci.yml",
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
        star = False
        while self.peek() in (".", "["):
            if self.take()[1] == ".":
                key = self.take()[1]
            else:
                key = _text(self.or_())
                self.take("]")
            if key == "*":
                # An object filter: `labels.*.name` is every label's name.
                value = list(value.values()) if isinstance(value, dict) else value if isinstance(value, list) else None
                star = True
                continue
            if star and isinstance(value, list):
                value = [item.get(key) if isinstance(item, dict) else None for item in value]
                continue
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
    whole = gh_expressions.EXPRESSION.fullmatch(value.strip())
    if whole and value.count("${{") == 1:
        return evaluate(whole.group(1), context)
    return gh_expressions.EXPRESSION.sub(lambda m: _text(evaluate(m.group(1), context)), value)


def condition(value: Any, context: dict[str, Any]) -> bool:
    if value is None:
        return True
    if isinstance(value, bool):
        return value
    text = str(value).strip()
    whole = gh_expressions.EXPRESSION.fullmatch(text) if text.count("${{") == 1 else None
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


# Runs a pull request run must never cancel: (event, ref) of each.
NON_PR_RUNS = (
    ("push", "refs/heads/feat-cmux-next"),
    ("push", "refs/heads/main"),
    ("schedule", "refs/heads/feat-cmux-next"),
    ("workflow_dispatch", "refs/heads/feat-cmux-next"),
    ("workflow_dispatch", "refs/heads/main"),
)


def non_pr_context(workflow: dict, event: str, ref: str) -> dict[str, Any]:
    context = pr_context(workflow, "pull_request", 101, 1)
    context["github"].update({"event_name": event, "ref": ref, "ref_name": ref.rsplit("/", 1)[-1],
                              "head_ref": "", "base_ref": "", "event": {}, "run_id": 9000})
    return context


def collision_problem(concurrency: Any, workflow: dict, event: str) -> str | None:
    """Why a cancelling pull request run of `event` could cancel a push, schedule or dispatch run, or None."""
    if not isinstance(concurrency, dict):
        return None
    try:
        pr_group = group_of(concurrency, pr_context(workflow, event, 101, 2))
        for other, ref in NON_PR_RUNS:
            if other not in triggers(workflow):
                continue
            if group_of(concurrency, non_pr_context(workflow, other, ref)) == pr_group:
                return (f"a {event} run shares group {pr_group!r} with a {other} run on {ref} and cancels it: "
                        "key the pull request group by its number")
    except (ExpressionError, KeyError, IndexError, TypeError, ValueError) as error:
        return f"cannot evaluate its group for a non-pull-request run: {error}"
    return None


def workflow_problem(workflow: dict) -> str | None:
    for event in PR_EVENTS:
        if event not in triggers(workflow):
            continue
        if not push_starts_a_run(triggers(workflow)[event]):
            continue
        reason = problem(workflow.get("concurrency"), workflow, event)
        if reason is None:
            collision = collision_problem(workflow.get("concurrency"), workflow, event)
            if collision:
                return f"{event}: {collision}"
            continue
        jobs = jobs_on(workflow, event)
        job_reasons = {job_id: problem(job.get("concurrency"), workflow, event) for job_id, job in jobs.items()}
        if jobs and all(r is None for r in job_reasons.values()):
            continue
        bad_jobs = ", ".join(f"{j}: {r}" for j, r in job_reasons.items() if r)
        return f"{event}: {reason}" + (f" (jobs: {bad_jobs})" if workflow.get("jobs") and not workflow.get("concurrency") else "")
    return None


# --- Title, body and comment events (pattern pr-edit-fans-out-ci) -------------

# Text that shows a workflow reads the description in its own expressions.
DESCRIPTION_READS = ("pull_request.body", "pull_request.title", "changes.body", "changes.title")

# Workflows that run on every title or body edit although their own text never reads it, and why.
READS_DESCRIPTION: dict[str, str] = {}


# Workflows whose edit skip lands in a pull request of its own, and why. An entry whose workflow
# already passes the edit rule fails the test, so it is removed when that pull request lands.
EDIT_SKIP_PENDING = {
    "language-boundaries.yml": "changing the language-boundaries check itself merges only with Leo's "
    "leo-approved-port label, so its edit skip is split out (branch lane/pr-edit-fanout-language-boundaries)",
}


def edit_context(workflow: dict, event: str, changes: dict) -> dict[str, Any]:
    """The contexts of an `edited` run of pull request 101 with these `changes`."""
    context = pr_context(workflow, event, 101, 1)
    context["github"]["event"]["action"] = "edited"
    context["github"]["event"]["changes"] = changes
    return context


METADATA_EDITS = {
    "title-only edit": {"title": {"from": "old title"}},
    "body-only edit": {"body": {"from": "old body"}},
}

STATUS_FUNCTION = re.compile(r"\b(always|cancelled|failure)\(\)")


class _AnyOutput(dict):
    """Every output name reads as one value."""

    def __init__(self, value: str):
        super().__init__()
        self.value = value

    def __missing__(self, key: str) -> str:
        return self.value

    def get(self, key: str, default: Any = None) -> str:
        return self.value

    def __contains__(self, key: object) -> bool:
        return True


def needs_guesses(needs: list[str]) -> list[dict[str, Any]]:
    return [{parent: {"result": result, "outputs": _AnyOutput(output)} for parent in needs}
            for result in ("success", "failure", "cancelled", "skipped") for output in ("true", "false", "")]


def started_jobs(workflow: dict, context: dict[str, Any]) -> list[str]:
    """Jobs that take a runner for this event: an `if` that holds, and needs that ran (or a status function)."""
    jobs = {job_id: job for job_id, job in (workflow.get("jobs") or {}).items() if isinstance(job, dict)}
    ran: dict[str, bool] = {}

    def runs(job_id: str, seen: frozenset[str] = frozenset()) -> bool:
        if job_id in ran:
            return ran[job_id]
        job = jobs.get(job_id) or {}
        needs = job.get("needs") or []
        needs = [needs] if isinstance(needs, str) else list(needs)
        text = str(job.get("if", ""))
        try:
            # needs.* results and outputs are unknown here: a job gated on them counts as starting when any
            # plausible value (each result, each output true, false or empty) makes its `if` hold.
            holds = any(condition(job.get("if"), {**context, "needs": guess}) for guess in needs_guesses(needs)) \
                if "needs." in text else condition(job.get("if"), context)
        except (ExpressionError, KeyError, IndexError, TypeError, ValueError):
            holds = True
        if holds and needs and not STATUS_FUNCTION.search(text) and job_id not in seen:
            holds = all(runs(parent, seen | {job_id}) for parent in needs if parent in jobs)
        ran[job_id] = holds
        return holds

    return [job_id for job_id in jobs if runs(job_id)]


def group_of(concurrency: Any, context: dict[str, Any]) -> str | None:
    if not concurrency:
        return None
    group = concurrency if isinstance(concurrency, str) else concurrency.get("group")
    return _text(resolve(group, context))


def edit_problems(workflow: dict, text: str, name: str) -> list[str]:
    """Why a title or body edit starts work in a workflow that never reads either."""
    out: list[str] = []
    reads = name in READS_DESCRIPTION or any(marker in text for marker in DESCRIPTION_READS)
    for event in PR_EVENTS:
        trigger = triggers(workflow).get(event)
        types = trigger.get("types") if isinstance(trigger, dict) else None
        types = [types] if isinstance(types, str) else list(types or [])
        if "edited" not in types or reads:
            continue
        push = pr_context(workflow, event, 101, 1)
        for kind, changes in METADATA_EDITS.items():
            edit = edit_context(workflow, event, changes)
            try:
                started = started_jobs(workflow, edit)
                if started:
                    out.append(f"{event}: a {kind} starts {', '.join(started)}, and nothing here reads the "
                               "description: skip it in each job's `if` (`edited` stays for a base change)")
                scopes = [("workflow", workflow.get("concurrency"))] + [
                    (f"job {job_id}", job.get("concurrency"))
                    for job_id, job in (workflow.get("jobs") or {}).items() if isinstance(job, dict)]
                for scope, concurrency in scopes:
                    if concurrency and group_of(concurrency, edit) == group_of(concurrency, push):
                        out.append(f"{event}: a {kind} shares the push's concurrency group in {scope}, so it "
                                   "cancels or replaces the run that judges the head: add a '-metadata' suffix")
                on_push = started_jobs(workflow, push)
                for job_id, job in (workflow.get("jobs") or {}).items():
                    # A named job that answers a push is a check someone gates on.
                    if not isinstance(job, dict) or job_id in started or job_id not in on_push or not job.get("name"):
                        continue
                    pushed = _text(resolve(job["name"], push))
                    edited = _text(resolve(job["name"], edit))
                    if pushed == edited:
                        out.append(f"{event}: job {job_id} skips a {kind} under its real name {pushed!r}; a "
                                   "skipped check reads as a pass: name the skipped run differently")
            except (ExpressionError, KeyError, IndexError, TypeError, ValueError) as error:
                out.append(f"{event}: cannot evaluate a {kind}: {error}")
    return out


def comment_context(workflow: dict) -> dict[str, Any]:
    """An ordinary pull request comment by a person: `issue_comment` `created`."""
    context = pr_context(workflow, "pull_request", 101, 1)
    context["github"]["event_name"] = "issue_comment"
    context["github"]["ref"] = "refs/heads/main"
    context["github"]["event"] = {
        "action": "created",
        "issue": {"number": 101, "pull_request": {"url": "https://api.github.com/repos/manaflow-ai/cmux/pulls/101"}},
        "comment": {"id": 9, "body": "HOLD: waiting on the base\r\n", "user": {"login": "someone", "type": "User"},
                    "author_association": "MEMBER"},
    }
    return context


def comment_problems(workflow: dict) -> list[str]:
    if "issue_comment" not in triggers(workflow):
        return []
    try:
        started = started_jobs(workflow, comment_context(workflow))
    except (ExpressionError, KeyError, IndexError, TypeError, ValueError) as error:
        return [f"issue_comment: cannot evaluate an ordinary comment: {error}"]
    if started:
        return [f"issue_comment: an ordinary comment starts {', '.join(started)}: admit only the command it "
                "serves in each job's `if` (github.event.comment.body), before a runner is taken"]
    return []


def closed_context(workflow: dict, number: int, labels: list[str]) -> dict[str, Any]:
    """The contexts of the `closed` run of pull request `number`."""
    context = pr_context(workflow, "pull_request", number, 1)
    context["github"]["event"]["action"] = "closed"
    context["github"]["event"]["pull_request"]["labels"] = [{"name": name} for name in labels]
    return context


def twin_problem(twin: dict, target: dict) -> str | None:
    """Why `twin` does not cancel `target`'s run when a pull request closes, or None."""
    twin_concurrency, target_concurrency = twin.get("concurrency"), target.get("concurrency")
    if not isinstance(twin_concurrency, dict) or not isinstance(target_concurrency, dict):
        return "the twin or its target has no workflow concurrency block"
    trigger = triggers(twin).get("pull_request")
    types = trigger.get("types") if isinstance(trigger, dict) else None
    if list(types or []) != ["closed"]:
        return f"the twin must run only on pull_request closed, not {types!r}"
    try:
        closed = _text(resolve(twin_concurrency.get("group"), closed_context(twin, 101, [])))
        kept = _text(resolve(twin_concurrency.get("group"), closed_context(twin, 101, ["no-janitor"])))
        target_group = _text(resolve(target_concurrency.get("group"), pr_context(target, "pull_request", 101, 1)))
        cancels = _truthy(resolve(twin_concurrency.get("cancel-in-progress", False), closed_context(twin, 101, [])))
    except (ExpressionError, KeyError, IndexError, TypeError, ValueError) as error:
        return f"cannot evaluate a group: {error}"
    if closed != target_group:
        return f"its closed group {closed!r} is not the target's pull request group {target_group!r}"
    if kept == target_group:
        return "a no-janitor pull request's run is cancelled too; give it a group of its own"
    if not cancels:
        return "cancel-in-progress is false"
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
    # A pull request into feat-cmux-next and a push to it both get `w-feat-cmux-next` (#47604's first fixture,
    # `number || 'deploy'`, gave w-101 and w-deploy: no shared group, so it never failed).
    shared = {"on": {"pull_request": None, "push": None},
              "concurrency": {"group": "w-${{ github.event.pull_request.base.ref || github.ref_name }}",
                              "cancel-in-progress": True}}
    if workflow_problem(shared) is None:
        failures.append("self-check: a pull request group that equals the push group must fail")
    split = {**shared, "concurrency": {"group": "w-${{ github.event.pull_request.number || github.ref }}",
                                       "cancel-in-progress": "${{ github.event_name == 'pull_request' }}"}}
    if workflow_problem(split) is not None:
        failures.append(f"self-check: a per-PR group with a ref fallback must pass: {workflow_problem(split)}")
    if workflow_problem({"on": {"pull_request": {"types": ["labeled"]}}, "concurrency": {"group": "w-${{ github.run_id }}"}}) is not None:
        failures.append("self-check: a labeled-only workflow gets no push run to cancel")
    if workflow_problem({"on": {"pull_request": {"types": ["labeled", "synchronize"]}}, "concurrency": {"group": "w-${{ github.run_id }}"}}) is None:
        failures.append("self-check: a workflow whose types include synchronize is still judged")
    # pull_request_target runs carry the base branch in github.ref.
    if problem({"group": "w-${{ github.ref }}", "cancel-in-progress": True}, on, "pull_request_target") is None:
        failures.append("self-check: a github.ref group must not count as per-PR for pull_request_target")
    # Title and body edits (pattern pr-edit-fans-out-ci).
    meta = "github.event.action == 'edited' && !github.event.changes.base"
    listens = {"pull_request_target": {"types": ["synchronize", "edited"]}}
    naive = {"on": listens, "concurrency": {"group": "w-${{ github.event.pull_request.number }}", "cancel-in-progress": True},
             "jobs": {"check": {"name": "check", "runs-on": "x"}}}
    if not edit_problems(naive, "", "w.yml"):
        failures.append("self-check: a workflow that runs on every edit and never reads the description must fail")
    guarded = {"on": listens,
               "concurrency": {"group": "w-${{ github.event.pull_request.number }}${{ " + meta + " && '-metadata' || '' }}",
                               "cancel-in-progress": True},
               "jobs": {"check": {"name": "${{ " + meta + " && 'check (ignored)' || 'check' }}",
                                  "if": "${{ !(" + meta + ") }}", "runs-on": "x"}}}
    if edit_problems(guarded, "", "w.yml"):
        failures.append(f"self-check: the metadata-edit guard must pass: {edit_problems(guarded, '', 'w.yml')}")
    same_name = {**guarded, "jobs": {"check": {"name": "check", "if": "${{ !(" + meta + ") }}", "runs-on": "x"}}}
    if not any("real name" in p for p in edit_problems(same_name, "", "w.yml")):
        failures.append("self-check: a skipped edit run under the check's own name must fail")
    same_group = {**guarded, "concurrency": naive["concurrency"]}
    if not any("concurrency group" in p for p in edit_problems(same_group, "", "w.yml")):
        failures.append("self-check: an edit run in the push's concurrency group must fail")
    if edit_problems(naive, "BODY: ${{ github.event.pull_request.body }}", "w.yml"):
        failures.append("self-check: a workflow that reads the body may run on edits")
    # Comments.
    comments = {"on": {"issue_comment": {"types": ["created"]}}}
    open_gate = {**comments, "jobs": {"rerun": {"if": "github.event.issue.pull_request != null", "runs-on": "x"}}}
    if not comment_problems(open_gate):
        failures.append("self-check: a comment workflow that starts on every PR comment must fail")
    command = {**comments, "jobs": {"run": {"if": "github.event.issue.pull_request != null && "
                                            "contains(github.event.comment.body, '@claude')", "runs-on": "x"}}}
    if comment_problems(command):
        failures.append("self-check: a comment workflow gated on its command must pass")


    target = {"name": "W", "concurrency": {"group": "${{ github.workflow }}-${{ github.ref }}"}}
    twin = {"on": {"pull_request": {"types": ["closed"]}}, "concurrency": {
        "group": "${{ contains(github.event.pull_request.labels.*.name, 'no-janitor') && 'kept' || format('W-refs/pull/{0}/merge', github.event.pull_request.number) }}",
        "cancel-in-progress": True}}
    if twin_problem(twin, target) is not None:
        failures.append(f"self-check: a matching closed twin fails: {twin_problem(twin, target)}")
    if twin_problem({**twin, "concurrency": {"group": "W-other", "cancel-in-progress": True}}, target) is None:
        failures.append("self-check: a closed twin with another group passes")
    return failures


# backend.yml's test jobs cancel per pull request at job level (its ALLOWED entry): two runs of one pull
# request share each job's group, two pull requests do not, a pull request run cancels, and a push to
# feat-cmux-next gets a group per run, so it neither cancels nor waits. migrations-development never cancels.
BACKEND_CANCEL_JOBS = ("api-workerd", "test")


def backend_test_job_problems(workflow: dict) -> list[str]:
    problems: list[str] = []
    jobs = workflow.get("jobs") or {}
    for job_id in BACKEND_CANCEL_JOBS:
        concurrency = (jobs.get(job_id) or {}).get("concurrency")
        if not isinstance(concurrency, dict):
            problems.append(f"backend.yml {job_id}: no job concurrency, so a superseded pull request run keeps it")
            continue

        def run(event: str, number: int, n: int) -> tuple[Any, Any]:
            context = pr_context(workflow, event, number, n)
            context["matrix"] = {"shard": 3}
            return (resolve(concurrency.get("group"), context),
                    resolve(concurrency.get("cancel-in-progress", False), context))

        first, second, other = run("pull_request", 7, 1), run("pull_request", 7, 2), run("pull_request", 8, 1)
        push_a, push_b = run("push", 0, 1), run("push", 0, 2)
        if first[0] != second[0] or first[0] == other[0] or not _truthy(second[1]):
            problems.append(f"backend.yml {job_id}: a newer push to the pull request must cancel it ({first}, {second}, {other})")
        if push_a[0] == push_b[0] or _truthy(push_a[1]) or push_a[0] == first[0]:
            problems.append(f"backend.yml {job_id}: a push run must get its own group and never cancel ({push_a}, {push_b})")
    migrations = (jobs.get("migrations-development") or {}).get("concurrency") or {}
    if migrations.get("cancel-in-progress", False) is not False:
        problems.append("backend.yml migrations-development: must never cancel (a migration mid-apply)")
    return problems


def main() -> int:
    failures = self_check()
    checked = 0
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        workflow = load(path)
        text = path.read_text(encoding="utf-8")
        edits = edit_problems(workflow, text, path.name)
        if path.name in EDIT_SKIP_PENDING:
            if not edits:
                failures.append(f"EDIT_SKIP_PENDING names {path.name}, which passes the edit rule now: remove it")
            edits = []
        for reason in edits + comment_problems(workflow):
            failures.append(f"{path.relative_to(ROOT)}: {reason}")
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
    if (WORKFLOWS / "backend.yml").exists():
        failures.extend(backend_test_job_problems(load(WORKFLOWS / "backend.yml")))
    for twin_name, target_name in sorted(CLOSED_TWINS.items()):
        if not (WORKFLOWS / twin_name).exists() or not (WORKFLOWS / target_name).exists():
            failures.append(f"CLOSED_TWINS names {twin_name} -> {target_name}, and one of them no longer exists")
            continue
        reason = twin_problem(load(WORKFLOWS / twin_name), load(WORKFLOWS / target_name))
        if reason:
            failures.append(f".github/workflows/{twin_name} (closes {target_name}'s runs): {reason}")
    for name, why in sorted(ALLOWED.items()):
        if not why.strip() or not (WORKFLOWS / name).exists():
            failures.append(f"ALLOWED names {name}, which no longer exists or has no reason")
    for name, why in sorted(READS_DESCRIPTION.items()):
        if not why.strip() or not (WORKFLOWS / name).exists():
            failures.append(f"READS_DESCRIPTION names {name}, which no longer exists or has no reason")
    for name, why in sorted(EDIT_SKIP_PENDING.items()):
        if not why.strip() or not (WORKFLOWS / name).exists():
            failures.append(f"EDIT_SKIP_PENDING names {name}, which no longer exists or has no reason")
    if failures:
        print("superseded pull request runs that keep running:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(f"{checked} pull request workflows cancel a superseded run ({len(ALLOWED)} allowed exceptions); "
          f"{len(CLOSED_TWINS)} closed-cancel twins match their targets")
    return 0


if __name__ == "__main__":
    sys.exit(main())
