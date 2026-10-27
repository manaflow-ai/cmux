#!/usr/bin/env python3
"""Traces with every T0, bisect, verify and try attempt (p12-perf-process.md 3.6, task 157).

Chromium's lab keeps a trace of every measured story run: TBMv2 metrics are computed from the trace that
Telemetry records for each run (catapult `tracing/tracing/metrics/`), and Pinpoint links each execution's trace
from the job page (catapult `dashboard/dashboard/pinpoint/models/quest/read_value.py`, the execution's `trace`
details). The cmux lab does the same with the cheap sources of `scripts/cmux-next/trace.py`, never xctrace:

  signpost   `log stream --signpost` of com.cmuxterm.app.next  -> signposts.ndjson
  watchdog   the app's main-thread watchdog ring (`debug.hangs`) -> hangs.json
  daemon     CMUX_TUI_DEBUG_SPANS lines, stamped on arrival    -> daemon-spans-stamped.jsonl

Every attempt is recorded the same way, so tracing never makes one attempt slower than another. After a story
run (or a Pinpoint Change, or a try arm) the first attempt and the median attempt are kept: each source file is
gzipped (mtime 0) and stored in R2 by the sha256 of the stored bytes, and the rest are deleted. The digests go
into the run's result-v1 attachments as `trace-<source>-<attempt>` (an attachment has only digest and kind).
Downloading the files of one attempt into a directory under their trace.py names lets `trace.py export DIR`
rebuild the Perfetto timeline.

After ingest, `index` turns those attachments into `traces` rows of the lab store, which link a trace to its
series point (the run), its Change (job + build sha), its alert group (job.alert_group_id) and from there the
issue (`links`). `expire` deletes rows older than 30 days that nothing references, then R2 objects older than
30 days that no live row and no kept run's attachments name (also uploads whose ingest never happened). A run is
kept while it is younger than 30 days or referenced, indexed or not. Referenced: a run or trace of a job that
belongs to an alert group (bisect, verify), or a waterfall point inside an alert's range or the point just before it.

  lab.py runs --since 1h [--kind K] [--json]         stored runs with their trace digests (indexed or not)
  lab.py traces publish DIR --attempt N              upload one recorded attempt directory, print its attachments
  lab.py traces index --run UUID                     traces rows from a stored run's trace attachments (exit 1
                                                     when one is not in R2; the others are still indexed)
  lab.py traces coverage --since 1h                  T0 points, bisect Changes and verified culprits with no trace,
                                                     and runs whose trace attachments are not indexed yet
  lab.py traces links --group N                      the group's trace links, as issue Markdown
  lab.py traces expire [--dry-run]                   the 30-day retention sweep

The store is --db or $CMUX_PERF_LAB_DB. `trace_quest.py runs|publish|index|coverage|links|expire ...` runs the
same commands without lab.py.

R2 (publish, expire): CMUX_PERF_LAB_R2_ACCOUNT_ID, CMUX_PERF_LAB_R2_ACCESS_KEY_ID,
CMUX_PERF_LAB_R2_SECRET_ACCESS_KEY, CMUX_PERF_LAB_R2_BUCKET (default cmux-perf-lab) and
CMUX_PERF_LAB_R2_PUBLIC_URL (the link base; without it a link is r2://BUCKET/KEY).

Run: python3 -m unittest scripts/perf-lab/tests/test_trace_quest.py. Not a CI gate.
"""
from __future__ import annotations

import argparse
import contextlib
import dataclasses
import gzip
import hashlib
import hmac
import http.client
import importlib.util
import json
import os
import re
import shutil
import sqlite3
import sys
import urllib.parse
import xml.etree.ElementTree as ET
from collections.abc import Callable, Iterable, Iterator, Mapping, Sequence
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Protocol

HERE = Path(__file__).resolve().parent
TRACE_PY = HERE.parent / "cmux-next" / "trace.py"
# The store's traces.kind values, each with the file name trace.py's export reads.
SOURCES = {"signpost": "signposts.ndjson", "watchdog": "hangs.json", "daemon": "daemon-spans-stamped.jsonl"}
ATTACHMENT_KIND = re.compile(r"^trace-(signpost|watchdog|daemon)-([0-9]+)$")
DIGEST = re.compile(r"^sha256:([0-9a-f]{64})$")
PREFIX = "perf-lab/traces/sha256/"
RETENTION = timedelta(days=30)


class TraceQuestError(RuntimeError):
    pass


def stamp(moment: datetime) -> str:
    """The lab store's stamp format (store.py): fixed-width UTC ISO-8601, ordered as text."""
    if moment.tzinfo is None:
        raise TraceQuestError(f"{moment.isoformat()}: a stored time needs a timezone")
    return moment.astimezone(timezone.utc).isoformat(timespec="microseconds")


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


# ---------------------------------------------------------------- blob store

class BlobStore(Protocol):
    def put(self, key: str, data: bytes, content_type: str) -> None: ...
    def delete(self, key: str) -> None: ...
    def size(self, key: str) -> int | None: ...
    def list(self, prefix: str) -> Iterable[tuple[str, datetime]]: ...
    def url_for(self, key: str) -> str: ...


def blob_key(digest: str) -> str:
    match = DIGEST.match(digest)
    if not match:
        raise TraceQuestError(f"{digest!r} is not sha256:<64 hex>")
    return f"{PREFIX}{match.group(1)}.gz"


def digest_of_key(key: str) -> str | None:
    name = key[len(PREFIX):] if key.startswith(PREFIX) else ""
    return f"sha256:{name[:-3]}" if re.fullmatch(r"[0-9a-f]{64}\.gz", name) else None


def sigv4_headers(*, method: str, host: str, path: str, query: Mapping[str, str], headers: Mapping[str, str],
                  payload_sha256: str, access_key: str, secret_key: str, now: datetime,
                  region: str = "auto", service: str = "s3") -> dict[str, str]:
    """AWS Signature Version 4 headers for one S3 request (R2 takes region `auto`)."""
    amz_date, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    signed = {key.lower(): value.strip() for key, value in headers.items()}
    signed.update({"host": host, "x-amz-content-sha256": payload_sha256, "x-amz-date": amz_date})
    names = ";".join(sorted(signed))
    canonical_query = "&".join(f"{urllib.parse.quote(k, safe='-_.~')}={urllib.parse.quote(v, safe='-_.~')}"
                               for k, v in sorted(query.items()))
    canonical = "\n".join([method, urllib.parse.quote(path, safe="/-_.~"), canonical_query,
                           "".join(f"{k}:{signed[k]}\n" for k in sorted(signed)), names, payload_sha256])
    scope = f"{day}/{region}/{service}/aws4_request"
    to_sign = f"AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}"
    key = ("AWS4" + secret_key).encode()
    for part in (day, region, service, "aws4_request"):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
    signed["authorization"] = f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, SignedHeaders={names}, Signature={signature}"
    return signed


@dataclasses.dataclass(frozen=True)
class R2BlobStore:
    account_id: str
    access_key: str
    secret_key: str
    bucket: str
    public_url: str | None = None
    clock: Callable[[], datetime] = utc_now
    timeout_s: float = 60

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> "R2BlobStore":
        names = ("CMUX_PERF_LAB_R2_ACCOUNT_ID", "CMUX_PERF_LAB_R2_ACCESS_KEY_ID", "CMUX_PERF_LAB_R2_SECRET_ACCESS_KEY")
        missing = [name for name in names if not env.get(name)]
        if missing:
            raise TraceQuestError(f"R2 is not configured: {', '.join(missing)} not set")
        return cls(env[names[0]], env[names[1]], env[names[2]], env.get("CMUX_PERF_LAB_R2_BUCKET") or "cmux-perf-lab",
                   (env.get("CMUX_PERF_LAB_R2_PUBLIC_URL") or "").rstrip("/") or None)

    @property
    def host(self) -> str:
        return f"{self.account_id}.r2.cloudflarestorage.com"

    def _request(self, method: str, key: str, *, query: Mapping[str, str] | None = None, body: bytes = b"",
                 headers: Mapping[str, str] | None = None,
                 ok: tuple[int, ...] = (200,)) -> tuple[http.client.HTTPResponse, bytes]:
        path, query = f"/{self.bucket}/{key}" if key else f"/{self.bucket}", query or {}
        signed = sigv4_headers(method=method, host=self.host, path=path, query=query, headers=headers or {},
                               payload_sha256=hashlib.sha256(body).hexdigest(), access_key=self.access_key,
                               secret_key=self.secret_key, now=self.clock().astimezone(timezone.utc))
        target = urllib.parse.quote(path, safe="/-_.~") + (f"?{urllib.parse.urlencode(sorted(query.items()))}" if query else "")
        connection = http.client.HTTPSConnection(self.host, timeout=self.timeout_s)
        try:
            connection.request(method, target, body=body, headers=signed)
            response = connection.getresponse()
            data = response.read()
        except http.client.HTTPException as error:  # IncompleteRead, BadStatusLine, ...: not OSError
            raise TraceQuestError(f"R2 {method} {key or self.bucket}: {type(error).__name__}: {error}") from error
        finally:
            connection.close()
        if response.status not in ok:
            raise TraceQuestError(f"R2 {method} {key or self.bucket}: HTTP {response.status} {data[:200]!r}")
        return response, data

    def put(self, key: str, data: bytes, content_type: str) -> None:
        self._request("PUT", key, body=data, headers={"content-type": content_type})

    def delete(self, key: str) -> None:
        self._request("DELETE", key, ok=(200, 204, 404))

    def size(self, key: str) -> int | None:
        """The object's size from HEAD, or None when R2 has no such object."""
        response, _ = self._request("HEAD", key, ok=(200, 404))
        return int(response.getheader("content-length") or 0) if response.status == 200 else None

    def list(self, prefix: str) -> Iterator[tuple[str, datetime]]:
        token = None
        while True:
            query = {"list-type": "2", "prefix": prefix, **({"continuation-token": token} if token else {})}
            keys, token = parse_list_page(self._request("GET", "", query=query)[1])
            yield from keys
            if token is None:
                return

    def url_for(self, key: str) -> str:
        return f"{self.public_url}/{key}" if self.public_url else f"r2://{self.bucket}/{key}"


def parse_list_page(body: bytes) -> tuple[list[tuple[str, datetime]], str | None]:
    """One ListObjectsV2 page: (key, LastModified) of each object, and the continuation token when truncated."""
    try:
        root = ET.fromstring(body)
    except ET.ParseError as error:
        raise TraceQuestError(f"R2 list: not an XML list body: {error} {body[:200]!r}") from error
    ns = root.tag[1:].split("}")[0] if root.tag.startswith("{") else ""

    def child(node: ET.Element, name: str) -> str | None:
        found = node.find(f"{{{ns}}}{name}" if ns else name)
        return None if found is None else found.text

    def required(node: ET.Element, name: str) -> str:
        text = child(node, name)
        if text is None:
            raise TraceQuestError(f"R2 list: a {node.tag.split('}')[-1]} element has no {name}")
        return text

    keys = []
    for item in root.iterfind(f"{{{ns}}}Contents" if ns else "Contents"):
        modified = required(item, "LastModified")
        try:
            moment = datetime.fromisoformat(modified.replace("Z", "+00:00"))
        except ValueError as error:
            raise TraceQuestError(f"R2 list: LastModified {modified!r}: {error}") from error
        keys.append((required(item, "Key"), moment))
    if child(root, "IsTruncated") != "true":
        return keys, None
    return keys, required(root, "NextContinuationToken")


# ---------------------------------------------------------------- recording

class Source(Protocol):
    def start(self) -> None: ...
    def stop(self) -> None: ...
    def kill(self) -> None: ...  # ends the recorder at once after its stop failed, as trace.py's recorders do


# (attempt directory, the app's debug-socket rpc or None, the daemon spans file or None) -> sources.
SourceFactory = Callable[[Path, Any, Any], "list[Source]"]


def _load_trace_py() -> Any:
    spec = importlib.util.spec_from_file_location("cmux_trace", TRACE_PY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def trace_py_sources(directory: Path, rpc: Callable[..., Any] | None, spans_path: Path | None) -> list[Source]:
    """trace.py's recorders without xctrace or the sampler: signposts always, the watchdog with the app's
    debug socket, daemon spans with the app's CMUX_NEXT_TUI_DEBUG_SPANS file."""
    trace = _load_trace_py()
    sources: list[Source] = [trace.SignpostStream(str(directory / SOURCES["signpost"]))]
    if rpc is not None:
        rpc("debug.hangs", {"clear": True}, timeout=trace.RPC_SHORT_S)  # this attempt's stalls only
        sources.append(trace.HangDrain(rpc, str(directory / SOURCES["watchdog"])))
    if spans_path is not None:
        spans_path.write_bytes(b"")  # tail -F reads from the start; the app appends with O_APPEND
        sources.append(trace.FileFollower(str(spans_path), str(directory / SOURCES["daemon"])))
    return sources


@dataclasses.dataclass(frozen=True)
class TraceRef:
    source: str
    attempt: int
    digest: str
    url: str
    bytes: int

    @property
    def attachment_kind(self) -> str:
        return f"trace-{self.source}-{self.attempt}"


def pick_attempts(values: Sequence[float | None]) -> list[int]:
    """The first attempt and the median one (the lower median by value, the earlier attempt on a tie).
    A failed attempt (None) is never the median, but attempt 0 is kept even when it failed."""
    if not values:
        return []
    measured = sorted(value for value in values if value is not None)
    picks = {0}
    if measured:
        median = measured[(len(measured) - 1) // 2]
        picks.add(values.index(median))
    return sorted(picks)


def publish_attempt(directory: Path, attempt: int, blobs: BlobStore) -> list[TraceRef]:
    """Uploads each non-empty source file of one recorded attempt, gzipped, by digest."""
    refs = []
    for source, name in SOURCES.items():
        path = directory / name
        if not path.is_file() or path.stat().st_size == 0:
            continue
        data = gzip.compress(path.read_bytes(), mtime=0)
        digest = f"sha256:{hashlib.sha256(data).hexdigest()}"
        key = blob_key(digest)
        blobs.put(key, data, "application/gzip")
        refs.append(TraceRef(source, attempt, digest, blobs.url_for(key), len(data)))
    return refs


class TraceQuest:
    """The traces of one story run, Pinpoint Change or try arm: record every attempt, keep first and median."""

    def __init__(self, root: Path, blobs: BlobStore, sources: SourceFactory = trace_py_sources) -> None:
        self.root, self.blobs, self.sources = Path(root), blobs, sources
        self.recorded: list[int] = []

    def attempt_dir(self, attempt: int) -> Path:
        return self.root / f"attempt-{attempt:03d}"

    @contextlib.contextmanager
    def record(self, attempt: int, *, rpc: Callable[..., Any] | None = None,
               spans_path: Path | None = None) -> Iterator[Path]:
        directory = self.attempt_dir(attempt)
        directory.mkdir(parents=True, exist_ok=False)
        started: list[Source] = []
        try:
            for source in self.sources(directory, rpc, spans_path):
                source.start()
                started.append(source)
            yield directory
        finally:
            self.recorded.append(attempt)
            failures = []
            for source in reversed(started):  # every source stops, even after another one's stop failed
                try:
                    source.stop()
                except Exception as error:  # noqa: BLE001 - re-raised below, after the other stops
                    failures.append(f"{type(source).__name__}: {error}")
                    try:
                        source.kill()  # trace.py does the same past its stop bound: no recorder outlives its attempt
                    except Exception as kill_error:  # noqa: BLE001 - re-raised below with the stop failure
                        failures.append(f"{type(source).__name__} kill: {kill_error}")
            if failures:
                raise TraceQuestError(f"{directory}: a trace source did not stop: {'; '.join(failures)}")

    def publish(self, values: Sequence[float | None]) -> dict[int, list[TraceRef]]:
        """`values[i]` is attempt i's value of the story's primary metric. Uploads the picked attempts and
        deletes the other attempt directories."""
        if sorted(self.recorded) != list(range(len(values))):
            raise TraceQuestError(f"{self.root}: recorded attempts {sorted(self.recorded)} do not match "
                                  f"{len(values)} values")
        picks = pick_attempts(values)
        refs = {attempt: publish_attempt(self.attempt_dir(attempt), attempt, self.blobs) for attempt in picks}
        for attempt in self.recorded:
            if attempt not in refs:
                shutil.rmtree(self.attempt_dir(attempt))
        return refs


def with_traces(results: Sequence[Any], refs: Mapping[int, Sequence[TraceRef]], perf_result: Any) -> list[Any]:
    """The run's results with the trace attachments added (every result of a run carries the same ones).
    `perf_result` is the caller's loaded perf_result module: Result.to_dict checks its own Attachment class."""
    extra = [perf_result.Attachment(digest=ref.digest, kind=ref.attachment_kind)
             for attempt in sorted(refs) for ref in refs[attempt]]
    return [dataclasses.replace(result, attachments=[*result.attachments, *extra]) for result in results]


# ---------------------------------------------------------------- the lab store

def connect(path: Path | str, busy_timeout_ms: int = 5000) -> sqlite3.Connection:
    """A connection to labd's store (store.py owns the schema; it must be migrated)."""
    db = sqlite3.connect(str(path), isolation_level=None, timeout=busy_timeout_ms / 1000)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'traces'").fetchone():
        db.close()
        raise TraceQuestError(f"{path}: no traces table; run store.py's migrate first")
    return db


@contextlib.contextmanager
def _write(db: sqlite3.Connection) -> Iterator[None]:
    db.execute("BEGIN IMMEDIATE")  # as store.py: writers in other processes wait on busy_timeout
    try:
        yield
    except BaseException:
        db.execute("ROLLBACK")
        raise
    db.execute("COMMIT")


def trace_attachments(attachments_json: str) -> list[tuple[str, int, str]]:
    """(source, attempt, digest) of each trace attachment in a run's attachments_json."""
    out = []
    for item in json.loads(attachments_json):
        match = ATTACHMENT_KIND.match(str(item.get("kind", ""))) if isinstance(item, dict) else None
        if match:
            out.append((match.group(1), int(match.group(2)), str(item.get("digest"))))
    return out


@dataclasses.dataclass(frozen=True)
class IndexReport:
    added: int
    missing: list[str]  # "<attachment kind> <digest>" of each trace attachment with no R2 object


def index_run(db: sqlite3.Connection, run_uuid: str, blobs: BlobStore,
              clock: Callable[[], datetime] = utc_now) -> IndexReport:
    """Adds a traces row for each trace attachment of a stored run (idempotent). An attachment whose object is
    not in R2 gets no row, so every stored link opens: it is reported, and the run's other attachments are indexed."""
    run = db.execute("SELECT id, job_id, attachments_json FROM runs WHERE run_uuid = ?", (run_uuid,)).fetchone()
    if run is None:
        raise TraceQuestError(f"no run {run_uuid}")
    found, missing = [], []
    for source, attempt, digest in trace_attachments(run["attachments_json"]):
        size = blobs.size(blob_key(digest)) if DIGEST.match(digest) else None  # network reads before the lock
        if size is None:
            missing.append(f"trace-{source}-{attempt} {digest}")
        else:
            found.append((source, attempt, digest, blobs.url_for(blob_key(digest)), size))
    added = 0
    with _write(db):
        for source, attempt, digest, url, size in found:
            row = (run["id"], run["job_id"], attempt, source, digest)
            if db.execute("SELECT 1 FROM traces WHERE run_id = ? AND job_id IS ? AND attempt = ? AND kind = ? "
                          "AND digest = ?", row).fetchone():
                continue
            db.execute("INSERT INTO traces (run_id, job_id, attempt, kind, digest, url, bytes, created_at) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?, ?)", (*row, url, size, stamp(clock())))
            added += 1
    return IndexReport(added, missing)


_TRACE_COLUMNS = """t.id, t.kind, t.attempt, t.digest, t.url, u.run_uuid, u.kind AS run_kind, b.sha,
                    b.commit_pos, COALESCE(t.job_id, u.job_id) AS job_id"""
_TRACE_JOINS = "FROM traces t JOIN runs u ON u.id = t.run_id JOIN builds b ON b.id = u.build_id"

# CTEs (after WITH). alert_point_runs: the waterfall runs inside an alert's [start_pos, end_pos] on its series,
# plus the last point before it (C^), of the alerts of group :group (NULL: every alert). referenced_runs adds
# the runs of every job that belongs to an alert group. All in SQL: no bound variable per run.
_ALERT_POINT_RUNS = """
    alert_points AS (
        SELECT a.id AS alert_id, a.start_pos, u.id AS run_id, b.commit_pos
        FROM alerts a JOIN results r ON r.series_id = a.series_id
        JOIN runs u ON u.id = r.run_id AND u.kind = 'waterfall' JOIN builds b ON b.id = u.build_id
        WHERE (:group IS NULL OR a.group_id = :group) AND b.commit_pos <= a.end_pos),
    alert_lows AS (
        SELECT alert_id, MAX(CASE WHEN commit_pos < start_pos THEN commit_pos END) AS before_pos
        FROM alert_points GROUP BY alert_id),
    alert_point_runs AS (
        SELECT DISTINCT p.run_id FROM alert_points p JOIN alert_lows l ON l.alert_id = p.alert_id
        WHERE p.commit_pos >= COALESCE(l.before_pos, p.start_pos))"""
_REFERENCED_RUNS = _ALERT_POINT_RUNS + """,
    referenced_runs AS (
        SELECT run_id FROM alert_point_runs
        UNION SELECT u.id FROM runs u JOIN jobs j ON j.id = u.job_id WHERE j.alert_group_id IS NOT NULL)"""


def traces_for_point(db: sqlite3.Connection, run_uuid: str) -> list[sqlite3.Row]:
    return db.execute(f"SELECT {_TRACE_COLUMNS} {_TRACE_JOINS} WHERE u.run_uuid = ? ORDER BY t.attempt, t.kind",
                      (run_uuid,)).fetchall()


def traces_for_change(db: sqlite3.Connection, job_id: int, sha: str) -> list[sqlite3.Row]:
    """A Pinpoint Change's traces: the job's runs of the build at `sha`."""
    return db.execute(f"SELECT {_TRACE_COLUMNS} {_TRACE_JOINS} WHERE COALESCE(t.job_id, u.job_id) = ? AND b.sha = ? "
                      "ORDER BY u.run_uuid, t.attempt, t.kind", (job_id, sha)).fetchall()


def traces_for_group(db: sqlite3.Connection, group_id: int) -> list[sqlite3.Row]:
    """An alert group's traces in commit order: its jobs' runs (bisect Changes, the verify C^ and C) and its
    alert points."""
    return db.execute(
        f"WITH {_ALERT_POINT_RUNS} SELECT {_TRACE_COLUMNS}, j.kind AS job_kind, j.base_sha, j.head_sha "
        f"{_TRACE_JOINS} LEFT JOIN jobs j ON j.id = COALESCE(t.job_id, u.job_id) "
        "WHERE j.alert_group_id = :group OR u.id IN (SELECT run_id FROM alert_point_runs) "
        "ORDER BY b.commit_pos, u.run_uuid, t.attempt, t.kind", {"group": group_id}).fetchall()


def issue_markdown(db: sqlite3.Connection, group_id: int) -> str:
    """The issue's trace section: one line per (role, sha), C^ and C of the verify job first, then the rest in
    commit order."""
    lines: dict[tuple[int, str, str], list[str]] = {}  # insertion order is traces_for_group's commit order
    for row in traces_for_group(db, group_id):
        if row["job_kind"] == "verify":
            role = "C^" if row["sha"] == row["base_sha"] else "C" if row["sha"] == row["head_sha"] else "verify"
            order = 0 if role == "C^" else 1
        else:
            role, order = (row["job_kind"] or row["run_kind"]), 2
        links = lines.setdefault((order, role, row["sha"]), [])
        links.append(f"[{row['kind']} #{row['attempt']}]({row['url']})")
    ordered = sorted(lines.items(), key=lambda item: item[0][0])  # stable: commit order within each order
    body = [f"- {role} `{sha[:12]}`: {' '.join(links)}" for (_, role, sha), links in ordered]
    return "\n".join(["### Traces", *body]) if body else "### Traces\n- none recorded"


_RUN_TRACED = "u.attachments_json, EXISTS (SELECT 1 FROM traces t WHERE t.run_id = u.id) AS indexed"


def _traced(run: sqlite3.Row) -> bool:
    """A run has a trace digest once ingested with a trace attachment, indexed or not."""
    return bool(run["indexed"]) or bool(trace_attachments(run["attachments_json"]))


def _change_traced(db: sqlite3.Connection, job_id: int, sha: str) -> bool:
    return bool(traces_for_change(db, job_id, sha)) or any(_traced(run) for run in db.execute(
        f"SELECT {_RUN_TRACED} FROM runs u JOIN builds b ON b.id = u.build_id WHERE u.job_id = ? AND b.sha = ?",
        (job_id, sha)))


def coverage(db: sqlite3.Connection, since: datetime) -> dict[str, list[str]]:
    """What the acceptance needs and lacks: T0 points and bisect Changes with no trace digest, verified culprits
    without traces for both C^ and C. `not_indexed` names runs whose trace digests have no traces rows yet
    (no links): it is not an acceptance miss."""
    after = stamp(since)
    runs = db.execute(
        f"SELECT u.run_uuid, u.kind, u.tier, u.job_id, b.sha, j.kind AS job_kind, {_RUN_TRACED} "
        "FROM runs u JOIN builds b ON b.id = u.build_id LEFT JOIN jobs j ON j.id = u.job_id "
        "WHERE u.started_at >= ? ORDER BY u.started_at, u.id", (after,)).fetchall()
    points = [run["run_uuid"] for run in runs if run["kind"] == "waterfall" and run["tier"] == "T0" and not _traced(run)]
    changes: dict[tuple[int, str], bool] = {}
    for run in runs:
        if run["job_kind"] == "bisect":
            key = (run["job_id"], run["sha"])
            changes[key] = changes.get(key, False) or _traced(run)
    not_indexed = [run["run_uuid"] for run in runs if not run["indexed"] and trace_attachments(run["attachments_json"])]
    culprits = []
    for group in db.execute("SELECT g.id, j.id AS job_id, j.base_sha, j.head_sha FROM alert_groups g "
                            "JOIN jobs j ON j.alert_group_id = g.id AND j.kind = 'verify' "
                            "WHERE g.culprit_verified = 1 AND g.updated_at >= ?", (after,)).fetchall():
        for role, sha in (("C^", group["base_sha"]), ("C", group["head_sha"])):
            if not sha or not _change_traced(db, group["job_id"], sha):
                culprits.append(f"group {group['id']} {role} {sha}")
    return {"t0_points": points,
            "bisect_changes": [f"job {job} {sha}" for (job, sha), traced in sorted(changes.items()) if not traced],
            "verified_culprits": culprits, "not_indexed": not_indexed}


COVERAGE_MISSES = ("t0_points", "bisect_changes", "verified_culprits")


@dataclasses.dataclass(frozen=True)
class ExpireReport:
    rows: int
    blobs: list[str]


def expire(db: sqlite3.Connection, blobs: BlobStore, *, now: datetime, retention: timedelta = RETENTION,
           dry_run: bool = False) -> ExpireReport:
    """Deletes unreferenced traces rows older than `retention`, then R2 objects older than it that no live row
    and no kept run names. A run is kept while it is younger than `retention` or referenced, so the digests of an
    ingested run that was never indexed (or only in part) stay. The object pass also removes uploads whose run
    was never ingested and objects a failed earlier sweep left."""
    cutoff = now - retention
    params = {"group": None, "cutoff": stamp(cutoff)}
    with _write(db):
        rows = db.execute(
            f"WITH {_REFERENCED_RUNS} SELECT t.id, t.digest, t.created_at < :cutoff AND NOT ("
            "t.run_id IN (SELECT run_id FROM referenced_runs) OR EXISTS (SELECT 1 FROM jobs j "
            "WHERE j.id = t.job_id AND j.alert_group_id IS NOT NULL)) AS doomed FROM traces t", params).fetchall()
        kept_runs = db.execute(
            f"WITH {_REFERENCED_RUNS} SELECT attachments_json FROM runs "
            "WHERE started_at >= :cutoff OR id IN (SELECT run_id FROM referenced_runs)", params).fetchall()
        doomed = sorted(row["id"] for row in rows if row["doomed"])
        if doomed and not dry_run:
            db.executemany("DELETE FROM traces WHERE id = ?", [(trace_id,) for trace_id in doomed])
    live = {row["digest"] for row in rows if not row["doomed"]}
    live.update(digest for run in kept_runs for _, _, digest in trace_attachments(run["attachments_json"]))
    gone = []
    for key, modified in blobs.list(PREFIX):
        digest = digest_of_key(key)
        if digest is None or digest in live or modified >= cutoff:
            continue
        if not dry_run:
            blobs.delete(key)
        gone.append(key)
    return ExpireReport(len(doomed), gone)


# ---------------------------------------------------------------- runs

SINCE_AGO = re.compile(r"^([0-9]+)([mhd])$")


def parse_since(text: str, now: datetime) -> datetime:
    """`1h`, `30m`, `7d` before `now`, or an ISO-8601 time with a timezone."""
    match = SINCE_AGO.match(text)
    if match:
        unit = {"m": "minutes", "h": "hours", "d": "days"}[match.group(2)]
        return now - timedelta(**{unit: int(match.group(1))})
    moment = datetime.fromisoformat(text)
    if moment.tzinfo is None:
        raise TraceQuestError(f"--since {text}: give a duration (1h, 30m, 7d) or a time with a timezone")
    return moment


def runs_since(db: sqlite3.Connection, since: datetime, kind: str | None = None) -> list[dict[str, Any]]:
    """Stored runs started at or after `since`, oldest first, each with its trace digests: every trace attachment
    of the run, with the link and size once `index` has stored its traces row (`indexed` false before that)."""
    where, args = "WHERE u.started_at >= ?", [stamp(since)]
    if kind:
        where, args = f"{where} AND u.kind = ?", [*args, kind]
    out = []
    for run in db.execute(f"SELECT u.id, u.run_uuid, u.kind, u.tier, u.story, u.job_id, u.started_at, "
                          f"u.attachments_json, b.sha, b.commit_pos FROM runs u JOIN builds b ON b.id = u.build_id "
                          f"{where} ORDER BY u.started_at, u.id", args).fetchall():
        indexed = {(row["kind"], row["attempt"], row["digest"]): row for row in db.execute(
            "SELECT kind, attempt, digest, url, bytes FROM traces WHERE run_id = ?", (run["id"],))}
        traces = []
        for source, attempt, digest in trace_attachments(run["attachments_json"]):
            row = indexed.get((source, attempt, digest))
            traces.append({"source": source, "attempt": attempt, "digest": digest, "indexed": row is not None,
                           **({"url": row["url"], "bytes": row["bytes"]} if row is not None else {})})
        out.append({"run_uuid": run["run_uuid"], "kind": run["kind"], "tier": run["tier"], "story": run["story"],
                    "sha": run["sha"], "commit_pos": run["commit_pos"], "job_id": run["job_id"],
                    "started_at": run["started_at"], "traces": traces})
    return out


# ---------------------------------------------------------------- CLI (lab.py commands and direct)

DB_ENV = "CMUX_PERF_LAB_DB"
LAB_COMMANDS = {
    "runs": "List stored runs since --since (1h, 30m, 7d or ISO-8601) with their trace digests.",
    "traces": "Story-run traces: publish an attempt, index a run, coverage, issue links, the 30-day expiry.",
}
ACTIONS = {
    "publish": "upload one recorded attempt directory, print its attachments",
    "index": "traces rows from a stored run's trace attachments (exit 1 when one is not in R2)",
    "coverage": "T0 points, bisect Changes and verified culprits with no trace (exit 1 when any), unindexed runs",
    "links": "the alert group's trace links, as issue Markdown",
    "expire": "the 30-day retention sweep",
}


def _add_db(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--db", type=Path, default=os.environ.get(DB_ENV),
                        help=f"the lab store (SQLite); default ${DB_ENV}")


def _add_action(action: str, parser: argparse.ArgumentParser) -> None:
    if action == "publish":
        parser.add_argument("dir", type=Path)
        parser.add_argument("--attempt", type=int, required=True)
        return
    _add_db(parser)
    if action == "index":
        parser.add_argument("--run", required=True)
    elif action == "coverage":
        parser.add_argument("--since", required=True, help="1h, 30m, 7d or ISO-8601 with a timezone")
    elif action == "links":
        parser.add_argument("--group", type=int, required=True)
    elif action == "expire":
        parser.add_argument("--dry-run", action="store_true")


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    if command == "runs":
        _add_db(parser)
        parser.add_argument("--since", required=True, help="1h, 30m, 7d or ISO-8601 with a timezone")
        parser.add_argument("--kind", help="only runs of this kind (waterfall, bisect, verify, try, ...)")
        parser.add_argument("--json", action="store_true", help="print the runs as JSON")
        return
    actions = parser.add_subparsers(dest="action", metavar="ACTION", required=True)
    for action, text in ACTIONS.items():
        _add_action(action, actions.add_parser(action, help=text, description=text))


def _run(action: str, args: argparse.Namespace, clock: Callable[[], datetime]) -> int:
    if action == "publish":
        refs = publish_attempt(args.dir, args.attempt, R2BlobStore.from_env())
        print(json.dumps([{"digest": ref.digest, "kind": ref.attachment_kind, "url": ref.url, "bytes": ref.bytes}
                          for ref in refs], indent=1))
        return 0
    if not args.db:
        raise TraceQuestError(f"--db or ${DB_ENV} names the lab store")
    db = connect(args.db)
    try:
        if action == "runs":
            runs = runs_since(db, parse_since(args.since, clock()), args.kind)
            if args.json:
                print(json.dumps(runs, indent=1))
            for run in [] if args.json else runs:
                digests = " ".join(f"{t['source']}#{t['attempt']}={t['digest'][7:19]}" for t in run["traces"])
                print(f"{run['started_at']} {run['kind']:<9} {run['tier'] or '-':<3} {run['story']} "
                      f"{run['sha'][:12]} {run['run_uuid']} {digests or 'no traces'}")
        elif action == "index":
            report = index_run(db, args.run, R2BlobStore.from_env())
            print(json.dumps({"added": report.added, "missing": report.missing}, indent=1))
            return 1 if report.missing else 0
        elif action == "coverage":
            misses = coverage(db, parse_since(args.since, clock()))
            print(json.dumps(misses, indent=1))
            return 1 if any(misses[name] for name in COVERAGE_MISSES) else 0
        elif action == "links":
            print(issue_markdown(db, args.group))
        else:
            report = expire(db, R2BlobStore.from_env(), now=clock(), dry_run=args.dry_run)
            print(json.dumps({"rows": report.rows, "blobs": report.blobs, "dry_run": args.dry_run}, indent=1))
        return 0
    finally:
        db.close()


def run(command: str, args: argparse.Namespace, clock: Callable[[], datetime] = utc_now) -> int:
    """lab.py's entry: `runs`, or `traces ACTION`. Exit 2 when the command could not run."""
    try:
        return _run(args.action if command == "traces" else command, args, clock)
    except (TraceQuestError, ValueError, OSError, sqlite3.Error) as error:
        print(f"perf-lab {command}: {error}", file=sys.stderr)
        return 2


def main(argv: Sequence[str] | None = None, clock: Callable[[], datetime] = utc_now) -> int:
    """Direct use: `trace_quest.py runs ...` or `trace_quest.py ACTION ...` (the actions of `lab.py traces`)."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    add_arguments("runs", sub.add_parser("runs", help=LAB_COMMANDS["runs"]))
    for action, text in ACTIONS.items():
        _add_action(action, sub.add_parser(action, help=text, description=text))
    opts = parser.parse_args(argv)
    return run(opts.command, opts, clock)


if __name__ == "__main__":
    sys.exit(main())
