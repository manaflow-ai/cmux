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

And the crash section of the report: crashes and hangs of the last --hours, by signature, new or returning,
NIGHTLY or DEV. From Sentry when its API answers (SENTRY_AUTH_TOKEN with event:read and org:read); else from
leo-workspace tools/hang_watch.py's cmuxterm-hq issues (titles "hang-watch SIG: KIND in FRAME", one per stack
signature; their report lines carry each report's time and build), read with `gh` (GH_TOKEN with issues read on
cmuxterm-hq). The section says which source answered and why the other did not.

    quality-report.py report [--hours 24] [--perf-state state.json] [--god-small FILE] [--anim-coverage FILE]
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
TITLE_RE = re.compile(r"^hang-watch ([0-9a-f]{6,}): (\w+)(?: \(([^)]*)\))? in (.+)$")
REPORT_LINE_RE = re.compile(r"^- `([^`]+)`(.*)$")
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


def sentry_get(path: str, params: List[Tuple[str, str]], token: str, opener: Callable = urllib.request.urlopen) -> Any:
    url = f"{SENTRY_API}{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "User-Agent": "cmux-quality-report"})
    try:
        with opener(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
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


def sentry_crashes(get: Callable[[str, List[Tuple[str, str]]], Any], hours: int, since: dt.datetime) -> Dict[str, Any]:
    """Unresolved error and fatal issues of cmux NEXT with events in the window, one query per environment."""
    sigs: Dict[str, Dict[str, Any]] = {}
    for env, channel in SENTRY_ENVIRONMENTS.items():
        params = [("project", SENTRY_PROJECT_ID), ("environment", env), ("statsPeriod", f"{hours}h"),
                  ("query", "is:unresolved level:[fatal,error] app:cmux-next"), ("sort", "freq"), ("limit", "50")]
        for issue in get(f"/organizations/{SENTRY_ORG}/issues/", params) or []:
            key = str(issue.get("shortId") or issue.get("id"))
            first = parse_time(issue.get("firstSeen"))
            s = sigs.setdefault(key, {
                "id": key, "title": str(issue.get("title") or "")[:140],
                "kind": "crash" if issue.get("level") == "fatal" else "error",
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
        return json.loads(done.stdout or "[]")
    except ValueError as e:
        raise SourceError(f"gh returned no JSON for the hang-watch issues: {e}") from e


def report_channel(line: str) -> str:
    low = line.lower()
    if "(dev)" in low or ".debug" in low or " dev " in f" {low} " or "cmux dev" in low:
        return "DEV"
    if "nightly" in low:
        return "NIGHTLY"
    return "OTHER"


def report_lines(text: str, posted: Optional[dt.datetime]) -> List[Tuple[dt.datetime, str]]:
    """(time, channel) per report line of an issue body or comment. A line's own time is the report's start (or the
    time in its file name); a line with none takes the post's time."""
    out = []
    for raw in (text or "").splitlines():
        m = REPORT_LINE_RE.match(raw.strip())
        if not m:
            continue
        path, rest = m.groups()
        when = parse_time(rest) or parse_time(os.path.basename(path)) or posted
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
    for s in sigs:
        s["count"] = sum(s["counts"].values())
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
            "by_channel": by_channel, "by_kind": by_kind, "signatures": sigs[:TOP_SIGNATURES]}


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
    """Newest p95 per interaction row of a perf-cron state: the row's last row_history entry, else last_good."""
    if not isinstance(state, dict):
        return {"source": None, "rows": {}, "over_budget": [], "why": why or "the perf cron state is not an object"}
    good = (state.get("last_good") or {}).get("rows") or {}
    hist = state.get("row_history") if isinstance(state.get("row_history"), dict) else {}
    rows: Dict[str, Any] = {}
    for name in sorted(set(good) | set(hist)):
        g = good.get(name) or {}
        unit = g.get("unit")
        if unit not in (None, "ms") or NOT_INTERACTION.search(name) or (unit is None and name not in good):
            continue
        h = hist.get(name) or []
        last = h[-1] if h and isinstance(h[-1], dict) else {}
        p95 = last.get("p95", g.get("p95"))
        if not isinstance(p95, (int, float)):
            continue
        budget = g.get("budget")
        rows[name] = {"p95": p95, "budget": budget, "at": last.get("at") or (state.get("last_good") or {}).get("measured_at"),
                      "sha": last.get("sha") or (state.get("last_good") or {}).get("sha")}
    over = sorted((n for n, r in rows.items() if isinstance(r["budget"], (int, float)) and r["budget"] > 0
                   and r["p95"] > r["budget"]), key=lambda n: -rows[n]["p95"] / rows[n]["budget"])
    worst = max(rows.values(), key=lambda r: r["p95"])["p95"] if rows else None
    return {"source": "perf-cron", "rows": rows, "over_budget": over, "worst_p95_ms": worst,
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


# The report

def build_report(hours: int, t: dt.datetime, sentry_token: Optional[str], perf_state: Optional[str],
                 god_small_path: Optional[str], anim_path: Optional[str],
                 sentry_getter: Optional[Callable] = None,
                 hang_watch: Callable[[dt.datetime], List[Dict[str, Any]]] = gh_hang_watch_issues) -> Dict[str, Any]:
    since = t - dt.timedelta(hours=hours)
    get = sentry_getter or (lambda path, params: sentry_get(path, params, sentry_token or ""))
    sentry_why = None if sentry_token or sentry_getter else "no SENTRY_AUTH_TOKEN"
    crash_free: Dict[str, Any] = {"value": None, "sessions": 0, "by_environment": {}, "source": None, "why": sentry_why}
    crashes: Optional[Dict[str, Any]] = None
    if sentry_why is None:
        try:
            crash_free = sentry_crash_free(get, hours)
        except SourceError as e:
            crash_free["why"] = sentry_why = str(e)
        if sentry_why is None:
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
            "animation_token_coverage": anim_coverage(anim, anim_why)}


def pct(v: Optional[float]) -> str:
    return "n/a" if v is None else f"{v * 100:.2f}%"


def headline(r: Dict[str, Any]) -> Dict[str, str]:
    cf = r["crash_free_session_rate"]
    cr = r["crashes"]
    p = r["interaction_p95_ms"]
    g = r["god_vs_small"]
    a = r["animation_token_coverage"]
    return {
        "Crash-free sessions": f"{pct(cf['value'])} of {cf['sessions']}" if cf["value"] is not None else f"n/a ({cf['why']})",
        "Crashes and hangs": (f"{cr['total']} ({', '.join(f'{k} {v}' for k, v in sorted(cr['by_channel'].items())) or 'none'}; "
                              f"{cr.get('new_signatures', 0)} new, {cr.get('returning_signatures', 0)} returning signatures; "
                              f"from {cr['source']})") if cr.get("total") is not None else f"n/a ({cr.get('why')})",
        "Interaction p95": (f"worst {p['worst_p95_ms']} ms over {len(p['rows'])} rows, {len(p['over_budget'])} over budget"
                            if p["rows"] else f"n/a ({p['why']})"),
        "God vs small": (f"worst {g['worst_ratio']}x (limit {g['limit']}x), {len(g['failing'])} over"
                         if g["rows"] else f"n/a ({g['why']})"),
        "Animation token coverage": pct(a["value"]) if a["value"] is not None else f"n/a ({a['why']})",
    }


def render_markdown(r: Dict[str, Any], public: bool) -> str:
    out = [f"## cmux NEXT quality, {r['window_hours']} h to {r['generated_at']}", "", "| Metric | Value |", "| --- | --- |"]
    out += [f"| {k} | {v} |" for k, v in headline(r).items()]
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
    p = r["interaction_p95_ms"]
    if p["over_budget"]:
        out += ["", "Interaction rows over budget: " + ", ".join(
            f"`{n}` {p['rows'][n]['p95']} ms (budget {p['rows'][n]['budget']})" for n in p["over_budget"][:10])]
    g = r["god_vs_small"]
    if g["failing"]:
        out += ["", f"God over {g['limit']}x small: " + ", ".join(f"`{n}`" for n in g["failing"][:10])]
    return "\n".join(out) + "\n"


def history_row(r: Dict[str, Any]) -> Dict[str, Any]:
    cr = r["crashes"]
    return {"at": r["generated_at"][:10], "crash_free": r["crash_free_session_rate"]["value"],
            "sessions": r["crash_free_session_rate"]["sessions"], "crashes": cr.get("total"),
            "crash_source": cr.get("source"), "nightly": (cr.get("by_channel") or {}).get("NIGHTLY"),
            "dev": (cr.get("by_channel") or {}).get("DEV"), "new_sigs": cr.get("new_signatures"),
            "worst_p95_ms": r["interaction_p95_ms"].get("worst_p95_ms"),
            "over_budget": len(r["interaction_p95_ms"]["over_budget"]),
            "god_ratio": r["god_vs_small"]["worst_ratio"], "anim": r["animation_token_coverage"]["value"]}


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
    lines = ["| Night | Crash-free | Crashes (NIGHTLY/DEV) | New sigs | Worst p95 ms | Over budget | God/small | Anim coverage |",
             "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for h in reversed(history):
        crashes = "n/a" if h.get("crashes") is None else f"{h['crashes']} ({h.get('nightly') or 0}/{h.get('dev') or 0}, {h.get('crash_source')})"
        lines.append(f"| {h['at']} | {pct(h.get('crash_free'))} | {crashes} | {h.get('new_sigs') if h.get('new_sigs') is not None else 'n/a'} | "
                     f"{h.get('worst_p95_ms') if h.get('worst_p95_ms') is not None else 'n/a'} | {h.get('over_budget')} | "
                     f"{h.get('god_ratio') if h.get('god_ratio') is not None else 'n/a'} | {pct(h.get('anim'))} |")
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
    rep.add_argument("--json", required=True, help="the metrics JSON")
    rep.add_argument("--md", help="the full report (signature names)")
    rep.add_argument("--public-md", help="the numbers only")
    st = sub.add_parser("sticky", help="write the report into the sticky cmuxterm-hq issue")
    st.add_argument("--report", required=True)
    st.add_argument("--md", required=True)
    st.add_argument("--repo", default=HQ_REPO)
    args = ap.parse_args(argv)
    if args.cmd == "report":
        r = build_report(args.hours, now_utc(), os.environ.get("SENTRY_AUTH_TOKEN") or None, args.perf_state,
                         args.god_small, args.anim_coverage)
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(r, f, indent=2, sort_keys=True)
            f.write("\n")
        for path, public in ((args.md, False), (args.public_md, True)):
            if path:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(render_markdown(r, public))
        print(json.dumps(headline(r), indent=2))
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
