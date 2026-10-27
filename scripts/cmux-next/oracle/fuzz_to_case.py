#!/usr/bin/env python3
"""Turn a crash of the resource_ops fuzz target into an oracle walk case (p15-oracle-186).

The cmux-tui/fuzz target `resource_ops` sends typed resource-op sequences through the daemon's dispatch in
process and stops on a daemon panic or a broken invariant (I1, I2, facet consistency). This script replays
one crash input with CMUX_RESOURCE_OPS_WALK set, so the target writes its walk: each step as a case-v1 step
(ids as `$step:` references to the reply that created the object, else to the `session.snapshot` read step
before it), each reply's outcome, and the broken invariant. It then writes the walk as a case of the
`fuzz` suite (tests/oracle/corpus/fuzz/<id>.json) that the daemon driver runs (driver_daemon.py run-case):

- every step before the crash expects the outcome it had, so the case keeps the path to the crash;
- the crashing step expects what the invariant requires, so the case fails on the build that crashed:
  a mutation whose result is no MutationResult, or that the daemon refused as outside its own catalog
  contract (`details.contract: result`), expects a mutation_result receipt; an error code outside the
  catalog (`details.contract: error`) expects that code; a step whose reply never came because the request
  thread panicked expects its own receipt and the driver reports the daemon's exit as a Crash;
- a panic on another thread (a terminal reader, a work item; the replay's stderr names it) ran the effect
  of an earlier step: the case ends at the last step that got a reply, with its observed outcome, then a
  settle step, so it asserts nothing about the step that happened to be in flight;
- an I2 or consistency violation keeps the observed reply; invariants.py checks I2 at the step's
  before and settled checkpoints, and the case's `invariants` names the broken rule and its pointer.

A crash input that no longer crashes is refused (exit 1): it converts nothing.

Chrome reference (chromium/src): ClusterFuzz turns each fuzzer crash into a reproducible test case (the
input, the target and the stack) before it files it; testing/libfuzzer/reproducing.md replays one input by
passing its path to the target binary, which is what `reproduce` does here.

The VM run (task test phase): `scripts/cmux-next/rust-fuzz.sh --target resource_ops --seconds 3600 -- -fork=300`,
then `fuzz_to_case.py convert --binary cmux-tui/fuzz/target/x86_64-unknown-linux-gnu/release/resource_ops
<out>/artifacts/resource_ops/*/crash-*` (the binary that run built; rust-fuzz.sh's verdicts name the artifacts).

Usage:
  fuzz_to_case.py convert --binary RESOURCE_OPS CRASH... [--out DIR] [--minimize SECONDS]
      the case of each crash input; --minimize first runs libFuzzer's -minimize_crash on it
  fuzz_to_case.py --selftest
      offline tests of the walk-to-case conversion (no fuzz binary)
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
PANIC_LINE = re.compile(r"^thread '([^']*)'(?: \(\d+\))? panicked at", re.MULTILINE)


class ConvertError(Exception):
    pass


def read_walk(text: str) -> Dict[str, Any]:
    """The walk lines of one replay: the steps in order, each op step's reply, and the violation (none when
    the crash was a daemon panic, which writes no line)."""
    steps: List[Dict[str, Any]] = []
    replies: Dict[str, Dict[str, Any]] = {}
    violation: Optional[Dict[str, Any]] = None
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise ConvertError(f"walk line {number}: {error}") from None
        kind = record.get("walk")
        if kind == "step":
            steps.append(record["step"])
        elif kind == "reply":
            replies[record["step"]] = record
        elif kind == "violation":
            violation = record
        else:
            raise ConvertError(f"walk line {number}: unknown record {kind!r}")
    if not steps:
        raise ConvertError("the walk has no step: the crash happened before the first request")
    return {"steps": steps, "replies": replies, "violation": violation}


def mutating(step: Mapping[str, Any]) -> bool:
    return step.get("op") == "resource.call" and step.get("readOnly") is not True


def observed_expect(step: Mapping[str, Any], reply: Mapping[str, Any]) -> Dict[str, Any]:
    if reply["outcome"] == "error":
        return {"outcome": "error", "error": reply["error"]}
    return {"outcome": "ok", "receipt": "mutation_result"} if mutating(step) else {"outcome": "ok"}


def required_expect(step: Mapping[str, Any], reply: Optional[Mapping[str, Any]],
                    violation: Optional[Mapping[str, Any]]) -> Dict[str, Any]:
    """The crashing step's expectation: what its invariant requires, so the case fails where it crashed."""
    ok = {"outcome": "ok", "receipt": "mutation_result"} if mutating(step) else {"outcome": "ok"}
    if reply is None or violation is None:
        return ok  # the daemon panicked in the step: no reply at all
    if violation["invariant"] != "I1":
        return observed_expect(step, reply)
    details = reply.get("details") if isinstance(reply.get("details"), Mapping) else {}
    if details.get("contract") == "error" and isinstance(details.get("emitted_code"), str):
        return {"outcome": "error", "error": details["emitted_code"]}
    return ok


def panic_thread(stderr: str) -> Optional[str]:
    """The thread of the first Rust panic in a replay's stderr (`thread '<name>' (<tid>) panicked at`)."""
    match = PANIC_LINE.search(stderr)
    return match.group(1) if match else None


def synchronous(thread: Optional[str]) -> bool:
    """A panic on the thread that sent the request: the input's own thread, which libFuzzer's C main starts
    with no Rust name. A request thread's panic belongs to the request it ran; another thread's (a terminal
    reader, a work item) to an earlier step whose effect it ran, so it is not the step that was in flight."""
    return thread in (None, "main", "<unnamed>")


def case_of(walk: Mapping[str, Any], crash: bytes, target: str = TARGET,
            thread: Optional[str] = None) -> Dict[str, Any]:
    """The walk case of one crash. A broken invariant ends the case at its step. A panic ends it at the
    step in flight when it ran on the request thread; a panic on another thread ends it at the last step
    that got a reply, followed by a settle step (one ping), so the case asserts no outcome the fixed
    daemon would not give and the driver reports the daemon's exit at that settle or at teardown."""
    digest = hashlib.sha1(crash).hexdigest()
    case_id = f"{target.replace('_', '-')}-{digest[:12]}"
    violation = walk["violation"]
    replies = walk["replies"]
    asynchronous = violation is None and not synchronous(thread)
    if violation:
        crashed = violation["step"]
    elif asynchronous:
        answered = [step["id"] for step in walk["steps"] if step["id"] in replies]
        crashed = answered[-1] if answered else None
    else:
        # The target writes a step's snapshot read and its request together, before it sends either, so a
        # request-thread panic belongs to the last step written.
        crashed = walk["steps"][-1]["id"]
    steps = []
    for step in walk["steps"]:
        if crashed is None:
            break
        step = dict(step)
        reply = replies.get(step["id"])
        if step["id"] == crashed:
            step["expect"] = (observed_expect(step, reply) if asynchronous
                              else required_expect(step, reply, violation))
            steps.append(step)
            break
        if reply is None:
            step["expect"] = {"outcome": "ok"}  # a session.snapshot read
        else:
            step["expect"] = observed_expect(step, reply)
        steps.append(step)
    else:
        raise ConvertError(f"the crash names step {crashed}, which is not in the walk")
    if violation:
        broken = (f"{violation['invariant']} at step {violation['step']}, {violation['pointer']} of the daemon "
                  f"facet or reply: {violation['message']}")
    elif asynchronous:
        after = f"after step {crashed}" if crashed else "before the first reply"
        broken = f"the daemon panicked on thread {thread} {after}"
        steps.append({"id": "await-panic", "op": "settle", "settleMaxMs": 5000,
                      "note": f"the panic on {thread} ran after the last reply; the daemon must still answer"})
    else:
        broken = f"the daemon panicked in step {crashed}"
    return {
        "$schema": "../../../../schemas/oracle/case-v1.schema.json",
        "corpusVersion": 1,
        "id": case_id,
        "suite": SUITE,
        "title": f"{target} fuzz crash {digest[:12]}: {broken}"[:200],
        "surface": "cmux-next-daemon",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        "environment": {},
        "fixture": {"seed": f"fuzz.{case_id}", "network": "offline", "clock": "virtual"},
        "preconditions": ["hermetic state root", "no other cmux-tui on the state root"],
        "requires": ["resource_api"],
        "platforms": ["linux", "mac"],
        "steps": steps,
        "invariants": [
            f"converted by scripts/cmux-next/oracle/fuzz_to_case.py from cmux-tui/fuzz {target} input sha1 {digest}",
            f"the crash: {broken}",
        ],
        "teardown": ["stop the case daemon", "verify the socket and state root are gone"],
    }


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


def convert(binary: Path, crashes: Sequence[Path], out: Path, minimize_s: int) -> int:
    failed = False
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="resource-ops-min-") as scratch:
        for crash in crashes:
            try:
                path = minimize(binary, crash, minimize_s, Path(scratch)) if minimize_s else crash
                walk, thread = reproduce(binary, path)
                case = case_of(walk, path.read_bytes(), thread=thread)
                errors = validate(case)
                if errors:
                    raise ConvertError(f"{crash}: the case is not case-v1: {'; '.join(errors[:5])}")
            except ConvertError as error:
                print(f"fuzz_to_case.py: {error}", file=sys.stderr)
                failed = True
                continue
            target = out / f"{case['id']}.json"
            target.write_text(json.dumps(case, indent=2, ensure_ascii=False) + "\n")
            print(target)
    return 1 if failed else 0


# ---------------------------------------------------------------------------------------------- selftest


def _snapshot_step(step_id: str) -> Dict[str, Any]:
    return {"id": step_id, "op": "resource.call", "target": {"machine": "current", "session": "current"},
            "args": {"method": "session.snapshot", "params": {}}, "readOnly": True}


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


CREATE = _op_step("op0", "workspace.create", params={"initial_content": "terminal", "focus": False})
SPLIT = _op_step("op1", "pane.split", {"pane": "$step:op0#/value/pane_id"}, {"direction": "right"})


class FuzzToCaseSelfTest(unittest.TestCase):
    def convert(self, text: str, crash: bytes = b"crash") -> Dict[str, Any]:
        case = case_of(read_walk(text), crash)
        self.assertEqual(validate(case), [], json.dumps(case, indent=1))
        return case

    def test_an_i2_violation_keeps_the_observed_replies(self) -> None:
        case = self.convert(_walk(
            {"walk": "step", "step": _snapshot_step("s0")}, {"walk": "step", "step": CREATE}, _reply("op0"),
            {"walk": "step", "step": _snapshot_step("s1")}, {"walk": "step", "step": SPLIT}, _reply("op1"),
            {"walk": "violation", "step": "op1", "invariant": "I2", "pointer": "/tabs/0",
             "message": "tab tab_1 disappeared, but the step did not close it"},
        ))
        self.assertEqual([step["id"] for step in case["steps"]], ["s0", "op0", "s1", "op1"])
        self.assertEqual(case["steps"][3]["expect"], {"outcome": "ok", "receipt": "mutation_result"})
        self.assertEqual(case["steps"][0]["expect"], {"outcome": "ok"})
        self.assertIn("I2 at step op1, /tabs/0", case["invariants"][1])
        self.assertEqual(case["suite"], "fuzz")
        self.assertTrue(case["id"].startswith("resource-ops-"))

    def test_a_contract_refusal_expects_the_receipt_the_catalog_promises(self) -> None:
        case = self.convert(_walk(
            {"walk": "step", "step": _snapshot_step("s0")}, {"walk": "step", "step": CREATE},
            _reply("op0", "error", "operation.failed", {"contract": "result"}),
            {"walk": "violation", "step": "op0", "invariant": "I1", "pointer": "/error/details/contract",
             "message": "the daemon refused its own result as outside the catalog"},
        ))
        self.assertEqual(case["steps"][-1]["expect"], {"outcome": "ok", "receipt": "mutation_result"})

    def test_an_undeclared_error_code_expects_that_code(self) -> None:
        case = self.convert(_walk(
            {"walk": "step", "step": _snapshot_step("s0")}, {"walk": "step", "step": CREATE},
            _reply("op0", "error", "operation.failed", {"contract": "error", "emitted_code": "resource.not_found"}),
            {"walk": "violation", "step": "op0", "invariant": "I1", "pointer": "/error/details/contract",
             "message": "the daemon refused its own error as outside the catalog"},
        ))
        self.assertEqual(case["steps"][-1]["expect"], {"outcome": "error", "error": "resource.not_found"})

    def test_a_daemon_panic_ends_the_case_at_the_step_with_no_reply(self) -> None:
        case = self.convert(_walk(
            {"walk": "step", "step": _snapshot_step("s0")}, {"walk": "step", "step": CREATE}, _reply("op0"),
            {"walk": "step", "step": _snapshot_step("s1")}, {"walk": "step", "step": SPLIT},
        ))
        self.assertEqual(case["steps"][-1]["id"], "op1")
        self.assertEqual(case["steps"][-1]["expect"], {"outcome": "ok", "receipt": "mutation_result"})
        self.assertIn("panicked in step op1", case["invariants"][1])

    def test_a_panic_on_another_thread_ends_at_the_last_reply_and_settles(self) -> None:
        close = _op_step("op1", "pane.close", {"pane": "$step:op0#/value/pane_id"})
        rename = _op_step("op2", "workspace.rename", {"workspace": "ws_" + "0" * 32}, {"name": "x"})
        walk = read_walk(_walk(
            {"walk": "step", "step": _snapshot_step("s0")}, {"walk": "step", "step": CREATE}, _reply("op0"),
            {"walk": "step", "step": _snapshot_step("s1")}, {"walk": "step", "step": close}, _reply("op1"),
            {"walk": "step", "step": _snapshot_step("s2")}, {"walk": "step", "step": rename},
        ))
        case = case_of(walk, b"async", thread="surface-2-reader")
        self.assertEqual(validate(case), [], json.dumps(case, indent=1))
        self.assertEqual([step["id"] for step in case["steps"]], ["s0", "op0", "s1", "op1", "await-panic"])
        self.assertEqual(case["steps"][3]["expect"], {"outcome": "ok", "receipt": "mutation_result"})
        self.assertEqual(case["steps"][-1]["op"], "settle")
        self.assertIn("thread surface-2-reader after step op1", case["invariants"][1])
        # The same walk with the panic on the request thread keeps the step in flight.
        self.assertEqual(case_of(walk, b"sync", thread="<unnamed>")["steps"][-1]["id"], "op2")

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
        case = self.convert(_walk(
            {"walk": "step", "step": _snapshot_step("s0")}, {"walk": "step", "step": read},
            _reply("op0", "error", "operation.failed", {"contract": "result"}),
            {"walk": "violation", "step": "op0", "invariant": "I1", "pointer": "/error/details/contract",
             "message": "refused"},
        ))
        self.assertEqual(case["steps"][-1]["expect"], {"outcome": "ok"})

    def test_the_case_id_is_the_input_digest(self) -> None:
        text = _walk({"walk": "step", "step": _snapshot_step("s0")}, {"walk": "step", "step": CREATE},
                     _reply("op0"))
        first, second = case_of(read_walk(text), b"a"), case_of(read_walk(text), b"b")
        self.assertNotEqual(first["id"], second["id"])
        self.assertEqual(first["id"], case_of(read_walk(text), b"a")["id"])

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


def main(argv: Sequence[str]) -> int:
    if list(argv) == ["--selftest"]:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(FuzzToCaseSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    convert_parser = sub.add_parser("convert", help="crash inputs to walk cases")
    convert_parser.add_argument("--binary", type=Path, required=True,
                                help="the built resource_ops target (cargo fuzz build resource_ops)")
    convert_parser.add_argument("crashes", type=Path, nargs="+")
    convert_parser.add_argument("--out", type=Path, default=CORPUS / SUITE)
    convert_parser.add_argument("--minimize", type=int, default=0, metavar="SECONDS",
                                help="minimize each input with libFuzzer for this long first")
    args = parser.parse_args(argv)
    return convert(args.binary, args.crashes, args.out, args.minimize)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
