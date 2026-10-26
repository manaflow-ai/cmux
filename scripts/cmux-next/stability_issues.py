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
  bisect-result --hash12   record stability_bisect.py's verdict: the first bad commit, or flaky (1-2 of 3 replays).
  fix-verified --hash12    record the fix commit once its repro no longer reproduces on a build that has it.

Rules:
  * Labels stability-sig, stability-sig:<hash12> and stability-kind:<kind>; the issue is found by its hash label.
  * Idempotent: a run id is applied to an issue once (its state block records it), so a repeated sync of the same
    run writes nothing. Two findings of one signature in one run make one issue with count 2.
  * An issue closes only when a fix is verified and 3 distinct tips that contain the fix ran a lane and major that
    found the signature without finding it again. A finding on a tip with the fix resets the fix and the clean
    tips; on a closed issue it reopens it, unless a person closed it as not planned.
  * GitHub reads follow the glaeda-gh read rules: one batched `gh issue list` per invocation, no polling loop, and
    when a run needs many writes the free `gh api rate_limit` read must show 500 requests to spare; writes beyond
    the budget or --max-writes are deferred, exit 75, and the same sync applies them later.

The issue body is generated; a person comments instead of editing it. Its last line holds the state as JSON.

    python3 scripts/cmux-next/stability_issues.py sync run.json --dry-run
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Protocol

DEFAULT_REPO = os.environ.get("CMUX_STABILITY_REPO", "manaflow-ai/cmux")
RUN_SCHEMA = "cmux-stability-run/v1"
LABEL = "stability-sig"
CLEAN_TIPS_TO_CLOSE = 3
RUNS_KEPT = 200
REST_RESERVE = 500
BUDGET_CHECK_AT = 20
EX_TEMPFAIL = 75
HASH12 = re.compile(r"^[0-9a-f]{12}$")
STATE_RE = re.compile(r"<!-- stability-sig-state: (\{.*?\}) -->", re.S)
ROOT = Path(__file__).resolve().parent.parent.parent


class StabilityIssueError(Exception):
    """A bad run file or argument, or a gh call that failed."""


# --- GitHub seam --------------------------------------------------------------------------------------------------


@dataclass
class Issue:
    number: int
    state: str  # OPEN or CLOSED
    state_reason: str  # COMPLETED, NOT_PLANNED, REOPENED or ""
    title: str
    body: str
    labels: list[str]


class GitHub(Protocol):
    def list_issues(self, label: str) -> list[Issue]: ...
    def ensure_labels(self, names: list[str]) -> None: ...
    def create_issue(self, title: str, body: str, labels: list[str]) -> int: ...
    def edit_issue(self, number: int, title: str, body: str) -> None: ...
    def comment(self, number: int, text: str) -> None: ...
    def close_issue(self, number: int, text: str) -> None: ...
    def reopen_issue(self, number: int, text: str) -> None: ...
    def rest_remaining(self) -> int | None: ...


class GhCli:
    """The real GitHub through the gh CLI. Each method is one gh call (reads are batched by the caller)."""

    def __init__(self, repo: str, gh: str = "gh") -> None:
        self.repo = repo
        self.gh = gh

    def _run(self, args: list[str], stdin: str | None = None, scoped: bool = True) -> str:
        command = [self.gh, *args, *(["--repo", self.repo] if scoped else [])]
        proc = subprocess.run(command, input=stdin, text=True, capture_output=True, check=False)
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

    def ensure_labels(self, names: list[str]) -> None:
        # One search covers stability-sig, stability-sig:<hash12> and stability-kind:<kind>.
        out = self._run(["label", "list", "--search", "stability-", "--limit", "2000", "--json", "name"])
        have = {row["name"] for row in json.loads(out or "[]")}
        for name in names:
            if name not in have:
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

    def close_issue(self, number: int, text: str) -> None:
        self._run(["issue", "close", str(number), "--reason", "completed", "--comment", text])

    def reopen_issue(self, number: int, text: str) -> None:
        self._run(["issue", "reopen", str(number), "--comment", text])

    def rest_remaining(self) -> int | None:
        # GET /rate_limit does not count against the quota.
        try:
            out = self._run(["api", "rate_limit", "--jq", ".resources.core.remaining"], scoped=False)
            return int(out.strip())
        except (StabilityIssueError, ValueError):
            return None


def git_is_ancestor(repo_dir: Path) -> Callable[[str, str], bool | None]:
    """True when `ancestor` is in `tip`'s history, None when git does not know one of them."""

    def check(ancestor: str, tip: str) -> bool | None:
        proc = subprocess.run(["git", "-C", str(repo_dir), "merge-base", "--is-ancestor", ancestor, tip],
                              capture_output=True, check=False)
        if proc.returncode in (0, 1):
            return proc.returncode == 0
        return None

    return check


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

    @property
    def is_closed(self) -> bool:
        return self.issue is not None and self.issue.state == "CLOSED"

    def writes(self) -> list[tuple]:
        """The gh writes, in an order where a failure part-way is repaired by the same sync: the body (which
        records the run id) is written after a reopen and its comments, and a close is planned again from the
        state whenever the issue is still open."""
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
            out.append(("close", self.issue.number, self.close))
        return out


def index_issues(issues: list[Issue]) -> tuple[dict[str, Issue], list[str]]:
    """hash12 -> its issue (the lowest number when there are duplicates), and the duplicates found."""
    by_hash: dict[str, Issue] = {}
    duplicates: list[str] = []
    for issue in sorted(issues, key=lambda item: item.number):
        hashes = {name.split(":", 1)[1] for name in issue.labels if name.startswith(f"{LABEL}:")}
        state = read_state(issue.body)
        if state:
            hashes.add(state["hash12"])
        for hash12 in hashes:
            if hash12 in by_hash:
                duplicates.append(f"#{issue.number} duplicates #{by_hash[hash12].number} ({hash12})")
            else:
                by_hash[hash12] = issue
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


def plan_sync(issues: list[Issue], run: dict, is_ancestor: Callable[[str, str], bool | None]) -> tuple[list[Tracked], list[str]]:
    """What one lab run changes. Pure: reads issues as listed, returns the wanted states and notes."""
    validate_run(run)
    run_id, tip = run["run"], run["tip"]
    by_hash, notes = index_issues(issues)
    found: dict[str, list[dict]] = {}
    for finding in run.get("findings") or []:
        found.setdefault(finding["hash12"], []).append(finding)
    ran = {tuple(lane_key(item)) for item in run.get("lanes") or []}
    ran |= {tuple(lane_key(item)) for items in found.values() for item in items}

    out: list[Tracked] = []
    for hash12, findings in sorted(found.items()):
        t = track(hash12, by_hash, findings[0])
        state = t.state
        if run_id in state["runs"]:
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
        with_fix = [sha for sha in {finding.get("sha") or tip for finding in findings}
                    if fix and is_ancestor(fix["sha"], sha)]
        if fix and with_fix:
            state["fix_history"].append({"sha": fix["sha"], "recurred_on": sorted(with_fix)[0], "run": run_id})
            state["fix"], state["clean_tips"] = None, []
            note = (f" The build {sorted(with_fix)[0]} contains the fix {fix['sha']}, so the fix is reset; closing "
                    f"needs a new verified fix and {CLEAN_TIPS_TO_CLOSE} clean tips.")
        # A finding from a build without the verified fix is counted but reopens nothing.
        if t.is_closed and state["fix"] is None and t.issue and t.issue.state_reason != "NOT_PLANNED":
            t.reopen = f"Recurred on tip {tip} (run {run_id}). Reopened by stability_issues.py.{note}"
        elif note:
            t.comments.append(f"Seen again on tip {tip} (run {run_id}).{note}")
        out.append(t)

    for hash12, issue in sorted(by_hash.items()):
        if hash12 in found or issue.state != "OPEN":
            continue
        before = read_state(issue.body)
        if not before or not before.get("fix"):
            continue
        t = Tracked(hash12=hash12, issue=issue, before=before, state=copy.deepcopy(before))
        state = t.state
        covered = any(tuple(key) in ran for key in state["seen_in"])
        if covered and tip not in state["clean_tips"] and is_ancestor(state["fix"]["sha"], tip):
            state["clean_tips"].append(tip)
        if len(state["clean_tips"]) >= CLEAN_TIPS_TO_CLOSE:
            t.close = (f"Fix {state['fix']['sha']} verified and {len(state['clean_tips'])} clean tips "
                       f"({', '.join(short(sha) for sha in state['clean_tips'])}) ran a lane that found this "
                       "signature without finding it. Closed by stability_issues.py; a recurrence reopens it.")
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
    """Writes per signature, all of one signature's writes or none, within --max-writes and the REST budget."""
    outcome = Outcome()
    planned = [(t, t.writes()) for t in tracked]
    planned = [(t, writes) for t, writes in planned if writes]
    total = sum(len(writes) for _, writes in planned)
    budget = max_writes
    if not dry_run and total >= BUDGET_CHECK_AT:
        remaining = github.rest_remaining()
        if remaining is not None:
            budget = min(budget, max(0, remaining - REST_RESERVE))
            outcome.notes.append(f"REST remaining {remaining}, write budget {budget}")
    creating = [t for t, _ in planned if t.issue is None]
    if not dry_run and creating:
        github.ensure_labels(sorted({name for t in creating for name in labels_for(t.state)}))
    used = 0
    for t, writes in planned:
        if used + len(writes) > budget:
            outcome.deferred.append(t.hash12)
            continue
        used += len(writes)
        for write in writes:
            outcome.applied.append(f"{write[0]} {t.hash12}" + (f" #{write[1]}" if write[0] != "create" else ""))
            if dry_run:
                continue
            kind, *args = write
            if kind == "create":
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


def main(argv: list[str] | None = None, github: GitHub | None = None,
         is_ancestor: Callable[[str, str], bool | None] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", default=DEFAULT_REPO, help="owner/name of the issue tracker (CMUX_STABILITY_REPO)")
    parser.add_argument("--git-dir", type=Path, default=ROOT, help="checkout used for fix-in-tip ancestry checks")
    parser.add_argument("--dry-run", action="store_true", help="read issues, print the writes, write nothing")
    parser.add_argument("--max-writes", type=int, default=60, help="gh writes per invocation; the rest is deferred")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sync = sub.add_parser("sync", help="apply one cmux-stability-run/v1 file")
    sync.add_argument("run", type=Path)
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
    is_ancestor = is_ancestor or git_is_ancestor(args.git_dir)
    try:
        if args.cmd == "sync":
            try:
                run = json.loads(args.run.read_text())
            except (OSError, json.JSONDecodeError) as error:
                raise StabilityIssueError(f"cannot read {args.run}: {error}") from error
            tracked, notes = plan_sync(github.list_issues(LABEL), run, is_ancestor)
        else:
            if not HASH12.match(args.hash12):
                raise StabilityIssueError(f"--hash12 must be 12 lowercase hex characters, got {args.hash12!r}")
            issues = github.list_issues(f"{LABEL}:{args.hash12}")
            notes = []
            if args.cmd == "bisect-result":
                result = ({"result": "first_bad", "sha": args.first_bad} if args.first_bad
                          else {"result": "flaky", "hits": args.flaky})
                result.update({key: value for key, value in (("range", args.range), ("evidence", args.evidence))
                               if value})
                tracked = [plan_bisect(issues, args.hash12, result)]
            else:
                tracked = [plan_fix(issues, args.hash12, args.fix, args.evidence)]
        outcome = apply(tracked, github, args.max_writes, args.dry_run)
    except StabilityIssueError as error:
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
