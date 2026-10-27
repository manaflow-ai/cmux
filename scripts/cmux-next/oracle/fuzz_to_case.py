#!/usr/bin/env python3
"""Turn a crash of the resource_ops fuzz target into an oracle walk case (p15-oracle-186).

The cmux-tui/fuzz target `resource_ops` sends typed resource-op sequences through the daemon's dispatch in
process, on the daemon's own owner model (a registry on disk and one `__terminal-host` per terminal, the default
terminal model driver_daemon.py runs), and stops on a daemon panic or a broken invariant: I1, I2 or I19, each the
rule invariants.py checks on the converted case. This script replays one crash input with CMUX_RESOURCE_OPS_WALK
set, so the target writes its walk (fuzz_targets/support/resource_walk.rs `Recorder`): each step as a case-v1 step
(every id as a `$step:` reference to the reply that named it, so the case names the same object in the oracle's
daemon, whose ids are random), each checkpoint before its `session.snapshot` read, each reply's outcome, and the
broken invariant. It writes the walk as a case of the `fuzz` suite (tests/oracle/corpus/fuzz/<id>.json) that the
daemon driver runs (driver_daemon.py run-case):

- every step before the crash expects the outcome it had, so the case keeps the path to the crash;
- an I1 violation's step expects what I1 requires, so the case fails on the build that crashed: a mutation whose
  result is no MutationResult, or that the daemon refused as outside its own catalog (`details.extra.contract:
  result`), expects a mutation_result receipt; an error the catalog refused (`contract: error`: a code it does not
  declare, or a declared code with the wrong details or retryability) expects the code the operation emitted
  (`extra.emitted_code`);
- an I2 or I19 violation keeps the observed replies and ends where the oracle observes it: at the step's settled
  checkpoint, or, for a before checkpoint (the previous step's late effects, invariants.py `Checker.owner`), at a
  snapshot step with a before checkpoint after the previous step;
- a panic on the request thread ends at the work it died in, which the walk's last line names: a request with no
  reply expects its own receipt; a checkpoint's `session.snapshot` read ends at that checkpoint (the step's
  settled one keeps its observed reply; a before one is a snapshot step); the teardown keeps every step;
- a panic on another thread (a terminal host's reader, a work item; the replay's stderr names it) ran the effect
  of an earlier step: the case ends at the last step that got a reply, with its observed outcome, then a settle
  step, so it asserts nothing about the step that happened to be in flight.

`convert` then runs the case once through driver_daemon.py on the crashing build's cmux-tui (`--cmux-tui`, built
from the same commit as the fuzz binary) with a trace and the target's blocking-check mode (`--daemon-blocking
record`, which the case's preconditions name), and keeps it only when it fails there as the fuzz target
did: the named invariant in invariants.py's report at the named step and checkpoint, or the driver's Failure or
Crash at the crashing step. A crash input that no longer crashes, or whose case does not fail, is refused (exit 1).

Chrome reference (chromium/src): ClusterFuzz turns each fuzzer crash into a reproducible test case (the input,
the target and the stack) and confirms it reproduces before it files it; testing/libfuzzer/reproducing.md replays
one input by passing its path to the target binary, which is what `reproduce` does here.

The VM run (task test phase): `scripts/cmux-next/rust-fuzz.sh --target resource_ops --seconds 3600 -- -fork=300`,
then `fuzz_to_case.py convert --binary cmux-tui/fuzz/target/x86_64-unknown-linux-gnu/release/resource_ops
--cmux-tui <debug or --profile oracle cmux-tui of the same commit> <out>/artifacts/resource_ops/*/crash-*`.

Usage:
  fuzz_to_case.py convert --binary RESOURCE_OPS --cmux-tui CMUX_TUI CRASH... [--out DIR] [--minimize SECONDS]
                          [--isolation netns|auto|none]
      the case of each crash input, checked on CMUX_TUI; --minimize first runs libFuzzer's -minimize_crash on it
  fuzz_to_case.py --selftest
      offline tests of the walk-to-case conversion and the reproduction check (no fuzz binary, no daemon)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
CORPUS = REPO / "tests" / "oracle" / "corpus"
SUITE = "fuzz"
TARGET = "resource_ops"
WALK_ENV = "CMUX_RESOURCE_OPS_WALK"
# A replay is one input: well under a minute unless the daemon hangs, which is then the finding.
REPLAY_TIMEOUT_S = 120
# One case on a fresh daemon: its start, the steps and an orderly teardown.
CASE_TIMEOUT_S = 600
PANIC_LINE = re.compile(r"^thread '([^']*)'(?: \(\d+\))? panicked at", re.MULTILINE)
FAILED = ("Failure", "Crash", "Timeout")
# The target's blocking-check mode (resource_ops.rs `hermetic_environment`): a blocking call on a thread that
# disallows it is I11's finding, recorded, not a crash. The check run gives the case daemon the same mode.
BLOCKING = "record"


class ConvertError(Exception):
    pass


def read_walk(text: str) -> Dict[str, Any]:
    """The walk lines of one replay: the steps in order, each step's reply, the violation (none for a daemon
    panic, which writes no line) and the last line's place, the work the process was in when it stopped."""
    steps: List[Dict[str, Any]] = []
    replies: Dict[str, Dict[str, Any]] = {}
    violation: Optional[Dict[str, Any]] = None
    last: Optional[Dict[str, Any]] = None
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise ConvertError(f"walk line {number}: {error}") from None
        kind = record.get("walk") if isinstance(record, dict) else None
        if kind == "step":
            steps.append(record["step"])
            last = {"at": "request", "step": record["step"]["id"]}
        elif kind == "reply":
            replies[record["step"]] = record
            last = {"at": "reply", "step": record["step"]}
        elif kind == "checkpoint":
            last = {"at": record["checkpoint"], "step": record["step"]}
        elif kind == "teardown":
            last = {"at": "teardown", "step": None}
        elif kind == "violation":
            violation = record
        else:
            raise ConvertError(f"walk line {number}: unknown record {kind!r}")
    if last is None:
        raise ConvertError("the walk is empty: the crash happened before the first checkpoint")
    return {"steps": steps, "replies": replies, "violation": violation, "last": last}


def mutating(step: Mapping[str, Any]) -> bool:
    return step.get("op") == "resource.call" and step.get("readOnly") is not True


def receipt(step: Mapping[str, Any]) -> Dict[str, Any]:
    return {"outcome": "ok", "receipt": "mutation_result"} if mutating(step) else {"outcome": "ok"}


def observed_expect(step: Mapping[str, Any], reply: Mapping[str, Any]) -> Dict[str, Any]:
    if reply["outcome"] == "error":
        return {"outcome": "error", "error": reply["error"]}
    return receipt(step)


def required_expect(step: Mapping[str, Any], reply: Optional[Mapping[str, Any]],
                    violation: Optional[Mapping[str, Any]]) -> Dict[str, Any]:
    """The crashing step's expectation. A step whose request the daemon died in owes its receipt. A step with a
    reply keeps it unless I1 refused the reply itself: then what I1 requires, so the case fails where it crashed."""
    if reply is None:
        return receipt(step)
    if violation is None or violation.get("invariant") != "I1" or violation.get("step") != step["id"]:
        return observed_expect(step, reply)
    details = reply.get("details") if isinstance(reply.get("details"), Mapping) else {}
    extra = details.get("extra") if isinstance(details.get("extra"), Mapping) else {}
    if extra.get("contract") == "error":
        code = extra.get("emitted_code")
        if not isinstance(code, str):
            raise ConvertError(f"step {step['id']}: the daemon refused its own error but names no emitted_code "
                               f"(a daemon from before p15-oracle-186): {json.dumps(extra)[:300]}")
        return {"outcome": "error", "error": code}
    return receipt(step)


def panic_thread(stderr: str) -> Optional[str]:
    """The thread of the first Rust panic in a replay's stderr (`thread '<name>' (<tid>) panicked at`)."""
    match = PANIC_LINE.search(stderr)
    return match.group(1) if match else None


def synchronous(thread: Optional[str]) -> bool:
    """A panic on the thread that sent the request: the input's own thread, which libFuzzer's C main starts
    with no Rust name. A request thread's panic belongs to the work it ran; another thread's (a terminal host's
    reader, a work item) to an earlier step whose effect it ran, so it is not the step that was in flight."""
    return thread in (None, "main", "<unnamed>")


@dataclass(frozen=True)
class Expected:
    """How the case must fail on the crashing build: the invariant invariants.py reports at `step`/`checkpoint`,
    or (invariant None) the driver's Failure or Crash at `step` (None: at any step or at teardown)."""
    invariant: Optional[str]
    step: Optional[str]
    checkpoint: Optional[str] = None

    def describe(self) -> str:
        where = f"step {self.step}" if self.step else "any step or the teardown"
        if self.invariant:
            return f"{self.invariant} at {where}/{self.checkpoint}"
        return f"a driver Failure or Crash at {where}"


def snapshot_step(step_id: str) -> Dict[str, Any]:
    """A runner step whose before checkpoint observes what the previous step left (invariants.py
    `Checker.owner`: a before checkpoint's changes are the previous step's)."""
    return {"id": f"{step_id}-before", "op": "snapshot", "args": {"facets": ["daemon"]}, "checkpoint": ["before"],
            "note": f"the before checkpoint of fuzz step {step_id}, where the target observed the crash"}


def case_of(walk: Mapping[str, Any], crash: bytes, target: str = TARGET,
            thread: Optional[str] = None) -> Tuple[Dict[str, Any], Expected]:
    """The walk case of one crash and how it must fail (see the module docstring)."""
    digest = hashlib.sha1(crash).hexdigest()
    case_id = f"{target.replace('_', '-')}-{digest[:12]}"
    violation = walk["violation"]
    replies = walk["replies"]
    written = [step["id"] for step in walk["steps"]]
    tail: List[Dict[str, Any]] = []
    if violation:
        point = {"at": violation.get("checkpoint") or "reply", "step": violation["step"]}
    elif not synchronous(thread):
        answered = [step for step in written if step in replies]
        point = {"at": "async", "step": answered[-1] if answered else None}
    else:
        point = walk["last"]
    at, crashed = point["at"], point["step"]
    if at == "before" and crashed not in written:
        # Observed before the step was sent: the steps so far, then a checkpoint where the target read it.
        end = written[-1] if written else None
        tail.append(snapshot_step(crashed))
        expected = Expected(violation["invariant"] if violation else None, tail[0]["id"],
                            "before" if violation else None)
    elif at in ("teardown", "async"):
        end = crashed if at == "async" else (written[-1] if written else None)
        if at == "async":
            tail.append({"id": "await-panic", "op": "settle", "settleMaxMs": 5000,
                         "note": f"the panic on {thread} ran after the last reply; the daemon must still answer"})
        expected = Expected(None, None)
    else:
        if crashed not in written:
            raise ConvertError(f"the crash names step {crashed}, which is not in the walk")
        end = crashed
        expected = (Expected(violation["invariant"], crashed, violation.get("checkpoint"))
                    if violation and violation.get("checkpoint") else Expected(None, crashed))
    steps = []
    for step in walk["steps"] if end is not None else ():
        step = dict(step)
        reply = replies.get(step["id"])
        if step["id"] == crashed and at not in ("async", "teardown"):
            step["expect"] = required_expect(step, reply, violation)
        elif reply is None:
            raise ConvertError(f"step {step['id']} has no reply but the walk went on past it")
        else:
            step["expect"] = observed_expect(step, reply)
        steps.append(step)
        if step["id"] == end:
            break
    steps.extend(tail)
    if violation:
        broken = (f"{violation['invariant']} at step {violation['step']} "
                  f"({violation.get('checkpoint') or 'its reply'}), {violation['pointer']} of the daemon "
                  f"facet or reply: {violation['message']}")
    elif at == "async":
        after = f"after step {crashed}" if crashed else "before the first reply"
        broken = f"the daemon panicked on thread {thread} {after}"
    elif at == "teardown":
        broken = "the daemon panicked or failed while it ended its terminals at teardown"
    elif at == "request":
        broken = f"the daemon panicked in step {crashed}'s request"
    else:
        broken = f"the daemon panicked in step {crashed}'s {at} checkpoint (session.snapshot)"
    case = {
        "$schema": "../../../../schemas/oracle/case-v1.schema.json",
        "corpusVersion": 1,
        "id": case_id,
        "suite": SUITE,
        "title": f"{target} fuzz crash {digest[:12]}: {broken}"[:200],
        "surface": "cmux-next-daemon",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        "environment": {},
        "fixture": {"seed": f"fuzz.{case_id}", "network": "offline", "clock": "virtual"},
        "preconditions": ["hermetic state root", "no other cmux-tui on the state root",
                          f"the daemon's blocking checks are in {BLOCKING} mode (driver_daemon.py --daemon-blocking "
                          f"{BLOCKING}), as the fuzz target ran"],
        "requires": ["resource_api"],
        "platforms": ["linux", "mac"],
        "steps": steps,
        "invariants": [
            f"converted by scripts/cmux-next/oracle/fuzz_to_case.py from cmux-tui/fuzz {target} input sha1 {digest}",
            f"the crash: {broken}",
            f"on the crashing build the case fails with {expected.describe()}",
        ],
        "teardown": ["stop the case daemon", "verify the socket and state root are gone"],
    }
    if not steps:
        raise ConvertError(f"the crash ({broken}) happened before the first step: no case can reach it")
    return case, expected


def reproduced(expected: Expected, result: Mapping[str, Any], report: Optional[Mapping[str, Any]]) -> Optional[str]:
    """None when the driver's `result` and invariants.py's `report` (cmux.oracle.invariants/v1) show the case
    failing as `expected` says, else why not."""
    status, at = result.get("status"), result.get("step")
    if expected.invariant is None:
        if status in FAILED and (expected.step is None or at == expected.step):
            return None
        return f"want {expected.describe()}, the driver says {status} at {at}: {str(result.get('message'))[:300]}"
    if status in FAILED and at != expected.step:
        return f"the case stopped at {at} ({status}: {str(result.get('message'))[:300]}) before {expected.step}"
    found = [v for v in (report or {}).get("violations", [])
             if v.get("invariant") == expected.invariant and v.get("step") == expected.step
             and v.get("checkpoint") == expected.checkpoint]
    if found:
        return None
    seen = sorted({(v.get("invariant"), v.get("step"), v.get("checkpoint")) for v in (report or {}).get("violations", [])},
                  key=str)
    return f"want {expected.describe()}; invariants.py reports {seen[:10]}"


def run_case(cmux_tui: Path, case: Mapping[str, Any], isolation: str) -> Tuple[Dict[str, Any], Optional[Dict[str, Any]]]:
    """One run of `case` on `cmux_tui` through driver_daemon.py run-case with a trace; the driver's result and
    invariants.py's report on the trace (None when the run captured nothing)."""
    if str(HERE) not in sys.path:
        sys.path.insert(0, str(HERE))
    import invariants  # noqa: E402

    with tempfile.TemporaryDirectory(prefix="resource-ops-case-") as scratch:
        case_path, trace_path = Path(scratch) / "case.json", Path(scratch) / "trace.json"
        case_path.write_text(json.dumps(case, indent=1))
        command = [sys.executable, "-I", str(HERE / "driver_daemon.py"), "run-case", "--binary", str(cmux_tui),
                   "--isolation", isolation, "--daemon-blocking", BLOCKING, "--trace", str(trace_path),
                   str(case_path)]
        try:
            run = subprocess.run(command, capture_output=True, timeout=CASE_TIMEOUT_S, cwd=scratch)
        except subprocess.TimeoutExpired:
            raise ConvertError(f"driver_daemon.py run-case ran past {CASE_TIMEOUT_S} s") from None
        try:
            result = json.loads(run.stdout)
        except json.JSONDecodeError:
            raise ConvertError(f"driver_daemon.py run-case printed no result (exit {run.returncode}): "
                               f"{run.stderr.decode(errors='replace')[-600:]}") from None
        report = None
        if trace_path.exists():
            report = invariants.check_trace(json.loads(trace_path.read_text()), case).to_json()
        return result, report


def reproduce(binary: Path, crash: Path) -> Tuple[Dict[str, Any], Optional[str]]:
    """Runs `binary` on the one input `crash` with the walk recorder on; the walk and the thread of the
    panic, or ConvertError when the input does not crash."""
    with tempfile.TemporaryDirectory(prefix="resource-ops-walk-") as scratch:
        walk_path = Path(scratch) / "walk.jsonl"
        env = {**os.environ, WALK_ENV: str(walk_path)}
        try:
            run = subprocess.run([str(binary), str(crash)], env=env, cwd=scratch, capture_output=True,
                                 timeout=REPLAY_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            raise ConvertError(f"{crash}: the replay ran past {REPLAY_TIMEOUT_S} s (a hang; convert it by hand)") from None
        if run.returncode == 0:
            raise ConvertError(f"{crash}: the input no longer crashes {binary.name}")
        stderr = run.stderr.decode(errors="replace")
        if not walk_path.exists():
            raise ConvertError(f"{crash}: the target wrote no walk (exit {run.returncode}): {stderr[-600:]}")
        return read_walk(walk_path.read_text()), panic_thread(stderr)


def minimize(binary: Path, crash: Path, seconds: int, scratch: Path) -> Path:
    """libFuzzer's crash minimization of one input; the smallest input that still crashes."""
    out = scratch / f"minimized-{crash.name}"
    subprocess.run([str(binary), "-minimize_crash=1", f"-max_total_time={seconds}",
                    f"-exact_artifact_path={out}", str(crash)], cwd=scratch, capture_output=True,
                   timeout=seconds + REPLAY_TIMEOUT_S)
    return out if out.exists() and out.stat().st_size else crash


def validate(case: Mapping[str, Any]) -> List[str]:
    """case-v1 (normalize.py's JSON Schema validator) and its x-oracle checks (case_checks.py)."""
    if str(HERE) not in sys.path:
        sys.path.insert(0, str(HERE))
    import case_checks  # noqa: E402
    import normalize  # noqa: E402
    schema = json.loads(case_checks.SCHEMA.read_text())
    errors = list(normalize.validate(case, schema))
    errors += [finding.message for finding in case_checks.check_case(case, case_checks.Rules(schema))]
    return errors


def convert(binary: Path, cmux_tui: Path, crashes: Sequence[Path], out: Path, minimize_s: int,
            isolation: str) -> int:
    failed = False
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="resource-ops-min-") as scratch:
        for crash in crashes:
            try:
                path = minimize(binary, crash, minimize_s, Path(scratch)) if minimize_s else crash
                walk, thread = reproduce(binary, path)
                case, expected = case_of(walk, path.read_bytes(), thread=thread)
                errors = validate(case)
                if errors:
                    raise ConvertError(f"{crash}: the case is not case-v1: {'; '.join(errors[:5])}")
                why = reproduced(expected, *run_case(cmux_tui, case, isolation))
                if why:
                    raise ConvertError(f"{crash}: the case does not fail on {cmux_tui.name} as the target did: {why}")
            except ConvertError as error:
                print(f"fuzz_to_case.py: {error}", file=sys.stderr)
                failed = True
                continue
            target = out / f"{case['id']}.json"
            target.write_text(json.dumps(case, indent=2, ensure_ascii=False) + "\n")
            print(target)
    return 1 if failed else 0


# ---------------------------------------------------------------------------------------------- selftest


def _op_step(step_id: str, method: str, target: Optional[Dict[str, str]] = None,
             params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    return {"id": step_id, "op": "resource.call",
            "target": {"machine": "current", "session": "current", **(target or {})},
            "args": {"method": method, "params": params or {}, "idempotencyKey": f"fuzz-{step_id}"},
            "checkpoint": ["before", "settled"]}


def _walk(*records: Dict[str, Any]) -> str:
    return "\n".join(json.dumps(record) for record in records) + "\n"


def _reply(step: str, outcome: str = "ok", error: Optional[str] = None, details: Any = None) -> Dict[str, Any]:
    return {"walk": "reply", "step": step, "outcome": outcome, "error": error, "details": details}


def _at(step: str, checkpoint: str) -> Dict[str, Any]:
    return {"walk": "checkpoint", "step": step, "checkpoint": checkpoint}


def _step(step: Dict[str, Any]) -> Dict[str, Any]:
    return {"walk": "step", "step": step}


def _violation(step: str, checkpoint: Optional[str], invariant: str, pointer: str = "/tabs/0",
               message: str = "broken") -> Dict[str, Any]:
    return {"walk": "violation", "step": step, "checkpoint": checkpoint, "invariant": invariant, "pointer": pointer,
            "message": message}


def _refused(contract: str, **extra: Any) -> Dict[str, Any]:
    return {"operation": "workspace.create", "reason": "operation error violates the embedded catalog",
            "extra": {"contract": contract, **extra}}


CREATE = _op_step("op0", "workspace.create", params={"initial_content": "terminal", "focus": False})
SPLIT = _op_step("op1", "pane.split", {"pane": "$step:op0#/value/pane_id"}, {"direction": "right"})
# The first step: its before checkpoint, the request and its reply, its settled checkpoint.
FIRST = (_at("op0", "before"), _step(CREATE), _reply("op0"), _at("op0", "settled"))


class FuzzToCaseSelfTest(unittest.TestCase):
    def convert(self, text: str, crash: bytes = b"crash", thread: Optional[str] = None) -> Tuple[Dict[str, Any], Expected]:
        case, expected = case_of(read_walk(text), crash, thread=thread)
        self.assertEqual(validate(case), [], json.dumps(case, indent=1))
        return case, expected

    def ids(self, case: Mapping[str, Any]) -> List[str]:
        return [step["id"] for step in case["steps"]]

    def test_an_i2_violation_at_settled_keeps_the_observed_replies(self) -> None:
        case, expected = self.convert(_walk(
            *FIRST, _at("op1", "before"), _step(SPLIT), _reply("op1"), _at("op1", "settled"),
            _violation("op1", "settled", "I2", "/tabs/0", "tab tab_1 disappeared, but step op1 did not close it"),
        ))
        self.assertEqual(self.ids(case), ["op0", "op1"])
        self.assertEqual(case["steps"][1]["expect"], {"outcome": "ok", "receipt": "mutation_result"})
        self.assertIn("I2 at step op1 (settled), /tabs/0", case["invariants"][1])
        self.assertEqual(expected, Expected("I2", "op1", "settled"))
        self.assertEqual(case["suite"], "fuzz")
        self.assertTrue(case["id"].startswith("resource-ops-"))

    def test_a_late_effect_ends_at_a_before_checkpoint_after_the_step_that_owns_it(self) -> None:
        case, expected = self.convert(_walk(
            *FIRST, _at("op1", "before"),
            _violation("op1", "before", "I2", "/panes/1", "pane p appeared, but step op0 did not create it"),
        ))
        self.assertEqual(self.ids(case), ["op0", "op1-before"])
        self.assertEqual(case["steps"][1]["op"], "snapshot")
        self.assertEqual(case["steps"][1]["checkpoint"], ["before"])
        self.assertEqual(expected, Expected("I2", "op1-before", "before"))

    def test_a_broken_first_cut_is_one_snapshot_step(self) -> None:
        case, expected = self.convert(_walk(_at("op0", "before"), _violation("op0", "before", "I19")))
        self.assertEqual(self.ids(case), ["op0-before"])
        self.assertEqual(expected, Expected("I19", "op0-before", "before"))

    def test_an_i19_violation_at_settled_keeps_an_error_reply(self) -> None:
        case, expected = self.convert(_walk(
            _at("op0", "before"), _step(CREATE), _reply("op0", "error", "validation.invalid", {}),
            _at("op0", "settled"), _violation("op0", "settled", "I19", "/screens/0/layout/root"),
        ))
        self.assertEqual(case["steps"][0]["expect"], {"outcome": "error", "error": "validation.invalid"})
        self.assertEqual(expected, Expected("I19", "op0", "settled"))

    def test_a_contract_refusal_expects_the_receipt_the_catalog_promises(self) -> None:
        case, expected = self.convert(_walk(
            _at("op0", "before"), _step(CREATE), _reply("op0", "error", "operation.failed", _refused("result")),
            _violation("op0", None, "I1", "/error/details/extra/contract"),
        ))
        self.assertEqual(case["steps"][-1]["expect"], {"outcome": "ok", "receipt": "mutation_result"})
        self.assertEqual(expected, Expected(None, "op0"))

    def test_an_undeclared_error_code_expects_that_code(self) -> None:
        case, _ = self.convert(_walk(
            _at("op0", "before"), _step(CREATE),
            _reply("op0", "error", "operation.failed", _refused("error", emitted_code="resource.not_found")),
            _violation("op0", None, "I1", "/error/details/extra/contract"),
        ))
        self.assertEqual(case["steps"][-1]["expect"], {"outcome": "error", "error": "resource.not_found"})

    def test_a_declared_code_with_wrong_details_or_retryability_expects_that_code(self) -> None:
        details = _refused("error", emitted_code="selector.not_found", violation_code="validation.invalid",
                           violation={"field": "retryable"})
        case, _ = self.convert(_walk(
            _at("op0", "before"), _step(CREATE), _reply("op0", "error", "operation.failed", details),
            _violation("op0", None, "I1", "/error/details/extra/contract"),
        ))
        self.assertEqual(case["steps"][-1]["expect"], {"outcome": "error", "error": "selector.not_found"})
        no_code = _refused("error", violation_code="validation.invalid")
        with self.assertRaisesRegex(ConvertError, "names no emitted_code"):
            case_of(read_walk(_walk(_at("op0", "before"), _step(CREATE), _reply("op0", "error", "operation.failed", no_code),
                                    _violation("op0", None, "I1", "/error/details/extra/contract"))), b"x")

    def test_a_daemon_panic_in_a_request_expects_its_receipt(self) -> None:
        case, expected = self.convert(_walk(*FIRST, _at("op1", "before"), _step(SPLIT)))
        self.assertEqual(self.ids(case), ["op0", "op1"])
        self.assertEqual(case["steps"][-1]["expect"], {"outcome": "ok", "receipt": "mutation_result"})
        self.assertIn("panicked in step op1's request", case["invariants"][1])
        self.assertEqual(expected, Expected(None, "op1"))

    def test_a_panic_after_the_reply_keeps_the_observed_reply(self) -> None:
        """A panic in the settled checkpoint's session.snapshot, after an error reply: the step keeps its error,
        and its settled checkpoint is where the daemon dies."""
        case, expected = self.convert(_walk(
            *FIRST, _at("op1", "before"), _step(SPLIT), _reply("op1", "error", "selector.not_found", {}),
            _at("op1", "settled"),
        ))
        self.assertEqual(case["steps"][-1]["expect"], {"outcome": "error", "error": "selector.not_found"})
        self.assertIn("op1's settled checkpoint", case["invariants"][1])
        self.assertEqual(expected, Expected(None, "op1"))

    def test_a_panic_in_a_before_checkpoint_ends_at_a_snapshot_step(self) -> None:
        case, expected = self.convert(_walk(*FIRST, _at("op1", "before")))
        self.assertEqual(self.ids(case), ["op0", "op1-before"])
        self.assertEqual(case["steps"][0]["expect"], {"outcome": "ok", "receipt": "mutation_result"})
        self.assertEqual(expected, Expected(None, "op1-before"))

    def test_a_teardown_failure_keeps_every_step(self) -> None:
        case, expected = self.convert(_walk(*FIRST, {"walk": "teardown"}))
        self.assertEqual(self.ids(case), ["op0"])
        self.assertIn("at teardown", case["invariants"][1])
        self.assertEqual(expected, Expected(None, None))

    def test_a_panic_on_another_thread_ends_at_the_last_reply_and_settles(self) -> None:
        close = _op_step("op1", "pane.close", {"pane": "$step:op0#/value/pane_id"})
        rename = _op_step("op2", "workspace.rename", {"workspace": "ws_" + "0" * 32}, {"name": "x"})
        text = _walk(*FIRST, _at("op1", "before"), _step(close), _reply("op1"), _at("op1", "settled"),
                     _at("op2", "before"), _step(rename))
        case, expected = self.convert(text, b"async", thread="surface-2-reader")
        self.assertEqual(self.ids(case), ["op0", "op1", "await-panic"])
        self.assertEqual(case["steps"][1]["expect"], {"outcome": "ok", "receipt": "mutation_result"})
        self.assertEqual(case["steps"][-1]["op"], "settle")
        self.assertIn("thread surface-2-reader after step op1", case["invariants"][1])
        self.assertEqual(expected, Expected(None, None))
        # The same walk with the panic on the request thread keeps the step in flight.
        self.assertEqual(case_of(read_walk(text), b"sync", thread="<unnamed>")[0]["steps"][-1]["id"], "op2")

    def test_the_panic_thread_is_read_from_stderr(self) -> None:
        stderr = ("noise\nthread 'surface-2-reader' (2953041) panicked at crates/x.rs:1:2:\nboom\n"
                  "thread 'other' panicked at y.rs:3:4:\n")
        self.assertEqual(panic_thread(stderr), "surface-2-reader")
        self.assertEqual(panic_thread("thread '<unnamed>' panicked at z.rs:1:1:\n"), "<unnamed>")
        self.assertIsNone(panic_thread("==1==ERROR: AddressSanitizer: heap-use-after-free\n"))
        self.assertTrue(synchronous(None))
        self.assertFalse(synchronous("mux-work-1"))

    def test_a_read_keeps_read_only_and_expects_no_receipt(self) -> None:
        read = {**_op_step("op0", "workspace.list"), "readOnly": True}
        del read["args"]["idempotencyKey"]
        case, _ = self.convert(_walk(
            _at("op0", "before"), _step(read), _reply("op0", "error", "operation.failed", _refused("result")),
            _violation("op0", None, "I1", "/error/details/extra/contract"),
        ))
        self.assertEqual(case["steps"][-1]["expect"], {"outcome": "ok"})

    def test_the_case_id_is_the_input_digest(self) -> None:
        text = _walk(*FIRST)
        first, second = case_of(read_walk(text), b"a")[0], case_of(read_walk(text), b"b")[0]
        self.assertNotEqual(first["id"], second["id"])
        self.assertEqual(first["id"], case_of(read_walk(text), b"a")[0]["id"])

    def test_bad_walks_are_refused(self) -> None:
        with self.assertRaises(ConvertError):
            read_walk("")
        with self.assertRaises(ConvertError):
            read_walk('{"walk": "other"}\n')
        with self.assertRaises(ConvertError):
            read_walk("not json\n")

    def test_an_input_that_does_not_crash_converts_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            crash = Path(scratch) / "input"
            crash.write_bytes(b"x")
            with self.assertRaisesRegex(ConvertError, "no longer crashes"):
                reproduce(Path("/bin/true"), crash)

    def test_a_case_reproduces_only_with_the_named_failure(self) -> None:
        violation = {"invariant": "I2", "step": "op1", "checkpoint": "settled"}
        report = {"violations": [{"invariant": "I1", "step": "op0", "checkpoint": None}, violation]}
        passed = {"status": "Pass"}
        self.assertIsNone(reproduced(Expected("I2", "op1", "settled"), passed, report))
        self.assertIn("invariants.py reports", reproduced(Expected("I2", "op1", "before"), passed, report))
        self.assertIn("invariants.py reports", reproduced(Expected("I19", "op1", "settled"), passed, report))
        stopped = {"status": "Failure", "step": "op0", "message": "expected ok"}
        self.assertIn("stopped at op0", reproduced(Expected("I2", "op1", "settled"), stopped, report))
        self.assertIsNone(reproduced(Expected(None, "op0"), stopped, None))
        self.assertIn("want a driver Failure", reproduced(Expected(None, "op1"), stopped, None))
        self.assertIn("want a driver Failure", reproduced(Expected(None, "op0"), passed, None))
        self.assertIsNone(reproduced(Expected(None, None), {"status": "Crash", "message": "exited"}, None))


def main(argv: Sequence[str]) -> int:
    if list(argv) == ["--selftest"]:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(FuzzToCaseSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    convert_parser = sub.add_parser("convert", help="crash inputs to walk cases")
    convert_parser.add_argument("--binary", type=Path, required=True,
                                help="the built resource_ops target (cargo fuzz build resource_ops)")
    convert_parser.add_argument("--cmux-tui", type=Path, required=True,
                                help="a debug or --profile oracle cmux-tui of the fuzz binary's commit: each case must "
                                     "fail on it as the target did")
    convert_parser.add_argument("crashes", type=Path, nargs="+")
    convert_parser.add_argument("--out", type=Path, default=CORPUS / SUITE)
    convert_parser.add_argument("--minimize", type=int, default=0, metavar="SECONDS",
                                help="minimize each input with libFuzzer for this long first")
    convert_parser.add_argument("--isolation", choices=("netns", "auto", "none"), default="auto",
                                help="driver_daemon.py run-case --isolation for the check run (default auto)")
    args = parser.parse_args(argv)
    # The replays run in scratch directories: every path is made absolute first.
    return convert(args.binary.resolve(), args.cmux_tui.resolve(), [crash.resolve() for crash in args.crashes],
                   args.out.resolve(), args.minimize, args.isolation)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
