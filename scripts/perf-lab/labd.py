#!/usr/bin/env python3
"""labd: the perf lab's service on cmux-lawrence, beside the controller (p12-perf-process.md 3.5, decision D1).

    python3 -I scripts/perf-lab/labd.py serve --controller NODE [--lab-host NODE ...] [--submit-command PATH]
    python3 -I scripts/perf-lab/labd.py render-plist --sha SHA --release DIR --controller NODE ...  (deploy.sh)

A stdlib `http.server` bound only to this host's tailnet address; 0.0.0.0, loopback and any other non-tailnet
address are refused (`tailnet_address`).

- GET /status, /api/series, /api/alerts, /api/jobs, /api/coverage are open to the tailnet.
- POST /ingest (a result-v1 .ndjson body) and POST /hooks/job-finished (the controller's callback) need a caller
  that `tailscale whois` names by a full MagicDNS name on the allowlist: the controller, or a lab host for /ingest
  (under its own name; only the controller may name another host). The allowlist holds names in this host's own
  tailnet only, so a node shared in from another tailnet never matches. This host's own tailnet address is refused,
  as the home server refuses it (backend/apps/home-server/src/admission.ts): every OS user here can reach it. The
  controller on this host posts to the Unix socket DATA_DIR/labd.sock instead (`LocalServer`).
- A POST body needs a Content-Length of at most 1 MiB; a larger one is refused before it is read.

Handlers are thin calls into store.py, ingest.py, alerts.py and the scheduler's Driver (scheduler.py, task 011). A
`Worker` thread runs Driver.tick every POLL_SECONDS and right after a job-finished callback, with --submit-command
as its submit callback; the Driver reads the tip with `git ls-remote` and fetches only that branch into
refs/perf-lab/BRANCH, which ingest also orders commits by. Without --submit-command the scheduler does not run and
/status answers 503 saying so. A canary run in progress (canary.py) is a side lane: its DATA_DIR/canary/<run>/
lane.json gives the Driver the lane's T0 rounds, and /ingest stores a body of the lane's commits in the lane's own
store, ordered on the lane's ref, never in the lab's. SQLite (WAL) lives in
~/Library/Application Support/cmux-perf-lab; each request opens its own connection, as store.Store requires. Every
night a gzipped online copy goes to R2 under its sha256 through scripts/ci/upload-r2-object.py --write-once.

launchd runs it (com.cmux.perf-lab.plist) with ProcessType=Background and Nice 10. macOS does not enforce the
plist's ResidentSetSize, so labd exits with EX_TEMPFAIL once its peak RSS passes that limit and launchd starts it
again. Stdlib only; loads its siblings by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import importlib.util
import ipaddress
import json
import os
import plistlib
import queue
import re
import resource
import shutil
import socket
import socketserver
import sqlite3
import subprocess
import sys
import tempfile
import threading
import traceback
from collections.abc import Callable, Iterator, Mapping, Sequence
from contextlib import contextmanager
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone, tzinfo
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]


def _sibling(name: str, path: Path):
    """The module at `path` as perf_lab_<name>, once per process (the names the siblings themselves use)."""
    module_name = f"perf_lab_{name}"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or not path.is_file():
        raise ImportError(f"labd: no module at {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module  # before exec: a dataclass resolves its module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[module_name]
        raise
    return module


store = _sibling("store", HERE / "store.py")
ingest = _sibling("ingest", HERE / "ingest.py")
alerts = _sibling("alerts", HERE / "alerts.py")
harness_alerts = _sibling("harness_alerts", HERE / "harness_alerts.py")

LABEL = "com.cmux.perf-lab"
PLIST_TEMPLATE = HERE / f"{LABEL}.plist"
DATA_DIR = Path.home() / "Library" / "Application Support" / "cmux-perf-lab"
DB_NAME = "lab.sqlite3"
SOCKET_NAME = "labd.sock"
DEFAULT_PORT = 18766  # the controller listens on 18765 on the same host
DEFAULT_BRANCH = "feat-cmux-next"
MAX_BODY_BYTES = 1 << 20
PLAN_STALE = timedelta(minutes=10)  # 60 s ticks; a tick may spend 300 s in its one-branch fetch
BACKUP_HOUR = 3  # local time
BACKUP_STALE = timedelta(days=2)
BACKUP_PREFIX = "perf-lab/backups/sha256"
R2_ENV_FILE = Path.home() / ".secrets" / "cmux-perf-lab.env"
R2_ENV = ("CMUX_PERF_LAB_R2_ENDPOINT", "CMUX_PERF_LAB_R2_BUCKET", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY")
UPLOADER = REPO_ROOT / "scripts" / "ci" / "upload-r2-object.py"
EX_TEMPFAIL = 75  # sysexits.h: launchd's KeepAlive starts labd again
TAILNETS = (ipaddress.ip_network("100.64.0.0/10"), ipaddress.ip_network("fd7a:115c:a1e0::/48"))
SHA = re.compile(r"^[0-9a-f]{40}$")
NODE_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*(\.[a-z0-9-]+)*$")
JOB_STATE = re.compile(r"^[a-z][a-z_-]{0,31}$")
JOB_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
DIGITS = re.compile(r"[0-9]{1,9}")  # ASCII only: str.isdigit() also takes '²', which int() refuses


class LabdError(RuntimeError):
    pass


def _failure(error: BaseException) -> str:
    return f"{type(error).__name__}: {error}"


def tailnet_address(text: str) -> str:
    """`text` when it is one tailnet address (100.64.0.0/10 or fd7a:115c:a1e0::/48); labd binds nothing else."""
    try:
        address = ipaddress.ip_address(text)
    except ValueError:
        raise LabdError(f"bind address {text!r} is not an IP address") from None
    if not any(address in network for network in TAILNETS):
        raise LabdError(f"bind address {text} is not a tailnet address; labd binds only this host's 100.x address")
    return str(address)


def tailnet_self(run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> tuple[str, str]:
    """This host's tailnet IPv4 address and full MagicDNS name, from `tailscale status --json`."""
    try:
        done = run(["tailscale", "status", "--json", "--peers=false"], capture_output=True, text=True, timeout=10)
        me = json.loads(done.stdout)["Self"]
        fqdn = me["DNSName"].rstrip(".").lower()
        addresses = [a for a in me["TailscaleIPs"] if ipaddress.ip_address(a).version == 4]
    except (OSError, subprocess.TimeoutExpired, ValueError, TypeError, KeyError, AttributeError) as error:
        raise LabdError(f"tailscale status --json: {_failure(error)}") from None
    if "." not in fqdn or not addresses:
        raise LabdError(f"tailscale status --json: no MagicDNS name or IPv4 address for this host ({fqdn!r})")
    return tailnet_address(addresses[0]), fqdn


# ---------- caller identity ----------


@dataclass(frozen=True)
class Node:
    name: str  # the MagicDNS host label, lower case: the store's host name
    fqdn: str  # the full MagicDNS name: the identity


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


def check_node_names(names: Sequence[str]) -> list[str]:
    cleaned = [name.lower().rstrip(".") for name in names]
    bad = [name for name in cleaned if not NODE_NAME.match(name)]
    if bad:
        raise LabdError(f"not tailnet node names: {', '.join(bad)}")
    return cleaned


@dataclass(frozen=True)
class Allowlist:
    """Who may write, by full MagicDNS name in this host's tailnet: the controller (both write endpoints) and lab
    hosts (/ingest, under their own name). A bare label is qualified with `domain`; any other domain is refused."""

    controllers: frozenset[str]
    lab_hosts: frozenset[str]

    @classmethod
    def of(cls, controllers: Sequence[str], lab_hosts: Sequence[str], *, domain: str) -> "Allowlist":
        def qualify(name: str) -> str:
            fqdn = name if "." in name else f"{name}.{domain}"
            if not fqdn.endswith(f".{domain}"):
                raise LabdError(f"{name} is not in this host's tailnet ({domain})")
            return fqdn

        return cls(*(frozenset(qualify(name) for name in check_node_names(names)) for names in (controllers, lab_hosts)))

    def role(self, node: Node | None) -> str | None:
        if node is None:
            return None
        if node.fqdn in self.controllers:
            return "controller"
        return "lab-host" if node.fqdn in self.lab_hosts else None


# ---------- background workers ----------


@dataclass
class Worker:
    """Runs `step` after `delay(now)` seconds, again and again, and at once on wake(); wakes that arrive during a
    step coalesce into one more step. A failing step never ends the thread: its error and time stay in `report`,
    and the step runs again on time. Unhealthy once the last success is older than `stale`."""

    name: str
    step: Callable[[], object]
    delay: Callable[[datetime], float]
    stale: timedelta
    clock: Callable[[], datetime]
    ok_at: datetime | None = None
    detail: object = None
    error: str | None = None
    error_at: datetime | None = None
    _wake: threading.Event = field(default_factory=threading.Event)
    _stopped: bool = False

    def __post_init__(self) -> None:
        self.started_at = self.clock()

    def wake(self) -> None:
        self._wake.set()

    def stop(self) -> None:
        self._stopped = True
        self._wake.set()

    def run_once(self) -> None:
        try:
            detail = self.step()
        except Exception as error:  # noqa: BLE001 - any failure is reported in /status and the next step runs
            self.error, self.error_at = _failure(error), self.clock()
            return
        self.ok_at, self.detail, self.error, self.error_at = self.clock(), detail, None, None

    def run(self) -> None:
        while True:
            self._wake.wait(max(0.0, self.delay(self.clock())))
            self._wake.clear()
            if self._stopped:
                return
            self.run_once()

    def report(self, now: datetime) -> dict[str, object]:
        healthy = self.error is None and now - (self.ok_at or self.started_at) <= self.stale
        return {"healthy": healthy, "ok_at": self.ok_at and store._stamp(self.ok_at), "detail": self.detail,
                "error": self.error, "error_at": self.error_at and store._stamp(self.error_at)}


class PlanLoop:
    """One scheduler step: apply the controller's finished jobs, then Driver.tick (task 011), which hands the plan
    to `submit` and saves its state only after submit returns what it could not hand on (scheduler.Rejected).

    The Driver is not thread-safe, so only the worker's thread touches it: a callback only queues its job id."""

    def __init__(self, driver, *, hosts: Callable[[], Sequence], builds: Callable[[], object],
                 submit: Callable[[object], object], lanes: Callable[[], Sequence] = lambda: ()) -> None:
        self._driver, self._hosts, self._builds, self._submit = driver, hosts, builds, submit
        self._lanes = lanes  # the side lanes (scheduler.Lane) of the canary runs in progress
        self._finished: queue.SimpleQueue[str] = queue.SimpleQueue()

    def job_finished(self, job_id: str) -> None:
        self._finished.put(job_id)

    def step(self) -> dict[str, object]:
        while True:
            try:
                job_id = self._finished.get_nowait()
            except queue.Empty:
                break
            self._driver.job_finished(job_id)
        lanes = tuple(lane.lane for lane in self._lanes())
        plan = self._driver.tick(self._hosts(), self._builds(), submit=self._submit, lanes=lanes)
        return {"tip": self._driver.tip, "mode": plan.mode, "jobs": len(plan.jobs), "builds": len(plan.builds),
                "gaps": len(plan.gaps), "skipped": len(plan.skipped), "problems": list(plan.problems)}


def command_submitter(program: Path, rejected: Callable[..., object]) -> Callable[[object], object]:
    """Hands each plan (Plan.to_document() JSON on stdin) to the program that starts its jobs and builds; it prints
    {"jobs": [ids], "arms": [features], "builds": [[sha, config]]} it could not hand on, or nothing. A refused build
    is asked for again on the next tick. A failure raises, so the Driver keeps its previous state and the next tick
    plans the same work again.

    A job whose `lane` is set measures a side lane (canary.py). The program runs it as any T0 job and its host
    posts the results to /ingest as usual: labd stores a body whose commits are a lane's in that lane's store, so
    the program needs nothing more for it."""
    def submit(plan) -> object:
        try:
            done = subprocess.run([str(program)], input=json.dumps(plan.to_document()), capture_output=True,
                                  text=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise LabdError(f"{program}: {error}") from None
        if done.returncode != 0:
            raise LabdError(f"{program} exited {done.returncode}: {done.stderr.strip()[-500:]}")
        try:
            answer = json.loads(done.stdout) if done.stdout.strip() else {}
            builds = frozenset((str(sha), str(config)) for sha, config in answer.get("builds", ()))
            return rejected(jobs=frozenset(map(str, answer.get("jobs", ()))),
                            arms=frozenset(map(str, answer.get("arms", ()))), builds=builds)
        except (ValueError, TypeError, AttributeError) as error:
            raise LabdError(f"{program}: its answer is not {{jobs, arms, builds}} JSON ({error})") from None

    return submit


def ledger_builds(scheduler, builds, ledger: Path):
    """scheduler.Builds from the lab's build ledger (builds.py, task 009): every ok record is a ready build."""
    ready = set()
    for path in sorted((ledger / "records").glob("*.json")):
        record = builds.BuildRecord.from_json(json.loads(path.read_text(encoding="utf-8")))
        if record.status == "ok":
            ready.add((record.sha, record.config))
    return scheduler.Builds(ready=frozenset(ready))


def next_backup_delay(now: datetime, *, hour: int = BACKUP_HOUR, tz: tzinfo | None = None) -> float:
    local = now.astimezone(tz)
    due = local.replace(hour=hour, minute=0, second=0, microsecond=0)
    return ((due if due > local else due + timedelta(days=1)) - local).total_seconds()


def read_r2_env(path: Path = R2_ENV_FILE) -> dict[str, str] | None:
    """R2_ENV from NAME=value lines of the operator's secrets file; None when it is missing or incomplete."""
    values = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return None
    for line in lines:
        name, sep, value = line.strip().removeprefix("export ").partition("=")
        if sep and name in R2_ENV:
            values[name] = value.strip().strip("\"'")
    return values if all(values.get(name) for name in R2_ENV) else None


def r2_upload(path: Path, key: str, config: Mapping[str, str], *,
              run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> None:
    """Puts `path` at `key`, write-once, with the repo's one R2 uploader; the keys travel in its environment."""
    done = run([sys.executable, "-I", str(UPLOADER), "--file", str(path), "--write-once",
                "--endpoint-url", config["CMUX_PERF_LAB_R2_ENDPOINT"], "--bucket", config["CMUX_PERF_LAB_R2_BUCKET"],
                "--key", key, "--cache-control", "no-store", "--content-type", "application/gzip"],
               capture_output=True, text=True, timeout=600,
               env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "AWS_DEFAULT_REGION": "auto",
                    "AWS_ACCESS_KEY_ID": config["AWS_ACCESS_KEY_ID"],
                    "AWS_SECRET_ACCESS_KEY": config["AWS_SECRET_ACCESS_KEY"]})
    if done.returncode != 0:
        raise LabdError(f"upload-r2-object.py exited {done.returncode}: {done.stderr.strip()[-500:]}")


def backup_step(db_path: Path, directory: Path, upload: Callable[[Path, str], None] | None) -> Callable[[], dict]:
    """A gzipped online copy of the store, kept as latest.lab.sqlite3.gz and put at BACKUP_PREFIX/<sha256>."""
    def step() -> dict[str, object]:
        directory.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=directory, prefix=".backup-") as scratch:
            copy, packed = Path(scratch) / DB_NAME, Path(scratch) / f"{DB_NAME}.gz"
            db = store.Store(db_path)
            try:
                db.backup_to(copy)
            finally:
                db.close()
            digest = hashlib.sha256()
            with open(copy, "rb") as source, open(packed, "wb") as raw, \
                    gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as target:
                shutil.copyfileobj(source, target, 1 << 20)
            with open(packed, "rb") as handle:
                for chunk in iter(lambda: handle.read(1 << 20), b""):
                    digest.update(chunk)
            key = f"{BACKUP_PREFIX}/{digest.hexdigest()}.sqlite3.gz"
            if upload is not None:
                upload(packed, key)
            size = packed.stat().st_size
            os.replace(packed, directory / f"latest.{DB_NAME}.gz")
        return {"key": key, "bytes": size, "r2": "uploaded" if upload else f"not configured ({R2_ENV_FILE})"}

    return step


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
    if not DIGITS.fullmatch(text) or not 1 <= int(text) <= 1000:
        raise _refuse(HTTPStatus.BAD_REQUEST, "limit is 1..1000")
    return int(text)


@dataclass
class Labd:
    """What the endpoints do; the handler only parses HTTP, checks identity and calls one of these."""

    db_path: Path
    allowlist: Allowlist
    whois: Whois
    self_fqdn: str
    commit_positions: Callable[[], "ingest.CommitPositions"]
    plan: PlanLoop | None
    workers: Mapping[str, Worker]
    clock: Callable[[], datetime]
    version: str
    scheduler_off: str | None = None  # why the scheduler does not run
    max_rss_bytes: int | None = None
    # The side lanes of canary runs in progress (canary.LaneDocument: name, commits, mainline, store) and the commit
    # positions on a lane's mainline ref.
    lanes: Callable[[], Sequence] = lambda: ()
    lane_positions: Callable[[str], "ingest.CommitPositions"] | None = None

    def __post_init__(self) -> None:
        self.started_at = store._stamp(self.clock())

    @contextmanager
    def open_store(self, path: Path | None = None) -> Iterator["store.Store"]:
        db = store.Store(path or self.db_path)
        try:
            yield db
        finally:
            db.close()

    def lane_of(self, path: Path):
        """The side lane whose commits the result file at `path` measures, or None for the lab's own store. A body
        that mixes a lane's commits with any other commit is refused: a run is stored whole, in one store."""
        lanes = self.lanes()
        if not lanes:
            return None
        try:
            shas = {result.build.sha for result in ingest.perf_result.read_file(path)}
        except ingest.perf_result.ResultError:
            return None  # the lab's ingest names what is wrong with the file
        for lane in lanes:
            inside = shas & lane.commits
            if inside and inside != shas:
                raise _refuse(HTTPStatus.BAD_REQUEST, f"the body mixes commits of lane {lane.name} with others")
            if inside:
                return lane
        return None

    def caller(self, address: str) -> tuple[Node, str]:
        """The caller's node and write role at a tailnet peer address, or a 403."""
        node = self.whois(address)
        if node is not None and node.fqdn == self.self_fqdn:
            raise _refuse(HTTPStatus.FORBIDDEN, f"{address} is this host's own tailnet address, open to every OS "
                                                f"user here; post to the Unix socket {SOCKET_NAME} instead")
        role = self.allowlist.role(node)
        if node is None or role is None:
            raise _refuse(HTTPStatus.FORBIDDEN, f"{node.fqdn if node else address} is not on labd's write allowlist")
        return node, role

    # ----- read endpoints -----

    def status(self, query: Mapping[str, list[str]]) -> Reply:
        now = self.clock()
        with self.open_store() as db:
            schema = db.schema_version()
        workers = {name: worker.report(now) for name, worker in self.workers.items()}
        problems = [f"{name}: {report['error'] or 'no success since ' + str(report['ok_at'] or self.started_at)}"
                    for name, report in workers.items() if not report["healthy"]]
        if self.scheduler_off:
            problems.insert(0, f"scheduler: {self.scheduler_off}")
        body = {"service": LABEL, "version": self.version, "started_at": self.started_at, "schema_version": schema,
                "workers": workers, "ok": not problems, "problems": problems, "rss_bytes": rss_bytes(),
                "max_rss_bytes": self.max_rss_bytes}
        return Reply(HTTPStatus.SERVICE_UNAVAILABLE if problems else HTTPStatus.OK, body)

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
            broken = harness_alerts.broken_stories(db._db)
            return {"coverage": _rows(db.coverage()), "harness_broken": [
                {"story": b.story, "host_class": b.host_class, "start_pos": b.start_pos, "end_pos": b.end_pos,
                 "errored_batches": b.errored_batches, "reason": b.last_error.reason} for b in broken.values()]}

    # ----- write endpoints -----

    def ingest(self, caller: Node, role: str, query: Mapping[str, list[str]], body: bytes) -> Reply:
        host = _one(query, "host")
        if role == "lab-host":
            if host not in (None, caller.name):
                raise _refuse(HTTPStatus.FORBIDDEN, f"lab host {caller.name} may ingest only its own results")
            host = caller.name
        elif host is not None and not NODE_NAME.match(host):
            raise _refuse(HTTPStatus.BAD_REQUEST, f"host {host!r} is not a node name")
        with tempfile.TemporaryDirectory(prefix="labd-ingest-") as scratch:
            path = Path(scratch) / "body.ndjson"
            path.write_bytes(body)
            lane = self.lane_of(path)
            try:
                positions = self.commit_positions() if lane is None else self.lane_positions(lane.mainline)
            except ingest.IngestError as error:
                raise _refuse(HTTPStatus.SERVICE_UNAVAILABLE, str(error)) from None
            with self.open_store(None if lane is None else lane.store) as db:
                if lane is not None:
                    db.migrate()  # the canary migrates its lane store too; this one is idempotent
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
            raise _refuse(HTTPStatus.FORBIDDEN, f"{caller.fqdn} is not the controller")
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
        if self.plan is not None:
            self.plan.job_finished(job_id)  # applied by the scheduler worker, which this wakes
            self.workers["scheduler"].wake()
        return Reply(HTTPStatus.OK, {"job_id": job_id, "known": known, "scheduler": self.plan is not None})


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

    def address_string(self) -> str:
        return self.client_address[0] if isinstance(self.client_address, tuple) else SOCKET_NAME

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
        except Exception as error:  # noqa: BLE001 - every request gets an HTTP answer, never a dropped connection
            self.log_error("%s", traceback.format_exc())
            reply = _refuse(HTTPStatus.INTERNAL_SERVER_ERROR, _failure(error))
        self._send(reply)

    def do_GET(self) -> None:
        url = urlsplit(self.path)
        read = READS.get(url.path)
        if read is None:
            self.close_connection = True
            self._send(_refuse(HTTPStatus.NOT_FOUND, f"no endpoint {url.path}"))
            return

        def work() -> Reply:
            answer = read(self.app, parse_qs(url.query))
            return answer if isinstance(answer, Reply) else Reply(HTTPStatus.OK, answer)

        self._answer(work)

    def do_POST(self) -> None:
        self.close_connection = True  # a refused body is never read, so the connection cannot be reused
        self._answer(self._post)

    def _post(self) -> Reply:
        url = urlsplit(self.path)
        if url.path not in WRITES:
            raise _refuse(HTTPStatus.NOT_FOUND, f"no endpoint {url.path}")
        if self.server.local:
            caller, role = Node(self.app.self_fqdn.split(".")[0], self.app.self_fqdn), "controller"
        else:
            caller, role = self.app.caller(self.client_address[0])
        length = self.headers.get("Content-Length")
        if length is None or self.headers.get("Transfer-Encoding"):
            raise _refuse(HTTPStatus.LENGTH_REQUIRED, "a POST needs a Content-Length body")
        if not DIGITS.fullmatch(length):
            raise _refuse(HTTPStatus.BAD_REQUEST, "Content-Length is not a number")
        if int(length) > MAX_BODY_BYTES:
            raise _refuse(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, f"bodies are at most {MAX_BODY_BYTES} bytes")
        body = self.rfile.read(int(length))
        if url.path == "/ingest":
            return self.app.ingest(caller, role, parse_qs(url.query), body)
        return self.app.job_finished(caller, role, body)


class LabServer(ThreadingHTTPServer):
    """The tailnet HTTP server; `bind_policy` (tailnet_address in labd serve) decides which addresses it may bind."""

    daemon_threads = True
    local = False

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


class LocalServer(socketserver.ThreadingUnixStreamServer):
    """The controller on this host posts here. The socket is 0600 in labd's 0700 data directory, so only labd's
    own OS user connects, and that user can already write the database file."""

    daemon_threads = True
    local = True

    def __init__(self, path: Path, app: Labd) -> None:
        self.app = app
        path.unlink(missing_ok=True)
        previous = os.umask(0o177)  # set before any worker thread starts
        try:
            super().__init__(str(path), Handler)
        finally:
            os.umask(previous)


# ---------- command line ----------


def render_plist(template: Path, *, sha: str, release: Path, data_dir: Path, repo: Path, python: str,
                 controllers: Sequence[str], lab_hosts: Sequence[str], branch: str, log_dir: Path,
                 submit_command: Path | None = None) -> bytes:
    """The launchd job for one pinned release: the template's limits, this release's labd and arguments."""
    if not SHA.match(sha):
        raise LabdError(f"--sha {sha!r} is not a full commit sha")
    check_node_names([*controllers, *lab_hosts])
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
    if submit_command is not None:
        arguments += ["--submit-command", str(submit_command)]
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
        command.add_argument("--submit-command", type=Path,
                             help="program that starts a plan's jobs and builds (the plan JSON on stdin)")
    serve = commands.choices["serve"]
    serve.add_argument("--bind", help="this host's tailnet address (default: from tailscale status)")
    serve.add_argument("--port", type=int, default=DEFAULT_PORT)
    serve.add_argument("--remote", default="origin")
    serve.add_argument("--pool", type=Path, default=HERE / "pool.json", help="the lab hosts (task 130)")
    serve.add_argument("--version", default="unknown", help="the deployed sha (deploy.sh sets it)")
    serve.add_argument("--max-rss-mb", type=int, help="exit once peak RSS passes this many MiB")
    render = commands.choices["render-plist"]
    render.add_argument("--sha", required=True)
    render.add_argument("--release", type=Path, required=True, help="the checkout of --sha labd runs from")
    render.add_argument("--python", default=sys.executable)
    render.add_argument("--log-dir", type=Path, default=Path.home() / "Library" / "Logs")
    render.add_argument("--template", type=Path, default=PLIST_TEMPLATE)
    return parser


def load_scheduler():
    """scheduler.py (task 011) and its Driver; labd never runs without the scheduler it feeds."""
    try:
        return _sibling("scheduler", HERE / "scheduler.py"), _sibling("builds", HERE / "builds.py")
    except ImportError as error:
        raise LabdError(f"{error}: labd needs the scheduler (task 011) and the build ledger (task 009)") from None


def plan_driver(scheduler, state_path: Path, *, ls_remote: Callable[[], str | None],
                first_parent: Callable[[str | None, str], object], clock: Callable[[], datetime],
                root: Path = REPO_ROOT):
    """scheduler.Driver on the checkout at `root`: its story catalog, its shard map and its expectations.json, which
    the Driver reads again for every plan (task 023), so an entry skips its story x host-class pair until it expires."""
    catalog = scheduler._load_sibling("catalog")
    expectations = scheduler._load_sibling("expectations")
    try:
        return scheduler.Driver(
            state_path, stories=scheduler.stories_from_catalog(catalog.load_catalog(root)),
            shard_map=scheduler.ShardMap.load(root / "scripts" / "perf-lab" / "shard_map.json"),
            ls_remote=ls_remote, first_parent=first_parent, clock=clock,
            expectations=lambda now: expectations.active_at(root / expectations.EXPECTATIONS_PATH, now))
    except (scheduler.SchedulerError, catalog.CatalogError) as error:
        raise LabdError(f"scheduler: {error}") from None


def serve(args: argparse.Namespace) -> int:
    clock = lambda: datetime.now(timezone.utc)
    bind = args.bind and tailnet_address(args.bind)
    scheduler, builds = load_scheduler()
    data_dir: Path = args.data_dir
    data_dir.mkdir(parents=True, exist_ok=True)
    data_dir.chmod(0o700)
    db_path, repo = data_dir / DB_NAME, args.repo or data_dir / "repo"
    address, self_fqdn = tailnet_self()
    allowlist = Allowlist.of(args.controller, args.lab_host, domain=self_fqdn.partition(".")[2])
    db = store.Store(db_path)
    try:
        db.migrate()
    finally:
        db.close()
    driver = plan_driver(scheduler, data_dir / "scheduler.json", clock=clock,
                         ls_remote=lambda: scheduler.git_ls_remote(args.remote, args.branch, repo=repo),
                         first_parent=scheduler.git_first_parent(args.remote, args.branch, repo=repo))
    canary = _sibling("canary", HERE / "canary.py")
    lanes = lambda: canary.lane_documents(data_dir / canary.CANARY_DIR)
    plan = None if args.submit_command is None else PlanLoop(
        driver, hosts=lambda: scheduler.hosts_from_document(json.loads(args.pool.read_text(encoding="utf-8"))),
        builds=lambda: ledger_builds(scheduler, builds, data_dir / "builds"),
        submit=command_submitter(args.submit_command, scheduler.Rejected), lanes=lanes)
    r2_env = read_r2_env()
    upload = None if r2_env is None else lambda path, key: r2_upload(path, key, r2_env)
    workers = {"backup": Worker("backup", backup_step(db_path, data_dir / "backups", upload), next_backup_delay,
                                BACKUP_STALE, clock)}
    if plan is not None:
        workers["scheduler"] = Worker("scheduler", plan.step, lambda now: scheduler.POLL_SECONDS, PLAN_STALE, clock)
    app = Labd(db_path=db_path, allowlist=allowlist, whois=tailscale_whois, self_fqdn=self_fqdn,
               commit_positions=lambda: ingest.GitCommitPositions(repo, mainline=f"refs/perf-lab/{args.branch}"),
               lanes=lanes, lane_positions=lambda mainline: ingest.GitCommitPositions(repo, mainline=mainline),
               plan=plan, workers=workers, clock=clock, version=args.version,
               scheduler_off=None if plan else "no --submit-command: it would record jobs that nobody starts",
               max_rss_bytes=args.max_rss_mb << 20 if args.max_rss_mb else None)
    server = LabServer(bind or address, args.port, app)
    local = LocalServer(data_dir / SOCKET_NAME, app)
    threads = [threading.Thread(target=local.serve_forever, name="labd-local", daemon=True),
               *(threading.Thread(target=worker.run, name=f"labd-{name}", daemon=True)
                 for name, worker in workers.items())]
    for thread in threads:
        thread.start()
    print(f"labd {args.version} on http://{server.server_address[0]}:{server.server_address[1]} and "
          f"{data_dir / SOCKET_NAME}" + (f"; {app.scheduler_off}" if app.scheduler_off else ""), file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        for worker in workers.values():
            worker.stop()
        local.shutdown()
        local.server_close()
        server.server_close()
    return EX_TEMPFAIL if server.over_memory else 0


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "render-plist":
            sys.stdout.buffer.write(render_plist(
                args.template, sha=args.sha, release=args.release, data_dir=args.data_dir,
                repo=args.repo or args.data_dir / "repo", python=args.python, controllers=args.controller,
                lab_hosts=args.lab_host, branch=args.branch, log_dir=args.log_dir,
                submit_command=args.submit_command))
            return 0
        return serve(args)
    except (LabdError, store.StoreError, OSError) as error:
        print(f"labd.py {args.command}: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
