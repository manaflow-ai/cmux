#!/usr/bin/env python3
"""The cmux NEXT health gate: real-session health of the feed's newest Nightly build, judged every 15 minutes.

Leo, 2026-11-19 (paraphrased): we want to be a professional software organization, so agents look these practices
up and build them; "always be building". The practice is release health gating (canarying): a build's crash-free
sessions and hang rate, read from the crash reporter and compared with the build before it, decide whether it stays
on the feed. Before this, the crash-free rate reached a person
once a day (cmux-next-quality-report.yml, which gates nothing), so a bad build was found up to 24 h later, or by Leo.

nightly-next-health.yml runs it every 15 minutes:

  recent       prints the feed's RECENT newest builds Nightly apps are offered (never a Dev-only one), newest
               first. Each tick judges every one, so a build superseded within a tick still gets a verdict;
               only the newest can be pulled.
  sentry-read  reads Sentry release health (org manaflow, project cmuxterm-macos, environment nightly-next) for
               a Nightly build B and the Nightly build before it, P: sessions by status (crashed,
               abnormal) and app hang events. A release is `cmux-next@<short version>+<build>`
               (CrashReportingPolicy.release); the short version is the appcast's sparkle:shortVersionString.
  judge        turns that reading, the feed and B's earlier health file into B's health file
               (health/<B>.json, beside verdicts/<B>.json in R2) and says whether to pull B.
  drill-reading  (the rollback drill, nightly-next-rollback-drill.yml step health) a made-up failing reading
               of the drill's bad canary, so the drill times every step after the Sentry read.

The verdict (VERDICTS):

  fail     crashed sessions >= MIN_CRASHED and the crash-free rate is under CRASH_FREE_FLOOR and under P's, or
           hangs >= MIN_HANGS and the hang rate (hangs per session) is over HANG_RATE_FLOOR and over
           HANG_RATE_FACTOR x P's. A failing verdict pulls B through nightly-next-rollback.yml with
           bad_build = if_newest = B, so a build published meanwhile is never pulled.
  pass     B has MIN_SESSIONS sessions, or its first session is PASS_AFTER_S old, and nothing fails. A pass is
           judged again on every tick while B is the newest build, so a later crash still pulls it.
  pending  B has no session yet, or too few and too young for a pass.
  unknown  Sentry could not be read (the token, an HTTP error); the file says why. Nothing is pulled.
           The judge calls such a gate blind (it can never pull), and nightly-next-health.yml's job blind
           opens one issue (BLIND_TITLE) and turns the run red until Sentry reads again.

Nothing here waits for a soak: a fail acts on the tick that sees it, and a pass never holds a build.
"""
from __future__ import annotations

import argparse
import datetime as dt
import http.client
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

SENTRY_API = "https://sentry.io/api/0"
SENTRY_ORG = "manaflow"
# The project id in CmuxNextCrashReporting's DSN (CrashReporter.dsn): the sessions API takes ids, not slugs.
SENTRY_PROJECT_ID = "4510796264636416"
SENTRY_ENVIRONMENT = "nightly-next"
# Release health over this window: a feed build is newer than a day almost always (about 3 builds an hour).
WINDOW_H = 24

MIN_CRASHED = 2
CRASH_FREE_FLOOR = 0.995  # the quality report's own threshold
MIN_HANGS = 3
HANG_RATE_FLOOR = 0.2
HANG_RATE_FACTOR = 2.0
MIN_SESSIONS = 5
PASS_AFTER_S = 15 * 60
VERDICTS = ("pass", "fail", "pending", "unknown")
# About 3 builds an hour reach the feed, so a 15-minute tick sees at most one or two new ones.
RECENT = 3
DRILL_SESSIONS = 20
DRILL_CRASHED = 5
# The one issue a blind gate opens (nightly-next-health.yml, job blind); an open one is never repeated.
BLIND_TITLE = "nightly-next health gate is blind: Sentry is not read"

ITEM = re.compile(r"<item>.*?</item>", re.S)
VERSION = re.compile(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>")
SHORT = re.compile(r"<sparkle:shortVersionString>\s*([^<]*?)\s*</sparkle:shortVersionString>")
CHANNEL = re.compile(r"<sparkle:channel>\s*([^<]*?)\s*</sparkle:channel>")
# The tags Nightly apps accept (UpdateRing.swift; nightly_next_launch_smoke.NIGHTLY_CHANNELS).
NIGHTLY_CHANNELS = (None, "cmux-next-stable", "cmux-next")


class SourceError(Exception):
    pass


def iso(t: dt.datetime) -> str:
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(text: Any) -> Optional[dt.datetime]:
    if not isinstance(text, str) or not text:
        return None
    try:
        return dt.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def nightly_builds(feed: str) -> List[Tuple[int, str]]:
    """(build, short version) of each feed item Nightly apps are offered, newest first."""
    found = []
    for item in ITEM.findall(feed):
        version, short, channel = VERSION.search(item), SHORT.search(item), CHANNEL.search(item)
        if version and (channel.group(1) if channel else None) in NIGHTLY_CHANNELS:
            found.append((int(version.group(1)), short.group(1) if short else ""))
    return sorted(found, reverse=True)


def release_name(build: int, short: str) -> str:
    return f"cmux-next@{short}+{build}"


# Sentry


def sentry_get(path: str, params: List[Tuple[str, str]], token: str,
               opener: Callable = urllib.request.urlopen) -> Any:
    url = f"{SENTRY_API}{path}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "User-Agent": "cmux-health/1"})
    try:
        with opener(request, timeout=30) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as e:
        hint = " (the token needs org:read and event:read)" if e.code in (401, 403) else ""
        raise SourceError(f"Sentry answered HTTP {e.code} for {path}{hint}") from e
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as e:
        raise SourceError(f"Sentry did not answer {path}: {e}") from e


def sessions_of(get: Callable[[str, List[Tuple[str, str]]], Any], release: str) -> Dict[str, Any]:
    """Sessions of RELEASE by status over WINDOW_H, and the time of its first session bucket."""
    params = [("project", SENTRY_PROJECT_ID), ("environment", SENTRY_ENVIRONMENT), ("field", "sum(session)"),
              ("groupBy", "session.status"), ("statsPeriod", f"{WINDOW_H}h"), ("interval", "5m"),
              ("query", f'release:"{release}"')]
    data = get(f"/organizations/{SENTRY_ORG}/sessions/", params)
    by_status: Dict[str, int] = {}
    first = None
    intervals = data.get("intervals") or []
    for group in data.get("groups") or []:
        status = str((group.get("by") or {}).get("session.status") or "unknown")
        by_status[status] = by_status.get(status, 0) + int((group.get("totals") or {}).get("sum(session)") or 0)
        series = (group.get("series") or {}).get("sum(session)") or []
        for at, n in zip(intervals, series):
            if n:
                first = at if first is None or at < first else first
                break
    return {"sessions": sum(by_status.values()), "crashed": by_status.get("crashed", 0),
            "abnormal": by_status.get("abnormal", 0), "first_session_at": first}


def hangs_of(get: Callable[[str, List[Tuple[str, str]]], Any], release: str) -> int:
    """App hang events of RELEASE over WINDOW_H (sentry-cocoa's AppHang mechanism, fatal or not)."""
    params = [("project", SENTRY_PROJECT_ID), ("environment", SENTRY_ENVIRONMENT), ("dataset", "errors"),
              ("field", "count()"), ("statsPeriod", f"{WINDOW_H}h"),
              ("query", f'release:"{release}" error.mechanism:AppHang')]
    rows = (get(f"/organizations/{SENTRY_ORG}/events/", params) or {}).get("data") or []
    return int(rows[0].get("count()") or 0) if rows else 0


def sentry_read(feed: str, build: Optional[int], get: Callable) -> Dict[str, Any]:
    """The reading of the newest Nightly build (or BUILD) and the Nightly build before it."""
    builds = nightly_builds(feed)
    if build is not None:
        builds = [b for b in builds if b[0] <= build]
    reading: Dict[str, Any] = {"source": "sentry", "builds": {}, "why": None}
    for number, short in builds[:2]:
        release = release_name(number, short)
        try:
            entry = sessions_of(get, release)
            entry["hangs"] = hangs_of(get, release)
        except SourceError as e:
            reading["why"] = str(e)
            break
        entry["release"] = release
        reading["builds"][str(number)] = entry
    return reading


# The verdict


def rate(part: int, whole: int) -> Optional[float]:
    return round(part / whole, 6) if whole else None


def judge(feed: str, reading: Dict[str, Any], existing: Optional[Dict[str, Any]], now: dt.datetime,
          build: Optional[int] = None, run_url: str = "") -> Dict[str, Any]:
    """{"health": B's health file, "action": "rollback" | "none", "why": ...}. EXISTING is B's earlier file."""
    builds = nightly_builds(feed)
    if build is None:
        if not builds:
            raise SourceError("the feed offers Nightly apps no build")
        build = builds[0][0]
    earlier = [b for b, _ in builds if b < build]
    previous = earlier[0] if earlier else None
    mine = (reading.get("builds") or {}).get(str(build)) or {}
    theirs = ((reading.get("builds") or {}).get(str(previous)) or {}) if previous else {}
    sessions, crashed, hangs = int(mine.get("sessions") or 0), int(mine.get("crashed") or 0), int(mine.get("hangs") or 0)
    crash_free = None if not sessions else round(1 - crashed / sessions, 6)
    prev_crash_free = None if not theirs.get("sessions") else round(1 - theirs["crashed"] / theirs["sessions"], 6)
    hang_rate, prev_hang_rate = rate(hangs, sessions), rate(int(theirs.get("hangs") or 0), int(theirs.get("sessions") or 0))

    first = parse_time((existing or {}).get("first_session_at")) or parse_time(mine.get("first_session_at"))
    if first is None and sessions:
        first = now
    age = (now - first).total_seconds() if first else None

    reasons = []
    blind = bool(reading.get("why") and (not mine or (previous is not None and not theirs)))
    if blind:
        # A build is judged only against the build before it: half a reading is no reading.
        verdict = "unknown"
        reasons.append(f"Sentry was not read: {reading['why']}")
    else:
        if crashed >= MIN_CRASHED and crash_free is not None and crash_free < CRASH_FREE_FLOOR \
                and (prev_crash_free is None or crash_free < prev_crash_free):
            reasons.append(f"crash-free sessions {crash_free:.2%} ({crashed} of {sessions} crashed), under "
                           f"{CRASH_FREE_FLOOR:.1%} and under build {previous}'s "
                           f"{'n/a' if prev_crash_free is None else f'{prev_crash_free:.2%}'}")
        if hangs >= MIN_HANGS and hang_rate is not None and hang_rate > HANG_RATE_FLOOR \
                and (prev_hang_rate is None or hang_rate > HANG_RATE_FACTOR * prev_hang_rate):
            reasons.append(f"{hangs} app hangs in {sessions} sessions ({hang_rate:.2f} a session), over "
                           f"{HANG_RATE_FLOOR} and over {HANG_RATE_FACTOR:g}x build {previous}'s "
                           f"{'n/a' if prev_hang_rate is None else f'{prev_hang_rate:.2f}'}")
        if reasons:
            verdict = "fail"
        elif sessions >= MIN_SESSIONS or (age is not None and age >= PASS_AFTER_S):
            verdict = "pass"
            reasons.append(f"{sessions} sessions, {crashed} crashed, {hangs} hangs")
        else:
            verdict = "pending"
            reasons.append("no session yet" if not sessions else
                           f"{sessions} sessions in {int(age or 0)} s; a pass needs {MIN_SESSIONS} or {PASS_AFTER_S} s")

    health = {
        "build": str(build), "verdict": verdict, "why": "; ".join(reasons),
        "previous": str(previous) if previous else None,
        "sessions": sessions, "crashed": crashed, "abnormal": int(mine.get("abnormal") or 0), "hangs": hangs,
        "crash_free_rate": crash_free, "hang_rate": hang_rate,
        "previous_crash_free_rate": prev_crash_free, "previous_hang_rate": prev_hang_rate,
        "first_session_at": iso(first) if first else None,
        "first_verdict_at": (existing or {}).get("first_verdict_at") or (iso(now) if verdict in ("pass", "fail") else None),
        "failed_at": (existing or {}).get("failed_at") or (iso(now) if verdict == "fail" else None),
        "checked_at": iso(now), "source": reading.get("source"), "release": mine.get("release"), "run": run_url,
    }
    if verdict != "fail":
        return {"health": health, "action": "none", "why": health["why"], "blind": blind}
    if builds and build != builds[0][0]:
        return {"health": health, "action": "none", "blind": False,
                "why": f"the feed's newest build is {builds[0][0]}, newer than {build}; a pull of {build} would pull it too"}
    if previous is None:
        return {"health": health, "action": "none", "blind": False, "why": f"no earlier Nightly build on the feed to serve instead of {build}"}
    return {"health": health, "action": "rollback", "serving": str(previous), "blind": False,
            "why": f"build {build} failed its health check: {health['why']}"}


def blind_report(result: Dict[str, Any], run_url: str) -> Dict[str, str]:
    """The title and body of the one issue a blind gate opens: which build, why, and the fix."""
    h = result.get("health") or {}
    body = (f"The cmux NEXT health gate (nightly-next-health.yml) could not read Sentry release health, so build "
            f"{h.get('build')} has the verdict unknown and a crashing build would stay on the feed.\n\n"
            f"Why: {result.get('why')}\n\nRun: {run_url}\n\n"
            "Fix: give the release-next environment's SENTRY_AUTH_TOKEN the org:read and event:read scopes "
            "(org manaflow). Each tick turns red while the gate is blind; close this issue once a tick reads "
            "Sentry again. This issue is opened once: an open one is never repeated.")
    return {"title": BLIND_TITLE, "body": body}


def drill_reading(build: int, now: dt.datetime) -> Dict[str, Any]:
    """The rollback drill's reading of its bad canary BUILD: DRILL_SESSIONS sessions, DRILL_CRASHED of them
    crashed, so the drill times every step after the Sentry read on the production route."""
    return {"source": "drill", "why": None, "builds": {str(build): {
        "sessions": DRILL_SESSIONS, "crashed": DRILL_CRASHED, "abnormal": 0, "hangs": 0,
        "first_session_at": iso(now), "release": f"drill+{build}"}}}


def load(path: Optional[str]) -> Optional[Dict[str, Any]]:
    if not path or not Path(path).is_file():
        return None
    try:
        doc = json.loads(Path(path).read_text())
    except json.JSONDecodeError:
        return None
    return doc if isinstance(doc, dict) else None


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("sentry-read")
    r.add_argument("--feed", required=True)
    r.add_argument("--build", type=int)
    r.add_argument("--out", required=True)
    j = sub.add_parser("judge")
    j.add_argument("--feed", required=True)
    j.add_argument("--reading", required=True)
    j.add_argument("--existing")
    j.add_argument("--build", type=int)
    j.add_argument("--now", required=True)
    j.add_argument("--run-url", default="")
    j.add_argument("--out", required=True)
    p = sub.add_parser("recent")
    p.add_argument("--feed", required=True)
    b = sub.add_parser("blind-report")
    b.add_argument("--result", required=True)
    b.add_argument("--run-url", default="")
    d = sub.add_parser("drill-reading")
    d.add_argument("--build", type=int, required=True)
    d.add_argument("--now", required=True)
    d.add_argument("--out", required=True)
    args = parser.parse_args(argv)

    if args.command == "sentry-read":
        token = os.environ.get("SENTRY_AUTH_TOKEN", "")
        feed = Path(args.feed).read_text()
        if not token:
            reading = {"source": "sentry", "builds": {}, "why": "no SENTRY_AUTH_TOKEN"}
        else:
            reading = sentry_read(feed, args.build, lambda path, params: sentry_get(path, params, token))
        Path(args.out).write_text(json.dumps(reading, indent=2) + "\n")
        print(json.dumps(reading))
        return 0
    if args.command == "recent":
        builds = nightly_builds(Path(args.feed).read_text())
        if not builds:
            print("nightly-next health: the feed offers Nightly apps no build", file=sys.stderr)
            return 1
        print(" ".join(str(b) for b, _ in builds[:RECENT]))
        return 0
    if args.command == "judge":
        now = parse_time(args.now)
        if now is None:
            parser.error(f"--now {args.now!r} is not YYYY-MM-DDTHH:MM:SSZ")
        reading = load(args.reading) or {"source": None, "builds": {}, "why": f"no reading at {args.reading}"}
        try:
            result = judge(Path(args.feed).read_text(), reading, load(args.existing), now, args.build, args.run_url)
        except SourceError as e:
            print(f"nightly-next health: {e}", file=sys.stderr)
            return 1
        Path(args.out).write_text(json.dumps(result["health"], indent=2) + "\n")
        print(json.dumps(result))
        return 0
    if args.command == "blind-report":
        print(json.dumps(blind_report(load(args.result) or {}, args.run_url)))
        return 0
    now = parse_time(args.now)
    if now is None:
        parser.error(f"--now {args.now!r} is not YYYY-MM-DDTHH:MM:SSZ")
    Path(args.out).write_text(json.dumps(drill_reading(args.build, now), indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
