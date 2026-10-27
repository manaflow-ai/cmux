#!/usr/bin/env python3
"""Try admission: the queue in front of `lab.py try` (task 018) and the general-fleet try pool.

An agent's try request (base, head, stories, features) becomes one `kind = 'try'` row in the lab
store's jobs table (store.py schema 1). Admission is one BEGIN IMMEDIATE transaction, so parallel
requests from many agents see one consistent queue:

- Dedupe. A request with the same (base, head, stories, features) as an unfinished try job joins
  that job and gets its receipt; it adds no work. Swarming dedupes idempotent tasks the same way, by
  a hash of the task properties (luci-py `appengine/swarming/server/task_scheduler.py`,
  `_find_dupe_task`, keyed by `TaskProperties.properties_hash` in `task_request.py`).
- Quota. A session has at most SESSION_QUOTA unfinished (queued or started) try jobs. The next new
  request is refused with a reason that names those jobs. A join costs no quota.
- Builds. Each arm reuses a bench build of its SHA that the lab already has (batch tips build first,
  task 234); the receipt says which arms still need a build.
- Queue position. The receipt says the job's place among the queued try jobs (FIFO, oldest first).

Placement (p12-perf-process.md 3.1): a try job runs on any free fleet Mac with the `measure` label,
never on a perf-lab host (the `perf-lab` label or a host in pool.json). Try jobs are same-host ABBA,
so the host's identity does not matter; the receipt names the host class it ran on.

- dispatch(): gives the oldest queued job a free eligible host and moves it to `env-check`.
- env_result(): takes that host's host_env.py verdict (task 006: {ok, reasons, hz, fingerprint,
  class}). An `ok` verdict starts the job with the verdict's host class; an invalid host puts the job
  back at its place in the queue, and that host is not offered to the job again.
- finish(): the try runner's terminal state (`done`, `failed`); cancel(): the owner session stops it.

Stdlib only; loaded by file path, with store.py next to it.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import sqlite3
import sys
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path


def _load_store():
    name = "perf_lab_store"
    if name in sys.modules:
        return sys.modules[name]
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "store.py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


store = _load_store()

JOB_KIND = "try"
SESSION_QUOTA = 3
MEASURE_LABEL = "measure"
LAB_LABEL = "perf-lab"
BUILD_CONFIG = "bench"
DEDUPE_VERSION = "try1"
DEFAULT_POOL = Path(__file__).resolve().parent / "pool.json"

QUEUED = "queued"
ENV_CHECK = "env-check"
RUNNING = "running"
DONE = "done"
FAILED = "failed"
CANCELLED = "cancelled"
UNFINISHED = (QUEUED, ENV_CHECK, RUNNING)
TERMINAL = (DONE, FAILED, CANCELLED)

ADMITTED = "admitted"
JOINED = "joined"
REFUSED = "refused"

_SHA = re.compile(r"[0-9a-f]{40}")
_STORY = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
_FEATURE = re.compile(r"([A-Za-z0-9][A-Za-z0-9._-]*)=(on|off)")
_UNFINISHED_SQL = ", ".join(f"'{state}'" for state in UNFINISHED)


class AdmissionError(RuntimeError):
    """A request or a state change the queue cannot take; `code` is stable for scripts."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class TryRequest:
    """One agent's try request, in canonical form: full SHAs, sorted stories, features sorted by name."""

    session: str
    base: str
    head: str
    stories: tuple[str, ...] = ()
    features: tuple[tuple[str, str], ...] = ()
    attempts: int = 20

    @classmethod
    def parse(cls, *, session: str, base: str, head: str, stories: Iterable[str] = (),
              features: Iterable[str] = (), attempts: int = 20) -> "TryRequest":
        session = session.strip()
        if not session:
            raise AdmissionError("bad-session", "a try request needs a session id (--session)")
        shas = []
        for arm, sha in (("base", base), ("head", head)):
            sha = sha.strip().lower()
            if not _SHA.fullmatch(sha):
                raise AdmissionError("bad-sha", f"--{arm} {sha!r}: give the full 40-character commit SHA")
            shas.append(sha)
        names = sorted({story.strip() for story in stories if story.strip()})
        for story in names:
            if not _STORY.fullmatch(story):
                raise AdmissionError("bad-story", f"story {story!r} is not a story id")
        by_name: dict[str, str] = {}
        for item in features:
            match = _FEATURE.fullmatch(item.strip())
            if match is None:
                raise AdmissionError("bad-feature", f"--feature {item!r}: use NAME=on or NAME=off")
            name, value = match.groups()
            if by_name.get(name, value) != value:
                raise AdmissionError("bad-feature", f"--feature {name} is set both on and off")
            by_name[name] = value
        if attempts < 1:
            raise AdmissionError("bad-attempts", f"--attempts {attempts}: give 1 or more")
        return cls(session=session, base=shas[0], head=shas[1], stories=tuple(names),
                   features=tuple(sorted(by_name.items())), attempts=attempts)

    @property
    def dedupe_key(self) -> str:
        """Identical work has one key: (base, head, stories, features). Session and attempts are not inputs."""
        canonical = json.dumps([self.base, self.head, list(self.stories), [list(f) for f in self.features]],
                               separators=(",", ":"))
        return f"{DEDUPE_VERSION}:{hashlib.sha256(canonical.encode()).hexdigest()[:32]}"


@dataclass(frozen=True)
class FleetHost:
    """One fleet Mac as the controller reports it."""

    name: str
    labels: frozenset[str] = frozenset()
    busy: bool = False

    @classmethod
    def from_json(cls, item: dict) -> "FleetHost":
        return cls(name=str(item["name"]), labels=frozenset(str(label) for label in item.get("labels", ())),
                   busy=bool(item.get("busy", False)))


@dataclass(frozen=True)
class Admission:
    """What admit() did. `receipt` is the line to print; `reason` is set when the request was refused."""

    outcome: str
    job_id: int | None
    receipt: str
    position: int | None = None
    queued: int | None = None
    reason: str | None = None


@dataclass(frozen=True)
class Assignment:
    """dispatch()'s offer: run host_env.py on `host`, then report it with env_result()."""

    job_id: int
    host: str


@dataclass(frozen=True)
class JobStatus:
    job_id: int
    state: str
    sessions: tuple[str, ...]
    host: str | None
    host_class: str | None
    position: int | None
    builds: dict[str, str | None] = field(default_factory=dict)

    def where(self, queued: int | None = None) -> str:
        if self.state == QUEUED:
            of = f" of {queued}" if queued is not None else ""
            return (f"queue position {self.position}{of}, host class named when a free {MEASURE_LABEL} host "
                    f"passes host_env (never {LAB_LABEL})")
        if self.state == ENV_CHECK:
            return f"host_env check on {self.host}"
        if self.host_class:
            return f"{self.state} on {self.host} @{self.host_class}"
        return self.state

    def receipt(self) -> str:
        return f"Perf try job {self.job_id}: {self.where()}"


def lab_hosts(pool_path: Path | str) -> frozenset[str]:
    """The perf-lab host names in pool.json (`{"hosts": [{"name": ...}, ...]}`)."""
    try:
        document = json.loads(Path(pool_path).read_text())
    except FileNotFoundError as error:
        raise AdmissionError("no-pool", f"{pool_path}: no lab pool file, so lab hosts cannot be excluded") from error
    except json.JSONDecodeError as error:
        raise AdmissionError("bad-pool", f"{pool_path}: {error}") from error
    hosts = document.get("hosts") if isinstance(document, dict) else None
    if not isinstance(hosts, list) or not all(isinstance(h, dict) and isinstance(h.get("name"), str) for h in hosts):
        raise AdmissionError("bad-pool", f"{pool_path}: expected {{\"hosts\": [{{\"name\": ...}}]}}")
    return frozenset(host["name"] for host in hosts)


def eligible(host: FleetHost, lab: frozenset[str]) -> bool:
    """A try host has the measure label and is neither labelled perf-lab nor listed in the lab pool."""
    return MEASURE_LABEL in host.labels and LAB_LABEL not in host.labels and host.name not in lab


def _stamp(moment: datetime) -> str:
    if moment.tzinfo is None or moment.utcoffset() is None:
        raise AdmissionError("bad-clock", f"{moment.isoformat()}: a stored time needs a timezone")
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _short(sha: str) -> str:
    return sha[:12]


class TryQueue:
    """The try queue on a migrated lab store. One connection, owned by the opening thread, like store.Store."""

    def __init__(self, path: Path | str, *, clock: Callable[[], datetime] = store.utc_now,
                 quota: int = SESSION_QUOTA, busy_timeout_ms: int = 5000) -> None:
        self._clock = clock
        self._quota = quota
        self._db = sqlite3.connect(str(path), isolation_level=None, timeout=busy_timeout_ms / 1000)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA foreign_keys=ON")

    def close(self) -> None:
        self._db.close()

    def _write(self, statements: Callable[[], object]) -> object:
        self._db.execute("BEGIN IMMEDIATE")
        try:
            result = statements()
        except BaseException:
            self._db.execute("ROLLBACK")
            raise
        self._db.execute("COMMIT")
        return result

    def _job(self, job_id: int) -> sqlite3.Row:
        row = self._db.execute("SELECT * FROM jobs WHERE id = ? AND kind = ?", (job_id, JOB_KIND)).fetchone()
        if row is None:
            raise AdmissionError("no-job", f"no try job {job_id}")
        return row

    def _update(self, job_id: int, *, params: dict, state: str | None = None, host_class: str | None = None,
                result: dict | None = None) -> None:
        self._db.execute(
            """UPDATE jobs SET state = COALESCE(?, state), params_json = ?, host_class = COALESCE(?, host_class),
                   result_json = COALESCE(?, result_json), updated_at = ? WHERE id = ?""",
            (state, json.dumps(params, sort_keys=True), host_class,
             None if result is None else json.dumps(result, sort_keys=True), _stamp(self._clock()), job_id))

    def _position(self, job_id: int) -> tuple[int | None, int]:
        queued = [row["id"] for row in self._db.execute(
            "SELECT id FROM jobs WHERE kind = ? AND state = ? ORDER BY created_at, id", (JOB_KIND, QUEUED))]
        return (queued.index(job_id) + 1 if job_id in queued else None), len(queued)

    def _builds(self, request: TryRequest) -> dict[str, str | None]:
        found = {}
        for arm, sha in (("base", request.base), ("head", request.head)):
            row = self._db.execute(
                "SELECT artifact_digest FROM builds WHERE sha = ? AND config = ? AND artifact_digest IS NOT NULL",
                (sha, BUILD_CONFIG)).fetchone()
            found[arm] = row["artifact_digest"] if row else None
        return found

    def admit(self, request: TryRequest) -> Admission:
        """Joins an identical unfinished job, refuses past the session quota, or queues a new job."""

        def write() -> Admission:
            duplicate = self._db.execute(
                f"""SELECT id, params_json FROM jobs WHERE kind = ? AND state IN ({_UNFINISHED_SQL})
                    AND json_extract(params_json, '$.dedupe_key') = ? ORDER BY id LIMIT 1""",
                (JOB_KIND, request.dedupe_key)).fetchone()
            if duplicate is not None:
                params = json.loads(duplicate["params_json"])
                if request.session not in params["sessions"]:
                    params["sessions"].append(request.session)
                    self._update(duplicate["id"], params=params)
                return self._receipt(JOINED, duplicate["id"])
            owned = [row["id"] for row in self._db.execute(
                f"""SELECT id FROM jobs WHERE kind = ? AND state IN ({_UNFINISHED_SQL})
                    AND json_extract(params_json, '$.sessions[0]') = ? ORDER BY id""",
                (JOB_KIND, request.session))]
            if len(owned) >= self._quota:
                reason = (f"session {request.session} already has {len(owned)} unfinished try jobs "
                          f"({', '.join(str(job) for job in owned)}); the limit is {self._quota}. "
                          f"Wait for one to finish or cancel one")
                return Admission(outcome=REFUSED, job_id=None, receipt=f"Perf try refused: {reason}", reason=reason)
            params = {"dedupe_key": request.dedupe_key, "sessions": [request.session],
                      "stories": list(request.stories), "features": [list(f) for f in request.features],
                      "attempts": request.attempts, "builds": self._builds(request), "host": None,
                      "env_refused": {}}
            now = _stamp(self._clock())
            job_id = self._db.execute(
                """INSERT INTO jobs (kind, state, base_sha, head_sha, params_json, created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (JOB_KIND, QUEUED, request.base, request.head, json.dumps(params, sort_keys=True), now, now)).lastrowid
            return self._receipt(ADMITTED, job_id)

        return self._write(write)

    def _receipt(self, outcome: str, job_id: int) -> Admission:
        row = self._job(job_id)
        params = json.loads(row["params_json"])
        status = self.status(job_id)
        _, queued = self._position(job_id)
        builds = ", ".join(
            f"{arm} {_short(row[f'{arm}_sha'])} " + (f"reuses {status.builds[arm]}" if status.builds[arm]
                                                     else f"needs a {BUILD_CONFIG} build")
            for arm in ("base", "head"))
        stories = ",".join(params["stories"]) or "default T0 stories"
        features = ",".join(f"{name}={value}" for name, value in params["features"]) or "none"
        verb = "admitted" if outcome == ADMITTED else "joined existing"
        receipt = (f"Perf try {verb} job {job_id}: {status.where(queued)}; {builds}; stories {stories}; "
                   f"features {features}")
        return Admission(outcome=outcome, job_id=job_id, receipt=receipt, position=status.position, queued=queued)

    def status(self, job_id: int) -> JobStatus:
        row = self._job(job_id)
        params = json.loads(row["params_json"])
        position, _ = self._position(job_id)
        return JobStatus(job_id=job_id, state=row["state"], sessions=tuple(params["sessions"]),
                         host=params["host"], host_class=row["host_class"], position=position,
                         builds=dict(params["builds"]))

    def dispatch(self, fleet: Sequence[FleetHost], lab: frozenset[str]) -> list[Assignment]:
        """Offers free eligible hosts to queued jobs, oldest job first; each host takes one job."""

        def write() -> list[Assignment]:
            taken = {json.loads(row["params_json"])["host"] for row in self._db.execute(
                "SELECT params_json FROM jobs WHERE kind = ? AND state IN (?, ?)", (JOB_KIND, ENV_CHECK, RUNNING))}
            free = [host.name for host in sorted(fleet, key=lambda h: h.name)
                    if eligible(host, lab) and not host.busy and host.name not in taken]
            assignments = []
            for row in self._db.execute(
                    "SELECT id, params_json FROM jobs WHERE kind = ? AND state = ? ORDER BY created_at, id",
                    (JOB_KIND, QUEUED)).fetchall():
                params = json.loads(row["params_json"])
                host = next((name for name in free if name not in params["env_refused"]), None)
                if host is None:
                    continue
                free.remove(host)
                params["host"] = host
                self._update(row["id"], state=ENV_CHECK, params=params)
                assignments.append(Assignment(job_id=row["id"], host=host))
            return assignments

        return self._write(write)

    def env_result(self, job_id: int, host: str, verdict: dict) -> JobStatus:
        """host_env.py's verdict for the offered host: start the job there, or requeue it without that host."""

        def write() -> None:
            row = self._job(job_id)
            params = json.loads(row["params_json"])
            if row["state"] != ENV_CHECK or params["host"] != host:
                raise AdmissionError("not-offered", f"try job {job_id} is {row['state']}, not offered to {host}")
            if verdict.get("ok") is True:
                host_class = verdict.get("class")
                if not isinstance(host_class, str) or not host_class:
                    raise AdmissionError("bad-verdict", f"host_env verdict for {host} has no host class")
                self._update(job_id, state=RUNNING, params=params, host_class=host_class)
                return
            params["env_refused"][host] = [str(reason) for reason in verdict.get("reasons") or ["env-invalid"]]
            params["host"] = None
            self._update(job_id, state=QUEUED, params=params)

        self._write(write)
        return self.status(job_id)

    def finish(self, job_id: int, state: str, result: dict | None = None) -> JobStatus:
        """The try runner's terminal state for a started job. Idempotent for the same state."""
        if state not in (DONE, FAILED):
            raise AdmissionError("bad-state", f"finish state {state!r}: use {DONE} or {FAILED}")

        def write() -> None:
            row = self._job(job_id)
            if row["state"] == state:
                return
            if row["state"] != RUNNING:
                raise AdmissionError("not-running", f"try job {job_id} is {row['state']}, not {RUNNING}")
            self._update(job_id, state=state, params=json.loads(row["params_json"]), result=result)

        self._write(write)
        return self.status(job_id)

    def cancel(self, job_id: int, session: str) -> JobStatus:
        """The session that queued the job stops it; joined sessions only leave it."""

        def write() -> None:
            row = self._job(job_id)
            params = json.loads(row["params_json"])
            if row["state"] in TERMINAL:
                return
            if session not in params["sessions"]:
                raise AdmissionError("not-owner", f"session {session} did not request try job {job_id}")
            params["sessions"].remove(session)
            self._update(job_id, state=None if params["sessions"] else CANCELLED, params=params)

        self._write(write)
        return self.status(job_id)


def _fleet(path: str) -> list[FleetHost]:
    try:
        document = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise AdmissionError("bad-fleet", f"{path}: {error}") from error
    hosts = document.get("hosts") if isinstance(document, dict) else document
    if not isinstance(hosts, list):
        raise AdmissionError("bad-fleet", f"{path}: expected a host list or {{\"hosts\": [...]}}")
    return [FleetHost.from_json(item) for item in hosts]


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="try_admission.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--store", required=True, help="the lab store (SQLite, store.py schema)")
    commands = parser.add_subparsers(dest="command", required=True)
    admit = commands.add_parser("admit", help="queue or join a try job")
    admit.add_argument("--session", default=os.environ.get("CMUX_TRY_SESSION", ""))
    admit.add_argument("--base", required=True)
    admit.add_argument("--head", required=True)
    admit.add_argument("--stories", default="")
    admit.add_argument("--feature", action="append", default=[])
    admit.add_argument("--attempts", type=int, default=20)
    status = commands.add_parser("status", help="one try job's state and receipt")
    status.add_argument("job", type=int)
    dispatch = commands.add_parser("dispatch", help="offer free measure hosts to queued try jobs")
    dispatch.add_argument("--fleet", required=True, help="JSON host list: name, labels, busy")
    dispatch.add_argument("--pool", default=str(DEFAULT_POOL))
    env = commands.add_parser("env-result", help="report host_env.py's JSON verdict for an offered host")
    env.add_argument("job", type=int)
    env.add_argument("--host", required=True)
    env.add_argument("--verdict", required=True, help="host_env.py JSON output file")
    finish = commands.add_parser("finish", help="record a started job's end")
    finish.add_argument("job", type=int)
    finish.add_argument("--state", required=True, choices=(DONE, FAILED))
    cancel = commands.add_parser("cancel", help="cancel or leave a try job")
    cancel.add_argument("job", type=int)
    cancel.add_argument("--session", default=os.environ.get("CMUX_TRY_SESSION", ""))
    args = parser.parse_args(argv)

    lab = store.Store(args.store)
    try:
        lab.migrate()
    finally:
        lab.close()
    queue = TryQueue(args.store)
    try:
        if args.command == "admit":
            request = TryRequest.parse(session=args.session, base=args.base, head=args.head,
                                       stories=args.stories.split(","), features=args.feature,
                                       attempts=args.attempts)
            admission = queue.admit(request)
            print(admission.receipt)
            return 2 if admission.outcome == REFUSED else 0
        if args.command == "status":
            print(queue.status(args.job).receipt())
        elif args.command == "dispatch":
            for assignment in queue.dispatch(_fleet(args.fleet), lab_hosts(args.pool)):
                print(json.dumps({"job": assignment.job_id, "host": assignment.host}))
        elif args.command == "env-result":
            print(queue.env_result(args.job, args.host, json.loads(Path(args.verdict).read_text())).receipt())
        elif args.command == "finish":
            print(queue.finish(args.job, args.state).receipt())
        elif args.command == "cancel":
            print(queue.cancel(args.job, args.session).receipt())
        return 0
    except AdmissionError as error:
        print(f"try_admission: {error.code}: {error}", file=sys.stderr)
        return 1
    finally:
        queue.close()


if __name__ == "__main__":
    sys.exit(main())
