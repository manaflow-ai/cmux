#!/usr/bin/env python3
"""List, and optionally close, agent PRs whose change already landed or that went quiet.

Run nightly by .github/workflows/stale-agent-prs.yml. It reads every open PR
by the agent author (teamleaderleo, the account every cmux agent opens PRs
from; never another author, whose PRs only a human may close) in batched
GraphQL and scores each one against its base branch: the share of the lines it
adds that are already in the base's copy of each file. Generated files
(xcstrings, lockfiles, project.pbxproj), blank lines, imports and comments are
not scored, and only lines of 8+ characters count.

Verdicts:

- close "landed": 100% of the scored added lines are on the base, every scored
  line it removes is gone from the base, and nobody pushed or commented for
  LANDED_IDLE_DAYS. The comment names the base commit it was checked against
  and the successor PR when a merged PR said "supersedes #N".
- list "mostly landed N%": 85-99%. Real remainders hide here (2026-10-18: #21253
  at 95% and #21318 at 87% each still had code and tests missing), and some
  fixes land refactored, so a human reads the hunks.
- list "superseded": a merged PR says "supersedes / replaces / re-cut of #N",
  but the lines haven't all landed. A lead, not proof.
- list "stale, red or conflicting": no push and no human comment for
  STALE_DAYS, and its checks are red or it conflicts with its base.
- list "security", or "stacked on deleted X" when a stacked PR's base branch
  is gone: never closed by this script. A stacked PR whose base still exists
  is left to its base PR.
- skip: a keep label (KEEP_LABELS), a last human comment that hands a
  decision to someone by @-mention, or any push or human
  comment in the last 12 hours (re-read right before closing, since other
  sessions close the same PRs).

A merged PR that only reuses the same head branch name is not a successor:
#15911 reused a merged branch for a different fix. A pending review request
is not a skip: CODEOWNERS requests one on most PRs automatically. Activity is the head
commit's date and the latest comment or review by a human or agent other than
the bots in BOT_LOGINS; GitHub's updatedAt moves with bot comments and bulk
label sweeps (the 2026-10-13 sweep touched about 60 PRs at once).

Report mode (the default) writes the list to stdout and the step summary.
CLOSE=1 closes "landed" PRs, at most MAX_CLOSE per run. Rules agreed with the
stale-closer session after its 2026-10-18 hand sweep of about 400 PRs.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import PurePosixPath

BASES = ("main", "feat-cmux-next")
KEEP_LABELS = {"keep-open", "do-not-close", "exploration", "merge-freeze", "dev-build", "blocked"}
BOT_LOGINS = {
    "coderabbitai", "cursor", "github-actions", "blacksmith-sh", "chatgpt-codex-connector",
    "vercel", "cla-assistant", "claude", "copilot-pull-request-reviewer", "greptile-apps",
}
SECURITY = re.compile(r"\b(security|cve-\d+|vuln\w*|acl|ghsa-[\w-]+|authz|authorization)\b", re.IGNORECASE)
MENTION = re.compile(r"(?<![\w`/])@([A-Za-z0-9][\w-]*)")
SUCCESSOR = re.compile(r"\b(?:supersedes|replaces|re-?cut of)\s+((?:[\w.-]+/[\w.-]+)?#\d+(?:\s*(?:,|and)\s*#\d+)*)", re.IGNORECASE)
GENERATED = re.compile(r"(\.xcstrings|\.lock|\.lockb|package-lock\.json|Package\.resolved|\.pbxproj|\.snap|\.svg|\.min\.js)$")
SKIP_LINE = re.compile(r"^(import\s|@_?implementationOnly import|from\s+\S+\s+import\s|use\s|#include|#import|//|/\*|\*|#(?!!)|<!--|--\s)")
MOSTLY = 0.85
RECENT = dt.timedelta(hours=12)

OPEN_QUERY = """
query($q: String!, $after: String) {
  search(query: $q, type: ISSUE, first: 40, after: $after) {
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest {
      number title body isDraft baseRefName headRefName createdAt mergeable
      labels(first: 20) { nodes { name } }
      commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state } } } }
      comments(last: 20) { nodes { author { login } createdAt body } }
      reviews(last: 10) { nodes { author { login } submittedAt } }
    } }
  }
}
"""

MERGED_QUERY = """
query($q: String!, $after: String) {
  search(query: $q, type: ISSUE, first: 100, after: $after) {
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest { number body } }
  }
}
"""


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def is_bot(login: str | None) -> bool:
    if not login:
        return True
    login = login.lower()
    return login.endswith("[bot]") or login in BOT_LOGINS


@dataclass
class Score:
    present: int = 0
    total: int = 0
    removed_left: int = 0
    unreadable: int = 0

    @property
    def share(self) -> float:
        return self.present / self.total if self.total else 0.0

    @property
    def landed(self) -> bool:
        return self.total > 0 and self.present == self.total and not self.removed_left and not self.unreadable


@dataclass
class Verdict:
    number: int
    title: str
    action: str  # close | list | skip | keep
    reason: str
    idle_days: int
    successor: int | None = None


def scored(line: str) -> str | None:
    text = line.strip()
    if len(text) < 8 or SKIP_LINE.match(text):
        return None
    return text


def score(files: list[dict], base_text: dict[str, str | None]) -> Score:
    """How much of the PR's diff is already on the base.

    Added lines must appear in the base copy of their file, and scored removed
    lines must be gone from it. A file the base no longer has, or a patch
    GitHub didn't return (binary or too large), makes the score unreadable,
    which never closes.
    """
    result = Score()
    for entry in files:
        path = entry["filename"]
        if GENERATED.search(PurePosixPath(path).name):
            continue
        base = base_text.get(path)
        if entry.get("status") == "removed":
            result.removed_left += base is not None
            continue
        patch = entry.get("patch")
        if patch is None or base is None:
            result.unreadable += 1
            continue
        have = {line.strip() for line in base.splitlines()}
        for line in patch.splitlines():
            if line[:1] not in ("+", "-") or line.startswith(("+++", "---")):
                continue
            text = scored(line[1:])
            if text is None:
                continue
            if line[0] == "+":
                result.total += 1
                result.present += text in have
            elif text in have:
                result.removed_left += 1
    return result


def human_comments(pr: dict) -> list[dict]:
    return [n for n in pr["comments"]["nodes"] if not is_bot((n.get("author") or {}).get("login"))]


def last_activity(pr: dict) -> dt.datetime:
    times = [parse_time(pr["createdAt"])]
    times += [parse_time(n["commit"]["committedDate"]) for n in pr["commits"]["nodes"]]
    times += [parse_time(n["createdAt"]) for n in human_comments(pr)]
    times += [parse_time(n["submittedAt"]) for n in pr["reviews"]["nodes"] if n.get("submittedAt") and not is_bot((n.get("author") or {}).get("login"))]
    return max(times)


def skip_reason(pr: dict, now: dt.datetime) -> str | None:
    labels = {n["name"].lower() for n in pr["labels"]["nodes"]}
    kept = labels & KEEP_LABELS
    if kept:
        return f"label {sorted(kept)[0]}"
    human = human_comments(pr)
    if human:
        match = MENTION.search(human[-1]["body"] or "")
        if match:
            return f"waiting on @{match.group(1)}"
    if now - last_activity(pr) < RECENT:
        return "touched in the last 12 hours"
    return None


def list_only_reason(pr: dict, live_branches: set[str] | None = None) -> str | None:
    """PRs a human always decides: listed, never closed.

    A stacked PR is left alone while its base branch exists; once the base is
    deleted (merged or abandoned) it is listed for a human to retarget or close.
    """
    if pr["baseRefName"] not in BASES:
        if live_branches is not None and pr["baseRefName"] in live_branches:
            return "stacked"
        return f"stacked on deleted {pr['baseRefName']}"
    if SECURITY.search(pr["title"]) or any("security" in n["name"].lower() for n in pr["labels"]["nodes"]):
        return "security"
    return None


def red_or_conflicting(pr: dict) -> bool:
    if pr.get("mergeable") == "CONFLICTING":
        return True
    states = [(n["commit"].get("statusCheckRollup") or {}).get("state") for n in pr["commits"]["nodes"]]
    return any(state in {"FAILURE", "ERROR"} for state in states)


def classify(pr: dict, *, now: dt.datetime, score: Score | None, successor: int | None, stale_days: int, landed_idle_days: int,
             live_branches: set[str] | None = None) -> Verdict:
    idle = (now - last_activity(pr)).days
    verdict = Verdict(pr["number"], pr["title"], "keep", "active", idle, successor)
    reason = skip_reason(pr, now)
    if reason:
        verdict.action, verdict.reason = "skip", reason
        return verdict
    reason = list_only_reason(pr, live_branches)
    if reason == "stacked":
        pass  # base branch still exists: its own PR decides
    elif reason:
        verdict.action, verdict.reason = "list", reason
    elif score and score.landed and idle >= landed_idle_days:
        verdict.action, verdict.reason = "close", "landed"
    elif score and score.landed:
        pass  # landed but touched within LANDED_IDLE_DAYS: a later night closes it
    elif score and score.total and score.share >= MOSTLY:
        verdict.action, verdict.reason = "list", f"mostly landed {int(score.share * 100)}%"
    elif successor:
        verdict.action, verdict.reason = "list", "superseded"
    elif idle >= stale_days and red_or_conflicting(pr):
        verdict.action, verdict.reason = "list", "stale, red or conflicting"
    return verdict


def successors(merged_prs: list[dict], repo: str) -> dict[int, int]:
    found: dict[int, int] = {}
    for pr in merged_prs:
        for match in SUCCESSOR.finditer(pr.get("body") or ""):
            for ref in re.findall(r"(?:([\w.-]+/[\w.-]+))?#(\d+)", match.group(1)):
                if ref[0] and ref[0].lower() != repo.lower():
                    continue
                found.setdefault(int(ref[1]), pr["number"])
    return found


def close_comment(verdict: Verdict, base: str, base_sha: str) -> str:
    where = f"#{verdict.successor}" if verdict.successor else "another PR"
    return (
        f"Landed through {where}: every line this PR adds is already on `{base}` at {base_sha[:10]}, "
        f"and the lines it removes are gone. No push or human comment for {verdict.idle_days} days. "
        f"Closing; the branch is kept, so reopen it or re-cut from `{base}` if something is missing. "
        "(stale-agent-prs.yml)"
    )


# ---- GitHub and git I/O (gh CLI; GH_TOKEN comes from the workflow) -----------------------------


def gh_json(*args: str) -> object:
    out = subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout
    return json.loads(out) if out.strip() else None


def search(query: str, q: str) -> list[dict]:
    nodes, after = [], None
    while True:
        args = ["api", "graphql", "-f", f"query={query}", "-f", f"q={q}"]
        if after:
            args += ["-f", f"after={after}"]
        data = gh_json(*args)["data"]["search"]
        nodes += [n for n in data["nodes"] if n]
        if not data["pageInfo"]["hasNextPage"]:
            return nodes
        after = data["pageInfo"]["endCursor"]


def pr_files(repo: str, number: int) -> list[dict]:
    files: list[dict] = []
    for page in range(1, 31):  # GitHub lists at most 3000 files
        batch = gh_json("api", f"repos/{repo}/pulls/{number}/files?per_page=100&page={page}")
        files += batch
        if len(batch) < 100:
            break
    return files


def base_file(base: str, path: str) -> str | None:
    result = subprocess.run(["git", "show", f"origin/{base}:{path}"], capture_output=True, text=True, errors="replace")
    return result.stdout if result.returncode == 0 else None


def base_sha(base: str) -> str:
    return subprocess.run(["git", "rev-parse", f"origin/{base}"], check=True, capture_output=True, text=True).stdout.strip()


def remote_branches(names: set[str]) -> set[str]:
    """Which of these branch names exist on origin (one ls-remote, no API quota)."""
    if not names:
        return set()
    out = subprocess.run(["git", "ls-remote", "--heads", "origin", *sorted(names)], check=True, capture_output=True, text=True).stdout
    return {line.split("refs/heads/", 1)[1] for line in out.splitlines() if "refs/heads/" in line}


def still_quiet(repo: str, number: int, since: dt.datetime) -> bool:
    """Re-read the PR right before closing: another session may have touched it."""
    pr = gh_json("pr", "view", str(number), "-R", repo, "--json", "state,commits,comments")
    if pr["state"] != "OPEN":
        return False
    times = [parse_time(c["committedDate"]) for c in pr["commits"][-1:]]
    times += [parse_time(c["createdAt"]) for c in pr["comments"] if not is_bot((c.get("author") or {}).get("login"))]
    return all(t <= since for t in times)


def main() -> int:
    repo = os.environ.get("GH_REPO", "manaflow-ai/cmux")
    author = os.environ.get("AGENT_AUTHOR", "teamleaderleo")
    stale_days = int(os.environ.get("STALE_DAYS", "14"))
    landed_idle_days = int(os.environ.get("LANDED_IDLE_DAYS", "3"))
    close = os.environ.get("CLOSE", "0") in {"1", "true"}
    max_close = int(os.environ.get("MAX_CLOSE", "25"))
    now = dt.datetime.now(dt.timezone.utc)

    open_prs = search(OPEN_QUERY, f"repo:{repo} is:pr is:open author:{author}")
    since = (now - dt.timedelta(days=60)).date().isoformat()
    merged = search(MERGED_QUERY, f"repo:{repo} is:pr is:merged merged:>={since} in:body supersedes OR replaces OR re-cut")
    successor_of = successors(merged, repo)
    heads = {base: base_sha(base) for base in BASES}
    live = remote_branches({pr["baseRefName"] for pr in open_prs} - set(BASES))

    verdicts = []
    for pr in sorted(open_prs, key=lambda p: p["number"]):
        result = None
        if not skip_reason(pr, now) and not list_only_reason(pr) and (now - last_activity(pr)).days >= landed_idle_days:
            try:
                files = pr_files(repo, pr["number"])
            except subprocess.CalledProcessError as error:
                print(f"#{pr['number']}: cannot read files, not scored: {error.stderr.strip()[:200]}", file=sys.stderr)
            else:
                result = score(files, {f["filename"]: base_file(pr["baseRefName"], f["filename"]) for f in files})
        verdicts.append((pr, classify(pr, now=now, score=result, successor=successor_of.get(pr["number"]),
                                      stale_days=stale_days, landed_idle_days=landed_idle_days, live_branches=live)))

    closed = 0
    lines = [
        f"## Stale agent PRs ({'closing' if close else 'dry run: nothing closed'})",
        "",
        f"{len(open_prs)} open PRs by {author}. Close: fully landed on the base and idle {landed_idle_days}+ days. "
        f"List: {int(MOSTLY * 100)}-99% landed, superseded, security, stacked, or idle {stale_days}+ days and red or conflicting.",
        "",
        "| PR | Verdict | Idle days | Title |",
        "| --- | --- | --- | --- |",
    ]
    for pr, verdict in verdicts:
        if verdict.action == "keep":
            continue
        label = f"{verdict.action}: {verdict.reason}" + (f" (successor #{verdict.successor})" if verdict.successor else "")
        if close and verdict.action == "close" and closed < max_close:
            if still_quiet(repo, verdict.number, now - RECENT):
                base = pr["baseRefName"]
                subprocess.run(["gh", "pr", "close", str(verdict.number), "-R", repo, "--comment", close_comment(verdict, base, heads[base])], check=True)
                closed += 1
                label += ", closed"
            else:
                label += ", touched since the scan; left open"
        title = verdict.title.replace("|", "\\|")
        lines.append(f"| #{verdict.number} | {label} | {verdict.idle_days} | {title} |")
    counts = {a: sum(1 for _, v in verdicts if v.action == a) for a in ("close", "list", "skip", "keep")}
    lines += ["", f"close {counts['close']}, list {counts['list']}, skip {counts['skip']}, active {counts['keep']}; closed {closed}."]
    report = "\n".join(lines) + "\n"
    print(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
