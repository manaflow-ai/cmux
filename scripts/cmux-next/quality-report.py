#!/usr/bin/env python3
"""cmux NEXT nightly quality report: crash and hang counts, and the three quality metrics as one JSON.

Leo, 2026-11-10: "the lags, the crashes ... it's not acceptable ... to put that out there, have my name on it."
So the nightly tracks three numbers over time, each from the source that already measures it:

  crash_free_session_rate   Sentry release health (org manaflow, project cmuxterm-macos; cmux NEXT's environments
                            nightly-next and dev). CmuxNextCrashReporting leaves Sentry's automatic session tracking
                            on, so every reporting launch is a session; a session that ends in a crash is not
                            crash free.
  interaction_p95_ms        the perf cron's newest p95 per interaction row (scripts/cmux-next/perf-cron.py's
                            state.json: row_history, else last_good), and the god-vs-small gate's rows when its
                            output is given (--god-small; a row fails over GOD_SMALL_LIMIT x small).
  animation_token_coverage  the share of animations that go through the motion tokens (--anim-coverage, the
                            coverage script's JSON).
  ci_health                 Leo, 2026-11-10: "WE DO NOT STAND FOR BAD CI AND LOW QUALITY STUFF EVER". From the check
                            runs of the last --ci-commits commits of each --ci-branches branch (GitHub GraphQL, every
                            attempt of every run): green_share, the share of checks whose newest finished run on the
                            branch is green, and flake_rate, the share of (commit, check) pairs that failed and then
                            passed on the same commit. The checks red now are listed with their failure counts.

And the crash section of the report: crashes and hangs of the last --hours, by signature, new or returning,
NIGHTLY or DEV. From Sentry when its API answers (SENTRY_AUTH_TOKEN with event:read and org:read); else from
leo-workspace tools/hang_watch.py's cmuxterm-hq issues (titles "hang-watch SIG: KIND in FRAME", one per stack
signature; their report lines carry each report's time and build), read with `gh` (GH_TOKEN with issues read on
cmuxterm-hq). The section says which source answered and why the other did not.

    quality-report.py report [--hours 24] [--perf-state state.json] [--god-small FILE] [--anim-coverage FILE]
                             [--ci-branches feat-cmux-next,main] [--ci-commits 50] [--ci-repo manaflow-ai/cmux]
                             --json OUT [--md OUT] [--public-md OUT]
    quality-report.py sticky --report OUT.json --md OUT.md [--repo manaflow-ai/cmuxterm-hq]

`report` writes the metrics JSON (--json), the full report with signature names (--md, for the private sticky
issue) and the numbers only (--public-md, for this public repository's step summary). `sticky` puts the report in
the one open cmuxterm-hq issue titled STICKY_TITLE (opening it the first time) and keeps a dated row per night in
it, so the three numbers can be read over time in one place. A source that cannot be read leaves its metric null
with a `why`; nothing here fails a build. Input slots that other checks fill, by shape:

  --god-small      {"rows": [{"name": str, "small_p95": num, "god_p95": num}, ...]} (or a bare list of those rows;
                   `small`/`god` are accepted for the two numbers, and a given `ratio` is used as is)
  --anim-coverage  {"coverage": 0..1} or {"covered": int, "total": int} (`animated` for total is accepted)

Tests: scripts/cmux-next/tests/test_quality_report.py (python3 -m unittest, no network).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Dict, List, Optional, Tuple

SCHEMA = 1
SENTRY_API = "https://sentry.io/api/0"
SENTRY_ORG = "manaflow"
SENTRY_PROJECT = "cmuxterm-macos"
# The project id in CmuxNextCrashReporting's DSN (CrashReporter.dsn): the sessions API takes ids, not slugs.
SENTRY_PROJECT_ID = "4510796264636416"
# CrashReportingPolicy.Channel.environment: NIGHTLY builds report as nightly-next, DEV builds (only with
# CMUX_NEXT_DEV_SENTRY=1) as dev; rc-next and release-next are RELEASE. A hang-watch report that names neither
# NIGHTLY nor DEV (a release build's, or another cmux's) is OTHER.
SENTRY_ENVIRONMENTS = {"nightly-next": "NIGHTLY", "dev": "DEV", "rc-next": "RELEASE", "release-next": "RELEASE"}
HQ_REPO = "manaflow-ai/cmuxterm-hq"
HANG_WATCH_TAG = "hang-watch"
STICKY_TITLE = "cmux NEXT nightly quality report"
STICKY_MARK = "<!-- cmux-next-quality-report -->"
HISTORY_RE = re.compile(r"<!-- quality-history: (\[.*?\]) -->", re.S)
HISTORY_KEEP = 60
GOD_SMALL_LIMIT = 1.2
TOP_SIGNATURES = 15
# Interaction rows of the perf cron: latencies a person waits on. Background and shape rows (idle CPU, long-task
# totals, slopes, heap) are not interaction latencies and stay out of this metric.
NOT_INTERACTION = re.compile(r"idle|long_ms|long_tasks|slope|heap|wakeups|\.cls@|_px@|rows_lost|dom_content_loaded")
SIBLING_RE = re.compile(r"with signature `([0-9a-f]{6,})`")
TITLE_RE = re.compile(r"^hang-watch ([0-9a-f]{6,}): (\w+)(?: \(([^)]*)\))? in (.+)$")
REPORT_LINE_RE = re.compile(r"^- `([^`]+)`(.*)$")
# hang_watch.py lists at most 20 reports per post, then "- and N more".
MORE_RE = re.compile(r"^- and (\d+) more$")
# A post's held block ("Earlier reports of this signature, held until it recurred:") lists reports already outside
# hang-watch's issue; they are older than the post and are read by their own times like any other line.
# A report's time as hang_watch.py writes it: ISO with Z (app hang files, file names with - for :) or a macOS report's
# local time with its offset ("2026-11-05 17:52:59.00 -0800").
STAMP_RE = re.compile(r"(\d{4}-\d{2}-\d{2})[T ](\d{2})[:-](\d{2})[:-](\d{2})(?:\.\d+)?(?:\s*(Z|[+-]\d{2}:?\d{2}))?")


def now_utc() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def iso(t: dt.datetime) -> str:
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(text: Optional[str]) -> Optional[dt.datetime]:
    if not text:
        return None
    m = STAMP_RE.search(text)
    if not m:
        return None
    day, hh, mm, ss, zone = m.groups()
    try:
        t = dt.datetime.strptime(f"{day} {hh} {mm} {ss}", "%Y-%m-%d %H %M %S").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None
    if zone and zone != "Z":
        sign = -1 if zone[0] == "-" else 1
        digits = zone[1:].replace(":", "")
        t -= sign * dt.timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
    return t


# Sentry

class SourceError(Exception):
    """A source that could not be read; its message is the report's `why`."""


NEXT_CURSOR = re.compile(r'<[^>]*[?&]cursor=([^&>]+)[^>]*>;\s*rel="next";\s*results="true"')
SENTRY_PAGES = 5


def sentry_get(path: str, params: List[Tuple[str, str]], token: str, opener: Callable = urllib.request.urlopen) -> Any:
    """One GET, or for a list endpoint every page up to SENTRY_PAGES (Sentry's Link header cursor)."""
    out: List[Any] = []
    cursor = None
    for _ in range(SENTRY_PAGES):
        page = sentry_page(path, params + ([("cursor", cursor)] if cursor else []), token, opener)
        body, link = page
        if not isinstance(body, list):
            return body
        out += body
        m = NEXT_CURSOR.search(link or "")
        if not m:
            break
        cursor = urllib.parse.unquote(m.group(1))
    return out


def sentry_page(path: str, params: List[Tuple[str, str]], token: str, opener: Callable) -> Tuple[Any, str]:
    url = f"{SENTRY_API}{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "User-Agent": "cmux-quality-report"})
    try:
        with opener(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8")), resp.headers.get("Link", "") if getattr(resp, "headers", None) else ""
    except urllib.error.HTTPError as e:
        hint = " (the token needs org:read and event:read)" if e.code in (401, 403) else ""
        raise SourceError(f"Sentry answered HTTP {e.code} for {path}{hint}") from e
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as e:
        raise SourceError(f"Sentry did not answer {path}: {e}") from e


def sentry_crash_free(get: Callable[[str, List[Tuple[str, str]]], Any], hours: int) -> Dict[str, Any]:
    """Crash-free session rate per cmux NEXT environment over the window, and overall (session-weighted)."""
    params = [("project", SENTRY_PROJECT_ID), ("field", "sum(session)"), ("field", "crash_free_rate(session)"),
              ("groupBy", "environment"), ("statsPeriod", f"{hours}h"), ("interval", f"{hours}h")]
    params += [("environment", env) for env in SENTRY_ENVIRONMENTS]
    data = get(f"/organizations/{SENTRY_ORG}/sessions/", params)
    by_env: Dict[str, Any] = {}
    sessions = crashed = 0.0
    for group in data.get("groups") or []:
        env = (group.get("by") or {}).get("environment")
        totals = group.get("totals") or {}
        n = totals.get("sum(session)") or 0
        rate = totals.get("crash_free_rate(session)")
        if env not in SENTRY_ENVIRONMENTS:
            continue
        by_env[env] = {"sessions": int(n), "crash_free_rate": rate}
        if n and isinstance(rate, (int, float)):
            sessions += n
            crashed += n * (1 - rate)
    value = round(1 - crashed / sessions, 6) if sessions else None
    return {"value": value, "sessions": int(sessions), "by_environment": by_env, "source": "sentry",
            "why": None if sessions else "Sentry has no cmux NEXT sessions in the window"}


def sentry_kind(issue: Dict[str, Any]) -> str:
    """crash (a fatal event), hang (an app hang or main-thread hang report) or error (any other error event, such as a
    browser failure): only the first two are counted as crashes and hangs; errors are reported beside them."""
    if issue.get("level") == "fatal":
        return "crash"
    text = " ".join(str(issue.get(k) or "") for k in ("title", "culprit", "type"))
    text += " " + json.dumps(issue.get("metadata") or {})
    return "hang" if re.search(r"app ?hang|apphang|main.?thread.?hang|watchdog", text, re.I) else "error"


def sentry_crashes(get: Callable[[str, List[Tuple[str, str]]], Any], hours: int, since: dt.datetime) -> Dict[str, Any]:
    """Unresolved error and fatal issues of cmux NEXT with events in the window, one query per environment."""
    sigs: Dict[str, Dict[str, Any]] = {}
    for env, channel in SENTRY_ENVIRONMENTS.items():
        params = [("project", SENTRY_PROJECT_ID), ("environment", env), ("statsPeriod", f"{hours}h"),
                  ("query", "!is:resolved level:[fatal,error] app:cmux-next"), ("sort", "freq"), ("limit", "100")]
        for issue in get(f"/organizations/{SENTRY_ORG}/issues/", params) or []:
            key = str(issue.get("shortId") or issue.get("id"))
            first = parse_time(issue.get("firstSeen"))
            s = sigs.setdefault(key, {
                "id": key, "title": str(issue.get("title") or "")[:140],
                "kind": sentry_kind(issue),
                "url": issue.get("permalink"), "first_seen": issue.get("firstSeen"),
                "new": bool(first and first >= since), "counts": {}})
            s["counts"][channel] = s["counts"].get(channel, 0) + int(issue.get("count") or 0)
    return summarize_signatures(list(sigs.values()), "sentry")


# hang-watch issues

def gh_hang_watch_issues(since: dt.datetime, repo: str = HQ_REPO, run: Callable = subprocess.run) -> List[Dict[str, Any]]:
    """hang-watch issues updated in the window, by title (triage may replace the hang-watch label)."""
    cmd = ["gh", "issue", "list", "--repo", repo, "--state", "all", "--limit", "200",
           "--search", f'"{HANG_WATCH_TAG}" in:title updated:>={since.strftime("%Y-%m-%dT%H:%M:%SZ")}',
           "--json", "number,title,state,createdAt,url,body,comments"]
    try:
        done = run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError) as e:
        raise SourceError(f"gh could not list the hang-watch issues: {e}") from e
    if done.returncode != 0:
        raise SourceError(f"gh could not list the hang-watch issues: {(done.stderr or done.stdout).strip()[-200:]}")
    try:
        issues = json.loads(done.stdout or "[]")
    except ValueError as e:
        raise SourceError(f"gh returned no JSON for the hang-watch issues: {e}") from e
    # `gh issue list --json comments` gives the first 100 comments, oldest first; hang-watch comments every tick a
    # signature recurs, so a busy issue's newest reports are past them. Read those issues' comments of the window.
    for issue in issues:
        if len(issue.get("comments") or []) >= 100:
            issue["comments"] = gh_comments_since(repo, issue["number"], since, run)
    return issues


def gh_comments_since(repo: str, number: int, since: dt.datetime, run: Callable) -> List[Dict[str, Any]]:
    path = f"repos/{repo}/issues/{number}/comments?since={since.strftime('%Y-%m-%dT%H:%M:%SZ')}&per_page=100"
    # One bounded page: hang-watch comments at most once a tick (15 min), so a day's window is under 100.
    cmd = ["gh", "api", path, "--jq", ".[] | {createdAt: .created_at, body: .body}"]
    try:
        done = run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError) as e:
        raise SourceError(f"gh could not read hang-watch issue #{number}'s comments: {e}") from e
    if done.returncode != 0:
        raise SourceError(f"gh could not read hang-watch issue #{number}'s comments: {(done.stderr or done.stdout).strip()[-200:]}")
    try:
        return [json.loads(line) for line in (done.stdout or "").splitlines() if line.strip()]
    except ValueError as e:
        raise SourceError(f"gh returned no JSON for issue #{number}'s comments: {e}") from e


def report_channel(line: str) -> str:
    low = line.lower()
    if "(dev)" in low or ".debug" in low or " dev " in f" {low} " or "cmux dev" in low:
        return "DEV"
    if "nightly" in low:
        return "NIGHTLY"
    return "OTHER"


def held_block(text: str, line: str) -> bool:
    """Whether `line` is in the post's held block: an undated held report is not this post's, so it is not counted."""
    head, sep, _ = (text or "").partition("held until it recurred:")
    return bool(sep) and line in text[len(head):]


def report_lines(text: str, posted: Optional[dt.datetime]) -> List[Tuple[dt.datetime, str]]:
    """(time, channel) per report line of an issue body or comment. A line's own time is the report's start (or the
    time in its file name); a line with none takes the post's time."""
    out: List[Tuple[dt.datetime, str]] = []
    channel_of_post = None
    for raw in (text or "").splitlines():
        more = MORE_RE.match(raw.strip())
        if more and posted is not None:
            # The unlisted reports are dated by the post and take the listed reports' most common channel.
            channels = [c for _, c in out] or ["OTHER"]
            channel_of_post = max(set(channels), key=channels.count)
            out += [(posted, channel_of_post)] * int(more.group(1))
            continue
        m = REPORT_LINE_RE.match(raw.strip())
        if not m:
            continue
        path, rest = m.groups()
        when = parse_time(rest) or parse_time(os.path.basename(path))
        if when is None and not held_block(text, raw):
            when = posted
        if when is not None:
            out.append((when, report_channel(raw)))
    return out


def hang_watch_crashes(issues: List[Dict[str, Any]], since: dt.datetime) -> Dict[str, Any]:
    sigs = []
    for issue in issues:
        m = TITLE_RE.match(str(issue.get("title") or ""))
        if not m:
            continue
        sig, kind, binary, headline = m.groups()
        created = parse_time(issue.get("createdAt"))
        lines = report_lines(issue.get("body") or "", created)
        came_back = False
        for c in issue.get("comments") or []:
            body = c.get("body") or ""
            sib = SIBLING_RE.search(body) if body.startswith("Another signature of this stall") else None
            if sib:
                # A new signature that joined this issue (hang_watch.py sibling_body): its own signature.
                posted = parse_time(c.get("createdAt"))
                sib_counts: Dict[str, int] = {}
                for when, channel in report_lines(body, posted):
                    if when >= since:
                        sib_counts[channel] = sib_counts.get(channel, 0) + 1
                if sib_counts:
                    sigs.append({"id": sib.group(1), "title": f"{kind} in {headline} (joined #{issue.get('number')})"[:140],
                                 "kind": kind, "url": issue.get("url"), "first_seen": c.get("createdAt"),
                                 "new": bool(posted and posted >= since), "came_back": False, "counts": sib_counts})
                continue
            lines += report_lines(body, parse_time(c.get("createdAt")))
            if body.startswith("Came back after the close") and (parse_time(c.get("createdAt")) or since) >= since:
                came_back = True
        counts: Dict[str, int] = {}
        for when, channel in lines:
            if when >= since:
                counts[channel] = counts.get(channel, 0) + 1
        if not counts:
            continue
        sigs.append({"id": sig, "title": f"{kind}{f' ({binary})' if binary else ''} in {headline}"[:140],
                     "kind": kind, "url": issue.get("url"), "first_seen": issue.get("createdAt"),
                     "new": bool(created and created >= since and not came_back), "came_back": came_back,
                     "counts": counts})
    return summarize_signatures(sigs, "hang-watch")


def summarize_signatures(sigs: List[Dict[str, Any]], source: str) -> Dict[str, Any]:
    """Totals of crashes and hangs (hang-watch's resource reports included); Sentry's other error issues are counted
    apart, in `errors`, and listed after them."""
    for s in sigs:
        s["count"] = sum(s["counts"].values())
    errors = [s for s in sigs if s["kind"] == "error"]
    sigs = [s for s in sigs if s["kind"] != "error"]
    sigs.sort(key=lambda s: (-s["count"], s["id"]))
    by_channel: Dict[str, int] = {}
    by_kind: Dict[str, int] = {}
    for s in sigs:
        for ch, n in s["counts"].items():
            by_channel[ch] = by_channel.get(ch, 0) + n
        by_kind[s["kind"]] = by_kind.get(s["kind"], 0) + s["count"]
    return {"source": source, "total": sum(s["count"] for s in sigs), "signatures_seen": len(sigs),
            "new_signatures": sum(1 for s in sigs if s["new"]),
            "returning_signatures": sum(1 for s in sigs if not s["new"]),
            "by_channel": by_channel, "by_kind": by_kind, "signatures": sigs[:TOP_SIGNATURES],
            "errors": sum(s["count"] for s in errors),
            "error_signatures": sorted(errors, key=lambda s: (-s["count"], s["id"]))[:TOP_SIGNATURES]}


# Perf, god-vs-small and animation coverage inputs

def load_json(path: Optional[str]) -> Tuple[Any, Optional[str]]:
    if not path:
        return None, "no input given"
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f), None
    except FileNotFoundError:
        return None, f"{path} does not exist"
    except (OSError, ValueError) as e:
        return None, f"{path} is not readable JSON: {e}"


def interaction_p95(state: Any, why: Optional[str]) -> Dict[str, Any]:
    """Newest p95 per interaction row of a perf-cron state. perf-cron.py keeps a row that regressed or went over its
    target out of last_good and row_history, so the newest value is taken from every place a measurement lands: the
    last measurement (`last`), open regressions and unconfirmed candidates (both marked `held`), row_history and
    last_good. Each row says when it was measured, so a stale state shows."""
    if not isinstance(state, dict):
        return {"source": None, "rows": {}, "over_budget": [], "held": [], "worst_p95_ms": None,
                "why": why or "the perf cron state is not an object"}
    good_rec = state.get("last_good") or {}
    good = good_rec.get("rows") or {}
    last_rec = state.get("last") or {}
    hist = state.get("row_history") if isinstance(state.get("row_history"), dict) else {}
    meta: Dict[str, Dict[str, Any]] = {}
    seen: Dict[str, List[Dict[str, Any]]] = {}

    def add(name: Any, value: Any, at: Any, sha: Any, held: bool = False, info: Optional[Dict[str, Any]] = None) -> None:
        if not isinstance(name, str) or not isinstance(value, (int, float)):
            return
        seen.setdefault(name, []).append({"p95": value, "at": at, "sha": sha, "held": held})
        if info:
            m = meta.setdefault(name, {})
            for k in ("unit", "budget"):
                if info.get(k) is not None and m.get(k) is None:
                    m[k] = info[k]

    for name, r in good.items():
        add(name, (r or {}).get("p95"), good_rec.get("measured_at"), good_rec.get("sha"), info=r)
    for name, h in hist.items():
        if isinstance(h, list) and h and isinstance(h[-1], dict):
            add(name, h[-1].get("p95"), h[-1].get("at"), h[-1].get("sha"))
    for name, r in (last_rec.get("rows") or {}).items():
        add(name, (r or {}).get("p95"), last_rec.get("measured_at"), last_rec.get("sha"), info=r)
    for r in list(state.get("regressions") or []) + list(state.get("unconfirmed") or []):
        if isinstance(r, dict):
            at = r.get("at") or (r.get("first_bad") or {}).get("measured_at")
            add(r.get("name"), r.get("p95"), at, r.get("sha") or (r.get("first_bad") or {}).get("sha"), held=True, info=r)
    rows: Dict[str, Any] = {}
    for name in sorted(seen):
        unit = (meta.get(name) or {}).get("unit")
        if unit != "ms" or NOT_INTERACTION.search(name):
            continue
        newest = max(seen[name], key=lambda v: (parse_time(v["at"]) or dt.datetime.min.replace(tzinfo=dt.timezone.utc), v["held"]))
        rows[name] = {**newest, "budget": (meta.get(name) or {}).get("budget")}
    over = sorted((n for n, r in rows.items() if isinstance(r["budget"], (int, float)) and r["budget"] > 0
                   and r["p95"] > r["budget"]), key=lambda n: -rows[n]["p95"] / rows[n]["budget"])
    worst = max(rows.values(), key=lambda r: r["p95"])["p95"] if rows else None
    stamps = [t for t in (parse_time(r["at"]) for r in rows.values()) if t]
    return {"source": "perf-cron", "rows": rows, "over_budget": over, "held": sorted(n for n, r in rows.items() if r["held"]),
            "worst_p95_ms": worst, "newest_at": iso(max(stamps)) if stamps else None,
            "why": None if rows else "the perf cron state has no interaction rows"}


def god_vs_small(doc: Any, why: Optional[str]) -> Dict[str, Any]:
    raw = doc.get("rows") if isinstance(doc, dict) else doc
    if not isinstance(raw, list):
        return {"source": None, "limit": GOD_SMALL_LIMIT, "rows": [], "failing": [], "worst_ratio": None,
                "why": why or "the god-vs-small input has no rows"}
    rows = []
    for r in raw:
        if not isinstance(r, dict):
            continue
        small = r.get("small_p95", r.get("small"))
        god = r.get("god_p95", r.get("god"))
        ratio = r.get("ratio")
        if not isinstance(ratio, (int, float)):
            ratio = round(god / small, 3) if isinstance(small, (int, float)) and small > 0 and isinstance(god, (int, float)) else None
        rows.append({"name": str(r.get("name") or "?"), "small_p95": small, "god_p95": god, "ratio": ratio})
    ratios = [r["ratio"] for r in rows if isinstance(r["ratio"], (int, float))]
    return {"source": "god-vs-small", "limit": GOD_SMALL_LIMIT, "rows": rows,
            "failing": [r["name"] for r in rows if isinstance(r["ratio"], (int, float)) and r["ratio"] > GOD_SMALL_LIMIT],
            "worst_ratio": max(ratios) if ratios else None, "why": None if rows else "the god-vs-small input has no rows"}


def anim_coverage(doc: Any, why: Optional[str]) -> Dict[str, Any]:
    value = None
    if isinstance(doc, dict):
        if isinstance(doc.get("coverage"), (int, float)):
            value = float(doc["coverage"])
        else:
            covered, total = doc.get("covered"), doc.get("total", doc.get("animated"))
            if isinstance(covered, (int, float)) and isinstance(total, (int, float)) and total > 0:
                value = covered / total
    if value is not None and value > 1:  # a percentage
        value /= 100.0
    return {"value": round(value, 4) if value is not None else None, "source": "anim-coverage" if value is not None else None,
            "why": None if value is not None else (why or "the coverage input has no coverage figure")}


# CI health

CI_REPO = "manaflow-ai/cmux"
CI_COMMITS = 50
CI_PAGE = 5  # commits per GraphQL page: each carries up to 100 suites of up to 100 runs
CI_TOP_RED = 15
CI_CALL_TIMEOUT = 45  # seconds per read: 20 reads stay inside the job's limit
# A finished run counts as green or red; skipped, neutral, cancelled (superseded by a newer push) and still running
# runs say nothing about the check's health.
CI_GREEN = {"SUCCESS"}
CI_RED = {"FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"}
CI_QUERY = """query($owner:String!,$name:String!,$expr:String!,$n:Int!,$after:String){
 repository(owner:$owner,name:$name){ object(expression:$expr){ ... on Commit {
  history(first:$n, after:$after){ pageInfo{endCursor hasNextPage} nodes{ oid committedDate
   checkSuites(first:100){ nodes{ app{slug} workflowRun{ workflow{name} }
     checkRuns(first:100, filterBy:{checkType:ALL}){ nodes{ name conclusion startedAt completedAt } } } } } } } } } }"""


def gh_graphql(query: str, variables: Dict[str, Any], run: Callable = subprocess.run) -> Dict[str, Any]:
    """One GraphQL read with gh: on CI_GH_TOKEN (the workflow's checks-read token) when set, else gh's own login."""
    cmd = ["gh", "api", "graphql", "-f", "query=" + query]
    env = None
    if os.environ.get("CI_GH_TOKEN"):
        env = {**os.environ, "GH_TOKEN": os.environ["CI_GH_TOKEN"]}
    elif "CI_GH_TOKEN" in os.environ:
        raise SourceError("no checks-read token (CI_GH_TOKEN is empty: the App mint failed or there is no App)")
    for k, v in variables.items():
        if v is not None:
            cmd += ["-F" if isinstance(v, int) else "-f", f"{k}={v}"]
    try:
        done = run(cmd, capture_output=True, text=True, timeout=CI_CALL_TIMEOUT, env=env)
    except (OSError, subprocess.SubprocessError) as e:
        raise SourceError(f"gh could not read the check runs: {e}") from e
    if done.returncode != 0:
        raise SourceError("gh could not read the check runs: " + " ".join((done.stderr or done.stdout).split())[:240])
    try:
        return json.loads(done.stdout or "{}")
    except ValueError as e:
        raise SourceError(f"gh returned no JSON for the check runs: {e}") from e


def gh_ci_history(repo: str, branch: str, commits: int, graphql: Callable = gh_graphql) -> List[Dict[str, Any]]:
    """The newest `commits` commits of `branch`, newest first, each with its check suites and every run attempt."""
    owner, name = repo.split("/", 1)
    out: List[Dict[str, Any]] = []
    after = None
    while len(out) < commits:
        r = graphql(CI_QUERY, {"owner": owner, "name": name, "expr": branch, "n": min(CI_PAGE, commits - len(out)), "after": after})
        obj = ((r.get("data") or {}).get("repository") or {}).get("object")
        if not obj:
            raise SourceError(f"{repo}@{branch} has no commit history to read ({(r.get('errors') or [{}])[0].get('message', 'no data')})")
        h = obj["history"]
        out += h.get("nodes") or []
        if not (h.get("pageInfo") or {}).get("hasNextPage"):
            break
        after = h["pageInfo"]["endCursor"]
    return out[:commits]


def ci_branch_health(commits: List[Dict[str, Any]]) -> Dict[str, Any]:
    """green_share and flake_rate of one branch's commits (newest first). A check is `workflow / job`, or the app's
    name for a check that no workflow runs. Its attempts on one commit (re-runs, and a dispatch on the same commit)
    are read in start order: the last finished one is the commit's result, and a red before a later green on the
    same commit is a flake."""
    per_check: Dict[str, Dict[str, Any]] = {}
    pairs = flaky = 0
    flaky_checks: Dict[str, int] = {}
    for c in commits:
        attempts: Dict[str, List[Dict[str, Any]]] = {}
        for s in ((c.get("checkSuites") or {}).get("nodes") or []):
            wf = ((s.get("workflowRun") or {}).get("workflow") or {}).get("name") or ((s.get("app") or {}).get("slug") or "?")
            for run in ((s.get("checkRuns") or {}).get("nodes") or []):
                attempts.setdefault(f"{wf} / {run.get('name')}", []).append(run)
        for check, runs in attempts.items():
            done = [r for r in sorted(runs, key=lambda r: r.get("startedAt") or r.get("completedAt") or "")
                    if r.get("conclusion") in CI_GREEN | CI_RED]
            if not done:
                continue
            pairs += 1
            final = done[-1]["conclusion"]
            if final in CI_GREEN and any(r["conclusion"] in CI_RED for r in done[:-1]):
                flaky += 1
                flaky_checks[check] = flaky_checks.get(check, 0) + 1
            st = per_check.setdefault(check, {"runs": 0, "red": 0, "newest": None})
            st["runs"] += 1
            st["red"] += final in CI_RED
            if st["newest"] is None:  # commits come newest first
                st["newest"] = "green" if final in CI_GREEN else "red"
    green = sum(1 for v in per_check.values() if v["newest"] == "green")
    red_now = sorted((k for k, v in per_check.items() if v["newest"] == "red"),
                     key=lambda k: (-per_check[k]["red"], -per_check[k]["red"] / per_check[k]["runs"], k))
    return {"commits": len(commits),
            "from": commits[-1].get("committedDate") if commits else None,
            "to": commits[0].get("committedDate") if commits else None,
            "head_sha": commits[0].get("oid") if commits else None,
            "checks": len(per_check), "green_checks": green,
            "green_share": round(green / len(per_check), 4) if per_check else None,
            "pairs": pairs, "flaky_pairs": flaky,
            "flake_rate": round(flaky / pairs, 4) if pairs else None,
            "red_now": [{"check": k, "red": per_check[k]["red"], "runs": per_check[k]["runs"]} for k in red_now[:CI_TOP_RED]],
            "red_now_count": len(red_now),
            "flaky": [{"check": k, "flaky": n} for k, n in sorted(flaky_checks.items(), key=lambda kv: (-kv[1], kv[0]))[:CI_TOP_RED]]}


def ci_health(branches: List[str], commits: int, repo: str, history: Optional[Callable] = None) -> Dict[str, Any]:
    """CI health over the base branches: the two headline numbers pool every branch's checks and pairs."""
    if not branches or history is None:
        return {"green_share": None, "flake_rate": None, "branches": {}, "source": None, "why": "no --ci-branches given"}
    per: Dict[str, Any] = {}
    whys = []
    for b in branches:
        try:
            per[b] = ci_branch_health(history(repo, b, commits))
        except Exception as e:  # any odd reply costs this branch's numbers, never the report
            why = str(e) if isinstance(e, SourceError) else f"unreadable check runs: {type(e).__name__}: {e}"
            per[b] = {"why": why}
            whys.append(f"{b}: {why}")
    read = [v for v in per.values() if "why" not in v]
    checks = sum(v["checks"] for v in read)
    pairs = sum(v["pairs"] for v in read)
    return {"source": "github-checks" if read else None, "repo": repo, "commits_per_branch": commits,
            "green_share": round(sum(v["green_checks"] for v in read) / checks, 4) if checks else None,
            "flake_rate": round(sum(v["flaky_pairs"] for v in read) / pairs, 4) if pairs else None,
            "checks": checks, "pairs": pairs, "branches": per,
            "why": "; ".join(whys) if whys and not read else (None if read else "no check runs were read")}


# The report

def build_report(hours: int, t: dt.datetime, sentry_token: Optional[str], perf_state: Optional[str],
                 god_small_path: Optional[str], anim_path: Optional[str],
                 sentry_getter: Optional[Callable] = None,
                 hang_watch: Callable[[dt.datetime], List[Dict[str, Any]]] = gh_hang_watch_issues,
                 ci_branches: Optional[List[str]] = None, ci_commits: int = CI_COMMITS, ci_repo: str = CI_REPO,
                 ci_history: Optional[Callable] = None) -> Dict[str, Any]:
    since = t - dt.timedelta(hours=hours)
    get = sentry_getter or (lambda path, params: sentry_get(path, params, sentry_token or ""))
    sentry_why = None if sentry_token or sentry_getter else "no SENTRY_AUTH_TOKEN"
    crash_free: Dict[str, Any] = {"value": None, "sessions": 0, "by_environment": {}, "source": None, "why": sentry_why}
    crashes: Optional[Dict[str, Any]] = None
    if sentry_why is None:
        # Two reads, each with its own reason: a token that can read issues but not sessions still counts crashes.
        try:
            crash_free = sentry_crash_free(get, hours)
        except SourceError as e:
            crash_free["why"] = str(e)
        try:
            crashes = sentry_crashes(get, hours, since)
        except SourceError as e:
            sentry_why = str(e)
    if crashes is None:
        try:
            crashes = hang_watch_crashes(hang_watch(since), since)
            crashes["sentry_why"] = sentry_why
        except SourceError as e:
            crashes = {"source": None, "total": None, "signatures": [], "by_channel": {}, "by_kind": {},
                       "why": f"Sentry: {sentry_why}; hang-watch: {e}"}
    state, state_why = load_json(perf_state)
    god, god_why = load_json(god_small_path)
    anim, anim_why = load_json(anim_path)
    return {"schema": SCHEMA, "generated_at": iso(t), "window_hours": hours, "since": iso(since),
            "head_sha": os.environ.get("GITHUB_SHA") or None,
            "crash_free_session_rate": crash_free, "crashes": crashes,
            "interaction_p95_ms": interaction_p95(state, state_why),
            "god_vs_small": god_vs_small(god, god_why),
            "animation_token_coverage": anim_coverage(anim, anim_why),
            "ci_health": ci_health(ci_branches or [], ci_commits, ci_repo, ci_history)}


def public_report(r: Dict[str, Any]) -> Dict[str, Any]:
    """The report without what names a crash (signature ids, titles, links, Sentry's messages): for this public
    repository's artifact. The full report goes only to the private sticky issue."""
    out = json.loads(json.dumps(r))
    cr = out.get("crashes") or {}
    for key in ("signatures", "error_signatures"):
        cr.pop(key, None)
    # Session counts are usage numbers: the rate is public, how many sessions it is over is not.
    cf = out.get("crash_free_session_rate") or {}
    cf.pop("sessions", None)
    for env in (cf.get("by_environment") or {}).values():
        env.pop("sessions", None)
    return out


def pct(v: Optional[float]) -> str:
    return "n/a" if v is None else f"{v * 100:.2f}%"


def headline(r: Dict[str, Any], public: bool = False) -> Dict[str, str]:
    cf = r["crash_free_session_rate"]
    cr = r["crashes"]
    p = r["interaction_p95_ms"]
    g = r["god_vs_small"]
    a = r["animation_token_coverage"]
    ci = r.get("ci_health") or {"why": "not in this report"}
    return {
        "Crash-free sessions": (pct(cf["value"]) + ("" if public else f" of {cf.get('sessions')}")) if cf["value"] is not None else f"n/a ({cf['why']})",
        "Crashes and hangs": (f"{cr['total']} ({', '.join(f'{k} {v}' for k, v in sorted(cr['by_channel'].items())) or 'none'}; "
                              f"{cr.get('new_signatures', 0)} new, {cr.get('returning_signatures', 0)} returning signatures; "
                              f"from {cr['source']})") if cr.get("total") is not None else f"n/a ({cr.get('why')})",
        "Interaction p95": (f"worst {p['worst_p95_ms']} ms over {len(p['rows'])} rows, {len(p['over_budget'])} over budget"
                            if p["rows"] else f"n/a ({p['why']})"),
        "God vs small": (f"worst {g['worst_ratio']}x (limit {g['limit']}x), {len(g['failing'])} over"
                         if g["rows"] else f"n/a ({g['why']})"),
        "Animation token coverage": pct(a["value"]) if a["value"] is not None else f"n/a ({a['why']})",
        "CI checks green on base": (f"{pct(ci['green_share'])} of {ci['checks']} checks, newest run on "
                                    + ", ".join(b for b, v in ci["branches"].items() if "why" not in v) if ci.get("green_share") is not None else f"n/a ({ci.get('why')})"),
        "CI flake rate": (f"{pct(ci['flake_rate'])} of {ci['pairs']} commit-check pairs failed then passed on the same commit"
                          if ci.get("flake_rate") is not None else f"n/a ({ci.get('why')})"),
    }


def render_markdown(r: Dict[str, Any], public: bool) -> str:
    out = [f"## cmux NEXT quality, {r['window_hours']} h to {r['generated_at']}", "", "| Metric | Value |", "| --- | --- |"]
    out += [f"| {k} | {v} |" for k, v in headline(r, public).items()]
    cr = r["crashes"]
    if cr.get("source") == "hang-watch" and cr.get("sentry_why"):
        out += ["", f"Sentry was not read ({cr['sentry_why']}); crash counts are hang-watch's reports from the hosts it "
                    "runs on, not every user's, and there is no crash-free rate without Sentry's sessions."]
    if not public and cr.get("signatures"):
        out += ["", f"### Top signatures ({cr['source']})", "", "| Signature | Kind | Count | NIGHTLY | DEV | New |",
                "| --- | --- | --- | --- | --- | --- |"]
        for s in cr["signatures"]:
            name = f"[{s['id']}]({s['url']})" if s.get("url") else s["id"]
            title = s["title"].replace("|", "\\|")
            state = "new" if s["new"] else ("came back" if s.get("came_back") else "returning")
            out.append(f"| {name} {title} | {s['kind']} | {s['count']} | {s['counts'].get('NIGHTLY', 0)} | "
                       f"{s['counts'].get('DEV', 0)} | {state} |")
    if cr.get("errors"):
        out += ["", f"Other error events (not counted above): {cr['errors']}."]
    p = r["interaction_p95_ms"]
    if p.get("newest_at"):
        out += ["", f"Perf rows measured up to {p['newest_at']}" + (f"; held as regressed or unconfirmed: {len(p['held'])}" if p.get("held") else "") + "."]
    if p["over_budget"]:
        out += ["", "Interaction rows over budget: " + ", ".join(
            f"`{n}` {p['rows'][n]['p95']} ms (budget {p['rows'][n]['budget']})" for n in p["over_budget"][:10])]
    g = r["god_vs_small"]
    if g["failing"]:
        out += ["", f"God over {g['limit']}x small: " + ", ".join(f"`{n}`" for n in g["failing"][:10])]
    out += ci_markdown(r.get("ci_health") or {})
    return "\n".join(out) + "\n"


def ci_markdown(ci: Dict[str, Any]) -> List[str]:
    if not ci.get("branches"):
        return []
    out = ["", "### CI health", "", "| Branch | Commits | Green checks | Flaky pairs | Red now |", "| --- | --- | --- | --- | --- |"]
    for b, v in ci["branches"].items():
        if "why" in v:
            out.append(f"| {b} | n/a ({' '.join(str(v['why']).split()).replace('|', '/')}) | | | |")
            continue
        out.append(f"| {b} | {v['commits']} ({v['from']} to {v['to']}) | {v['green_checks']}/{v['checks']} ({pct(v['green_share'])}) | "
                   f"{v['flaky_pairs']}/{v['pairs']} ({pct(v['flake_rate'])}) | {v['red_now_count']} |")
    for b, v in ci["branches"].items():
        if v.get("red_now"):
            out += ["", f"Red now on {b}, most often red first (red of finished commits in the window): " + ", ".join(
                f"`{x['check'].replace('|', '/')}` {x['red']}/{x['runs']}" for x in v["red_now"])]
        if v.get("flaky"):
            out += ["", f"Flaky on {b} (commits where it failed, then passed): " + ", ".join(
                f"`{x['check'].replace('|', '/')}` {x['flaky']}" for x in v["flaky"])]
    return out


def history_row(r: Dict[str, Any]) -> Dict[str, Any]:
    cr = r["crashes"]
    return {"at": r["generated_at"][:10], "crash_free": r["crash_free_session_rate"]["value"],
            "sessions": r["crash_free_session_rate"]["sessions"], "crashes": cr.get("total"),
            "crash_source": cr.get("source"), "nightly": (cr.get("by_channel") or {}).get("NIGHTLY"),
            "dev": (cr.get("by_channel") or {}).get("DEV"), "new_sigs": cr.get("new_signatures"),
            "worst_p95_ms": r["interaction_p95_ms"].get("worst_p95_ms"),
            "over_budget": len(r["interaction_p95_ms"]["over_budget"]),
            "god_ratio": r["god_vs_small"]["worst_ratio"], "anim": r["animation_token_coverage"]["value"],
            "ci_green": (r.get("ci_health") or {}).get("green_share"), "ci_flake": (r.get("ci_health") or {}).get("flake_rate")}


def sticky_body(r: Dict[str, Any], md: str, old_body: str) -> str:
    """The sticky issue's body: the newest report, then one row per night (newest first), the rows also kept as JSON
    in a comment so the next night appends to them."""
    m = HISTORY_RE.search(old_body or "")
    try:
        history = json.loads(m.group(1)) if m else []
    except ValueError:
        history = []
    row = history_row(r)
    history = [h for h in history if isinstance(h, dict) and h.get("at") != row["at"]] + [row]
    history = history[-HISTORY_KEEP:]
    lines = ["| Night | Crash-free | Crashes (NIGHTLY/DEV) | New sigs | Worst p95 ms | Over budget | God/small | Anim coverage | CI green | CI flake |",
             "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for h in reversed(history):
        crashes = "n/a" if h.get("crashes") is None else f"{h['crashes']} ({h.get('nightly') or 0}/{h.get('dev') or 0}, {h.get('crash_source')})"
        lines.append(f"| {h['at']} | {pct(h.get('crash_free'))} | {crashes} | {h.get('new_sigs') if h.get('new_sigs') is not None else 'n/a'} | "
                     f"{h.get('worst_p95_ms') if h.get('worst_p95_ms') is not None else 'n/a'} | {h.get('over_budget')} | "
                     f"{h.get('god_ratio') if h.get('god_ratio') is not None else 'n/a'} | {pct(h.get('anim'))} | "
                     f"{pct(h.get('ci_green'))} | {pct(h.get('ci_flake'))} |")
    return (f"{STICKY_MARK}\nWritten each night by cmux `.github/workflows/cmux-next-quality-report.yml` "
            f"(`scripts/cmux-next/quality-report.py`). Do not edit: the next night replaces this body.\n\n{md}\n"
            f"## Over time\n\n" + "\n".join(lines) + f"\n\n<!-- quality-history: {json.dumps(history, separators=(',', ':'))} -->\n")


def write_sticky(r: Dict[str, Any], md: str, repo: str, run: Callable = subprocess.run) -> str:
    found = run(["gh", "issue", "list", "--repo", repo, "--state", "open", "--search", f'"{STICKY_TITLE}" in:title',
                 "--json", "number,title,body", "--limit", "10"], capture_output=True, text=True, timeout=60)
    if found.returncode != 0:
        raise SourceError(f"gh could not list {repo} issues: {(found.stderr or found.stdout).strip()[-200:]}")
    own = [i for i in json.loads(found.stdout or "[]") if i.get("title") == STICKY_TITLE and STICKY_MARK in (i.get("body") or "")]
    body = sticky_body(r, md, own[0]["body"] if own else "")
    if own:
        cmd = ["gh", "issue", "edit", str(own[0]["number"]), "--repo", repo, "--body-file", "-"]
    else:
        cmd = ["gh", "issue", "create", "--repo", repo, "--title", STICKY_TITLE, "--body-file", "-"]
    done = run(cmd, input=body, capture_output=True, text=True, timeout=60)
    if done.returncode != 0:
        raise SourceError(f"gh could not write the sticky issue: {(done.stderr or done.stdout).strip()[-200:]}")
    return f"#{own[0]['number']}" if own else (done.stdout or "").strip()


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    rep = sub.add_parser("report", help="compute the report")
    rep.add_argument("--hours", type=int, default=24)
    rep.add_argument("--perf-state", help="perf-cron state.json (perf-cron.py fetch-state)")
    rep.add_argument("--god-small", help="the god-vs-small gate's JSON")
    rep.add_argument("--anim-coverage", help="the animation token coverage JSON")
    rep.add_argument("--ci-branches", default="", help="comma-separated base branches for the CI health section")
    rep.add_argument("--ci-commits", type=int, default=CI_COMMITS, help="commits read per branch")
    rep.add_argument("--ci-repo", default=CI_REPO)
    rep.add_argument("--json", required=True, help="the metrics JSON, signature names included (private)")
    rep.add_argument("--public-json", help="the metrics JSON without signature names (public)")
    rep.add_argument("--md", help="the full report (signature names)")
    rep.add_argument("--public-md", help="the numbers only")
    st = sub.add_parser("sticky", help="write the report into the sticky cmuxterm-hq issue")
    st.add_argument("--report", required=True)
    st.add_argument("--md", required=True)
    st.add_argument("--repo", default=HQ_REPO)
    args = ap.parse_args(argv)
    if args.cmd == "report":
        branches = [b.strip() for b in args.ci_branches.split(",") if b.strip()]
        r = build_report(args.hours, now_utc(), os.environ.get("SENTRY_AUTH_TOKEN") or None, args.perf_state,
                         args.god_small, args.anim_coverage, ci_branches=branches, ci_commits=args.ci_commits,
                         ci_repo=args.ci_repo, ci_history=gh_ci_history if branches else None)
        for path, doc in ((args.json, r), (args.public_json, public_report(r) if args.public_json else None)):
            if path:
                with open(path, "w", encoding="utf-8") as f:
                    json.dump(doc, f, indent=2, sort_keys=True)
                    f.write("\n")
        for path, public in ((args.md, False), (args.public_md, True)):
            if path:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(render_markdown(r, public))
        print(json.dumps(headline(r, public=True), indent=2))  # the job log is public
        return 0
    with open(args.report, encoding="utf-8") as f:
        r = json.load(f)
    with open(args.md, encoding="utf-8") as f:
        md = f.read()
    try:
        print(f"quality-report: sticky issue {write_sticky(r, md, args.repo)}")
    except SourceError as e:
        print(f"quality-report: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
