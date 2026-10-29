#!/usr/bin/env python3
"""Crash-consistency walks: kill the session owner after a seeded step, restart it on the same state root, and
require the state of the last acknowledged mutation (p15-oracle-207).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, task 207 ("SIGKILL at random steps, restart on the same root,
state equals last acknowledged sequence"). Stdlib only, Python 3.9+, safe under `python3 -I`. The planning, case
building and ddmin here need no daemon and no SDK; `run` and `replay` run cases through crash_driver.py, the
daemon driver (driver_daemon.py, p15-oracle-023) with the fault environment added.

A walk is a case-v1 daemon case: the walk cases of tests/oracle/corpus/walks/ (written by gen_walks.py,
p15-oracle-098) and, until those exist, the daemon-ops cases (gen_daemon_ops.py). For one seed, `plan` draws a
walk, a kill point (after a resource.call step whose reply the daemon sent, so the call is acknowledged) and a
fault, all from `random.Random("cmux-crash-walk:<seed>")`, so the same seed gives the same crash walk. The crash
case is the walk's steps up to the kill point, then:

  crash-acked      session.snapshot: the state at the last acknowledged step
  crash-abort      host-abort only: kill holder ABRT, the terminal host's crash seam (CMUX_TUI_TEST_HOST_ABORT_ONCE,
                   host_crash.rs): crash_driver.py opens its trigger FIFO and waits for the host to exit. Old holder
                   arm only (the cmux-holder of the new arm has no such seam); oracle.py's driver_daemon.py kills no
                   host until p15-oracle-224, and crash.txt expects that
  crash-kill       kill daemon KILL
  crash-recover    restart daemon on the same root (owner-panic: with CMUX_TUI_TEST_OWNER_PANIC=thread, so the
                   recovering owner panics a worker thread while it reopens the root)
  crash-recovered  session.snapshot equals crash-acked, except what a new daemon generation changes
  crash-replay     the last acknowledged mutation again, with its idempotency key: the daemon replays the reply it
                   acknowledged before the kill (invariant I10 across a crash)

Every crash case lists the terminal-holder switch, so `oracle.py run --switch terminal-holder --arm old|new` runs
it on both holder arms; `run --arms old,new` here does the same through CMUX_TUI_TERMINAL_HOST_MODEL until the
daemon reads its switches from CMUX_TUI_SWITCHES (p15-oracle-049, 232).

A failing crash walk is ddmin-minimized (Zeller and Hildebrandt, "Simplifying and Isolating Failure-Inducing
Input", 2002; ClusterFuzz's delta minimizer does the same for Chromium's fuzz crashes): the steps before the kill
point are reduced while the case still fails at the same step with the same status. A reduced prefix keeps the
steps its $step: references name and must keep the daemon running at the kill point; any other subset is
unresolved and counts as passing. The minimized case (`s<seed>-<fault>-<arm>`) goes to tests/oracle/corpus/crash/
and its kill point, with its result on each arm, to `_kill-points.json` there; each failing result is a line of
tests/oracle/Expectations.d/crash.txt, so a default oracle run expects it. Every walk of a run, failing or not, is
in the run receipt with its kill point.

A failure is the walk's when it is at a walk step or at crash-acked (both before the fault), or names no step in a
case that never reached crash-kill; every other failure is the crash's, a teardown I6 leak after the restart or a
worker hang after the kill included. Only the crash's are grouped, minimized and written.

Chrome reference (chromium/src):
- components/sessions/core/command_storage_backend.cc: the session service appends commands to its file and, on
  restore after a crash, keeps every whole command and drops a torn tail, so the restored session is the last
  command written. Here the daemon's acknowledgement plays the written command: the state after the restart is
  the state at the last acknowledged reply, no more and no less.
- content/public/test/browser_test_utils.h (CrashTab, RenderProcessHostWatcher) and chrome://crash: a test kills
  a child on purpose inside ScopedAllowRendererCrashes; crash-kill and crash-abort are inside allow_crashes.

Usage:
  crash_walks.py plan [--walks PATH...] [--seeds 20] [--first-seed 0] [--faults F,...]
                                                 the kill point of each seed, one JSON line each (no daemon)
  crash_walks.py gen  [--walks PATH...] [--seeds N] [--faults F,...] [--out tests/oracle/corpus/crash]
                                                 write the crash cases of those seeds, their kill points and
                                                 the suite's coverage.json
  crash_walks.py run --binary CMUX_TUI [--walks PATH...] [--seeds 5000] [--arms old,new] [--jobs 200]
                     [--out DIR] [--corpus DIR] [--no-minimize] [--isolation netns|auto|none]
                                                 the crash walks on each arm; failures minimized into the corpus
  crash_walks.py replay --binary CMUX_TUI CASE.json... [--arms old,new] [--repeat N] [--record]
                                                 corpus crash cases with the fault their kill points recorded;
                                                 --record keeps each result in _kill-points.json and crash.txt
  crash_walks.py --selftest                      the offline tests (crash_walks_test.py)
"""

from __future__ import annotations

import argparse
import copy
import json
import random
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
CORPUS = REPO / "tests" / "oracle" / "corpus"
CRASH_DIR = CORPUS / "crash"
EXPECTATIONS = REPO / "tests" / "oracle"
WALK_SOURCES = (CORPUS / "walks", CORPUS / "daemon-ops")
OPERATIONS_SPEC = REPO / "cmux-tui" / "spec" / "resource-operations-v2.json"
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

SUITE = "crash"
TASK = "p15-oracle-207"
KILL_POINTS = "_kill-points.json"
KILL_POINTS_SCHEMA = "cmux.oracle.crash-kill-points/v1"
RECEIPT_SCHEMA = "cmux.oracle.crash-walks/v1"
SEED_PREFIX = "cmux-crash-walk:"

SIGKILL, OWNER_PANIC, HOST_ABORT = "sigkill", "owner-panic", "host-abort"
FAULTS = (SIGKILL, OWNER_PANIC, HOST_ABORT)
# The draw: half the walks are a plain SIGKILL of the owner, a quarter each add one of the two debug seams.
FAULT_DRAW = (SIGKILL, SIGKILL, OWNER_PANIC, HOST_ABORT)
ARMS = ("old", "new")
HOLDER_SWITCH = "terminal-holder"

ACKED, ABORT, KILL, RECOVER, RECOVERED, REPLAY = (
    "crash-acked", "crash-abort", "crash-kill", "crash-recover", "crash-recovered", "crash-replay")
CRASH_STEPS = frozenset({ACKED, ABORT, KILL, RECOVER, RECOVERED, REPLAY})
SELECTORS = {"machine": "current", "session": "current"}
# What a new daemon generation changes in session.snapshot (the graceful-restart cases of gen_daemon_ops.py), and
# the connected clients: a killed owner drops every connection, which is not session state it acknowledged.
RECOVERED_EXCEPT = ["/cursor", "/session/generation", "/session/revision", "/terminals/*/stream_revision",
                    "/terminals/*/extra", "/clients"]
# What a replayed mutation_result changes: its generation is the replaying daemon's, and its replayed flag. The
# value and the revision are the acknowledged ones (gen_daemon_ops.py's graceful-restart replays except the same).
REPLAY_EXCEPT = ["/generation", "/replayed"]
# The graceful-restart cases wait this long for an adopted terminal.
ADOPT_WAIT_MS = 15000

DAEMON_OPS = frozenset({"resource.call", "snapshot", "settle", "kill", "restart", "advance_clock"})
WALK_REQUIRES = frozenset({"resource_api", "restart"})
CASE_FIXTURE_KEYS = frozenset({"seed", "network", "clock"})
STEP_REF = re.compile(r"\$step:([a-z0-9][a-z0-9-]{0,63})#")
# The parts of a failure message that differ between two walks with one cause: JSON strings, paths, numbers.
VOLATILE = re.compile(r'"[^"]*"|/tmp/\S+|\b\d+\b')
# A host-abort walk needs exactly one terminal (the seam ends the first host only, and driver_daemon.py refuses
# it with several): a step that surely makes one, none that may make or end one. A creator surely makes a running
# terminal only when its call succeeds and it runs the default shell: a given argv may exit at once.
CREATES_TERMINAL = frozenset({"tab.create_terminal"})
MAY_CREATE_TERMINAL = frozenset({"closed.reopen", "pane.create", "pane.run", "pane.split", "saved_tab_group.reopen",
                                 "screen.create", "session.open", "stash.create", "stash.restore",
                                 "terminal.input.keys", "terminal.input.write", "workspace.layout.apply",
                                 "workspace.run"})
ENDS_SOMETHING = re.compile(r"\.(close|delete|remove|kill|end|restart|respawn|clear|discard)(_|\.|$)")


class CrashWalkError(Exception):
    """A walk source or seed that cannot make a crash walk."""


# ---------------------------------------------------------------------------------------------------------
# Walks and kill points


@dataclass(frozen=True)
class Walk:
    id: str
    case: Mapping[str, Any]

    @property
    def steps(self) -> List[Mapping[str, Any]]:
        return list(self.case.get("steps") or ())


@dataclass(frozen=True)
class KillPoint:
    """Where and how a crash walk kills the owner: after step `index` (`after`, its id) of walk `walk`."""

    seed: int
    walk: str
    index: int
    after: str
    fault: str

    @property
    def case_id(self) -> str:
        return f"s{self.seed}-{self.fault}"

    def found_id(self, arm: str) -> str:
        """The id of a minimized failure of this walk on `arm`: one seed can fail with another signature on each
        arm, and each representative is its own case."""
        return f"{self.case_id}-{arm}"

    def to_json(self) -> Dict[str, Any]:
        return asdict(self)


def operation_classes(path: Path = OPERATIONS_SPEC) -> Dict[str, str]:
    with open(path, encoding="utf-8") as handle:
        return {name: spec["class"] for name, spec in json.load(handle)["operations"].items()}


def method(step: Mapping[str, Any]) -> Optional[str]:
    if step.get("op") != "resource.call":
        return None
    value = (step.get("args") or {}).get("method")
    return value if isinstance(value, str) else None


def running_after(steps: Sequence[Mapping[str, Any]]) -> Optional[List[bool]]:
    """Whether the daemon runs after each step, or None when a step needs a daemon that a kill or an ending call
    stopped (a walk no restart follows)."""
    running = True
    out: List[bool] = []
    for step in steps:
        op = step.get("op")
        target = (step.get("target") or {}).get("process")
        if op in ("resource.call", "advance_clock") and not running:
            return None
        if op == "kill" and target == "daemon":
            if not running:
                return None
            running = False
        elif op == "restart" and target == "daemon":
            running = True
        elif op == "resource.call" and step.get("ends") == "daemon":
            running = False
        out.append(running)
    return out


def usable(case: Mapping[str, Any], platform: str) -> Optional[str]:
    """None when the case can be a crash walk on `platform`, else why not."""
    if case.get("suite") == SUITE:
        return "a crash case is not a walk"
    if not set(case.get("requires") or ()) <= WALK_REQUIRES:
        return f"requires {sorted(set(case.get('requires') or ()) - WALK_REQUIRES)}"
    if platform not in (case.get("platforms") or ("linux", "mac")):
        return f"not on {platform}"
    fixture = case.get("fixture") or {}
    setup = sorted(set(fixture) - CASE_FIXTURE_KEYS - {"agent"}) + (["agent"] if fixture.get("agent") == "mock" else [])
    if setup:
        return f"fixture {setup} needs its own setup"
    steps = case.get("steps") or ()
    ops = {step.get("op") for step in steps}
    if not ops <= DAEMON_OPS:
        return f"ops {sorted(o for o in ops - DAEMON_OPS if o)} are not the daemon driver's"
    if any(step.get("op") == "kill" and (step.get("target") or {}).get("process") != "daemon" for step in steps):
        return "a walk kills only the daemon"
    if any(step.get("id") in CRASH_STEPS for step in steps):
        return "a step id is a crash step's"
    if running_after(steps) is None:
        return "a step needs a daemon the walk stopped"
    return None


def expected_cases(root: Path = EXPECTATIONS) -> Dict[str, str]:
    """The cases an Expectations.d or NeverFix.d line names, by id, with the line: a walk that is known to fail or
    is skipped before any kill would make every crash walk on it fail at the walk, not at the crash."""
    import expectations  # noqa: PLC0415 - sibling; only the corpus commands read it

    found: Dict[str, str] = {}
    for directory, kind in ((root / "Expectations.d", "expectations"), (root / "NeverFix.d", "neverfix")):
        for path in sorted(directory.glob("*.txt")) if directory.is_dir() else ():
            entries, _ = expectations.parse_text(path.read_text(encoding="utf-8"), str(path), kind)
            for entry in entries:
                found.setdefault(f"{entry.suite}/{entry.case}", f"{entry.bug or kind} {entry.target} "
                                                                 f"[ {' '.join(sorted(entry.results))} ]")
    return found


def load_walks(paths: Iterable[Path], platform: str,
               expected: Optional[Mapping[str, str]] = None) -> Tuple[List[Walk], Dict[str, str]]:
    """The usable walk cases under `paths` (files or directories), by id; and why each other case is left out.
    `expected` (expected_cases) leaves out the walks with an expectation."""
    walks: List[Walk] = []
    skipped: Dict[str, str] = {}
    for root in paths:
        files = sorted(root.rglob("*.json")) if root.is_dir() else [root]
        for path in files:
            if path.name.startswith("_") or path.name == "coverage.json":
                continue
            try:
                case = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError) as error:
                skipped[str(path)] = f"cannot read: {error}"
                continue
            if not isinstance(case, dict) or not isinstance(case.get("steps"), list):
                skipped[str(path)] = "not a case"
                continue
            walk_id = f"{case.get('suite')}/{case.get('id')}"
            reason = usable(case, platform)
            if not reason and expected and walk_id in expected:
                reason = f"expected: {expected[walk_id]}"
            if reason:
                skipped[walk_id] = reason
            elif not kill_candidates(case["steps"], {}):
                skipped[walk_id] = "no step can be a kill point"
            else:
                walks.append(Walk(walk_id, case))
    walks.sort(key=lambda walk: walk.id)
    return walks, skipped


def kill_candidates(steps: Sequence[Mapping[str, Any]], classes: Mapping[str, str]) -> List[int]:
    """The steps a kill may follow: a resource.call the daemon answered and still runs after. Mutations when the
    walk has any (a kill after a read tests nothing a kill after the mutation before it does not)."""
    running = running_after(steps)
    if running is None:
        return []
    calls = [i for i, step in enumerate(steps) if method(step) and running[i]]
    mutations = [i for i in calls if classes.get(method(steps[i]) or "") == "mutation"]
    return mutations or calls


def sure_terminals(steps: Sequence[Mapping[str, Any]]) -> Optional[int]:
    """How many terminals the steps surely leave: the sure creators, or None when a step may make or end one."""
    sure = 0
    for step in steps:
        name = method(step)
        if name is None:
            continue
        params = (step.get("args") or {}).get("params") or {}
        creates = name in CREATES_TERMINAL or (name == "workspace.create" and params.get("initial_content") == "terminal")
        if (step.get("expect") or {}).get("outcome") == "error" and (creates or name == "workspace.create"):
            continue  # a refused create makes nothing
        if creates and "argv" not in params and "command" not in params:
            sure += 1
        elif creates or name in MAY_CREATE_TERMINAL or name == "workspace.create" or ENDS_SOMETHING.search(name):
            return None
    return sure


def terminal_count_is_one(steps: Sequence[Mapping[str, Any]]) -> bool:
    """Whether the steps surely leave exactly one terminal (a host-abort walk's precondition)."""
    return sure_terminals(steps) == 1


def has_running_terminal(steps: Sequence[Mapping[str, Any]]) -> bool:
    """Whether the acknowledged state surely has a terminal: then the restart waits for the first one to run
    again. A walk that may have closed it gets no wait (a closed terminal leaves the list empty)."""
    return (sure_terminals(steps) or 0) >= 1


def fault_candidates(steps: Sequence[Mapping[str, Any]], classes: Mapping[str, str], fault: str) -> List[int]:
    """The kill points of `fault`: every kill candidate, and for host-abort only those after which exactly one
    terminal surely runs."""
    candidates = kill_candidates(steps, classes)
    if fault != HOST_ABORT:
        return candidates
    return [index for index in candidates if terminal_count_is_one(steps[:index + 1])]


def plan(seed: int, walks: Sequence[Walk], classes: Mapping[str, str],
         faults: Sequence[str] = FAULTS) -> KillPoint:
    """The crash walk of `seed`: a fault, then a walk and a kill point that fault can follow, all from one seeded
    generator, so the plan never depends on a run. A host-abort draw takes only walks with a kill point after
    which exactly one terminal runs; with none, the draw is a SIGKILL walk when the fault set allows another
    fault, else the plan is refused."""
    if not walks:
        raise CrashWalkError("no usable walk")
    draw = [fault for fault in FAULT_DRAW if fault in faults]
    if not draw:
        raise CrashWalkError(f"no fault of {list(faults)} is drawn")
    rng = random.Random(f"{SEED_PREFIX}{seed}")
    fault = rng.choice(draw)
    eligible = [(walk, points) for walk in walks for points in [fault_candidates(walk.steps, classes, fault)]
                if points]
    if not eligible and fault == HOST_ABORT:
        others = [other for other in draw if other != HOST_ABORT]
        if not others:
            raise CrashWalkError("no walk has a kill point after which exactly one terminal runs, which a "
                                 "host-abort walk needs")
        fault = SIGKILL if SIGKILL in others else others[0]
        eligible = [(walk, kill_candidates(walk.steps, classes)) for walk in walks]
    if not eligible:
        raise CrashWalkError("no walk has a kill point")
    walk, points = eligible[rng.randrange(len(eligible))]
    index = rng.choice(points)
    return KillPoint(seed, walk.id, index, str(walk.steps[index]["id"]), fault)


# ---------------------------------------------------------------------------------------------------------
# The crash case


def references(value: Any) -> Set[str]:
    """The step ids that `$step:` references anywhere in `value` name."""
    found: Set[str] = set()
    if isinstance(value, str):
        found.update(STEP_REF.findall(value))
    elif isinstance(value, list):
        for item in value:
            found |= references(item)
    elif isinstance(value, dict):
        for item in value.values():
            found |= references(item)
    return found


def closure(steps: Sequence[Mapping[str, Any]], keep: Iterable[int]) -> List[int]:
    """`keep` and every step a kept step references, transitively, in walk order."""
    by_id = {step.get("id"): i for i, step in enumerate(steps)}
    kept = set(keep)
    pending = list(kept)
    while pending:
        for name in references(steps[pending.pop()]):
            index = by_id.get(name)
            if index is not None and index not in kept:
                kept.add(index)
                pending.append(index)
    return sorted(kept)


def last_acked_mutation(steps: Sequence[Mapping[str, Any]], classes: Mapping[str, str]) -> Optional[Mapping[str, Any]]:
    """The last mutation the walk expects to succeed and sends with an idempotency key: its reply is the one the
    replay must get back."""
    for step in reversed(steps):
        name = method(step)
        if (name and classes.get(name) == "mutation" and (step.get("args") or {}).get("idempotencyKey")
                and (step.get("expect") or {}).get("outcome") == "ok" and not step.get("ends")):
            return step
    return None


def snapshot_step(step_id: str, expect: Dict[str, Any]) -> Dict[str, Any]:
    """A session.snapshot read (case-v1 needs readOnly on a call without an idempotency key)."""
    return {"id": step_id, "op": "resource.call", "target": dict(SELECTORS),
            "args": {"method": "session.snapshot", "params": {}}, "readOnly": True, "expect": expect}


def tail_steps(prefix: Sequence[Mapping[str, Any]], fault: str, classes: Mapping[str, str]) -> List[Dict[str, Any]]:
    steps: List[Dict[str, Any]] = [snapshot_step(ACKED, {"outcome": "ok"})]
    if fault == HOST_ABORT:
        steps.append({"id": ABORT, "op": "kill", "target": {"process": "holder"}, "args": {"signal": "ABRT"},
                      "expect": {"outcome": "ok", "noReceiptReason": "a kill sends no request; its reply is the "
                                                                    "daemon's record of the ended host"}})
    steps.append({"id": KILL, "op": "kill", "target": {"process": "daemon"}, "args": {"signal": "KILL"},
                  "expect": {"outcome": "ok", "noReceiptReason": "a SIGKILL sends no request; the recovered state is "
                                                                "its result"}})
    recover: Dict[str, Any] = {"id": RECOVER, "op": "restart", "target": {"process": "daemon"},
                               "expect": {"outcome": "ok", "receipt": "identify"}}
    if has_running_terminal(prefix):
        recover["waitFor"] = {"pointer": "/daemon/session/terminals/0/lifecycle", "equals": "running",
                              "maxMs": ADOPT_WAIT_MS}
    steps.append(recover)
    steps.append(snapshot_step(RECOVERED, {"outcome": "ok", "result": f"$step:{ACKED}#",
                                           "resultExcept": list(RECOVERED_EXCEPT)}))
    acked = last_acked_mutation(prefix, classes)
    if acked is not None:
        replay: Dict[str, Any] = {"id": REPLAY}
        replay.update((key, copy.deepcopy(acked[key])) for key in ("op", "target", "args") if key in acked)
        replay["expect"] = {"outcome": "ok", "receipt": "mutation_result", "result": f"$step:{acked['id']}#",
                            "resultExcept": list(REPLAY_EXCEPT)}
        steps.append(replay)
    return steps


def allow_crashes(walk: Mapping[str, Any], kept_ids: Set[str], fault: str) -> List[Dict[str, Any]]:
    entries: List[Dict[str, Any]] = []
    for entry in walk.get("allow_crashes") or ():
        named = entry.get("steps")
        if named is None:
            entries.append(copy.deepcopy(entry))
            continue
        still = [name for name in named if name in kept_ids]
        if still:
            entries.append({**copy.deepcopy(entry), "steps": still})
    entries.append({"kind": "daemon", "reason": "the crash walk kills the session owner on purpose (SIGKILL)",
                    "steps": [KILL]})
    if fault == HOST_ABORT:
        entries.append({"kind": "holder", "reason": "the crash walk aborts the terminal host on purpose (its crash "
                                                    "seam, SIGABRT)", "steps": [ABORT]})
    return entries


def crash_case(walk: Walk, point: KillPoint, classes: Mapping[str, str],
               keep: Optional[Iterable[int]] = None, case_id: Optional[str] = None) -> Dict[str, Any]:
    """The case-v1 crash case of `point`: the walk's steps up to the kill point (`keep` of those before it, with
    what they reference; all of them when None), then the crash steps. Its id is `case_id`, else the point's."""
    steps = walk.steps
    if point.walk != walk.id or point.after != steps[point.index].get("id"):
        raise CrashWalkError(f"kill point {point.case_id} is not on walk {walk.id}")
    chosen = range(point.index) if keep is None else [i for i in keep if i < point.index]
    indices = closure(steps, [*chosen, point.index])
    prefix = [copy.deepcopy(dict(steps[i])) for i in indices]
    source = walk.case
    # The walk's own fixture seed, so the daemon names its objects as it does in the walk.
    fixture = {"seed": f"crash.{point.seed}", "network": "offline", "clock": "virtual",
               **{key: value for key, value in (source.get("fixture") or {}).items() if key in CASE_FIXTURE_KEYS}}
    kept_ids = {str(step["id"]) for step in prefix}
    untested = ["the state between the kill and the last acknowledged step (an unacknowledged call may or may not "
                "survive; this case sends none)"]
    if point.fault == OWNER_PANIC:
        untested.append("the recovering owner's worker-thread panic (CMUX_TUI_TEST_OWNER_PANIC=thread): only "
                        "crash_walks.py run and replay set it; oracle.py runs this case as a SIGKILL walk")
    tail = tail_steps(prefix, point.fault, classes)
    invariants = [
        f"generated by scripts/cmux-next/oracle/crash_walks.py ({TASK}) from seed {point.seed}: walk {walk.id}, "
        f"{point.fault} after step {point.after}",
        f"{RECOVERED} replies what {ACKED} replied, but for what a new daemon generation changes: a restart on "
        f"the same root after the kill keeps every acknowledged mutation",
    ]
    if any(step["id"] == REPLAY for step in tail):
        invariants.append(f"{REPLAY} replies the receipt the daemon acknowledged before the kill (I10 across a "
                          f"crash)")
    return {
        "$schema": "../../../../schemas/oracle/case-v1.schema.json",
        "corpusVersion": 1,
        "id": case_id or point.case_id,
        "suite": SUITE,
        "title": f"Crash walk {point.seed}: {point.fault} after {walk.id} step {point.after}, then the last "
                 f"acknowledged state",
        "surface": "cmux-next-daemon",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        "environment": {},
        "fixture": fixture,
        "preconditions": ["hermetic state root", "no other cmux-tui on the state root"],
        "requires": sorted(set(source.get("requires") or ()) | WALK_REQUIRES),
        "switches": sorted(set(source.get("switches") or ()) | {HOLDER_SWITCH}),
        "platforms": list(source.get("platforms") or ("linux", "mac")),
        "allow_crashes": allow_crashes(source, kept_ids, point.fault),
        "steps": prefix + tail,
        "invariants": invariants,
        "teardown": ["stop the case daemon", "verify the socket and state root are gone"],
        "untested": untested,
    }


# ---------------------------------------------------------------------------------------------------------
# ddmin


Outcome = Callable[[List[int]], bool]


def chunks_of(items: Sequence[int], count: int) -> List[List[int]]:
    """`items` in `count` contiguous chunks whose sizes differ by at most one."""
    size, extra = divmod(len(items), count)
    out, start = [], 0
    for index in range(count):
        end = start + size + (1 if index < extra else 0)
        out.append(list(items[start:end]))
        start = end
    return out


def ddmin(items: Sequence[int], fails: Outcome) -> List[int]:
    """Zeller's ddmin: a 1-minimal subset of `items` for which `fails` holds (it holds for `items`): removing any
    one item more makes it pass. `fails` is asked about chunks, then their complements, at a granularity that
    doubles until it is one item; an unresolved subset answers False. The empty subset is asked first: most crash
    walks fail with no step before the kill point."""
    current = list(items)
    if not current or fails([]):
        return []
    granularity = 2
    while len(current) >= 2:
        chunks = chunks_of(current, granularity)
        smaller = next((chunk for chunk in chunks if fails(chunk)), None)
        if smaller is not None:
            current, granularity = smaller, 2
            continue
        complements = ([item for item in current if item not in chunk] for chunk in chunks)
        rest = next((left for left in complements if granularity > 2 and fails(left)), None)
        if rest is not None:
            current, granularity = rest, max(granularity - 1, 2)
            continue
        if granularity >= len(current):
            break
        granularity = min(granularity * 2, len(current))
    return current


@dataclass(frozen=True)
class Failure:
    """What a crash walk's failure is, for ddmin: the same status at the same step."""

    status: str
    step: Optional[str]

    @classmethod
    def of(cls, result: Mapping[str, Any]) -> Optional["Failure"]:
        status = result.get("status")
        if status in (None, "Pass", "Skip"):
            return None
        return cls(str(status), result.get("step"))

    def kind(self, killed: Optional[bool]) -> str:
        """`walk` when the walk failed before its kill point, else `crash`. By position: a walk step, or
        crash-acked (it reads the state before the fault), is the walk's; a crash step after it is the crash's.
        A failure that names no step (the teardown's I6 proof, a worker over its bound) is the walk's only when
        the case never reached crash-kill (`killed` False); unknown (None) counts as the crash's."""
        if self.step is None:
            return "walk" if killed is False else "crash"
        return "crash" if self.step in CRASH_STEPS - {ACKED} else "walk"


def signature(failure: Failure, message: str) -> str:
    """What makes two failing walks one finding, as ClusterFuzz groups crashes by their crash state: the status,
    the step and the message's first clause without its values, paths and numbers (so `/terminals/1/cwd` and
    `/terminals/0/cwd` group)."""
    head = VOLATILE.sub("_", message.split(";")[0])
    return f"{failure.status} {failure.step}: {head[:160]}"


def minimize(walk: Walk, point: KillPoint, classes: Mapping[str, str], failure: Failure,
             run: Callable[[Dict[str, Any]], Mapping[str, Any]], case_id: Optional[str] = None
             ) -> Tuple[List[int], Dict[str, Any]]:
    """The fewest steps before the kill point that still fail as `failure`, and their crash case (id `case_id`).
    `run` runs one case and returns its result."""
    steps = walk.steps

    def fails(keep: List[int]) -> bool:
        running = running_after([steps[i] for i in closure(steps, [*keep, point.index])])
        if not running or not running[-1]:
            return False  # unresolved: the reduced walk cannot reach its kill point with the daemon up
        return Failure.of(run(crash_case(walk, point, classes, keep, case_id))) == failure

    kept = ddmin(list(range(point.index)), fails)
    return kept, crash_case(walk, point, classes, kept, case_id)


Job = Tuple[KillPoint, str]
Grouped = Tuple[KillPoint, str, Dict[str, Any]]


def group_failures(jobs: Sequence[Job], records: Sequence[Dict[str, Any]]) -> Tuple[Dict[str, List[Grouped]], int]:
    """The run's crash failures by signature, and the count of walk failures (the walk failed before its kill
    point: the walk's own suite owns it). Each failing record gets its `signature` and `side`."""
    groups: Dict[str, List[Grouped]] = {}
    walk_failures = 0
    for (point, arm), record in zip(jobs, records):
        failure = Failure.of(record)
        if failure is None:
            continue
        record["signature"] = signature(failure, str(record.get("message") or ""))
        record["side"] = failure.kind(record.get("killed"))
        if record["side"] == "walk":
            walk_failures += 1
            continue
        groups.setdefault(record["signature"], []).append((point, arm, record))
    return groups, walk_failures


def representatives(groups: Mapping[str, Sequence[Grouped]]) -> List[Grouped]:
    """One failing walk per signature, the one with the fewest steps before its kill point. Each becomes its own
    case (KillPoint.found_id); two that would share an id are refused, so no write replaces another."""
    chosen = [min(group, key=lambda item: (item[0].index, item[0].seed, item[1]))
              for _, group in sorted(groups.items())]
    ids = [point.found_id(arm) for point, arm, _ in chosen]
    if len(set(ids)) != len(ids):
        raise CrashWalkError(f"two minimized failures would share a case id: {sorted(ids)}")
    return chosen


# ---------------------------------------------------------------------------------------------------------
# Corpus files


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=False, ensure_ascii=False) + "\n", encoding="utf-8")


def read_kill_points(directory: Path) -> Dict[str, Dict[str, Any]]:
    path = directory / KILL_POINTS
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema") != KILL_POINTS_SCHEMA:
        raise CrashWalkError(f"{path}: schema is not {KILL_POINTS_SCHEMA}")
    return dict(data.get("cases") or {})


def write_kill_points(directory: Path, cases: Mapping[str, Mapping[str, Any]]) -> None:
    write_json(directory / KILL_POINTS, {
        "schema": KILL_POINTS_SCHEMA,
        "generator": f"scripts/cmux-next/oracle/crash_walks.py ({TASK})",
        "cases": {key: cases[key] for key in sorted(cases)},
    })


def write_coverage(directory: Path, records: Mapping[str, Mapping[str, Any]]) -> None:
    """The suite's coverage: the fault kinds with a case."""
    found = {record["fault"] for record in records.values()}
    excluded: Dict[str, str] = {}
    write_json(directory / "coverage.json", {
        "generator": "scripts/cmux-next/oracle/crash_walks.py",
        "suite": SUITE,
        "total": len(FAULTS),
        "covered": len(found & set(FAULTS)),
        "verdicts": "not run",
        "excluded": excluded,
        "missing": sorted(set(FAULTS) - found - set(excluded)),
        "faults": {fault: sorted(k for k, r in records.items() if r["fault"] == fault) for fault in FAULTS},
    })


Results = Mapping[str, Mapping[str, Any]]


def kill_point_record(point: KillPoint, case: Mapping[str, Any], walk: Walk, *,
                      found: Optional[Mapping[str, Any]] = None, results: Optional[Results] = None) -> Dict[str, Any]:
    record = {**point.to_json(), "walkSteps": len(walk.steps), "caseSteps": len(case["steps"])}
    if found is not None:
        record["found"] = dict(found)
    if results:
        record["results"] = {arm: dict(results[arm]) for arm in sorted(results)}
    return record


def write_case(directory: Path, point: KillPoint, case: Mapping[str, Any], walk: Walk,
               found: Optional[Mapping[str, Any]] = None, results: Optional[Results] = None) -> None:
    """The case file and its kill point (by the case's id); the suite's coverage and the expectations of its
    failing results follow."""
    case_id = str(case["id"])
    write_json(directory / f"{case_id}.json", case)
    records = read_kill_points(directory)
    records[case_id] = kill_point_record(point, case, walk, found=found, results=results)
    write_kill_points(directory, records)
    write_coverage(directory, records)
    write_expectations(expectations_path(directory), records)


def merge_results(runs: Sequence[Mapping[str, Any]]) -> Dict[str, Any]:
    """One arm's result over several runs of a case: the last failing run (else the last run), with `seen`, every
    status the runs gave, when they disagree (a flaky case: its expectation lists them all)."""
    if not runs:
        raise CrashWalkError("no run to merge")
    failing = [run for run in runs if run.get("status") in EXPECTED_RESULTS]
    out = dict(failing[-1] if failing else runs[-1])
    seen = sorted({str(run.get("status")) for run in runs})
    if len(seen) > 1:
        out["seen"] = seen
    return out


def record_results(directory: Path, case_id: str, results: Results) -> None:
    """A corpus case's result on each arm (`replay --record`, which replaces what the arm had), and the
    expectations that follow."""
    records = read_kill_points(directory)
    if case_id not in records:
        raise CrashWalkError(f"{directory / KILL_POINTS} has no kill point for {case_id}")
    merged = {**(records[case_id].get("results") or {}), **{arm: dict(value) for arm, value in results.items()}}
    records[case_id]["results"] = {arm: merged[arm] for arm in sorted(merged)}
    write_kill_points(directory, records)
    write_expectations(expectations_path(directory), records)


# The crash suite's known failures, as Blink keeps a failing test in TestExpectations with its bug: a corpus case
# whose recorded result on an arm is not Pass gets a line, so a default oracle run counts it as expected. This file
# owns one block of tests/oracle/Expectations.d/crash.txt (expectations.py); lines outside the block are kept.
EXPECTATIONS_GENERATOR = "scripts/cmux-next/oracle/crash_walks.py"
EXPECTATIONS_BEGIN_PREFIX = f"# BEGIN {EXPECTATIONS_GENERATOR}:"
EXPECTATIONS_BEGIN = f"{EXPECTATIONS_BEGIN_PREFIX} the crash cases whose recorded result ({KILL_POINTS}) is not Pass"
EXPECTATIONS_END = f"# END {EXPECTATIONS_GENERATOR}"
EXPECTATIONS_HEADER = (f"# {SUITE} expectations (format: scripts/cmux-next/oracle/expectations.py).\n"
                       f"# {EXPECTATIONS_GENERATOR} writes the block below from the results in {KILL_POINTS}\n"
                       "# (`run`, `replay --record`): do not edit the block. Lines outside it are kept.\n")
EXPECTED_RESULTS = ("Failure", "Crash", "Timeout")
HOST_ABORT_LINE = "p15-oracle-224 {case}/" + ABORT + " [ Crash ]"


def expectations_path(directory: Path) -> Path:
    """`<oracle root>/Expectations.d/crash.txt` for the suite directory `<oracle root>/corpus/crash`."""
    return directory.parent.parent / "Expectations.d" / f"{SUITE}.txt"


def expectation_lines(records: Mapping[str, Mapping[str, Any]]) -> List[str]:
    """`<task> [ <arm> ] crash/<case>/<step> [ <results> ]` per failing recorded result (every status a flaky one
    gave): no arm tag when every arm fails the same way, no step when the failure names none. A host-abort case
    also gets HOST_ABORT_LINE: oracle.py runs it on driver_daemon.py, which kills no terminal host until
    p15-oracle-224, so it ends at crash-abort there (its crash_driver.py results after that step stay recorded)."""
    lines = []
    for case_id in sorted(records):
        by_failure: Dict[Tuple[str, Tuple[str, ...]], List[str]] = {}
        host_abort = records[case_id].get("fault") == HOST_ABORT
        for arm, result in (records[case_id].get("results") or {}).items():
            status, step = str(result.get("status")), str(result.get("step") or "")
            if status in EXPECTED_RESULTS and not (host_abort and step == ABORT):
                statuses = tuple(sorted((set(result.get("seen") or ()) & {"Pass", *EXPECTED_RESULTS}) | {status}))
                by_failure.setdefault((step, statuses), []).append(arm)
        if host_abort:
            lines.append(HOST_ABORT_LINE.format(case=f"{SUITE}/{case_id}"))
        for (step, statuses), arms in sorted(by_failure.items()):
            tags = "" if sorted(arms) == sorted(ARMS) else "".join(f"[ {arm} ] " for arm in sorted(arms))
            target = f"{SUITE}/{case_id}" + (f"/{step}" if step else "")
            lines.append(f"{TASK} {tags}{target} [ {' '.join(statuses)} ]")
    return lines


def render_expectations(existing: str, lines: Sequence[str]) -> str:
    """`existing` with this file's block replaced by `lines` (appended, with a header for a new file); the block
    goes when no line is left."""
    begin, end = existing.find(EXPECTATIONS_BEGIN_PREFIX), existing.find(EXPECTATIONS_END)
    if (begin >= 0) != (end >= 0) or end < begin:
        raise CrashWalkError(f"the {SUITE} expectations file has one of the block markers without the other")
    block = "\n".join([EXPECTATIONS_BEGIN, *lines, EXPECTATIONS_END]) + "\n" if lines else ""
    if begin >= 0:
        tail = existing[end + len(EXPECTATIONS_END):]
        return existing[:begin] + block + (tail[1:] if tail.startswith("\n") else tail)
    if not block:
        return existing
    if not existing.strip():
        return EXPECTATIONS_HEADER + block
    return existing + ("" if existing.endswith("\n") else "\n") + block


def write_expectations(path: Path, records: Mapping[str, Mapping[str, Any]]) -> None:
    existing = path.read_text(encoding="utf-8") if path.is_file() else ""
    text = render_expectations(existing, expectation_lines(records))
    if text != existing:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


# ---------------------------------------------------------------------------------------------------------
# Commands


def host_platform() -> str:
    return "linux" if sys.platform.startswith("linux") else "mac"


def walk_paths(values: Optional[Sequence[str]]) -> List[Path]:
    if values:
        return [Path(value) for value in values]
    return [path for path in WALK_SOURCES if path.is_dir()][:1]


def parse_faults(value: str) -> Tuple[str, ...]:
    faults = tuple(part.strip() for part in value.split(",") if part.strip())
    unknown = sorted(set(faults) - set(FAULTS))
    if unknown or not faults:
        raise argparse.ArgumentTypeError(f"faults are {', '.join(FAULTS)}")
    return faults


def parse_arms(value: str) -> Tuple[str, ...]:
    arms = tuple(part.strip() for part in value.split(",") if part.strip())
    if not arms or set(arms) - set(ARMS):
        raise argparse.ArgumentTypeError(f"arms are {', '.join(ARMS)}")
    return arms


def loaded(args: argparse.Namespace) -> Tuple[List[Walk], Dict[str, str]]:
    """The usable walks of the command's sources and the operation classes."""
    walks, _ = load_walks(walk_paths(args.walks), host_platform(), expected_cases())
    if not walks:
        raise CrashWalkError(f"no usable walk under {', '.join(map(str, walk_paths(args.walks)))}")
    return walks, operation_classes()


def cmd_plan(args: argparse.Namespace) -> int:
    walks, classes = loaded(args)
    for seed in range(args.first_seed, args.first_seed + args.seeds):
        print(json.dumps(plan(seed, walks, classes, args.faults).to_json(), sort_keys=True))
    return 0


def cmd_gen(args: argparse.Namespace) -> int:
    walks, classes = loaded(args)
    by_id = {walk.id: walk for walk in walks}
    for seed in range(args.first_seed, args.first_seed + args.seeds):
        point = plan(seed, walks, classes, args.faults)
        walk = by_id[point.walk]
        write_case(args.out, point, crash_case(walk, point, classes), walk)
    print(f"crash_walks.py: {args.seeds} crash cases in {args.out}")
    return 0


def add_walk_options(cmd: argparse.ArgumentParser, seeds: int) -> None:
    cmd.add_argument("--walks", nargs="+", help="walk case files or directories (default: tests/oracle/corpus/walks, "
                                                "else daemon-ops)")
    cmd.add_argument("--seeds", type=int, default=seeds)
    cmd.add_argument("--first-seed", type=int, default=0)
    cmd.add_argument("--faults", type=parse_faults, default=FAULTS, help=f"comma list of {', '.join(FAULTS)}")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--selftest", action="store_true", help="run crash_walks_test.py")
    sub = parser.add_subparsers(dest="command")
    add_walk_options(sub.add_parser("plan", help="print each seed's kill point"), 20)
    gen = sub.add_parser("gen", help="write crash cases into the corpus")
    add_walk_options(gen, 12)
    gen.add_argument("--out", type=Path, default=CRASH_DIR)
    run = sub.add_parser("run", help="run crash walks on the holder arms, minimize failures")
    add_walk_options(run, 5000)
    run.add_argument("--binary", required=True)
    run.add_argument("--arms", type=parse_arms, default=ARMS)
    run.add_argument("--jobs", type=int, default=200)
    run.add_argument("--out", type=Path, default=Path("/tmp/oracle-crash-walks"))
    run.add_argument("--corpus", type=Path, default=CRASH_DIR, help="where minimized failures go")
    run.add_argument("--no-minimize", action="store_true")
    run.add_argument("--isolation", choices=("netns", "auto", "none"), default="netns")
    run.add_argument("--state-base", type=Path, default=Path("/tmp/o"))
    replay = sub.add_parser("replay", help="corpus crash cases with their recorded faults")
    replay.add_argument("cases", type=Path, nargs="+")
    replay.add_argument("--binary", required=True)
    replay.add_argument("--arms", type=parse_arms, default=ARMS)
    replay.add_argument("--jobs", type=int, default=24)
    replay.add_argument("--repeat", type=int, default=1, help="runs of each case on each arm (a flaky result "
                                                              "records every status it gave)")
    replay.add_argument("--record", action="store_true", help="keep each result in _kill-points.json and crash.txt")
    replay.add_argument("--isolation", choices=("netns", "auto", "none"), default="netns")
    replay.add_argument("--state-base", type=Path, default=Path("/tmp/o"))
    args = parser.parse_args(argv)
    if args.selftest:
        import crash_walks_test  # noqa: PLC0415 - sibling, only for --selftest

        return crash_walks_test.main()
    try:
        if args.command == "plan":
            return cmd_plan(args)
        if args.command == "gen":
            return cmd_gen(args)
        if args.command in ("run", "replay"):
            # The driver imports the SDK and driver_daemon.py; planning needs neither.
            import crash_driver  # noqa: PLC0415 - sibling of this file

            return crash_driver.cmd_run(args) if args.command == "run" else crash_driver.cmd_replay(args)
    except (CrashWalkError, ValueError) as error:
        print(f"crash_walks.py: {error}", file=sys.stderr)
        return 2
    parser.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
