#!/usr/bin/env python3
"""The crash walks' driver: driver_daemon.py's case runner with a crash walk's fault environment (p15-oracle-207).

crash_walks.py plans the walks and builds their case-v1 cases; this file runs them. Every case is
driver_daemon.py's (p15-oracle-023): its own state root, hermetic environment, `cmux-tui --headless` daemon,
subreaper worker and I6 proof. CrashCaseRun adds what case-v1 cannot say, from the case context's `crash` entry:
- the holder arm: `new` runs the terminal holder (CMUX_TUI_TERMINAL_HOST_MODEL=holder), `old` the per-terminal
  host; until the daemon reads its switches from CMUX_TUI_SWITCHES (p15-oracle-049, 232), the arm is that name.
- an owner-panic walk restarts the killed owner with CMUX_TUI_TEST_OWNER_PANIC=thread (owner_start/owner_panic.rs,
  debug-assertion builds): the recovering owner panics a worker thread while it reopens the root. The walk then
  needs a test line (`"test": true`) in the owner panic log, else the seam did not run and the walk fails.
- a host-abort walk starts the daemon with CMUX_TUI_TEST_HOST_ABORT_ONCE=<case root>/host-abort-once and the FIFO
  `host-abort-once.trigger` beside it (terminal_host_runtime/shared/host_crash.rs, debug-assertion builds): the
  first terminal host creates the marker and aborts when the FIFO is opened for writing. crash-abort waits until
  the daemon holds the host's PTY master (only then can it replace the host), opens the FIFO and waits for the
  host to exit, as terminal_host_recovery/loss_causes.rs does. Old arm only: the new arm's cmux-holder has no seam.
- the result's `killed` says whether the case reached crash-kill, so a failure that names no step (the
  teardown's I6 proof) is the walk's or the crash's by position (crash_walks.Failure.kind).

The session gives each case a fresh state root (`/tmp/o/<run>/<n>`, every socket path within sun_path). Failing
walks are ddmin-minimized (crash_walks.minimize), each candidate a fresh case, run once more on every arm, and
written to the crash corpus with their kill points, results and expectation lines.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import itertools
import json
import os
import shutil
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import crash_walks  # noqa: E402 - sibling: plans, cases, ddmin
import driver_daemon  # noqa: E402 - the daemon driver's case runner
from crash_walks import (  # noqa: E402
    ABORT,
    HOST_ABORT,
    KILL,
    OWNER_PANIC,
    RECOVER,
    CrashWalkError,
    Failure,
    KillPoint,
    Walk,
)
from driver_daemon import CaseError, CaseRun, DaemonExit, DaemonSession  # noqa: E402

HOLDER_ENV = "CMUX_TUI_TERMINAL_HOST_MODEL"
HOLDER_ARM = {"old": None, "new": "holder"}
OWNER_PANIC_ENV = "CMUX_TUI_TEST_OWNER_PANIC"
OWNER_PANIC_LOG = "owner-panics-*.jsonl"
HOST_ABORT_ENV = "CMUX_TUI_TEST_HOST_ABORT_ONCE"
HOST_ABORT_MARKER = "host-abort-once"
TERMINAL_HOST_ARGS = ("__terminal-host",)
TERMINAL_HOST_EXE = "cmux-tui-host"
# The daemon's thread that receives a host's PTY master (terminal_host_recovery/host_replacement.rs).
CUSTODY_THREAD = "pty-custody"
SEAM_POLL_S = 0.02


def with_env(case_env: Any, names: Mapping[str, str]) -> Any:
    """`case_env` with `names` added; a name the hermetic environment already sets is refused."""
    clash = sorted(set(names) & set(case_env.env))
    if clash:
        raise CrashWalkError(f"{', '.join(clash)} is set by hermetic_env.py; a crash walk adds only its own names")
    return dataclasses.replace(case_env, env={**case_env.env, **names})


def test_panic_lines(root: Path) -> int:
    """The owner panic log lines under the case root that the debug test trigger wrote."""
    count = 0
    for path in sorted(root.rglob(OWNER_PANIC_LOG)):
        for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                line = json.loads(raw)
            except ValueError:
                continue
            count += isinstance(line, dict) and line.get("test") is True
    return count


def is_terminal_host(proc: driver_daemon.CaseProcess) -> bool:
    """A per-terminal host: `cmux-tui __terminal-host ...`, or the slim cmux-tui-host beside it (host_exe.rs)."""
    return bool(proc.argv) and (proc.argv[1:2] == TERMINAL_HOST_ARGS or Path(proc.argv[0]).name == TERMINAL_HOST_EXE)


def custody_held(pid: int) -> Optional[bool]:
    """Whether daemon `pid` holds a PTY master and no custody exchange is still storing one; None without /proc.
    host_replacement.rs's wait_for_daemon_custody reads the same: no event reports a received descriptor."""
    try:
        names, threads = os.listdir(f"/proc/{pid}/fd"), os.listdir(f"/proc/{pid}/task")
    except OSError:
        return None
    masters = 0
    for name in names:
        try:
            masters += os.readlink(f"/proc/{pid}/fd/{name}").endswith("ptmx")
        except OSError:
            continue  # closed since the listing
    exchanging = False
    for task in threads:
        try:
            with open(f"/proc/{pid}/task/{task}/comm", encoding="utf-8") as handle:
                exchanging = exchanging or handle.read().strip() == CUSTODY_THREAD
        except OSError:
            continue  # exited since the listing
    return masters > 0 and not exchanging


class CrashCaseRun(CaseRun):
    """A crash walk's case: the daemon driver's, on a holder arm, with its fault's seam."""

    def __init__(self, binary: str, sha: str, schema: Any, case: Mapping[str, Any], ctx: Mapping[str, Any],
                 session_ctx: Mapping[str, Any], isolation: Any):
        super().__init__(binary, sha, schema, case, ctx, session_ctx, isolation)
        crash = ctx.get("crash") or {}
        self.fault = str(crash.get("fault") or "")
        arm = HOLDER_ARM[str(crash.get("arm") or "old")]
        names = {HOLDER_ENV: arm} if arm else {}
        self.abort_marker = self.paths.root / HOST_ABORT_MARKER
        if self.fault == HOST_ABORT:
            names[HOST_ABORT_ENV] = str(self.abort_marker)
        self.case_env = with_env(self.case_env, names)
        self.daemon.case_env = self.case_env
        # The killed owner restarts with the panic seam: the recovery is what panics.
        self.recovery_env = with_env(self.case_env, {OWNER_PANIC_ENV: "thread"}) if self.fault == OWNER_PANIC \
            else self.case_env
        self.killed = False

    @property
    def abort_trigger(self) -> Path:
        return self.abort_marker.with_name(f"{HOST_ABORT_MARKER}.trigger")

    def op_kill(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        if step["id"] == ABORT and self.fault == HOST_ABORT:
            return self.abort_host(step["id"])
        if step["id"] == KILL:
            self.killed = True
        return super().op_kill(index, step)

    def abort_host(self, step_id: str) -> Tuple[str, Any]:
        """Releases the one terminal host's crash seam and waits for its exit, which I17 checks against
        allow_crashes (kind holder). The host starts after its create call replies: first its marker, then the
        daemon's custody of its PTY master (a host that aborts before that is lost, not replaced)."""
        self.poll_until(self.abort_marker.exists, step_id, "Failure",
                        f"{HOST_ABORT_ENV}: no terminal host created {HOST_ABORT_MARKER}, so the seam did not run (a "
                        f"build without debug assertions; build with --profile oracle)")
        self.poll_until(lambda: self.custody_held(step_id), step_id, "Timeout",
                        "the daemon held no PTY master of the terminal host")
        tree = driver_daemon.descendants(os.getpid(), str(self.paths.root))
        hosts = [proc for proc in tree if is_terminal_host(proc)]
        if len(hosts) != 1:
            raise CaseError("Crash", f"a host-abort walk needs exactly one terminal host, found {len(hosts)}: "
                                     + "; ".join(proc.describe() for proc in hosts), step_id)
        self.remember()
        # Read-write never blocks on a FIFO; the open releases the host's crash thread.
        trigger = os.open(self.abort_trigger, os.O_RDWR | os.O_NONBLOCK)
        try:
            alive = driver_daemon.wait_for_exits([hosts[0].pid], driver_daemon.EXIT_S * self.scale)
        finally:
            os.close(trigger)
        if alive:
            raise CaseError("Timeout", f"the terminal host did not abort {driver_daemon.EXIT_S * self.scale:.0f} s "
                                       f"after its trigger opened", step_id)
        self.state.exits.append(DaemonExit(step_id, "holder", f"SIGABRT by the host's crash seam "
                                                              f"({hosts[0].describe()})", None))
        refusal = driver_daemon.crash_allowed(self.case.get("allow_crashes") or (), self.state.exits)
        if refusal:
            raise CaseError("Crash", f"I17: {refusal}", step_id)
        reply = {"signal": "ABRT", "pid": hosts[0].pid}
        self.state.replies[step_id] = reply
        return ("ok", reply)

    def custody_held(self, step_id: str) -> bool:
        if self.daemon.proc is None or not self.daemon.running:
            raise CaseError("Failure", "the daemon is not running", step_id)
        held = custody_held(self.daemon.proc.pid)
        if held is None:
            raise CaseError("Crash", "the custody wait reads /proc: host-abort walks run on Linux", step_id)
        return held

    def poll_until(self, check: Callable[[], bool], step_id: str, status: str, what: str) -> None:
        """Until `check` holds, at most REQUEST_S. What the seams leave is a file or a descriptor with no event to
        wait on; host_replacement.rs's custody wait polls the same way."""
        bound = driver_daemon.REQUEST_S * self.scale
        deadline = time.monotonic() + bound
        while not check():
            if time.monotonic() >= deadline:
                raise CaseError(status, f"{what} within {bound:.0f} s", step_id)
            time.sleep(SEAM_POLL_S)

    def op_restart(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        if step["id"] != RECOVER:
            return super().op_restart(index, step)
        self.daemon.case_env = self.recovery_env
        outcome = super().op_restart(index, step)
        if self.fault == OWNER_PANIC:
            # The seam's thread panics as the owner starts. Its line lands before the recovered state is read, so
            # the read-only snapshot after it sees one panic log, not a log that grows during the read.
            self.poll_until(lambda: test_panic_lines(self.paths.root) > 0, step["id"], "Failure",
                            f"{OWNER_PANIC_ENV}=thread wrote no test line to the owner panic log: the seam did not "
                            f"run (a build without debug assertions; build with --profile oracle)")
        return outcome

    def run(self) -> Dict[str, Any]:
        if self.fault == HOST_ABORT:
            os.mkfifo(self.abort_trigger, 0o600)
        result = super().run()
        result["killed"] = self.killed
        return result


def skip_reason(point: KillPoint, arm: str) -> Optional[str]:
    """Why `point` cannot run on `arm` on this host, or None."""
    if point.fault != HOST_ABORT:
        return None
    if arm != "old":
        return (f"{HOST_ABORT_ENV} is a per-terminal host's seam; the {arm} arm's cmux-holder has none (its crash is "
                f"p15-oracle-224's journey)")
    if not sys.platform.startswith("linux"):
        return "a host-abort walk reads the daemon's PTY custody from /proc (Linux)"
    return None


class CrashSession(DaemonSession):
    """The daemon session whose workers run CrashCaseRun (this file's `case-worker`)."""

    worker_script = Path(__file__).resolve()

    def __init__(self, session_ctx: Mapping[str, Any], state_base: Path):
        super().__init__(session_ctx)
        self.base = state_base / driver_daemon.short_token(str(session_ctx.get("run_id")))
        self.counter = itertools.count()

    def run_crash(self, case: Mapping[str, Any], point: KillPoint, arm: str) -> Dict[str, Any]:
        """One crash case on `arm`, in a fresh state root."""
        reason = skip_reason(point, arm)
        if reason:
            return {"status": "Skip", "checkpoints": [], "message": reason}
        number = next(self.counter)
        ctx = {"case_id": f"{crash_walks.SUITE}/{case['id']}", "key": f"{case['id']}-{arm}-{number}",
               "state_root": str(self.base / f"{number:06d}"[-6:]),
               "crash": {"fault": point.fault, "arm": arm}}
        return self.run_case(dict(case), ctx)


def open_session(args: argparse.Namespace) -> CrashSession:
    run_id = f"crash-{os.getpid()}-{time.time_ns()}"
    return CrashSession({"binary": args.binary, "run_id": run_id, "isolation": args.isolation}, args.state_base)


def summary(result: Mapping[str, Any]) -> Dict[str, Any]:
    out = {"status": result.get("status"), "step": result.get("step"), "killed": result.get("killed")}
    if result.get("status") != "Pass":
        out["message"] = str(result.get("message") or "")[:600]
    return out


def recorded(result: Mapping[str, Any]) -> Dict[str, Any]:
    """What _kill-points.json keeps of one result."""
    out = {"status": result.get("status"), "step": result.get("step")}
    if result.get("status") != "Pass":
        out["message"] = str(result.get("message") or "")[:300]
    return out


def cmd_run(args: argparse.Namespace) -> int:
    """`crash_walks.py run`: every seed on every arm, then each crash failure minimized into the corpus."""
    walks, classes = crash_walks.loaded(args)
    by_id = {walk.id: walk for walk in walks}
    points = [crash_walks.plan(seed, walks, classes, args.faults)
              for seed in range(args.first_seed, args.first_seed + args.seeds)]
    session = open_session(args)
    started = time.monotonic()
    jobs = [(point, arm) for point in points for arm in args.arms]

    def one(job: Tuple[KillPoint, str]) -> Dict[str, Any]:
        point, arm = job
        case = crash_walks.crash_case(by_id[point.walk], point, classes)
        return {"killPoint": point.to_json(), "arm": arm, **summary(session.run_crash(case, point, arm))}

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        records = list(pool.map(one, jobs))
    groups, walk_failures = crash_walks.group_failures(jobs, records)
    chosen = crash_walks.representatives(groups)
    minimized: List[Dict[str, Any]] = []
    if not args.no_minimize:
        def shrink(item: crash_walks.Grouped) -> Tuple[Dict[str, Any], Dict[str, Any], Dict[str, Any]]:
            point, arm, record = item
            group = groups[record["signature"]]
            return minimize_one(session, by_id[point.walk], point, arm, classes, record, arms=args.arms,
                                seen_on=sorted({a for _, a, _ in group}), walks_failing=len(group))

        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            shrunk = list(pool.map(shrink, chosen))
        # The corpus files are written here, one at a time: _kill-points.json is read, changed and written.
        for (point, _, _), (case, found, results) in zip(chosen, shrunk):
            crash_walks.write_case(args.corpus, point, case, by_id[point.walk], found, results)
            minimized.append({"case": case["id"], **found})
    counts: Dict[str, int] = {}
    for record in records:
        counts[str(record["status"])] = counts.get(str(record["status"]), 0) + 1
    receipt = {
        "schema": crash_walks.RECEIPT_SCHEMA, "task": crash_walks.TASK, "binary": session.binary, "sha": session.sha,
        "seeds": [args.first_seed, args.first_seed + args.seeds], "arms": list(args.arms), "faults": list(args.faults),
        "jobs": args.jobs, "seconds": round(time.monotonic() - started, 1), "counts": counts,
        "crashFailures": sum(len(group) for group in groups.values()), "signatures": sorted(groups),
        "walkFailures": walk_failures, "minimized": minimized, "walks": records,
    }
    args.out.mkdir(parents=True, exist_ok=True)
    crash_walks.write_json(args.out / "crash-walks.json", receipt)
    shutil.rmtree(session.base, ignore_errors=True)
    print(json.dumps({key: receipt[key] for key in ("sha", "seeds", "arms", "seconds", "counts", "crashFailures",
                                                    "signatures", "walkFailures")}, sort_keys=True))
    print(f"crash_walks.py: receipt {args.out / 'crash-walks.json'}")
    return 1 if groups or walk_failures else 0


def minimize_one(session: CrashSession, walk: Walk, point: KillPoint, arm: str, classes: Mapping[str, str],
                 record: Mapping[str, Any], *, arms: Sequence[str], seen_on: Sequence[str], walks_failing: int
                 ) -> Tuple[Dict[str, Any], Dict[str, Any], Dict[str, Any]]:
    """ddmin of one failing walk on its arm, then the minimized case once more on every arm: the case, what the
    corpus records of the finding (`found`) and the case's result on each arm."""
    failure = Failure.of(record)
    if failure is None:
        raise CrashWalkError(f"{point.case_id} on {arm} did not fail; there is nothing to minimize")
    case_id = point.found_id(arm)
    kept, case = crash_walks.minimize(walk, point, classes, failure,
                                      lambda candidate: session.run_crash(candidate, point, arm), case_id)
    results = {each: recorded(session.run_crash(case, point, each)) for each in arms}
    found = {"arm": arm, "arms": list(seen_on), "walksFailing": walks_failing, "status": failure.status,
             "step": failure.step, "signature": record["signature"], "message": str(record.get("message") or "")[:600],
             "keptBeforeKill": len(kept), "reproduced": Failure.of(results[arm]) == failure}
    return case, found, results


def cmd_replay(args: argparse.Namespace) -> int:
    """`crash_walks.py replay`: corpus crash cases on each arm, `--repeat` times, with the fault their kill points
    recorded; `--record` keeps the results in _kill-points.json and the expectations they give."""
    if args.repeat < 1:
        raise CrashWalkError("--repeat is at least 1")
    jobs: List[Tuple[Path, Dict[str, Any], KillPoint, str]] = []
    for path in args.cases:
        case = json.loads(path.read_text(encoding="utf-8"))
        record = crash_walks.read_kill_points(path.parent).get(case["id"])
        if record is None:
            raise CrashWalkError(f"{path.parent / crash_walks.KILL_POINTS} has no kill point for {case['id']}")
        point = KillPoint(**{key: record[key] for key in ("seed", "walk", "index", "after", "fault")})
        jobs.extend((path, case, point, arm) for arm in args.arms for _ in range(args.repeat))
    session = open_session(args)

    def one(job: Tuple[Path, Dict[str, Any], KillPoint, str]) -> Dict[str, Any]:
        _, case, point, arm = job
        return session.run_crash(case, point, arm)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(one, jobs))
    shutil.rmtree(session.base, ignore_errors=True)
    failed = False
    by_case: Dict[Tuple[Path, str], Dict[str, List[Dict[str, Any]]]] = {}
    for (path, case, point, arm), result in zip(jobs, results):
        print(json.dumps({"case": case["id"], "killPoint": point.to_json(), "arm": arm, **summary(result)},
                         sort_keys=True))
        failed = failed or result["status"] not in ("Pass", "Skip")
        by_case.setdefault((path.parent, case["id"]), {}).setdefault(arm, []).append(recorded(result))
    if args.record:
        for (directory, case_id), arms in sorted(by_case.items()):
            crash_walks.record_results(directory, case_id,
                                       {arm: crash_walks.merge_results(runs) for arm, runs in arms.items()})
    return 1 if failed else 0


def case_worker() -> int:
    """`case-worker`: one CrashCaseRun from the JSON payload on stdin (driver_daemon.case_worker's subreaper)."""
    return driver_daemon.case_worker(CrashCaseRun)


if __name__ == "__main__":
    if sys.argv[1:] == ["case-worker"]:
        sys.exit(case_worker())
    print("crash_walks.py: run crash walks with crash_walks.py run|replay", file=sys.stderr)
    sys.exit(2)
