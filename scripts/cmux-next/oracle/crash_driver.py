#!/usr/bin/env python3
"""The crash walks' driver: driver_daemon.py's case runner with a crash walk's fault environment (p15-oracle-207).

crash_walks.py plans the walks and builds their case-v1 cases; this file runs them. Every case is
driver_daemon.py's (p15-oracle-023): its own state root, hermetic environment, `cmux-tui --headless` daemon,
subreaper worker and I6 proof. CrashCaseRun adds what case-v1 cannot say, from the case context's `crash` entry:
- the holder arm: `new` runs the terminal holder (CMUX_TUI_TERMINAL_HOST_MODEL=holder), `old` the per-terminal
  host; until the daemon reads its switches from CMUX_TUI_SWITCHES (p15-oracle-049, 232), the arm is that name.
- an owner-panic walk restarts the killed owner with CMUX_TUI_TEST_OWNER_PANIC=thread (owner_start/owner_panic.rs,
  debug-assertion builds): the recovering owner panics a worker thread while it reopens the root. The walk then
  needs a test line (`"test": true`) in the owner's panic log, else the seam did not run and the walk fails.
A host-abort walk's `kill holder ABRT` releases the terminal host's crash seam through driver_daemon.py's holder
kill (p15-oracle-224); on a driver without it the walk is a Skip that names the task.

The session gives each case a fresh state root (`/tmp/o/<run>/<n>`, every socket path within sun_path). Failing
walks are ddmin-minimized (crash_walks.minimize), each candidate a fresh case, and written to the crash corpus
with their kill points.
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
from typing import Any, Dict, List, Mapping, Sequence, Tuple

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import crash_walks  # noqa: E402 - sibling: plans, cases, ddmin
import driver_daemon  # noqa: E402 - the daemon driver's case runner (p15-oracle-023)
from crash_walks import (  # noqa: E402
    HOST_ABORT,
    OWNER_PANIC,
    RECOVER,
    CrashWalkError,
    Failure,
    KillPoint,
    Walk,
)
from driver_daemon import CaseRun, DaemonSession  # noqa: E402

HOLDER_ENV = "CMUX_TUI_TERMINAL_HOST_MODEL"
HOLDER_ARM = {"old": None, "new": "holder"}
OWNER_PANIC_ENV = "CMUX_TUI_TEST_OWNER_PANIC"
OWNER_PANIC_LOG = "owner-panics-*.jsonl"
# driver_daemon.py's holder kill and its crash seam (p15-oracle-224).
HOLDER_KILL_TASK = "p15-oracle-224"


def holder_kills_supported() -> bool:
    return hasattr(driver_daemon, "arms_abort_seam")


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


class CrashCaseRun(CaseRun):
    """A crash walk's case: the daemon driver's, on a holder arm, with an owner-panic walk's recovery seam."""

    def __init__(self, binary: str, sha: str, schema: Any, case: Mapping[str, Any], ctx: Mapping[str, Any],
                 session_ctx: Mapping[str, Any], isolation: Any):
        super().__init__(binary, sha, schema, case, ctx, session_ctx, isolation)
        crash = ctx.get("crash") or {}
        self.fault = str(crash.get("fault") or "")
        arm = HOLDER_ARM[str(crash.get("arm") or "old")]
        base = {HOLDER_ENV: arm} if arm else {}
        self.case_env = with_env(self.case_env, base)
        self.daemon.case_env = self.case_env
        # The killed owner restarts with the panic seam: the recovery is what panics.
        self.recovery_env = with_env(self.case_env, {OWNER_PANIC_ENV: "thread"}) if self.fault == OWNER_PANIC \
            else self.case_env

    def op_restart(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        if step["id"] == RECOVER:
            self.daemon.case_env = self.recovery_env
        return super().op_restart(index, step)

    def run(self) -> Dict[str, Any]:
        result = super().run()
        if self.fault == OWNER_PANIC and result["status"] == "Pass" and not test_panic_lines(self.paths.root):
            result.update(status="Failure", step=RECOVER,
                          message=f"{OWNER_PANIC_ENV}=thread wrote no test line to the owner panic log: the seam did "
                                  f"not run (a build without debug assertions; build with --profile oracle)")
        return result


class CrashSession(DaemonSession):
    """The daemon session whose workers run CrashCaseRun (this file's `case-worker`)."""

    worker_script = Path(__file__).resolve()

    def __init__(self, session_ctx: Mapping[str, Any], state_base: Path):
        super().__init__(session_ctx)
        self.base = state_base / driver_daemon.short_token(str(session_ctx.get("run_id")))
        self.counter = itertools.count()

    def run_crash(self, case: Mapping[str, Any], point: KillPoint, arm: str) -> Dict[str, Any]:
        """One crash case on `arm`, in a fresh state root."""
        if point.fault == HOST_ABORT and not holder_kills_supported():
            return {"status": "Skip", "checkpoints": [],
                    "message": f"host-abort walks need driver_daemon.py's holder kill ({HOLDER_KILL_TASK})"}
        number = next(self.counter)
        ctx = {"case_id": f"{crash_walks.SUITE}/{case['id']}", "key": f"{case['id']}-{arm}-{number}",
               "state_root": str(self.base / f"{number:06d}"[-6:]),
               "crash": {"fault": point.fault, "arm": arm}}
        return self.run_case(dict(case), ctx)


def open_session(args: argparse.Namespace) -> CrashSession:
    run_id = f"crash-{os.getpid()}-{time.time_ns()}"
    return CrashSession({"binary": args.binary, "run_id": run_id, "isolation": args.isolation}, args.state_base)


def summary(result: Mapping[str, Any]) -> Dict[str, Any]:
    out = {"status": result.get("status"), "step": result.get("step")}
    if result.get("status") != "Pass":
        out["message"] = str(result.get("message") or "")[:600]
    return out


def cmd_run(args: argparse.Namespace) -> int:
    """`crash_walks.py run`: every seed on every arm, then each failure minimized into the corpus."""
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
    # One representative per signature: the failing walk with the fewest steps before its kill point.
    groups: Dict[str, List[Tuple[KillPoint, str, Dict[str, Any]]]] = {}
    walk_failures = 0
    for (point, arm), record in zip(jobs, records):
        failure = Failure.of(record)
        if failure is None:
            continue
        record["signature"] = crash_walks.signature(failure, str(record.get("message") or ""))
        if failure.kind == "walk":
            walk_failures += 1  # the walk failed before its kill point: the walk's own suite owns it
            continue
        groups.setdefault(record["signature"], []).append((point, arm, record))
    representatives = [min(group, key=lambda item: (item[0].index, item[0].seed)) for _, group in sorted(groups.items())]
    minimized: List[Dict[str, Any]] = []
    if not args.no_minimize:
        def shrink(item: Tuple[KillPoint, str, Dict[str, Any]]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
            point, arm, record = item
            group = groups[record["signature"]]
            return minimize_one(session, by_id[point.walk], point, arm, classes, record,
                                seen_on=sorted({a for _, a, _ in group}), walks_failing=len(group))

        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            shrunk = list(pool.map(shrink, representatives))
        # The corpus files are written here, one at a time: _kill-points.json is read, changed and written.
        for (point, _, _), (case, found) in zip(representatives, shrunk):
            crash_walks.write_case(args.corpus, point, case, by_id[point.walk], found)
            minimized.append({"case": point.case_id, **found})
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
                 record: Mapping[str, Any], *, seen_on: Sequence[str], walks_failing: int
                 ) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    """ddmin of one failing walk on its arm, then one more run of the minimized case: the case and what the
    corpus records of it (`found`)."""
    failure = Failure.of(record)
    if failure is None:
        raise CrashWalkError(f"{point.case_id} on {arm} did not fail; there is nothing to minimize")
    kept, case = crash_walks.minimize(walk, point, classes, failure,
                                      lambda candidate: session.run_crash(candidate, point, arm))
    confirm = session.run_crash(case, point, arm)
    found = {"arm": arm, "arms": list(seen_on), "walksFailing": walks_failing, "status": failure.status,
             "step": failure.step, "signature": record["signature"], "message": str(record.get("message") or "")[:600],
             "keptBeforeKill": len(kept), "reproduced": Failure.of(confirm) == failure}
    return case, found


def cmd_replay(args: argparse.Namespace) -> int:
    """`crash_walks.py replay`: one corpus crash case with the fault its kill point recorded."""
    case = json.loads(args.case.read_text(encoding="utf-8"))
    record = crash_walks.read_kill_points(args.case.parent).get(case["id"])
    if record is None:
        raise CrashWalkError(f"{args.case.parent / crash_walks.KILL_POINTS} has no kill point for {case['id']}")
    point = KillPoint(**{key: record[key] for key in ("seed", "walk", "index", "after", "fault")})
    session = open_session(args)
    result = session.run_crash(case, point, args.arm)
    shutil.rmtree(session.base, ignore_errors=True)
    print(json.dumps({"killPoint": point.to_json(), "arm": args.arm, **summary(result)}, indent=1, sort_keys=True))
    return 0 if result["status"] in ("Pass", "Skip") else 1


def case_worker() -> int:
    """`case-worker`: one CrashCaseRun from the JSON payload on stdin (driver_daemon.case_worker's subreaper)."""
    return driver_daemon.case_worker(CrashCaseRun)


if __name__ == "__main__":
    if sys.argv[1:] == ["case-worker"]:
        sys.exit(case_worker())
    print("crash_driver.py: run crash walks with crash_walks.py run|replay", file=sys.stderr)
    sys.exit(2)
