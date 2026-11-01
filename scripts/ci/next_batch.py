#!/usr/bin/env python3
"""Implicit merge queue for feat-cmux-next: stack, validate once, land.

.github/workflows/cmux-next-batch.yml runs this. See docs/ci/cmux-next-batch.md.

  debounce  pull request and push events: wait for quiet, then dispatch a batch
  serve     the same queue as a long-running loop under the operator's gh
            login (until the batch App exists): poll, debounce, run batches
  run       the batch: select eligible PRs, stack them on feat-cmux-next,
            validate the stack once (every cmux-next tier plus a fleet
            production build), land each PR through GitHub's merge API at that head, or bisect a
            red stack down to the PR that broke it
  stack     stack PRs locally and print the result (no pushes, no GitHub writes)
  select    print which open PRs are eligible and why the others are not

Generated files never get a hand resolution. A conflict in one keeps the
stack's copy and the matching generator rebuilds it from the merged sources,
in a dispatched job that sends back a patch (the generators run the stack's
code, never on the controller's host). A conflict anywhere else drops that
PR from the batch.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import base_red_excuse  # noqa: E402
import gh_pages  # noqa: E402
import merge_main_resolver as mmr  # noqa: E402
import next_batch_groups as groups  # noqa: E402

TOOLS_ROOT = Path(__file__).resolve().parents[2]
BASE = "feat-cmux-next"
BRANCH_PREFIX = "next-batch/"
WORKFLOW = "cmux-next-batch.yml"
HEAVY_WORKFLOW = "cmux-next.yml"
TUI_WORKFLOW = "cmux-tui-artifacts.yml"
# A group's extra lanes (docs/ci/cmux-next-batch.md#groups), dispatched on its branch.
WEB_WORKFLOW = "cmux-next-web.yml"
MEDIA_WORKFLOW = "cmux-next-media.yml"
TOUR_JOB = "Tour the app"
STICKY_MARKER = "<!-- cmux-next-batch-queue -->"
COMMENT_MARKER = "<!-- cmux-next-batch:{kind}:{sha} -->"

QUIET_SECONDS = 120
HARD_MAX_SECONDS = 600
STALE_DAYS = 5
MAX_PRS = 12
MAX_CULPRITS = 3
# Group heads validated recently, and when: a cycle with the same heads learns
# nothing new, so a group that did not land waits for a push or the hour.
GROUP_TRIED: dict[tuple[tuple[int, str], ...], float] = {}
GROUP_RETRY_SECONDS = 60 * 60
# A group outcome that says the next cycle should validate it again, the hour notwithstanding.
REVALIDATE = "revalidate next cycle"
# GitHub refuses a merge right after another lands ("Base branch was modified").
MERGE_RETRIES = 3
POLL_SECONDS = 90
SERVE_POLL_SECONDS = 60
CLOSE_BURST = 3
CLOSE_WINDOW_SECONDS = 600

# Authors whose PRs the queue lands without asking (the agent lanes post as
# Leo). Anyone else opts a PR in with the OPT_IN label. Override the list with
# the CMUX_NEXT_BATCH_AUTHORS repository variable (space separated).
DEFAULT_AUTHORS = ("teamleaderleo",)
OPT_IN = "batch-queue"
# Overrides count only when a login no lane runs as applied them: every agent
# session runs gh as teamleaderleo, so its labels and statuses prove nothing.
OVERRIDE_ALONE = "queue: land alone"
OVERRIDE_BASE_RED = "queue: known base red"
DEFAULT_OVERRIDERS = ("lawrencecchen",)
REVIEW_CONTEXT = "review/independent"
# A PR carrying one of these is never batched.
HOLD_LABELS = frozenset({
    "hold", "exploration", "needs a call", "default call", "do-not-merge", "do not merge", "wip",
})
# The heavy tier. The batch runs these once on the stack, so a PR's own copy
# being red or pending does not keep it out of a batch.
HEAVY_CHECKS = frozenset({
    "cmux-next swift test",
    "cmux-next Release compile (Xcode 26)",
    "cmux app scheme compile (Debug)",
    "cmux-next daemon tests",
    "cmux-next generated files",
    "cmux-next generated files (shared build)",
    "wait for the same-tree cmux-tui",
})
# cmux-next.yml's base tier dispatch (cmux-next-base-tier-kick.yml) and the jobs it carries: a
# feat-cmux-next push no longer runs them (cmuxterm-hq#5424).
BASE_TIER_TITLE = "cmux-next base tier · "
# How many base tier runs a job's newest verdict is looked for in (a run whose tree was not
# published yet skips the tree jobs; its same-tree run, a later run, carries them).
BASE_TIER_LOOKBACK = 6
BASE_TIER_JOBS = frozenset({
    "cmux app scheme compile (Debug)",
    "cmux-next daemon tests",
    "cmux-next generated files",
    "cmux-next crash ends the app",
})
# One job, many static checks. Its last step lists each red one; the queue
# compares those, not the job, with the base (one base red never hides another).
CHECKS_JOB = "cmux-next checks (god files, concurrency, crash safety, l10n)"
# How long a red stack waits for the base probe to finish (it started with the
# first stack, so it is usually done), and the conclusions that count as red
# in the base's own push run when the probe gave nothing.
BASE_PROBE_GRACE = 60 * 60
OUTRIGHT_RED = frozenset({"failure", "timed_out"})
# Web formatting and lint autofix (`bun run check:fix` in webviews). The queue
# fixes these on the PR's own branch before landing, so they never block one.
FORMAT_CHECKS = frozenset({"web / react-apps-check", "web / Web status"})
RED = frozenset({"failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale", "error"})
PASS = frozenset({"success", "neutral", "skipped"})

# Generated outputs, by the generator that rebuilds them.
WEB_GENERATED = (
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/*",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity/*",
    "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/*",
    "Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources/palette-ranker.js",
    "Resources/markdown-viewer/webviews-app/*",
    # fnmatch's * crosses "/": every strings table gen-strings.mjs writes
    # (build output since #21946; an older branch still tracks them).
    "webviews/src/*/generated/strings.json",
    "webviews/src/pages/home-channels/generated/pane-strings.json",
    "webviews/src/pages/diff/generated/locales/*",
    "webviews/src/pages/diff/generated/localeLoaders.ts",
)
def settings_exports() -> tuple[str, ...]:
    """scripts/cmux-next/settings-exports.txt, the one list of what the settings export writes, so
    the settings half of SWIFT_GENERATED cannot drift from it. Its own copy was already short by
    docs/mdm/cmux-example.mobileconfig, which made that export look rebuildable anywhere (review
    of #23915)."""
    text = (TOOLS_ROOT / "scripts/cmux-next/settings-exports.txt").read_text(encoding="utf-8")
    listed = [line.split("#", 1)[0].strip() for line in text.splitlines()]
    return tuple(path for path in listed if path)


# Written by Swift tests under CMUX_UPDATE_*; only a mini can rebuild them.
SWIFT_GENERATED = (
    "plans/cmux-next/action-surfaces.json",
    "plans/cmux-next/actions.md",
    "plans/cmux-next/links.json",
    "plans/cmux-next/daemon-capabilities.json",
    *settings_exports(),
    "Packages/macOS/CmuxNext/ci-target-graph.json",
)
# cmux-tui/bindings/codegen/generate.py output.
SDK_GENERATED = tuple("cmux-tui/bindings/" + glob for glob in (
    "python/cmux/raw/_generated/*",
    "java/src/com/cmux/raw/*",
    "cpp/include/cmux/raw/generated/*",
    "cpp/src/raw/generated/*",
    "go/raw/*",
    "typescript/src/raw/generated/*",
    "rust/src/generated/*",
    "zig/src/raw/generated/*",
))
# The SDK IR is source, but a JSON document: two PRs that add different keys
# merge key by key, and the SDK output is then regenerated.
SPEC_JSON = ("cmux-tui/spec/*.json",)
TUI_PATHS = ("cmux-tui/", "ghostty", "ghostty-next", "scripts/cmux-next/build-layout-reducer-ffi.sh")
# The cmux-tui tree key's inputs, listed in the stack's own checkout.
TREE_INPUTS = "scripts/cmux-next/cmux-tui-tree-inputs.txt"


def touches_tree(changed: list[str], root: Path) -> bool:
    """Whether the stack changes a cmux-tui tree-key input (so its tree is not the base's)."""
    inputs = list(TUI_PATHS)
    try:
        for line in (root / TREE_INPUTS).read_text(encoding="utf-8").splitlines():
            parts = line.split()
            if len(parts) == 2 and not line.startswith("#"):
                inputs.append(parts[1] + ("/" if parts[0] == "tree" else ""))
    except OSError:
        pass
    return any(path == item or (item.endswith("/") and path.startswith(item)) or path.startswith(TUI_PATHS)
               for path in changed for item in inputs)
SECRET_ENV = re.compile(r"(TOKEN|SECRET|KEY|PASSWORD|CREDENTIAL)", re.I)


def classify(path: str) -> str:
    def matches(globs: tuple[str, ...]) -> bool:
        return any(fnmatch.fnmatchcase(path, glob) for glob in globs)

    if matches(WEB_GENERATED):
        return "web"
    if matches(SWIFT_GENERATED):
        return "swift"
    if matches(SDK_GENERATED):
        return "sdk"
    if matches(SPEC_JSON):
        return "spec"
    if path.endswith(".xcstrings"):
        return "xcstrings"
    if path == mmr.PBXPROJ:
        return "pbxproj"
    return "source"


# --- time and GitHub ----------------------------------------------------------


def now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def log(message: str) -> None:
    print(f"[next-batch {now().strftime('%H:%M:%S')}] {message}", flush=True)


class GitHub:
    """`gh` with the job's token. Every call is one request; nothing loops on its own."""

    def __init__(self, repo: str, token_env: str = "GH_TOKEN") -> None:
        self.repo = repo
        self.workflow_ids: dict[str, int] = {}
        self.env = dict(os.environ)
        if token_env != "GH_TOKEN":
            self.env["GH_TOKEN"] = os.environ.get(token_env, "")

    def gh(self, *args: str, input_text: str | None = None, check: bool = True) -> subprocess.CompletedProcess:
        completed = subprocess.run(
            ["gh", *args], input=input_text, capture_output=True, text=True, env=self.env,
        )
        if check and completed.returncode != 0:
            raise RuntimeError(f"gh {' '.join(args[:3])} failed: {completed.stderr.strip()[-500:]}")
        return completed

    def api(self, path: str, *args: str, method: str = "GET", body: dict | None = None) -> Any:
        extra = ["--input", "-"] if body is not None else []
        out = self.gh("api", "-X", method, path, *args, *extra,
                      input_text=json.dumps(body) if body is not None else None).stdout
        return json.loads(out) if out.strip() else None

    def graphql(self, query: str, **variables: Any) -> Any:
        args = ["api", "graphql", "-f", f"query={query}"]
        for key, value in variables.items():
            if value is not None:
                args += ["-F", f"{key}={value}"]
        completed = self.gh(*args, check=False)
        if completed.returncode != 0 and re.search(
                r"HTTP 5\d\d|unexpected end of JSON input|TLS handshake timeout|connection reset|i/o timeout",
                completed.stderr):
            time.sleep(10)  # a gateway or network timeout; once
            completed = self.gh(*args, check=False)
        if completed.returncode != 0:
            raise RuntimeError(f"gh api graphql failed: {completed.stderr.strip()[-500:]}")
        return json.loads(completed.stdout)["data"]

    def workflow(self, name: str) -> str:
        """The workflow's numeric id. A file name resolves only on the default
        branch (main), and feat-cmux-next-only workflows like this one are not
        there; the id works for every registered workflow."""
        if not self.workflow_ids:
            # One bounded page per call (scripts/ci/gh_pages.py): the gh quota wrapper refuses an
            # unbounded paginating call.
            listed = gh_pages.items(lambda url: json.loads(self.gh("api", url).stdout),
                                    f"repos/{self.repo}/actions/workflows")
            for workflow in listed:
                self.workflow_ids[workflow["path"].rsplit("/", 1)[-1]] = int(workflow["id"])
        return str(self.workflow_ids.get(name, name))

    def runs(self, workflow: str, query: str) -> list[dict]:
        return self.api(f"repos/{self.repo}/actions/workflows/{self.workflow(workflow)}/runs?{query}")["workflow_runs"]

    def dispatch(self, workflow: str, ref: str, inputs: dict[str, str] | None = None) -> None:
        self.api(f"repos/{self.repo}/actions/workflows/{self.workflow(workflow)}/dispatches", method="POST",
                 body={"ref": ref, "inputs": inputs or {}})

    def comment(self, number: int, body: str) -> None:
        self.api(f"repos/{self.repo}/issues/{number}/comments", method="POST", body={"body": body})

    def comments(self, number: int) -> list[dict]:
        return self.api(f"repos/{self.repo}/issues/{number}/comments?per_page=100")


# --- selection ----------------------------------------------------------------


@dataclass
class PullRequest:
    number: int
    sha: str
    title: str
    url: str = ""
    head_ref: str = ""
    labels: list[str] = field(default_factory=list)
    draft: bool = False
    same_repo: bool = True
    author_association: str = "MEMBER"
    committed_at: str = ""
    author: str = ""
    mergeable: str = "UNKNOWN"  # GitHub's MERGEABLE, CONFLICTING or UNKNOWN against BASE
    files: list[str] = field(default_factory=list)
    checks: list[tuple[str, str, str]] = field(default_factory=list)  # (name, status, conclusion)
    label_actors: dict[str, str] = field(default_factory=dict)  # label -> login that last applied it

    def short(self) -> str:
        return f"#{self.number}"


# Open PRs come in two queries. The list (LIST_PAGE per page) carries what the
# cheap filters read, plus the check rollup's state and counts. Files and check
# contexts, the heavy part (30 PRs with both in one page timed out at GitHub,
# HTTP 504), are fetched DETAIL_PAGE PRs at a time and only for PRs the cheap
# filters keep. Contexts are paged: a cmux-next head carries well over 100.
# The list also carries the last label events, so an override label counts only
# when an allowed login applied it after the head's commit (trusted_labels).
LIST_PAGE = 50
DETAIL_PAGE = 10
LIST_QUERY = """
query($owner: String!, $name: String!, $base: String!, $first: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, baseRefName: $base, first: $first, after: $after,
                 orderBy: {field: CREATED_AT, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id number title url isDraft headRefName headRefOid authorAssociation mergeable
        author { login }
        isCrossRepository
        labels(first: 30) { nodes { name } }
        timelineItems(itemTypes: [LABELED_EVENT], last: 10) { nodes {
          ... on LabeledEvent { createdAt label { name } actor { login } }
        } }
        commits(last: 1) { nodes { commit {
          committedDate
          statusCheckRollup { state contexts(first: 1) {
            checkRunCountsByState { state count }
            statusContextCountsByState { state count }
          } }
        } } }
      }
    }
  }
}
"""
CONTEXTS = """contexts(first: 100{after}) {{
  pageInfo {{ hasNextPage endCursor }}
  nodes {{
    __typename
    ... on CheckRun {{ name status conclusion startedAt checkSuite {{ workflowRun {{ workflow {{ name }} }} }} }}
    ... on StatusContext {{ context state createdAt }}
  }}
}}"""
GRAPHQL_TOKEN = re.compile(r"^[A-Za-z0-9_=+/-]+$")
# (head sha, rollup counts) -> (files, checks); a PR whose head and check
# counts did not move since the last poll is not fetched again.
DETAILS: dict[tuple[str, str], tuple[list[str], list[tuple[str, str, str]]]] = {}


def detail_query(items: list[tuple[str, bool, str | None]]) -> str:
    """One query for up to DETAIL_PAGE PRs: (node id, want files, contexts cursor).
    A cursor of "" asks for the first contexts page, None for none."""
    parts = []
    for index, (node_id, files, cursor) in enumerate(items):
        if not GRAPHQL_TOKEN.match(node_id) or (cursor and not GRAPHQL_TOKEN.match(cursor)):
            raise ValueError(f"unexpected GraphQL id or cursor {node_id!r} {cursor!r}")
        fields = "files(first: 100) { nodes { path } }" if files else ""
        if cursor is not None:
            after = f', after: "{cursor}"' if cursor else ""
            fields += (" commits(last: 1) { nodes { commit { statusCheckRollup { "
                       + CONTEXTS.format(after=after) + " } } } }")
        parts.append(f'p{index}: node(id: "{node_id}") {{ ... on PullRequest {{ {fields} }} }}')
    return "query {\n" + "\n".join(parts) + "\n}"


def parse_contexts(rollup: list[dict]) -> list[tuple[str, str, str, str, str]]:
    """(key, name, status, conclusion, started) per context; newest_checks reduces them.
    A check run's key is its workflow and name, so same-named jobs of two workflows stay apart."""
    checks = []
    for item in rollup:
        if item["__typename"] == "CheckRun":
            workflow = ((((item.get("checkSuite") or {}).get("workflowRun") or {}).get("workflow") or {}).get("name") or "")
            checks.append((f"{workflow}\0{item['name']}", item["name"], (item["status"] or "").lower(),
                           (item["conclusion"] or "").lower(), item.get("startedAt") or ""))
        else:
            state = (item["state"] or "").lower()
            status = "completed" if state not in {"pending", "expected"} else "in_progress"
            checks.append(("\0" + item["context"], item["context"], status, state, item.get("createdAt") or ""))
    return checks


# Conclusions that say nothing about the code (merge_guard.py: SETTLED leaves them out).
SILENT = frozenset({"cancelled", "skipped"})


def newest_checks(runs: list[tuple[str, str, str, str, str]]) -> list[tuple[str, str, str]]:
    """One (name, status, conclusion) per check: its newest run, by start time.

    A head keeps every run of a check (a rerun, a second workflow event, a
    concurrency-cancelled one), and an old red would otherwise hold the PR after
    a later run passed. A run not started yet counts as the newest. A cancelled
    or skipped newest run says nothing about the code, so the newest run of the
    same check that finished otherwise stands instead (a superseded run
    cancelled late, or a label event a workflow skips: a `risk:*` swap must not
    hide a red); with none, the cancelled or skipped run counts."""
    by_key: dict[str, list[tuple[str, str, str, str, str]]] = {}
    for run in runs:
        by_key.setdefault(run[0], []).append(run)
    checks = []
    for items in by_key.values():
        # Stable sort: among runs with the same start time, the later one in the rollup wins.
        ordered = sorted(items, key=lambda run: run[4] or "\uffff")
        newest = ordered[-1]
        if newest[2] == "completed" and newest[3] in SILENT:
            finished = [run for run in ordered if run[2] == "completed" and run[3] not in SILENT]
            if finished:
                newest = finished[-1]
        checks.append((newest[1], newest[2], newest[3]))
    return checks


def fetch_details(gh: GitHub, wanted: list[tuple[str, bool, bool]]) -> dict[str, tuple[list[str], list]]:
    """Files and every check context for (node id, want files, want checks)."""
    files: dict[str, list[str]] = {node_id: [] for node_id, _, _ in wanted}
    checks: dict[str, list] = {node_id: [] for node_id, _, _ in wanted}
    # node id -> (want files still, contexts cursor or None when done)
    todo = {node_id: (want_files, "" if want_checks else None) for node_id, want_files, want_checks in wanted
            if want_files or want_checks}
    while todo:
        batch = list(todo.items())[:DETAIL_PAGE]
        data = gh.graphql(detail_query([(node_id, want, cursor) for node_id, (want, cursor) in batch]))
        for index, (node_id, (want_files, cursor)) in enumerate(batch):
            node = data.get(f"p{index}") or {}
            if want_files:
                files[node_id] = [item["path"] for item in (node.get("files") or {}).get("nodes") or []]
            following = None
            if cursor is not None:
                commit = ((node.get("commits") or {}).get("nodes") or [{}])[0].get("commit") or {}
                connection = (commit.get("statusCheckRollup") or {}).get("contexts") or {}
                checks[node_id] += parse_contexts(connection.get("nodes") or [])
                info = connection.get("pageInfo") or {}
                if info.get("hasNextPage") and info.get("endCursor"):
                    following = info["endCursor"]
            if following is None:
                del todo[node_id]
            else:
                todo[node_id] = (False, following)
    return {node_id: (files[node_id], newest_checks(checks[node_id])) for node_id, _, _ in wanted}


def rollup_failing(rollup: dict) -> bool:
    """Whether any check or status in the rollup ended red (its state or a red count)."""
    if (rollup.get("state") or "").upper() in {"FAILURE", "ERROR"}:
        return True
    contexts = rollup.get("contexts") or {}
    counts = (contexts.get("checkRunCountsByState") or []) + (contexts.get("statusContextCountsByState") or [])
    return any((item.get("state") or "").lower() in RED and item.get("count") for item in counts)


def open_prs(gh: GitHub, fresh: bool = False) -> list[PullRequest]:
    """Every open PR into BASE. Files and checks are filled in only for PRs
    the cheap filters keep (ineligible_reason without them), and checks only
    when the rollup has a failure: nothing else reads them. `fresh` skips the
    cache (landing rechecks the exact state)."""
    owner, name = gh.repo.split("/")
    nodes, after = [], None
    while True:
        page = gh.graphql(LIST_QUERY, owner=owner, name=name, base=BASE, first=LIST_PAGE, after=after)
        connection = page["repository"]["pullRequests"]
        nodes += connection["nodes"]
        info = connection.get("pageInfo") or {}
        if not info.get("hasNextPage"):
            break
        after = info["endCursor"]
    at = now()
    prs, wanted, keys, found = [], [], {}, {}
    for node in nodes:
        commit = (node["commits"]["nodes"] or [{}])[0].get("commit") or {}
        rollup = commit.get("statusCheckRollup") or {}
        pr = PullRequest(
            number=node["number"], sha=node["headRefOid"], title=node["title"], url=node["url"],
            head_ref=node["headRefName"], labels=[label["name"] for label in node["labels"]["nodes"]],
            draft=node["isDraft"], same_repo=not node["isCrossRepository"],
            author_association=node["authorAssociation"], committed_at=commit.get("committedDate", ""),
            author=(node.get("author") or {}).get("login", ""),
            # An override holds for the head it was applied to: one applied before the
            # head's commit says nothing about the new code.
            label_actors={event["label"]["name"]: (event.get("actor") or {}).get("login", "")
                          for event in (node.get("timelineItems") or {}).get("nodes") or []
                          if event and event.get("label")
                          and (event.get("createdAt") or "") >= commit.get("committedDate", "")},
            mergeable=node.get("mergeable") or "UNKNOWN",
        )
        prs.append((pr, node))
        if ineligible_reason(pr, at) is not None:
            continue
        key = (pr.sha, json.dumps(rollup, sort_keys=True))
        keys[node["id"]] = key
        cached = None if fresh else DETAILS.get(key)
        if cached is None:
            wanted.append((node["id"], True, rollup_failing(rollup)))
        else:
            found[key] = cached
    if wanted:
        fetched = {keys[node_id]: details for node_id, details in fetch_details(gh, wanted).items()}
        found.update(fetched)
        if len(DETAILS) > 5000:
            DETAILS.clear()
        DETAILS.update(fetched)
    for pr, node in prs:
        if node["id"] in keys:
            pr.files, pr.checks = found[keys[node["id"]]]
    return [pr for pr, _ in prs]


def touches_webviews(pr: PullRequest) -> bool:
    return any(path.startswith("webviews/") for path in pr.files)


def red_fast_checks(pr: PullRequest) -> list[str]:
    fixable = FORMAT_CHECKS if touches_webviews(pr) else frozenset()
    return sorted({name for name, status, conclusion in pr.checks
                   if status == "completed" and conclusion in RED and name not in HEAVY_CHECKS | fixable})


def group_hold(pr: PullRequest) -> str | None:
    """Why a group member can't land with the rest: any failed check of its own,
    heavy tier and trusted `queue: known base red` included. A policy, stricter
    than a single PR's bar (merge_one doesn't judge checks): a group lands as
    one, so it waits until every member is clean, a red the base shares
    included, rather than land members whose own CI is red. Each check counts by its newest run
    (newest_checks), so a rerun that passed clears it."""
    red = sorted({name for name, status, conclusion in pr.checks if status == "completed" and conclusion in RED})
    return "red check " + ", ".join(red) if red else None


# Never waived by an override label: risk evidence judges the PR's own description and merge freeze its
# own paths, and neither runs on the stack, so the batch can't judge them for it.
NEVER_WAIVED = frozenset({"risk evidence", "merge freeze"})


def freeze_check(repo: str, number: int, env: dict[str, str]) -> tuple[int, str]:
    """merge_freeze.py's verdict right before the merge: 0 clear, 1 frozen, 2 unreadable (never clear).

    A freeze opened after the PR's own `merge freeze` check ran still stops it here."""
    try:
        done = subprocess.run([sys.executable, str(TOOLS_ROOT / "scripts/ci/merge_freeze.py"), "check", "--repo", repo,
                               "--pr", str(number), "--base", BASE], capture_output=True, text=True, env=env, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as error:
        return 2, str(error)
    return (done.returncode if done.returncode in (0, 1) else 2), (done.stdout + done.stderr).strip()[-300:]


def drop_frozen(prs: list[PullRequest], check: Callable[[int], tuple[int, str]]
                ) -> tuple[list[PullRequest], dict[int, str]]:
    """Leave out PRs a merge freeze covers (or whose freeze state can't be read) before stacking, so one
    frozen PR never stops every batch at its place in the stack until the freeze lapses."""
    kept, skipped = [], {}
    for pr in prs:
        code, detail = check(pr.number)
        if code == 0:
            kept.append(pr)
        else:
            skipped[pr.number] = (f"frozen: {detail}" if code == 1 else f"freeze state unreadable: {detail}")[:200]
    return kept, skipped


# A transient GitHub or network error, from gh's message (as GitHub.graphql retries).
TRANSIENT = re.compile(r"HTTP 5\d\d|Base branch was modified|unexpected end of JSON input|TLS handshake timeout|"
                       r"connection reset|i/o timeout|timed out|EOF", re.I)


def red_format_checks(pr: PullRequest) -> list[str]:
    return sorted({name for name, status, conclusion in pr.checks
                   if status == "completed" and conclusion in RED and name in FORMAT_CHECKS})


def batch_authors() -> frozenset[str]:
    configured = os.environ.get("CMUX_NEXT_BATCH_AUTHORS", "").split()
    return frozenset(configured or DEFAULT_AUTHORS)


def overriders() -> frozenset[str]:
    configured = os.environ.get("CMUX_NEXT_BATCH_OVERRIDERS", "").split()
    return frozenset(configured or DEFAULT_OVERRIDERS) - batch_authors() - frozenset(DEFAULT_AUTHORS)  # never a lane's login


def trusted_labels(pr: PullRequest) -> set[str]:
    """Override labels on this PR that an allowed login applied."""
    return {label for label in pr.labels if pr.label_actors.get(label) in overriders()}


def coordinator_prs() -> set[int]:
    """PR numbers coord-2 lands itself: every number in CMUX_NEXT_BATCH_EXCLUDE (its merge-ready file)."""
    path = os.environ.get("CMUX_NEXT_BATCH_EXCLUDE", "")
    if not path:
        return set()
    # Its entries are "owner/repo|<pr>|<sha>|..." strings; nothing else in the file counts.
    text = Path(path).expanduser().read_text()  # unreadable is an error, never "exclude nothing"
    return {int(number) for number in re.findall(r"manaflow-ai/cmux\|([1-9][0-9]*)\|", text)}


def landing_refusal() -> str | None:
    """Why this process must not land anything, or None."""
    if os.environ.get("GITHUB_ACTIONS") == "true" and not os.environ.get("CMUX_NEXT_BATCH_EXCLUDE"):
        return ("no CMUX_NEXT_BATCH_EXCLUDE on this runner, so coord-2's PRs can't be told apart; "
                "serve on the coordinator's host lands instead")
    return None


def land_alone_first(eligible: list[PullRequest], tried: set[int] = frozenset()) -> list[PullRequest]:
    """A PR with a trusted `queue: land alone` label is validated and landed in a batch of its own,
    once per head: `tried` holds the PRs already taken alone at their current head."""
    alone = [pr for pr in eligible if OVERRIDE_ALONE in trusted_labels(pr) and pr.number not in tried]
    return alone[:1] or eligible


def admit_reviewed(eligible: list[PullRequest], gh: "GitHub | None", landing: bool
                   ) -> tuple[list[PullRequest], dict[int, str]]:
    """When the batch lands, stack only reviewed heads, so the validated stack is exactly what lands.
    A receipt-only batch lands nothing and validates everything."""
    if not landing:
        return eligible, {}
    admitted = [pr for pr in eligible if reviewed(pr, gh)]
    return admitted, {pr.number: "waiting for an independent review at this head"
                      for pr in eligible if pr not in admitted}


def reviewed(pr: PullRequest, gh: "GitHub | None" = None) -> bool:
    """An independent review approved this exact head.

    Two sources, either is enough: CMUX_NEXT_BATCH_REVIEWED, a file of `<pr> <sha>` lines the reviewer
    writes (coord-2 today), and a `review/independent` success status whose creator is one of
    CMUX_NEXT_BATCH_REVIEWERS (for a review App or bot that no lane runs as). A push makes a new head
    with neither, so approval never carries over.
    """
    path = os.environ.get("CMUX_NEXT_BATCH_REVIEWED", "")
    if path:
        try:
            file = Path(path).expanduser()
            info = file.stat()
            # Owned by this user and writable by nobody else. Every lane is this
            # user too, so this keeps out other accounts, not other lanes.
            if info.st_uid == os.getuid() and not info.st_mode & 0o022:
                for line in file.read_text().splitlines():
                    fields = line.split("#", 1)[0].split()
                    if len(fields) >= 2 and fields[0] == str(pr.number) and len(fields[1]) >= 12 \
                            and pr.sha.startswith(fields[1]):
                        return True
        except OSError:
            pass
    reviewers = set(os.environ.get("CMUX_NEXT_BATCH_REVIEWERS", "").split()) - batch_authors() - set(DEFAULT_AUTHORS)
    if reviewers and gh is not None:
        try:
            statuses = gh.api(f"repos/{gh.repo}/commits/{pr.sha}/statuses?per_page=100") or []
        except RuntimeError as error:
            log(f"#{pr.number}: statuses unreadable ({error}); not reviewed")
            return False
        for status in statuses:
            if status.get("context") == REVIEW_CONTEXT and (status.get("creator") or {}).get("login") in reviewers:
                return status.get("state") == "success"  # newest first: the latest status from a reviewer decides
    return False


def ineligible_reason(pr: PullRequest, at: dt.datetime, stale_days: int = STALE_DAYS,
                      authors: frozenset[str] | None = None, own_checks: bool = True) -> str | None:
    """Why this PR stays out of the batch, or None when it is eligible.

    Eligible: ready for review, a same-repository member branch by a batch
    author (or labeled OPT_IN), no hold label, a head commit from the last
    `stale_days` days, and no failed check outside the heavy tier (pending
    is fine). A group member (`own_checks=False`) skips the last rule: its
    group's combined run stands in for its own CI.
    """
    authors = batch_authors() if authors is None else authors
    if pr.draft:
        return "draft"
    if not pr.same_repo:
        return "head is in a fork"
    if pr.author_association not in {"MEMBER", "OWNER", "COLLABORATOR"}:
        return f"author association {pr.author_association}"
    if pr.head_ref.startswith(BRANCH_PREFIX):
        return "a batch integration branch"
    if pr.author not in authors and OPT_IN not in pr.labels:
        return f"author {pr.author or '?'} has not opted in (label {OPT_IN})"
    # The job token can neither push nor merge a workflow change (GitHub
    # requires the `workflows` permission), so those PRs land by hand.
    if any(path.startswith(".github/workflows/") for path in pr.files):
        return "changes .github/workflows (lands by hand)"
    held = sorted(label for label in pr.labels if label.lower() in HOLD_LABELS)
    if held:
        return "label " + ", ".join(held)
    # A PR that conflicts with the base itself can never stack; it waits for
    # its owner to merge feat-cmux-next instead of taking a batch slot.
    if pr.mergeable == "CONFLICTING":
        return f"conflicts with {BASE} (merge it, push)"
    if pr.committed_at and at - parse_time(pr.committed_at) > dt.timedelta(days=stale_days):
        return f"head commit older than {stale_days} days"
    if pr.number in coordinator_prs():
        return "coord-2 lands it (listed in its merge-ready file)"
    red = red_fast_checks(pr) if own_checks else []
    never = sorted(name for name in red if name.lower() in NEVER_WAIVED)
    if never:
        return "red check " + ", ".join(never)
    # A trusted `queue: known base red` lets the batch judge it: a job red on
    # feat-cmux-next itself never counts against the stack.
    if red and OVERRIDE_BASE_RED not in trusted_labels(pr):
        return "red check " + ", ".join(red)
    return None


def select(prs: list[PullRequest], at: dt.datetime, only: set[int] | None = None,
           limit: int = MAX_PRS) -> tuple[list[PullRequest], dict[int, str]]:
    eligible, skipped = [], {}
    for pr in sorted(prs, key=lambda item: item.number):
        if only is not None and pr.number not in only:
            continue
        if clash := groups.conflicting_groups(pr.labels):
            skipped[pr.number] = "two group labels: " + ", ".join(clash) + " (keep one)"
            continue
        if name := groups.group_of(pr.labels):
            skipped[pr.number] = f"in group {groups.GROUP_PREFIX}{name}; lands with its group"
            continue
        reason = ineligible_reason(pr, at)
        if reason:
            skipped[pr.number] = reason
        elif len(eligible) >= limit:
            skipped[pr.number] = f"batch is full ({limit}); next batch"
        else:
            eligible.append(pr)
    return eligible, skipped


# --- debounce -----------------------------------------------------------------


def debounce_wait(at: dt.datetime, first_trigger: dt.datetime,
                  quiet: int = QUIET_SECONDS, hard_max: int = HARD_MAX_SECONDS) -> int:
    """Seconds to wait before dispatching.

    A newer event's run supersedes the waiting one (`superseded`), so a
    dispatch happens after `quiet` seconds without events, but never later
    than `hard_max` after the first event since the last dispatch.
    """
    waited = int((at - first_trigger).total_seconds())
    return max(0, min(quiet, hard_max - waited))


def first_trigger_since_dispatch(runs: list[dict], at: dt.datetime) -> dt.datetime:
    """The oldest event run newer than the last batch dispatch (this run included)."""
    dispatches = [parse_time(run["created_at"]) for run in runs if run.get("event") == "workflow_dispatch"
                  and str(run.get("display_title", "")).startswith("batch")]
    last = max(dispatches, default=dt.datetime.min.replace(tzinfo=dt.timezone.utc))
    triggers = [parse_time(run["created_at"]) for run in runs
                if run.get("event") in {"pull_request", "push"} and parse_time(run["created_at"]) > last]
    return min(triggers, default=at)


def superseded(runs: list[dict], run_id: int | str | None, repo: str | None = None,
               page: int = 60) -> bool:
    """A newer pull_request or push run whose debounce job runs exists, and it takes over the wait.
    The older run then exits 0: a cancelled run would read red on its pull request. A fork's run
    or a next-batch/ head's skips the job (the workflow's `if`), so it never takes over."""
    try:
        mine = int(run_id or 0)
    except ValueError:
        return False

    def waits(run: dict) -> bool:
        head = (run.get("head_repository") or {}).get("full_name") or repo
        return (run.get("event") in {"pull_request", "push"} and head == repo
                and not str(run.get("head_branch") or "").startswith("next-batch/"))

    ids = [run.get("id") or 0 for run in runs]
    if mine not in ids:
        # a full listing that no longer reaches this run holds `page` newer ones; a shorter one
        # means this run is not listed yet, so nothing newer is either
        return len(runs) >= page and mine < min(ids)
    return any(waits(run) and (run.get("id") or 0) > mine for run in runs)


def cmd_debounce(args: argparse.Namespace) -> int:
    gh = GitHub(args.repo)
    me = os.environ.get("GITHUB_RUN_ID")
    runs = gh.runs(WORKFLOW, "per_page=60")
    if superseded(runs, me, args.repo):
        log("a newer event's run waits instead; nothing to do")
        return 0
    at = now()
    first = first_trigger_since_dispatch(runs, at)
    wait = debounce_wait(at, first)
    log(f"first event since the last batch at {first.isoformat()}; waiting {wait}s for quiet")
    time.sleep(wait)
    if superseded(gh.runs(WORKFLOW, "per_page=60"), me, args.repo):
        log("an event arrived during the wait; its run dispatches instead")
        return 0
    gh.dispatch(WORKFLOW, BASE, {"mode": "batch", "reason": args.reason or "debounced events"})
    log("dispatched a batch")
    return 0


class Debouncer:
    """The serve loop's trigger, with the debounce job's timing.

    `observe` gets the eligible set as (number, head sha) pairs once per poll.
    A batch runs after `quiet` seconds without a change, never later than
    `hard_max` after the first change since the last batch, and not again
    for a set it already ran.
    """

    def __init__(self, quiet: int = QUIET_SECONDS, hard_max: int = HARD_MAX_SECONDS) -> None:
        self.quiet, self.hard_max = quiet, hard_max
        self.seen: tuple | None = None
        self.done: tuple | None = None
        self.first: dt.datetime | None = None
        self.last: dt.datetime | None = None

    def observe(self, heads: tuple, at: dt.datetime) -> bool:
        if heads != self.seen:
            self.seen, self.last = heads, at
            if not heads or heads == self.done:
                self.first = None
            elif self.first is None:
                self.first = at
        if self.first is None or self.last is None:
            return False
        return (at - self.last).total_seconds() >= self.quiet or \
            (at - self.first).total_seconds() >= self.hard_max

    def ran(self, heads: tuple) -> None:
        self.done, self.first = heads, None


# --- close watch --------------------------------------------------------------


CLOSED_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      state merged closedAt author { login }
      timelineItems(last: 1, itemTypes: [CLOSED_EVENT]) {
        nodes { ... on ClosedEvent { actor { login } createdAt } }
      }
    }
  }
}
"""


def closed_info(gh: GitHub, number: int) -> dict:
    owner, name = gh.repo.split("/")
    node = gh.graphql(CLOSED_QUERY, owner=owner, name=name, number=number)["repository"]["pullRequest"]
    event = (node["timelineItems"]["nodes"] or [{}])[-1]
    return {"state": node["state"], "merged": node["merged"], "author": (node.get("author") or {}).get("login", ""),
            "actor": (event.get("actor") or {}).get("login", "?"),
            "closed_at": event.get("createdAt") or node.get("closedAt") or "?"}


class CloseWatch:
    """Notices a batch author's PR that left the open set closed, unmerged,
    by someone else, from the open-PR poll serve already makes. One lookup
    per PR that left; it reports and never reopens anything.

    Each close is reported on its own until `burst` of them fall within
    `window` seconds; then one alert lists them, and later closes in that
    burst wait for one summary when it is over.
    """

    def __init__(self, lookup: Callable[[int], dict], notify: Callable[[str], None], authors: frozenset[str],
                 burst: int = CLOSE_BURST, window: int = CLOSE_WINDOW_SECONDS) -> None:
        self.lookup, self.notify, self.authors = lookup, notify, authors
        self.burst, self.window = burst, window
        self.open: set[int] | None = None
        self.pending: set[int] = set()
        self.recent: list[tuple[dt.datetime, str]] = []
        self.alerted = False
        self.held: list[str] = []

    def observe(self, prs: list[PullRequest], at: dt.datetime) -> None:
        current = {pr.number for pr in prs if pr.author in self.authors}
        if self.open is not None:
            self.pending |= self.open - current
        self.open = current
        found = []
        for number in sorted(self.pending):
            try:
                info = self.lookup(number)
            except Exception as error:  # the next poll retries it
                log(f"close watch: #{number}: {error}")
                continue
            self.pending.discard(number)
            if info["state"] == "CLOSED" and not info["merged"] and info["actor"] != info["author"]:
                found.append(f"#{number} closed unmerged by {info['actor']} at {info['closed_at']}")
        self.recent = [(when, text) for when, text in self.recent
                       if (at - when).total_seconds() < self.window]
        if self.alerted and not self.recent and not found:
            if self.held:
                self.notify("cmux-next close burst over; also closed: " + "; ".join(self.held))
            self.alerted, self.held = False, []
        for text in found:
            self.recent.append((at, text))
        if not found:
            return
        if self.alerted:
            self.held += found
        elif len(self.recent) >= self.burst:
            self.alerted = True
            self.notify(f"ALERT: {len(self.recent)} {'/'.join(sorted(self.authors))} PRs to {BASE} closed by "
                        f"others within {self.window // 60} min: " + "; ".join(text for _, text in self.recent))
        else:
            for text in found:
                self.notify(f"{'/'.join(sorted(self.authors))} PR {text} (PR to {BASE})")


def notify_coordinator(text: str) -> None:
    command = os.environ.get("CMUX_NEXT_BATCH_NOTIFY", "tell-coordinator")
    if not shutil.which(command):
        log(f"no {command}; would notify: {text}")
        return
    completed = subprocess.run([command, text], capture_output=True, text=True)
    log(f"notified: {text}" if completed.returncode == 0 else f"{command} failed: {completed.stderr.strip()[-200:]}")


# --- stacking -----------------------------------------------------------------


class JsonConflict(Exception):
    pass


_MISSING = object()


def json_merge(base: Any, ours: Any, theirs: Any, where: str = "$") -> Any:
    """Three-way merge of JSON values, key by key.

    Objects merge per key; arrays merge when both sides only appended. Any
    key both sides changed differently is a conflict.
    """
    if ours == theirs:
        return ours
    if ours == base:
        return theirs
    if theirs == base:
        return ours
    if all(isinstance(value, dict) for value in (ours, theirs)) and isinstance(base, (dict, type(_MISSING))):
        base_dict = base if isinstance(base, dict) else {}
        merged: dict = {}
        keys = list(ours) + [key for key in theirs if key not in ours]
        for key in keys:
            value = json_merge(base_dict.get(key, _MISSING), ours.get(key, _MISSING),
                               theirs.get(key, _MISSING), f"{where}.{key}")
            if value is not _MISSING:
                merged[key] = value
        return merged
    if all(isinstance(value, list) for value in (base, ours, theirs)):
        size = len(base)
        if ours[:size] == base and theirs[:size] == base:
            added = ours[size:]
            return base + added + [item for item in theirs[size:] if item not in added]
    raise JsonConflict(where)


def json_merge_text(base: str, ours: str, theirs: str) -> str:
    merged = json_merge(json.loads(base), json.loads(ours), json.loads(theirs))
    second = ours.splitlines()[1] if len(ours.splitlines()) > 1 else ""
    indent = len(second) - len(second.lstrip(" ")) or 2
    text = json.dumps(merged, indent=indent, ensure_ascii=False)
    return text + ("\n" if ours.endswith("\n") else "")


@dataclass
class Merge:
    number: int
    ok: bool
    regen: set[str] = field(default_factory=set)
    resolved: list[dict[str, str]] = field(default_factory=list)
    blocking: list[dict[str, str]] = field(default_factory=list)


@dataclass
class Stack:
    base: str
    head: str = ""
    included: list[PullRequest] = field(default_factory=list)
    dropped: list[tuple[PullRequest, list[dict[str, str]]]] = field(default_factory=list)
    resolved: list[dict[str, str]] = field(default_factory=list)
    regen: set[str] = field(default_factory=set)
    regenerated: list[str] = field(default_factory=list)
    error: str = ""
    heads: dict[int, str] = field(default_factory=dict)  # the stack commit right after each PR merged

    def summary(self) -> dict:
        return {
            "base": self.base, "head": self.head,
            "included": [{"number": pr.number, "sha": pr.sha, "title": pr.title} for pr in self.included],
            "dropped": [{"number": pr.number, "sha": pr.sha, "blocking": blocking} for pr, blocking in self.dropped],
            "resolved": self.resolved, "regenerated": self.regenerated,
            "swift_regen": "swift" in self.regen, "error": self.error,
        }


def take_side(repo: mmr.Repo, path: str, stages: set[int]) -> None:
    """Keep the stack's copy of a generated path (the generator rewrites it)."""
    if 2 in stages:
        repo.run("checkout", "--ours", "--", path)
        repo.run("add", "--", path)
    else:
        repo.run("rm", "--cached", "--quiet", "--", path)
        target = repo.path / path
        if target.is_file() or target.is_symlink():
            target.unlink()


def merge_pr(repo: mmr.Repo, pr: PullRequest, tools_root: Path) -> Merge:
    result = Merge(pr.number, ok=False)
    merge = repo.run("merge", "--no-ff", "--no-commit", "--no-edit", pr.sha, check=False)
    in_merge = repo.run("rev-parse", "--verify", "--quiet", "MERGE_HEAD", check=False).returncode == 0
    if not in_merge:
        if merge.returncode == 0:  # already contained in the stack
            result.ok = True
            return result
        result.blocking.append({"path": "", "reason": mmr.tail(merge.stderr.decode(errors="replace"))})
        return result
    try:
        resolver = mmr.Resolver(repo, tools_root)
        unmerged = repo.unmerged()
        for path, stages in sorted(unmerged.items()):
            kind = classify(path)
            if kind in {"web", "swift", "sdk"}:
                take_side(repo, path, stages)
                result.regen.add(kind)
                result.resolved.append({"path": path, "method": f"kept the stack's copy; {kind} regeneration"})
            elif stages != {1, 2, 3}:
                side = "added on both sides" if 1 not in stages else "deleted on one side and changed on the other"
                resolver.block(path, side)
            elif kind == "spec":
                try:
                    texts = [repo.stage_bytes(stage, path).decode("utf-8") for stage in (1, 2, 3)]
                    (repo.path / path).write_text(json_merge_text(*texts), encoding="utf-8")
                except (JsonConflict, ValueError) as error:
                    resolver.block(path, f"both sides changed the same key ({error})")
                    continue
                repo.run("add", "--", path)
                result.regen.add("sdk")
                result.resolved.append({"path": path, "method": "JSON key merge; SDK regeneration"})
            elif kind == "xcstrings":
                resolver.xcstrings(path)
            elif kind == "pbxproj":
                resolver.pbxproj(path)
            else:
                resolver.block(path, "both sides changed it")
        result.resolved += resolver.resolved
        result.blocking = resolver.blocking
        if result.blocking or repo.unmerged():
            repo.run("merge", "--abort", check=False)
            if not result.blocking:
                result.blocking.append({"path": "", "reason": "unresolved paths remain"})
            return result
        # A generated file both sides changed can merge without a conflict
        # and still be wrong; rebuild it too.
        bases = repo.text("merge-base", "--all", "HEAD", "MERGE_HEAD").split()
        if len(bases) == 1:
            ours = set(repo.text("diff", "--name-only", bases[0], "HEAD").splitlines())
            theirs = set(repo.text("diff", "--name-only", bases[0], "MERGE_HEAD").splitlines())
            for path in ours & theirs:
                kind = classify(path)
                if kind in {"web", "swift", "sdk"}:
                    result.regen.add(kind)
                elif kind == "spec":
                    result.regen.add("sdk")
        message = f"next-batch: merge #{pr.number}\n\n{pr.title}\n"
        if result.resolved:
            message += "\nResolved:\n" + "".join(f"- {item['path']}: {item['method']}\n" for item in result.resolved)
        repo.run("commit", "--no-verify", "-F", "-", input_bytes=message.encode())
        result.ok = True
        return result
    except BaseException:
        if repo.run("rev-parse", "--verify", "--quiet", "MERGE_HEAD", check=False).returncode == 0:
            repo.run("merge", "--abort", check=False)
        raise


def scrubbed_env() -> dict[str, str]:
    """The environment for generators, which run the merged tree's code."""
    return {key: value for key, value in os.environ.items()
            if not SECRET_ENV.search(key) and not key.startswith(("GITHUB_TOKEN", "ACTIONS_"))}


def regenerate(repo: mmr.Repo, stack: Stack) -> None:
    steps = []
    if "web" in stack.regen:
        steps.append(("web bundles", ["sh", "scripts/cmux-next/regenerate-web-bundles.sh"]))
    if "sdk" in stack.regen:
        steps.append(("cmux-tui SDK", [sys.executable, "cmux-tui/bindings/codegen/generate.py", "--write"]))
    for name, command in steps:
        log(f"regenerating {name}")
        completed = subprocess.run(command, cwd=repo.path, env=scrubbed_env(), capture_output=True, text=True)
        if completed.returncode != 0:
            stack.error = f"regenerating {name} failed: {mmr.tail(completed.stdout + completed.stderr, 1200)}"
            return
        repo.run("add", "-A", "--", ".")
        if repo.run("diff", "--cached", "--quiet", check=False).returncode != 0:
            repo.run("commit", "--no-verify", "-m", f"next-batch: regenerate {name}")
            stack.regenerated.append(name)


def build_stack(worktree: Path, base_sha: str, prs: list[PullRequest], tools_root: Path = TOOLS_ROOT,
                regen: bool = True) -> Stack:
    """Merge `prs` in order onto `base_sha` in `worktree` (a clean checkout)."""
    mmr.check_git_version()
    repo = mmr.Repo(worktree)
    repo.attr_tree = base_sha  # merge attributes come from the trusted base
    repo.run("checkout", "--quiet", "--force", "--detach", base_sha)
    repo.run("clean", "-fdq")
    stack = Stack(base=base_sha)
    for pr in prs:
        merged = merge_pr(repo, pr, tools_root)
        if merged.ok:
            stack.included.append(pr)
            stack.heads[pr.number] = repo.text("rev-parse", "HEAD")
            stack.resolved += [{"pr": f"#{pr.number}", **item} for item in merged.resolved]
            stack.regen |= merged.regen
            log(f"merged #{pr.number}" + (f" ({len(merged.resolved)} resolved)" if merged.resolved else ""))
        else:
            stack.dropped.append((pr, merged.blocking))
            log(f"dropped #{pr.number}: " + "; ".join(f"{b['path']} {b['reason']}" for b in merged.blocking))
    if regen and stack.included:
        regenerate(repo, stack)
    stack.head = repo.text("rev-parse", "HEAD")
    return stack


# --- validation ---------------------------------------------------------------


CHECKS_FAILED_HEADER = re.compile(r"Z ### \d+ cmux-next check\(s\) failed\s*$")
CHECKS_FAILED_ITEM = re.compile(r"Z - (.+) \(([a-z_ ]+)\)\s*$")


def red_subchecks(log: str) -> list[str]:
    """The checks CHECKS_JOB's last step names as red (`- name (outcome)`
    under its `### N cmux-next check(s) failed` header)."""
    names, listing = [], False
    for line in log.splitlines():
        if CHECKS_FAILED_HEADER.search(line):
            listing, names = True, []
            continue
        if listing:
            found = CHECKS_FAILED_ITEM.search(line)
            if found:
                names.append(found.group(1))
            elif names:
                listing = False
    return names


@dataclass
class Validation:
    name: str
    stack: Stack
    branch: str = ""
    heavy_url: str = ""
    heavy_failed: list[str] = field(default_factory=list)
    heavy_passed: list[str] = field(default_factory=list)
    inherited: list[str] = field(default_factory=list)
    rerun: bool = False
    build: dict = field(default_factory=dict)
    seconds: int = 0
    # A group's extra lanes ("web", "tour") -> "passed", "failed: ..." or "did not run: ...".
    group: str | None = None
    lanes: dict[str, str] = field(default_factory=dict)
    plan: Any = None

    @property
    def green(self) -> bool:
        return (not self.stack.error and not self.heavy_failed and bool(self.build.get("ok"))
                and all(result == "passed" for result in self.lanes.values()))

    @property
    def lane_failed(self) -> bool:
        """A lane ran and failed (a PR's fault); one that did not run blames nobody."""
        return any(result.startswith("failed") for result in self.lanes.values())

    def failures(self) -> list[str]:
        out = []
        if self.stack.error:
            out.append(self.stack.error)
        out += [f"`{job}`" for job in self.heavy_failed]
        out += [f"{lane}: {result}" for lane, result in sorted(self.lanes.items()) if result != "passed"]
        if not self.build.get("ok"):
            out.append("fleet build: " + str(self.build.get("error") or "did not complete"))
        return out


class OwnerPushed(Exception):
    """The PR's branch moved while the queue formatted it."""


class Controller:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.gh = GitHub(args.repo)
        self.server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
        self.local = bool(getattr(args, "local", False))
        if self.local:
            # No Actions run to link: comments point at the sticky report.
            sticky = os.environ.get("CMUX_NEXT_BATCH_STICKY", "")
            repo, _, number = sticky.partition("#")
            self.run_url = f"{self.server}/{repo}/issues/{number}" if number else \
                f"{self.server}/{args.repo}/blob/{BASE}/docs/ci/cmux-next-batch.md"
            self.batch_id = "local-" + now().strftime("%Y%m%d-%H%M%S")
        else:
            self.run_url = os.environ.get("NEXT_BATCH_RUN_URL") or \
                f"{self.server}/{args.repo}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '0')}"
            self.batch_id = f"{os.environ.get('GITHUB_RUN_ID', 'local')}-{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"
        # Pushes and merges use the App token when the workflow minted one.
        self.writer = GitHub(args.repo, token_env="PUSH_TOKEN") if os.environ.get("PUSH_TOKEN") else self.gh
        self.worktree = Path(args.worktree)
        self.validations: list[Validation] = []
        self.timings: dict[str, int] = {}
        self.started = time.monotonic()
        self.base_failures: set[str] | None = None
        self.base_sha = ""
        # The base itself, validated on its own next-batch branch alongside the
        # first stack: base pushes skip CHECKS_JOB, and base dispatches (DEV
        # daily, same-tree) route jobs away, so neither records what a stack
        # would find red on the base.
        self.base_probe: threading.Thread | None = None
        self.base_probe_result: dict = {}
        self.base_probe_stop = threading.Event()
        self.base_tree_waited = False

    # git in the trusted checkout. The token goes on the command line of this
    # process only, never into .git/config, which the generators could read.
    def git(self, *args: str, cwd: Path | None = None) -> str:
        auth = []
        if token := os.environ.get("PUSH_TOKEN") or os.environ.get("GH_TOKEN"):
            basic = __import__("base64").b64encode(f"x-access-token:{token}".encode()).decode()
            auth = ["-c", f"http.{self.server}/.extraheader=AUTHORIZATION: basic {basic}"]
        completed = subprocess.run(["git", *auth, *args], cwd=cwd or TOOLS_ROOT, capture_output=True, text=True)
        if completed.returncode != 0:
            raise RuntimeError(f"git {' '.join(args[:2])} failed: {completed.stderr.strip()[-400:]}")
        return completed.stdout.strip()

    def fetch(self, prs: list[PullRequest]) -> str:
        refspecs = [f"+refs/heads/{BASE}:refs/remotes/origin/{BASE}"]
        refspecs += [f"+refs/pull/{pr.number}/head:refs/next-batch/pr/{pr.number}" for pr in prs]
        self.git("fetch", "--quiet", "--no-tags", "origin", *refspecs)
        return self.git("rev-parse", f"refs/remotes/origin/{BASE}")

    def push(self, sha: str, ref: str) -> None:
        """Point refs/heads/`ref` at `sha`, created first at the batch's base.

        GitHub checks a job-token push for workflow changes. A new branch is
        compared with the default branch (main), which differs from
        feat-cmux-next in many workflows, and the push is refused. Created at
        the base through the API and then fast-forwarded, the push carries
        only the stacked PRs' changes. A local controller's login has the
        workflow scope and pushes directly, so no base push starts CI.
        """
        if self.base_sha and not self.local:
            exists = self.writer.gh("api", f"repos/{self.args.repo}/git/ref/heads/{ref}", check=False).returncode == 0
            if exists:
                self.writer.api(f"repos/{self.args.repo}/git/refs/heads/{ref}", method="PATCH",
                            body={"sha": self.base_sha, "force": True})
            else:
                self.writer.api(f"repos/{self.args.repo}/git/refs", method="POST",
                            body={"ref": f"refs/heads/{ref}", "sha": self.base_sha})
        self.git("push", "--quiet", "--force", "origin", f"{sha}:refs/heads/{ref}")

    def delete_branch(self, ref: str) -> None:
        try:
            self.git("push", "--quiet", "origin", f":refs/heads/{ref}")
        except RuntimeError as error:
            log(f"could not delete {ref}: {error}")

    # -- waiting on dispatched runs
    def find_run(self, workflow: str, branch: str, match: Callable[[dict], bool], since: dt.datetime,
                 timeout: int = 600) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            time.sleep(15)
            runs = self.gh.runs(workflow, f"event=workflow_dispatch&branch={branch}&per_page=30")
            for run in runs:
                if match(run) and parse_time(run["created_at"]) >= since - dt.timedelta(seconds=60):
                    return run
            if time.monotonic() > deadline:
                raise RuntimeError(f"{workflow} never started on {branch}")

    def wait_run(self, run_id: int, timeout: int) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            run = self.gh.api(f"repos/{self.args.repo}/actions/runs/{run_id}")
            if run["status"] == "completed":
                return run
            if time.monotonic() > deadline:
                return run
            time.sleep(POLL_SECONDS)

    def passed_heavy_jobs(self, run_id: int) -> list[str]:
        """Heavy-tier jobs that ran and passed. A dispatch on a ref whose
        cmux-next.yml predates the next-batch gate skips them all."""
        jobs = self.gh.api(f"repos/{self.args.repo}/actions/runs/{run_id}/jobs?per_page=100&filter=latest")["jobs"]
        return sorted({job["name"] for job in jobs
                       if job.get("conclusion") == "success" and any(job["name"].endswith(name) for name in HEAVY_CHECKS)})

    def failed_jobs(self, run_id: int, reds: frozenset[str] = RED, detail: bool = False) -> list[str]:
        """Red jobs, with CHECKS_JOB as `CHECKS_JOB: <check>` for each red check in it.

        `detail` (comparing with the base) splits every other red job too, into
        `<job>: step <name>`, `<job>: test <name>` and, when no test failed,
        `<job>: error <line>`: a job red on the base then excuses only the same
        failures, never a stack that breaks another test in it."""
        jobs = self.gh.api(f"repos/{self.args.repo}/actions/runs/{run_id}/jobs?per_page=100&filter=latest")["jobs"]
        failed: set[str] = set()
        for job in jobs:
            if (job.get("conclusion") or "") in reds:
                failed |= self.expand_job(job["name"], job["id"], job if detail else None)
        return sorted(failed)

    def job_log(self, job_id: int | str) -> str | None:
        # The job's log, readable while the rest of its run still goes. The classifier
        # strips ANSI in Python; use its compatible flag-first request here too.
        route = f"repos/{self.args.repo}/actions/jobs/{job_id}/logs"
        got = self.gh.gh("api", base_red_excuse.ESCAPE_FLAG, route, check=False)
        if got.returncode != 0 and base_red_excuse.escape_flag_unknown(got.stderr):
            got = self.gh.gh("api", route, check=False)
        return got.stdout if got.returncode == 0 else None

    def expand_job(self, name: str, job_id: int | str, job: dict | None = None) -> set[str]:
        if name.endswith(CHECKS_JOB):
            log = self.job_log(job_id) or ""
            return {f"{name}: {check}" for check in red_subchecks(log)} or {name}
        if job is None:
            return {name}
        log = self.job_log(job_id)
        if log is None or not log.strip():
            # A test job's unreadable or empty log: nothing can show it is the base's, so it is this job's
            # own (fails closed). Any other job keeps its bare name, as before.
            if (base_red_excuse.test_reds.is_test_red(base_red_excuse.test_reds.Result(), name)
                    or name in base_red_excuse.NO_VERDICT_JOBS):
                return {f"{name}: log unreadable (job {job_id}, never a base red)"}
            return {name}
        if base_red_excuse.no_verdict(log) is not None:
            # A compile check with no verdict compiled nothing: keyed by this job's id, it is never the base's.
            return {f"{name}: no compile verdict (job {job_id}, never a base red)"}
        steps, tests, errors = base_red_excuse.signature(job, log)
        # A crash or a run cut short is never the base's (scripts/ci/test_reds.py): keyed by
        # this job's id, no base failure can match it, whatever the base shows.
        own = base_red_excuse.test_reds.read(log)
        if own.crashes or own.truncated:
            return {f"{name}: {why} (job {job_id}, never a base red)" for why in own.crashes + own.truncated[:1]}
        crashes = base_red_excuse.crash_signals(log)  # test_reds covers cut-short evidence; this adds step signals.
        if not tests and not errors and not crashes:
            # Only failed steps (a timeout, unparsed output): nothing to compare, as
            # base_red_excuse.judge refuses. The bare name matches only a base job just as opaque.
            return {name}
        parts = {f"{name}: step {step}" for step in steps} | {f"{name}: test {test}" for test in tests}
        parts |= {f"{name}: crash signal {signal}" for signal in crashes}
        if not tests:
            parts |= {f"{name}: error {error}" for error in errors}
        return parts

    def wait_base_tree(self) -> None:
        """Wait (once a batch) for the base's own cmux-tui artifacts runs.

        A stack that changes no tree input shares the base's tree. Pushed
        while the base still publishes it, the stack branch's artifacts run
        defers to that publisher and cmux-next reads it as never published
        (same-tree cmux-tui red, daemon tests and scheme compile skipped)."""
        if self.base_tree_waited:
            return
        self.base_tree_waited = True
        try:
            runs = self.gh.runs(TUI_WORKFLOW, f"head_sha={self.base_sha}&per_page=10")
        except RuntimeError as error:
            log(f"could not list the base's cmux-tui runs: {error}")
            return
        deadline = time.monotonic() + 60 * 60  # in all, not per run
        for run in runs:
            left = int(deadline - time.monotonic())
            if run.get("head_branch") == BASE and run.get("status") != "completed" and left > 0:
                log(f"waiting for the base's cmux-tui tree: {run.get('html_url')}")
                try:
                    self.wait_run(run["id"], timeout=left)
                except RuntimeError as error:
                    log(f"could not wait for the base's cmux-tui run: {error}")
                    return

    def start_base_probe(self) -> None:
        if self.base_probe is None:
            # The batch's first base keeps the plain -base branch; a later one (reset_base) gets its own.
            self.first_base = getattr(self, "first_base", "") or self.base_sha
            # The probe keeps its own base, result and stop: reset_base swaps
            # the controller's while an old probe may still be finishing.
            self.base_probe = threading.Thread(
                target=self.probe_base, args=(self.base_sha, self.base_probe_result, self.base_probe_stop),
                name="base-probe", daemon=True)
            self.base_probe.start()

    def probe_base(self, sha: str | None = None, result: dict | None = None,
                   stop: threading.Event | None = None) -> None:
        """Run every cmux-next tier on the base head, the way a stack runs them,
        with one rerun of failed jobs. Its failures are the batch's inherited reds."""
        sha = sha or self.base_sha
        result = self.base_probe_result if result is None else result
        stop = self.base_probe_stop if stop is None else stop
        branch = f"{BRANCH_PREFIX}{self.batch_id}-base" + ("" if sha == getattr(self, "first_base", sha) else f"-{sha[:12]}")
        try:
            self.push(sha, branch)
            result["branch"] = branch
            dispatched = now()
            self.gh.dispatch(HEAVY_WORKFLOW, branch)
            heavy = self.find_run(HEAVY_WORKFLOW, branch, lambda item: item["head_sha"] == sha, dispatched)
            result["url"] = heavy["html_url"]
            result["run"] = heavy["id"]
            log(f"base probe: {heavy['html_url']}")
            if stop.is_set():
                # The batch ended while this looked for its run: stop_base_probe had no run to cancel.
                self.gh.gh("run", "cancel", str(heavy["id"]), "-R", self.args.repo, check=False)
                if not getattr(self.args, "keep_branches", False):
                    self.delete_branch(branch)
                return
            run = self.wait_run(heavy["id"], timeout=180 * 60)
            if run["status"] != "completed":
                raise RuntimeError("the base probe did not finish")
            failed = self.failed_jobs(heavy["id"], detail=True)
            if stop.is_set() or run.get("conclusion") == "cancelled":
                return  # the batch ended and cancelled it: no rerun, no result
            if failed:
                self.gh.gh("run", "rerun", str(heavy["id"]), "--failed", "-R", self.args.repo, check=False)
                time.sleep(30)
                if self.wait_run(heavy["id"], timeout=120 * 60)["status"] != "completed":
                    # The first attempt's list still holds its flakes: record nothing (push-run fallback).
                    log("base probe: its rerun did not finish; no result")
                    return
                failed = self.failed_jobs(heavy["id"], detail=True)
            if stop.is_set():
                return  # the base was dropped meanwhile: its reds are no one's now
            result["failed"] = set(failed)
            log("base probe: " + (", ".join(failed) or "green"))
        except Exception as error:  # the base runs' own record is the fallback
            log(f"base probe: {type(error).__name__}: {error}")

    def failing_on_base(self, base_sha: str) -> set[str]:
        """Checks already red on the base head (inherited, not the batch's).

        The base probe's reds when it finished in time. Otherwise the jobs that
        failed outright in the base's newest completed push run: a cancelled
        job there was superseded by a newer push, not red, and dispatches at
        the base sha (same-tree, DEV daily) may test something else.
        """
        if self.base_failures is not None:
            return self.base_failures
        if self.base_probe is not None:
            self.base_probe.join(timeout=BASE_PROBE_GRACE)
        if "failed" in self.base_probe_result:
            self.base_failures = set(self.base_probe_result["failed"])
            return self.base_failures
        log("base probe gave no result; falling back to the base's push run")
        runs = self.gh.runs(HEAVY_WORKFLOW, f"head_sha={base_sha}&event=push&per_page=10")
        done = [run for run in runs if run["status"] == "completed" and run["head_branch"] == BASE]
        self.base_failures = set(self.failed_jobs(done[0]["id"], OUTRIGHT_RED, detail=True)) if done else set()
        # The base tier's jobs fall back to its newest run only where the base's own push run gave them no
        # verdict: with coalescing off, or a push that kept its scheme compile, the exact base decides.
        judged = self.judged_jobs(done[0]["id"]) if done else set()
        self.base_failures |= {red for red in self.base_tier_failures() if red.split(":", 1)[0] not in judged}
        return self.base_failures

    def judged_jobs(self, run_id: int) -> set[str]:
        """The jobs of a run that ended with a verdict (passed or failed outright)."""
        jobs = self.gh.api(f"repos/{self.args.repo}/actions/runs/{run_id}/jobs?per_page=100&filter=latest")["jobs"]
        return {job["name"] for job in jobs if (job.get("conclusion") or "") in OUTRIGHT_RED | {"success"}}

    def base_tier_failures(self) -> set[str]:
        """Outright reds of the base's newest base tier verdict for each of its jobs (cmuxterm-hq#5424).

        A feat-cmux-next push leaves daemon tests, generated files and the Debug scheme compile to
        a `cmux-next base tier · <sha>` dispatch at most every 15 minutes, so the base's push run has
        no verdict for them. For each job, the newest completed base tier run that ran it to a verdict
        (passed or failed outright) stands in, named with its commit and age. A run that skipped the
        job (its cmux-tui tree was not published yet, so its same-tree run carries it) is passed over
        for that job, so it never hides an older red. A red the base head fixed shows as inherited.
        """
        runs = self.gh.runs(HEAVY_WORKFLOW, f"branch={BASE}&event=workflow_dispatch&status=completed&per_page=50")
        # A cancelled base tier run (the kick cancels superseded ones before a Mac job starts) has no verdict:
        # it never counts toward the lookback.
        tiers = [run for run in runs if (run.get("display_title") or "").startswith(BASE_TIER_TITLE)
                 and run.get("conclusion") not in ("skipped", "cancelled")][:BASE_TIER_LOOKBACK]
        failed: set[str] = set()
        pending = set(BASE_TIER_JOBS)
        for tier in tiers:
            jobs = self.gh.api(f"repos/{self.args.repo}/actions/runs/{tier['id']}/jobs?per_page=100&filter=latest")["jobs"]
            tested = tier["display_title"][len(BASE_TIER_TITLE):]
            for job in jobs:
                name, conclusion = job.get("name") or "", job.get("conclusion") or ""
                if name not in pending or conclusion not in OUTRIGHT_RED | {"success"}:
                    continue
                pending.discard(name)
                reds = self.expand_job(name, job["id"], job) if conclusion in OUTRIGHT_RED else set()
                failed |= reds
                log(f"base tier verdict for {name} from {tier.get('html_url') or tier['id']} at {tested[:12]} "
                    f"(created {tier.get('created_at', '?')}; the newest for it, not necessarily the base head): "
                    f"{', '.join(sorted(reds)) or 'passed'}")
            if not pending:
                break
        if pending:
            log(f"no base tier verdict in the newest {len(tiers)} base tier runs for: {', '.join(sorted(pending))}")
        return failed

    def stop_base_probe(self) -> None:
        """A batch that ends before its probe does cancels the probe's run."""
        self.base_probe_stop.set()
        if self.base_probe is not None and self.base_probe.is_alive() and self.base_probe_result.get("run"):
            self.gh.gh("run", "cancel", str(self.base_probe_result["run"]), "-R", self.args.repo, check=False)

    def mini(self, mode: str, branch: str, sha: str, extra: dict[str, str]) -> tuple[dict, dict]:
        """`mini_once`, dispatched once more when the job wrote no result.

        A runner can refuse a job at setup (its host is busy with a fleet
        build); that says nothing about the stack.
        """
        run, result = self.mini_once(mode, branch, sha, extra)
        if result.get("no_result"):
            log(f"{mode}: no result from {result.get('run')}; dispatching once more")
            run, result = self.mini_once(mode, branch, sha, extra)
        return run, result

    def mini_once(self, mode: str, branch: str, sha: str, extra: dict[str, str]) -> tuple[dict, dict]:
        """Dispatch the mini job of this workflow and return (run, result.json)."""
        since = now()
        nonce = f"{self.batch_id}-{mode}-{sha[:12]}-{int(time.time())}"
        self.gh.dispatch(WORKFLOW, self.args.ref, {"mode": mode, "branch": branch, "sha": sha, "nonce": nonce, **extra})
        run = self.find_run(WORKFLOW, self.args.ref, lambda item: item.get("display_title") == f"{mode} {nonce}", since)
        run = self.wait_run(run["id"], timeout=150 * 60)
        result: dict = {"ok": False, "error": f"mini run {run.get('conclusion') or run['status']}",
                        "run": run["html_url"], "no_result": True}
        with tempfile.TemporaryDirectory() as tmp:
            got = self.gh.gh("run", "download", str(run["id"]), "-R", self.args.repo,
                             "-n", f"next-batch-{mode}", "-D", tmp, check=False)
            path = Path(tmp) / "result.json"
            if got.returncode == 0 and path.is_file():
                result = {**json.loads(path.read_text()), "run": run["html_url"]}
            patch = Path(tmp) / "regen.patch"
            if result.get("ok") and patch.is_file() and patch.stat().st_size:
                result["patch"] = patch.read_bytes()
        return run, result

    def regenerate_remote(self, stack: Stack, branch: str) -> bool:
        """Rebuild conflicted generated files on runners, from the pushed stack.

        Web bundles and SDK bindings on Linux, then the Swift exports on a
        mini. Each job commits its output and sends it back as a patch, which
        lands on the stack here and is pushed before the next job.
        """
        steps = []
        if linux := sorted(stack.regen & {"web", "sdk"}):
            steps.append(("regen-linux", " ".join(linux)))
        if "swift" in stack.regen:
            steps.append(("regen", "swift"))
        for mode, kinds in steps:
            _, result = self.mini(mode, branch, stack.head, {"kinds": kinds})
            if not result.get("ok"):
                stack.error = f"regenerating {kinds} failed: {result.get('error')}"
                return False
            if patch := result.get("patch"):
                completed = subprocess.run(["git", "am", "--quiet", "--keep-cr"], cwd=self.worktree,
                                           input=patch, capture_output=True)
                if completed.returncode != 0:
                    subprocess.run(["git", "am", "--abort"], cwd=self.worktree, capture_output=True)
                    stack.error = f"the {kinds} patch did not apply: {completed.stderr.decode(errors='replace')[-400:]}"
                    return False
                stack.head = self.git("rev-parse", "HEAD", cwd=self.worktree)
                self.git("push", "--quiet", "origin", f"{stack.head}:refs/heads/{branch}")
                stack.regenerated.append(kinds)
        return True

    def format_pr(self, pr: PullRequest, branch: str) -> str:
        """Run the web formatter and lint autofix on the PR's head on a
        runner, and push the fix to the PR's branch. Returns the new head, or
        "" when there was nothing to fix. A push the owner raced fails, and
        the PR waits for the next batch."""
        _, result = self.mini("regen-linux", branch, pr.sha, {"kinds": "format"})
        if not result.get("ok"):
            raise RuntimeError(f"formatting #{pr.number} failed: {result.get('error')}")
        patch = result.get("patch")
        if not patch:
            return ""
        with tempfile.TemporaryDirectory() as tmp:
            checkout = Path(tmp) / "pr"
            self.git("worktree", "add", "--quiet", "--detach", str(checkout), pr.sha)
            try:
                completed = subprocess.run(["git", "am", "--quiet", "--keep-cr"], cwd=checkout,
                                           input=patch, capture_output=True)
                if completed.returncode != 0:
                    raise RuntimeError(f"the format patch for #{pr.number} did not apply: "
                                       f"{completed.stderr.decode(errors='replace')[-300:]}")
                sha = self.git("rev-parse", "HEAD", cwd=checkout)
            finally:
                self.git("worktree", "remove", "--force", str(checkout))
        try:
            self.git("push", "--quiet", "origin", f"{sha}:refs/heads/{pr.head_ref}")
        except RuntimeError as error:
            if "non-fast-forward" in str(error) or "rejected" in str(error):
                raise OwnerPushed(f"#{pr.number}") from error
            raise
        log(f"#{pr.number}: pushed formatting {sha[:12]}")
        return sha

    def fleet_build(self, branch: str, sha: str, tag: str) -> dict:
        """A fleet --production build of `sha`: from a mini, or with this
        host's cmux-ci when it serves locally (it is on the tailnet)."""
        if not self.local:
            return self.mini("build", branch, sha, {"tag": tag})[1]
        started = time.monotonic()

        def cmux_ci(*args: str) -> subprocess.CompletedProcess:
            return subprocess.run(["cmux-ci", *args], capture_output=True, text=True)

        with tempfile.TemporaryDirectory() as tmp:
            receipt = Path(tmp) / "submit.json"
            submitted = cmux_ci("build", "cmux", "--ref", sha, "--tag", tag,
                                "--workspace", f"{self.server}/{self.args.repo}/tree/{branch}",
                                "--production", "--agent", "cmux-next-batch",
                                "--receipt", str(receipt))
            try:
                job = str(json.loads(receipt.read_text())["id"])
            except (OSError, ValueError, KeyError):
                return {"ok": False, "error": "fleet submission failed: " + (submitted.stderr or submitted.stdout)[-300:]}
        log(f"fleet job {job}")
        if cmux_ci("wait", job, "--interval", "30", "--timeout", "7800").returncode != 0:
            return {"ok": False, "job_id": job, "error": f"fleet job {job} did not succeed (cmux-ci log {job})"}
        link = f"cmux-ci artifact {job}"
        published = cmux_ci("publish-hq", job)
        if published.returncode == 0 and published.stdout.strip():
            try:
                link = json.loads(published.stdout.strip().splitlines()[-1]).get("url") or link
            except ValueError:
                pass
        return {"ok": True, "job_id": job, "tag": tag, "link": f"{link} (job {job}, tag {tag})",
                "seconds": int(time.monotonic() - started)}

    def validate(self, prs: list[PullRequest], name: str, group: str | None = None) -> Validation:
        """Stack `prs` on the batch's base and run every tier plus the fleet build.

        The base is fixed at the batch's first fetch, so bisect probes and
        reruns compare against the same feat-cmux-next commit.
        """
        started = time.monotonic()
        fetched = self.fetch(prs)
        self.base_sha = self.base_sha or fetched
        base_sha = self.base_sha
        stack = build_stack(self.worktree, base_sha, prs, regen=False)
        validation = Validation(name=name, stack=stack, group=group)
        self.validations.append(validation)
        if not stack.included or stack.error:
            validation.seconds = int(time.monotonic() - started)
            return validation
        self.wait_base_tree()
        self.start_base_probe()
        branch = f"{BRANCH_PREFIX}{self.batch_id}-{len(self.validations)}"
        validation.branch = branch
        self.push(stack.head, branch)
        log(f"{name}: pushed {branch} at {stack.head[:12]} ({len(stack.included)} PRs)")
        if stack.regen and not self.regenerate_remote(stack, branch):
            validation.seconds = int(time.monotonic() - started)
            return validation
        sha = stack.head
        changed = self.git("diff", "--name-only", base_sha, sha).splitlines()
        tree = touches_tree(changed, self.worktree)
        if tree:
            log(f"{name}: no helper publisher ref; the fleet build bundles its own daemon")
        dispatched = now()
        self.gh.dispatch(HEAVY_WORKFLOW, branch)
        heavy = self.find_run(HEAVY_WORKFLOW, branch, lambda item: item["head_sha"] == sha, dispatched)
        validation.heavy_url = heavy["html_url"]
        log(f"{name}: heavy tier {heavy['html_url']}")
        lane_runs = self.start_group_lanes(validation, branch, base_sha, sha) if group else {}
        validation.build = self.fleet_build(branch, sha, f"nb-{self.batch_id}-{len(self.validations)}")
        log(f"{name}: fleet build " + ("ok" if validation.build.get("ok") else f"failed: {validation.build.get('error')}"))
        run = self.wait_run(heavy["id"], timeout=180 * 60)
        failed = self.failed_jobs(heavy["id"], detail=True) if run["status"] == "completed" else ["(timed out waiting)"]
        if failed and run["status"] == "completed" and not validation.rerun:
            # One rerun of the failed jobs before blaming a PR: flakes are not culprits.
            validation.rerun = True
            self.gh.gh("run", "rerun", str(heavy["id"]), "--failed", "-R", self.args.repo, check=False)
            time.sleep(30)
            run = self.wait_run(heavy["id"], timeout=120 * 60)
            failed = self.failed_jobs(heavy["id"], detail=True)
        inherited = self.failing_on_base(base_sha) if failed else set()
        validation.inherited = sorted(set(failed) & inherited)
        validation.heavy_failed = sorted(set(failed) - inherited)
        if run["status"] == "completed":
            validation.heavy_passed = self.passed_heavy_jobs(heavy["id"])
        if lane_runs:
            self.finish_group_lanes(validation, lane_runs)
        validation.seconds = int(time.monotonic() - started)
        log(f"{name}: {'green' if validation.green else 'red'} in {validation.seconds}s")
        return validation

    # -- a group's extra lanes (docs/ci/cmux-next-batch.md#groups)
    def start_group_lanes(self, validation: Validation, branch: str, base_sha: str, sha: str) -> dict[str, dict]:
        """Dispatch the lanes the members' paths route to beyond the heavy tier
        (which a dispatch runs whole, a superset of every member's tiers): the
        web checks, and the media tour with the union of the members' tours
        (it maps the combined diff from `base_sha`)."""
        plan = groups.check_plan(TOOLS_ROOT, {pr.number: self.member_files(pr, base_sha)
                                              for pr in validation.stack.included},
                                 {pr.number: pr.labels for pr in validation.stack.included})
        validation.plan = plan
        runs: dict[str, dict] = {}
        for lane in plan.lanes():
            workflow, inputs = (WEB_WORKFLOW, None) if lane == "web" else (MEDIA_WORKFLOW, {"base_sha": base_sha})
            since = now()
            try:
                self.gh.dispatch(workflow, branch, inputs)
                runs[lane] = self.find_run(workflow, branch, lambda item: item["head_sha"] == sha, since)
                log(f"{validation.name}: {lane} {runs[lane]['html_url']}")
            except RuntimeError as error:
                validation.lanes[lane] = f"did not run: {error}"
        return runs

    def member_files(self, pr: PullRequest, base_sha: str) -> list[str]:
        """Every file the member changes since the stack's base. `pr.files`
        stops at 100, which could drop a lane a large member routes to."""
        return self.git("diff", "--name-only", f"{base_sha}...{pr.sha}", cwd=self.worktree).splitlines()

    def finish_group_lanes(self, validation: Validation, runs: dict[str, dict]) -> None:
        for lane, started in runs.items():
            try:
                run = self.wait_run(started["id"], timeout=150 * 60)
            except RuntimeError as error:
                validation.lanes[lane] = f"did not run: {error}"
                continue
            if run["status"] != "completed":
                validation.lanes[lane] = "did not run: timed out waiting"
            elif lane == "web":
                validation.lanes[lane] = self.judge_web(run, validation.stack.base)
            else:
                jobs = self.gh.api(f"repos/{self.args.repo}/actions/runs/{run['id']}/jobs?per_page=100&filter=latest")["jobs"]
                tour = next((job.get("conclusion") or "" for job in jobs if job["name"] == TOUR_JOB), "skipped")
                validation.lanes[lane] = self.judge_tour(run, self.capture_receipt(run["id"]), tour)

    def judge_web(self, run: dict, base_sha: str) -> str:
        """Web jobs red on the combined head and not on the base's own web run
        (at `base_sha`, else the newest one on an ancestor of it). A run that
        failed with no failed job (cancelled, startup failure) blames nobody."""
        if run.get("conclusion") == "success":
            return "passed"
        failed = set(self.failed_jobs(run["id"], detail=True))
        if not failed:
            return f"did not run: web run {run.get('conclusion')}"

        def finished(items: list[dict]) -> list[dict]:
            return [item for item in items if item.get("head_branch") == BASE and item.get("status") == "completed"]

        base = finished(self.gh.runs(WEB_WORKFLOW, f"head_sha={base_sha}&per_page=20"))
        if not base:
            base = [item for item in finished(self.gh.runs(WEB_WORKFLOW, f"branch={BASE}&per_page=20"))
                    if self.is_ancestor(item["head_sha"], base_sha)][:1]
        inherited = set(self.failed_jobs(base[0]["id"], detail=True)) if base else set()
        new = sorted(failed - inherited)
        return "passed" if not new else "failed: " + ", ".join(new)

    def judge_tour(self, run: dict, receipt: dict | None, tour_job: str) -> str:
        """The tour's verdict lives in its capture receipt: capture is
        continue-on-error, so the job stays green when the recorder fails. A
        tour job that failed before the recorder did (the base app's build,
        setup, a timeout) says nothing about the members."""
        if tour_job == "skipped":
            return "did not run: no owned gui runner took the tour"
        status = (receipt or {}).get("status")
        if status == "recorder-failed":
            return "failed: recorder-failed"
        if tour_job != "success" or run.get("conclusion") not in ("success", None):
            return f"did not run: tour job {tour_job or run.get('conclusion')} before a capture verdict"
        if receipt is None:
            return "failed: no capture receipt"
        return "passed" if status in ("ok", "no-ui-paths") else f"failed: {status}"

    def capture_receipt(self, run_id: int) -> dict | None:
        with tempfile.TemporaryDirectory() as tmp:
            got = self.gh.gh("run", "download", str(run_id), "-R", self.args.repo, "-n", "cmux-next-media",
                             "-D", tmp, check=False)
            path = Path(tmp) / "capture-receipt.json"
            if got.returncode != 0 or not path.is_file():
                return None
            try:
                return json.loads(path.read_text())
            except ValueError:
                return None

    # -- bisect
    def bisect(self, red: Validation) -> PullRequest:
        """Smallest red prefix of the stack: its last PR is the culprit."""
        prs = red.stack.included
        low, high = 0, len(prs)  # prefix[:low] green (the base), prefix[:high] red
        while high - low > 1:
            middle = (low + high) // 2
            extra = {"group": red.group} if red.group else {}
            probe = self.validate(prs[:middle], f"bisect {middle}/{len(prs)}", **extra)
            if probe.green:
                low = middle
            else:
                high = middle
        return prs[high - 1]

    # -- comments
    def reported(self, pr: PullRequest, kinds: tuple[str, ...]) -> str:
        bodies = [comment.get("body") or "" for comment in self.gh.comments(pr.number)]
        return next((kind for kind in kinds
                     if any(COMMENT_MARKER.format(kind=kind, sha=pr.sha) in body for body in bodies)), "")

    def comment_once(self, pr: PullRequest, kind: str, body: str) -> None:
        marker = COMMENT_MARKER.format(kind=kind, sha=pr.sha)
        if any(marker in (comment.get("body") or "") for comment in self.gh.comments(pr.number)):
            return
        if self.args.dry_run:
            log(f"dry run: would comment on #{pr.number}: {body.splitlines()[0]}")
            return
        self.gh.comment(pr.number, f"{marker}\n{body}")

    def report_drop(self, pr: PullRequest, blocking: list[dict[str, str]]) -> None:
        lines = "\n".join(f"- `{item['path']}`: {item['reason']}" if item["path"] else f"- {item['reason']}"
                          for item in blocking)
        self.comment_once(pr, "conflict", (
            f"Batch queue: dropped from [this batch]({self.run_url}), conflict.\n\n{lines}\n\n"
            "Next: merge feat-cmux-next, resolve, push."))

    def report_culprit(self, pr: PullRequest, red: Validation, prefix: Validation | None) -> None:
        evidence = prefix or red
        failing = "\n".join(f"- {item}" for item in evidence.failures())
        runs = f"[heavy tier]({evidence.heavy_url})" if evidence.heavy_url else "the stack"
        self.comment_once(pr, "culprit", (
            f"Batch queue: dropped from [this batch]({self.run_url}), turns {runs} red.\n\n"
            f"{failing}\n\nNext: fix, push."))

    # -- landing
    def land(self, validation: Validation) -> list[tuple[PullRequest, str]]:
        landed = []
        fresh = {pr.number: pr for pr in open_prs(self.gh, fresh=True)}
        landing = getattr(self.args, "land", True) and not self.args.dry_run and not self.args.no_land
        stop = 0
        for pr in validation.stack.included:
            # Only a prefix of the validated stack may land: once one PR doesn't, a
            # later one would land on a tree that was never validated.
            if landing and landed and not landed[-1][1].startswith("landed"):
                stop = stop or landed[-1][0].number
            if stop:
                landed.append((pr, f"skipped: an earlier PR in this stack (#{stop}) didn't land; next batch"))
                continue
            current = fresh.get(pr.number)
            if current is None:
                landed.append((pr, "closed meanwhile"))
                continue
            if current.sha != pr.sha:
                landed.append((pr, "skipped: pushed after validation; next batch"))
                continue
            if reason := ineligible_reason(current, now()):
                landed.append((pr, f"skipped: {reason}"))
                continue
            if self.args.dry_run or self.args.no_land:
                landed.append((pr, "validated; landing disabled for this run"))
                continue
            # Formatting pushes go only to batch authors' branches; another
            # author's opted-in PR keeps its branch to itself.
            if red_format_checks(current) and current.author in batch_authors():
                try:
                    if self.format_pr(current, validation.branch):
                        self.comment_once(pr, "formatted", (
                            "Batch queue: pushed `bun run check:fix` output (web formatting and lint "
                            "autofix) to this branch. That's a new head: it lands in a later batch "
                            "once its checks rerun and it's reviewed."))
                        landed.append((pr, "formatted; a later batch lands the new head once reviewed"))
                        continue
                except OwnerPushed:
                    landed.append((pr, "skipped: pushed while formatting; next batch"))
                    continue
                except RuntimeError as error:
                    landed.append((pr, f"not landed: {error}"))
                    continue
            if not getattr(self.args, "land", True) or landing_refusal() or not reviewed(current, self.gh):
                # A "receipt" tells later batches the owner lands this head, so only a
                # receipt-only queue posts one. A batch that may not land, or a head
                # still waiting for review, leaves a "validated" note that holds nothing out.
                kind = "receipt" if not getattr(self.args, "land", True) else "validated"
                self.comment_once(pr, kind, self.receipt(validation, pr))
                why = ("receipt posted; owner lands" if not getattr(self.args, "land", True) else
                       f"not landed: {landing_refusal()}; receipt posted" if landing_refusal() else
                       "not reviewed at this head; receipt posted")
                landed.append((pr, why))
                log(f"#{pr.number}: {why}")
                continue
            self.comment_once(pr, "landing", (
                f"Batch queue: landing. [Batch]({self.run_url}), stack `{validation.stack.head[:12]}` "
                f"on `{validation.stack.base[:12]}`, [heavy tier]({validation.heavy_url}), "
                f"build: {validation.build.get('link', 'n/a')}."))
            outcome = self.merge_one(pr, validation)
            landed.append((pr, outcome))
            if "GitHub refused to merge" in outcome:
                self.comment_once(pr, "refused", (
                    "Batch queue: [batch]({run}) green, GitHub merge refused.\n\n"
                    "Next: merge feat-cmux-next, run `scripts/cmux-next/regenerate-web-bundles.sh`, push."
                ).format(run=self.run_url))
            log(f"#{pr.number}: {outcome}")
        return landed

    def receipt(self, validation: Validation, pr: PullRequest) -> str:
        stack = validation.stack
        heavy = (f"[heavy tier]({validation.heavy_url}) passed: " + ", ".join(f"`{job}`" for job in validation.heavy_passed)
                 if validation.heavy_passed else
                 f"heavy tier did not run on this branch ([run]({validation.heavy_url})); your PR's own checks are the tests")
        build = validation.build
        return (f"Batch queue: green. [Batch]({self.run_url}) stack `{stack.head[:12]}` on feat-cmux-next "
                f"`{stack.base[:12]}` with " + " ".join(f"#{item.number}" for item in stack.included) + ". "
                f"Fleet production build: job `{build.get('job_id', 'n/a')}` ({build.get('link', 'n/a')}). "
                f"{heavy}. Validated this PR at `{pr.sha[:12]}`.\n\n"
                "Next: land it yourself on this receipt (`gh pr merge --squash --match-head-commit`).")

    def risk_evidence(self, pr: PullRequest) -> str:
        """Why the head's `risk evidence` doesn't let it land ("" when every run of it passed)."""
        try:
            runs = self.gh.api(f"repos/{self.args.repo}/commits/{pr.sha}/check-runs?check_name=risk%20evidence&per_page=100") or {}
        except RuntimeError as error:
            return f"risk evidence unreadable ({str(error)[-120:]})"
        for run in runs.get("check_runs", []):
            if run.get("status") != "completed" or (run.get("conclusion") or "") not in PASS:
                return "risk evidence has not passed on this head"
        return ""

    def merge_one(self, pr: PullRequest, validation: Validation) -> str:
        """Squash-merge the exact head this batch validated through GitHub's merge API.

        The batch already ran every tier on the stack, so checks aren't re-judged here, except the two the
        stack can't run: a `risk evidence` check on the head must have finished green (an edited description
        regrades it), and the merge freezes are read again, since one may have opened after the PR's own
        check ran. GitHub's default squash body is kept, with every commit's Co-authored-by trailer. A
        transient error (5xx, network, "Base branch was modified") is retried once, after checking whether
        GitHub merged anyway; it never marks the PR refused. A real refusal (the head moved, a conflict)
        does, and the PR waits for a push."""
        if problem := self.risk_evidence(pr):
            return f"not landed: {problem}; the next batch tries again"
        code, detail = freeze_check(self.args.repo, pr.number, getattr(self.gh, "env", None) or dict(os.environ))
        if code == 1:
            return f"not landed: frozen ({detail})"
        if code != 0:
            return f"not landed: the merge freeze state is unreadable ({detail})"
        path = f"repos/{self.args.repo}/pulls/{pr.number}/merge"
        for attempt in (1, 2):
            try:
                self.writer.api(path, method="PUT", body={"sha": pr.sha, "merge_method": "squash"})
                return "landed"
            except RuntimeError as error:
                text = str(error)
                if not TRANSIENT.search(text):
                    return f"not landed: GitHub refused to merge {self.args.repo}#{pr.number}: {text[-200:]}"
                # A timeout can come back after GitHub merged: look before trying again.
                try:
                    state = self.gh.api(f"repos/{self.args.repo}/pulls/{pr.number}") or {}
                except RuntimeError:
                    state = {}
                if state.get("merged") and (state.get("head") or {}).get("sha") == pr.sha:
                    return "landed"
                if attempt == 2:
                    return f"not landed: GitHub was unreachable or busy ({text[-160:]}); the next batch tries again"
                time.sleep(15)
        return "not landed"

    def after_landing(self) -> None:
        """Merges by the job token start no push workflows; start the base ones.

        That includes this workflow's own push trigger, so queue the next
        batch here for whatever is still eligible. A local controller merges
        with the operator's login, whose merges start them, and its serve
        loop picks up the next batch.
        """
        if self.local:
            return
        for ref in dict.fromkeys((BASE, self.args.ref)):
            try:
                self.gh.dispatch(WORKFLOW, ref, {"mode": "batch", "reason": f"after batch {self.batch_id}"})
                break
            except RuntimeError as error:
                log(f"could not queue the next batch on {ref}: {error}")
        for workflow in (HEAVY_WORKFLOW, TUI_WORKFLOW):
            try:
                self.gh.dispatch(workflow, BASE)
            except RuntimeError as error:
                log(f"could not dispatch {workflow} on {BASE}: {error}")

    # -- the sticky report
    def report(self, eligible: list[PullRequest], skipped: dict[int, str],
               landed: list[tuple[PullRequest, str]], culprits: list[PullRequest]) -> str:
        final = self.validations[-1] if self.validations else None
        total = int(time.monotonic() - self.started)
        lines = [f"### cmux-next batch [{self.batch_id}]({self.run_url})", ""]
        if final and final.stack.head:
            build = final.build
            lines.append(f"Stack `{final.stack.head[:12]}` on feat-cmux-next `{final.stack.base[:12]}`. "
                         f"Heavy tier: {final.heavy_url or 'n/a'}. "
                         f"Fleet build: {build.get('link') or build.get('error') or 'n/a'}.")
            lines.append("")
        outcome = {pr.number: text for pr, text in landed}
        for pr in culprits:
            outcome[pr.number] = "dropped: turns the stack red"
        for validation in self.validations:
            for pr, blocking in validation.stack.dropped:
                paths = ", ".join(f"`{item['path']}`" for item in blocking if item["path"])
                outcome.setdefault(pr.number, f"dropped: conflict in {paths}" if paths else "dropped: conflict")
        lines += ["| PR | Title | Result |", "| --- | --- | --- |"]
        for pr in eligible:
            lines.append(f"| #{pr.number} | {pr.title.replace('|', '/')} | {outcome.get(pr.number, 'not reached')} |")
        lines += ["", "| Validation | PRs | Result | Time |", "| --- | --- | --- | --- |"]
        for validation in self.validations:
            result = "green" if validation.green else "red: " + "; ".join(validation.failures())[:300]
            prs = " ".join(f"#{pr.number}" for pr in validation.stack.included)
            lines.append(f"| {validation.name} | {prs} | {result} | {validation.seconds // 60}m{validation.seconds % 60:02d}s |")
        if url := self.base_probe_result.get("url"):
            lines += ["", f"Base probe (feat-cmux-next `{self.base_sha[:12]}` alone): {url}"]
        if final and final.inherited:
            lines += ["", "Red on feat-cmux-next itself (not counted): " + ", ".join(f"`{j}`" for j in final.inherited)]
        if final and final.stack.resolved:
            lines += ["", "Generated conflicts rebuilt: " + ", ".join(
                f"{item['pr']} `{item['path']}`" for item in final.stack.resolved[:20])]
        lines += ["", f"Total {total // 60}m{total % 60:02d}s. Not batched: " + (", ".join(
            f"#{number} ({reason})" for number, reason in sorted(skipped.items())) or "none")]
        return "\n".join(lines)

    def post_sticky(self, text: str) -> None:
        target = os.environ.get("CMUX_NEXT_BATCH_STICKY", "")
        token = os.environ.get("STICKY_TOKEN") or (os.environ.get("GH_TOKEN", "") if self.local else "")
        if not target or not token or self.args.dry_run:
            log("no sticky issue configured or no token for it; the report is in the job summary")
            return
        repo, number = target.split("#")
        sticky = GitHub(repo, token_env="STICKY_TOKEN") if os.environ.get("STICKY_TOKEN") else self.gh
        try:
            comments = sticky.api(f"repos/{repo}/issues/{number}/comments?per_page=100")
            mine = [c for c in comments if STICKY_MARKER in (c.get("body") or "")]
            body = sticky_body(text, mine[-1]["body"] if mine else "")
            if mine:
                sticky.api(f"repos/{repo}/issues/comments/{mine[-1]['id']}", method="PATCH", body={"body": body})
            else:
                sticky.api(f"repos/{repo}/issues/{number}/comments", method="POST", body={"body": body})
        except RuntimeError as error:
            log(f"could not update the sticky issue: {error}")

    # -- groups (docs/ci/cmux-next-batch.md#groups)
    GROUP_QUERY = """pr{n}: pullRequest(number: {n}) {{
      timelineItems(last: 50, itemTypes: [LABELED_EVENT]) {{ nodes {{ ... on LabeledEvent {{ createdAt label {{ name }} }} }} }}
    }}"""

    def group_meta(self, prs: list[PullRequest]) -> dict[int, dict]:
        """Per member: when each label was last put on."""
        owner, name = self.args.repo.split("/")
        body = "\n".join(self.GROUP_QUERY.format(n=int(pr.number)) for pr in prs)
        data = self.gh.graphql(f'query {{ repository(owner: "{owner}", name: "{name}") {{ {body} }} }}')["repository"]
        meta = {}
        for pr in prs:
            node = data.get(f"pr{pr.number}") or {}
            labeled: dict[str, str] = {}
            for event in (node.get("timelineItems") or {}).get("nodes") or []:
                if event and event.get("label"):
                    labeled[event["label"]["name"]] = event["createdAt"]  # the latest application wins
            meta[pr.number] = {"labeled": labeled}
        return meta

    def group_reviews(self, prs: list[PullRequest]) -> dict[int, bool]:
        """The batch's own gate (reviewed()): an independent review of this exact head."""
        return {pr.number: reviewed(pr, self.gh) for pr in prs}

    def frozen(self, pr: PullRequest) -> str:
        """Why a merge freeze holds this PR ("" when none does); unreadable counts as frozen.
        Every member is checked before any lands, so a freeze never splits a group."""
        completed = subprocess.run([sys.executable, "-I", str(TOOLS_ROOT / "scripts/ci/merge_freeze.py"), "check",
                                    "--repo", self.args.repo, "--pr", str(pr.number), "--base", BASE],
                                   capture_output=True, text=True, env=self.gh.env)
        if completed.returncode == 0:
            return ""
        return "frozen: " + ((completed.stdout + completed.stderr).strip().splitlines() or ["freeze state unknown"])[-1]

    def is_ancestor(self, older: str, newer: str) -> bool:
        try:
            self.git("merge-base", "--is-ancestor", older, newer, cwd=self.worktree)
            return True
        except RuntimeError:
            return False

    def current_base(self) -> str:
        return self.fetch([])

    def base_moved_onto(self, old: str, new: str, files: set[str]) -> bool:
        """Whether the base commits since validation touch any file the group changes."""
        changed = set(self.git("diff", "--name-only", old, new, cwd=self.worktree).splitlines())
        return bool(changed & files)

    def fresh_members(self, prs: list[PullRequest]) -> dict[int, PullRequest]:
        return {pr.number: pr for pr in open_prs(self.gh, fresh=True)}

    def run_group(self, name: str, members: list[PullRequest]) -> list[tuple[PullRequest, str]]:
        """Validate the group as one stack; land it in order when green, or
        bisect it, name the culprit, and validate the rest again."""
        reviews = self.group_reviews(members)
        missing = [pr for pr in members if not reviews.get(pr.number)]
        if missing:
            wait = "waiting: no review pass on " + " ".join(f"#{pr.number}" for pr in missing)
            log(f"group {name}: {wait}")
            return [(pr, wait) for pr in members]
        outcome: list[tuple[PullRequest, str]] = []
        culprits: list[PullRequest] = []
        candidates = list(members)
        while candidates:
            validation = self.validate(candidates, f"group {name}" + (f" rerun {len(culprits)}" if culprits else ""),
                                       group=name)
            for pr, blocking in validation.stack.dropped:
                self.report_drop(pr, blocking)
                outcome.append((pr, "dropped: conflict"))
            included = validation.stack.included
            if not included:
                break
            if validation.green:
                outcome += self.land_group(name, validation)
                break
            if not validation.heavy_failed and not validation.stack.error and not validation.lane_failed:
                # The fleet build failed or a lane never ran: nothing to blame on a PR.
                why = "; ".join(validation.failures())
                outcome += [(pr, f"not landed: {why}") for pr in included]
                break
            if len(culprits) >= MAX_CULPRITS:
                outcome += [(pr, "not landed: too many culprits in one group") for pr in included]
                break
            culprit = included[0] if len(included) == 1 else self.bisect(validation)
            prefix = next((item for item in reversed(self.validations) if item.stack.included
                           and item.stack.included[-1].number == culprit.number and not item.green), None)
            self.report_culprit(culprit, validation, prefix)
            culprits.append(culprit)
            outcome.append((culprit, "culprit"))
            log(f"group {name}: culprit #{culprit.number}")
            candidates = [pr for pr in included if pr.number != culprit.number]
        return outcome

    def land_group(self, name: str, validation: Validation) -> list[tuple[PullRequest, str]]:
        """Merge the members in stack order, each through GitHub's merge API at
        the validated head (merge_one). Stops at the first member that cannot land, so a later member
        never lands without what it was tested on."""
        included = validation.stack.included
        if self.args.dry_run or self.args.no_land:
            return [(pr, "validated; landing disabled for this run") for pr in included]
        if refusal := landing_refusal():
            return [(pr, f"not landed: {refusal}") for pr in included]
        # Every member clears the freeze check before any lands: a freeze never splits a group.
        # Nor does risk evidence merge_one would refuse (an edited description regrades it).
        held = {pr.number: why for pr in included if (why := self.frozen(pr) or self.risk_evidence(pr))}
        if held:
            why = "; ".join(f"#{number} {text}" for number, text in held.items())
            return [(pr, f"not landed: {why}") for pr in included]
        files = {path for pr in included for path in self.member_files(pr, validation.stack.base)}
        base = self.current_base()
        if base != validation.stack.base and self.base_moved_onto(validation.stack.base, base, files):
            return [(pr, f"not landed: {BASE} changed the group's files since validation; {REVALIDATE}")
                    for pr in included]
        fresh = self.fresh_members(included)
        # Validation takes hours: a check pending at selection may be red by now.
        late = {pr.number: why for pr in included if (current := fresh.get(pr.number)) is not None
                and (why := ineligible_reason(current, now()) or group_hold(current))}
        if late:
            why = "; ".join(f"#{number} {text}" for number, text in late.items())
            return [(pr, f"not landed: {why}") for pr in included]
        outcome: list[tuple[PullRequest, str]] = []
        for index, pr in enumerate(included):
            current = fresh.get(pr.number)
            problem = ("closed meanwhile" if current is None else
                       "pushed after validation" if current.sha != pr.sha else "")
            if problem:
                outcome.append((pr, f"not landed: {problem}"))
                outcome += [(rest, f"not landed: #{pr.number} {problem}") for rest in included[index + 1:]]
                break
            if not getattr(self.args, "land", True):
                self.comment_once(pr, "receipt", self.receipt(validation, pr) + (
                    f"\n\nGroup `{groups.GROUP_PREFIX}{name}`: land the members in this order: "
                    + " ".join(f"#{item.number}" for item in included) + "."))
                outcome.append((pr, "receipt posted; owner lands"))
                continue
            self.comment_once(pr, "landing", (
                f"Batch queue: landing group `{groups.GROUP_PREFIX}{name}` ({index + 1}/{len(included)}). "
                f"[Batch]({self.run_url}), stack `{validation.stack.head[:12]}` on `{validation.stack.base[:12]}`, "
                f"[heavy tier]({validation.heavy_url}), lanes: "
                + (", ".join(f"{lane} {result}" for lane, result in sorted(validation.lanes.items())) or "none")
                + "."))
            # Through GitHub's merge API at the validated head, like every batch merge.
            for attempt in range(MERGE_RETRIES + 1):
                text = self.merge_one(pr, validation)
                # Right after the previous member lands GitHub can still see the old
                # base; the head is pinned, so trying again merges the same commit.
                if text.startswith("landed") or "Base branch was modified" not in text or attempt == MERGE_RETRIES:
                    break
                time.sleep(5 * (attempt + 1))
            if not text.startswith("landed"):
                outcome.append((pr, text))
                outcome += [(rest, f"not landed: #{pr.number} did not land") for rest in included[index + 1:]]
                break
            outcome.append((pr, "landed"))
            log(f"group {name}: #{pr.number} {text}")
        return outcome

    def run_groups(self, prs: list[PullRequest], only: set[int] | None,
                   skipped: dict[int, str]) -> list[tuple[PullRequest, str]]:
        outcome: list[tuple[PullRequest, str]] = []
        for name, members in sorted(groups.assemble(prs).items()):
            if only is not None and not any(pr.number in only for pr in members):
                continue
            members = [pr for pr in members if not self.reported(pr, ("culprit", "conflict", "refused"))]
            # Own checks count: a red one found only at landing would strand the members before it.
            reasons = {pr.number: ineligible_reason(pr, now()) or group_hold(pr) for pr in members}
            if not members or any(reasons.values()):
                why = "; ".join(f"#{number} {reason}" for number, reason in reasons.items() if reason) or "no member left"
                log(f"group {name}: waiting ({why})")
                for pr in members:
                    skipped[pr.number] = f"group {groups.GROUP_PREFIX}{name} waits: {why}"
                continue
            heads = tuple(sorted((pr.number, pr.sha) for pr in members))
            if time.time() - GROUP_TRIED.get(heads, float("-inf")) < GROUP_RETRY_SECONDS:
                log(f"group {name}: tried at these heads within the hour; waiting for a push")
                for pr in members:
                    skipped[pr.number] = f"group {groups.GROUP_PREFIX}{name}: tried at these heads; waiting for a push"
                continue
            self.base_sha = self.base_sha or self.fetch(members)
            self.fetch(members)
            meta = self.group_meta(members)
            label = f"{groups.GROUP_PREFIX}{name}"
            ordered = groups.order(members, {pr.number: meta[pr.number]["labeled"].get(label, "") for pr in members},
                                   self.is_ancestor)
            log(f"group {name}: " + " ".join(f"#{pr.number}" for pr in ordered))
            result = self.run_group(name, ordered)
            outcome += result
            if not all(text.startswith("waiting") or text.endswith(REVALIDATE) for _, text in result):
                GROUP_TRIED[heads] = time.time()
            if any(text == "landed" for _, text in result):
                # The base moved: the next group is validated next cycle, on top of this one.
                break
        return outcome

    def group_report(self, outcome: list[tuple[PullRequest, str]]) -> str:
        lines = [f"### cmux-next groups [{self.batch_id}]({self.run_url})", ""]
        lines += [f"- #{pr.number}: {text}" for pr, text in outcome]
        return "\n".join(lines) + "\n\n"

    # -- the whole batch
    def cleanup(self) -> None:
        """Delete the batch's branches and stop its base probe."""
        for validation in self.validations:
            if validation.branch and not self.args.keep_branches:
                self.delete_branch(validation.branch)
        self.stop_base_probe()
        if self.base_probe_result.get("branch") and not self.args.keep_branches:
            self.delete_branch(self.base_probe_result["branch"])

    def reset_base(self) -> None:
        """Forget the groups' base so the ordinary batch stacks on the current
        feat-cmux-next: stop the old base's probe and delete its branch."""
        self.stop_base_probe()
        if self.base_probe_result.get("branch") and not self.args.keep_branches:
            self.delete_branch(self.base_probe_result["branch"])
        self.base_sha = ""
        self.base_failures = None
        self.base_tree_waited = False
        self.base_probe = None
        self.base_probe_result = {}
        self.base_probe_stop = threading.Event()

    def run(self) -> int:
        try:
            return self.run_cycle()
        finally:
            # Every exit, also a raise (a 502 GitHub never retried): under serve the
            # process lives on, and a leaked probe would keep its heavy run going.
            self.cleanup()

    def run_cycle(self) -> int:
        only = {int(item) for item in re.split(r"[\s,#]+", self.args.prs) if item} if self.args.prs else None
        prs = open_prs(self.gh)
        eligible, skipped = select(prs, now(), only)
        group_outcome = self.run_groups(prs, only, skipped)
        if self.validations and not any(text == "landed" for _, text in group_outcome) \
                and self.current_base() != self.base_sha:
            self.reset_base()  # the groups took long enough for feat-cmux-next to move
        if any(text == "landed" for _, text in group_outcome):
            # The base moved under the ordinary batch: it runs next cycle on the new base.
            self.after_landing()
            skipped.update({pr.number: "next cycle (a group landed)" for pr in eligible})
            eligible = []
        # A PR this queue already dropped at its current head waits for a push.
        for pr in list(eligible):
            if kind := self.reported(pr, ("culprit", "conflict", "refused")):
                eligible.remove(pr)
                skipped[pr.number] = f"dropped at this head ({kind}); waiting for a push"
            elif self.reported(pr, ("receipt",)):
                eligible.remove(pr)
                skipped[pr.number] = "green receipt at this head; owner lands"
        log("eligible: " + (" ".join(f"#{pr.number}" for pr in eligible) or "none"))
        if not eligible:
            text = ("No eligible pull requests.\n\n" if not group_outcome else self.group_report(group_outcome)) + \
                "\n".join(f"- #{number}: {reason}" for number, reason in sorted(skipped.items()))
            write_summary(text)
            if group_outcome:
                self.post_sticky(text)
            return 0
        landing = (getattr(self.args, "land", True) and not self.args.dry_run and not self.args.no_land
                   and not landing_refusal())
        eligible, waiting = admit_reviewed(eligible, self.gh, landing)
        if landing:
            env = getattr(self.gh, "env", None) or dict(os.environ)
            eligible, frozen = drop_frozen(eligible, lambda number: freeze_check(self.args.repo, number, env))
            waiting.update(frozen)
        skipped.update(waiting)
        if not eligible:
            text = (self.group_report(group_outcome) if group_outcome else "") + "Nothing reviewed to land.\n\n" + \
                "\n".join(f"- #{number}: {reason}" for number, reason in sorted(skipped.items()))
            write_summary(text)
            if group_outcome:
                self.post_sticky(text)
            return 0
        tried = {pr.number for pr in eligible if self.reported(pr, ("alone",))}
        candidates = land_alone_first(eligible, tried)
        for pr in eligible:
            if pr not in candidates:
                skipped[pr.number] = "waiting: a trusted land-alone PR goes first"
        if landing and len(candidates) == 1 and candidates[0].number not in tried and candidates is not eligible:
            self.comment_once(candidates[0], "alone", "Batch queue: validating this PR on its own (`queue: land alone`).")
        culprits: list[PullRequest] = []
        landed: list[tuple[PullRequest, str]] = []
        while candidates:
            validation = self.validate(candidates, "batch" if not culprits else f"rerun {len(culprits)}")
            for pr, blocking in validation.stack.dropped:
                self.report_drop(pr, blocking)
            if not validation.stack.included:
                break
            if validation.green:
                landed = self.land(validation)
                if any(text.startswith("landed") for _, text in landed):
                    self.after_landing()
                break
            if not validation.heavy_failed and not validation.stack.error:
                # Every tier passed and only the fleet build failed: the
                # compiles already ran, so blame the fleet, not a PR.
                log("fleet build failed on a green stack; not bisecting, not landing")
                break
            if len(culprits) >= MAX_CULPRITS:
                log("too many culprits in one batch; stopping")
                break
            included = validation.stack.included
            culprit = included[0] if len(included) == 1 else self.bisect(validation)
            prefix = next((v for v in reversed(self.validations)
                           if v.stack.included and v.stack.included[-1].number == culprit.number and not v.green), None)
            self.report_culprit(culprit, validation, prefix)
            culprits.append(culprit)
            log(f"culprit #{culprit.number}")
            candidates = [pr for pr in included if pr.number != culprit.number]
        text = self.report(eligible, skipped, landed, culprits)
        if group_outcome:
            text = self.group_report(group_outcome) + text
        write_summary(text)
        self.post_sticky(text)
        print(text)
        return 0


def sticky_body(text: str, previous: str, keep: int = 9) -> str:
    """The sticky comment: this batch on top, up to `keep` earlier ones folded below."""
    entries: list[str] = []
    if STICKY_MARKER in previous:
        head, _, folded = previous.partition("<details>")
        current = head.replace(STICKY_MARKER, "").strip()
        older = folded.partition("<!-- entries -->")[2].rpartition("</details>")[0]
        entries = [current] + [entry.strip() for entry in older.split("<!-- entry -->") if entry.strip()]
    entries = entries[:keep]
    body = f"{STICKY_MARKER}\n{text}\n"
    if entries:
        body += "\n<details><summary>Earlier batches</summary>\n\n<!-- entries -->\n" + "".join(
            f"<!-- entry -->\n{entry}\n\n" for entry in entries) + "</details>\n"
    return body


def write_summary(text: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as summary:
            summary.write(text + "\n")


# --- commands -----------------------------------------------------------------


def cmd_select(args: argparse.Namespace) -> int:
    eligible, skipped = select(open_prs(GitHub(args.repo)), now())
    print(json.dumps({"eligible": [pr.number for pr in eligible], "skipped": skipped}, indent=2))
    return 0


def cmd_stack(args: argparse.Namespace) -> int:
    gh = GitHub(args.repo)
    wanted = {int(item) for item in re.split(r"[\s,#]+", args.prs) if item}
    prs = [pr for pr in open_prs(gh) if pr.number in wanted]
    controller = Controller(args)
    base_sha = controller.fetch(prs)
    stack = build_stack(Path(args.worktree), base_sha, sorted(prs, key=lambda pr: pr.number),
                        regen=not args.no_regen)
    print(json.dumps(stack.summary(), indent=2))
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    if args.local:
        use_local_login()
    return Controller(args).run()


def use_local_login() -> None:
    """The operator's gh login pushes and merges, so its pushes and merges
    start CI like anyone's. Generators never see it: they run on runners."""
    if not os.environ.get("GH_TOKEN"):
        os.environ["GH_TOKEN"] = subprocess.run(["gh", "auth", "token"], capture_output=True,
                                                text=True, check=True).stdout.strip()


def cmd_serve(args: argparse.Namespace) -> int:
    """Poll the open PRs, debounce like the debounce job, run one batch at a
    time. A batch is never interrupted; events meanwhile wait for it."""
    args.local = True
    use_local_login()
    gh = GitHub(args.repo)
    debouncer = Debouncer()
    watch = CloseWatch(lambda number: closed_info(gh, number), notify_coordinator, batch_authors())
    latest: list = [None]  # (prs, polled at), replaced whole by the poller

    def poll() -> None:
        """The one open-PR query a minute. It runs while a batch blocks the
        main loop too, so the close watch never waits for a batch."""
        while True:
            try:
                prs = open_prs(gh)
                latest[0] = (prs, now())
                watch.observe(prs, now())
            except Exception as error:  # keep polling
                log(f"serve poll: {type(error).__name__}: {error}")
            time.sleep(SERVE_POLL_SECONDS)

    threading.Thread(target=poll, name="poll", daemon=True).start()
    log(f"serving {args.repo} {BASE}; mini jobs on {args.ref}")
    seen = None
    while True:
        snapshot = latest[0]
        if snapshot is not None and snapshot is not seen:
            seen = snapshot
            try:
                eligible, _ = select(snapshot[0], snapshot[1])
                # Group members wait in select(); their heads and labels still start a cycle.
                grouped = [pr for pr in snapshot[0] if groups.group_of(pr.labels)]
                heads = tuple(sorted({(pr.number, pr.sha) for pr in eligible}
                                     | {(pr.number, pr.sha + ":" + (groups.group_of(pr.labels) or "")) for pr in grouped}))
                if debouncer.observe(heads, snapshot[1]):
                    debouncer.ran(heads)
                    log("batch for " + " ".join(f"#{number}" for number, _ in heads))
                    Controller(args).run()
            except Exception as error:  # keep serving; the next poll retries
                log(f"serve: {type(error).__name__}: {error}")
        time.sleep(5)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    sub = parser.add_subparsers(dest="command", required=True)
    debounce = sub.add_parser("debounce")
    debounce.add_argument("--reason", default="")
    sub.add_parser("select")
    for name in ("run", "stack", "serve"):
        command = sub.add_parser(name)
        command.add_argument("--worktree", default=os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), "next-batch-stack"))
        command.add_argument("--prs", default="", help="only these PR numbers (still checked for eligibility in run)")
        command.add_argument("--ref", default=os.environ.get("GITHUB_REF_NAME", BASE),
                             help="ref the mini jobs of this workflow are dispatched on")
        command.add_argument("--dry-run", action="store_true", help="no comments, no landing, no sticky")
        command.add_argument("--no-land", action="store_true", help="validate and report, but do not land")
        command.add_argument("--keep-branches", action="store_true")
        command.add_argument("--no-regen", action="store_true")
        command.add_argument("--local", action="store_true",
                             help="run here with the gh login; build with this host's cmux-ci")
        command.add_argument("--land", action="store_true",
                             help="serve: merge green PRs (default: post a receipt; the owner lands)")
    args = parser.parse_args(argv)
    if args.command == "run" and not args.local:
        args.land = True  # the workflow's App lands; a workstation posts receipts unless --land
    if args.command in {"run", "stack", "serve"}:
        worktree = Path(args.worktree)
        if not (worktree / ".git").exists():
            subprocess.run(["git", "worktree", "add", "--quiet", "--detach", str(worktree), "HEAD"],
                           cwd=TOOLS_ROOT, check=True)
    return {"debounce": cmd_debounce, "select": cmd_select, "run": cmd_run, "stack": cmd_stack,
            "serve": cmd_serve}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
