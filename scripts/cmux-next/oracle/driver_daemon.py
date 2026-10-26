#!/usr/bin/env python3
"""The daemon product driver of the oracle: the daemon facet (p15-oracle task 021).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3A and task 021; the facet's shape is
`facets.daemon` in schemas/oracle/snapshot-v1.schema.json. Stdlib plus the repo's Python SDK
(cmux-tui/bindings/python, the one daemon client, rule 9); safe under `python3 -I`.

The daemon facet is `session.snapshot` + `settings.snapshot` + the journal head of the snapshot's cut,
with the `oracle-state` extras (switches, terminal attach counts, live object counts, panic log). A
debug or `--features oracle` daemon answers `oracle-state` with the asking connection's `session.snapshot`
result (`clients` included) and its journal head from the one snapshot builder
(`public_session_snapshot_at_cut`), so `session`, `journalHead`, `terminalAttach` and `liveObjects` (all
but `subscriptions`) are one cut. A release daemon, or a push-base daemon from before task 021, answers
`oracle-state` as an unknown command; the facet is then the v0 facet: `session.snapshot` and
`settings.snapshot` only, with no `journalHead` and no `oracle` (both optional in the schema).

`settings` is the `settings.snapshot` result after the schema's capture rules (a `derive: sha256` field
holds the hash of the wire value it names), which check_snapshot_schema.py owns; this driver imports them.
Nothing here normalizes: volatile fields, path rewrites and id labels are normalize.py's (task 013).

Switch arms (task 049): a daemon gets its arms as CMUX_TUI_SWITCHES (switches.arm_plan's
`daemon_environment()`), and `daemon_readback` reads them back from `identify` and `oracle-state`; a
mismatch is arm-not-applied. Task 023's case driver applies the same two calls to each case daemon.

Task 023 adds the rest of the driver (hermetic daemon per case, steps, teardown proof) to this file.

Usage:
  driver_daemon.py facet --socket PATH     print the daemon facet of a running daemon (canonical JSON)
  driver_daemon.py live-check --cmux BIN [--write]
                                           capture_wire_fixtures.py's op script on a hermetic daemon; its
                                           oracle-state part must equal daemon-oracle-state.expected.json
  driver_daemon.py arms --cmux BIN [--switch NAME=ARM]... [--registry DIR] [--receipt FILE]
                                           a hermetic daemon on those arms, read back (exit 0 applied,
                                           1 arm-not-applied, 2 unknown switch: nothing starts)
  driver_daemon.py --selftest              offline tests against the recorded wire fixtures
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import unittest
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Protocol

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SDK = REPO / "cmux-tui" / "bindings" / "python"
SCHEMA = REPO / "schemas" / "oracle" / "snapshot-v1.schema.json"
WIRE = REPO / "schemas" / "oracle" / "fixtures" / "wire"
EXAMPLE = REPO / "schemas" / "oracle" / "fixtures" / "snapshot-example.json"
LIVE_EXPECTED = REPO / "schemas" / "oracle" / "fixtures" / "daemon-oracle-state.expected.json"

ORACLE_STATE = "oracle-state"
SELECTORS = {"machine": "current", "session": "current"}
# `oracle-state` fields that make the facet's `oracle` object (schema: facets.daemon.oracle).
EXTRAS = ("switches", "terminalAttach", "liveObjects", "panicLog")


class DriverError(Exception):
    """The daemon answered something the facet cannot be built from."""


class DaemonReads(Protocol):
    """The two reads the facet needs; `SdkReads` is the real one."""

    def command(self, cmd: str) -> Mapping[str, Any]:
        """A raw `{"cmd": cmd}` request; the whole reply line (`ok`, `data`, `error`)."""

    def operation(self, operation: str, params: Mapping[str, Any]) -> Any:
        """A resource-protocol read; its result."""


def _sibling(module: str) -> Any:
    if str(HERE) not in sys.path:
        sys.path.insert(0, str(HERE))
    return __import__(module)


def load_schema() -> Dict[str, Any]:
    return json.loads(SCHEMA.read_text(encoding="utf-8"))


def daemon_properties(schema: Mapping[str, Any]) -> Mapping[str, Any]:
    return schema["properties"]["facets"]["properties"]["daemon"]["oneOf"][0]["properties"]


def is_unknown_command(reply: Mapping[str, Any]) -> bool:
    """A daemon with no `oracle-state`: serde refuses the tag before any handler runs."""
    error = reply.get("error")
    return reply.get("ok") is False and isinstance(error, str) and f"unknown variant `{ORACLE_STATE}`" in error


def capture_daemon_facet(reads: DaemonReads, schema: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
    """The `facets.daemon` value of the daemon behind `reads`."""
    schema = load_schema() if schema is None else schema
    props = daemon_properties(schema)
    capture = _sibling("check_snapshot_schema").capture
    reply = reads.command(ORACLE_STATE)
    facet: Dict[str, Any] = {}
    if reply.get("ok") is True:
        data = reply.get("data")
        if not isinstance(data, dict) or not isinstance(data.get("session"), dict):
            raise DriverError(f"{ORACLE_STATE} replied without a session: {reply!r:.300}")
        missing = [key for key in ("journal_head", *EXTRAS) if key not in data]
        if missing:
            raise DriverError(f"{ORACLE_STATE} reply lacks {', '.join(missing)}")
        facet["journalHead"] = data["journal_head"]
        session = data["session"]
        facet["oracle"] = {key: data[key] for key in EXTRAS}
    elif is_unknown_command(reply):
        session = reads.operation("session.snapshot", SELECTORS)
    else:
        raise DriverError(f"{ORACLE_STATE} failed: {reply.get('error')!r}")
    facet["session"] = capture(schema, props["session"], session)
    facet["settings"] = capture(schema, props["settings"], reads.operation("settings.snapshot", SELECTORS))
    return facet


class SdkReads:
    """`DaemonReads` over one daemon socket through the repo's Python SDK."""

    def __init__(self, socket_path: str, timeout: float = 10.0):
        if str(SDK) not in sys.path:
            sys.path.insert(0, str(SDK))
        from cmux._protocol import ProtocolConnection
        from cmux.raw import CmuxClient

        self._raw = CmuxClient(socket_path, timeout=timeout)
        self._resource = ProtocolConnection(socket_path, timeout)

    def command(self, cmd: str) -> Mapping[str, Any]:
        return self._raw.request(cmd)

    def operation(self, operation: str, params: Mapping[str, Any]) -> Any:
        return self._resource.request(operation, params)

    def close(self) -> None:
        self._raw.close()
        self._resource.close()

    def __enter__(self) -> "SdkReads":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


# ---------------------------------------------------------------------------------------------- switch arms


IDENTIFY = "identify"


def daemon_arm_sources(reads: DaemonReads) -> Dict[str, Optional[Any]]:
    """The daemon's switch readers (p15-oracle-049): `identify`'s `switches` (task 020; None on a daemon
    whose identify has none) and `oracle-state`'s `switches` (task 021; None on a daemon without it)."""
    identify = reads.command(IDENTIFY)
    data = identify.get("data")
    if identify.get("ok") is not True or not isinstance(data, dict):
        raise DriverError(f"{IDENTIFY} failed: {identify.get('error')!r}")
    sources: Dict[str, Optional[Any]] = {IDENTIFY: data.get("switches")}
    state = reads.command(ORACLE_STATE)
    if state.get("ok") is True and isinstance(state.get("data"), dict) and "switches" in state["data"]:
        sources[ORACLE_STATE] = state["data"]["switches"]
    elif is_unknown_command(state):
        sources[ORACLE_STATE] = None
    else:
        raise DriverError(f"{ORACLE_STATE} gave no switches: {state.get('error') or state.get('data')!r:.300}")
    return sources


def daemon_readback(plan: Any, reads: DaemonReads) -> Any:
    """switches.read_back of the daemon behind `reads`; `.check()` raises ArmNotApplied on a mismatch."""
    switches = _sibling("switches")
    try:
        return switches.read_back(plan, switches.DAEMON, daemon_arm_sources(reads))
    except switches.UsageError as error:
        raise DriverError(str(error)) from None


def arms_check(binary: Path, requested: Mapping[str, str], registry: Optional[Path], receipt: Optional[Path]) -> int:
    """`arms`: one hermetic daemon started with the plan's CMUX_TUI_SWITCHES, its arms read back. Exit 0 when
    they are the plan's, 1 on arm-not-applied (the daemon refused the value at start, or read back others),
    2 when the request names an unknown switch (nothing starts)."""
    import shutil
    import subprocess
    import tempfile

    switches = _sibling("switches")
    roots = switches.Roots() if registry is None else switches.Roots(registry=registry.resolve())
    try:
        plan = switches.arm_plan(requested, roots)
    except switches.UnknownSwitch as error:
        print(f"arms: {error}", file=sys.stderr)
        return 2
    if not os.access(binary, os.X_OK):
        print(f"arms: {binary} is not an executable cmux-tui", file=sys.stderr)
        return 2
    environment = plan.daemon_environment()
    record: Dict[str, Any] = {"switches": dict(sorted(requested.items())), "environment": environment}
    wire = _sibling("capture_wire_fixtures")
    root = Path(tempfile.mkdtemp(prefix="oracle-049-", dir="/tmp"))
    daemon = wire.Daemon(binary.resolve(), root)
    daemon.env.update(environment)
    try:
        try:
            daemon.start()
        except subprocess.CalledProcessError as error:
            detail = (error.stderr or error.stdout or "").strip()[-400:]
            record.update(verdict=switches.ARM_NOT_APPLIED,
                          problems=[f"the daemon refused {switches.DAEMON_SWITCHES_ENV}={environment.get(switches.DAEMON_SWITCHES_ENV, '')!r} "
                                    f"at start (exit {error.returncode}): {detail}"])
        else:
            with SdkReads(daemon.socket) as reads:
                readback = daemon_readback(plan, reads)
            record.update(verdict="applied" if not readback.problems else switches.ARM_NOT_APPLIED,
                          readback=readback.arms, sources=readback.sources, problems=list(readback.problems))
    finally:
        daemon.stop()
        shutil.rmtree(root, ignore_errors=True)
    text = json.dumps(record, indent=1, sort_keys=True) + "\n"
    if receipt is not None:
        receipt.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if record["verdict"] == "applied" else 1


# ---------------------------------------------------------------------------------------------- self test


class _FakeReads:
    def __init__(self, oracle_reply: Mapping[str, Any], wire: Mapping[str, Any]):
        self.oracle_reply = oracle_reply
        self.wire = wire
        self.calls: list = []

    def command(self, cmd: str) -> Mapping[str, Any]:
        self.calls.append(cmd)
        return self.oracle_reply

    def operation(self, operation: str, params: Mapping[str, Any]) -> Any:
        self.calls.append(operation)
        assert params == SELECTORS, params
        return self.wire[operation]


def _wire() -> Dict[str, Any]:
    return {p.stem: json.loads(p.read_text(encoding="utf-8"))["result"] for p in sorted(WIRE.glob("*.json"))}


EXTRAS_REPLY = {
    "journal_head": 42,
    "switches": {"terminal-holder": "old"},
    "terminalAttach": {"attached": 3, "detached": 0, "dead": 0},
    "liveObjects": {"browsers": 0, "panes": 3, "screens": 2, "subscriptions": 1, "terminals": 3, "views": 3,
                    "workspaces": 2},
    "panicLog": {"path": "/tmp/oracle-case/state/owner-panics-main.jsonl", "bytes": 0},
}


class DriverDaemonSelfTest(unittest.TestCase):
    def setUp(self) -> None:
        self.schema = load_schema()
        self.wire = _wire()
        self.checks = _sibling("check_snapshot_schema")

    def facet_errors(self, facet: Mapping[str, Any]) -> list:
        """The schema check on the example snapshot with this facet as its daemon facet.

        check_snapshot_schema.py's validator, not normalize.py's: at this base normalize.py refuses the
        schema's x-oracle-decimal, x-oracle-open-keys and x-oracle-id-unpatterned keywords.
        """
        snapshot = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        snapshot["facets"]["daemon"] = facet
        return self.checks.check_snapshot(self.schema, snapshot, "facet")

    def test_oracle_state_gives_one_cut_and_the_extras(self) -> None:
        reply = {"ok": True, "data": {**EXTRAS_REPLY, "session": self.wire["session.snapshot"]}}
        reads = _FakeReads(reply, self.wire)
        facet = capture_daemon_facet(reads, self.schema)
        self.assertEqual(reads.calls, [ORACLE_STATE, "settings.snapshot"], "session comes from the cut")
        self.assertEqual(facet["journalHead"], 42)
        self.assertEqual(sorted(facet["oracle"]), sorted(EXTRAS))
        self.assertEqual(facet["oracle"]["switches"], {"terminal-holder": "old"})
        self.assertEqual(facet["session"]["session"], self.wire["session.snapshot"]["session"])
        self.assertRegex(facet["settings"]["effective_sha256"], r"^sha256:[0-9a-f]{64}$")
        self.assertNotIn("effective", facet["settings"])
        self.assertEqual(self.facet_errors(facet), [])

    def test_a_daemon_without_oracle_state_gives_the_v0_facet(self) -> None:
        reply = {"ok": False, "error": "bad request: unknown variant `oracle-state`, expected one of `identify`"}
        reads = _FakeReads(reply, self.wire)
        facet = capture_daemon_facet(reads, self.schema)
        self.assertEqual(reads.calls, [ORACLE_STATE, "session.snapshot", "settings.snapshot"])
        self.assertEqual(sorted(facet), ["session", "settings"])
        self.assertEqual(self.facet_errors(facet), [])

    def test_other_refusals_and_short_replies_are_errors(self) -> None:
        refused = {"ok": False, "error": "oracle state requires a trusted local connection"}
        with self.assertRaises(DriverError):
            capture_daemon_facet(_FakeReads(refused, self.wire), self.schema)
        short = {"ok": True, "data": {"journal_head": 1, "session": self.wire["session.snapshot"]}}
        with self.assertRaisesRegex(DriverError, "switches"):
            capture_daemon_facet(_FakeReads(short, self.wire), self.schema)

    def test_an_extra_field_the_schema_does_not_know_fails_validation(self) -> None:
        data = {**EXTRAS_REPLY, "session": self.wire["session.snapshot"]}
        facet = capture_daemon_facet(_FakeReads({"ok": True, "data": data}, self.wire), self.schema)
        facet["oracle"]["holders"] = 1
        self.assertNotEqual(self.facet_errors(facet), [])


class _ArmReads:
    """`identify` and `oracle-state` replies by command."""

    def __init__(self, identify: Mapping[str, Any], state: Mapping[str, Any]):
        self.replies = {IDENTIFY: identify, ORACLE_STATE: state}

    def command(self, cmd: str) -> Mapping[str, Any]:
        return self.replies[cmd]

    def operation(self, operation: str, params: Mapping[str, Any]) -> Any:
        raise AssertionError(f"no resource read is needed for the arms ({operation})")


def _identify(**extra: Any) -> Dict[str, Any]:
    return {"ok": True, "data": {"app": "cmux-tui", "protocol": 5, **extra}}


def _state(arms: Mapping[str, str]) -> Dict[str, Any]:
    return {"ok": True, "data": {**EXTRAS_REPLY, "switches": dict(arms)}}


UNKNOWN_STATE = {"ok": False, "error": "bad request: unknown variant `oracle-state`, expected one of `identify`"}


class DaemonArmsSelfTest(unittest.TestCase):
    """The daemon half of p15-oracle-049 on a temporary registry with one daemon switch, `holder`."""

    def setUp(self) -> None:
        import tempfile

        self.switches = _sibling("switches")
        tmp = tempfile.TemporaryDirectory(prefix="oracle-049-")
        self.addCleanup(tmp.cleanup)
        self.roots = self.switches.selftest_tree(Path(tmp.name), {"holder": self.switches.daemon_entry()}, None)

    def plan(self, arm: str) -> Any:
        return self.switches.arm_plan({"holder": arm}, self.roots)

    def test_both_arms_read_back(self) -> None:
        for arm in ("old", "new"):
            plan = self.plan(arm)
            self.assertEqual(plan.daemon_environment(), {"CMUX_TUI_SWITCHES": f"holder={arm}"})
            reads = _ArmReads(_identify(switches={"holder": arm}), _state({"holder": arm, "terminal-holder": "old"}))
            self.assertEqual(daemon_readback(plan, reads).check(), {"holder": arm})

    def test_a_daemon_that_ignores_the_value_is_arm_not_applied(self) -> None:
        reads = _ArmReads(_identify(), _state({"holder": "old"}))
        readback = daemon_readback(self.plan("new"), reads)
        self.assertEqual(readback.sources, {IDENTIFY: None, ORACLE_STATE: {"holder": "old"}})
        with self.assertRaisesRegex(self.switches.ArmNotApplied, "arm-not-applied: holder=new: oracle-state read back holder=old"):
            readback.check()

    def test_identify_alone_reads_back_on_a_daemon_without_oracle_state(self) -> None:
        reads = _ArmReads(_identify(switches={"holder": "new"}), UNKNOWN_STATE)
        self.assertEqual(daemon_readback(self.plan("new"), reads).check(), {"holder": "new"})
        with self.assertRaisesRegex(self.switches.ArmNotApplied, "no daemon reader in this build"):
            daemon_readback(self.plan("new"), _ArmReads(_identify(), UNKNOWN_STATE)).check()

    def test_refused_reads_are_driver_errors(self) -> None:
        with self.assertRaisesRegex(DriverError, "identify failed"):
            daemon_arm_sources(_ArmReads({"ok": False, "error": "nope"}, _state({})))
        with self.assertRaisesRegex(DriverError, "oracle-state gave no switches"):
            daemon_arm_sources(_ArmReads(_identify(), {"ok": False, "error": "oracle state requires a trusted local connection"}))
        with self.assertRaisesRegex(DriverError, "object of strings"):
            daemon_readback(self.plan("new"), _ArmReads(_identify(switches={"holder": 1}), UNKNOWN_STATE))

    def test_an_unknown_switch_aborts_before_any_daemon_starts(self) -> None:
        import io
        from contextlib import redirect_stderr

        err = io.StringIO()
        with redirect_stderr(err):
            code = arms_check(Path("/nonexistent/cmux-tui"), {"ghost": "new"}, self.roots.registry, None)
        self.assertEqual(code, 2)
        self.assertIn("unknown switch: ghost", err.getvalue())


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--selftest", action="store_true", help="run the offline self tests")
    sub = parser.add_subparsers(dest="command")
    facet = sub.add_parser("facet", help="print the daemon facet of a running daemon")
    facet.add_argument("--socket", required=True, help="the daemon's control socket")
    live = sub.add_parser("live-check", help="the fixed op script on a hermetic daemon vs the checked-in JSON")
    live.add_argument("--cmux", type=Path, required=True, help="a debug or --features oracle cmux-tui binary")
    live.add_argument("--write", action="store_true", help="rewrite the expected JSON instead of comparing")
    arms = sub.add_parser("arms", help="start a hermetic daemon on switch arms and read them back")
    arms.add_argument("--cmux", type=Path, required=True, help="a debug or --features oracle cmux-tui binary")
    arms.add_argument("--switch", action="append", default=[], metavar="NAME=ARM", help="a registry switch and its arm")
    arms.add_argument("--registry", type=Path, help="refactor switch registry (default plans/cmux-next/refactor-switches)")
    arms.add_argument("--receipt", type=Path, help="also write the readback receipt here")
    args = parser.parse_args(argv)
    if args.selftest:
        loader = unittest.defaultTestLoader
        suite = unittest.TestSuite([loader.loadTestsFromTestCase(DriverDaemonSelfTest),
                                    loader.loadTestsFromTestCase(DaemonArmsSelfTest)])
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.command == "arms":
        switches = _sibling("switches")
        try:
            requested = switches.parse_requests(args.switch)
        except switches.UsageError as error:
            parser.error(str(error))
        return arms_check(args.cmux, requested, args.registry, args.receipt)
    if args.command == "facet":
        with SdkReads(args.socket) as reads:
            value = capture_daemon_facet(reads)
        print(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
        return 0
    if args.command == "live-check":
        return live_check(args.cmux, write=args.write)
    parser.print_usage(sys.stderr)
    return 2


def live_check(binary: Path, *, write: bool) -> int:
    """Run capture_wire_fixtures.py's op script on a hermetic daemon and compare the facet's oracle-state
    part with LIVE_EXPECTED. The session and settings are checked against the schema, not pinned: their
    ids and times are random until task 185's seeded ids and virtual clock. The expected panic log path
    is the Linux XDG state path, so this is a VM check."""
    import shutil
    import tempfile

    wire = _sibling("capture_wire_fixtures")
    root = Path(tempfile.mkdtemp(prefix="oracle-021-", dir="/tmp"))
    daemon = wire.Daemon(binary.resolve(), root)
    try:
        daemon.start()
        wire.make_state(daemon)
        with SdkReads(daemon.socket) as reads:
            facet = capture_daemon_facet(reads)
    finally:
        daemon.stop()
        shutil.rmtree(root, ignore_errors=True)
    snapshot = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    snapshot["facets"]["daemon"] = facet
    problems = _sibling("check_snapshot_schema").check_snapshot(load_schema(), snapshot, "live facet")
    oracle = json.loads(json.dumps(facet.get("oracle")).replace(str(root), "$ROOT"))
    got = {"facetKeys": sorted(facet), "journalHeadPositive": facet.get("journalHead", 0) > 0,
           "oracle": oracle, "schemaProblems": problems}
    text = json.dumps(got, indent=2, sort_keys=True) + "\n"
    if write:
        LIVE_EXPECTED.write_text(text, encoding="utf-8")
        print(LIVE_EXPECTED)
        return 0
    expected = LIVE_EXPECTED.read_text(encoding="utf-8")
    if text != expected:
        print(f"live-check: the facet differs from {LIVE_EXPECTED.relative_to(REPO)}:\n{text}", file=sys.stderr)
        return 1
    print("live-check: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
