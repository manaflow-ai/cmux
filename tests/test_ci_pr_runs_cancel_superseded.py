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


# --- Title, body and comment events (pattern pr-edit-fans-out-ci) -------------

# Text that shows a workflow reads the description in its own expressions.
DESCRIPTION_READS = ("pull_request.body", "pull_request.title", "changes.body", "changes.title")

# Workflows that run on every title or body edit although their own text never reads it, and why.
READS_DESCRIPTION = {
    "risk-tier.yml": "scripts/ci/risk_tier.py reads the body's author footer and `Takes back #N` lines over the API",
    "cla-policy-guard.yml": "`CLA policy guard` is required on main: it publishes a verdict on every edit (#13871); "
    "pull_request_target into main only, so it runs main's copy",
}


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
            # needs.* outputs are unknown here; a job gated on them counts as starting.
            holds = "needs." in text or condition(job.get("if"), context)
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


# --- A cancelled run that cannot end (pattern cancelled-run-holds-group) -------

# `always()` starts a job even when its run is cancelled. In a workflow whose newer push cancels the older run, that
# job then waits for a runner of its own, the cancelled run stays in flight holding the concurrency group, and the
# newer head's run waits behind it as `pending`. cmux#47223, 2026-11-19: the 10:36Z head's `tab switch (frames,
# under load)`, `ios-e2e-status`, `rust workspaces` and `web-validation` jobs were created by the 11:06Z push's cancel
# and sat queued on a Blacksmith label that started nothing; the 11:06Z head's runs of those four workflows were still
# `pending` an hour later. `!cancelled()` runs the job on every needs result (success, failure, skip) but not on a
# cancel, and nobody reads a superseded run's verdict.
ALWAYS = re.compile(r"\balways\(\)")
NOT_CANCELLED = re.compile(r"!\s*cancelled\(\)")


def keepalive_problems(workflow: dict) -> list[str]:
    """Jobs a superseded pull request run's cancel starts: `always()` with no `!cancelled()`."""
    out: list[str] = []
    for event in PR_EVENTS:
        trigger = triggers(workflow).get(event, False)
        if trigger is False or not push_starts_a_run(trigger):
            continue
        concurrency = workflow.get("concurrency")
        if not isinstance(concurrency, dict):
            continue
        try:
            cancels = _truthy(resolve(concurrency.get("cancel-in-progress", False), pr_context(workflow, event, 101, 2)))
        except (ExpressionError, KeyError, IndexError, TypeError, ValueError):
            cancels = True
        if not cancels:
            continue
        for job_id, job in (workflow.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            text = " ".join(str(job.get("if", "")).split())
            if not ALWAYS.search(text) or NOT_CANCELLED.search(text):
                continue
            # Cancelled after its needs passed, with outputs unknown: does the job start on this event?
            needs = job.get("needs") or []
            needs = [needs] if isinstance(needs, str) else list(needs)
            context = pr_context(workflow, event, 101, 1)
            context["needs"] = {name: {"result": "success", "outputs": {}} for name in needs}
            try:
                starts = condition(job.get("if"), context)
            except (ExpressionError, KeyError, IndexError, TypeError, ValueError, AttributeError):
                starts = True
            if starts:
                out.append(f"{event}: job {job_id} runs on `always()`, so a superseded run's cancel starts it and the "
                           "cancelled run holds the concurrency group until a runner takes it: use `!cancelled()`")
        return out
    return out


# --- Release runs are never cancelled by a newer one --------------------------

# A nightly, DEV, release or promote run that a newer run cancels stops halfway through a publication: a tag with no
# release, a feed with no build. Every workflow that makes one is named for it (RELEASE_NAME); each of its non pull
# request runs is evaluated twice, two pushes to one ref or two dispatches, schedules or upstream completions, and
# the second run may share the first one's group only with `cancel-in-progress` false. So may cmux-next.yml's DEV
# dispatch (inputs.dev_daily) and a push to a release branch (RELEASE_BRANCHES) of any workflow.
RELEASE_NAME = re.compile(r"nightly|release|promot|stable|dev-daily|appcast|notari|publish|deliver|canary|rollback|train")
RELEASE_BRANCHES = ("nightly-next", "rc/", "stable-next", "release/")
RELEASE_EVENTS = ("schedule", "workflow_dispatch", "workflow_run", "repository_dispatch")

# Release-named workflows whose cancelled run publishes nothing, and why.
RELEASE_CANCEL_ALLOWED = {
    "release-rails.yml": "tests the release rails on fakes; it deploys and publishes nothing",
    "cmux-browser-host-release.yml": "a feat-cmux-next push only builds and packages; its tag push publishes, and "
    "keeps cancel-in-progress false (github.ref_type == 'tag')",
}


def release_context(workflow: dict, event: str, ref: str, run: int, inputs: dict[str, Any] | None = None) -> dict:
    context = pr_context(workflow, "pull_request", 101, run)
    context["github"].update(
        event_name=event, ref=ref, ref_name=ref.split("/", 2)[-1],
        ref_type="tag" if ref.startswith("refs/tags/") else "branch",
        head_ref="", base_ref="", sha=f"{run:040d}", run_id=5000 + run, run_number=run)
    context["github"]["event"] = {}
    if event == "workflow_run":
        context["github"]["event"] = {"workflow_run": {
            "id": run, "run_attempt": 1, "event": "push", "conclusion": "success", "head_branch": "main",
            "head_sha": f"{run:040d}", "path": ".github/workflows/upstream.yml", "pull_requests": [],
            "head_repository": {"full_name": "manaflow-ai/cmux"}}}
    context["inputs"] = dict(inputs or {})
    return context


def _concrete(pattern: str) -> str:
    return pattern.replace("**", "x").replace("*", "x")


def release_runs(workflow: dict, name: str) -> list[tuple[str, dict, dict]]:
    """(what, first run, second run) for each release run kind of this workflow."""
    named = bool(RELEASE_NAME.search(name))
    out: list[tuple[str, dict, dict]] = []
    for event, spec in triggers(workflow).items():
        spec = spec if isinstance(spec, dict) else {}
        if event == "push":
            branches = [str(b) for b in spec.get("branches") or []]
            tags = [str(t) for t in spec.get("tags") or []]
            refs = [f"refs/tags/{_concrete(t).replace('x', '1')}" for t in tags] if named else []
            for branch in branches or (["main"] if named and not tags else []):
                if named or _concrete(branch).startswith(RELEASE_BRANCHES):
                    refs.append(f"refs/heads/{_concrete(branch)}")
            if not branches and not tags and not named:
                refs.append("refs/heads/nightly-next")  # every branch, release branches included
            for ref in refs:
                out.append((f"push to {ref}", release_context(workflow, "push", ref, 1),
                            release_context(workflow, "push", ref, 2)))
        elif event in RELEASE_EVENTS and named:
            inputs = {}
            if event == "workflow_dispatch":
                inputs = {key: (value or {}).get("default") for key, value in (spec.get("inputs") or {}).items()}
            out.append((event, release_context(workflow, event, "refs/heads/main", 1, inputs),
                        release_context(workflow, event, "refs/heads/main", 2, inputs)))
    if name == "cmux-next.yml":
        dev = {"dev_daily": True, "same_tree_sha": ""}
        ref = "refs/heads/feat-cmux-next"
        out.append(("DEV dispatch (dev_daily)", release_context(workflow, "workflow_dispatch", ref, 1, dev),
                    release_context(workflow, "workflow_dispatch", ref, 2, dev)))
    return out


def release_problems(workflow: dict, name: str) -> list[str]:
    """Why a newer run cancels one of this workflow's nightly, DEV, release or promote runs."""
    out: list[str] = []
    for what, first, second in release_runs(workflow, name):
        scopes = [("workflow", workflow.get("concurrency"))]
        for job_id, job in (workflow.get("jobs") or {}).items():
            if not isinstance(job, dict) or not isinstance(job.get("concurrency"), dict):
                continue
            try:
                runs = condition(job.get("if"), second)
            except (ExpressionError, KeyError, IndexError, TypeError, ValueError, AttributeError):
                runs = True
            if runs:
                scopes.append((f"job {job_id}", job["concurrency"]))
        for scope, concurrency in scopes:
            if not isinstance(concurrency, dict):
                continue  # none, or a bare group: a newer run waits and never cancels a running one
            try:
                groups = (_text(resolve(concurrency.get("group"), first)), _text(resolve(concurrency.get("group"), second)))
                cancels = _truthy(resolve(concurrency.get("cancel-in-progress", False), second))
            except (ExpressionError, KeyError, IndexError, TypeError, ValueError) as error:
                out.append(f"{what}: {scope}: cannot evaluate its concurrency: {error}")
                continue
            if groups[0] == groups[1] and cancels:
                out.append(f"{what}: {scope}: a newer run cancels this one (group {groups[0]!r} with "
                           "cancel-in-progress true): a nightly, DEV, release or promote run must finish")
    return out


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
    # A cancelled run's always() job (pattern cancelled-run-holds-group).
    cancelling = {"on": {"pull_request": None}, "concurrency": {"group": "w-${{ github.ref }}", "cancel-in-progress": True}}
    if not keepalive_problems({**cancelling, "jobs": {"verdict": {"needs": ["a"], "if": "always()", "runs-on": "x"}}}):
        failures.append("self-check: an always() verdict in a cancelling workflow must fail")
    if not keepalive_problems({**cancelling, "jobs": {"r": {"needs": ["plan"], "if": "always() && needs.plan.result == 'success'"}}}):
        failures.append("self-check: always() && a needs result must fail (the needs succeeded before the cancel)")
    for ok in ("${{ !cancelled() }}", "${{ always() && !cancelled() }}", "success()"):
        if keepalive_problems({**cancelling, "jobs": {"verdict": {"if": ok, "runs-on": "x"}}}):
            failures.append(f"self-check: {ok!r} must pass")
    serial = {**cancelling, "concurrency": {"group": "w-${{ github.ref }}", "cancel-in-progress": False}}
    if keepalive_problems({**serial, "jobs": {"verdict": {"if": "always()", "runs-on": "x"}}}):
        failures.append("self-check: a workflow that never cancels a pull request run may use always()")
    # Release runs.
    nightly = {"on": {"push": {"branches": ["nightly-next"]}, "workflow_dispatch": None}}
    if not release_problems({**nightly, "concurrency": {"group": "n-${{ github.ref }}", "cancel-in-progress": True}},
                            "nightly-x.yml"):
        failures.append("self-check: a nightly whose newer push cancels the older one must fail")
    if not release_problems({"on": {"push": {"branches": ["rc/**"]}},
                             "concurrency": {"group": "w-${{ github.ref }}", "cancel-in-progress": True}}, "w.yml"):
        failures.append("self-check: any workflow cancelling a release-branch push must fail")
    for ok in ({"group": "n-${{ github.ref }}", "cancel-in-progress": False},
               {"group": "n-${{ github.run_id }}", "cancel-in-progress": True},
               {"group": "n-${{ github.ref }}", "cancel-in-progress": "${{ github.event_name == 'pull_request' }}"}):
        if release_problems({**nightly, "concurrency": ok}, "nightly-x.yml"):
            failures.append(f"self-check: a nightly with {ok} must pass")
    dev = {"on": {"workflow_dispatch": {"inputs": {"dev_daily": {"type": "boolean", "default": False}}}},
           "concurrency": {"group": "${{ inputs.dev_daily && format('d-{0}', github.run_id) || 'd' }}",
                           "cancel-in-progress": True}}
    if release_problems(dev, "cmux-next.yml"):
        failures.append("self-check: a DEV dispatch with a group of its own must pass")
    if not release_problems({**dev, "concurrency": {"group": "d", "cancel-in-progress": True}}, "cmux-next.yml"):
        failures.append("self-check: a DEV dispatch a newer dispatch cancels must fail")


    target = {"name": "W", "concurrency": {"group": "${{ github.workflow }}-${{ github.ref }}"}}
    twin = {"on": {"pull_request": {"types": ["closed"]}}, "concurrency": {
        "group": "${{ contains(github.event.pull_request.labels.*.name, 'no-janitor') && 'kept' || format('W-refs/pull/{0}/merge', github.event.pull_request.number) }}",
        "cancel-in-progress": True}}
    if twin_problem(twin, target) is not None:
        failures.append(f"self-check: a matching closed twin fails: {twin_problem(twin, target)}")
    if twin_problem({**twin, "concurrency": {"group": "W-other", "cancel-in-progress": True}}, target) is None:
        failures.append("self-check: a closed twin with another group passes")
    return failures


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
        for reason in edits + comment_problems(workflow) + keepalive_problems(workflow):
            failures.append(f"{path.relative_to(ROOT)}: {reason}")
        releases = release_problems(workflow, path.name)
        if path.name in RELEASE_CANCEL_ALLOWED:
            if not releases:
                failures.append(f"RELEASE_CANCEL_ALLOWED names {path.name}, whose release runs are never cancelled "
                                "now: remove it")
            releases = []
        for reason in releases:
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
    for name, why in sorted(RELEASE_CANCEL_ALLOWED.items()):
        if not why.strip() or not (WORKFLOWS / name).exists():
            failures.append(f"RELEASE_CANCEL_ALLOWED names {name}, which no longer exists or has no reason")
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
