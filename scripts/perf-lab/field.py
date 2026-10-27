#!/usr/bin/env python3
"""Field import of opt-in Nightly hang reports (p12-perf-process-042, p12-perf-process.md 3.10).

    CMUX_FIELD_DATABASE_URL=... python3 -I scripts/perf-lab/lab.py field --since 7d [--json] [--out PATH]
    python3 -I scripts/perf-lab/lab.py field --fixture rows.jsonl --json

Chrome reports field performance as UMA histograms per channel, version and hardware class, beside the lab
(docs/speed/how_does_chrome_measure_performance.md), and normalizes hang counts by the time the thread was
watched (base/threading/hang_watcher.h; HangWatcher.IsThreadHung.* is logged per watched interval). This
module does the same with the PlanetScale `cmux-prod` table `hang_reports` (branch `main`, org `cmux`). Per
Nightly build, hardware class and features arm it reports (and again per field-trial arm, below):

- hangs > 250 ms per 1000 active hours: the watchdog's stall histogram (StallAggregate, every finished stall
  of 50 ms and up; its 250 ms edge splits the count exactly) over the reports that carry active seconds
  (task 043). A group with no active time has no rate, never a guessed one.
- action-latency histograms: the merged `action` signpost intervals, with interpolated p50, p95 and p99.
- turn histograms when present: the `main_turn` and `input_queueing` intervals (task 031's histograms,
  sent by task 043 as interval entries).
- the top main-thread blocking sites (task 226): schema 3's `blocking_sites[]`, the blocking detector's calls per
  site since the client's last report (nightly-next builds compile the detector in). A site is only its id, the
  first 8 bytes of SHA-256 over `Module/File.swift:line`, so no path leaves the Mac; `--sites-from CHECKOUT`
  names each id by hashing every line of that checkout's Swift sources (check out the build's commit).

The features arm is the report's `features_hash` (task 151). A Nightly field trial (task 152, FieldTrial.swift)
puts the install in one arm of each study it runs. Task 151's `features[]` names every feature an input other
than the channel default decided, as `{name, state, source}`; an entry of source `trial` is a feature whose
field-trial arm decided it, so a feature that policy, the environment, a Labs override or the remote document
forced is not in its study's arm. Every metric is also reported per (build, hardware class, `feature=on|off`)
of those entries, so the arms of one study compare directly, as Chrome's UMA splits each histogram by the
variation ids of the active field trials (components/variations/variations_ids_provider.h). One study owns a
feature and an arm only sets its state, so `feature=state` is the arm: two arms of one state run the same code.
A report counts once in its features group and once in each of its trial groups; the trial groups are left out
of the report total.

Rules (R10): SELECT only, counts only. Every query runs in one read-only repeatable-read transaction with
`default_transaction_read_only=on`, and `assert_select_only` refuses any other statement before psql starts.
The import first checks that its role cannot write `hang_reports` and stops if it can. The credential is the
connection URL of a read-only role, read from the environment variable CMUX_FIELD_DATABASE_URL. It reaches
psql only as PG* environment variables of the child process, never in argv, and is redacted from every error.
The operator makes the role once, with no write grant:

    pscale role create cmux-prod main field-ro --org cmux --inherited-roles pg_read_all_data

The URL must be for org `cmux`, database `cmux-prod`, branch `main`: a PlanetScale Postgres user name ends in
`.<branch id>` (the release rails' check, scripts/cmux-next/release/db-release.ts), so a staging, development
or other-database URL is refused before psql starts, and the report's `source` names the target.

The SELECT reads no frames, install ids leave the database only as count(DISTINCT install_id) per build,
hardware and features key or field-trial tag, and the output is aggregates. Field rows are reported on the dashboard (/field)
and in done check 18; they are never judged.
"""
from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlsplit

LAB_COMMANDS = {"field": "Nightly field data: hangs > 250 ms per 1000 active hours, action and turn histograms "
                         "per build and hardware class (read-only hang_reports)."}

URL_ENV = "CMUX_FIELD_DATABASE_URL"
ORG = "cmux"
DATABASE = "cmux-prod"
BRANCH = "main"
# cmux-prod/main's id, the same pin as scripts/cmux-next/release/trees.ts (TREES["cmux-vm"].branchIds.production).
BRANCH_ID = "pj68ww4tuq8x"
PLANETSCALE_PG_HOST_SUFFIX = ".pg.psdb.cloud"
SOURCE = f"hang_reports (org {ORG}, database {DATABASE}, branch {BRANCH})"
PSQL_ENV = "CMUX_FIELD_PSQL"
TABLE = "public.hang_reports"
CHANNELS = ("nightly", "dev", "rc", "release")
HANG_MS = 250
MAX_SINCE_HOURS = 90 * 24
QUERY_TIMEOUT_S = 120
ACTION_CATEGORY = "action"
# Task 031's histogram names (MainTurnHistogram, `debug.hangs` turn_histogram); task 043 sends them as intervals.
TURN_INTERVAL_NAMES = frozenset({"main_turn", "input_queueing"})
PERCENTILES = (("p50", 0.50), ("p95", 0.95), ("p99", 0.99))
NO_ARM = "unrecorded"
# The blocking sites each group reports (most calls first), and the shapes of a `blocking_sites[]` entry
# (wireSchema3.ts BlockingSiteCount).
TOP_BLOCKING_SITES = 10
_BLOCKING_SITE = re.compile(r"^[0-9a-f]{16}$")
_BLOCKING_KIND = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
_NOT_SOURCE_DIRS = frozenset({"node_modules", "target", "build", "DerivedData"})
WRITE_PRIVILEGES = ("INSERT", "UPDATE", "DELETE", "TRUNCATE")
# The child gets these from the parent, then only the PG* values made from the URL.
PASSTHROUGH_ENV = ("PATH", "HOME", "LANG", "LC_ALL", "TMPDIR")


class FieldError(RuntimeError):
    """A field import that cannot run or must not run; the message never carries the credential."""


# --- SQL ----------------------------------------------------------------------------------------------------------

_STRING_LITERAL = re.compile(r"'(?:[^']|'')*'")
_BEGIN = "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY"
_ALLOWED_FRAMING = frozenset({_BEGIN, "ROLLBACK"})
_FORBIDDEN = re.compile(
    r"\b(INSERT|UPDATE|DELETE|MERGE|UPSERT|DROP|ALTER|CREATE|GRANT|REVOKE|TRUNCATE|COPY|CALL|DO|SET|RESET|"
    r"VACUUM|ANALYZE|LOCK|COMMIT|PREPARE|EXECUTE|LISTEN|NOTIFY|INTO)\b|\\", re.IGNORECASE)


def assert_select_only(script: str) -> list[str]:
    """The script's statements; raises FieldError unless each is a SELECT or the read-only BEGIN / ROLLBACK frame.

    String literals are blanked before the scan, so a literal such as 'INSERT' in has_table_privilege is data,
    and a psql meta-command (a backslash anywhere outside a literal) is refused.
    """
    blanked = _STRING_LITERAL.sub("''", script)
    statements = [" ".join(part.split()) for part in blanked.split(";")]
    statements = [statement for statement in statements if statement]
    if not statements:
        raise FieldError("empty query")
    for statement in statements:
        if statement.upper() in _ALLOWED_FRAMING:
            continue
        if not statement.upper().startswith("SELECT "):
            raise FieldError(f"refused a statement that is not a SELECT: {statement[:40]!r}")
        forbidden = _FORBIDDEN.search(statement)
        if forbidden:
            raise FieldError(f"refused a SELECT with {forbidden.group(0)!r}")
    if statements[0].upper() != _BEGIN or statements[-1].upper() != "ROLLBACK":
        raise FieldError(f"the query must run inside {_BEGIN} ... ROLLBACK")
    return statements


def _read_only(*selects: str) -> str:
    return f"{_BEGIN};\n" + "".join(f"{select};\n" for select in selects) + "ROLLBACK;\n"


def privilege_query() -> str:
    """One JSON row: whether the session's role holds each write privilege on hang_reports."""
    pairs = ", ".join(f"'{name.lower()}', has_table_privilege('{TABLE}', '{name}')" for name in WRITE_PRIVILEGES)
    return _read_only(f"SELECT json_build_object({pairs})::text")


_FEATURES_HASH = "COALESCE(payload->>'featuresHash', payload->>'features_hash')"
_FEATURES = "payload->'features'"
# A report without a list (or with another JSON type there) is in no trial.
_FEATURE_ARRAY = f"CASE WHEN jsonb_typeof({_FEATURES}) = 'array' THEN {_FEATURES} ELSE '[]'::jsonb END"
# task 151's `Feature.Source` wire name of a field-trial arm (FeatureFieldState.Entry, wireSchema3.ts FeatureEntry).
TRIAL_SOURCE = "trial"
# The registry name the server accepts (wireSchema3.ts FeatureEntry), then the state.
_FEATURE_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9]{0,63}$")
_TRIAL_TAG = re.compile(r"^[A-Za-z][A-Za-z0-9]{0,63}=(on|off)$")
_TRIAL_STATES = ("on", "off")
FEATURES_SPLIT = "features"
TRIAL_SPLIT = "trial"
_KEY_COLUMNS = ("app_version", "app_build", "chip", "memory_gb")


def reports_query(*, since_hours: int, channel: str) -> str:
    """JSON rows of the window, in one snapshot: kind `report` per report (build, hardware class and the payload
    parts this module counts), kind `installs` per build, hardware and features key (a distinct count), and kind
    `trial_installs` per build, hardware and field-trial arm `feature=on|off` (a distinct count)."""
    if not isinstance(since_hours, int) or not 1 <= since_hours <= MAX_SINCE_HOURS:
        raise FieldError(f"since must be 1 h to {MAX_SINCE_HOURS} h")
    if channel not in CHANNELS:
        raise FieldError(f"channel must be one of {', '.join(CHANNELS)}")
    key = [f"'{column}', {column}" for column in _KEY_COLUMNS] + [f"'features_hash', {_FEATURES_HASH}"]
    report_columns = ", ".join(["'kind', 'report'", *key,
                                "'stall_histogram', payload->'stallHistogram'",
                                "'intervals', payload->'intervals'",
                                f"'features', {_FEATURES}",
                                "'blocking_sites', payload->'blocking_sites'",
                                "'active_seconds', COALESCE(payload->'activeSeconds', payload->'active_seconds')"])
    install_columns = ", ".join(["'kind', 'installs'", *key, "'installs', count(DISTINCT install_id)"])
    trial_name, trial_state = "trials.entry->>'name'", "trials.entry->>'state'"
    trial_columns = ", ".join(["'kind', 'trial_installs'", *key[:len(_KEY_COLUMNS)],
                               f"'trial', ({trial_name}) || '=' || ({trial_state})",
                               "'installs', count(DISTINCT install_id)"])
    where = (f"WHERE received_at >= now() - make_interval(hours => {since_hours}) "
             f"AND channel = '{channel}'")
    trials = f"CROSS JOIN LATERAL jsonb_array_elements({_FEATURE_ARRAY}) AS trials(entry)"
    trial_where = f"{where} AND trials.entry->>'source' = '{TRIAL_SOURCE}'"
    return _read_only(
        f"SELECT json_build_object({report_columns})::text FROM {TABLE} {where} ORDER BY received_at",
        f"SELECT json_build_object({install_columns})::text FROM {TABLE} {where} "
        f"GROUP BY {', '.join(_KEY_COLUMNS)}, {_FEATURES_HASH}",
        f"SELECT json_build_object({trial_columns})::text FROM {TABLE} {trials} {trial_where} "
        f"GROUP BY {', '.join(_KEY_COLUMNS)}, {trial_name}, {trial_state}")


# --- the credential and psql -----------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Credential:
    """A read-only role's connection, as PG* variables; repr hides the password."""
    env: Mapping[str, str] = field(repr=False)
    secrets: tuple[str, ...] = field(repr=False, default=())

    def redact(self, text: str) -> str:
        for secret in self.secrets:
            if secret:
                text = text.replace(secret, "<redacted>")
        return text


def credential_from_url(url: str) -> Credential:
    """PG* variables for psql from a postgres:// URL. TLS is verify-full against the system roots by default."""
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError:
        raise FieldError(f"{URL_ENV} is not a postgres URL") from None
    if parts.scheme not in ("postgres", "postgresql") or not parts.hostname or not parts.username:
        raise FieldError(f"{URL_ENV} is not a postgres URL with a host and a user")
    if not parts.password:
        raise FieldError(f"{URL_ENV} has no password")
    user = unquote(parts.username)
    if not parts.hostname.endswith(PLANETSCALE_PG_HOST_SUFFIX):
        raise FieldError(f"{URL_ENV} is not a PlanetScale Postgres host (*{PLANETSCALE_PG_HOST_SUFFIX}); refusing")
    branch_id = user.rsplit(".", 1)[1] if "." in user else "none"
    if branch_id != BRANCH_ID:
        raise FieldError(f"{URL_ENV} is not for {ORG}/{DATABASE}/{BRANCH} (its user's branch id is {branch_id!r}, "
                         f"want {BRANCH_ID!r}); refusing")
    password = unquote(parts.password)
    query = {key: values[-1] for key, values in parse_qs(parts.query).items() if values}
    env = {
        "PGHOST": parts.hostname,
        "PGPORT": str(port or 5432),
        "PGUSER": user,
        "PGPASSWORD": password,
        "PGDATABASE": unquote(parts.path.lstrip("/")) or "postgres",
        "PGSSLMODE": query.get("sslmode", "verify-full"),
        "PGOPTIONS": "-c default_transaction_read_only=on",
        "PGAPPNAME": "cmux-perf-lab-field",
        "PGCONNECT_TIMEOUT": "15",
    }
    if env["PGSSLMODE"] == "verify-full":
        env["PGSSLROOTCERT"] = query.get("sslrootcert", "system")
    return Credential(env=env, secrets=tuple(sorted({password, parts.password, url}, key=len, reverse=True)))


def credential_from_environment(environ: Mapping[str, str]) -> Credential:
    url = environ.get(URL_ENV, "").strip()
    if not url:
        raise FieldError(f"no credential: set {URL_ENV} to a read-only role's connection URL "
                         "(pscale role create cmux-prod main field-ro --org cmux --inherited-roles pg_read_all_data)")
    return credential_from_url(url)


# Runs psql: argv, the child environment and the script on stdin; returns (exit code, stdout, stderr).
PsqlRunner = Callable[[Sequence[str], Mapping[str, str], str], tuple[int, str, str]]


def subprocess_runner(argv: Sequence[str], env: Mapping[str, str], script: str) -> tuple[int, str, str]:
    try:
        done = subprocess.run(list(argv), input=script, env=dict(env), capture_output=True, text=True,
                              timeout=QUERY_TIMEOUT_S, check=False)
    except subprocess.TimeoutExpired:
        return 124, "", f"psql timed out after {QUERY_TIMEOUT_S} s"
    except OSError as error:
        return 127, "", f"psql did not start: {error.strerror or error}"
    return done.returncode, done.stdout, done.stderr


def psql_argv(environ: Mapping[str, str]) -> list[str]:
    """psql with no connection argument (it reads PG* variables), no psqlrc, tuples only, script on stdin."""
    binary = environ.get(PSQL_ENV) or shutil.which("psql") or "psql"
    return [binary, "--no-psqlrc", "--quiet", "--no-align", "--tuples-only", "--set", "ON_ERROR_STOP=1",
            "--file", "-"]


def child_env(credential: Credential, environ: Mapping[str, str]) -> dict[str, str]:
    env = {name: environ[name] for name in PASSTHROUGH_ENV if name in environ}
    env.update(credential.env)
    return env


def run_select(script: str, credential: Credential, *, runner: PsqlRunner = subprocess_runner,
               environ: Mapping[str, str] | None = None) -> list[dict[str, Any]]:
    """The script's rows, one JSON object per output line; raises FieldError (redacted) on any failure."""
    assert_select_only(script)
    environ = os.environ if environ is None else environ
    code, stdout, stderr = runner(psql_argv(environ), child_env(credential, environ), script)
    if code != 0:
        detail = credential.redact((stderr or stdout).strip())[:400]
        raise FieldError(f"psql exited {code}: {detail}")
    return parse_rows(stdout)


def parse_rows(text: str) -> list[dict[str, Any]]:
    rows = []
    for number, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            raise FieldError(f"row {number} is not JSON") from None
        if not isinstance(row, dict):
            raise FieldError(f"row {number} is not a JSON object")
        rows.append(row)
    return rows


def check_read_only(credential: Credential, *, runner: PsqlRunner = subprocess_runner,
                    environ: Mapping[str, str] | None = None) -> None:
    rows = run_select(privilege_query(), credential, runner=runner, environ=environ)
    if len(rows) != 1:
        raise FieldError("the privilege check returned no row")
    held = [name for name in WRITE_PRIVILEGES if rows[0].get(name.lower()) is not False]
    if held:
        raise FieldError(f"refused: the role can {', '.join(held)} {TABLE}; use a read-only role")


def fetch_reports(*, since_hours: int, channel: str, credential: Credential,
                  runner: PsqlRunner = subprocess_runner, environ: Mapping[str, str] | None = None) -> list[dict]:
    check_read_only(credential, runner=runner, environ=environ)
    return run_select(reports_query(since_hours=since_hours, channel=channel), credential, runner=runner,
                      environ=environ)


# --- aggregation ----------------------------------------------------------------------------------------------------

def _count(value: object) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else 0


def _buckets(value: object) -> list[tuple[int, int, int]]:
    """(lowMs, highMs, count) of a wire histogram; a malformed bucket is skipped, never guessed."""
    out = []
    for bucket in value if isinstance(value, list) else []:
        if not isinstance(bucket, Mapping):
            continue
        low, high, count = bucket.get("lowMs"), bucket.get("highMs"), _count(bucket.get("count"))
        if isinstance(low, int) and isinstance(high, int) and 0 <= low <= high and count:
            out.append((low, high, count))
    return out


def merge(histogram: dict[tuple[int, int], int], buckets: Iterable[tuple[int, int, int]]) -> None:
    for low, high, count in buckets:
        histogram[(low, high)] = histogram.get((low, high), 0) + count


def disjoint(histogram: Mapping[tuple[int, int], int]) -> list[tuple[int, int, float]]:
    """The histogram on the union of its edges: each bucket's count is shared out over the union intervals it
    covers, in proportion to their width, so no two buckets overlap. A zero-width bucket stays a point.

    MetricKit's bucket ranges differ across reports and OS versions, and Chrome never merges histograms whose
    bucket ranges differ (base/metrics/histogram.cc, HasConstructionArguments); rebucketing onto shared edges
    keeps every quantile monotone in q.
    """
    edges = sorted({edge for low_high in histogram for edge in low_high})
    shares: dict[tuple[int, int], float] = {}
    for (low, high), count in histogram.items():
        if low == high:
            shares[(low, low)] = shares.get((low, low), 0.0) + count
            continue
        start, end = bisect.bisect_left(edges, low), bisect.bisect_left(edges, high)
        for left, right in zip(edges[start:end], edges[start + 1:end + 1]):
            shares[(left, right)] = shares.get((left, right), 0.0) + count * (right - left) / (high - low)
    return [(low, high, share) for (low, high), share in sorted(shares.items()) if share > 0]


def percentile(histogram: Mapping[tuple[int, int], int], q: float) -> float | None:
    """The q-quantile of the disjoint histogram, interpolated inside the rank's bucket (as task 031's
    MainTurnHistogram); None when empty."""
    buckets = disjoint(histogram)
    total = sum(share for _, _, share in buckets)
    if total <= 0:
        return None
    rank = q * total
    seen = 0.0
    for low, high, share in buckets:
        if seen + share >= rank:
            return low + (high - low) * max(0.0, rank - seen) / share
        seen += share
    return float(buckets[-1][1])


def hardware_class(chip: object, memory_gb: object) -> str:
    """The lab host class without the display Hz (store.host_class's first two parts), so rows line up."""
    chip_text = chip.strip().lower().replace(" ", "-") if isinstance(chip, str) and chip.strip() else "unknown"
    memory = f"{memory_gb}gb" if isinstance(memory_gb, int) and memory_gb > 0 else "unknown"
    return f"{chip_text}/{memory}"


def build_label(version: object, build: object) -> str:
    version_text = version if isinstance(version, str) and version else "unknown"
    return f"{version_text} ({build})" if isinstance(build, str) and build else version_text


@dataclass
class Group:
    build: str
    hardware_class: str
    arm: str
    # FEATURES_SPLIT: `arm` is the features hash (or NO_ARM). TRIAL_SPLIT: `arm` is one `feature=on|off` arm.
    split: str = FEATURES_SPLIT
    reports: int = 0
    installs: int = 0
    hangs_over_250ms: int = 0
    timed_reports: int = 0
    timed_hangs_over_250ms: int = 0
    active_seconds: float = 0.0
    action: dict[str, dict[tuple[int, int], int]] = field(default_factory=dict)
    turn: dict[str, dict[tuple[int, int], int]] = field(default_factory=dict)
    # (site id, kind) -> [calls, total ms, reports that named it]
    blocking: dict[tuple[str, str], list[int]] = field(default_factory=dict)

    def top_blocking_sites(self) -> list[tuple[str, str, int, int, int]]:
        """(site, kind, calls, total ms, reports) of the sites with the most calls, at most TOP_BLOCKING_SITES."""
        ranked = sorted(self.blocking.items(), key=lambda item: (-item[1][0], -item[1][1], item[0]))
        return [(site, kind, calls, total, reports) for (site, kind), (calls, total, reports)
                in ranked[:TOP_BLOCKING_SITES]]

    @property
    def active_hours(self) -> float:
        return self.active_seconds / 3600

    @property
    def hangs_per_1000_active_hours(self) -> float | None:
        if self.active_seconds <= 0:
            return None
        return self.timed_hangs_over_250ms / self.active_hours * 1000


def _active_seconds(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(value) and value > 0 else None


def trial_tags(features: object) -> list[str]:
    """The distinct `feature=on|off` arms of a report's `features[]` entries of source `trial`, sorted; any other
    entry, and a malformed one, is skipped."""
    tags = set()
    for entry in features if isinstance(features, list) else ():
        if not isinstance(entry, Mapping) or entry.get("source") != TRIAL_SOURCE:
            continue
        name, state = entry.get("name"), entry.get("state")
        if isinstance(name, str) and _FEATURE_NAME.match(name) and state in _TRIAL_STATES:
            tags.add(f"{name}={state}")
    return sorted(tags)


def aggregate(rows: Iterable[Mapping[str, Any]]) -> list[Group]:
    """Groups by (build, hardware class, features arm), then by (build, hardware class, field-trial arm), in that
    order. A row of kind `installs` adds its distinct count to a features group and one of kind `trial_installs`
    to a trial group; any other row is one report, counted in its features group and in each of its trial groups.
    One Mac sends one chip and memory value, so the raw keys that land in a group never share an install and their
    counts add."""
    groups: dict[tuple[str, str, str, str], Group] = {}

    def group_of(row: Mapping[str, Any], split: str, arm: str) -> Group:
        build, hardware = build_label(row.get("app_version"), row.get("app_build")), \
            hardware_class(row.get("chip"), row.get("memory_gb"))
        key = (split, build, hardware, arm)
        group = groups.get(key)
        if group is None:
            group = groups[key] = Group(build, hardware, arm, split)
        return group

    for row in rows:
        if row.get("kind") == "trial_installs":
            tag = row.get("trial")
            if isinstance(tag, str) and _TRIAL_TAG.match(tag):
                group_of(row, TRIAL_SPLIT, tag).installs += _count(row.get("installs"))
            continue
        arm = row.get("features_hash") if isinstance(row.get("features_hash"), str) and row.get("features_hash") \
            else NO_ARM
        group = group_of(row, FEATURES_SPLIT, arm)
        if row.get("kind") == "installs":
            group.installs += _count(row.get("installs"))
            continue
        for target in [group, *(group_of(row, TRIAL_SPLIT, tag) for tag in trial_tags(row.get("features")))]:
            add_report(target, row)
    return [groups[key] for key in sorted(groups)]


def add_report(group: Group, row: Mapping[str, Any]) -> None:
    """Counts one report row into `group`."""
    group.reports += 1
    hangs = sum(count for low, _, count in _buckets(row.get("stall_histogram")) if low >= HANG_MS)
    group.hangs_over_250ms += hangs
    active = _active_seconds(row.get("active_seconds"))
    if active is not None:
        group.timed_reports += 1
        group.timed_hangs_over_250ms += hangs
        group.active_seconds += active
    for interval in row.get("intervals") if isinstance(row.get("intervals"), list) else []:
        if not isinstance(interval, Mapping) or not isinstance(interval.get("name"), str):
            continue
        name = interval["name"]
        if name in TURN_INTERVAL_NAMES:
            target = group.turn
        elif interval.get("category") == ACTION_CATEGORY:
            target = group.action
        else:
            continue
        merge(target.setdefault(name, {}), _buckets(interval.get("buckets")))
    for site, kind, calls, total_ms in blocking_sites(row.get("blocking_sites")):
        counts = group.blocking.setdefault((site, kind), [0, 0, 0])
        counts[0] += calls
        counts[1] += total_ms
        counts[2] += 1


def blocking_sites(value: object) -> list[tuple[str, str, int, int]]:
    """(site, kind, calls, total ms) of a report's `blocking_sites[]`, one per site; a malformed entry is skipped."""
    found: dict[tuple[str, str], tuple[int, int]] = {}
    for entry in value if isinstance(value, list) else ():
        if not isinstance(entry, Mapping):
            continue
        site, kind = entry.get("site"), entry.get("kind")
        if not (isinstance(site, str) and _BLOCKING_SITE.match(site) and isinstance(kind, str)
                and _BLOCKING_KIND.match(kind)):
            continue
        calls, total = _count(entry.get("count")), _count(entry.get("total_ms"))
        if calls > 0:
            before = found.get((site, kind), (0, 0))
            found[(site, kind)] = (before[0] + calls, before[1] + total)
    return [(site, kind, calls, total) for (site, kind), (calls, total) in found.items()]


def site_id(location: str) -> str:
    """The client's `HangReport.BlockingSiteCount.siteID`: SHA-256 of `Module/File.swift:line`, first 8 bytes."""
    return hashlib.sha256(location.encode("utf-8")).digest()[:8].hex()


def site_locations(root: Path, wanted: Iterable[str]) -> dict[str, str]:
    """The `Module/File.swift:line` of each wanted site id found in the Swift sources under `root`
    (`<package>/Sources/<Module>/.../<File>.swift`, whose `#fileID` is `Module/File.swift`)."""
    wanted = set(wanted)
    found: dict[str, str] = {}
    if not wanted:
        return found
    for directory, subdirectories, files in os.walk(root):
        # Hidden folders (other worktrees, caches) and dependency trees hold no cmux source.
        subdirectories[:] = sorted(name for name in subdirectories
                                   if not name.startswith(".") and name not in _NOT_SOURCE_DIRS)
        parts = Path(directory).relative_to(root).parts
        if "Sources" not in parts[:-1]:
            continue
        module = parts[parts.index("Sources") + 1]
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            try:
                lines = (Path(directory) / name).read_bytes().count(b"\n") + 1
            except OSError:
                continue
            for line in range(1, lines + 1):
                location = f"{module}/{name}:{line}"
                identifier = site_id(location)
                if identifier in wanted:
                    found[identifier] = location
            if len(found) == len(wanted):
                return found
    return found


def field_rows(groups: Sequence[Group]) -> list[dict[str, Any]]:
    """dashboard.FieldRow-shaped rows (build, hardware_class, metric, value, unit, samples, arm)."""
    rows = []

    def add(group: Group, metric: str, value: float | None, unit: str, samples: int) -> None:
        rows.append({"build": group.build, "hardware_class": group.hardware_class, "metric": metric,
                     "value": None if value is None else round(value, 4), "unit": unit, "samples": samples,
                     "arm": group.arm})

    for group in groups:
        add(group, "reports", group.reports, "count", group.reports)
        add(group, "installs", group.installs, "count", group.reports)
        add(group, "hangs_over_250ms", group.hangs_over_250ms, "count", group.reports)
        add(group, "active_hours", group.active_hours if group.timed_reports else None, "h", group.timed_reports)
        add(group, "hangs_over_250ms_per_1000_active_hours", group.hangs_per_1000_active_hours, "per 1000 h",
            group.timed_reports)
        for prefix, histograms in (("action", group.action), ("turn", group.turn)):
            for name, histogram in sorted(histograms.items()):
                samples = sum(histogram.values())
                for label, q in PERCENTILES:
                    add(group, f"{prefix}.{name}.{label}", percentile(histogram, q), "ms", samples)
        for site, kind, calls, total, reports in group.top_blocking_sites():
            add(group, f"blocking_site.{site}.{kind}", calls, "calls", reports)
            add(group, f"blocking_site.{site}.{kind}.total_ms", total, "ms", reports)
    return rows


def report(groups: Sequence[Group], *, since_hours: int | None, channel: str, source: str,
           locations: Mapping[str, str] | None = None) -> dict[str, Any]:
    """The JSON result; `locations` names blocking site ids (site_locations), else each `location` is null."""
    locations = locations or {}

    def histograms(entries: Mapping[str, Mapping[tuple[int, int], int]]) -> dict[str, list[dict[str, int]]]:
        return {name: [{"lowMs": low, "highMs": high, "count": count} for (low, high), count in sorted(h.items())]
                for name, h in sorted(entries.items())}

    return {
        "source": source,
        "channel": channel,
        "since_hours": since_hours,
        # Each report is in exactly one features group; the trial groups count it again.
        "reports": sum(group.reports for group in groups if group.split == FEATURES_SPLIT),
        "groups": [{
            "build": group.build, "hardware_class": group.hardware_class, "arm": group.arm, "split": group.split,
            "reports": group.reports, "installs": group.installs,
            "hangs_over_250ms": group.hangs_over_250ms, "timed_reports": group.timed_reports,
            "active_hours": round(group.active_hours, 4) if group.timed_reports else None,
            "hangs_over_250ms_per_1000_active_hours": (None if group.hangs_per_1000_active_hours is None
                                                       else round(group.hangs_per_1000_active_hours, 4)),
            "action_histograms": histograms(group.action), "turn_histograms": histograms(group.turn),
            "blocking_sites": [{"site": site, "kind": kind, "calls": calls, "total_ms": total, "reports": reports,
                                "location": locations.get(site)}
                               for site, kind, calls, total, reports in group.top_blocking_sites()],
        } for group in groups],
        "rows": field_rows(groups),
    }


# --- the command ------------------------------------------------------------------------------------------------------

_SINCE = re.compile(r"^([1-9][0-9]{0,4})([dh])$")


def parse_since(text: str) -> int:
    """`7d` or `48h` as hours."""
    match = _SINCE.match(text.strip())
    if not match:
        raise FieldError(f"--since must look like 7d or 48h, not {text!r}")
    hours = int(match.group(1)) * (24 if match.group(2) == "d" else 1)
    if hours > MAX_SINCE_HOURS:
        raise FieldError(f"--since is at most {MAX_SINCE_HOURS // 24}d")
    return hours


REPORT_MODE = 0o644


def write_atomically(path: Path, text: str) -> None:
    """Replaces `path` with `text`, mode 0644 (aggregates only; the dashboard may run as another user). A failed
    write leaves no temporary file behind."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.",
                                         delete=False)
    temporary = Path(handle.name)
    try:
        with handle:
            handle.write(text)
        os.chmod(temporary, REPORT_MODE)
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def render_text(result: Mapping[str, Any]) -> str:
    lines = [f"field: {result['reports']} {result['channel']} reports"
             + (f" in the last {result['since_hours']} h" if result.get("since_hours") else "")
             + f" ({result['source']})"]
    for group in result["groups"]:
        rate = group["hangs_over_250ms_per_1000_active_hours"]
        label = "trial" if group["split"] == TRIAL_SPLIT else "arm"
        lines.append(f"  {group['build']}  {group['hardware_class']}  {label} {group['arm']}: "
                     f"{group['reports']} reports, {group['installs']} installs, "
                     f"{group['hangs_over_250ms']} hangs > {HANG_MS} ms, "
                     + (f"{rate:.1f} per 1000 active hours" if rate is not None else "no active time reported"))
    for row in result["rows"]:
        if row["metric"].startswith(("action.", "turn.")) and row["value"] is not None:
            lines.append(f"    {row['build']}  {row['hardware_class']}  {row['metric']}: "
                         f"{row['value']:.1f} ms (n={row['samples']})")
    for group in result["groups"]:
        for site in group.get("blocking_sites", []):
            lines.append(f"    {group['build']}  {group['hardware_class']}  blocking {site['location'] or site['site']} "
                         f"{site['kind']}: {site['calls']} calls, {site['total_ms']} ms (n={site['reports']})")
    return "\n".join(lines)


def field_command(args: argparse.Namespace, *, runner: PsqlRunner = subprocess_runner,
                  environ: Mapping[str, str] | None = None, out: Any = None) -> int:
    environ = os.environ if environ is None else environ
    out = sys.stdout if out is None else out
    if args.fixture:
        try:
            rows = parse_rows(Path(args.fixture).read_text(encoding="utf-8"))
        except OSError as error:
            raise FieldError(f"cannot read the fixture: {error.strerror or error}") from None
        except UnicodeDecodeError as error:
            raise FieldError(f"the fixture is not UTF-8 (byte {error.start})") from None
        groups = aggregate(rows)
        result = report(groups, since_hours=None, channel=args.channel, source="fixture",
                        locations=_locations(args, groups))
    else:
        since_hours = parse_since(args.since)
        credential = credential_from_environment(environ)
        rows = fetch_reports(since_hours=since_hours, channel=args.channel, credential=credential, runner=runner,
                             environ=environ)
        groups = aggregate(rows)
        result = report(groups, since_hours=since_hours, channel=args.channel, source=SOURCE,
                        locations=_locations(args, groups))
    text = json.dumps(result, indent=2, sort_keys=True)
    if args.out:
        try:
            write_atomically(Path(args.out), text + "\n")
        except OSError as error:
            raise FieldError(f"cannot write --out: {error.strerror or error}") from None
    print(text if args.json else render_text(result), file=out)
    return 0


def _locations(args: argparse.Namespace, groups: Sequence[Group]) -> dict[str, str]:
    """The blocking site ids of `groups` named from `--sites-from`, when given."""
    root = getattr(args, "sites_from", None)
    if not root:
        return {}
    if not Path(root).is_dir():
        raise FieldError(f"--sites-from is not a directory: {root}")
    return site_locations(Path(root), {site for group in groups for site, *_ in group.top_blocking_sites()})


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--since", default="7d", help="the window, as Nd or Nh (default 7d)")
    parser.add_argument("--channel", default="nightly", choices=CHANNELS, help="the report channel (default nightly)")
    parser.add_argument("--fixture", metavar="JSONL", help="aggregate these rows (one JSON object per line) "
                                                           "instead of reading hang_reports")
    parser.add_argument("--out", metavar="PATH", help="also write the JSON report here (atomic replace)")
    parser.add_argument("--json", action="store_true", help="print JSON")
    parser.add_argument("--sites-from", metavar="CHECKOUT", help="name each blocking site id by hashing every line "
                                                                 "of this checkout's Swift sources")


def run(command: str, args: argparse.Namespace) -> int:
    """lab.py's command hook: `lab.py field`; a typed error exits 2."""
    try:
        return field_command(args)
    except FieldError as error:
        print(f"lab.py {command}: {error}", file=sys.stderr)
        return 2


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="field.py", description=LAB_COMMANDS["field"])
    add_arguments("field", parser)
    return run("field", parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
