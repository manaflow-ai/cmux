#!/usr/bin/env python3
"""List, and optionally close, agent PRs that have landed elsewhere or gone quiet.

Run nightly by .github/workflows/stale-agent-prs.yml. It reads every open PR
by the agent author (default teamleaderleo, the account every cmux agent opens
PRs from) in batched GraphQL, then sorts each into one verdict:

- close "landed": every line the PR adds is already in the base branch's copy
  of that file, and nobody has pushed or commented for LANDED_IDLE_DAYS. The
  work reached the base through another PR or a safe-push train.
- "superseded": a merged PR says "supersedes #N", "replaces #N" or
  "re-cut of #N" for this PR. Closed, with the comment linking the successor,
  only when it has also landed by the rule above; otherwise listed with the
  successor for a human. A merged PR that only reuses the same branch name
  does not count: #15911 reused a merged branch for a different fix.
- list "stale": no push and no human comment for STALE_DAYS. Listed for a
  human to decide, never closed by this script.
- skip: labelled to keep (KEEP_LABELS), security work, a stacked PR (base
  other than main or feat-cmux-next), or a PR waiting on a named person (a
  pending review request, or "waiting on @login" in the body or last comment).

Activity is the head commit's date and the latest comment or review by a human
other than the bots in BOT_LOGINS. GitHub's updatedAt is not used: bot comments
and bulk label sweeps move it without anyone touching the work.

Report mode (the default) only writes the list to stdout and, in Actions, to
the step summary. CLOSE=1 closes "landed" and "superseded" PRs with one
comment naming the reason, at most MAX_CLOSE per run. Only "landed" PRs are
ever closed (rules agreed with the stale-closer session, 2026-10-18).
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field

BASES = {"main", "feat-cmux-next"}
KEEP_LABELS = {"keep-open", "do-not-close", "exploration", "security", "merge-freeze", "dev-build", "blocked"}
BOT_LOGINS = {
    "coderabbitai", "cursor", "github-actions", "blacksmith-sh", "chatgpt-codex-connector",
    "vercel", "cla-assistant", "claude", "copilot-pull-request-reviewer", "greptile-apps",
}
SECURITY = re.compile(r"\b(security|cve-\d|vuln|secret leak|ghsa-)", re.IGNORECASE)
WAITING = re.compile(r"\b(waiting|blocked) (on|for) @([\w-]+)", re.IGNORECASE)
SUCCESSOR = re.compile(r"\b(?:supersedes|replaces|re-?cut of)\s+((?:[\w.-]+/[\w.-]+)?#\d+(?:\s*(?:,|and)\s*#\d+)*)", re.IGNORECASE)

OPEN_QUERY = """
query($q: String!, $after: String) {
  rateLimit { cost remaining }
  search(query: $q, type: ISSUE, first: 50, after: $after) {
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest {
      number title body isDraft baseRefName headRefName createdAt
      labels(first: 20) { nodes { name } }
      reviewRequests(first: 5) { nodes { requestedReviewer { ... on User { login } ... on Team { slug } } } }
      commits(last: 1) { nodes { commit { committedDate } } }
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
class Verdict:
    number: int
    title: str
    action: str  # close | list | skip | keep
    reason: str
    idle_days: int
    successor: int | None = None
    notes: list[str] = field(default_factory=list)


def last_activity(pr: dict) -> dt.datetime:
    times = [parse_time(pr["createdAt"])]
    times += [parse_time(n["commit"]["committedDate"]) for n in pr["commits"]["nodes"]]
    times += [parse_time(n["createdAt"]) for n in pr["comments"]["nodes"] if not is_bot((n.get("author") or {}).get("login"))]
    times += [parse_time(n["submittedAt"]) for n in pr["reviews"]["nodes"] if n.get("submittedAt") and not is_bot((n.get("author") or {}).get("login"))]
    return max(times)


def skip_reason(pr: dict) -> str | None:
    labels = {n["name"].lower() for n in pr["labels"]["nodes"]}
    kept = labels & KEEP_LABELS
    if kept:
        return f"label {sorted(kept)[0]}"
    if pr["baseRefName"] not in BASES:
        return f"stacked on {pr['baseRefName']}"
    if SECURITY.search(pr["title"]) or any("security" in label for label in labels):
        return "security"
    if pr["reviewRequests"]["nodes"]:
        return "review requested"
    human = [n for n in pr["comments"]["nodes"] if not is_bot((n.get("author") or {}).get("login"))]
    for text in (pr.get("body") or "", human[-1]["body"] if human else ""):
        match = WAITING.search(text)
        if match:
            return f"waiting on @{match.group(3)}"
    return None


def classify(pr: dict, *, now: dt.datetime, landed: bool | None, successor: int | None, stale_days: int, landed_idle_days: int) -> Verdict:
    idle = (now - last_activity(pr)).days
    verdict = Verdict(pr["number"], pr["title"], "keep", "active", idle, successor)
    reason = skip_reason(pr)
    if reason:
        verdict.action, verdict.reason = "skip", reason
    elif landed and idle >= landed_idle_days:
        verdict.action, verdict.reason = "close", "superseded" if successor else "landed"
    elif successor and idle >= landed_idle_days:
        verdict.action, verdict.reason = "list", "superseded"
    elif idle >= stale_days:
        verdict.action, verdict.reason = "list", "stale"
    return verdict


def added_lines_landed(files: list[dict], base_text: dict[str, str | None]) -> bool:
    """True when every non-blank line the PR adds is already in the base copy of its file.

    A PR must add at least one substantive line (8+ characters): a deletion-only
    or brace-only diff proves nothing and is kept.
    """
    if not files:
        return False
    substantive = False
    for entry in files:
        patch = entry.get("patch")
        if entry.get("status") == "removed":
            if base_text.get(entry["filename"]) is not None:
                return False
            continue
        if patch is None:
            return False  # binary or too large to compare: keep it
        base = base_text.get(entry["filename"])
        if base is None:
            return False
        have = {line.strip() for line in base.splitlines()}
        for line in patch.splitlines():
            if line.startswith("+") and not line.startswith("+++"):
                text = line[1:].strip()
                if text and text not in have:
                    return False
                substantive = substantive or len(text) >= 8
    return substantive


def successors(merged_prs: list[dict], repo: str) -> dict[int, int]:
    found: dict[int, int] = {}
    for pr in merged_prs:
        for match in SUCCESSOR.finditer(pr.get("body") or ""):
            for ref in re.findall(r"(?:([\w.-]+/[\w.-]+))?#(\d+)", match.group(1)):
                if ref[0] and ref[0].lower() != repo.lower():
                    continue
                found.setdefault(int(ref[1]), pr["number"])
    return found


def close_comment(verdict: Verdict, base: str) -> str:
    if verdict.reason == "superseded":
        why = f"Superseded by #{verdict.successor}, which merged, and every line this PR adds is already on `{base}`."
    else:
        why = f"Every line this PR adds is already on `{base}`, so the change landed through another PR."
    return (
        f"{why} No push or human comment for {verdict.idle_days} days. Closing; "
        "reopen it if something here is still missing. (stale-agent-prs.yml)"
    )


# ---- GitHub I/O (gh CLI; GH_TOKEN comes from the workflow) -------------------------------------


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
    pages = gh_json("api", "--paginate", "--slurp", f"repos/{repo}/pulls/{number}/files?per_page=100")
    return [entry for page in pages for entry in page]


def base_file(base: str, path: str) -> str | None:
    result = subprocess.run(["git", "show", f"origin/{base}:{path}"], capture_output=True, text=True, errors="replace")
    return result.stdout if result.returncode == 0 else None


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

    verdicts = []
    for pr in sorted(open_prs, key=lambda p: p["number"]):
        landed = None
        if not skip_reason(pr) and (now - last_activity(pr)).days >= landed_idle_days:
            files = pr_files(repo, pr["number"])
            landed = added_lines_landed(files, {f["filename"]: base_file(pr["baseRefName"], f["filename"]) for f in files})
        verdicts.append((pr, classify(pr, now=now, landed=landed, successor=successor_of.get(pr["number"]),
                                      stale_days=stale_days, landed_idle_days=landed_idle_days)))

    closed = 0
    lines = [
        f"## Stale agent PRs ({'closing' if close else 'dry run: nothing closed'})",
        "",
        f"{len(open_prs)} open PRs by {author}. Close: every added line already on the base, idle {landed_idle_days}+ days. "
        f"List: superseded but not landed, or idle {stale_days}+ days.",
        "",
        "| PR | Verdict | Idle days | Title |",
        "| --- | --- | --- | --- |",
    ]
    for pr, verdict in verdicts:
        if verdict.action == "keep":
            continue
        label = f"{verdict.action}: {verdict.reason}" + (f" by #{verdict.successor}" if verdict.successor else "")
        if close and verdict.action == "close" and closed < max_close:
            subprocess.run(["gh", "pr", "close", str(verdict.number), "-R", repo, "--comment", close_comment(verdict, pr["baseRefName"])], check=True)
            closed += 1
            label += " (closed)"
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
