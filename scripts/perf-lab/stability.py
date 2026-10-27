#!/usr/bin/env python3
"""Nightly stability from Sentry: crash-free rates per release and new top crash signatures (p12-perf-process-225).

    SENTRY_AUTH_TOKEN=... python3 -I scripts/perf-lab/lab.py stability --since 7d [--json] [--out PATH]
    SENTRY_AUTH_TOKEN=... python3 -I scripts/perf-lab/lab.py stability --since 7d --db lab.sqlite [--sync-issues]

Chrome reports stability per channel and version (crash-free sessions and users, Stability.Counts2 in
components/metrics/stability_metrics_provider.cc) and files one bug per new crash signature (ClusterFuzz,
src/clusterfuzz/_internal/issue_management/issue_filer.py). This command does the same for cmux NEXT with the
shared Sentry project (CrashReportingPolicy.swift: release `cmux-next@<version>+<build>`, environment
`nightly-next`, tag `app:cmux-next`), p12-perf-process.md 3.10:

- Per release: sessions, installs, crash-free sessions and crash-free installs (release health). Sentry Cocoa
  counts a session's user as its installation id when no user is set (CrashReporter.swift sets none), so
  `count_unique(user)` is installs.
- New top signatures: the --top unhandled (crash) issues first seen inside the window, most events first, each
  with the release Sentry saw it in first.
- With --db, each new top signature is one alert group in the lab store (state `new`, one sheriff_history row by
  actor perf-lab-stability), so the sheriff loop (sheriff.py) triages it like a perf group. Its field_signatures
  row (store migration 4) keys the group, so a signature gets one group, ever, and marks it a field group: Pinpoint
  never bisects it and the perf SLO leaves it out. Each run also reads every open field group's last release from
  Sentry and stores the newer cmux NEXT releases with sessions that did not crash with it; the sheriff's `fixed`
  needs sheriff.FIELD_CLEAN_RELEASES of them.
- With --sync-issues, each group links the one GitHub issue of its Sentry issue: stability_issues.py's issue
  (it keeps exactly one per Sentry id and edits it, never files a second), or the issue the Sentry issue already
  links or an other-owner entry claims. Then each sheriff state change is posted once to that issue, with the
  marker alerts.py uses, read back through glaeda-gh.

Read-only on Sentry. The token comes only from SENTRY_AUTH_TOKEN; it goes through stability-health.py's transport
(HTTPS only, no cross-host redirect, redacted from every error) and is never printed. Field rows are reported on
the dashboard and in done check 18; they are never judged.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
import re
import sqlite3
import sys
import tempfile
from collections.abc import Callable, Mapping, Sequence
from contextlib import nullcontext
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

LAB_COMMANDS = {"stability": "Nightly stability from Sentry: crash-free sessions and installs per release, new top "
                             "crash signatures as sheriff alert groups (read-only Sentry)."}

HERE = Path(__file__).resolve().parent
CMUX_NEXT_SCRIPTS = HERE.parent / "cmux-next"
TOKEN_ENV = "SENTRY_AUTH_TOKEN"
BASE_URL_ENV = "SENTRY_URL"
ENVIRONMENTS = ("nightly-next", "rc-next", "release-next", "dev")
SCHEMA = "cmux-perf-lab-stability/v1"
RELEASE = re.compile(r"^cmux-next@(?P<version>[^\s+@]+)\+(?P<build>\d+)$")
APP_QUERY = "app:cmux-next"
CRASH_QUERY = "error.unhandled:true"
SENTRY_ID = re.compile(r"^\d+$")
MAX_SINCE_HOURS = 90 * 24
MAX_PAGES = 10
DEFAULT_TOP = 10
ACTOR = "perf-lab-stability"
SIGNATURE_KEY = "stability sentry:"
SOURCE = "sentry"
# A field signature has no commit range; -1..-1 overlaps no waterfall range, so no perf alert joins its group.
NO_COMMIT_RANGE = -1
SESSION_FIELDS = ("sum(session)", "count_unique(user)", "crash_free_rate(session)", "crash_free_rate(user)")


class StabilityError(RuntimeError):
    """A stability read or write that cannot run; the message never carries the token."""


def _load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None:
        raise StabilityError(f"no module at {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


health = _load("perf_lab_stability_health", CMUX_NEXT_SCRIPTS / "stability-health.py")
issues_mod = _load("perf_lab_stability_issues", CMUX_NEXT_SCRIPTS / "stability_issues.py")
store_mod = _load("perf_lab_store", HERE / "store.py")
alerts = _load("perf_lab_alerts", HERE / "alerts.py")
sheriff_mod = _load("perf_lab_sheriff", HERE / "sheriff.py")

Fetch = Callable[[str, list[tuple[str, str]]], tuple[Any, dict[str, str]]]


# --- window -------------------------------------------------------------------------------------------------------


def parse_since(text: str) -> int:
    """`7d` or `48h` as hours, 1 h to 90 d."""
    match = re.fullmatch(r"(\d+)([dh])", text.strip())
    if not match:
        raise StabilityError(f"--since must look like 7d or 48h, not {text!r}")
    hours = int(match.group(1)) * (24 if match.group(2) == "d" else 1)
    if not 1 <= hours <= MAX_SINCE_HOURS:
        raise StabilityError(f"--since must be 1h to {MAX_SINCE_HOURS // 24}d")
    return hours


def stats_period(hours: int) -> str:
    return f"{hours // 24}d" if hours % 24 == 0 else f"{hours}h"


@dataclass(frozen=True)
class Scope:
    org: str
    project_id: str
    env: str
    since_hours: int

    def params(self) -> list[tuple[str, str]]:
        return [("project", self.project_id), ("environment", self.env), ("statsPeriod", stats_period(self.since_hours))]


# --- crash-free rates ---------------------------------------------------------------------------------------------


def _rate(value: object, where: str) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value <= 1:
        raise StabilityError(f"{where}: crash-free rate {value!r} is not a fraction 0..1")
    return float(value)


def _count(value: object, where: str) -> int:
    if value is None:
        return 0
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0 or not float(value).is_integer():
        raise StabilityError(f"{where}: count {value!r} is not a whole number")
    return int(value)


@dataclass(frozen=True)
class Rates:
    sessions: int
    installs: int
    crash_free_sessions: float | None
    crash_free_installs: float | None

    @classmethod
    def from_totals(cls, totals: Mapping[str, object], where: str) -> "Rates":
        sessions = _count(totals.get("sum(session)"), where)
        installs = _count(totals.get("count_unique(user)"), where)
        # Sentry reports no rate for a release with no sessions; a rate over zero sessions is not a rate.
        return cls(sessions, installs,
                   _rate(totals.get("crash_free_rate(session)"), where) if sessions else None,
                   _rate(totals.get("crash_free_rate(user)"), where) if installs else None)

    @property
    def crashed_sessions(self) -> int | None:
        return None if self.crash_free_sessions is None else round(self.sessions * (1 - self.crash_free_sessions))

    @property
    def crashed_installs(self) -> int | None:
        return None if self.crash_free_installs is None else round(self.installs * (1 - self.crash_free_installs))

    def to_dict(self) -> dict[str, object]:
        return {"sessions": self.sessions, "installs": self.installs,
                "crash_free_sessions": self.crash_free_sessions, "crash_free_installs": self.crash_free_installs,
                "crashed_sessions": self.crashed_sessions, "crashed_installs": self.crashed_installs}


@dataclass(frozen=True)
class ReleaseRow:
    release: str
    version: str
    build: int
    rates: Rates


def release_rows(groups: Sequence[Mapping[str, Any]]) -> list[ReleaseRow]:
    """cmux NEXT releases (`cmux-next@<version>+<build>`) from release-health groups, newest build first.

    Other names in the shared project (main's app, DEV builds) are left out. A release named twice (two pages)
    keeps its first group."""
    rows: dict[str, ReleaseRow] = {}
    for group in groups:
        name = str((group.get("by") or {}).get("release") or "")
        match = RELEASE.match(name)
        if match is None or name in rows:
            continue
        rows[name] = ReleaseRow(name, match.group("version"), int(match.group("build")),
                                Rates.from_totals(group.get("totals") or {}, name))
    return sorted(rows.values(), key=lambda row: -row.build)


def _sessions(fetch: Fetch, scope: Scope, extra: list[tuple[str, str]]) -> list[dict[str, Any]]:
    path = f"/organizations/{scope.org}/sessions/"
    params = scope.params() + [("interval", "1d" if scope.since_hours % 24 == 0 else "1h"), ("includeSeries", "0"),
                               *[("field", name) for name in SESSION_FIELDS], *extra]
    groups: list[dict[str, Any]] = []
    cursor = None
    for _ in range(MAX_PAGES):
        data, headers = fetch(path, params + ([("cursor", cursor)] if cursor else []))
        with health.response_shape(path):
            page = data["groups"]
            if not isinstance(page, list):
                raise TypeError("groups")
            groups += page
        cursor = health.next_cursor(headers)
        if cursor is None or not page:
            break
    return groups


def fetch_rates(fetch: Fetch, scope: Scope) -> tuple[Rates, list[ReleaseRow]]:
    """The environment's overall rates and the per-release rows."""
    totals = _sessions(fetch, scope, [])
    overall = Rates.from_totals((totals[0] if totals else {}).get("totals") or {}, f"{scope.env} totals")
    by_release = _sessions(fetch, scope, [("groupBy", "release"), ("orderBy", "-sum(session)"), ("per_page", "100")])
    return overall, release_rows(by_release)


# --- new top signatures -------------------------------------------------------------------------------------------


def _instant(text: object) -> datetime | None:
    if not isinstance(text, str) or not text:
        return None
    try:
        value = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


@dataclass(frozen=True)
class Signature:
    """One new top crash signature: a Sentry issue (normalized by stability-health.py), its first and last release."""

    issue: Mapping[str, Any]
    first_release: str | None
    last_release: str | None = None

    @property
    def sentry_id(self) -> str:
        return str(self.issue["id"])

    def reason(self) -> str:
        """The creation row's reason."""
        title = " ".join(str(self.issue.get("title") or "").split())[:120]
        return (f"{SIGNATURE_KEY}{self.sentry_id}: new top crash signature {self.issue.get('short_id') or '-'} "
                f"{title} (first release {self.first_release or 'unknown'}, {self.issue.get('events', 0)} events, "
                f"{self.issue.get('users', 0)} installs)")

    def to_dict(self) -> dict[str, object]:
        return {**self.issue, "first_release": self.first_release}


def new_top_issues(fetch: Fetch, scope: Scope, *, top: int, now: datetime,
                   owners: Sequence[Mapping[str, Any]] = ()) -> list[dict[str, Any]]:
    """The `top` unhandled cmux NEXT issues first seen in the window, most events first (normalized)."""
    path = f"/organizations/{scope.org}/issues/"
    oldest = now - timedelta(hours=scope.since_hours)
    query = f"{APP_QUERY} {CRASH_QUERY} firstSeen:-{scope.since_hours}h"
    found: list[dict[str, Any]] = []
    cursor = None
    for _ in range(MAX_PAGES):
        params = scope.params() + [("query", query), ("sort", "freq"), ("limit", str(min(100, top)))]
        data, headers = fetch(path, params + ([("cursor", cursor)] if cursor else []))
        if not isinstance(data, list):
            raise health.SentryError(f"GET {path}: expected a list, got {type(data).__name__}")
        with health.response_shape(path):
            for raw in data:
                issue = health.normalize_issue(raw, list(owners))
                first_seen = _instant(issue["first_seen"])
                # The server filter is the window; a signature seen before it is not new, whatever the filter did.
                if SENTRY_ID.match(issue["id"]) and first_seen is not None and first_seen >= oldest:
                    found.append(issue)
        cursor = health.next_cursor(headers)
        if len(found) >= top or cursor is None or not data:
            break
    return sorted(found, key=lambda issue: -issue["events"])[:top]


def issue_releases(fetch: Fetch, scope: Scope, sentry_id: str) -> tuple[str | None, str | None]:
    """The releases Sentry first and last saw the issue in, in this environment; None when not a cmux NEXT release."""
    path = f"/organizations/{scope.org}/issues/{sentry_id}/"
    data, _ = fetch(path, [("environment", scope.env)])

    def version(key: str) -> str | None:
        release = data.get(key) or {}
        name = release.get("version") if isinstance(release, dict) else None
        return name if isinstance(name, str) and RELEASE.match(name) else None

    with health.response_shape(path):
        return version("firstRelease"), version("lastRelease")


def fetch_signatures(fetch: Fetch, scope: Scope, *, top: int, now: datetime,
                     owners: Sequence[Mapping[str, Any]] = ()) -> list[Signature]:
    return [Signature(issue, *issue_releases(fetch, scope, issue["id"]))
            for issue in new_top_issues(fetch, scope, top=top, now=now, owners=owners)]


# --- the report ---------------------------------------------------------------------------------------------------


def report(scope: Scope, overall: Rates, rows: Sequence[ReleaseRow], signatures: Sequence[Signature], *,
           now: datetime, base_url: str) -> dict[str, Any]:
    new_by_release: dict[str, int] = {}
    for signature in signatures:
        if signature.first_release:
            new_by_release[signature.first_release] = new_by_release.get(signature.first_release, 0) + 1
    return {
        "schema": SCHEMA,
        "generated_at": now.astimezone(timezone.utc).isoformat(timespec="seconds"),
        "source": f"Sentry {base_url} org {scope.org} project {scope.project_id} environment {scope.env}",
        "env": scope.env,
        "since_hours": scope.since_hours,
        "overall": overall.to_dict(),
        # dashboard.StabilityRow reads release, crash_free_sessions, crash_free_installs and new_signatures.
        "releases": [{"release": row.release, "version": row.version, "build": row.build, **row.rates.to_dict(),
                      "new_signatures": new_by_release.get(row.release, 0)} for row in rows],
        "new_signatures": [signature.to_dict() for signature in signatures],
    }


def _percent(value: object) -> str:
    return "n/a" if value is None else f"{float(value) * 100:.2f} %"


def render_text(result: Mapping[str, Any]) -> str:
    overall = result["overall"]
    lines = [f"cmux NEXT stability, {result['env']}, last {result['since_hours']} h ({result['generated_at']})",
             f"overall: {overall['sessions']} sessions, {overall['installs']} installs, crash-free sessions "
             f"{_percent(overall['crash_free_sessions'])}, installs {_percent(overall['crash_free_installs'])}", "",
             f"{'release':<40} {'sessions':>9} {'installs':>9} {'cf sessions':>12} {'cf installs':>12} {'new':>4}"]
    for row in result["releases"]:
        lines.append(f"{row['release']:<40} {row['sessions']:>9} {row['installs']:>9} "
                     f"{_percent(row['crash_free_sessions']):>12} {_percent(row['crash_free_installs']):>12} "
                     f"{row['new_signatures']:>4}")
    lines += ["", f"new top crash signatures: {len(result['new_signatures'])}"]
    lines += [f"  {s['short_id'] or s['id']:<22} {s['events']:>7} {s['first_release'] or 'unknown':<32} "
              f"{str(s['title'])[:60]}" for s in result["new_signatures"]]
    for key in ("groups", "issues"):
        if key in result:
            lines += ["", f"{key}: {json.dumps(result[key], sort_keys=True)}"]
    return "\n".join(lines)


# --- alert groups -------------------------------------------------------------------------------------------------


def signature_groups(store) -> dict[str, int]:
    """Sentry id -> its alert group (field_signatures)."""
    return {row["signature"]: row["group_id"] for row in store._db.execute(
        "SELECT signature, group_id FROM field_signatures WHERE source = ?", (SOURCE,))}


@dataclass
class GroupReport:
    created: dict[str, int] = field(default_factory=dict)
    existing: dict[str, int] = field(default_factory=dict)
    judged: dict[str, dict[str, object]] = field(default_factory=dict)

    def to_dict(self) -> dict[str, object]:
        return dict(self.__dict__)

    def all(self) -> dict[str, int]:
        return {**self.existing, **self.created}


def record_groups(store, signatures: Sequence[Signature]) -> GroupReport:
    """One alert group per new top signature that has none, keyed by its field_signatures row (UNIQUE), in one write
    transaction with the read, so two runs never make two groups for one signature."""
    out = GroupReport()

    def write() -> None:
        known = signature_groups(store)
        now = store._now()
        for signature in signatures:
            if signature.sentry_id in known:
                out.existing[signature.sentry_id] = known[signature.sentry_id]
                continue
            group_id = store._db.execute(
                "INSERT INTO alert_groups (state, start_pos, end_pos, created_at, updated_at) VALUES ('new', ?, ?, ?, ?)",
                (NO_COMMIT_RANGE, NO_COMMIT_RANGE, now, now)).lastrowid
            store._db.execute("INSERT INTO field_signatures (group_id, source, signature) VALUES (?, ?, ?)",
                              (group_id, SOURCE, signature.sentry_id))
            store._db.execute(
                "INSERT INTO sheriff_history (group_id, from_state, to_state, actor, reason, at) "
                "VALUES (?, NULL, 'new', ?, ?, ?)", (group_id, ACTOR, signature.reason(), now))
            known[signature.sentry_id] = group_id
            out.created[signature.sentry_id] = group_id

    store._write(write)
    return out


def clean_releases(rows: Sequence[ReleaseRow], last_release: str | None) -> list[str]:
    """The cmux NEXT releases with sessions built after `last_release`, newest first: each ran without the signature."""
    match = RELEASE.match(last_release or "")
    if match is None:
        return []
    last_build = int(match.group("build"))
    return [row.release for row in rows if row.rates.sessions > 0 and row.build > last_build]


def judge_groups(store, fetch: Fetch, scope: Scope, rows: Sequence[ReleaseRow], signatures: Sequence[Signature],
                 out: GroupReport) -> None:
    """Stores each open field group's last release and the releases since that ran clean (sheriff.field_recovery
    judges `fixed` on them). A signature of this run reuses its read; any other open group costs one issue read."""
    marks = ",".join("?" * len(sheriff_mod.TERMINAL))
    groups = store._db.execute(
        f"""SELECT f.group_id, f.signature FROM field_signatures f JOIN alert_groups g ON g.id = f.group_id
            WHERE f.source = ? AND g.state NOT IN ({marks}) ORDER BY f.group_id""",
        (SOURCE, *sorted(sheriff_mod.TERMINAL))).fetchall()
    read = {signature.sentry_id: signature.last_release for signature in signatures}
    evidence: list[tuple[int, str, str | None, list[str]]] = []
    for group in groups:
        sentry_id = group["signature"]
        last = read[sentry_id] if sentry_id in read else issue_releases(fetch, scope, sentry_id)[1]
        evidence.append((group["group_id"], sentry_id, last, clean_releases(rows, last)))

    def write() -> None:
        now = store._now()
        for group_id, _, last, clean in evidence:
            store._db.execute("UPDATE field_signatures SET last_release = ?, clean_releases_json = ?, checked_at = ? "
                              "WHERE group_id = ?", (last, json.dumps(clean), now, group_id))

    store._write(write)
    for group_id, sentry_id, last, clean in evidence:
        out.judged[sentry_id] = {"group": group_id, "last_release": last, "clean_releases": clean,
                                 "recovered": len(clean) >= sheriff_mod.FIELD_CLEAN_RELEASES}


# --- GitHub issues ------------------------------------------------------------------------------------------------


def health_entries(signatures: Sequence[Signature]) -> list[dict[str, Any]]:
    return [dict(signature.issue) for signature in signatures]


def issue_numbers(issues: Sequence[Any], entries: Sequence[Mapping[str, Any]]) -> dict[str, int]:
    """Sentry id -> the one GitHub issue that tracks it, decided in stability_issues.plan_sentry's order: the stability
    issue whose state links it (the lowest number), else the other owner's issue, else the stability issue its
    annotations name, else the first issue they name. A signature issue not filed yet (a deferred write) has none."""
    stability_numbers = {issue.number for issue in issues_mod.index_issues(list(issues))[0].values()}
    linked: dict[str, int] = {}
    for issue in sorted(issues, key=lambda item: item.number):
        for sentry_id in (issues_mod.read_state(issue.body) or {}).get("sentry") or {}:
            linked.setdefault(str(sentry_id), issue.number)
    for entry in entries:
        sentry_id = str(entry["id"]).strip()
        if sentry_id in linked:
            continue
        owner = entry.get("owner")
        named = [int(number) for number in entry.get("github") or ()]
        if owner:
            if isinstance(owner.get("github_issue"), int):
                linked[sentry_id] = owner["github_issue"]
        elif named:
            linked[sentry_id] = next((number for number in named if number in stability_numbers), named[0])
    return linked


@dataclass
class IssueReport:
    applied: list[str] = field(default_factory=list)
    deferred: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    linked: dict[str, int] = field(default_factory=dict)
    comments: int = 0

    def to_dict(self) -> dict[str, object]:
        return dict(self.__dict__)


def sync_issues(store, signatures: Sequence[Signature], groups: Mapping[str, int], *, github, comments, env: str,
                since_hours: int, now: datetime, max_writes: int, dry_run: bool) -> IssueReport:
    """Keeps one issue per signature through stability_issues.py, links each group to it, then posts each sheriff
    state change of the group once (alerts.py's marker and comment text). A dry run writes no GitHub issue; its
    store is a copy (_open_store), so the links it makes there show what a real run would post."""
    out = IssueReport()
    entries = health_entries(signatures)
    report_doc = {"schema": issues_mod.HEALTH_SCHEMA, "env": env, "days": math.ceil(since_hours / 24),
                  "top_issues": entries}
    listed = github.list_issues(issues_mod.LABEL)
    tracked, notes = issues_mod.plan_sentry(listed, report_doc)
    outcome = issues_mod.apply(tracked, github, max_writes, dry_run)
    out.applied, out.deferred, out.notes = outcome.applied, outcome.deferred, notes + outcome.notes
    if not dry_run and outcome.applied:
        listed = github.list_issues(issues_mod.LABEL)  # the bodies just written, and the numbers just created
    numbers = issue_numbers(listed, entries)
    for sentry_id, group_id in groups.items():
        if sentry_id in numbers:
            out.linked[sentry_id] = numbers[sentry_id]
            store._write(lambda: store._db.execute(
                "UPDATE alert_groups SET issue_number = ?, updated_at = ? WHERE id = ? AND issue_number IS NULL",
                (numbers[sentry_id], store._now(), group_id)))
    out.comments = post_state_changes(store, comments, changed_since=now - timedelta(hours=since_hours))
    return out


def post_state_changes(store, comments, *, changed_since: datetime) -> int:
    """One comment per sheriff_history row of each linked field group that changed since `changed_since`, posted
    once: which of the group's own rows an issue has is read back from its comments (alerts.STATE_MARKER; groups that
    share one issue interleave their rows there). An issue with none of the group's rows yet gets its current state.
    Every move updates the group, so a run per window posts every move."""
    groups = store._db.execute(
        """SELECT g.id, g.issue_number FROM alert_groups g JOIN field_signatures f ON f.group_id = g.id
           WHERE g.issue_number IS NOT NULL AND g.updated_at >= ? ORDER BY g.id""",
        (store_mod._stamp(changed_since),)).fetchall()
    posted_count = 0
    for group in groups:
        history = store._db.execute("SELECT * FROM sheriff_history WHERE group_id = ? ORDER BY id",
                                    (group["id"],)).fetchall()
        own = {row["id"] for row in history}
        posted = [marker for body in comments.issue_comment_bodies(group["issue_number"])
                  for marker in map(int, alerts.STATE_MARKER.findall(body)) if marker in own]
        pending = [row for row in history if row["id"] > max(posted)] if posted else history[-1:]
        for change in pending:
            comments.comment(group["issue_number"], alerts.render_state_comment(change))
            posted_count += 1
    return posted_count


# --- CLI ----------------------------------------------------------------------------------------------------------


def _snapshot(db: Path, directory: Path) -> Path:
    copy = directory / "dry-run.sqlite"
    source = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    target = sqlite3.connect(copy)
    try:
        source.backup(target)
    finally:
        source.close()
        target.close()
    return copy


def _open_store(db: Path, scratch: Path | None, clock: Callable[[], datetime]):
    """An existing, migrated store (labd creates it); a dry run gets a copy, so nothing reaches the real one."""
    if not db.is_file():
        raise StabilityError(f"{db}: no lab store there")
    handle = store_mod.Store(_snapshot(db, scratch) if scratch else db, clock=clock)
    if handle.schema_version() == 0:
        handle.close()
        raise StabilityError(f"{db}: the lab store is not migrated")
    return handle


def stability_command(args: argparse.Namespace, *, environ: Mapping[str, str], fetch: Fetch | None = None,
                      github=None, comments=None, clock: Callable[[], datetime] | None = None) -> int:
    token = environ.get(TOKEN_ENV, "").strip()
    try:
        since_hours = parse_since(args.since)
        if args.top < 1:
            raise StabilityError("--top must be at least 1")
        if args.sync_issues and args.db is None:
            raise StabilityError("--sync-issues links alert groups; pass --db")
        if fetch is None and not token:
            raise StabilityError(f"{TOKEN_ENV} is not set")
        owners = health.load_owners(Path(args.owners))
    except (StabilityError, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f"lab.py stability: {health.redact(str(error), token)}", file=sys.stderr)
        return 2
    clock = clock or store_mod.utc_now
    now = clock()
    scope = Scope(args.org, args.project_id, args.env, since_hours)
    try:
        sentry = fetch or health.http_fetch(args.base_url, token)
        overall, rows = fetch_rates(sentry, scope)
        signatures = fetch_signatures(sentry, scope, top=args.top, now=now, owners=owners)
    except (health.SentryError, StabilityError) as error:
        print(f"lab.py stability: {health.redact(str(error), token)}", file=sys.stderr)
        return 3
    result = report(scope, overall, rows, signatures, now=now, base_url=args.base_url)
    if args.db is not None:
        try:
            with tempfile.TemporaryDirectory(prefix="perf-lab-stability-") as scratch:
                store = _open_store(Path(args.db), Path(scratch) if args.dry_run else None, clock)
                try:
                    groups = record_groups(store, signatures)
                    judge_groups(store, sentry, scope, rows, signatures, groups)
                    result["groups"] = {"dry_run": args.dry_run, **groups.to_dict()}
                    if args.sync_issues:
                        client = github or issues_mod.GhCli(args.repo)
                        reader = comments or alerts.GhClient(args.repo)
                        if args.dry_run:
                            reader = alerts.RecordingGitHub(reader)
                        lock = nullcontext() if args.dry_run else issues_mod.repo_lock(
                            issues_mod.default_lock_file(args.repo))
                        with lock:
                            issues = sync_issues(store, signatures, groups.all(), github=client, comments=reader,
                                                 env=args.env, since_hours=since_hours, now=now,
                                                 max_writes=args.max_writes, dry_run=args.dry_run)
                        result["issues"] = {"dry_run": args.dry_run, **issues.to_dict()}
                        if isinstance(reader, alerts.RecordingGitHub):
                            result["issues"]["comment_actions"] = reader.actions
                finally:
                    store.close()
        except (StabilityError, store_mod.StoreError, sqlite3.Error, OSError, alerts.AlertsError,
                issues_mod.StabilityIssueError) as error:
            print(f"lab.py stability: {health.redact(str(error), token)}", file=sys.stderr)
            return 1
    text = json.dumps(result, indent=2, sort_keys=True)
    if args.out:
        _write_atomically(Path(args.out), text + "\n")
    print(text if args.json else render_text(result))
    if result.get("issues", {}).get("deferred"):
        print("lab.py stability: GitHub writes deferred; run the same command again", file=sys.stderr)
        return issues_mod.EX_TEMPFAIL
    return 0


def _write_atomically(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--since", default="7d", help="the window, as Nd or Nh (default 7d)")
    parser.add_argument("--env", default="nightly-next", choices=ENVIRONMENTS, help="Sentry environment")
    parser.add_argument("--top", type=int, default=DEFAULT_TOP, help=f"new top signatures (default {DEFAULT_TOP})")
    parser.add_argument("--org", default=health.DEFAULT_ORG)
    parser.add_argument("--project-id", default=health.DEFAULT_PROJECT_ID)
    parser.add_argument("--base-url", default=os.environ.get(BASE_URL_ENV, health.DEFAULT_BASE_URL))
    parser.add_argument("--owners", default=str(health.DEFAULT_OWNERS), help="other-owner map (stability-health.py)")
    parser.add_argument("--db", type=Path, help="the lab store: one alert group per new top signature")
    parser.add_argument("--sync-issues", action="store_true", help="link each group to its one GitHub issue and post "
                                                                   "its sheriff state changes")
    parser.add_argument("--repo", default=os.environ.get("CMUX_STABILITY_REPO", "manaflow-ai/cmux"))
    parser.add_argument("--max-writes", type=int, default=60, help="GitHub issue writes per run (stability_issues.py)")
    parser.add_argument("--dry-run", action="store_true", help="write a copy of the store and print GitHub writes")
    parser.add_argument("--out", metavar="PATH", help="also write the JSON report here (atomic replace)")
    parser.add_argument("--json", action="store_true", help="print JSON")


def run(command: str, args: argparse.Namespace) -> int:
    return stability_command(args, environ=os.environ)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="stability.py", description=LAB_COMMANDS["stability"])
    add_arguments("stability", parser)
    return run("stability", parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
