#!/usr/bin/env python3
"""Field stability of cmux NEXT from Sentry (p10 done check 21, machine queue Q17).

Chrome's stability report (components/metrics/stability_metrics_provider.cc, clean_exit_beacon.cc,
Stability.Counts2) counts launches, crashes and exits no crash handler saw. cmux NEXT's field data is
in the shared Sentry project manaflow/cmuxterm-macos, told apart by its environment (`nightly-next`,
`rc-next`, `release-next`, `dev`) and the `app:cmux-next` tag (CrashEventLabels.swift). This script
reads, for one environment over the last --days days:

  sessions        crash-free sessions and users, overall and per release (release health), and the
                  sessions by status (healthy, errored, crashed, abnormal)
  lag spikes      main-thread stalls >= 250 ms (LagSpikeEvent, tag hang_source:main_thread_stall) per
                  1k session-hours, by stall_bucket. The app rate-limits them (LagSpikeRateLimiter:
                  10, then 1 per 2 min), so this is a lower bound. Each spike signature (a Sentry
                  issue: LagSpikeEvent groups by stack) must link a GitHub issue; the ones that do
                  not are listed.
  hangs           main-thread hangs >= 2 s (MainThreadHangEvent, hang_source:main_thread_watchdog) per
                  issue, split into own and other-owner. Sentry's own 8 s AppHang events report the same
                  stalls again and are not counted.
  unclean exits   the previous run's outcome (task 203's launch event, tag exit_outcome); the
                  `unclean-no-report` share of sessions is the clean-exit-beacon number
  top issues      the --top unresolved cmux-next issues by events in the period

Issues owned by another program (stability-other-owners.json: owner, ETA, GitHub issue, Sentry short
ids) are listed in a separate other-owner row and do not count against the hang check. An owner claims
a Sentry issue only by its identity: the issue links the owner's GitHub issue, or its short id is listed.
A title or stack match is not used, because it cannot tell the owner's stall from an own stall in the
same frames; an unclaimed issue counts as own until someone links it.

The token comes only from SENTRY_AUTH_TOKEN. It is never printed: every error text is redacted, and a
redirect to another host is refused so the Authorization header never leaves the API host.

    SENTRY_AUTH_TOKEN=... python3 scripts/cmux-next/stability-health.py --env nightly-next --days 3
    ... --top 50 --json          (Q17: every top issue without a GitHub issue is one task)
    ... --check                  (exit 1 unless every done-check-21 target is met)

Exit codes: 0 report printed, 1 a --check target missed, 2 no token, bad arguments or a bad owners file,
3 Sentry API error (transport, HTTP status or an unexpected response shape).
"""

from __future__ import annotations

import argparse
import contextlib
import http.client
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator

TOKEN_ENV = "SENTRY_AUTH_TOKEN"
BASE_URL_ENV = "SENTRY_URL"
DEFAULT_BASE_URL = "https://sentry.io"
DEFAULT_ORG = "manaflow"
DEFAULT_PROJECT = "cmuxterm-macos"
# The numeric id from CrashReporter.dsn; the sessions and events APIs take ids, not slugs.
DEFAULT_PROJECT_ID = "4510796264636416"
DEFAULT_OWNERS = Path(__file__).resolve().parent / "stability-other-owners.json"
SCHEMA = "cmux-stability-health/v1"

APP_QUERY = "app:cmux-next"
LAG_QUERY = "hang_source:main_thread_stall"
HANG_QUERY = "hang_source:main_thread_watchdog"
HANG_MIN_SECONDS = 2
EXIT_TAG = "exit_outcome"
UNCLEAN_NO_REPORT = "unclean-no-report"
# Release health returns session.duration aggregates in milliseconds.
DURATION_UNIT_MS = 1.0
MAX_ISSUES = 500
# An HTTP error body is redacted whole (up to this many bytes), then cut for the message.
ERROR_BODY_READ = 65536
ERROR_BODY_SHOWN = 300
GITHUB_ISSUE = re.compile(r"github\.com/[^/\s]+/[^/\s]+/issues/(\d+)")

# Done check 21 (p10-stability.md): crash-free sessions >= 99.9 %, unclean exits without a crash report
# <= 0.1 % of sessions, 0 own hangs >= 2 s, lag spikes >= 250 ms <= 1 per 100 session-hours, every spike
# signature has an issue.
TARGETS = {
    "crash_free_sessions_pct": (">=", 99.9),
    "unclean_no_report_pct": ("<=", 0.1),
    "own_hang_events": ("<=", 0),
    "lag_spikes_per_1k_session_hours": ("<=", 10.0),
    "lag_spike_issues_without_github": ("<=", 0),
}

Fetch = Callable[[str, list[tuple[str, str]]], tuple[Any, dict[str, str]]]


class SentryError(Exception):
    """A Sentry API request that failed; the message is already redacted."""


def redact(text: str, token: str | None) -> str:
    return text.replace(token, "[redacted]") if token else text


class SameHostRedirects(urllib.request.HTTPRedirectHandler):
    """urllib copies the Authorization header onto a redirect; refuse one that leaves the API host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401 - urllib's signature
        old, new = urllib.parse.urlsplit(req.full_url), urllib.parse.urlsplit(newurl)
        if (old.scheme, old.netloc) != (new.scheme, new.netloc):
            raise SentryError(f"refused a redirect from {old.netloc} to {new.netloc}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def http_fetch(base_url: str, token: str, timeout: float = 30.0) -> Fetch:
    """The live transport: GET base_url/api/0<path> with the token, JSON back, headers lower-cased.

    The token goes only over HTTPS (plain HTTP only to a loopback test server)."""
    parts = urllib.parse.urlsplit(base_url)
    if parts.scheme != "https" and not (parts.scheme == "http" and parts.hostname in ("127.0.0.1", "localhost")):
        raise SentryError(f"refused to send the token to a non-HTTPS URL ({parts.scheme}://{parts.hostname})")
    opener = urllib.request.build_opener(SameHostRedirects())

    def fetch(path: str, params: list[tuple[str, str]]) -> tuple[Any, dict[str, str]]:
        url = f"{base_url.rstrip('/')}/api/0{path}?{urllib.parse.urlencode(params)}"
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
        try:
            with opener.open(request, timeout=timeout) as response:
                headers = {k.lower(): v for k, v in response.headers.items()}
                return json.loads(response.read().decode("utf-8")), headers
        except urllib.error.HTTPError as error:
            # Redact before the cut: a token echoed across the cut would leave an unmatched prefix.
            body = redact(error.read(ERROR_BODY_READ).decode("utf-8", "replace"), token)[:ERROR_BODY_SHOWN]
            raise SentryError(redact(f"GET {path}: HTTP {error.code}: {body}", token)) from None
        except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as error:
            raise SentryError(redact(f"GET {path}: {error}", token)) from None

    return fetch


def next_cursor(headers: dict[str, str]) -> str | None:
    """The cursor of Sentry's `Link: <...>; rel="next"; results="true"; cursor="..."` part, if more results exist."""
    for part in headers.get("link", "").split(","):
        if 'rel="next"' in part and 'results="true"' in part:
            match = re.search(r'cursor="([^"]+)"', part)
            if match:
                return match.group(1)
    return None


@contextlib.contextmanager
def response_shape(path: str) -> Iterator[None]:
    """Turns a payload without the expected shape into a SentryError (exit 3), not a traceback (exit 1)."""
    try:
        yield
    except (KeyError, IndexError, TypeError, AttributeError, ValueError) as error:
        raise SentryError(f"unexpected response shape from {path} ({type(error).__name__})") from None


@dataclass
class Config:
    env: str = "nightly-next"
    days: int = 3
    top: int = 20
    releases: int = 10
    org: str = DEFAULT_ORG
    project_id: str = DEFAULT_PROJECT_ID
    owners: list[dict[str, Any]] = field(default_factory=list)

    def scope(self) -> list[tuple[str, str]]:
        return [("project", self.project_id), ("environment", self.env), ("statsPeriod", f"{self.days}d")]


def pct(rate: Any) -> float | None:
    return None if rate is None else round(float(rate) * 100.0, 4)


def per(count: float, base: float | None, scale: float) -> float | None:
    return None if not base else round(count * scale / base, 3)


SESSION_FIELDS = ["sum(session)", "count_unique(user)", "crash_free_rate(session)", "crash_free_rate(user)",
                  "avg(session.duration)"]


def session_row(totals: dict[str, Any]) -> dict[str, Any]:
    return {
        "sessions": int(totals.get("sum(session)") or 0),
        "users": int(totals.get("count_unique(user)") or 0),
        "crash_free_sessions_pct": pct(totals.get("crash_free_rate(session)")),
        "crash_free_users_pct": pct(totals.get("crash_free_rate(user)")),
    }


def sessions(fetch: Fetch, cfg: Config) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Release health: totals, sessions by status, and the busiest --releases releases."""
    path = f"/organizations/{cfg.org}/sessions/"
    base = cfg.scope() + [("interval", "1d"), ("includeSeries", "0")]
    fields = [("field", f) for f in SESSION_FIELDS]
    totals_data, _ = fetch(path, base + fields)
    with response_shape(path):
        groups = totals_data.get("groups") or [{}]
        totals = groups[0].get("totals", {})
        summary = session_row(totals)
        duration = totals.get("avg(session.duration)")
        summary["avg_duration_ms"] = None if duration is None else float(duration) * DURATION_UNIT_MS
        summary["session_hours"] = (None if duration is None else
                                    round(summary["sessions"] * summary["avg_duration_ms"] / 3_600_000.0, 2))
    status_data, _ = fetch(path, base + [("field", "sum(session)"), ("groupBy", "session.status")])
    with response_shape(path):
        summary["by_status"] = {g["by"]["session.status"]: int(g["totals"].get("sum(session)") or 0)
                                for g in status_data.get("groups", [])}
    release_data, _ = fetch(path, base + fields + [("groupBy", "release"), ("orderBy", "-sum(session)"),
                                                   ("per_page", str(cfg.releases))])
    with response_shape(path):
        releases = [{"release": g["by"]["release"], **session_row(g.get("totals", {}))}
                    for g in release_data.get("groups", [])]
    return summary, releases


def tag_counts(fetch: Fetch, cfg: Config, query: str, tag: str) -> dict[str, int]:
    """Error events of cmux NEXT matching `query`, counted per value of `tag` (Discover)."""
    column = f"tags[{tag}]"
    params = cfg.scope() + [("dataset", "errors"), ("field", column), ("field", "count()"),
                            ("query", f"{APP_QUERY} has:{tag} {query}".strip()), ("per_page", "100")]
    path = f"/organizations/{cfg.org}/events/"
    data, _ = fetch(path, params)
    with response_shape(path):
        return {str(row.get(column)): int(row.get("count()") or 0) for row in data.get("data", [])}


def github_issues(issue: dict[str, Any]) -> list[int]:
    """GitHub issue numbers linked from a Sentry issue's annotations (dicts or legacy HTML strings)."""
    found = []
    for annotation in issue.get("annotations") or []:
        text = annotation.get("url", "") if isinstance(annotation, dict) else str(annotation)
        found += [int(n) for n in GITHUB_ISSUE.findall(text)]
    return sorted(set(found))


def other_owner(issue: dict[str, Any], owners: list[dict[str, Any]]) -> dict[str, Any] | None:
    """The other-owner entry that claims `issue`: the issue links its GitHub issue or has a listed short id."""
    for entry in owners:
        if entry["github_issue"] in issue["github"] or issue["short_id"] in entry.get("sentry_issues", []):
            return entry
    return None


def normalize_issue(raw: dict[str, Any], owners: list[dict[str, Any]]) -> dict[str, Any]:
    filtered = raw.get("filtered") or {}
    issue = {
        "id": str(raw.get("id")),
        "short_id": raw.get("shortId", ""),
        "title": raw.get("title", ""),
        "culprit": raw.get("culprit") or "",
        "level": raw.get("level", ""),
        "events": int(filtered.get("count") or raw.get("count") or 0),
        "users": int(filtered.get("userCount") or raw.get("userCount") or 0),
        "first_seen": raw.get("firstSeen"),
        "last_seen": raw.get("lastSeen"),
        "permalink": raw.get("permalink", ""),
    }
    issue["github"] = github_issues(raw)
    owner = other_owner(issue, owners)
    issue["owner"] = None if owner is None else {k: owner.get(k) for k in ("owner", "eta", "github_issue")}
    return issue


def issues(fetch: Fetch, cfg: Config, query: str, limit: int) -> list[dict[str, Any]]:
    """cmux NEXT issues with events in the period matching `query`, most events first, up to `limit`."""
    found: list[dict[str, Any]] = []
    cursor: str | None = None
    while len(found) < limit:
        params = cfg.scope() + [("query", f"{APP_QUERY} {query}".strip()), ("sort", "freq"),
                                ("limit", str(min(100, limit - len(found))))]
        if cursor:
            params.append(("cursor", cursor))
        path = f"/organizations/{cfg.org}/issues/"
        data, headers = fetch(path, params)
        if not isinstance(data, list):
            raise SentryError(f"GET {path}: expected a list, got {type(data).__name__}")
        with response_shape(path):
            found += [normalize_issue(raw, cfg.owners) for raw in data]
        cursor = next_cursor(headers)
        if not data or cursor is None:
            break
    return found[:limit]


def other_owner_rows(groups: dict[str, list[dict[str, Any]]]) -> list[dict[str, Any]]:
    """One row per other owner: its issues and events among the hangs and the top issues."""
    rows: dict[str, dict[str, Any]] = {}
    for kind, items in groups.items():
        for issue in items:
            owner = issue["owner"]
            if owner is None:
                continue
            row = rows.setdefault(owner["owner"], {**owner, "hang_events": 0, "issue_events": 0, "issues": []})
            row["hang_events" if kind == "hangs" else "issue_events"] += issue["events"]
            if issue["short_id"] not in row["issues"]:
                row["issues"].append(issue["short_id"])
    return sorted(rows.values(), key=lambda r: -(r["hang_events"] + r["issue_events"]))


def check_rows(values: dict[str, float | None]) -> list[dict[str, Any]]:
    rows = []
    for name, (op, target) in TARGETS.items():
        value = values.get(name)
        ok = value is not None and (value >= target if op == ">=" else value <= target)
        rows.append({"name": name, "value": value, "op": op, "target": target, "ok": ok})
    return rows


def build_report(fetch: Fetch, cfg: Config) -> dict[str, Any]:
    summary, releases = sessions(fetch, cfg)
    hours, count = summary["session_hours"], summary["sessions"]
    lag = tag_counts(fetch, cfg, LAG_QUERY, "stall_bucket")
    lag_total = sum(lag.values())
    spike_issues = issues(fetch, cfg, LAG_QUERY, MAX_ISSUES)
    spikes_without_github = [i for i in spike_issues if not i["github"] and i["owner"] is None]
    hang_issues = issues(fetch, cfg, HANG_QUERY, MAX_ISSUES)
    own_hangs = sum(i["events"] for i in hang_issues if i["owner"] is None)
    other_hangs = sum(i["events"] for i in hang_issues if i["owner"] is not None)
    exits = tag_counts(fetch, cfg, "", EXIT_TAG)
    no_report = exits.get(UNCLEAN_NO_REPORT, 0)
    top = issues(fetch, cfg, "is:unresolved", cfg.top)
    report = {
        "schema": SCHEMA,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "org": cfg.org, "project_id": cfg.project_id, "env": cfg.env, "days": cfg.days,
        "sessions": summary,
        "releases": releases,
        "lag_spikes": {"min_ms": 250, "total": lag_total, "by_bucket": lag,
                       "per_1k_session_hours": per(lag_total, hours, 1000.0), "rate_limited": True,
                       "issues": len(spike_issues), "issues_without_github": spikes_without_github},
        "hangs": {"min_seconds": HANG_MIN_SECONDS, "own_events": own_hangs, "other_owner_events": other_hangs,
                  "own_per_1k_session_hours": per(own_hangs, hours, 1000.0), "issues": hang_issues},
        "unclean_exits": {"by_outcome": exits, "no_report": no_report,
                          "no_report_pct_of_sessions": per(no_report, count, 100.0),
                          "no_report_per_1k_sessions": per(no_report, count, 1000.0),
                          "abnormal_sessions": summary["by_status"].get("abnormal", 0)},
        "top_issues": top,
        "other_owner": other_owner_rows({"hangs": hang_issues, "top": top}),
    }
    report["checks"] = check_rows({
        "crash_free_sessions_pct": summary["crash_free_sessions_pct"],
        # No exit_outcome events at all means no data (task 203 not shipped, or no consent), not 0 %.
        "unclean_no_report_pct": report["unclean_exits"]["no_report_pct_of_sessions"] if exits else None,
        "own_hang_events": own_hangs,
        "lag_spikes_per_1k_session_hours": report["lag_spikes"]["per_1k_session_hours"],
        "lag_spike_issues_without_github": len(spikes_without_github),
    })
    return report


def fmt(value: Any) -> str:
    return "n/a" if value is None else str(value)


def table(report: dict[str, Any]) -> str:
    s = report["sessions"]
    lines = [f"cmux NEXT stability, env {report['env']}, last {report['days']} d ({report['generated_at']})", "",
             f"sessions {s['sessions']}  users {s['users']}  session-hours {fmt(s['session_hours'])}",
             f"crash-free sessions {fmt(s['crash_free_sessions_pct'])} %  users {fmt(s['crash_free_users_pct'])} %",
             "by status: " + "  ".join(f"{k} {v}" for k, v in sorted(s["by_status"].items())), "",
             f"{'release':<40} {'sessions':>9} {'users':>7} {'cf sess %':>10} {'cf users %':>10}"]
    for r in report["releases"]:
        lines.append(f"{r['release']:<40} {r['sessions']:>9} {r['users']:>7} "
                     f"{fmt(r['crash_free_sessions_pct']):>10} {fmt(r['crash_free_users_pct']):>10}")
    lag, hangs, exits = report["lag_spikes"], report["hangs"], report["unclean_exits"]
    lines += ["", f"lag spikes >= 250 ms: {lag['total']} ({fmt(lag['per_1k_session_hours'])} per 1k session-hours, "
                  "rate-limited) " + "  ".join(f"{k} {v}" for k, v in sorted(lag["by_bucket"].items())),
              f"lag spike signatures: {lag['issues']}, without a GitHub issue {len(lag['issues_without_github'])}",
              *[f"  {i['short_id']:<22} {i['events']:>7} {i['title'][:70]}" for i in lag["issues_without_github"]],
              f"hangs >= {hangs['min_seconds']} s: own {hangs['own_events']}, other-owner {hangs['other_owner_events']}",
              f"unclean exits without a crash report: {exits['no_report']} "
              f"({fmt(exits['no_report_pct_of_sessions'])} % of sessions); abnormal sessions {exits['abnormal_sessions']}",
              "", f"{'issue':<22} {'events':>7} {'users':>6} {'github':<10} {'owner':<12} title"]
    for i in report["top_issues"]:
        gh = ",".join(f"#{n}" for n in i["github"]) or "-"
        owner = i["owner"]["owner"] if i["owner"] else "-"
        lines.append(f"{i['short_id']:<22} {i['events']:>7} {i['users']:>6} {gh:<10} {owner:<12} {i['title'][:70]}")
    lines += ["", "other-owner (not counted against the hang check):"]
    lines += [f"  {r['owner']}: hangs {r['hang_events']}, issue events {r['issue_events']}, "
              f"#{r['github_issue']}, ETA {r['eta']}, "
              f"{' '.join(r['issues'])}"
              for r in report["other_owner"]] or ["  none"]
    lines += ["", "done check 21:"]
    lines += [f"  {'ok  ' if c['ok'] else 'MISS'} {c['name']} {fmt(c['value'])} {c['op']} {c['target']}"
              for c in report["checks"]]
    return "\n".join(lines)


def load_owners(path: Path) -> list[dict[str, Any]]:
    """The other-owner map. Done checks 16 and 21 need an owner, an ETA and a GitHub issue on every entry."""
    if not path.exists():
        return []
    entries = json.loads(path.read_text())["owners"]
    for entry in entries:
        name = entry.get("owner")
        if not isinstance(name, str) or not name.strip():
            raise ValueError("an entry has no owner")
        if not isinstance(entry.get("eta"), str) or not entry["eta"].strip():
            raise ValueError(f"{name} has no eta")
        if not isinstance(entry.get("github_issue"), int):
            raise ValueError(f"{name} has no github_issue number")
        if not all(isinstance(s, str) for s in entry.get("sentry_issues", [])):
            raise ValueError(f"{name}: sentry_issues must be short id strings")
        if "pattern" in entry:
            raise ValueError(f"{name}: pattern is not supported; claim issues by github_issue or sentry_issues")
    return entries


def days_arg(text: str) -> int:
    value = int(text)
    if not 1 <= value <= 90:
        raise argparse.ArgumentTypeError(f"{value} is not in 1..90")
    return value


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--env", default="nightly-next", help="Sentry environment (nightly-next, rc-next, release-next, dev)")
    parser.add_argument("--days", type=days_arg, default=3, help="period in days, 1..90 (default 3)")
    parser.add_argument("--top", type=int, default=20, help="unresolved issues to list (default 20)")
    parser.add_argument("--releases", type=int, default=10, help="releases to list (default 10)")
    parser.add_argument("--org", default=DEFAULT_ORG)
    parser.add_argument("--project-id", default=DEFAULT_PROJECT_ID)
    parser.add_argument("--base-url", default=os.environ.get(BASE_URL_ENV, DEFAULT_BASE_URL))
    parser.add_argument("--owners", type=Path, default=DEFAULT_OWNERS, help="other-owner map (JSON)")
    parser.add_argument("--json", action="store_true", help="print the report as JSON")
    parser.add_argument("--check", action="store_true", help="exit 1 unless every done-check-21 target is met")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None, environ: dict[str, str] | None = None, fetch: Fetch | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    env = os.environ if environ is None else environ
    token = env.get(TOKEN_ENV, "").strip()
    if fetch is None and not token:
        print(f"stability-health: {TOKEN_ENV} is not set", file=sys.stderr)
        return 2
    try:
        cfg = Config(env=args.env, days=args.days, top=max(1, args.top), releases=max(1, args.releases),
                     org=args.org, project_id=args.project_id, owners=load_owners(args.owners))
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f"stability-health: bad owners file {args.owners}: {error}", file=sys.stderr)
        return 2
    try:
        report = build_report(fetch or http_fetch(args.base_url, token), cfg)
    except SentryError as error:
        print(f"stability-health: {redact(str(error), token)}", file=sys.stderr)
        return 3
    print(json.dumps(report, indent=2) if args.json else table(report))
    return 1 if args.check and not all(c["ok"] for c in report["checks"]) else 0


if __name__ == "__main__":
    sys.exit(main())
