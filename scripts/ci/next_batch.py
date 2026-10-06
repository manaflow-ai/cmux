#!/usr/bin/env python3
"""Implicit merge queue for feat-cmux-next: stack, validate once, land.

.github/workflows/cmux-next-batch.yml runs this. See docs/ci/cmux-next-batch.md.

  debounce  pull request and push events: wait for quiet, then dispatch a batch
  serve     the same queue as a long-running loop under the operator's gh
            login (until the batch App exists): poll, debounce, run batches
  run       the batch: select eligible PRs, stack them on feat-cmux-next,
            validate the stack once (every cmux-next tier plus a fleet
            production build), land each PR with gh-merge-green, or bisect a
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
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import merge_main_resolver as mmr  # noqa: E402

TOOLS_ROOT = Path(__file__).resolve().parents[2]
BASE = "feat-cmux-next"
BRANCH_PREFIX = "next-batch/"
WORKFLOW = "cmux-next-batch.yml"
HEAVY_WORKFLOW = "cmux-next.yml"
TUI_WORKFLOW = "cmux-tui-artifacts.yml"
STICKY_MARKER = "<!-- cmux-next-batch-queue -->"
COMMENT_MARKER = "<!-- cmux-next-batch:{kind}:{sha} -->"

QUIET_SECONDS = 120
HARD_MAX_SECONDS = 600
STALE_DAYS = 5
MAX_PRS = 12
MAX_CULPRITS = 3
POLL_SECONDS = 90
SERVE_POLL_SECONDS = 60

# Authors whose PRs the queue lands without asking (the agent lanes post as
# Leo). Anyone else opts a PR in with the OPT_IN label. Override the list with
# the CMUX_NEXT_BATCH_AUTHORS repository variable (space separated).
DEFAULT_AUTHORS = ("teamleaderleo",)
OPT_IN = "batch-queue"
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
    "wait for the same-tree cmux-tui",
})
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
    "webviews/src/pages/*/generated/strings.json",
)
# Written by Swift tests under CMUX_UPDATE_*; only a mini can rebuild them.
SWIFT_GENERATED = (
    "plans/cmux-next/action-surfaces.json",
    "plans/cmux-next/actions.md",
    "plans/cmux-next/links.json",
    "plans/cmux-next/daemon-capabilities.json",
    "schemas/settings/settings-schema.json",
    "docs/mdm/com.manaflow.cmux.json",
    "docs/mdm/com.manaflow.cmux.plist",
    "docs/mdm/com.manaflow.cmux.intune.plist",
    "docs/mdm/managed-preferences.md",
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
        if completed.returncode != 0 and re.search(r"HTTP 5\d\d", completed.stderr):
            time.sleep(10)  # a gateway timeout on a large query; once
            completed = self.gh(*args, check=False)
        if completed.returncode != 0:
            raise RuntimeError(f"gh api graphql failed: {completed.stderr.strip()[-500:]}")
        return json.loads(completed.stdout)["data"]

    def workflow(self, name: str) -> str:
        """The workflow's numeric id. A file name resolves only on the default
        branch (main), and feat-cmux-next-only workflows like this one are not
        there; the id works for every registered workflow."""
        if not self.workflow_ids:
            listed = self.gh("api", "--paginate", f"repos/{self.repo}/actions/workflows?per_page=100",
                             "--jq", ".workflows[] | [.id, .path] | @tsv").stdout
            for line in listed.splitlines():
                workflow_id, _, path = line.partition("\t")
                self.workflow_ids[path.rsplit("/", 1)[-1]] = int(workflow_id)
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
    files: list[str] = field(default_factory=list)
    checks: list[tuple[str, str, str]] = field(default_factory=list)  # (name, status, conclusion)

    def short(self) -> str:
        return f"#{self.number}"


# PRs per open_prs page. Each carries files and checks; 100 in one query
# times out at GitHub (HTTP 504).
PRS_PAGE = 30
PRS_QUERY = """
query($owner: String!, $name: String!, $base: String!, $first: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, baseRefName: $base, first: $first, after: $after,
                 orderBy: {field: CREATED_AT, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title url isDraft headRefName headRefOid authorAssociation
        author { login }
        files(first: 100) { nodes { path } }
        isCrossRepository
        labels(first: 30) { nodes { name } }
        commits(last: 1) { nodes { commit {
          committedDate
          statusCheckRollup { contexts(first: 100) { nodes {
            __typename
            ... on CheckRun { name status conclusion }
            ... on StatusContext { context state }
          } } }
        } } }
      }
    }
  }
}
"""


def open_prs(gh: GitHub) -> list[PullRequest]:
    owner, name = gh.repo.split("/")
    nodes, after = [], None
    while True:
        page = gh.graphql(PRS_QUERY, owner=owner, name=name, base=BASE, first=PRS_PAGE, after=after)
        connection = page["repository"]["pullRequests"]
        nodes += connection["nodes"]
        info = connection.get("pageInfo") or {}
        if not info.get("hasNextPage"):
            break
        after = info["endCursor"]
    prs = []
    for node in nodes:
        commit = (node["commits"]["nodes"] or [{}])[0].get("commit") or {}
        rollup = (commit.get("statusCheckRollup") or {}).get("contexts", {}).get("nodes", [])
        checks = []
        for item in rollup:
            if item["__typename"] == "CheckRun":
                checks.append((item["name"], (item["status"] or "").lower(), (item["conclusion"] or "").lower()))
            else:
                state = (item["state"] or "").lower()
                status = "completed" if state not in {"pending", "expected"} else "in_progress"
                checks.append((item["context"], status, state))
        prs.append(PullRequest(
            number=node["number"], sha=node["headRefOid"], title=node["title"], url=node["url"],
            head_ref=node["headRefName"], labels=[label["name"] for label in node["labels"]["nodes"]],
            draft=node["isDraft"], same_repo=not node["isCrossRepository"],
            author_association=node["authorAssociation"], committed_at=commit.get("committedDate", ""),
            author=(node.get("author") or {}).get("login", ""),
            files=[item["path"] for item in (node.get("files") or {}).get("nodes") or []],
            checks=checks,
        ))
    return prs


def touches_webviews(pr: PullRequest) -> bool:
    return any(path.startswith("webviews/") for path in pr.files)


def red_fast_checks(pr: PullRequest) -> list[str]:
    fixable = FORMAT_CHECKS if touches_webviews(pr) else frozenset()
    return sorted({name for name, status, conclusion in pr.checks
                   if status == "completed" and conclusion in RED and name not in HEAVY_CHECKS | fixable})


def red_format_checks(pr: PullRequest) -> list[str]:
    return sorted({name for name, status, conclusion in pr.checks
                   if status == "completed" and conclusion in RED and name in FORMAT_CHECKS})


def batch_authors() -> frozenset[str]:
    configured = os.environ.get("CMUX_NEXT_BATCH_AUTHORS", "").split()
    return frozenset(configured or DEFAULT_AUTHORS)


def ineligible_reason(pr: PullRequest, at: dt.datetime, stale_days: int = STALE_DAYS,
                      authors: frozenset[str] | None = None) -> str | None:
    """Why this PR stays out of the batch, or None when it is eligible.

    Eligible: ready for review, a same-repository member branch by a batch
    author (or labeled OPT_IN), no hold label, a head commit from the last
    `stale_days` days, and no failed check outside the heavy tier (pending
    is fine).
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
    if pr.committed_at and at - parse_time(pr.committed_at) > dt.timedelta(days=stale_days):
        return f"head commit older than {stale_days} days"
    red = red_fast_checks(pr)
    if red:
        return "red check " + ", ".join(red)
    return None


def select(prs: list[PullRequest], at: dt.datetime, only: set[int] | None = None,
           limit: int = MAX_PRS) -> tuple[list[PullRequest], dict[int, str]]:
    eligible, skipped = [], {}
    for pr in sorted(prs, key=lambda item: item.number):
        if only is not None and pr.number not in only:
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

    Each new event cancels the waiting run (concurrency cancel-in-progress), so
    a dispatch happens after `quiet` seconds without events, but never later
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


def cmd_debounce(args: argparse.Namespace) -> int:
    gh = GitHub(args.repo)
    runs = gh.runs(WORKFLOW, "per_page=60")
    at = now()
    first = first_trigger_since_dispatch(runs, at)
    wait = debounce_wait(at, first)
    log(f"first event since the last batch at {first.isoformat()}; waiting {wait}s for quiet")
    time.sleep(wait)
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

    @property
    def green(self) -> bool:
        return not self.stack.error and not self.heavy_failed and bool(self.build.get("ok"))

    def failures(self) -> list[str]:
        out = []
        if self.stack.error:
            out.append(self.stack.error)
        out += [f"`{job}`" for job in self.heavy_failed]
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

    def failed_jobs(self, run_id: int) -> list[str]:
        jobs = self.gh.api(f"repos/{self.args.repo}/actions/runs/{run_id}/jobs?per_page=100&filter=latest")["jobs"]
        return sorted({job["name"] for job in jobs if (job.get("conclusion") or "") in RED})

    def failing_on_base(self, base_sha: str) -> set[str]:
        """Jobs already red on the base head's own cmux-next run (inherited, not the batch's)."""
        if self.base_failures is not None:
            return self.base_failures
        runs = self.gh.runs(HEAVY_WORKFLOW, f"head_sha={base_sha}&per_page=10")
        done = [run for run in runs if run["status"] == "completed" and run["head_branch"] == BASE]
        self.base_failures = set(self.failed_jobs(done[0]["id"])) if done else set()
        return self.base_failures

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

    def validate(self, prs: list[PullRequest], name: str) -> Validation:
        """Stack `prs` on the batch's base and run every tier plus the fleet build.

        The base is fixed at the batch's first fetch, so bisect probes and
        reruns compare against the same feat-cmux-next commit.
        """
        started = time.monotonic()
        fetched = self.fetch(prs)
        self.base_sha = self.base_sha or fetched
        base_sha = self.base_sha
        stack = build_stack(self.worktree, base_sha, prs, regen=False)
        validation = Validation(name=name, stack=stack)
        self.validations.append(validation)
        if not stack.included or stack.error:
            validation.seconds = int(time.monotonic() - started)
            return validation
        branch = f"{BRANCH_PREFIX}{self.batch_id}-{len(self.validations)}"
        validation.branch = branch
        self.push(stack.head, branch)
        log(f"{name}: pushed {branch} at {stack.head[:12]} ({len(stack.included)} PRs)")
        if stack.regen and not self.regenerate_remote(stack, branch):
            validation.seconds = int(time.monotonic() - started)
            return validation
        sha = stack.head
        changed = self.git("diff", "--name-only", base_sha, sha).splitlines()
        pin = ""
        if any(path.startswith(TUI_PATHS) for path in changed):
            pin = f"cmux-tui-pin-{sha[:12]}"
            self.push(sha, pin)
            if not self.local:  # the job token's push starts no workflow
                self.gh.dispatch(TUI_WORKFLOW, pin)
        dispatched = now()
        self.gh.dispatch(HEAVY_WORKFLOW, branch)
        heavy = self.find_run(HEAVY_WORKFLOW, branch, lambda item: item["head_sha"] == sha, dispatched)
        validation.heavy_url = heavy["html_url"]
        log(f"{name}: heavy tier {heavy['html_url']}")
        validation.build = self.fleet_build(branch, sha, f"nb-{self.batch_id}-{len(self.validations)}")
        log(f"{name}: fleet build {'ok' if validation.build.get('ok') else 'failed'}")
        run = self.wait_run(heavy["id"], timeout=180 * 60)
        failed = self.failed_jobs(heavy["id"]) if run["status"] == "completed" else ["(timed out waiting)"]
        if failed and run["status"] == "completed" and not validation.rerun:
            # One rerun of the failed jobs before blaming a PR: flakes are not culprits.
            validation.rerun = True
            self.gh.gh("run", "rerun", str(heavy["id"]), "--failed", "-R", self.args.repo, check=False)
            time.sleep(30)
            run = self.wait_run(heavy["id"], timeout=120 * 60)
            failed = self.failed_jobs(heavy["id"])
        inherited = self.failing_on_base(base_sha)
        validation.inherited = sorted(set(failed) & inherited)
        validation.heavy_failed = sorted(set(failed) - inherited)
        if run["status"] == "completed":
            validation.heavy_passed = self.passed_heavy_jobs(heavy["id"])
        if pin:
            self.delete_branch(pin)
        validation.seconds = int(time.monotonic() - started)
        log(f"{name}: {'green' if validation.green else 'red'} in {validation.seconds}s")
        return validation

    # -- bisect
    def bisect(self, red: Validation) -> PullRequest:
        """Smallest red prefix of the stack: its last PR is the culprit."""
        prs = red.stack.included
        low, high = 0, len(prs)  # prefix[:low] green (the base), prefix[:high] red
        while high - low > 1:
            middle = (low + high) // 2
            probe = self.validate(prs[:middle], f"bisect {middle}/{len(prs)}")
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
    def merge_green(self) -> Path:
        path = Path(tempfile.gettempdir()) / "gh-merge-green"
        if not path.exists():
            self.git("fetch", "--quiet", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main")
            path.write_text(self.git("show", "refs/remotes/origin/main:scripts/gh-merge-green") + "\n")
            path.chmod(0o755)
        return path

    def land(self, validation: Validation) -> list[tuple[PullRequest, str]]:
        landed = []
        helper = self.merge_green()
        fresh = {pr.number: pr for pr in open_prs(self.gh)}
        for pr in validation.stack.included:
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
            if red_format_checks(current):
                try:
                    if self.format_pr(current, validation.branch):
                        self.comment_once(pr, "formatted", (
                            "Batch queue: pushed `bun run check:fix` output (web formatting and lint "
                            "autofix) to this branch; landing once its checks rerun."))
                except OwnerPushed:
                    landed.append((pr, "skipped: pushed while formatting; next batch"))
                    continue
                except RuntimeError as error:
                    landed.append((pr, f"not landed: {error}"))
                    continue
            if not getattr(self.args, "land", True):
                self.comment_once(pr, "receipt", self.receipt(validation, pr))
                landed.append((pr, "receipt posted; owner lands"))
                log(f"#{pr.number}: receipt posted")
                continue
            self.comment_once(pr, "landing", (
                f"Batch queue: landing. [Batch]({self.run_url}), stack `{validation.stack.head[:12]}` "
                f"on `{validation.stack.base[:12]}`, [heavy tier]({validation.heavy_url}), "
                f"build: {validation.build.get('link', 'n/a')}."))
            outcome = self.merge_one(helper, pr, validation)
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
                "Next: land it yourself with gh-merge-green on this receipt.")

    def merge_one(self, helper: Path, pr: PullRequest, validation: Validation) -> str:
        ref = f"{self.args.repo}#{pr.number}"
        env = {**self.writer.env, "GH_MERGE_GREEN_NO_AUTO_UPDATE": "1"}
        reason = (f"cmux-next batch {self.run_url} validated this exact head in stack "
                  f"{validation.stack.head[:12]}: every cmux-next tier and the fleet production build passed")
        deadline = time.monotonic() + 30 * 60
        override = False
        while True:
            command = [str(helper), ref, *(["--override", reason] if override else []), "--squash"]
            completed = subprocess.run(command, capture_output=True, text=True, env=env)
            output = (completed.stdout + completed.stderr).strip()
            if completed.returncode == 0:
                return "landed" + (" (override: own heavy check red, batch green)" if override else "")
            line = next((item for item in output.splitlines() if item.startswith("not green")), output[-300:])
            pending = re.search(r"is (queued|in_progress|waiting|pending|requested)/", line) or "has not run" in line
            heavy_red = any(name in line for name in HEAVY_CHECKS) and "is not successful" in line
            if heavy_red and not override:
                override = True  # the batch ran that tier on this head's stack
                continue
            if pending and time.monotonic() < deadline:
                time.sleep(120)
                continue
            return f"not landed: {line}"

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

    # -- the whole batch
    def run(self) -> int:
        only = {int(item) for item in re.split(r"[\s,#]+", self.args.prs) if item} if self.args.prs else None
        eligible, skipped = select(open_prs(self.gh), now(), only)
        # A PR this queue already dropped at its current head waits for a push.
        for pr in list(eligible):
            if kind := self.reported(pr, ("culprit", "conflict", "refused")):
                eligible.remove(pr)
                skipped[pr.number] = f"dropped at this head ({kind}); waiting for a push"
        log("eligible: " + (" ".join(f"#{pr.number}" for pr in eligible) or "none"))
        if not eligible:
            write_summary("No eligible pull requests.\n\n" + "\n".join(
                f"- #{number}: {reason}" for number, reason in sorted(skipped.items())))
            return 0
        candidates = eligible
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
        for validation in self.validations:
            if validation.branch and not self.args.keep_branches:
                self.delete_branch(validation.branch)
        text = self.report(eligible, skipped, landed, culprits)
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
    log(f"serving {args.repo} {BASE}; mini jobs on {args.ref}")
    while True:
        try:
            eligible, _ = select(open_prs(gh), now())
            heads = tuple((pr.number, pr.sha) for pr in eligible)
            if debouncer.observe(heads, now()):
                debouncer.ran(heads)
                log("batch for " + " ".join(f"#{number}" for number, _ in heads))
                Controller(args).run()
        except Exception as error:  # keep serving; the next poll retries
            log(f"serve: {type(error).__name__}: {error}")
        time.sleep(SERVE_POLL_SECONDS)


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
