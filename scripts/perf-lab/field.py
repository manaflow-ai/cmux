#!/usr/bin/env python3
"""Field import of opt-in Nightly hang reports (p12-perf-process-042, p12-perf-process.md 3.10).

    CMUX_FIELD_DATABASE_URL=... python3 -I scripts/perf-lab/lab.py field --since 7d [--json] [--out PATH]
    python3 -I scripts/perf-lab/lab.py field --fixture rows.jsonl --json

Chrome reports field performance as UMA histograms per channel, version and hardware class, beside the lab
(docs/speed/how_does_chrome_measure_performance.md), and normalizes hang counts by the time the thread was
watched (base/threading/hang_watcher.h; HangWatcher.IsThreadHung.* is logged per watched interval). This
module does the same with the PlanetScale `cmux-prod` table `hang_reports` (branch `main`, org `cmux`). Per
Nightly build, hardware class and features arm it reports:

- hangs > 250 ms per 1000 active hours: the watchdog's stall histogram (StallAggregate, every finished stall
  of 50 ms and up; its 250 ms edge splits the count exactly) over the reports that carry active seconds
  (task 043). A group with no active time has no rate, never a guessed one.
- action-latency histograms: the merged `action` signpost intervals, with interpolated p50, p95 and p99.
- turn histograms when present: the `main_turn` and `input_queueing` intervals (task 031's histograms,
  sent by task 043 as interval entries).

Rules (R10): SELECT only, counts only. Every query runs in `BEGIN TRANSACTION READ ONLY` with
`default_transaction_read_only=on`, and `assert_select_only` refuses any other statement before psql starts.
The import first checks that its role cannot write `hang_reports` and stops if it can. The credential is the
connection URL of a read-only role, read from the environment variable CMUX_FIELD_DATABASE_URL. It reaches
psql only as PG* environment variables of the child process, never in argv, and is redacted from every error.
The operator makes the role once, with no write grant:

    pscale role create cmux-prod main field-ro --org cmux --inherited-roles pg_read_all_data

The SELECT reads no frames, install ids leave the query only as a count, and the output is aggregates.
Field rows are reported on the dashboard (/field) and in done check 18; they are never judged.
"""
from __future__ import annotations

import argparse
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
WRITE_PRIVILEGES = ("INSERT", "UPDATE", "DELETE", "TRUNCATE")
# The child gets these from the parent, then only the PG* values made from the URL.
PASSTHROUGH_ENV = ("PATH", "HOME", "LANG", "LC_ALL", "TMPDIR")


class FieldError(RuntimeError):
    """A field import that cannot run or must not run; the message never carries the credential."""


# --- SQL ----------------------------------------------------------------------------------------------------------

_STRING_LITERAL = re.compile(r"'(?:[^']|'')*'")
_ALLOWED_FRAMING = frozenset({"BEGIN TRANSACTION READ ONLY", "ROLLBACK"})
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
    if statements[0].upper() != "BEGIN TRANSACTION READ ONLY" or statements[-1].upper() != "ROLLBACK":
        raise FieldError("the query must run inside BEGIN TRANSACTION READ ONLY ... ROLLBACK")
    return statements


def _read_only(*selects: str) -> str:
    return "BEGIN TRANSACTION READ ONLY;\n" + "".join(f"{select};\n" for select in selects) + "ROLLBACK;\n"


def privilege_query() -> str:
    """One JSON row: whether the session's role holds each write privilege on hang_reports."""
    pairs = ", ".join(f"'{name.lower()}', has_table_privilege('{TABLE}', '{name}')" for name in WRITE_PRIVILEGES)
    return _read_only(f"SELECT json_build_object({pairs})::text")


def reports_query(*, since_hours: int, channel: str) -> str:
    """One JSON row per report in the window: build, hardware class, and the payload parts this module counts."""
    if not isinstance(since_hours, int) or not 1 <= since_hours <= MAX_SINCE_HOURS:
        raise FieldError(f"since must be 1 h to {MAX_SINCE_HOURS} h")
    if channel not in CHANNELS:
        raise FieldError(f"channel must be one of {', '.join(CHANNELS)}")
    columns = ", ".join([
        "'app_version', app_version", "'app_build', app_build", "'chip', chip", "'memory_gb', memory_gb",
        "'install', md5(install_id::text)",
        "'stall_histogram', payload->'stallHistogram'",
        "'intervals', payload->'intervals'",
        "'active_seconds', COALESCE(payload->'activeSeconds', payload->'active_seconds')",
        "'features_hash', COALESCE(payload->>'featuresHash', payload->>'features_hash')",
    ])
    return _read_only(
        f"SELECT json_build_object({columns})::text FROM {TABLE} "
        f"WHERE received_at >= now() - make_interval(hours => {since_hours}) AND channel = '{channel}' "
        "ORDER BY received_at")


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
    password = unquote(parts.password)
    query = {key: values[-1] for key, values in parse_qs(parts.query).items() if values}
    env = {
        "PGHOST": parts.hostname,
        "PGPORT": str(port or 5432),
        "PGUSER": unquote(parts.username),
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


def percentile(histogram: Mapping[tuple[int, int], int], q: float) -> float | None:
    """The q-quantile, interpolated inside the rank's bucket (as task 031's MainTurnHistogram); None when empty.

    Bucket edges from different reports may overlap; buckets are walked in (low, high) order, which is exact for
    the shared edge sets the client sends.
    """
    total = sum(histogram.values())
    if total <= 0:
        return None
    rank = q * total
    seen = 0
    for (low, high), count in sorted(histogram.items()):
        if seen + count >= rank:
            return low + (high - low) * max(0.0, rank - seen) / count
        seen += count
    return float(max(histogram)[1])


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
    reports: int = 0
    installs: set[str] = field(default_factory=set)
    hangs_over_250ms: int = 0
    timed_reports: int = 0
    timed_hangs_over_250ms: int = 0
    active_seconds: float = 0.0
    action: dict[str, dict[tuple[int, int], int]] = field(default_factory=dict)
    turn: dict[str, dict[tuple[int, int], int]] = field(default_factory=dict)

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


def aggregate(rows: Iterable[Mapping[str, Any]]) -> list[Group]:
    """Groups by (build, hardware class, features arm), in that order."""
    groups: dict[tuple[str, str, str], Group] = {}
    for row in rows:
        arm = row.get("features_hash") if isinstance(row.get("features_hash"), str) and row.get("features_hash") \
            else NO_ARM
        key = (build_label(row.get("app_version"), row.get("app_build")),
               hardware_class(row.get("chip"), row.get("memory_gb")), arm)
        group = groups.get(key)
        if group is None:
            group = groups[key] = Group(*key)
        group.reports += 1
        if isinstance(row.get("install"), str):
            group.installs.add(row["install"])
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
    return [groups[key] for key in sorted(groups)]


def field_rows(groups: Sequence[Group]) -> list[dict[str, Any]]:
    """dashboard.FieldRow-shaped rows (build, hardware_class, metric, value, unit, samples, arm)."""
    rows = []

    def add(group: Group, metric: str, value: float | None, unit: str, samples: int) -> None:
        rows.append({"build": group.build, "hardware_class": group.hardware_class, "metric": metric,
                     "value": None if value is None else round(value, 4), "unit": unit, "samples": samples,
                     "arm": group.arm})

    for group in groups:
        add(group, "reports", group.reports, "count", group.reports)
        add(group, "installs", len(group.installs), "count", group.reports)
        add(group, "hangs_over_250ms", group.hangs_over_250ms, "count", group.reports)
        add(group, "active_hours", group.active_hours if group.timed_reports else None, "h", group.timed_reports)
        add(group, "hangs_over_250ms_per_1000_active_hours", group.hangs_per_1000_active_hours, "per 1000 h",
            group.timed_reports)
        for prefix, histograms in (("action", group.action), ("turn", group.turn)):
            for name, histogram in sorted(histograms.items()):
                samples = sum(histogram.values())
                for label, q in PERCENTILES:
                    add(group, f"{prefix}.{name}.{label}", percentile(histogram, q), "ms", samples)
    return rows


def report(groups: Sequence[Group], *, since_hours: int | None, channel: str, source: str) -> dict[str, Any]:
    def histograms(entries: Mapping[str, Mapping[tuple[int, int], int]]) -> dict[str, list[dict[str, int]]]:
        return {name: [{"lowMs": low, "highMs": high, "count": count} for (low, high), count in sorted(h.items())]
                for name, h in sorted(entries.items())}

    return {
        "source": source,
        "channel": channel,
        "since_hours": since_hours,
        "reports": sum(group.reports for group in groups),
        "groups": [{
            "build": group.build, "hardware_class": group.hardware_class, "arm": group.arm,
            "reports": group.reports, "installs": len(group.installs),
            "hangs_over_250ms": group.hangs_over_250ms, "timed_reports": group.timed_reports,
            "active_hours": round(group.active_hours, 4) if group.timed_reports else None,
            "hangs_over_250ms_per_1000_active_hours": (None if group.hangs_per_1000_active_hours is None
                                                       else round(group.hangs_per_1000_active_hours, 4)),
            "action_histograms": histograms(group.action), "turn_histograms": histograms(group.turn),
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


def write_atomically(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.",
                                     delete=False) as handle:
        handle.write(text)
        temporary = Path(handle.name)
    os.replace(temporary, path)


def render_text(result: Mapping[str, Any]) -> str:
    lines = [f"field: {result['reports']} {result['channel']} reports"
             + (f" in the last {result['since_hours']} h" if result.get("since_hours") else "")
             + f" ({result['source']})"]
    for group in result["groups"]:
        rate = group["hangs_over_250ms_per_1000_active_hours"]
        lines.append(f"  {group['build']}  {group['hardware_class']}  arm {group['arm']}: "
                     f"{group['reports']} reports, {group['installs']} installs, "
                     f"{group['hangs_over_250ms']} hangs > {HANG_MS} ms, "
                     + (f"{rate:.1f} per 1000 active hours" if rate is not None else "no active time reported"))
    for row in result["rows"]:
        if row["metric"].startswith(("action.", "turn.")) and row["value"] is not None:
            lines.append(f"    {row['build']}  {row['hardware_class']}  {row['metric']}: "
                         f"{row['value']:.1f} ms (n={row['samples']})")
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
        result = report(aggregate(rows), since_hours=None, channel=args.channel, source="fixture")
    else:
        since_hours = parse_since(args.since)
        credential = credential_from_environment(environ)
        rows = fetch_reports(since_hours=since_hours, channel=args.channel, credential=credential, runner=runner,
                             environ=environ)
        result = report(aggregate(rows), since_hours=since_hours, channel=args.channel, source="hang_reports")
    text = json.dumps(result, indent=2, sort_keys=True)
    if args.out:
        write_atomically(Path(args.out), text + "\n")
    print(text if args.json else render_text(result), file=out)
    return 0


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--since", default="7d", help="the window, as Nd or Nh (default 7d)")
    parser.add_argument("--channel", default="nightly", choices=CHANNELS, help="the report channel (default nightly)")
    parser.add_argument("--fixture", metavar="JSONL", help="aggregate these rows (one JSON object per line) "
                                                           "instead of reading hang_reports")
    parser.add_argument("--out", metavar="PATH", help="also write the JSON report here (atomic replace)")
    parser.add_argument("--json", action="store_true", help="print JSON")


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
