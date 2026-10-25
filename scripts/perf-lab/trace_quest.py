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
30 days that no row names (also uploads whose ingest never happened). Referenced: a trace of a job that belongs
to an alert group (bisect, verify), or of a waterfall point inside an alert's range or the point just before it.

  trace_quest.py publish DIR --attempt N           upload one recorded attempt directory, print its attachments
  trace_quest.py index --db DB --run UUID          traces rows from a stored run's trace attachments
  trace_quest.py coverage --db DB --since ISO      T0 points, bisect Changes and verified culprits with no trace
  trace_quest.py links --db DB --group N           the group's trace links, as issue Markdown
  trace_quest.py expire --db DB [--dry-run]        the 30-day retention sweep

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
            root = ET.fromstring(self._request("GET", "", query=query)[1])
            ns = {"s3": root.tag.split("}")[0].strip("{")} if root.tag.startswith("{") else {"s3": ""}
            find = (lambda node, name: node.find(f"s3:{name}", ns)) if ns["s3"] else (lambda node, name: node.find(name))
            for item in root.iterfind("s3:Contents" if ns["s3"] else "Contents", ns):
                modified = find(item, "LastModified").text.replace("Z", "+00:00")
                yield find(item, "Key").text, datetime.fromisoformat(modified)
            truncated, next_token = find(root, "IsTruncated"), find(root, "NextContinuationToken")
            if truncated is None or truncated.text != "true" or next_token is None:
                return
            token = next_token.text

    def url_for(self, key: str) -> str:
        return f"{self.public_url}/{key}" if self.public_url else f"r2://{self.bucket}/{key}"


# ---------------------------------------------------------------- recording

class Source(Protocol):
    def start(self) -> None: ...
    def stop(self) -> None: ...


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


def index_run(db: sqlite3.Connection, run_uuid: str, blobs: BlobStore, clock: Callable[[], datetime] = utc_now) -> int:
    """Adds a traces row for each trace attachment of a stored run (idempotent); returns rows added.
    An attachment whose object is not in R2 is refused, so every stored link opens."""
    run = db.execute("SELECT id, job_id, attachments_json FROM runs WHERE run_uuid = ?", (run_uuid,)).fetchone()
    if run is None:
        raise TraceQuestError(f"no run {run_uuid}")
    found = []
    for item in json.loads(run["attachments_json"]):
        match = ATTACHMENT_KIND.match(str(item.get("kind", ""))) if isinstance(item, dict) else None
        if not match:
            continue
        key = blob_key(str(item.get("digest")))
        size = blobs.size(key)  # the network reads happen before the write lock is taken
        if size is None:
            raise TraceQuestError(f"{run_uuid}: {item['kind']} {item['digest']} is not in R2")
        found.append((match.group(1), int(match.group(2)), item["digest"], blobs.url_for(key), size))
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
    return added


_TRACE_COLUMNS = """t.id, t.kind, t.attempt, t.digest, t.url, u.run_uuid, u.kind AS run_kind, b.sha,
                    b.commit_pos, COALESCE(t.job_id, u.job_id) AS job_id"""
_TRACE_JOINS = "FROM traces t JOIN runs u ON u.id = t.run_id JOIN builds b ON b.id = u.build_id"


def traces_for_point(db: sqlite3.Connection, run_uuid: str) -> list[sqlite3.Row]:
    return db.execute(f"SELECT {_TRACE_COLUMNS} {_TRACE_JOINS} WHERE u.run_uuid = ? ORDER BY t.attempt, t.kind",
                      (run_uuid,)).fetchall()


def traces_for_change(db: sqlite3.Connection, job_id: int, sha: str) -> list[sqlite3.Row]:
    """A Pinpoint Change's traces: the job's runs of the build at `sha`."""
    return db.execute(f"SELECT {_TRACE_COLUMNS} {_TRACE_JOINS} WHERE COALESCE(t.job_id, u.job_id) = ? AND b.sha = ? "
                      "ORDER BY u.run_uuid, t.attempt, t.kind", (job_id, sha)).fetchall()


def _alert_point_runs(db: sqlite3.Connection, group_id: int | None = None) -> set[int]:
    """Waterfall runs inside an alert's [start_pos, end_pos] on its series, plus the last point before it (C^)."""
    where, args = ("WHERE a.group_id = ?", (group_id,)) if group_id is not None else ("", ())
    runs: set[int] = set()
    for alert in db.execute(f"SELECT a.series_id, a.start_pos, a.end_pos FROM alerts a {where}", args).fetchall():
        points = "FROM results r JOIN runs u ON u.id = r.run_id JOIN builds b ON b.id = u.build_id " \
                 "WHERE r.series_id = ? AND u.kind = 'waterfall'"
        before = db.execute(f"SELECT MAX(b.commit_pos) {points} AND b.commit_pos < ?",
                            (alert["series_id"], alert["start_pos"])).fetchone()[0]
        low = alert["start_pos"] if before is None else before
        runs.update(row[0] for row in db.execute(f"SELECT u.id {points} AND b.commit_pos BETWEEN ? AND ?",
                                                 (alert["series_id"], low, alert["end_pos"])))
    return runs


def traces_for_group(db: sqlite3.Connection, group_id: int) -> list[sqlite3.Row]:
    """An alert group's traces: its jobs' runs (bisect Changes, the verify C^ and C) and its alert points."""
    point_runs = _alert_point_runs(db, group_id)
    marks = ",".join("?" * len(point_runs))
    in_points = f" OR u.id IN ({marks})" if point_runs else ""
    return db.execute(
        f"SELECT {_TRACE_COLUMNS}, j.kind AS job_kind, j.base_sha, j.head_sha {_TRACE_JOINS} "
        "LEFT JOIN jobs j ON j.id = COALESCE(t.job_id, u.job_id) "
        f"WHERE j.alert_group_id = ?{in_points} ORDER BY b.commit_pos, u.run_uuid, t.attempt, t.kind",
        (group_id, *point_runs)).fetchall()


def issue_markdown(db: sqlite3.Connection, group_id: int) -> str:
    """The issue's trace section: one line per (role, sha), C^ and C of the verify job first."""
    lines: dict[tuple[int, str, str], list[str]] = {}
    for row in traces_for_group(db, group_id):
        if row["job_kind"] == "verify":
            role = "C^" if row["sha"] == row["base_sha"] else "C" if row["sha"] == row["head_sha"] else "verify"
            order = 0 if role == "C^" else 1
        else:
            role, order = (row["job_kind"] or row["run_kind"]), 2
        links = lines.setdefault((order, role, row["sha"]), [])
        links.append(f"[{row['kind']} #{row['attempt']}]({row['url']})")
    body = [f"- {role} `{sha[:12]}`: {' '.join(links)}" for (_, role, sha), links in sorted(lines.items())]
    return "\n".join(["### Traces", *body]) if body else "### Traces\n- none recorded"


def coverage(db: sqlite3.Connection, since: datetime) -> dict[str, list[str]]:
    """What the acceptance needs and lacks: T0 points and bisect Changes with no trace, verified culprits
    without traces for both C^ and C."""
    after = stamp(since)
    traced = "EXISTS (SELECT 1 FROM traces t WHERE t.run_id = u.id)"
    points = [row[0] for row in db.execute(
        f"SELECT u.run_uuid FROM runs u WHERE u.kind = 'waterfall' AND u.tier = 'T0' AND u.started_at >= ? "
        f"AND NOT {traced} ORDER BY u.started_at", (after,))]
    changes = [f"job {row[0]} {row[1]}" for row in db.execute(
        f"SELECT u.job_id, b.sha FROM runs u JOIN builds b ON b.id = u.build_id JOIN jobs j ON j.id = u.job_id "
        f"WHERE j.kind = 'bisect' AND u.started_at >= ? GROUP BY u.job_id, b.sha HAVING SUM({traced}) = 0 "
        "ORDER BY u.job_id, b.sha", (after,))]
    culprits = []
    for group in db.execute("SELECT g.id, j.id AS job_id, j.base_sha, j.head_sha FROM alert_groups g "
                            "JOIN jobs j ON j.alert_group_id = g.id AND j.kind = 'verify' "
                            "WHERE g.culprit_verified = 1 AND g.updated_at >= ?", (after,)).fetchall():
        for role, sha in (("C^", group["base_sha"]), ("C", group["head_sha"])):
            if not sha or not traces_for_change(db, group["job_id"], sha):
                culprits.append(f"group {group['id']} {role} {sha}")
    return {"t0_points": points, "bisect_changes": changes, "verified_culprits": culprits}


@dataclasses.dataclass(frozen=True)
class ExpireReport:
    rows: int
    blobs: list[str]


def _referenced(db: sqlite3.Connection) -> set[int]:
    in_group = {row[0] for row in db.execute(
        "SELECT t.id FROM traces t LEFT JOIN runs u ON u.id = t.run_id "
        "JOIN jobs j ON j.id = COALESCE(t.job_id, u.job_id) WHERE j.alert_group_id IS NOT NULL")}
    point_runs = _alert_point_runs(db)
    at_points = {row[0] for row in db.execute(
        f"SELECT id FROM traces WHERE run_id IN ({','.join('?' * len(point_runs))})", tuple(point_runs))} \
        if point_runs else set()
    return in_group | at_points


def expire(db: sqlite3.Connection, blobs: BlobStore, *, now: datetime, retention: timedelta = RETENTION,
           dry_run: bool = False) -> ExpireReport:
    """Deletes unreferenced traces rows older than `retention`, then R2 objects older than it that no row names.
    The object pass also removes uploads whose run was never ingested and objects a failed earlier sweep left."""
    cutoff = now - retention
    with _write(db):
        referenced = _referenced(db)
        rows = db.execute("SELECT id, digest, created_at FROM traces").fetchall()
        doomed = {row["id"] for row in rows if row["created_at"] < stamp(cutoff) and row["id"] not in referenced}
        if doomed and not dry_run:
            db.executemany("DELETE FROM traces WHERE id = ?", [(trace_id,) for trace_id in sorted(doomed)])
    live = {row["digest"] for row in rows if row["id"] not in doomed}
    gone = []
    for key, modified in blobs.list(PREFIX):
        digest = digest_of_key(key)
        if digest is None or digest in live or modified >= cutoff:
            continue
        if not dry_run:
            blobs.delete(key)
        gone.append(key)
    return ExpireReport(len(doomed), gone)


# ---------------------------------------------------------------- CLI

def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    pub = sub.add_parser("publish", help="upload one recorded attempt directory")
    pub.add_argument("dir", type=Path)
    pub.add_argument("--attempt", type=int, required=True)
    for name in ("index", "coverage", "links", "expire"):
        sub.add_parser(name).add_argument("--db", type=Path, required=True)
    sub.choices["index"].add_argument("--run", required=True)
    sub.choices["coverage"].add_argument("--since", required=True, help="ISO-8601 with a timezone")
    sub.choices["links"].add_argument("--group", type=int, required=True)
    sub.choices["expire"].add_argument("--dry-run", action="store_true")
    opts = parser.parse_args(argv)
    try:
        if opts.command == "publish":
            refs = publish_attempt(opts.dir, opts.attempt, R2BlobStore.from_env())
            print(json.dumps([{"digest": ref.digest, "kind": ref.attachment_kind, "url": ref.url, "bytes": ref.bytes}
                              for ref in refs], indent=1))
            return 0
        db = connect(opts.db)
        if opts.command == "index":
            print(index_run(db, opts.run, R2BlobStore.from_env()))
        elif opts.command == "coverage":
            misses = coverage(db, datetime.fromisoformat(opts.since))
            print(json.dumps(misses, indent=1))
            return 1 if any(misses.values()) else 0
        elif opts.command == "links":
            print(issue_markdown(db, opts.group))
        else:
            report = expire(db, R2BlobStore.from_env(), now=utc_now(), dry_run=opts.dry_run)
            print(json.dumps({"rows": report.rows, "blobs": report.blobs, "dry_run": opts.dry_run}, indent=1))
        return 0
    except (TraceQuestError, ValueError, OSError) as error:
        print(f"trace_quest: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
