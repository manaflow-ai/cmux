#!/usr/bin/env python3
"""Build a compact current-attention feed from GitHub issue and PR metadata."""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from typing import Any


API = "https://api.github.com"
RADAR_TITLE_PREFIX = "[Triage Radar]"
START_MARKER = "<!-- triage-radar:start -->"
END_MARKER = "<!-- triage-radar:end -->"

STOP_WORDS = {
    "a", "about", "after", "again", "all", "also", "an", "and", "another", "are", "as", "at",
    "be", "because", "before", "but", "by", "can", "cmux", "could", "custom", "does", "for",
    "from", "has", "have", "how", "i", "in", "into", "is", "it", "its", "keeps", "latest",
    "new", "of", "on", "or", "our", "please", "request", "rfc", "setting", "should", "still",
    "support", "that", "the", "their", "this", "to", "under", "use", "using", "version", "when", "with",
    "without", "work", "works",
}

BROAD_CLUSTER_TERMS = {
    "agent", "app", "browser", "build", "cloud", "connect", "display", "ios", "machine", "pane",
    "relay", "remote", "session", "sidebar", "ssh", "terminal", "window", "workspace",
}

STRONG_CLUSTER_TERMS = {
    "auth", "crash", "drag", "drop", "fail", "freeze", "hang", "index", "input", "reorder",
    "route", "socket",
}

NORMALIZE_PREFIXES = {
    "auth": "auth",
    "connect": "connect",
    "crash": "crash",
    "drag": "drag",
    "drop": "drop",
    "fail": "fail",
    "freez": "freeze",
    "hang": "hang",
    "reorder": "reorder",
    "reject": "reject",
    "rout": "route",
    "session": "session",
    "sidebar": "sidebar",
    "terminal": "terminal",
    "workspace": "workspace",
}

HIGH_RISK_PATTERNS: list[tuple[re.Pattern[str], int, str]] = [
    (re.compile(r"\b(crash(?:es|ed|ing)?|panic)\b", re.I), 6, "crash/panic"),
    (re.compile(r"\b(deadlock|freeze[sd]?|frozen|hang(?:s|ing)?)\b", re.I), 5, "hang/freeze"),
    (re.compile(r"\b(data loss|los(?:e|es|t) (?:data|session|state)|session(?:s)? (?:are )?lost)\b", re.I), 6, "data/session loss"),
    (re.compile(r"\b(wrong (?:terminal|pane|workspace|target)|route[sd]? to (?:the )?wrong)\b", re.I), 5, "wrong-target routing"),
    (re.compile(r"\b(cannot connect|can't connect|could not connect|connection fail|auth(?:entication)? fail)\b", re.I), 4, "connectivity/auth failure"),
    (re.compile(r"\b(unusable|unresponsive|stuck|wedged)\b", re.I), 3, "unusable/stuck"),
    (re.compile(r"\b(regression|regressed|previously worked|used to work)\b", re.I), 3, "regression wording"),
]

NIGHTLY_YES = re.compile(
    r"Can you reproduce this on cmux NIGHTLY\?.*?Yes, it still reproduces on NIGHTLY",
    re.I | re.S,
)
NIGHTLY_NO = re.compile(
    r"Can you reproduce this on cmux NIGHTLY\?.*?No, it does not reproduce on NIGHTLY",
    re.I | re.S,
)
TITLE_VERSION = re.compile(r"\b\d+\.\d+\.\d+\b")


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def clean_inline(value: str) -> str:
    value = " ".join(value.replace("\r", " ").replace("\n", " ").split())
    return value.replace("<!--", "&lt;!--").replace("-->", "--&gt;")


def normalize_token(token: str) -> str:
    token = token.lower()
    for prefix, normalized in NORMALIZE_PREFIXES.items():
        if token.startswith(prefix):
            return normalized
    if len(token) > 5 and token.endswith("ing"):
        token = token[:-3]
    elif len(token) > 4 and token.endswith("ed"):
        token = token[:-2]
    elif len(token) > 4 and token.endswith("s"):
        token = token[:-1]
    return token


def title_tokens(title: str) -> set[str]:
    raw = re.findall(r"[a-zA-Z][a-zA-Z0-9]*", title.replace("-", " "))
    tokens = {normalize_token(token) for token in raw}
    return {token for token in tokens if len(token) >= 3 and token not in STOP_WORDS}


def labels(item: dict[str, Any]) -> set[str]:
    result: set[str] = set()
    for label in item.get("labels") or []:
        if isinstance(label, str):
            result.add(label.lower())
        elif isinstance(label, dict) and label.get("name"):
            result.add(str(label["name"]).lower())
    return result


def issue_number(item: dict[str, Any]) -> int:
    return int(item["number"])


def reporter(item: dict[str, Any]) -> str:
    user = item.get("user") or {}
    return str(user.get("login") or "unknown")


def reaction_count(item: dict[str, Any]) -> int:
    reactions = item.get("reactions") or {}
    return int(reactions.get("total_count") or 0)


def attention_count(item: dict[str, Any]) -> int:
    return int(item.get("comments") or 0) + reaction_count(item)


def regression_evidence(item: dict[str, Any]) -> tuple[int, list[str]]:
    title = str(item.get("title") or "")
    body = str(item.get("body") or "")
    is_bug = "bug" in labels(item)
    risk_text = title + ("\n" + body if is_bug else "")
    score = 1 if is_bug else 0
    evidence: list[str] = []

    for pattern, points, name in HIGH_RISK_PATTERNS:
        if pattern.search(risk_text):
            score += points
            evidence.append(name)

    if NIGHTLY_YES.search(body):
        score += 3
        evidence.append("reproduces on NIGHTLY")
    elif NIGHTLY_NO.search(body):
        score -= 2

    if TITLE_VERSION.search(title):
        score += 1
        evidence.append("release version in title")

    activity = attention_count(item)
    if activity >= 3:
        score += min(3, activity // 3)
        evidence.append(f"{activity} comments/reactions")

    return score, evidence


def cluster_term_weight(token: str) -> float:
    if token in BROAD_CLUSTER_TERMS:
        return 0.25
    if token in STRONG_CLUSTER_TERMS:
        return 1.5
    return 1.0


def pair_is_clustered(left: set[str], right: set[str]) -> bool:
    shared = left & right
    if not (shared & STRONG_CLUSTER_TERMS):
        return False
    shared_score = sum(cluster_term_weight(token) for token in shared)
    smaller_score = min(
        sum(cluster_term_weight(token) for token in left),
        sum(cluster_term_weight(token) for token in right),
    )
    if smaller_score <= 0:
        return False
    return shared_score >= 1.75 and shared_score / smaller_score >= 0.18


def is_cluster_candidate(item: dict[str, Any]) -> bool:
    title = str(item.get("title") or "").strip().lower()
    return not (
        title.startswith("[rfc]")
        or title.startswith("rfc:")
        or title.startswith("[triage radar]")
    )


def build_clusters(issues: list[dict[str, Any]]) -> list[dict[str, Any]]:
    candidates = [item for item in issues if is_cluster_candidate(item)]
    if len(candidates) < 2:
        return []

    tokens = [title_tokens(str(item.get("title") or "")) for item in candidates]
    parent = list(range(len(candidates)))

    def find(index: int) -> int:
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    def union(left: int, right: int) -> None:
        left_root = find(left)
        right_root = find(right)
        if left_root != right_root:
            parent[right_root] = left_root

    for left in range(len(candidates)):
        for right in range(left + 1, len(candidates)):
            if pair_is_clustered(tokens[left], tokens[right]):
                union(left, right)

    groups: dict[int, list[int]] = {}
    for index in range(len(candidates)):
        groups.setdefault(find(index), []).append(index)

    clusters: list[dict[str, Any]] = []
    for indexes in groups.values():
        if len(indexes) < 2:
            continue
        if len(indexes) > 8:
            continue
        members = [candidates[index] for index in indexes]
        counts = Counter(token for index in indexes for token in tokens[index])
        shared_terms = [
            token
            for token, count in sorted(
                counts.items(),
                key=lambda pair: (-cluster_term_weight(pair[0]), -pair[1], pair[0]),
            )
            if count >= 2
        ][:4]
        risk_scores = [regression_evidence(member)[0] for member in members]
        clusters.append(
            {
                "members": members,
                "terms": shared_terms,
                "reporters": len({reporter(member) for member in members}),
                "risk": max(risk_scores, default=0),
            }
        )

    clusters.sort(
        key=lambda cluster: (
            len(cluster["members"]),
            cluster["risk"],
            max(
                (
                    parse_time(str(member["created_at"])).timestamp()
                    for member in cluster["members"]
                    if member.get("created_at")
                ),
                default=0,
            ),
        ),
        reverse=True,
    )
    return clusters


def render_issue(item: dict[str, Any]) -> str:
    return f"#{issue_number(item)} — {clean_inline(str(item.get('title') or 'Untitled'))}"


def render_cluster(cluster: dict[str, Any]) -> str:
    members = sorted(cluster["members"], key=issue_number)
    terms = ", ".join(f"`{term}`" for term in cluster["terms"]) or "related title terms"
    member_lines = "\n".join(f"- {render_issue(member)}" for member in members)
    return (
        f"### {clean_inline(' / '.join(cluster['terms'][:3]) or 'Related reports')}\n"
        f"{len(members)} recent open issues from {cluster['reporters']} reporter(s); shared terms: {terms}.\n\n"
        f"{member_lines}\n"
    )


def select_regressions(
    issues: list[dict[str, Any]], excluded_numbers: set[int], limit: int = 7
) -> list[tuple[dict[str, Any], int, list[str]]]:
    candidates: list[tuple[dict[str, Any], int, list[str]]] = []
    for item in issues:
        if issue_number(item) in excluded_numbers or "enhancement" in labels(item):
            continue
        score, evidence = regression_evidence(item)
        if score >= 4:
            candidates.append((item, score, evidence))
    candidates.sort(
        key=lambda row: (
            row[1],
            parse_time(str(row[0]["created_at"])).timestamp() if row[0].get("created_at") else 0,
        ),
        reverse=True,
    )
    return candidates[:limit]


def select_high_attention(
    issues: list[dict[str, Any]], excluded_numbers: set[int], limit: int = 3
) -> list[dict[str, Any]]:
    candidates = [
        item
        for item in issues
        if issue_number(item) not in excluded_numbers
        and is_cluster_candidate(item)
        and attention_count(item) >= 3
    ]
    candidates.sort(
        key=lambda item: (
            attention_count(item),
            parse_time(str(item["updated_at"])).timestamp() if item.get("updated_at") else 0,
        ),
        reverse=True,
    )
    return candidates[:limit]


def render_generated(
    issues: list[dict[str, Any]],
    near_finish_prs: list[dict[str, Any]],
    *,
    now: dt.datetime,
    issue_hours: int,
    pr_hours: int,
) -> str:
    clusters = build_clusters(issues)[:5]
    cluster_numbers = {
        issue_number(member)
        for cluster in clusters
        for member in cluster["members"]
    }
    regressions = select_regressions(issues, cluster_numbers, limit=7)
    regression_numbers = {issue_number(item) for item, _, _ in regressions}
    high_attention = select_high_attention(
        issues, cluster_numbers | regression_numbers, limit=3
    )

    sections: list[str] = []
    if clusters:
        sections.append(
            "## Recent clusters\n\n"
            + "\n".join(render_cluster(cluster) for cluster in clusters)
        )

    if regressions:
        lines = ["## Regression / severe-path candidates", ""]
        for item, _, evidence in regressions:
            why = ", ".join(evidence) if evidence else "recent bug signal"
            lines.append(f"- {render_issue(item)}  \n  Evidence: {clean_inline(why)}")
        sections.append("\n".join(lines))

    if near_finish_prs:
        lines = [
            "## Near-finish PR candidates",
            "",
            "_GitHub search reports these as open, non-draft, approved, successful-status PRs updated in the window._",
            "",
        ]
        for item in near_finish_prs[:5]:
            lines.append(f"- {render_issue(item)}")
        sections.append("\n".join(lines))

    if high_attention:
        lines = ["## High-attention recent reports", ""]
        for item in high_attention:
            lines.append(
                f"- {render_issue(item)} — {attention_count(item)} comments/reactions"
            )
        sections.append("\n".join(lines))

    if not sections:
        sections.append("No current attention candidates matched the deterministic V1 signals.")

    issue_cutoff = now - dt.timedelta(hours=issue_hours)
    pr_cutoff = now - dt.timedelta(hours=pr_hours)
    header = (
        f"_Generated {now.strftime('%Y-%m-%d %H:%M UTC')}. "
        f"Issue window: since {issue_cutoff.strftime('%Y-%m-%d %H:%M UTC')}; "
        f"PR window: since {pr_cutoff.strftime('%Y-%m-%d %H:%M UTC')}. "
        "This is attention evidence, not roadmap priority._"
    )
    return header + "\n\n" + "\n\n".join(sections)


def replace_generated(body: str, generated: str) -> str:
    if body.count(START_MARKER) != 1 or body.count(END_MARKER) != 1:
        raise ValueError("radar issue must contain exactly one start and end marker")
    start = body.index(START_MARKER) + len(START_MARKER)
    end = body.index(END_MARKER, start)
    if end < start:
        raise ValueError("radar markers are out of order")
    return body[:start] + "\n" + generated.strip() + "\n" + body[end:]


class GitHub:
    def __init__(self, token: str, repo: str) -> None:
        self.repo = repo
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-triage-radar",
        }

    def request(self, method: str, path: str, payload: dict[str, Any] | None = None) -> Any:
        data = None
        headers = dict(self.headers)
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(API + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                if response.status == 204:
                    return {}
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"GitHub API request failed ({error.code})") from error
        except urllib.error.URLError as error:
            raise RuntimeError("GitHub API request failed") from error

    def search(self, query: str, *, sort: str, order: str = "desc") -> list[dict[str, Any]]:
        encoded = urllib.parse.urlencode(
            {"q": query, "per_page": 100, "sort": sort, "order": order}
        )
        payload = self.request("GET", f"/search/issues?{encoded}")
        return list(payload.get("items", []))

    def issue(self, number: int) -> dict[str, Any]:
        return self.request("GET", f"/repos/{self.repo}/issues/{number}")

    def update_issue_body(self, number: int, body: str) -> None:
        self.request("PATCH", f"/repos/{self.repo}/issues/{number}", {"body": body})


def cutoff_query(now: dt.datetime, hours: int) -> str:
    cutoff = now - dt.timedelta(hours=hours)
    return cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")


def main() -> int:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("GH_REPO") or os.environ.get("GITHUB_REPOSITORY")
    radar_raw = os.environ.get("TRIAGE_RADAR_ISSUE", "")
    if not token or not repo or not radar_raw:
        print(
            "triage-radar: GH_TOKEN, GH_REPO, and TRIAGE_RADAR_ISSUE are required",
            file=sys.stderr,
        )
        return 2
    try:
        radar_issue = int(radar_raw)
        issue_hours = int(os.environ.get("ISSUE_HOURS", "72"))
        pr_hours = int(os.environ.get("PR_HOURS", "168"))
    except ValueError:
        print("triage-radar: issue number and windows must be integers", file=sys.stderr)
        return 2
    if radar_issue < 1 or issue_hours < 1 or pr_hours < 1:
        print("triage-radar: issue number and windows must be positive", file=sys.stderr)
        return 2

    github = GitHub(token, repo)
    now = dt.datetime.now(dt.timezone.utc)
    try:
        issues = github.search(
            f"repo:{repo} is:issue is:open created:>={cutoff_query(now, issue_hours)}",
            sort="created",
        )
        prs = github.search(
            f"repo:{repo} is:pr is:open draft:false review:approved status:success "
            f"updated:>={cutoff_query(now, pr_hours)}",
            sort="updated",
        )
        radar = github.issue(radar_issue)
        if not str(radar.get("title") or "").startswith(RADAR_TITLE_PREFIX):
            raise RuntimeError(
                f"configured issue #{radar_issue} is not a {RADAR_TITLE_PREFIX} issue"
            )
        current_body = str(radar.get("body") or "")
        generated = render_generated(
            issues,
            prs,
            now=now,
            issue_hours=issue_hours,
            pr_hours=pr_hours,
        )
        updated_body = replace_generated(current_body, generated)
        if updated_body == current_body:
            print("triage-radar: generated section already current")
            return 0
        github.update_issue_body(radar_issue, updated_body)
    except (RuntimeError, ValueError) as error:
        print(f"triage-radar: {error}", file=sys.stderr)
        return 1

    print(
        f"triage-radar: updated #{radar_issue}; "
        f"issues={len(issues)}; near-finish-prs={len(prs)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
