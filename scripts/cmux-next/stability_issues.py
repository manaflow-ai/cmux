#!/usr/bin/env python3
"""One GitHub issue per stability signature (plans/cmux-next/chrome-parity/p10-stability.md, task 004).

The stability lab (stability-lab.py collect) turns crash, sanitizer and hang artifacts into signatures with
crash_signature.py ({kind, process, exception, frames[3], hash12}). This script keeps exactly one issue per hash12,
as ClusterFuzz files one bug per crash state (src/clusterfuzz/_internal/issue_management/issue_filer.py) and closes it
only after its progression task stops reproducing the crash on newer builds
(src/clusterfuzz/_internal/bot/tasks/utasks/progression_task.py).

  sync RUN.json            apply one lab run: count findings, create or update issues, count clean tips, close or
                           reopen. RUN.json is cmux-stability-run/v1:
                             {"schema": "cmux-stability-run/v1", "run": "<unique id>", "tip": "<sha>",
                              "lanes": [{"lane": "smoke", "major": "26"}, ...],   # what ran on the tip
                              "findings": [{<crash_signature fields>, "lane": "smoke", "major": "26",
                                            "sha": "<build sha, default tip>", "at": "<iso time>",
                                            "repro": {"minimal": URL, "seed": S, "test_id": T, "fuzz_input": URL},
                                            "source": "<artifact name, or sentry>"}, ...]}
  sentry HEALTH.json       import the top Sentry issues of `stability-health.py --json` (task 034, schema
                           cmux-stability-health/v1) as signatures with source sentry; '-' reads stdin. It reads
                           env, days and top_issues: [{"id", "short_id", "permalink", "title", "culprit", "events",
                           "users", "first_seen", "last_seen", "github": [N, ...], "owner": {...} or null}, ...].
  bisect-result --hash12   record stability_bisect.py's verdict: the first bad commit, or flaky (1-2 of 3 replays).
  fix-verified --hash12    record the fix commit once its repro no longer reproduces on a build that has it.

Rules:
  * Labels stability-sig, stability-sig:<hash12> and stability-kind:<kind>; the issue is found by its hash label.
  * Idempotent: a run id is applied to an issue once (its state block records it), so a repeated sync of the same
    run writes nothing. Two findings of one signature in one run make one issue with count 2.
  * An issue closes only when a fix is verified and 3 distinct tips that contain the fix ran a lane and major that
    found the signature without finding it again. A finding on a tip with the fix resets the fix and the clean
    tips; on an issue closed as completed it reopens it. A person's other close reasons (not planned, duplicate)
    are kept: the recurrence is counted and noted once in a comment.
  * Fix-in-build checks use git in --git-dir and fetch a commit from --remote when the checkout does not have it.
    When git still cannot tell, a finding counts as a recurrence (the fix is reset) and a clean tip does not count;
    both are named in the notes. --fix must be the commit as it landed (the squash commit, not a PR head).
  * One writer: every command that writes holds a host lock per repo (--lock-file) for its read, plan and writes,
    so parallel lab collectors on one host apply their runs one after the other. Duplicates that a second host
    still makes heal on the next sync: the higher number is merged into the lowest and closed as not planned.
  * GitHub reads follow the glaeda-gh read rules: one batched `gh issue list` per invocation (plus one `gh label
    list` when an issue is created), no polling loop. gh issue writes use the GraphQL bucket and label creates the
    REST core bucket; when a run needs many writes the free `gh api rate_limit` read must show 500 to spare in
    both. Every write counts against --max-writes and that budget, label creates too; writes beyond them are
    deferred per signature, exit 75, and the same sync applies them later.

Sentry issues join the same flow:
  * One Sentry issue maps to exactly one GitHub issue, and its link is never dropped. The stability issue whose state
    links the Sentry id keeps it, through re-imports, lab syncs and duplicate merges. A new Sentry issue whose
    annotations name a stability issue joins it; one that names another GitHub issue, or that an other-owner entry
    claims, is not imported (a note names it); any other gets its own signature, a hash12 of "sentry:<id>".
  * The link holds Sentry's numbers for the report's period, so the same report writes nothing.
  * The import never changes a fix, clean tips or whether an issue is open. The report names releases by version,
    not by commit, so it cannot tell whether an event came from a build with the fix. A lab repro (and its
    fix-verified and clean tips) or a person closes an issue that only Sentry found.

The issue body is generated; a person comments instead of editing it. Its last line holds the state as JSON.

    python3 scripts/cmux-next/stability_issues.py sync run.json --dry-run
"""

from __future__ import annotations

import argparse
import copy
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
from contextlib import contextmanager, nullcontext
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterator, Protocol

DEFAULT_REPO = os.environ.get("CMUX_STABILITY_REPO", "manaflow-ai/cmux")
RUN_SCHEMA = "cmux-stability-run/v1"
HEALTH_SCHEMA = "cmux-stability-health/v1"
LABEL = "stability-sig"
CLEAN_TIPS_TO_CLOSE = 3
RUNS_KEPT = 200
RATE_RESERVE = 500
BUDGET_CHECK_AT = 20
EX_TEMPFAIL = 75
GH_TIMEOUT_SECONDS = 120
GIT_FETCH_TIMEOUT_SECONDS = 300
PERSON_CLOSE_REASONS = {"NOT_PLANNED": "not planned", "DUPLICATE": "duplicate"}
HASH12 = re.compile(r"^[0-9a-f]{12}$")
SENTRY_LINK = re.compile(r"https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~%/?=&+-]*)?")
STATE_RE = re.compile(r"<!-- stability-sig-state: (\{.*?\}) -->", re.S)
ROOT = Path(__file__).resolve().parent.parent.parent


class StabilityIssueError(Exception):
    """A bad run file or argument, or a gh call that failed."""


# --- GitHub seam --------------------------------------------------------------------------------------------------


@dataclass
class Issue:
    number: int
    state: str  # OPEN or CLOSED
    state_reason: str  # COMPLETED, NOT_PLANNED, DUPLICATE, REOPENED or ""
    title: str
    body: str
    labels: list[str]


class GitHub(Protocol):
    def list_issues(self, label: str) -> list[Issue]: ...
    def existing_labels(self) -> set[str]: ...
    def create_label(self, name: str) -> None: ...
    def create_issue(self, title: str, body: str, labels: list[str]) -> int: ...
    def edit_issue(self, number: int, title: str, body: str) -> None: ...
    def comment(self, number: int, text: str) -> None: ...
    def close_issue(self, number: int, text: str, reason: str) -> None: ...
    def reopen_issue(self, number: int, text: str) -> None: ...
    def rate_remaining(self) -> dict[str, int] | None: ...


class GhCli:
    """The real GitHub through the gh CLI. Each method is one gh call (reads are batched by the caller)."""

    def __init__(self, repo: str, gh: str = "gh") -> None:
        self.repo = repo
        self.gh = gh

    def _run(self, args: list[str], stdin: str | None = None, scoped: bool = True) -> str:
        command = [self.gh, *args, *(["--repo", self.repo] if scoped else [])]
        try:
            proc = subprocess.run(command, input=stdin, text=True, capture_output=True, check=False,
                                  timeout=GH_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired as error:
            raise StabilityIssueError(f"gh {' '.join(args[:2])} timed out after {GH_TIMEOUT_SECONDS} s") from error
        if proc.returncode != 0:
            raise StabilityIssueError(f"gh {' '.join(args[:2])} failed ({proc.returncode}): {proc.stderr.strip()}")
        return proc.stdout

    def list_issues(self, label: str) -> list[Issue]:
        out = self._run(["issue", "list", "--label", label, "--state", "all", "--limit", "2000",
                         "--json", "number,state,stateReason,title,body,labels"])
        return [Issue(number=int(row["number"]), state=str(row["state"]).upper(),
                      state_reason=str(row.get("stateReason") or "").upper(), title=row.get("title") or "",
                      body=row.get("body") or "", labels=[label_row["name"] for label_row in row.get("labels") or []])
                for row in json.loads(out or "[]")]

    def existing_labels(self) -> set[str]:
        # One search covers stability-sig, stability-sig:<hash12> and stability-kind:<kind>.
        out = self._run(["label", "list", "--search", "stability-", "--limit", "2000", "--json", "name"])
        return {row["name"] for row in json.loads(out or "[]")}

    def create_label(self, name: str) -> None:
        self._run(["label", "create", name, "--force", "--color", "b60205",
                   "--description", "Stability lab signature (scripts/cmux-next/stability_issues.py)"])

    def create_issue(self, title: str, body: str, labels: list[str]) -> int:
        args = ["issue", "create", "--title", title, "--body-file", "-"]
        for name in labels:
            args += ["--label", name]
        url = self._run(args, stdin=body).strip().splitlines()[-1]
        match = re.search(r"/issues/(\d+)$", url)
        if not match:
            raise StabilityIssueError(f"gh issue create printed no issue URL: {url!r}")
        return int(match.group(1))

    def edit_issue(self, number: int, title: str, body: str) -> None:
        self._run(["issue", "edit", str(number), "--title", title, "--body-file", "-"], stdin=body)

    def comment(self, number: int, text: str) -> None:
        self._run(["issue", "comment", str(number), "--body-file", "-"], stdin=text)

    def close_issue(self, number: int, text: str, reason: str) -> None:
        self._run(["issue", "close", str(number), "--reason", reason, "--comment", text])

    def reopen_issue(self, number: int, text: str) -> None:
        self._run(["issue", "reopen", str(number), "--comment", text])

    def rate_remaining(self) -> dict[str, int] | None:
        """What is left in the buckets the writes use: graphql (gh issue create/edit/comment/close/reopen) and core
        (gh label create). GET /rate_limit counts against neither."""
        try:
            resources = json.loads(self._run(["api", "rate_limit"], scoped=False))["resources"]
            return {bucket: int(resources[bucket]["remaining"]) for bucket in ("core", "graphql")}
        except (StabilityIssueError, ValueError, KeyError, TypeError):
            return None


class GitAncestry:
    """is_ancestor(ancestor, tip) from git: True or False, None when git cannot tell. A commit the checkout does not
    have is fetched once from `remote` (GitHub serves any reachable sha), so a lab tip or a fix newer than the
    checkout still resolves."""

    def __init__(self, repo_dir: Path, remote: str = "origin") -> None:
        self.repo_dir = repo_dir
        self.remote = remote
        self.fetched: set[str] = set()

    def _git(self, *args: str, timeout: int = 60) -> int:
        try:
            return subprocess.run(["git", "-C", str(self.repo_dir), *args], capture_output=True, check=False,
                                  timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            return -1

    def _has(self, sha: str) -> bool:
        return self._git("cat-file", "-e", f"{sha}^{{commit}}") == 0

    def __call__(self, ancestor: str, tip: str) -> bool | None:
        missing = [sha for sha in dict.fromkeys((ancestor, tip)) if sha not in self.fetched and not self._has(sha)]
        if missing and self.remote:
            self.fetched.update(missing)
            self._git("fetch", "--quiet", "--no-tags", self.remote, *missing, timeout=GIT_FETCH_TIMEOUT_SECONDS)
        code = self._git("merge-base", "--is-ancestor", ancestor, tip)
        return code == 0 if code in (0, 1) else None


def default_lock_file(repo: str) -> Path:
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    return cache / "cmux" / f"stability-issues-{re.sub(r'[^A-Za-z0-9._-]+', '_', repo)}.lock"


@contextmanager
def repo_lock(path: Path) -> Iterator[None]:
    """The host's one-writer lock for a repo. It waits for the holder, whose gh and git calls all have timeouts."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


# --- State --------------------------------------------------------------------------------------------------------


def empty_state(sig: dict) -> dict:
    return {
        "v": 1, "hash12": sig["hash12"], "kind": sig.get("kind", ""), "process": sig.get("process", ""),
        "exception": sig.get("exception", ""), "frames": list(sig.get("frames") or [])[:3],
        "source": sig.get("source") or "lab", "first_sha": "", "first_seen": "", "last_sha": "", "last_seen": "",
        "count": 0, "per_major": {}, "seen_in": [], "repro": {}, "bisect": None, "fix": None, "clean_tips": [],
        "fix_history": [], "runs": [],
    }


def read_state(body: str) -> dict | None:
    matches = STATE_RE.findall(body or "")
    if not matches:
        return None
    try:
        state = json.loads(matches[-1])
    except json.JSONDecodeError:
        return None
    return state if isinstance(state, dict) and HASH12.match(str(state.get("hash12", ""))) else None


def encode_state(state: dict) -> str:
    # `<` and `>` only occur inside JSON strings: escaped, no frame name can end the comment or start another.
    text = json.dumps(state, sort_keys=True, ensure_ascii=True, separators=(",", ":"))
    return text.replace("<", "\\u003c").replace(">", "\\u003e")


def short(sha: str) -> str:
    return sha[:11] if sha else "-"


def code(text: str) -> str:
    return "`" + str(text).replace("`", "'")[:200] + "`"


def sanitize_label(text: str) -> str:
    return re.sub(r"[^a-z0-9._-]+", "-", str(text).lower()).strip("-")[:40] or "unknown"


def labels_for(state: dict) -> list[str]:
    return [LABEL, f"{LABEL}:{state['hash12']}", f"stability-kind:{sanitize_label(state['kind'])}"]


def render_title(state: dict) -> str:
    where = state["frames"][0] if state["frames"] else state["exception"] or "unknown frame"
    head = " ".join(part for part in (state["kind"], state["process"]) if part)
    title = f"stability: {head} in {where}"
    return f"{title[:110]} [{state['hash12']}]"


def render_body(state: dict) -> str:
    lines = [
        "<!-- Generated by scripts/cmux-next/stability_issues.py on every lab run: comment instead of editing. -->",
        f"**Signature** {code(state['hash12'])}: kind {code(state['kind'])}, process {code(state['process'])}, "
        f"exception {code(state['exception'] or '-')}, source {code(state['source'])}",
        "",
        "Top frames (after scripts/cmux-next/signature-ignore.txt):",
        *[f"{index}. {code(frame)}" for index, frame in enumerate(state["frames"], 1)],
        "",
        "| Seen | Commit | When |",
        "| --- | --- | --- |",
        f"| First | {short(state['first_sha'])} | {state['first_seen'] or '-'} |",
        f"| Last | {short(state['last_sha'])} | {state['last_seen'] or '-'} |",
        "",
        f"Count: {state['count']}. Per major: "
        + (", ".join(f"macOS {major} {count}" if major.isdigit() else f"{major} {count}"
                     for major, count in sorted(state["per_major"].items())) or "-")
        + ". Lanes: " + (", ".join(sorted({f"{lane}@{major}" for lane, major in state["seen_in"]})) or "-") + ".",
        "",
        "Repro:",
    ]
    repro = state["repro"]
    for key, name in (("minimal", "minimal.jsonl"), ("seed", "seed"), ("test_id", "test id"),
                      ("fuzz_input", "fuzz input")):
        lines.append(f"- {name}: {repro[key] if repro.get(key) not in (None, '') else '-'}")
    bisect = state["bisect"]
    if not bisect:
        lines += ["", "Bisect: not run yet."]
    elif bisect.get("result") == "first_bad":
        lines += ["", f"Bisect: first bad commit {bisect['sha']}"
                  + (f" in {bisect['range']}" if bisect.get("range") else "")
                  + (f" ({bisect['evidence']})" if bisect.get("evidence") else "") + "."]
    else:
        lines += ["", f"Bisect: flaky, reproduced {bisect.get('hits', '?')} replays, no commit blamed"
                  + (f" in {bisect['range']}" if bisect.get("range") else "") + "."]
    fix = state["fix"]
    if fix:
        tips = ", ".join(short(sha) for sha in state["clean_tips"]) or "none yet"
        lines += ["", f"Fix: {fix['sha']} verified ({fix.get('evidence') or 'no evidence given'}). "
                  f"Clean tips with the fix: {len(state['clean_tips'])}/{CLEAN_TIPS_TO_CLOSE} ({tips})."]
    else:
        lines += ["", f"Fix: none verified. The issue closes after a verified fix and {CLEAN_TIPS_TO_CLOSE} clean tips."]
    for old in state["fix_history"][-3:]:
        lines.append(f"- Earlier fix {short(old['sha'])} did not hold: seen again on {short(old['recurred_on'])}.")
    if state.get("sentry"):
        lines += ["", "Sentry:"]
        for sentry_id, link in sorted(state["sentry"].items()):
            name = re.sub(r"[^A-Za-z0-9_-]+", "", str(link.get("short_id") or "")) or f"issue {sentry_id}"
            url = str(link.get("url") or "")
            period = f" in the last {link['days']} d" if link.get("days") else ""
            lines.append(f"- {f'[{name}]({url})' if SENTRY_LINK.fullmatch(url) else name} "
                         f"({code(link.get('env') or '-')}): {link.get('events', 0)} events and "
                         f"{link.get('users', 0)} users{period}, first seen {link.get('first_seen') or '-'}, "
                         f"last seen {link.get('last_seen') or '-'}: {code(link.get('title') or '-')}")
    lines += ["", f"<!-- stability-sig-state: {encode_state(state)} -->"]
    return "\n".join(lines)


# --- Planning -----------------------------------------------------------------------------------------------------


@dataclass
class Tracked:
    """One signature's issue as read, and as this run wants it."""

    hash12: str
    issue: Issue | None
    before: dict | None
    state: dict
    reopen: str = ""
    comments: list[str] = field(default_factory=list)
    close: str = ""
    close_duplicates: list[tuple[int, str]] = field(default_factory=list)

    @property
    def is_closed(self) -> bool:
        return self.issue is not None and self.issue.state == "CLOSED"

    def writes(self) -> list[tuple]:
        """The gh writes, in an order where a failure part-way is repaired by the same sync: the body (which
        records the run id and the merged duplicates) is written after a reopen and its comments and before the
        duplicates close, and a close is planned again from the state whenever the issue is still open."""
        state_body = render_body(self.state)
        title = render_title(self.state)
        if self.issue is None:
            return [("create", title, state_body, labels_for(self.state))]
        out: list[tuple] = []
        if self.reopen:
            out.append(("reopen", self.issue.number, self.reopen))
        out += [("comment", self.issue.number, text) for text in self.comments]
        if state_body != self.issue.body or title != self.issue.title:
            out.append(("edit", self.issue.number, title, state_body))
        if self.close:
            out.append(("close", self.issue.number, self.close, "completed"))
        out += [("close", number, text, "not planned") for number, text in self.close_duplicates]
        return out


def index_issues(issues: list[Issue]) -> tuple[dict[str, Issue], dict[str, list[Issue]]]:
    """hash12 -> its issue (the lowest number), and hash12 -> the higher-numbered issues that duplicate it. An issue
    that is also another signature's own issue is never a duplicate to close."""
    by_hash: dict[str, Issue] = {}
    duplicates: dict[str, list[Issue]] = {}
    for issue in sorted(issues, key=lambda item: item.number):
        hashes = {name.split(":", 1)[1] for name in issue.labels if name.startswith(f"{LABEL}:")}
        state = read_state(issue.body)
        if state:
            hashes.add(state["hash12"])
        for hash12 in sorted(hashes):
            if hash12 in by_hash:
                duplicates.setdefault(hash12, []).append(issue)
            else:
                by_hash[hash12] = issue
    owners = {issue.number for issue in by_hash.values()}
    duplicates = {hash12: kept for hash12, dups in duplicates.items()
                  if (kept := [dup for dup in dups if dup.number not in owners])}
    return by_hash, duplicates


def track(hash12: str, by_hash: dict[str, Issue], sig: dict | None = None) -> Tracked:
    issue = by_hash.get(hash12)
    before = read_state(issue.body) if issue else None
    if before is None:
        if sig is None:
            raise StabilityIssueError(f"no stability issue with a state block for {hash12}")
        state = empty_state(sig)
    else:
        state = copy.deepcopy(before)
    return Tracked(hash12=hash12, issue=issue, before=before, state=state)


def merge_state(into: dict, other: dict) -> None:
    """Add a duplicate issue's findings to the signature's state. Fix and clean tips stay the target's."""
    into["count"] += other.get("count", 0)
    for major, count in (other.get("per_major") or {}).items():
        into["per_major"][major] = into["per_major"].get(major, 0) + count
    for key in other.get("seen_in") or []:
        if key not in into["seen_in"]:
            into["seen_in"].append(key)
    if other.get("first_sha") and (not into["first_sha"] or other.get("first_seen", "") < into["first_seen"]):
        into["first_sha"], into["first_seen"] = other["first_sha"], other.get("first_seen", "")
    if other.get("last_sha") and other.get("last_seen", "") >= into["last_seen"]:
        into["last_sha"], into["last_seen"] = other["last_sha"], other.get("last_seen", "")
    for key, value in (other.get("repro") or {}).items():
        if value not in (None, "") and not into["repro"].get(key):
            into["repro"][key] = value
    if not into["bisect"] and other.get("bisect"):
        into["bisect"] = other["bisect"]
    into["runs"] = list(dict.fromkeys(into["runs"] + list(other.get("runs") or [])))[-RUNS_KEPT:]
    for sentry_id, link in (other.get("sentry") or {}).items():
        into.setdefault("sentry", {}).setdefault(sentry_id, link)


def merge_duplicates(t: Tracked, duplicates: list[Issue]) -> None:
    """Heal a race that made two issues for one signature: the higher numbers are merged into this one once (the
    state records them) and closed as not planned."""
    if not duplicates:
        return
    merged = t.state.setdefault("merged", [])
    for dup in duplicates:
        if dup.number not in merged:
            other = read_state(dup.body)
            if other:
                merge_state(t.state, other)
            merged.append(dup.number)
        if dup.state == "OPEN":
            where = f"#{t.issue.number}" if t.issue else "the signature's first issue"
            t.close_duplicates.append((dup.number, f"Duplicate of {where} for signature {t.hash12}; its counts are "
                                                   "merged there. Closed by stability_issues.py."))


def validate_run(run: dict) -> None:
    if run.get("schema") != RUN_SCHEMA:
        raise StabilityIssueError(f"run file schema is {run.get('schema')!r}, expected {RUN_SCHEMA}")
    for key in ("run", "tip"):
        if not isinstance(run.get(key), str) or not run[key]:
            raise StabilityIssueError(f"run file has no {key}")
    for finding in run.get("findings") or []:
        if not HASH12.match(str(finding.get("hash12", ""))):
            raise StabilityIssueError(f"finding without a 12-hex hash12: {finding!r}")


def lane_key(item: dict) -> list[str]:
    return [str(item.get("lane") or ""), str(item.get("major") or "")]


def plan_sync(issues: list[Issue], run: dict,
              is_ancestor: Callable[[str, str], bool | None]) -> tuple[list[Tracked], list[str]]:
    """What one lab run changes. Pure: reads issues as listed, returns the wanted states and notes."""
    validate_run(run)
    run_id, tip = run["run"], run["tip"]
    by_hash, duplicates = index_issues(issues)
    notes = [f"#{dup.number} duplicates #{by_hash[hash12].number} ({hash12}); merged and closed by this sync"
             for hash12, dups in sorted(duplicates.items()) for dup in dups
             if dup.state == "OPEN" or dup.number not in (read_state(by_hash[hash12].body) or {}).get("merged", [])]
    found: dict[str, list[dict]] = {}
    for finding in run.get("findings") or []:
        found.setdefault(finding["hash12"], []).append(finding)
    ran = {tuple(lane_key(item)) for item in run.get("lanes") or []}
    ran |= {tuple(lane_key(item)) for items in found.values() for item in items}

    out: list[Tracked] = []
    for hash12, findings in sorted(found.items()):
        t = track(hash12, by_hash, findings[0])
        merge_duplicates(t, duplicates.get(hash12, []))
        state = t.state
        if run_id in state["runs"]:
            if t.writes():
                out.append(t)
            continue
        for finding in findings:
            sha = finding.get("sha") or tip
            at = finding.get("at") or run.get("at") or ""
            state["count"] += 1
            major = str(finding.get("major") or "unknown")
            state["per_major"][major] = state["per_major"].get(major, 0) + 1
            if lane_key(finding) not in state["seen_in"]:
                state["seen_in"].append(lane_key(finding))
            if not state["first_sha"]:
                state["first_sha"], state["first_seen"] = sha, at
            state["last_sha"], state["last_seen"] = sha, at or state["last_seen"]
            for key, value in (finding.get("repro") or {}).items():
                if value not in (None, "") and not state["repro"].get(key):
                    state["repro"][key] = value
        state["runs"] = (state["runs"] + [run_id])[-RUNS_KEPT:]

        fix = state["fix"]
        note = ""
        if fix:
            # A build git cannot place relative to the fix may contain it: it resets the fix, as a recurrence does.
            ancestry = {sha: is_ancestor(fix["sha"], sha) for sha in sorted({f.get("sha") or tip for f in findings})}
            recurred = [sha for sha, has_fix in ancestry.items() if has_fix is not False]
            if recurred:
                on = recurred[0]
                state["fix_history"].append({"sha": fix["sha"], "recurred_on": on, "run": run_id})
                state["fix"], state["clean_tips"] = None, []
                if ancestry[on] is None:
                    notes.append(f"{hash12}: git could not tell whether build {on} contains fix {fix['sha']}; "
                                 "counted as a recurrence")
                    note = (f" git could not tell whether the build {on} contains the fix {fix['sha']}, so it "
                            "counts as a recurrence")
                else:
                    note = f" The build {on} contains the fix {fix['sha']}"
                note += f" and the fix is reset; closing needs a new verified fix and {CLEAN_TIPS_TO_CLOSE} clean tips."
        # A finding from a build without the verified fix is counted but reopens nothing.
        if t.is_closed and state["fix"] is None and t.issue and t.issue.state_reason in ("COMPLETED", ""):
            t.reopen = f"Recurred on tip {tip} (run {run_id}). Reopened by stability_issues.py.{note}"
        elif t.is_closed and t.issue and t.issue.state_reason in PERSON_CLOSE_REASONS:
            reason = t.issue.state_reason
            if note or state.get("kept_closed") != reason:
                state["kept_closed"] = reason
                t.comments.append(f"Seen again on tip {tip} (run {run_id}). The issue stays closed as "
                                  f"{PERSON_CLOSE_REASONS[reason]}; reopen it to track the signature again.{note}")
        elif note:
            t.comments.append(f"Seen again on tip {tip} (run {run_id}).{note}")
        out.append(t)

    for hash12, issue in sorted(by_hash.items()):
        if hash12 in found:
            continue
        before = read_state(issue.body)
        dups = duplicates.get(hash12, [])
        if before is None:
            # A hand-made issue with the hash label: the first duplicate with a state, if any, becomes its state.
            seed = next((s for s in (read_state(dup.body) for dup in dups) if s), None)
            if seed is None:
                continue
            before_state = empty_state(seed)
        else:
            before_state = copy.deepcopy(before)
        t = Tracked(hash12=hash12, issue=issue, before=before, state=before_state)
        merge_duplicates(t, dups)
        state = t.state
        if issue.state == "OPEN" and state.get("fix"):
            fix_sha = state["fix"]["sha"]
            covered = any(tuple(key) in ran for key in state["seen_in"])
            if covered and tip not in state["clean_tips"]:
                has_fix = is_ancestor(fix_sha, tip)
                if has_fix:
                    state["clean_tips"].append(tip)
                elif has_fix is None:
                    notes.append(f"{hash12}: git could not tell whether tip {tip} contains fix {fix_sha}; "
                                 "the tip is not counted")
                else:
                    notes.append(f"{hash12}: tip {tip} does not contain fix {fix_sha}; the tip is not counted")
            if len(state["clean_tips"]) >= CLEAN_TIPS_TO_CLOSE:
                t.close = (f"Fix {fix_sha} verified and {len(state['clean_tips'])} clean tips "
                           f"({', '.join(short(sha) for sha in state['clean_tips'])}) ran a lane that found this "
                           "signature without finding it. Closed by stability_issues.py; a recurrence reopens it.")
        if t.writes():
            out.append(t)
    return out, notes


def sentry_int(value: object) -> int:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 0


def sentry_hash12(sentry_id: str) -> str:
    return hashlib.sha256(f"sentry:{sentry_id}".encode()).hexdigest()[:12]


def sentry_link(entry: dict, report: dict) -> dict:
    """The state's record of one Sentry issue, from stability-health.py's normalized top_issues entry."""
    return {
        "short_id": str(entry.get("short_id") or ""), "url": str(entry.get("permalink") or ""),
        "env": str(report.get("env") or ""), "days": sentry_int(report.get("days")),
        "title": str(entry.get("title") or ""),
        "events": sentry_int(entry["events"] if "events" in entry else entry.get("count")),
        "users": sentry_int(entry.get("users")),
        "first_seen": str(entry.get("first_seen") or ""), "last_seen": str(entry.get("last_seen") or ""),
    }


def validate_health(report: object) -> list[dict]:
    if not isinstance(report, dict):
        raise StabilityIssueError("the Sentry report is not a JSON object")
    if report.get("schema") != HEALTH_SCHEMA:
        raise StabilityIssueError(f"Sentry report schema is {report.get('schema')!r}, expected {HEALTH_SCHEMA} "
                                  "(stability-health.py --json)")
    entries = report.get("top_issues")
    if not isinstance(entries, list):
        raise StabilityIssueError("the Sentry report has no top_issues list")
    for entry in entries:
        if not isinstance(entry, dict) or not str(entry.get("id") or "").strip():
            raise StabilityIssueError(f"Sentry issue without an id: {entry!r}")
        if not isinstance(entry.get("github", []), list) or not all(
                isinstance(number, int) for number in entry.get("github", [])):
            raise StabilityIssueError(f"Sentry issue {entry['id']} has a github list that is not issue numbers")
        if entry.get("owner") is not None and not isinstance(entry["owner"], dict):
            raise StabilityIssueError(f"Sentry issue {entry['id']} has an owner that is not an object")
    return entries


def plan_sentry(issues: list[Issue], report: dict) -> tuple[list[Tracked], list[str]]:
    """What one stability-health.py report changes. Pure, like plan_sync.

    A Sentry issue already linked from a stability issue's state stays there. A new one joins the stability issue
    that its Sentry annotations name; it is not imported when it names another GitHub issue or another owner claims
    it, and otherwise gets its own signature issue. Only the link is written: fix, clean tips and open/closed state
    are the lab's."""
    entries = validate_health(report)
    by_hash, duplicates = index_issues(issues)
    by_number = {issue.number: hash12 for hash12, issue in by_hash.items()}
    linked: dict[str, str] = {}
    for issue in sorted(issues, key=lambda item: item.number):
        state = read_state(issue.body)
        for sentry_id in (state or {}).get("sentry") or {}:
            linked.setdefault(sentry_id, state["hash12"])

    notes: list[str] = []
    groups: dict[str, list[dict]] = {}
    for entry in entries:
        sentry_id = str(entry["id"]).strip()
        name = str(entry.get("short_id") or sentry_id)
        hash12 = linked.get(sentry_id)
        if hash12 is None and entry.get("owner"):
            owner = entry["owner"]
            notes.append(f"Sentry {name} is claimed by {owner.get('owner')} (#{owner.get('github_issue')}); "
                         "not imported")
            continue
        if hash12 is None and entry.get("github"):
            hash12 = next((by_number[number] for number in entry["github"] if number in by_number), None)
            if hash12 is None:
                notes.append(f"Sentry {name} already links GitHub issue "
                             f"{', '.join(f'#{number}' for number in entry['github'])}; not imported")
                continue
        groups.setdefault(hash12 or sentry_hash12(sentry_id), []).append(entry)

    out: list[Tracked] = []
    for hash12, group in sorted(groups.items()):
        first = group[0]
        culprit = str(first.get("culprit") or "")
        sig = {"hash12": hash12, "kind": "sentry", "process": "", "exception": str(first.get("title") or ""),
               "frames": [culprit] if culprit else [], "source": "sentry"}
        t = track(hash12, by_hash, sig)
        merge_duplicates(t, duplicates.get(hash12, []))
        links = t.state.setdefault("sentry", {})
        for entry in group:
            links[str(entry["id"]).strip()] = sentry_link(entry, report)
        if t.writes():
            out.append(t)
    return out, notes


def plan_bisect(issues: list[Issue], hash12: str, result: dict) -> Tracked:
    t = track(hash12, index_issues(issues)[0])
    t.state["bisect"] = result
    if result != (t.before or {}).get("bisect"):
        if result["result"] == "first_bad":
            t.comments.append(f"Bisect: first bad commit {result['sha']}"
                              + (f" in {result['range']}" if result.get("range") else "")
                              + (f" ({result['evidence']})" if result.get("evidence") else "") + ".")
        else:
            t.comments.append(f"Bisect: flaky, reproduced {result['hits']} replays; no commit blamed.")
    return t


def plan_fix(issues: list[Issue], hash12: str, fix_sha: str, evidence: str) -> Tracked:
    t = track(hash12, index_issues(issues)[0])
    if (t.state.get("fix") or {}).get("sha") != fix_sha:
        t.state["fix"] = {"sha": fix_sha, "evidence": evidence}
        t.state["clean_tips"] = []
        t.comments.append(f"Fix {fix_sha} verified ({evidence}). The issue closes after {CLEAN_TIPS_TO_CLOSE} "
                          "tips that contain it run a lane that found this signature without finding it.")
    return t


# --- Applying -----------------------------------------------------------------------------------------------------


@dataclass
class Outcome:
    applied: list[str] = field(default_factory=list)
    deferred: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    def as_json(self) -> dict:
        return {"applied": self.applied, "deferred": self.deferred, "notes": self.notes}


def apply(tracked: list[Tracked], github: GitHub, max_writes: int, dry_run: bool) -> Outcome:
    """Writes per signature, all of one signature's writes or none, within --max-writes and the rate budget. The
    labels a new issue needs are its own writes, created only when that issue is."""
    outcome = Outcome()
    planned = [(t, t.writes()) for t in tracked]
    planned = [(t, writes) for t, writes in planned if writes]
    have = github.existing_labels() if any(t.issue is None for t, _ in planned) else set()

    def with_labels(t: Tracked, writes: list[tuple], labels: set[str]) -> list[tuple]:
        missing = [name for name in labels_for(t.state) if name not in labels] if t.issue is None else []
        return [("label", name) for name in missing] + writes

    preview, total = set(have), 0
    for t, writes in planned:
        full = with_labels(t, writes, preview)
        preview |= {write[1] for write in full if write[0] == "label"}
        total += len(full)
    budget = {"all": max_writes, "core": total, "graphql": total}
    if not dry_run and total >= BUDGET_CHECK_AT:
        remaining = github.rate_remaining()
        if remaining is not None:
            for bucket in ("core", "graphql"):
                budget[bucket] = max(0, remaining.get(bucket, 0) - RATE_RESERVE)
            outcome.notes.append(f"rate remaining core {remaining.get('core')} graphql {remaining.get('graphql')}, "
                                 f"write budget core {budget['core']} graphql {budget['graphql']}")
    used = {"all": 0, "core": 0, "graphql": 0}
    for t, writes in planned:
        full = with_labels(t, writes, have)
        need = {"all": len(full), "core": sum(1 for write in full if write[0] == "label")}
        need["graphql"] = need["all"] - need["core"]
        # --max-writes never stops the first signature of an invocation, so one that needs more still lands.
        over = [bucket for bucket in used if used[bucket] + need[bucket] > budget[bucket]]
        if over and not (over == ["all"] and used["all"] == 0):
            outcome.deferred.append(t.hash12)
            continue
        for bucket in used:
            used[bucket] += need[bucket]
        for write in full:
            kind, *args = write
            target = f" {args[0]}" if kind == "label" else (f" #{args[0]}" if kind != "create" else "")
            outcome.applied.append(f"{kind} {t.hash12}{target}")
            if kind == "label":
                have.add(args[0])
            if dry_run:
                continue
            if kind == "label":
                github.create_label(*args)
            elif kind == "create":
                github.create_issue(*args)
            elif kind == "edit":
                github.edit_issue(*args)
            elif kind == "comment":
                github.comment(*args)
            elif kind == "close":
                github.close_issue(*args)
            elif kind == "reopen":
                github.reopen_issue(*args)
    return outcome


# --- CLI ----------------------------------------------------------------------------------------------------------


def read_input(args: argparse.Namespace) -> dict | None:
    """The run file or Sentry report, read and checked before the lock: a slow producer on stdin never holds it."""
    if args.cmd not in ("sync", "sentry"):
        return None
    path = args.run if args.cmd == "sync" else args.report
    try:
        data = json.loads(sys.stdin.read() if args.cmd == "sentry" and str(path) == "-" else path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise StabilityIssueError(f"cannot read {path}: {error}") from error
    if not isinstance(data, dict):
        raise StabilityIssueError(f"{path} is not a JSON object")
    if args.cmd == "sentry":
        validate_health(data)
    return data


def plan(args: argparse.Namespace, data: dict | None, github: GitHub,
         is_ancestor: Callable[[str, str], bool | None]) -> tuple[list[Tracked], list[str]]:
    """Read issues and plan inside the caller's lock, so no other sync on this host writes between the read and the
    writes."""
    if args.cmd == "sync":
        return plan_sync(github.list_issues(LABEL), data, is_ancestor)
    if args.cmd == "sentry":
        return plan_sentry(github.list_issues(LABEL), data)
    if not HASH12.match(args.hash12):
        raise StabilityIssueError(f"--hash12 must be 12 lowercase hex characters, got {args.hash12!r}")
    if args.cmd == "bisect-result":
        result = {"result": "first_bad", "sha": args.first_bad} if args.first_bad else {"result": "flaky",
                                                                                         "hits": args.flaky}
        result.update({key: value for key, value in (("range", args.range), ("evidence", args.evidence)) if value})
        return [plan_bisect(github.list_issues(f"{LABEL}:{args.hash12}"), args.hash12, result)], []
    if is_ancestor(args.fix, args.fix) is None:
        raise StabilityIssueError(f"git cannot resolve fix {args.fix} in --git-dir or its --remote; pass the commit "
                                  "as it landed (the squash commit, not a PR head)")
    return [plan_fix(github.list_issues(f"{LABEL}:{args.hash12}"), args.hash12, args.fix, args.evidence)], []


def main(argv: list[str] | None = None, github: GitHub | None = None,
         is_ancestor: Callable[[str, str], bool | None] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", default=DEFAULT_REPO, help="owner/name of the issue tracker (CMUX_STABILITY_REPO)")
    parser.add_argument("--git-dir", type=Path, default=ROOT, help="checkout used for fix-in-tip ancestry checks")
    parser.add_argument("--remote", default="origin",
                        help="remote of --git-dir that commits the checkout lacks are fetched from ('' never fetches)")
    parser.add_argument("--lock-file", type=Path, default=None,
                        help="host lock for one writer per repo (default ~/.cache/cmux/stability-issues-REPO.lock)")
    parser.add_argument("--dry-run", action="store_true", help="read issues, print the writes, write nothing")
    parser.add_argument("--max-writes", type=int, default=60, help="gh writes per invocation; the rest is deferred")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sync = sub.add_parser("sync", help="apply one cmux-stability-run/v1 file")
    sync.add_argument("run", type=Path)
    sentry = sub.add_parser("sentry", help="import stability-health.py --json top issues as signatures")
    sentry.add_argument("report", type=Path, help="stability-health.py --json output, or - for stdin")
    bisect = sub.add_parser("bisect-result", help="record stability_bisect.py's verdict")
    bisect.add_argument("--hash12", required=True)
    verdict = bisect.add_mutually_exclusive_group(required=True)
    verdict.add_argument("--first-bad", metavar="SHA")
    verdict.add_argument("--flaky", metavar="HITS", help="replays that reproduced, e.g. 1/3")
    bisect.add_argument("--range", default="", help="good..bad range searched")
    bisect.add_argument("--evidence", default="", help="URL or job id of the replays")
    fix = sub.add_parser("fix-verified", help="record the fix commit whose build no longer reproduces the signature")
    fix.add_argument("--hash12", required=True)
    fix.add_argument("--fix", required=True, metavar="SHA")
    fix.add_argument("--evidence", required=True, help="the replay or regression test that proves it")
    args = parser.parse_args(argv)

    github = github or GhCli(args.repo)
    is_ancestor = is_ancestor or GitAncestry(args.git_dir, args.remote)
    lock = nullcontext() if args.dry_run else repo_lock(args.lock_file or default_lock_file(args.repo))
    try:
        data = read_input(args)
        with lock:
            tracked, notes = plan(args, data, github, is_ancestor)
            outcome = apply(tracked, github, args.max_writes, args.dry_run)
    except (StabilityIssueError, OSError) as error:
        print(f"stability_issues: {error}", file=sys.stderr)
        return 1
    outcome.notes = notes + outcome.notes
    print(json.dumps(outcome.as_json(), indent=2))
    if outcome.deferred:
        print(f"stability_issues: deferred {len(outcome.deferred)} signatures; run the same command again",
              file=sys.stderr)
        return EX_TEMPFAIL
    return 0


if __name__ == "__main__":
    sys.exit(main())
