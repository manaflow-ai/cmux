#!/usr/bin/env python3
"""Rerun each new main failure, and bisect the ones attribution could not pin.

main_regression_attribution.py names the pull requests suspected of each test
that newly fails in main's full suite, from the diff alone. That guess is
wrong for a flaky test, and gives no single answer for a tie or a failure no
diff explains. This checks it against real runs, one step per invocation,
because a dispatched focused run takes 10 to 30 minutes and a job must not sit
open for hours:

1. Flake check. The first MAX_CHECKS_PER_RUN new failures of each red run
   are run alone at that run's head with dispatch-focused-test.py, which reuses
   the app-host products the red run compiled when it can. A pass marks the
   failure flaky: the issue's row says so, and the suspect pull requests'
   comments say it did not reproduce, so their authors are not blamed.
2. Bisect. A reproduced failure with no suspect or several is bisected over
   the commits between the two full-suite runs that can change an app-host
   test (the section's data marker lists them): the test runs at the midpoint,
   the window halves, and so on until one commit is left. A range with one
   such commit needs no probe. A failure with one suspect is left at
   "reproduced". At most MAX_ACTIVE_BISECTS run at once.
3. Verdict. When one commit is left, the issue row and the pull request's
   comment say "confirmed", with the passing and failing run links; other
   suspects' comments say the bisect cleared them.

State lives in one comment on the tracking issue, as a hidden JSON marker the
next invocation resumes from. Every dispatch is recorded there, and at most
the --max-dispatches-per-day budget is spent in any 24 hours. Only comments
github-actions wrote are read, so no one else's comment can steer a dispatch.
Nothing is reverted.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import main_full_suite as suite_run  # noqa: E402
import main_regression_attribution as attribution  # noqa: E402

DISPATCH_SCRIPT = Path(__file__).resolve().parent / "dispatch-focused-test.py"
STATE_PREFIX = "<!-- main-regression-bisect-state "
VERDICT_MARKER_RE = re.compile(r"<!-- main-regression-bisect pr=(\d+) test=(\w+) -->")
BOT_LOGINS = frozenset({"github-actions", "github-actions[bot]"})
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
# What dispatch-focused-test.py accepts after cmuxTests/.
TEST_RE = re.compile(r"^[A-Za-z_]\w*/[A-Za-z_]\w*(?:\((?:[A-Za-z_]\w*:)*\))?$")
RUN_URL_RE = re.compile(r"^Run: (https://github\.com/[^\s]+/actions/runs/(\d+))\s*$", re.M)

# Bounds on what one red streak can spend.
MAX_CHECKS_PER_RUN = 5
MAX_ACTIVE_BISECTS = 2
MAX_DISPATCHES_PER_INVOCATION = 4
DEFAULT_MAX_DISPATCHES_PER_DAY = 24
# A probe that errored (a runner or infrastructure failure, not the test) is
# retried once before the item gives up.
MAX_PROBE_ERRORS = 2
# An item still open this long after it was queued is dropped.
ITEM_TTL = timedelta(days=3)
# Bounds on the state comment, which GitHub caps at 65,536 characters: a
# red run arriving while this many checks are open is not checked, and only
# the newest finished items are kept for the status table.
MAX_OPEN_ITEMS = 10
MAX_FINISHED_ITEMS = 20
KEEP_SEEN_RUNS = 200
DISPATCH_TIMEOUT_SECONDS = 8 * 60
# The step that runs the selected tests, in app-host-test-rerun.yml and
# test-e2e.yml. A failure anywhere else is not the test's verdict.
TEST_STEP = "Run selected tests"

OPEN_STATES = frozenset({"queued", "flake-check", "bisect-wait", "bisecting"})
UPDATE_SEPARATOR = " · "
PR_UPDATE = " **Update:** "


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def stamp(moment: datetime) -> str:
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_stamp(text: str) -> datetime:
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def short(sha: str) -> str:
    return sha[:10]


def test_digest(test: str) -> str:
    return hashlib.sha256(test.encode()).hexdigest()[:16]


# ---- markers ------------------------------------------------------------------------------


def hidden_json(body: str, prefix: str) -> list[dict]:
    """Every JSON object a `<prefix>{...} -->` marker in the body carries."""
    found = []
    for line in (body or "").splitlines():
        line = line.strip()
        if line.startswith(prefix) and line.endswith("-->"):
            try:
                value = json.loads(line[len(prefix):-3].strip())
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                found.append(value)
    return found


def valid_data(data: Mapping[str, object]) -> bool:
    """A data marker whose shas and test names are safe to dispatch."""
    shas = [data.get("head"), data.get("prev"), *(data.get("commits") or [])]
    tests = [entry.get("test") for entry in data.get("tests") or [] if isinstance(entry, dict)]
    return (
        isinstance(data.get("run_id"), int)
        and all(isinstance(sha, str) and SHA_RE.match(sha) for sha in shas)
        and all(isinstance(test, str) and TEST_RE.match(test) for test in tests)
    )


def empty_state() -> dict:
    return {"v": 1, "items": [], "seen": [], "dispatches": []}


def render_state(state: Mapping[str, object], budget: int) -> str:
    lines = [
        f"{STATE_PREFIX}{json.dumps(state, separators=(',', ':'))} -->",
        "### Reruns and bisects of new failures",
        "",
        "Each new failure is run again alone at the red run's head; one that does not reproduce is "
        "marked flaky. A reproduced failure with no single suspect is bisected over the commits in its "
        "range. This comment is rewritten as runs finish.",
        "",
    ]
    items = list(state.get("items") or [])
    if items:
        lines += ["Test | Red run | State", "--- | --- | ---"]
        for item in items:
            lines.append(f"`{item['test']}` | [{item['run']}]({item.get('run_url', '')}) | {item.get('note') or item['state']}")
    else:
        lines.append("Nothing checked yet.")
    lines += ["", f"Dispatches in the last 24 hours: {len(state.get('dispatches') or [])} of {budget}."]
    return "\n".join(lines)


# ---- edits to the issue section and pull request comments ----------------------------------


def annotate_row(body: str, test: str, note: str) -> str:
    """The "New since" table row for `test` with its suspect cell's update replaced by `note`."""
    lines = body.split("\n")
    for index, line in enumerate(lines):
        if not line.startswith(f"`{test}` | "):
            continue
        cells = line.split(" | ", 2)
        if len(cells) != 3:
            continue
        cells[1] = cells[1].split(UPDATE_SEPARATOR, 1)[0] + UPDATE_SEPARATOR + note
        lines[index] = " | ".join(cells)
    return "\n".join(lines)


def annotate_pr_comment(body: str, test: str, note: str, header: str = "") -> str:
    """A suspect comment with `test`'s line updated, and `header` placed under the marker."""
    lines = body.split("\n")
    for index, line in enumerate(lines):
        if line.startswith(f"- `{test}` "):
            lines[index] = line.split(PR_UPDATE, 1)[0] + PR_UPDATE + note
    if header:
        top = [line for line in lines[1:] if line.startswith("**Update:** ")]
        lines = [lines[0]] + [line for line in lines[1:] if line not in top]
        lines.insert(1, f"**Update:** {header}")
    return "\n".join(lines)


def comment_tests(body: str) -> list[str]:
    return re.findall(r"^- `([^`]+)` ", body, re.M)


def suspect_comment_range(data: Mapping[str, object]) -> str:
    return f"{short(str(data['prev']))}..{short(str(data['head']))}"


def is_suspect_comment(body: str, pr: int, range_: str) -> bool:
    return any(
        int(number) == pr and seen_range == range_
        for number, _, seen_range in attribution.MARKER_RE.findall(body or "")
    )


# ---- the state machine ---------------------------------------------------------------------


def new_items(state: dict, runs: Mapping[int, Mapping[str, object]], now: datetime) -> None:
    """Queue a flake check for the first new failures of each red run not seen before."""
    seen = set(state["seen"])
    for run_id, data in sorted(runs.items()):
        if run_id in seen:
            continue
        state["seen"].append(run_id)
        room = MAX_OPEN_ITEMS - sum(1 for item in state["items"] if item["state"] in OPEN_STATES)
        for entry in list(data.get("tests") or [])[:max(0, min(room, MAX_CHECKS_PER_RUN))]:
            state["items"].append({
                "run": run_id,
                "run_url": data.get("run_url"),
                "test": entry["test"],
                "suspects": list(entry.get("suspects") or []),
                "state": "queued",
                "created": stamp(now),
                "probes": {},
                "errors": 0,
            })
    state["seen"] = state["seen"][-KEEP_SEEN_RUNS:]


def points(data: Mapping[str, object]) -> list[str]:
    """The known-good previous head, then each commit that can change the outcome, oldest first."""
    return [str(data["prev"]), *[str(sha) for sha in data.get("commits") or []]]


@dataclass
class Event:
    """Something the issue and pull requests should now say about one item."""

    kind: str  # flaky, reproduced, bisecting, confirmed, unresolved, error
    item: dict


def conclude(item: dict, data: Mapping[str, object]) -> Event:
    """The verdict once the window is one commit wide."""
    window = points(data)
    culprit = window[item["hi"]]
    good = window[item["lo"]]
    head_probe = item["probes"].get(str(data["head"])) or {}
    culprit_probe = item["probes"].get(culprit) or head_probe
    item["culprit"] = {
        "sha": culprit,
        "pr": (data.get("prs") or {}).get(culprit),
        "pass_sha": good,
        "pass_url": (item["probes"].get(good) or {}).get("url") or data.get("prev_run_url"),
        "fail_url": culprit_probe.get("url"),
    }
    item["state"] = "confirmed"
    pr = item["culprit"]["pr"]
    who = f"#{pr}" if pr else f"direct commit `{short(culprit)}`"
    item["note"] = (
        f"confirmed: {who} (passes at `{short(good)}` [run]({item['culprit']['pass_url']}), "
        f"fails at `{short(culprit)}` [run]({item['culprit']['fail_url']}))"
    )
    return Event("confirmed", item)


def after_reproduced(item: dict, data: Mapping[str, object]) -> Event:
    """Decide what a reproduced failure needs next."""
    window = points(data)
    head_url = item["probes"][str(data["head"])]["url"]
    if len(window) < 2:
        item["state"] = "unresolved"
        item["note"] = (
            f"reproduced ([rerun]({head_url})), but no commit in the range changes the app or its tests"
        )
        return Event("unresolved", item)
    item["lo"], item["hi"] = 0, len(window) - 1
    if len(window) == 2:
        return conclude(item, data)
    if len(item["suspects"]) == 1:
        item["state"] = "reproduced"
        item["note"] = f"reproduced ([rerun]({head_url}))"
        return Event("reproduced", item)
    item["state"] = "bisect-wait"
    item["note"] = f"reproduced ([rerun]({head_url})); waiting to bisect {len(window) - 1} commits"
    return Event("reproduced", item)


def record_result(item: dict, data: Mapping[str, object], sha: str, result: str) -> Event | None:
    """Apply one finished probe to the item."""
    probe = item["probes"][sha]
    probe["result"] = result
    item.pop("pending", None)
    if result == "error":
        item["errors"] = item.get("errors", 0) + 1
        if item["errors"] >= MAX_PROBE_ERRORS:
            item["state"] = "error"
            item["note"] = f"could not be rerun ([last run]({probe['url']}))"
            return Event("error", item)
        return None
    if item["state"] == "flake-check":
        if result == "pass":
            item["state"] = "flaky"
            item["note"] = f"did not reproduce on a rerun at the same commit ([run]({probe['url']})); likely flaky"
            return Event("flaky", item)
        return after_reproduced(item, data)
    window = points(data)
    mid = window.index(sha)
    if result == "pass":
        item["lo"] = mid
    else:
        item["hi"] = mid
    if item["hi"] - item["lo"] <= 1:
        return conclude(item, data)
    item["note"] = f"bisecting: {item['hi'] - item['lo']} commits left"
    return None


def next_probe(item: dict, data: Mapping[str, object]) -> str | None:
    """The commit this item needs a run at now, or None."""
    if item.get("pending"):
        return None
    if item["state"] in ("queued", "flake-check"):
        return str(data["head"])
    if item["state"] == "bisecting":
        return points(data)[(item["lo"] + item["hi"]) // 2]
    return None


class Budget:
    """Dispatches left in the rolling day and in this invocation."""

    def __init__(self, state: dict, per_day: int, now: datetime):
        cutoff = now - timedelta(days=1)
        state["dispatches"] = [text for text in state.get("dispatches") or [] if parse_stamp(text) > cutoff]
        self.state, self.per_day, self.now = state, per_day, now
        self.this_invocation = 0

    def available(self) -> bool:
        return (
            len(self.state["dispatches"]) < self.per_day
            and self.this_invocation < MAX_DISPATCHES_PER_INVOCATION
        )

    def spend(self) -> None:
        self.state["dispatches"].append(stamp(self.now))
        self.this_invocation += 1


def advance(
    state: dict,
    runs: Mapping[int, Mapping[str, object]],
    *,
    poll: Callable[[int], str],
    dispatch: Callable[[str, str, bool], tuple[int, str] | None],
    per_day: int,
    now: datetime,
) -> list[Event]:
    """One step for every open item: collect finished probes, start bisects, dispatch the next runs.

    `poll(run_id)` answers pending, pass, fail or error. `dispatch(test, sha,
    retry)` returns (run id, url), or None when the dispatch failed.
    """
    events: list[Event] = []
    new_items(state, runs, now)
    budget = Budget(state, per_day, now)
    for item in state["items"]:
        if item["state"] not in OPEN_STATES:
            continue
        data = runs.get(item["run"])
        if data is None or now - parse_stamp(item["created"]) > ITEM_TTL:
            item["state"] = "expired"
            item["note"] = "dropped: its red run's report is gone or the check ran too long"
            continue
        pending = item.get("pending")
        if pending:
            result = poll(int(item["probes"][pending]["run_id"]))
            if result != "pending":
                event = record_result(item, data, pending, result)
                if event:
                    events.append(event)
    active = sum(1 for item in state["items"] if item["state"] == "bisecting")
    for item in state["items"]:
        if item["state"] == "bisect-wait" and active < MAX_ACTIVE_BISECTS:
            item["state"] = "bisecting"
            item["note"] = f"bisecting: {item['hi'] - item['lo']} commits left"
            active += 1
            events.append(Event("bisecting", item))
    for item in state["items"]:
        if item["state"] not in OPEN_STATES or item["run"] not in runs:
            continue
        sha = next_probe(item, runs[item["run"]])
        if sha is None or not budget.available():
            continue
        budget.spend()
        started = dispatch(item["test"], sha, sha in item["probes"])
        if started is None:
            item["errors"] = item.get("errors", 0) + 1
            if item["errors"] >= MAX_PROBE_ERRORS:
                item["state"] = "error"
                item["note"] = "could not be dispatched; see the bisect job's log"
                events.append(Event("error", item))
            continue
        run_id, url = started
        if item["state"] == "queued":
            item["state"] = "flake-check"
            item["note"] = f"rerunning at the red run's head ([run]({url}))"
        item["probes"][sha] = {"run_id": run_id, "url": url, "result": "pending"}
        item["pending"] = sha
    finished = [item for item in state["items"] if item["state"] not in OPEN_STATES]
    keep = {id(item) for item in finished[-MAX_FINISHED_ITEMS:]}
    state["items"] = [item for item in state["items"] if item["state"] in OPEN_STATES or id(item) in keep]
    return events


def classify(run: Mapping[str, object], failed_steps: Callable[[], list[str]]) -> str:
    """pending, pass, fail (the test step failed) or error (anything else went wrong)."""
    if run.get("status") != "completed":
        return "pending"
    if run.get("conclusion") == "success":
        return "pass"
    if run.get("conclusion") == "failure" and TEST_STEP in failed_steps():
        return "fail"
    return "error"


# ---- what each event changes ---------------------------------------------------------------


@dataclass
class Comment:
    """A comment github-actions wrote, or the issue body (id None, kind issue)."""

    id: int | None
    body: str
    kind: str = "comment"


def section_edits(
    events: Iterable[Event], runs: Mapping[int, Mapping[str, object]], nodes: list[Comment],
) -> dict[int | None, str]:
    """New bodies for the issue comments whose "New since" rows changed, by comment id."""
    edits: dict[int | None, str] = {}
    for event in events:
        data = runs.get(event.item["run"])
        if not data:
            continue
        for node in nodes:
            body = edits.get(node.id, node.body)
            if not any(found.get("run_id") == event.item["run"] for found in hidden_json(body, attribution.DATA_PREFIX)):
                continue
            changed = annotate_row(body, event.item["test"], event.item["note"])
            if changed != body:
                edits[node.id] = changed
    return edits


def pr_updates(
    event: Event, data: Mapping[str, object], comments: Callable[[int], list[Comment]],
) -> tuple[dict[int, str], list[tuple[int, str]]]:
    """(comment id -> new body, (pull request, new comment) to post) for one event."""
    item = event.item
    test = item["test"]
    range_ = suspect_comment_range(data)
    edits: dict[int, str] = {}
    posts: list[tuple[int, str]] = []

    def edit_suspects(numbers: Iterable[int], note: str, header_when_all: str = "") -> int:
        """Update `test`'s line in each suspect comment that lists it; returns how many list it."""
        listed = 0
        for number in numbers:
            for comment in comments(number):
                if comment.id is None or not is_suspect_comment(comment.body, number, range_):
                    continue
                if test not in comment_tests(comment.body):
                    continue
                listed += 1
                body = annotate_pr_comment(comment.body, test, note)
                if header_when_all and all(
                    note in line for line in body.split("\n") if line.startswith("- `")
                ):
                    body = annotate_pr_comment(body, test, note, header=header_when_all)
                if body != comment.body:
                    edits[comment.id] = body
        return listed

    if event.kind == "flaky":
        edit_suspects(
            item["suspects"],
            f"did not reproduce on a rerun at the same commit ([run]({item['probes'][str(data['head'])]['url']})); "
            "likely flaky, not this pull request",
            header_when_all="none of these failures reproduced on a rerun, so they look flaky. "
            "Nothing to do here unless you know otherwise.",
        )
    elif event.kind == "reproduced" and item["state"] == "reproduced":
        edit_suspects(
            item["suspects"],
            f"reproduced on a rerun at the same commit ([run]({item['probes'][str(data['head'])]['url']}))",
        )
    elif event.kind == "confirmed":
        culprit = item["culprit"]
        pr = culprit.get("pr")
        links = (
            f"passes at `{short(culprit['pass_sha'])}` ([run]({culprit['pass_url']})), "
            f"fails at `{short(culprit['sha'])}` ([run]({culprit['fail_url']}))"
        )
        if pr:
            if not edit_suspects([pr], f"**confirmed** by bisect: {links}"):
                marker = f"<!-- main-regression-bisect pr={pr} test={test_digest(test)} -->"
                if not any(marker in comment.body for comment in comments(pr)):
                    posts.append((pr, "\n".join([
                        marker,
                        f"`{test}` newly fails in [main's full suite]({data.get('run_url')}), and a bisect over "
                        f"the commits since [the previous full-suite run]({data.get('prev_run_url')}) "
                        f"points at this pull request: the test {links}.",
                        "",
                        "Please fix forward or revert. If this looks wrong, say so here; a flaky test "
                        "can mislead a bisect.",
                    ])))
        cleared = [number for number in item["suspects"] if number != pr]
        who = f"#{pr}" if pr else f"commit `{short(culprit['sha'])}`"
        edit_suspects(cleared, f"a bisect points at {who} instead ({links}); this pull request is cleared")
    return edits, posts


# ---- I/O ---------------------------------------------------------------------------------


def gh(args: list[str]) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def graphql(query: str, **variables: object) -> dict:
    args = ["api", "graphql", "-f", f"query={query}"]
    for key, value in variables.items():
        if value is None:
            continue
        args += ["-F" if isinstance(value, int) else "-f", f"{key}={value}"]
    return json.loads(gh(args))["data"]


def is_bot(node: Mapping[str, object]) -> bool:
    return str(((node.get("author") or {}) or {}).get("login") or "") in BOT_LOGINS


def issue_comments(repo: str, number: int) -> tuple[Comment | None, list[Comment]]:
    """(the issue body if github-actions wrote it, its github-actions comments), oldest first."""
    owner, name = repo.split("/", 1)
    query = (
        "query($owner: String!, $name: String!, $number: Int!, $after: String) { repository(owner: $owner, name: $name) "
        "{ issue(number: $number) { body author { login } comments(first: 100, after: $after) "
        "{ pageInfo { hasNextPage endCursor } nodes { databaseId body author { login } } } } } }"
    )
    after = None
    body: Comment | None = None
    found: list[Comment] = []
    while True:
        issue = graphql(query, owner=owner, name=name, number=number, after=after)["repository"]["issue"]
        if body is None and is_bot(issue):
            body = Comment(None, str(issue.get("body") or ""), "issue")
        page = issue["comments"]
        found += [Comment(int(node["databaseId"]), str(node.get("body") or "")) for node in page["nodes"] if is_bot(node)]
        if not page["pageInfo"]["hasNextPage"]:
            return body, found
        after = page["pageInfo"]["endCursor"]


def pr_comments(repo: str, number: int) -> list[Comment]:
    owner, name = repo.split("/", 1)
    query = (
        "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) "
        "{ pullRequest(number: $number) { comments(last: 100) { nodes { databaseId body author { login } } } } } }"
    )
    data = graphql(query, owner=owner, name=name, number=number)
    nodes = ((data["repository"].get("pullRequest") or {}).get("comments") or {}).get("nodes") or []
    return [Comment(int(node["databaseId"]), str(node.get("body") or "")) for node in nodes if is_bot(node)]


def poll_run(repo: str, run_id: int) -> str:
    try:
        run = json.loads(gh(["api", f"repos/{repo}/actions/runs/{run_id}"]))

        def failed_steps() -> list[str]:
            jobs = json.loads(gh(["api", f"repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100"]))
            return [
                str(step.get("name"))
                for job in jobs.get("jobs") or []
                for step in job.get("steps") or []
                if step.get("conclusion") == "failure"
            ]

        return classify(run, failed_steps)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"::warning::Could not read run {run_id}: {error}", file=sys.stderr)
        return "pending"


def dispatch_run(test: str, sha: str, retry: bool) -> tuple[int, str] | None:
    command = [sys.executable, str(DISPATCH_SCRIPT), f"cmuxTests/{test}", "--ref", sha]
    if retry:
        # The dispatcher refuses a selector that already failed at a commit;
        # the earlier run here failed outside the test step.
        command.append("--force")
    print(f"Dispatching {test} at {sha}", flush=True)
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=DISPATCH_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        print(f"::warning::Dispatching {test} at {sha} timed out", file=sys.stderr)
        return None
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    match = RUN_URL_RE.search(result.stdout)
    if result.returncode != 0 or not match:
        print(f"::warning::Could not dispatch {test} at {sha} (exit {result.returncode})", file=sys.stderr)
        return None
    return int(match.group(2)), match.group(1)


def command_advance(args: argparse.Namespace) -> int:
    issue = suite_run.open_issue(args.repo)
    if issue is None:
        print("Main's full suite is not red; nothing to check.")
        return 0
    number = int(issue["number"])
    body, comments = issue_comments(args.repo, number)
    nodes = ([body] if body else []) + comments
    runs: dict[int, dict] = {}
    for node in nodes:
        for data in hidden_json(node.body, attribution.DATA_PREFIX):
            if valid_data(data):
                runs[int(data["run_id"])] = data
    state_node = next((node for node in comments if hidden_json(node.body, STATE_PREFIX)), None)
    state = hidden_json(state_node.body, STATE_PREFIX)[0] if state_node else empty_state()
    for key, value in empty_state().items():
        state.setdefault(key, value)

    events = advance(
        state, runs,
        poll=lambda run_id: poll_run(args.repo, run_id),
        dispatch=dispatch_run if not args.dry_run else lambda test, sha, retry: None,
        per_day=args.max_dispatches_per_day,
        now=now_utc(),
    )
    for event in events:
        print(f"{event.item['test']} ({event.item['run']}): {event.kind}: {event.item.get('note', '')}")

    state_body = render_state(state, args.max_dispatches_per_day)
    cached: dict[int, list[Comment]] = {}

    def comments_of(pr: int) -> list[Comment]:
        if pr not in cached:
            cached[pr] = pr_comments(args.repo, pr)
        return cached[pr]

    # The state goes first: it records the runs just dispatched, and losing it
    # would dispatch them again. The edits after it are idempotent.
    writes: list[list[str]] = []
    if state_node:
        if state_node.body != state_body:
            writes.append(["api", "-X", "PATCH", f"repos/{args.repo}/issues/comments/{state_node.id}", "-f", f"body={state_body}"])
    elif state["items"]:
        writes.append(["api", f"repos/{args.repo}/issues/{number}/comments", "-f", f"body={state_body}"])
    for comment_id, text in section_edits(events, runs, nodes).items():
        if comment_id is None:
            writes.append(["api", "-X", "PATCH", f"repos/{args.repo}/issues/{number}", "-f", f"body={text}"])
        else:
            writes.append(["api", "-X", "PATCH", f"repos/{args.repo}/issues/comments/{comment_id}", "-f", f"body={text}"])
    for event in events:
        data = runs.get(event.item["run"])
        if not data:
            continue
        edits, posts = pr_updates(event, data, comments_of)
        for comment_id, text in edits.items():
            writes.append(["api", "-X", "PATCH", f"repos/{args.repo}/issues/comments/{comment_id}", "-f", f"body={text}"])
        for pr, text in posts:
            writes.append(["api", f"repos/{args.repo}/issues/{pr}/comments", "-f", f"body={text}"])

    if args.dry_run:
        for write in writes:
            print("--- would run gh " + " ".join(write[:4]))
        return 0
    failed = False
    for write in writes:
        try:
            gh(write)
        except subprocess.CalledProcessError as error:
            failed = True
            print(f"::warning::gh {' '.join(write[:4])} failed: {(error.stderr or '').strip()}", file=sys.stderr)
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    commands = parser.add_subparsers(dest="command", required=True)
    step = commands.add_parser("advance", help="one step of every open flake check and bisect")
    step.add_argument(
        "--max-dispatches-per-day", type=int, default=DEFAULT_MAX_DISPATCHES_PER_DAY,
        help="focused runs dispatched in any 24 hours; 0 stops new dispatches",
    )
    step.add_argument("--dry-run", action="store_true", help="dispatch and write nothing")
    step.set_defaults(handler=command_advance)
    args = parser.parse_args(argv)
    if not args.repo:
        parser.error("--repo or GITHUB_REPOSITORY is required")
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
