#!/usr/bin/env python3
"""labd: the perf lab's service on cmux-lawrence, beside the controller (p12-perf-process.md 3.5, decision D1).

    python3 -I scripts/perf-lab/labd.py serve --controller NODE [--lab-host NODE ...] [--bind 100.x.y.z]
    python3 -I scripts/perf-lab/labd.py render-plist --sha SHA --release DIR --controller NODE ...  (deploy.sh)

A stdlib `http.server` bound only to this host's tailnet address; 0.0.0.0, loopback and any other non-tailnet
address are refused (`tailnet_address`).

- GET /status, /api/series, /api/alerts, /api/jobs, /api/coverage are open to the tailnet.
- POST /ingest (a result-v1 .ndjson body) and POST /hooks/job-finished (the controller's callback) are open only to
  callers that `tailscale whois` maps to an allowlisted node: the controller, or a lab host for /ingest. A lab host
  ingests under its own node name; only the controller may name another host. A WireGuard peer cannot forge its
  source address, so whois of the peer address is the credential, as the home server admits peers
  (backend/apps/home-server/src/admission.ts).
- A POST body needs a Content-Length of at most 1 MiB; a larger one is refused before it is read.

Handlers are thin calls into store.py, ingest.py, alerts.py and the scheduler's driver (task 011). The driver's
inputs are the big-branch tip, read with `git ls-remote` every 60 s and right after a job-finished callback (labd
fetches that one branch only when its tip moves, so ingest can order commits), and the callbacks themselves.
SQLite (WAL) lives in ~/Library/Application Support/cmux-perf-lab; each request opens its own connection, as
store.Store requires. Every night a consistent copy is gzipped and put to R2 under its sha256 (r2.py).

launchd runs it (com.cmux.perf-lab.plist) with ProcessType=Background and Nice 10. macOS does not enforce the
plist's ResidentSetSize, so labd exits with EX_TEMPFAIL once its peak RSS passes that limit and launchd starts it
again. Stdlib only; loads its siblings by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import gzip
import importlib.util
import ipaddress
import json
import os
import plistlib
import re
import resource
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
from collections.abc import Callable, Iterator, Mapping, Sequence
from contextlib import contextmanager
from dataclasses import asdict, dataclass, replace
from datetime import datetime, timedelta, timezone, tzinfo
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Protocol
from urllib.parse import parse_qs, urlsplit

HERE = Path(__file__).resolve().parent


def _sibling(name: str, path: Path):
    """The module at `path` under `name`, once per process (the names ingest.py and alerts.py use)."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None:
        raise ImportError(f"labd: no module at {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


store = _sibling("perf_lab_store", HERE / "store.py")
ingest = _sibling("perf_lab_ingest", HERE / "ingest.py")
alerts = _sibling("perf_lab_alerts", HERE / "alerts.py")
r2 = _sibling("perf_lab_r2", HERE / "r2.py")

LABEL = "com.cmux.perf-lab"
PLIST_TEMPLATE = HERE / f"{LABEL}.plist"
DATA_DIR = Path.home() / "Library" / "Application Support" / "cmux-perf-lab"
DB_NAME = "lab.sqlite3"
DEFAULT_PORT = 18766  # the controller listens on 18765 on the same host
DEFAULT_BRANCH = "feat-cmux-next"
MAX_BODY_BYTES = 1 << 20
TIP_INTERVAL_S = 60.0
BACKUP_HOUR = 3  # local time
BACKUP_PREFIX = "perf-lab/backups/sha256"
EX_TEMPFAIL = 75  # sysexits.h: launchd's KeepAlive starts labd again
TAILNETS = (ipaddress.ip_network("100.64.0.0/10"), ipaddress.ip_network("fd7a:115c:a1e0::/48"))
SHA = re.compile(r"^[0-9a-f]{40}$")
NODE_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*(\.[a-z0-9-]+)*$")
JOB_STATE = re.compile(r"^[a-z][a-z_-]{0,31}$")
JOB_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")


class LabdError(RuntimeError):
    pass


def tailnet_address(text: str) -> str:
    """`text` when it is one tailnet address (100.64.0.0/10 or fd7a:115c:a1e0::/48); labd binds nothing else."""
    try:
        address = ipaddress.ip_address(text)
    except ValueError:
        raise LabdError(f"bind address {text!r} is not an IP address") from None
    if not any(address in network for network in TAILNETS):
        raise LabdError(f"bind address {text} is not a tailnet address; labd binds only this host's 100.x address")
    return str(address)


def discover_tailnet_address(run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> str:
    """This host's tailnet IPv4 address from `tailscale ip -4`."""
    try:
        done = run(["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LabdError(f"tailscale ip -4: {error}") from None
    lines = done.stdout.split() if done.returncode == 0 else []
    if not lines:
        raise LabdError(f"tailscale ip -4 gave no address: {done.stderr.strip()}")
    return tailnet_address(lines[0])


# ---------- caller identity ----------


@dataclass(frozen=True)
class Node:
    name: str  # the MagicDNS host label, lower case
    fqdn: str


def node_from_whois(text: str) -> Node | None:
    """The peer node of a `tailscale whois --json` answer; None when it names none."""
    try:
        name = json.loads(text)["Node"]["Name"]
    except (ValueError, TypeError, KeyError):
        return None
    if not isinstance(name, str) or not name.strip("."):
        return None
    fqdn = name.rstrip(".").lower()
    return Node(name=fqdn.split(".")[0], fqdn=fqdn)


Whois = Callable[[str], "Node | None"]


def tailscale_whois(address: str, *, run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> Node | None:
    """The tailnet node at `address`; None for a non-tailnet address or when tailscale does not know it."""
    try:
        if not any(ipaddress.ip_address(address) in network for network in TAILNETS):
            return None
        done = run(["tailscale", "whois", "--json", address], capture_output=True, text=True, timeout=5)
    except (ValueError, OSError, subprocess.TimeoutExpired):
        return None
    return node_from_whois(done.stdout) if done.returncode == 0 else None


@dataclass(frozen=True)
class Allowlist:
    """Who may write: the controller (both write endpoints) and lab hosts (/ingest, under their own name)."""

    controllers: frozenset[str]
    lab_hosts: frozenset[str]

    @classmethod
    def of(cls, controllers: Sequence[str], lab_hosts: Sequence[str]) -> "Allowlist":
        controller_names, lab_names = ([name.lower().rstrip(".") for name in names] for names in (controllers, lab_hosts))
        bad = [name for name in (*controller_names, *lab_names) if not NODE_NAME.match(name)]
        if bad:
            raise LabdError(f"not tailnet node names: {', '.join(bad)}")
        return cls(frozenset(controller_names), frozenset(lab_names))

    def role(self, node: Node | None) -> str | None:
        if node is None:
            return None
        for role, names in (("controller", self.controllers), ("lab-host", self.lab_hosts)):
            if node.name in names or node.fqdn in names:
                return role
        return None


# ---------- the scheduler driver (task 011) and the tip watcher ----------


class Driver(Protocol):
    """What labd feeds the scheduler (task 011): the big-branch tip and the controller's job callbacks."""

    name: str

    def tip_changed(self, sha: str) -> None: ...

    def job_finished(self, controller_job_id: str, state: str) -> None: ...


class IdleDriver:
    """No scheduler: labd stores results and job ends and plans nothing."""

    name = "idle"

    def tip_changed(self, sha: str) -> None:
        pass

    def job_finished(self, controller_job_id: str, state: str) -> None:
        pass


@dataclass(frozen=True)
class TipState:
    sha: str | None = None
    checked_at: str | None = None
    error: str | None = None


def _git(repo: Path, *args: str, timeout: float = 120) -> str:
    try:
        done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise LabdError(f"git {args[0]}: {error}") from None
    if done.returncode != 0:
        raise LabdError(f"git {args[0]}: {done.stderr.strip() or f'exit {done.returncode}'}")
    return done.stdout


@dataclass(frozen=True)
class GitBranch:
    """The branch labd follows in its lab checkout: `ls-remote` for the tip, a one-branch fetch when it moves."""

    repo: Path
    remote: str
    branch: str

    @property
    def mainline(self) -> str:
        return f"{self.remote}/{self.branch}"

    def tip(self) -> str:
        line = _git(self.repo, "ls-remote", "--exit-code", self.remote, f"refs/heads/{self.branch}", timeout=30)
        sha = line.split()[0] if line.split() else ""
        if not SHA.match(sha):
            raise LabdError(f"git ls-remote {self.remote} {self.branch}: no commit in {line!r}")
        return sha

    def fetch(self, sha: str) -> None:
        _git(self.repo, "fetch", "--no-tags", "--quiet", self.remote,
             f"+refs/heads/{self.branch}:refs/remotes/{self.remote}/{self.branch}")
        _git(self.repo, "cat-file", "-e", f"{sha}^{{commit}}")


class TipWatcher:
    """Reads the tip every `interval` seconds and on wake(); a moved tip is fetched, then handed to the driver.

    Wakes that arrive during a check coalesce into one more check, never a queue of them.
    """

    def __init__(self, *, tip: Callable[[], str], fetch: Callable[[str], None], driver: Driver,
                 clock: Callable[[], datetime], interval: float = TIP_INTERVAL_S) -> None:
        self._tip, self._fetch, self._driver, self._clock, self._interval = tip, fetch, driver, clock, interval
        self._wake = threading.Event()
        self._stop = threading.Event()
        self.state = TipState()

    def wake(self) -> None:
        self._wake.set()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()

    def check(self) -> TipState:
        checked = store._stamp(self._clock())
        try:
            sha = self._tip()
            if sha != self.state.sha:
                self._fetch(sha)
        except LabdError as error:
            self.state = replace(self.state, checked_at=checked, error=str(error))
            return self.state
        moved = sha != self.state.sha
        self.state = TipState(sha=sha, checked_at=checked)
        if moved:
            self._driver.tip_changed(sha)
        return self.state

    def run(self) -> None:
        while not self._stop.is_set():
            self._wake.clear()
            self.check()
            self._wake.wait(self._interval)


# ---------- the nightly backup ----------


@dataclass(frozen=True)
class BackupState:
    at: str | None = None
    sha256: str | None = None
    bytes: int | None = None
    key: str | None = None
    uploaded: bool | None = None  # False: the key already held these bytes; None: no R2 bucket configured
    error: str | None = None


class NightlyBackup:
    """A gzipped online copy of the store, kept as latest.sqlite3.gz and put to R2 at BACKUP_PREFIX/<sha256>."""

    def __init__(self, *, db_path: Path, directory: Path, bucket: "r2.R2Bucket | None",
                 clock: Callable[[], datetime], hour: int = BACKUP_HOUR, tz: tzinfo | None = None) -> None:
        self._db_path, self._directory, self._bucket = db_path, directory, bucket
        self._clock, self._hour, self._tz = clock, hour, tz
        self._stop = threading.Event()
        self.state = BackupState()

    def next_due(self, now: datetime) -> datetime:
        local = now.astimezone(self._tz)
        due = local.replace(hour=self._hour, minute=0, second=0, microsecond=0)
        return due if due > local else due + timedelta(days=1)

    def run_once(self) -> BackupState:
        at = store._stamp(self._clock())
        self._directory.mkdir(parents=True, exist_ok=True)
        try:
            with tempfile.TemporaryDirectory(dir=self._directory, prefix=".backup-") as scratch:
                copy, packed = Path(scratch) / DB_NAME, Path(scratch) / f"{DB_NAME}.gz"
                db = store.Store(self._db_path)
                try:
                    db.backup_to(copy)
                finally:
                    db.close()
                with open(copy, "rb") as source, open(packed, "wb") as raw, \
                        gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as target:
                    shutil.copyfileobj(source, target, 1 << 20)
                digest = r2.sha256_file(packed)
                key = f"{BACKUP_PREFIX}/{digest}.sqlite3.gz"
                uploaded = None if self._bucket is None else self._bucket.put_once(key, packed, sha256=digest)
                size = packed.stat().st_size
                os.replace(packed, self._directory / f"latest.{DB_NAME}.gz")
        except (OSError, store.StoreError, r2.R2Error, sqlite3.Error) as error:
            self.state = replace(self.state, at=at, error=str(error))
            return self.state
        self.state = BackupState(at=at, sha256=digest, bytes=size, key=key, uploaded=uploaded)
        return self.state

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        while True:
            now = self._clock()
            if self._stop.wait((self.next_due(now) - now).total_seconds()):
                return
            self.run_once()


# ---------- the service ----------


def rss_bytes() -> int:
    """This process's peak resident set (ru_maxrss is bytes on macOS, KiB on Linux)."""
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return peak if sys.platform == "darwin" else peak * 1024


class Reply(Exception):
    """An HTTP answer with a JSON body; raised by the service, written by the handler."""

    def __init__(self, status: HTTPStatus, body: object) -> None:
        super().__init__(status)
        self.status, self.body = status, body


def _refuse(status: HTTPStatus, reason: str) -> Reply:
    return Reply(status, {"error": reason})


def _rows(rows: Sequence[object]) -> list[dict[str, object]]:
    return [dict(row) for row in rows]


def _one(query: Mapping[str, list[str]], name: str) -> str | None:
    values = query.get(name, [])
    if len(values) > 1:
        raise _refuse(HTTPStatus.BAD_REQUEST, f"{name} is given more than once")
    return values[0] if values else None


def _limit(query: Mapping[str, list[str]], default: int) -> int:
    text = _one(query, "limit")
    if text is None:
        return default
    if not text.isdigit() or not 1 <= int(text) <= 1000:
        raise _refuse(HTTPStatus.BAD_REQUEST, "limit is 1..1000")
    return int(text)


@dataclass
class Labd:
    """What the endpoints do; the handler only parses HTTP, checks identity and calls one of these."""

    db_path: Path
    allowlist: Allowlist
    whois: Whois
    commit_positions: Callable[[], "ingest.CommitPositions"]
    driver: Driver
    tip: TipWatcher | None
    backup: NightlyBackup | None
    clock: Callable[[], datetime]
    version: str
    max_rss_bytes: int | None = None

    def __post_init__(self) -> None:
        self.started_at = store._stamp(self.clock())

    @contextmanager
    def open_store(self) -> Iterator["store.Store"]:
        db = store.Store(self.db_path)
        try:
            yield db
        finally:
            db.close()

    def caller_role(self, address: str) -> tuple[Node | None, str | None]:
        node = self.whois(address)
        return node, self.allowlist.role(node)

    # ----- read endpoints -----

    def status(self, query: Mapping[str, list[str]]) -> object:
        with self.open_store() as db:
            schema = db.schema_version()
        return {"service": LABEL, "version": self.version, "started_at": self.started_at, "schema_version": schema,
                "driver": self.driver.name, "tip": asdict(self.tip.state) if self.tip else None,
                "backup": asdict(self.backup.state) if self.backup else None,
                "rss_bytes": rss_bytes(), "max_rss_bytes": self.max_rss_bytes}

    def series(self, query: Mapping[str, list[str]]) -> object:
        key = _one(query, "key")
        with self.open_store() as db:
            if key is None:
                return {"series": _rows(db.list_series(story=_one(query, "story")))}
            return {"key": key, "points": [asdict(point) for point in db.series_points(key, limit=_limit(query, 50))],
                    "annotations": _rows(db.annotations(key))}

    def alerts(self, query: Mapping[str, list[str]]) -> object:
        states = [state for state in (_one(query, "state") or "").split(",") if state]
        unknown = sorted(set(states) - set(store.ALERT_GROUP_STATES))
        if unknown:
            raise _refuse(HTTPStatus.BAD_REQUEST, f"unknown states {unknown}")
        try:
            subscriptions = alerts.Subscriptions.load()
        except alerts.AlertsError as error:
            raise _refuse(HTTPStatus.INTERNAL_SERVER_ERROR, str(error)) from None
        with self.open_store() as db:
            return {"groups": alerts.list_groups(db, subscriptions, states)}

    def jobs(self, query: Mapping[str, list[str]]) -> object:
        with self.open_store() as db:
            return {"jobs": _rows(db.jobs(limit=_limit(query, 100)))}

    def coverage(self, query: Mapping[str, list[str]]) -> object:
        with self.open_store() as db:
            return {"coverage": _rows(db.coverage())}

    # ----- write endpoints -----

    def ingest(self, caller: Node, role: str, query: Mapping[str, list[str]], body: bytes) -> Reply:
        host = _one(query, "host")
        if role == "lab-host":
            if host not in (None, caller.name):
                raise _refuse(HTTPStatus.FORBIDDEN, f"lab host {caller.name} may ingest only its own results")
            host = caller.name
        elif host is not None and not NODE_NAME.match(host):
            raise _refuse(HTTPStatus.BAD_REQUEST, f"host {host!r} is not a node name")
        try:
            positions = self.commit_positions()
        except ingest.IngestError as error:
            raise _refuse(HTTPStatus.SERVICE_UNAVAILABLE, str(error)) from None
        with tempfile.TemporaryDirectory(prefix="labd-ingest-") as scratch:
            path = Path(scratch) / "body.ndjson"
            path.write_bytes(body)
            with self.open_store() as db:
                try:
                    report = ingest.ingest_paths(db, [path], commit_positions=positions, host_name=host,
                                                 kind=_one(query, "kind") or "waterfall", tier=_one(query, "tier"))
                except ingest.IngestError as error:
                    raise _refuse(HTTPStatus.BAD_REQUEST, str(error)) from None
        answer = {**report.to_dict(), "rejected": [
            {"source": r.source.replace(str(path), "body"), "reason": r.reason.replace(str(path), "body")}
            for r in report.rejected]}
        return Reply(HTTPStatus.UNPROCESSABLE_ENTITY if report.rejected else HTTPStatus.OK, answer)

    def job_finished(self, caller: Node, role: str, body: bytes) -> Reply:
        if role != "controller":
            raise _refuse(HTTPStatus.FORBIDDEN, f"{caller.name} is not the controller")
        try:
            event = json.loads(body)
        except ValueError:
            raise _refuse(HTTPStatus.BAD_REQUEST, "the body is not JSON") from None
        job_id = event.get("job_id") if isinstance(event, dict) else None
        state = event.get("state") if isinstance(event, dict) else None
        if not isinstance(job_id, str) or not JOB_ID.match(job_id):
            raise _refuse(HTTPStatus.BAD_REQUEST, "job_id is a controller job id")
        if not isinstance(state, str) or not JOB_STATE.match(state):
            raise _refuse(HTTPStatus.BAD_REQUEST, "state is a controller job state")
        with self.open_store() as db:
            known = db.finish_job(job_id, state=state, result=event.get("result"))
        self.driver.job_finished(job_id, state)
        if self.tip is not None:
            self.tip.wake()
        return Reply(HTTPStatus.OK, {"job_id": job_id, "known": known})


READS = {"/status": Labd.status, "/api/series": Labd.series, "/api/alerts": Labd.alerts, "/api/jobs": Labd.jobs,
         "/api/coverage": Labd.coverage}
WRITES = ("/ingest", "/hooks/job-finished")


class Handler(BaseHTTPRequestHandler):
    server_version = "cmux-perf-lab"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    timeout = 30  # a slow or stalled client gives its thread back

    @property
    def app(self) -> Labd:
        return self.server.app

    def _send(self, reply: Reply) -> None:
        data = json.dumps(reply.body, indent=1, sort_keys=True, default=str).encode() + b"\n"
        self.send_response(reply.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _answer(self, work: Callable[[], Reply]) -> None:
        try:
            reply = work()
        except Reply as raised:
            reply = raised
        except (store.StoreError, sqlite3.Error) as error:
            reply = _refuse(HTTPStatus.INTERNAL_SERVER_ERROR, str(error))
        self._send(reply)

    def do_GET(self) -> None:
        url = urlsplit(self.path)
        read = READS.get(url.path)
        if read is None:
            self.close_connection = True
            self._send(_refuse(HTTPStatus.NOT_FOUND, f"no endpoint {url.path}"))
            return
        self._answer(lambda: Reply(HTTPStatus.OK, read(self.app, parse_qs(url.query))))

    def do_POST(self) -> None:
        self.close_connection = True  # a refused body is never read, so the connection cannot be reused
        self._answer(self._post)

    def _post(self) -> Reply:
        url = urlsplit(self.path)
        if url.path not in WRITES:
            raise _refuse(HTTPStatus.NOT_FOUND, f"no endpoint {url.path}")
        caller, role = self.app.caller_role(self.client_address[0])
        if role is None:
            who = caller.fqdn if caller else self.client_address[0]
            raise _refuse(HTTPStatus.FORBIDDEN, f"{who} is not on labd's write allowlist")
        length = self.headers.get("Content-Length")
        if length is None or self.headers.get("Transfer-Encoding"):
            raise _refuse(HTTPStatus.LENGTH_REQUIRED, "a POST needs a Content-Length body")
        if not length.isdigit():
            raise _refuse(HTTPStatus.BAD_REQUEST, "Content-Length is not a number")
        if int(length) > MAX_BODY_BYTES:
            raise _refuse(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, f"bodies are at most {MAX_BODY_BYTES} bytes")
        body = self.rfile.read(int(length))
        if url.path == "/ingest":
            return self.app.ingest(caller, role, parse_qs(url.query), body)
        return self.app.job_finished(caller, role, body)


class LabServer(ThreadingHTTPServer):
    """The HTTP server; `bind_policy` (tailnet_address in labd serve) decides which addresses it may bind."""

    daemon_threads = True

    def __init__(self, address: str, port: int, app: Labd, *,
                 bind_policy: Callable[[str], str] = tailnet_address) -> None:
        host = bind_policy(address)
        self.address_family = socket.AF_INET6 if ":" in host else socket.AF_INET
        self.app = app
        self.over_memory = False
        super().__init__((host, port), Handler)

    def process_request_thread(self, request, client_address) -> None:
        super().process_request_thread(request, client_address)
        limit = self.app.max_rss_bytes
        if limit is not None and not self.over_memory and rss_bytes() > limit:
            self.over_memory = True
            print(f"labd: peak RSS {rss_bytes()} passed {limit} bytes; exiting for launchd to restart",
                  file=sys.stderr)
            self.shutdown()


# ---------- command line ----------


def render_plist(template: Path, *, sha: str, release: Path, data_dir: Path, repo: Path, python: str,
                 controllers: Sequence[str], lab_hosts: Sequence[str], branch: str, log_dir: Path) -> bytes:
    """The launchd job for one pinned release: the template's limits, this release's labd and arguments."""
    if not SHA.match(sha):
        raise LabdError(f"--sha {sha!r} is not a full commit sha")
    Allowlist.of(controllers, lab_hosts)
    with open(template, "rb") as handle:
        job = plistlib.load(handle)
    limit = job.get("SoftResourceLimits", {}).get("ResidentSetSize")
    if job.get("ProcessType") != "Background" or job.get("Nice") != 10 or not isinstance(limit, int):
        raise LabdError(f"{template}: needs ProcessType Background, Nice 10 and SoftResourceLimits.ResidentSetSize")
    arguments = [python, "-I", str(release / "scripts" / "perf-lab" / "labd.py"), "serve", "--version", sha,
                 "--data-dir", str(data_dir), "--repo", str(repo), "--branch", branch,
                 "--max-rss-mb", str(limit >> 20)]
    for flag, names in (("--controller", controllers), ("--lab-host", lab_hosts)):
        for name in names:
            arguments += [flag, name]
    job.update(ProgramArguments=arguments, WorkingDirectory=str(data_dir),
               StandardOutPath=str(log_dir / f"{LABEL}.log"), StandardErrorPath=str(log_dir / f"{LABEL}.log"))
    return plistlib.dumps(job, sort_keys=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="labd.py", description="The cmux perf lab service.")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("serve", "render-plist"):
        command = commands.add_parser(name)
        command.add_argument("--data-dir", type=Path, default=DATA_DIR)
        command.add_argument("--repo", type=Path, help="the lab's git checkout (default DATA_DIR/repo)")
        command.add_argument("--branch", default=DEFAULT_BRANCH, help="the big branch the lab follows")
        command.add_argument("--controller", action="append", default=[], help="controller node (repeat)")
        command.add_argument("--lab-host", action="append", default=[], help="lab host node (repeat)")
    serve = commands.choices["serve"]
    serve.add_argument("--bind", help="this host's tailnet address (default: tailscale ip -4)")
    serve.add_argument("--port", type=int, default=DEFAULT_PORT)
    serve.add_argument("--remote", default="origin")
    serve.add_argument("--version", default="unknown", help="the deployed sha (deploy.sh sets it)")
    serve.add_argument("--max-rss-mb", type=int, help="exit once peak RSS passes this many MiB")
    render = commands.choices["render-plist"]
    render.add_argument("--sha", required=True)
    render.add_argument("--release", type=Path, required=True, help="the checkout of --sha labd runs from")
    render.add_argument("--python", default=sys.executable)
    render.add_argument("--log-dir", type=Path, default=Path.home() / "Library" / "Logs")
    render.add_argument("--template", type=Path, default=PLIST_TEMPLATE)
    return parser


def serve(args: argparse.Namespace) -> int:
    clock = lambda: datetime.now(timezone.utc)
    data_dir: Path = args.data_dir
    data_dir.mkdir(parents=True, exist_ok=True)
    db_path = data_dir / DB_NAME
    branch = GitBranch(args.repo or data_dir / "repo", args.remote, args.branch)
    db = store.Store(db_path)
    try:
        db.migrate()
    finally:
        db.close()
    driver = IdleDriver()
    tip = TipWatcher(tip=branch.tip, fetch=branch.fetch, driver=driver, clock=clock)
    backup = NightlyBackup(db_path=db_path, directory=data_dir / "backups", bucket=r2.R2Bucket.from_env(),
                           clock=clock)
    app = Labd(db_path=db_path, allowlist=Allowlist.of(args.controller, args.lab_host), whois=tailscale_whois,
               commit_positions=lambda: ingest.GitCommitPositions(branch.repo, mainline=branch.mainline),
               driver=driver, tip=tip, backup=backup, clock=clock, version=args.version,
               max_rss_bytes=args.max_rss_mb << 20 if args.max_rss_mb else None)
    server = LabServer(args.bind or discover_tailnet_address(), args.port, app)
    workers = [threading.Thread(target=worker.run, name=f"labd-{name}", daemon=True)
               for name, worker in (("tip", tip), ("backup", backup))]
    for worker in workers:
        worker.start()
    print(f"labd {args.version} on http://{server.server_address[0]}:{server.server_address[1]}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        tip.stop()
        backup.stop()
        server.server_close()
    return EX_TEMPFAIL if server.over_memory else 0


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "render-plist":
            sys.stdout.buffer.write(render_plist(
                args.template, sha=args.sha, release=args.release, data_dir=args.data_dir,
                repo=args.repo or args.data_dir / "repo", python=args.python, controllers=args.controller,
                lab_hosts=args.lab_host, branch=args.branch, log_dir=args.log_dir))
            return 0
        return serve(args)
    except (LabdError, store.StoreError, r2.R2Error, OSError) as error:
        print(f"labd.py {args.command}: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
