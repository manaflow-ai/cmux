#!/usr/bin/env python3
"""The oracle's daemon driver: one isolated cmux-tui per case, driven only through the Python SDK.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3D and 3G and task 023. Stdlib plus the
cmux Python SDK of this checkout (cmux-tui/bindings/python), Python 3.9+, safe under `python3 -I`.
It implements the driver protocol of oracle.py (`open_session`, `session.run_case`, `session.close`).

The daemon facet (task 021, `facets.daemon` of schemas/oracle/snapshot-v1.schema.json) is
`capture_daemon_facet`: `session.snapshot` + `settings.snapshot` + the journal head of the snapshot's cut,
with the `oracle-state` extras (switches, terminal attach counts, live object counts, panic log). A
debug or `--features oracle` daemon answers `oracle-state` with the asking connection's `session.snapshot`
result (`clients` included) and its journal head from the one snapshot builder
(`public_session_snapshot_at_cut`), so `session`, `journalHead`, `terminalAttach` and `liveObjects` (all
but `subscriptions`) are one cut. A release daemon, or a push-base daemon from before task 021, answers
`oracle-state` as an unknown command; the facet is then the v0 facet: `session.snapshot` and
`settings.snapshot` only, with no `journalHead` and no `oracle` (both optional in the schema). `settings`
is the `settings.snapshot` result after the schema's capture rules, which check_snapshot_schema.py owns.
Nothing here normalizes: volatile fields, path rewrites and id labels are normalize.py's (task 013).

With `facets: v0` in the session context (facets_v0.py capture, p15-oracle-006) a case reads only push-base
methods (no `oracle-state`), runs on the wall clock and refuses advance_clock, so the push base and any later SHA
give comparable snapshots; the snapshot schema is then the v0 one (facets_v0.write_schema).

Each case gets:
- its own state root `/tmp/o/<run6>/<case6>` (oracle.py gives it out), holding the daemon's socket
  (`s.sock`, so every socket path stays <= 100 bytes, under Linux's 108-byte sun_path), state, HOME,
  XDG dirs, TMPDIR, config and log.
- its own session name (`oracle-<token of the root>`). The daemon names its install by the session, and
  a debug-assertion build (`--profile oracle`, a debug build) with `CMUX_TUI_TEST_HOST_INSTALL_ENDPOINT=1`
  binds its terminal hosts' sockets in that install's directory, `/tmp/cmux-th-<uid>/<token>/`
  (terminal_host_runtime/sys/unix.rs), so no two cases share it. A build without debug assertions binds
  them flat in `/tmp/cmux-th-<uid>/`, one file per terminal id. The facet shows the fixture's name,
  `oracle`, as paths show $ROOT.
- one `cmux-tui --headless` child started in its own session, awaited on its readiness pipe
  (`--owner-ready-fd`, the daemon's own startup protocol), never by probing the socket.
- the environment of hermetic_env.daemon_case only (an `env -i` base, CMUX_TUI_OFFLINE=1, version
  control without the person's config), and on Linux its own network namespace (loopback only, the
  caller's uid; hermetic_env.netns_prefix). The isolation is resolved once per run: oracle.py passes
  its description as `isolation` in the session context (`oracle.py run --isolation`), and this
  file's CLI takes `--isolation` (netns by default, which refuses a host without unprivileged user
  namespaces; auto; none). Each case result carries the environment it ran with (`environment`).
  Terminals use the default per-terminal `cmux-tui __terminal-host` model (CMUX_TUI_TERMINAL_HOST_MODEL
  is unset).
- every request through the SDK: resource operations on `cmux._protocol.ProtocolConnection` (the SDK's
  wire layer; the oracle compares wire replies, so it does not decode them into dataclasses), and the
  daemon-control commands (`identify`, `shutdown-daemon`, `oracle-state`, `oracle-advance-clock`) on
  `cmux.raw.CmuxClient`.

Steps: resource.call, snapshot, settle (one ping round trip: the daemon acknowledges a mutation after
it committed it, so the next read on the connection sees it), kill and restart of the daemon process,
kill of the terminal holder (below), advance_clock (`oracle-advance-clock {ms}` of task p15-oracle-185),
and waitFor on session.events (each event re-reads the facet; no sleeps). cli, mcp, action.run, key and
tui.key belong to the other drivers.
A resource.call runs on the SDK connection its `args.connection` names (case_connections.py, task 204; `main` by
default, the others opened at their first step); a stream_open operation opens its stream through the SDK and
replies {stream_id, attachment_lease?}; `args.inFlight` sends the call, replies {request_id} at once and leaves
it waiting until a request.cancel or the teardown; `scope: connection` sends no idempotency key. Each
session.events stream is an event_log.EventLog, read up to the daemon facet's session cursor at every
checkpoint. The result's `trace` (invariants.py cmux.oracle.trace/v1: raw checkpoints, replies, `eventLogs`, and
I9's restorePreviews in a `--trace` run) is what I8 reads, and an I8 violation fails the case.
A resource.call with expect outcome `any` (a walk move of gen_walks.py) passes with ok or a typed error, and what
it gave is the `reply` facet of its settled checkpoint, so a differential run compares it like any facet.

Invariant I6 (no orphan processes or sockets). Each case runs in its own worker process (`case-worker`),
which on Linux is a child subreaper (prctl PR_SET_CHILD_SUBREAPER): a process the case starts stays in
the worker's process tree until it exits, whatever its environment, session or parent did, so the
worker finds all of them by walking /proc/<pid>/task/*/children from itself, never by a scan of the
host's process table. macOS has no subreaper; there the worker also reads the case's marker
(`CMUX_ORACLE_CASE=<state root>`) from `ps`, which finds a child that kept its environment. Teardown
asks the daemon to stop and end its terminals (`shutdown-daemon end_terminals`; a daemon a step killed
or that died is started again first, so it adopts its terminals and rebinds its endpoints, then ends
them), waits for those exits on pidfds (kqueue on macOS), and then any process left in the tree fails
the case and is killed. A process is known by pid and start time, so a reused pid is never mistaken
for it. The session in oracle.py's process then checks the sockets: a socket file someone still listens
on fails the case; one with no listener (connect is refused) is a file the daemon did not remove, which
the result reports as daemon debt. When a worker did not finish (it hung or crashed), the session ends
its tree by SIGTERM and falls back to one marker scan of the process table for that case.

A kill of `process: holder` ends every process that runs the case's terminals (VT workers): each
`__terminal-host` on the default arm, the install's one `__holder` on the holder arm
(CMUX_TUI_TERMINAL_HOST_MODEL=holder). Before it ends a terminal host, it waits until the daemon holds
that host's PTY master (custody), without which the daemon cannot replace a dead host on its shell. Its
reply names the kinds it ended and the daemon's record of each ended terminal host: the `host_replaced`
line or the host-loss line that the daemon appends to `terminal-losses.jsonl` in the case's state
(cmux-tui/spec/terminal-host.md). A holder has no such record: the daemon starts a new holder and hands
it every PTY master. A case with a holder kill by ABRT arms the terminal host's debug crash seam
(CMUX_TUI_TEST_HOST_ABORT_ONCE, terminal_host_runtime/shared/host_crash.rs): the kill releases it, and
the host panics and aborts itself, so its panic hook writes the crash record that the daemon's line names.
A worker that does not wait on the seam (the holder, or a host started after the first one) gets SIGABRT.

Invariant I16 (the daemon panic log is empty at teardown). A session refuses a binary without the lock-rank
checker of cmux-tui-core/src/lock_rank.rs (invariants.lock_ranks_compiled_in): it builds only with debug
assertions, which the oracle profile keeps, so no case runs on a build that hides a lock-order bug. A case
refuses an environment whose owner or acpmux panic log would resolve outside its state root
(`panic_log_dirs`, the daemons' own resolution), so it reads its own panics and no other case's. After the
worker (every case process has exited, a panic during shutdown included) and before the root is removed,
the session reads every panic log under the root (invariants.read_panic_log): each line fails a passing case
with its message and location, and a Crash or Timeout keeps its status and gains the panic text, which
usually says why the daemon died. A traced case's trace gets the lines as `teardown.panicLog`.

Chrome reference (chromium/src):
- base/test/launcher/test_launcher.cc: each test child runs in its own process group and the launcher
  kills what remains of that group when the test ends (KillSpawnedTestProcesses), so a leaked process
  never outlives its test. cmux-tui's terminal hosts call setsid(), so the worker's subreaper tree
  stands in for the group here.
- chrome/test/base/in_process_browser_test.cc: a fresh temporary user data dir per test
  (temp_user_data_dir_), the per-case state root's model.
- base/task/common/checked_lock_impl.cc: CheckedLock's acquisition-order DCHECKs, kept in an optimized build by
  dcheck_always_on, as [profile.oracle] keeps lock_rank.rs; third_party/blink/tools/blinkpy/web_tests/port/
  driver.py fails a test on the content shell's crash output even when its text output matched (I16).
- content/public/test/browser_test_utils.h CrashTab and RenderProcessHostWatcher: a test crashes a
  child on purpose, inside ScopedAllowRendererCrashes, and waits for the browser to see the exit
  before it checks what the browser shows; the holder kill waits for the daemon's record the same way.

Switch arms (task 049): a daemon gets its arms as CMUX_TUI_SWITCHES (switches.arm_plan's
`daemon_environment()`), and `daemon_readback` reads them back from `identify` and `oracle-state`; a
mismatch is arm-not-applied. `arms` runs both on one hermetic daemon. The case driver (`run-case`,
DaemonSession) still runs the default arms only and refuses a session with switches.

Usage:
  driver_daemon.py run-case --binary CMUX_TUI CASE.json [--state-base DIR] [--snapshot-schema S]
                            [--isolation netns|auto|none] [--trace TRACE.json]
                                                     one case, its result JSON; --trace also takes a journal
                                                     checkpoint at setup and writes the case's trace with an
                                                     oracle-restore-preview at every capture (invariant I9)
                                                     and the daemon's fd, thread and child counts after setup
                                                     and after the last step (I15, resource_counts.py):
                                                     invariants.py check TRACE.json
  driver_daemon.py smoke --binary CMUX_TUI [--cases 300] [--jobs 300] [--case CASE.json] [--isolation ...]
                                                     parallel cases (no-op by default), then nothing left
  driver_daemon.py facet --socket PATH               the daemon facet of a running daemon (canonical JSON)
  driver_daemon.py live-check --cmux BIN [--write]   capture_wire_fixtures.py's op script on a hermetic
                                                     daemon; its oracle-state part must equal
                                                     daemon-oracle-state.expected.json
  driver_daemon.py arms --cmux BIN [--switch NAME=ARM]... [--registry DIR] [--receipt FILE]
                                                     a hermetic daemon on those arms, read back (exit 0
                                                     applied, 1 arm-not-applied, 2 unknown switch: nothing
                                                     starts, 3 readback-failed: the answer proves no arm)
  driver_daemon.py --selftest                        offline facet and arm tests against the recorded wire fixtures
"""

from __future__ import annotations

import argparse
import concurrent.futures
import copy
import errno
import glob
import hashlib
import json
import os
import platform as platform_mod
import re
import select
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from dataclasses import dataclass, field
from functools import lru_cache, partial
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Protocol, Sequence, Set, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SDK = REPO / "cmux-tui" / "bindings" / "python"
OPERATIONS_SPEC = REPO / "cmux-tui" / "spec" / "resource-operations-v2.json"
SCHEMA = REPO / "schemas" / "oracle" / "snapshot-v1.schema.json"
WIRE = REPO / "schemas" / "oracle" / "fixtures" / "wire"
EXAMPLE = REPO / "schemas" / "oracle" / "fixtures" / "snapshot-example.json"
LIVE_EXPECTED = REPO / "schemas" / "oracle" / "fixtures" / "daemon-oracle-state.expected.json"

for _path in (str(HERE), str(SDK)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import check_snapshot_schema  # noqa: E402 - sibling of this file (capture rules of the daemon facet)
import hermetic_env  # noqa: E402 - sibling of this file, the only place env is built
from invariants import first_difference  # noqa: E402 - JSON-typed equality, a bool never equals a number
from invariants import lock_ranks_compiled_in, panic_message, read_panic_log  # noqa: E402 - invariant I16
from case_values import MISSING, decode_pointer, predicate_holds, resolve_pointer, without_pointers  # noqa: E402,F401 - shared with driver_app_v0.py
import normalize  # noqa: E402 - sibling of this file
import case_connections  # noqa: E402 - sibling of this file: case connections and streams
from case_connections import CaseConnection  # noqa: E402
import invariants  # noqa: E402 - sibling of this file (I8 of p15-oracle-204)
import resource_counts  # noqa: E402 - sibling of this file, invariant I15's daemon reading
from cmux._protocol import ProtocolConnection  # noqa: E402
from cmux.errors import (  # noqa: E402
    CmuxConnectionError,
    CmuxError,
    ResourceError,
    StreamError,
)
from cmux.errors import TimeoutError as SdkTimeout  # noqa: E402
from cmux.raw import CmuxClient  # noqa: E402

MARKER_ENV = "CMUX_ORACLE_CASE"
# The fixture's session name, as the facet shows it; each case runs as `oracle-<token>` (CasePaths.session).
SESSION_NAME = "oracle"
# prctl(2) option: orphaned descendants are re-parented to the caller, not to init.
PR_SET_CHILD_SUBREAPER = 36
SOCKET_LIMIT = hermetic_env.MAX_SOCKET_PATH_BYTES
DEFAULT_STATE_BASE = Path("/tmp/o")
SELECTORS = {"machine": "current", "session": "current"}
FACETS = (
    "topology", "daemon", "focus", "layout", "sidebar", "tabs", "overlays", "settings", "intents", "windows",
    "history", "notifications", "agents", "terminals", "webviews", "ax", "crashes", "liveObjects",
    "invariants", "switches",
)
DEFAULT_FACETS = ("daemon",)
# expect outcome `any` (case-v1, a walk move of gen_walks.py): the step passes with ok or a typed error,
# and what it gave is the `reply` facet of its settled checkpoint, compared like any facet.
ANY_OUTCOME = "any"
REPLY_FACET = "reply"
# The build receipt linux_run.sh writes beside the binary it built (cmux-oracle-build-v1, with the full sha).
BUILD_RECEIPT = "build.json"
# The daemon product's only facet; the rest come from the app (driver_app.py) or later daemon tasks.
FACET_TASKS = {"crashes": "p15-oracle-188", "liveObjects": "p15-oracle-188", "switches": "p15-oracle-049"}
ORACLE_STATE = "oracle-state"
# Invariant I9's journal restore preview, asked for at each capture of a traced case.
RESTORE_PREVIEW = "oracle-restore-preview"
# The idempotency key of the journal checkpoint a traced case takes when its daemon first starts: the
# restore preview reduces from it.
FIXTURE_CHECKPOINT_KEY = "oracle.fixture-checkpoint"
# `oracle-state` fields that make the facet's `oracle` object (schema: facets.daemon.oracle).
EXTRAS = ("switches", "terminalAttach", "liveObjects", "panicLog")
OTHER_DRIVERS = {
    "cli": "driver_cli.py (p15-oracle-048)",
    "mcp": "driver_mcp.py (p15-oracle-209)",
    "tui.key": "driver_tui.py (p15-oracle-234)",
    "action.run": "driver_app.py (p15-oracle-047)",
    "key": "driver_app.py (p15-oracle-047)",
}
SIGNALS = {"KILL": signal.SIGKILL, "TERM": signal.SIGTERM, "ABRT": signal.SIGABRT, "SEGV": signal.SIGSEGV}
# The terminal host's crash seam of debug-assertion builds (terminal_host_runtime/shared/host_crash.rs): the
# first host that starts with it waits on `<marker>.trigger` and panics and aborts once a writer opens it.
ABORT_SEAM_ENV = "CMUX_TUI_TEST_HOST_ABORT_ONCE"
# The daemon's local log of terminal-host losses and replacements, in the state directory (terminal_loss_log.rs).
LOSS_LOG = "terminal-losses.jsonl"
# The daemon takes PTY custody and appends a loss record with no event a client can wait on for either: the
# holder kill reads its descriptors and the log anew at this interval until each holds.
DAEMON_POLL_S = 0.02
# The daemon's custody exchange runs on a thread of this name (cmux-tui-core surface/rehost.rs request_custody):
# it receives the master first and stores it in the host's attachment last.
CUSTODY_THREAD = "pty-custody"
STEP_REF = re.compile(r"^\$step:([a-z0-9][a-z0-9-]{0,63})#((?:/(?:[^~/]|~[01])*)*)$")
TYPED_ID = re.compile(r"^[a-z][a-z_]*_[0-9a-f]{32}$")
ENV_WORD = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
UNKNOWN_COMMAND = "unknown variant `{}`"
# Seconds; a case's Slow expectation multiplies them (case_ctx timeout_multiplier).
REQUEST_S = 10.0
READY_S = 60.0
STOP_S = 60.0
SHUTDOWN_S = 120.0
EXIT_S = 10.0
LOG_TAIL_BYTES = 2048


# ------------------------------------------------------------------------------------- the daemon facet


class DriverError(Exception):
    """The daemon answered something the facet cannot be built from."""


class DaemonReads(Protocol):
    """The two reads the facet needs; `SdkReads` and `CaseReads` are the real ones."""

    def command(self, cmd: str) -> Mapping[str, Any]:
        """A raw `{"cmd": cmd}` request; the whole reply line (`ok`, `data`, `error`)."""

    def operation(self, operation: str, params: Mapping[str, Any]) -> Any:
        """A resource-protocol read; its result."""


def load_schema() -> Dict[str, Any]:
    return json.loads(SCHEMA.read_text(encoding="utf-8"))


def daemon_properties(schema: Mapping[str, Any]) -> Mapping[str, Any]:
    return schema["properties"]["facets"]["properties"]["daemon"]["oneOf"][0]["properties"]


def is_unknown_command(reply: Mapping[str, Any]) -> bool:
    """A daemon with no `oracle-state`: serde refuses the tag before any handler runs."""
    error = reply.get("error")
    return reply.get("ok") is False and isinstance(error, str) and UNKNOWN_COMMAND.format(ORACLE_STATE) in error


def capture_daemon_facet(reads: DaemonReads, schema: Optional[Mapping[str, Any]] = None, *,
                         v0: bool = False) -> Dict[str, Any]:
    """The `facets.daemon` value of the daemon behind `reads`; `v0` reads push-base methods only (no oracle-state)."""
    schema = load_schema() if schema is None else schema
    props = daemon_properties(schema)
    reply = {} if v0 else reads.command(ORACLE_STATE)
    facet: Dict[str, Any] = {}
    if v0:
        session = reads.operation("session.snapshot", SELECTORS)
    elif reply.get("ok") is True:
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
    facet["session"] = check_snapshot_schema.capture(schema, props["session"], session)
    facet["settings"] = check_snapshot_schema.capture(schema, props["settings"],
                                                      reads.operation("settings.snapshot", SELECTORS))
    return facet


def restore_preview_at(facet: Any, command: Callable[..., Mapping[str, Any]],
                       case_session: str) -> Optional[Dict[str, Any]]:
    """Invariant I9's input at one capture: the `oracle-restore-preview` reply (its `data`) through the daemon
    facet's `journalHead`, so the preview and the facet are one cut whatever the daemon wrote between the two
    requests (spec/commands.md). None for a facet with no journalHead (v0, not comparable) or a daemon with no
    such command. The preview's session resource shows the fixture's name, as the facet does."""
    head = facet.get("journalHead") if isinstance(facet, Mapping) else None
    if not isinstance(head, int) or isinstance(head, bool):
        return None
    try:
        reply = dict(command(RESTORE_PREVIEW, through=head))
    except KeyError:
        return None
    preview = reply.get("preview")
    sections = preview.get("session") if isinstance(preview, dict) else None
    info = sections.get("session") if isinstance(sections, dict) else None
    if isinstance(info, dict) and info.get("name") == case_session:
        info["name"] = SESSION_NAME
    return reply


def trace_capture(record: Dict[str, Any], checkpoint: str, snapshot: Mapping[str, Any],
                  restore_preview: Optional[Mapping[str, Any]]) -> None:
    """One capture in its step's `cmux.oracle.trace/v1` record (invariants.py): the raw checkpoint, and in a
    traced run I9's restore preview at the same cut. Copies, so normalizing the checkpoints later leaves the
    trace raw."""
    record.setdefault("checkpoints", {})[checkpoint] = copy.deepcopy(snapshot)
    if restore_preview is not None:
        record.setdefault("restorePreviews", {})[checkpoint] = copy.deepcopy(restore_preview)


class SdkReads:
    """`DaemonReads` over one daemon socket through the repo's Python SDK."""

    def __init__(self, socket_path: str, timeout: float = 10.0):
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


def _sibling(module: str) -> Any:
    """A sibling module of this file, imported on first use (HERE is on sys.path)."""
    return __import__(module)


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


READBACK_FAILED = "readback-failed"
ARMS_EXIT = {"applied": 0, "arm-not-applied": 1, READBACK_FAILED: 3}


def hermetic_daemon(binary: Path, root: Path) -> Any:
    """capture_wire_fixtures.py's hermetic daemon of `binary` under `root` (not started)."""
    return _sibling("capture_wire_fixtures").Daemon(binary.resolve(), root)


def arms_check(binary: Path, requested: Mapping[str, str], roots: Any, receipt: Optional[Path], *,
               make_daemon: Callable[[Path, Path], Any] = hermetic_daemon,
               open_reads: Callable[[str], Any] = SdkReads) -> int:
    """`arms`: one hermetic daemon started with the plan's CMUX_TUI_SWITCHES, its arms read back. Exit 0 when
    they are the plan's, 1 on arm-not-applied (the daemon refused the value at start, or read back others),
    2 when the request names an unknown switch (nothing starts), 3 on readback-failed (identify failed, or
    oracle-state answered without switches or with malformed ones: no arm is proved either way). Every
    verdict but 2 writes the receipt."""
    import shutil
    import subprocess
    import tempfile

    switches = _sibling("switches")
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
    root = Path(tempfile.mkdtemp(prefix="oracle-049-", dir="/tmp"))
    daemon = make_daemon(binary, root)
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
            try:
                with open_reads(daemon.socket) as reads:
                    readback = daemon_readback(plan, reads)
            except (DriverError, OSError) as error:
                record.update(verdict=READBACK_FAILED, problems=[f"daemon switch readback: {error}"])
            else:
                record.update(verdict="applied" if not readback.problems else switches.ARM_NOT_APPLIED,
                              readback=readback.arms, sources=readback.sources, problems=list(readback.problems))
    finally:
        daemon.stop()
        shutil.rmtree(root, ignore_errors=True)
    text = json.dumps(record, indent=1, sort_keys=True) + "\n"
    if receipt is not None:
        receipt.write_text(text, encoding="utf-8")
    print(text, end="")
    return ARMS_EXIT[record["verdict"]]


class CaseError(Exception):
    """Ends the case with `status` (Failure, Crash or Timeout) at `step`."""

    def __init__(self, status: str, message: str, step: Optional[str] = None):
        super().__init__(message)
        self.status = status
        self.message = message
        self.step = step


# ---------------------------------------------------------------------------------------------------------
# Paths and environment


@dataclass(frozen=True)
class CasePaths:
    root: Path

    @property
    def socket(self) -> Path:
        return self.root / hermetic_env.SOCKET_NAME

    @property
    def state(self) -> Path:
        return self.root / hermetic_env.STATE_DIR

    @property
    def home(self) -> Path:
        return self.root / hermetic_env.HOME_DIR

    @property
    def run(self) -> Path:
        return self.root / hermetic_env.RUN_DIR

    @property
    def tmp(self) -> Path:
        return self.root / hermetic_env.TMP_DIR

    @property
    def log(self) -> Path:
        return self.root / "daemon.log"

    @property
    def abort_seam(self) -> Path:
        """The marker of the terminal host's crash seam (ABORT_SEAM_ENV); `<marker>.trigger` is its FIFO."""
        return self.root / "host-abort-once"

    @property
    def abort_trigger(self) -> Path:
        return self.root / "host-abort-once.trigger"

    @property
    def loss_log(self) -> Path:
        return self.state / LOSS_LOG

    @property
    def session(self) -> str:
        """The case's own session name: the daemon names its install, so its host socket directory, by it."""
        return f"{SESSION_NAME}-{short_token(str(self.root))}"

    @property
    def install_dir(self) -> Path:
        """Where the case's terminal hosts bind on a debug-assertion build: `/tmp/cmux-th-<uid>/<token>`,
        the token being cmux-tui's stable_token (FNV-1a 64) of the session (sys/unix.rs install_endpoint_dir)."""
        return Path("/tmp") / f"cmux-th-{os.geteuid()}" / stable_token(self.session)

    @classmethod
    def for_case(cls, state_root: Optional[str], run_id: str, key: str) -> "CasePaths":
        """oracle.py's state root, or `/tmp/o/<run6>/<case6>` from the run id and case key."""
        if state_root:
            return cls(Path(state_root))
        return cls(DEFAULT_STATE_BASE / short_token(run_id) / short_token(key))

    def check(self) -> None:
        if not self.root.is_absolute():
            raise CaseError("Crash", f"state root {self.root} is not absolute")
        length = len(os.fsencode(str(self.socket)))
        if length > SOCKET_LIMIT:
            raise CaseError("Crash", f"socket path {self.socket} is {length} bytes, over {SOCKET_LIMIT}: use a "
                                     f"state base like /tmp/o (spec rule 12)")

    def create(self) -> None:
        """A fresh, empty root: a leftover from another run would be shared state."""
        if self.root.exists() and any(self.root.iterdir()):
            raise CaseError("Crash", f"state root {self.root} is not empty; it belongs to another case")
        for path in (self.root, self.state, self.home, self.tmp):
            path.mkdir(parents=True, exist_ok=True)
        self.run.mkdir(mode=0o700, exist_ok=True)


def short_token(text: str) -> str:
    """Six base-36 characters derived from `text`."""
    value = int.from_bytes(hashlib.sha256(text.encode("utf-8")).digest()[:5], "big")
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    out = ""
    for _ in range(6):
        value, rest = divmod(value, 36)
        out = digits[rest] + out
    return out


def stable_token(text: str) -> str:
    """cmux-tui's terminal_host_runtime codec::stable_token: FNV-1a 64 of the UTF-8 bytes, 16 hex digits."""
    value = 0xCBF29CE484222325
    for byte in text.encode("utf-8"):
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{value:016x}"


def host_platform() -> str:
    return "linux" if sys.platform.startswith("linux") else "mac"


def panic_log_dirs(case_env: hermetic_env.CaseEnv) -> List[Path]:
    """Where the case's daemon processes write their panic logs, resolved as their Rust code does: the owner
    beside its sessions dir (diagnostics/owner_panic_log.rs over workspace_state_dir, which the case's state dir
    sets), acpmux in ACPMUX_HOME, else HOME/.acpmux (acpmux config.rs home)."""
    acpmux = case_env.env.get("ACPMUX_HOME")
    return [case_env.state_dir.parent, Path(acpmux) if acpmux else case_env.home / ".acpmux"]


def panic_logs_outside(case_env: hermetic_env.CaseEnv, root: Path) -> Optional[str]:
    """None when both panic logs of the case resolve under its root, else why not (I16 reads only the root)."""
    base = os.path.abspath(root)
    outside = [str(d) for d in panic_log_dirs(case_env) if os.path.commonpath([base, os.path.abspath(d)]) != base]
    return f"panic logs would land outside the case root {root}: {', '.join(outside)}" if outside else None


def require_lock_ranks(binary: str) -> None:
    """Refuses a cmux-tui built without the lock-rank checker (debug assertions off), as a session refusal."""
    try:
        present = lock_ranks_compiled_in(Path(binary))
    except OSError as error:
        raise ValueError(f"cannot read --binary {binary}: {error}") from None
    if not present:
        raise ValueError(f"--binary {binary} has no lock-rank checker (built without debug assertions), so I16 "
                         "cannot see a lock-order bug: build it with scripts/cmux-next/oracle/linux_run.sh build "
                         "(--profile oracle) or a debug build")


def apply_panic_log(result: Dict[str, Any], root: Path) -> None:
    """Invariant I16 on a finished case's result, from the panic logs under its root: each line fails a Pass with
    its message and location; a Crash or Timeout keeps its status and gains the text."""
    try:
        log = read_panic_log(root)
    except OSError as error:
        if result.get("status") == "Pass":
            result["status"] = "Crash"
        result["message"] = "; ".join(filter(None, [result.get("message"),
                                                    f"I16 not checked: cannot read the panic logs: {error}"]))
        return
    trace = result.get("trace")
    if isinstance(trace, dict):
        trace["teardown"] = {**(trace.get("teardown") or {}), "panicLog": log}
    if not log:
        return
    result["panic_log"] = log
    if result.get("status") == "Pass":
        result["status"] = "Failure"
    result["message"] = "; ".join(filter(None, [result.get("message"), *(f"I16 {panic_message(e)}" for e in log)]))


def case_environment(paths: CasePaths, seed: str, isolation: hermetic_env.Isolation,
                     abort_seam: bool = False) -> hermetic_env.CaseEnv:
    """The case daemon's whole environment, from hermetic_env.py, with this driver's process marker, and the
    terminal host's crash seam when the case aborts a terminal holder (`arms_abort_seam`)."""
    extra = {MARKER_ENV: str(paths.root)}
    if abort_seam:
        extra[ABORT_SEAM_ENV] = str(paths.abort_seam)
    return hermetic_env.daemon_case(paths.root, isolation, platform=host_platform(), seed=seed, extra=extra)


def arms_abort_seam(case: Mapping[str, Any]) -> bool:
    """Whether a step of the case kills the terminal holder by ABRT, the kill that the crash seam carries out."""
    return any(step.get("op") == "kill" and (step.get("target") or {}).get("process") == "holder"
               and (step.get("args") or {}).get("signal") == "ABRT" for step in case.get("steps") or ())


# ---------------------------------------------------------------------------------------------------------
# Processes: the case's process tree, its sockets, exit waits


@dataclass(frozen=True)
class CaseProcess:
    pid: int
    ppid: int
    # /proc/<pid>/stat field 22 (clock ticks after boot), or ps lstart: a reused pid has another.
    start: str
    argv: Tuple[str, ...]

    def describe(self) -> str:
        return f"{self.pid} {' '.join(self.argv)[:120]}"


def _linux_process(pid: int, needle: Optional[bytes] = None) -> Optional[CaseProcess]:
    """The live process `pid` (not a zombie); with `needle`, only if its environment carries it."""
    try:
        with open(f"/proc/{pid}/stat", "rb") as handle:
            # Fields after the command name: state (3), ppid (4), ... starttime (22).
            fields = handle.read().rsplit(b")", 1)[-1].split()
        if fields[0] == b"Z":
            return None  # it exited; its parent has not reaped it yet
        if needle is not None:
            with open(f"/proc/{pid}/environ", "rb") as handle:
                if needle not in handle.read().split(b"\0"):
                    return None
        with open(f"/proc/{pid}/cmdline", "rb") as handle:
            argv = tuple(part.decode("utf-8", "replace") for part in handle.read().split(b"\0") if part)
    except (OSError, IndexError):
        return None  # exited while we looked, or not ours
    return CaseProcess(pid, int(fields[1]), fields[19].decode(), argv)


def _linux_children(pid: int) -> List[int]:
    kids: List[int] = []
    for path in glob.glob(f"/proc/{pid}/task/*/children"):
        try:
            with open(path, "rb") as handle:
                kids.extend(int(value) for value in handle.read().split())
        except OSError:
            continue
    return kids


def _ps_table() -> List[Tuple[int, int, bytes, str, Tuple[str, ...]]]:
    """(pid, ppid, state, start, words) of every process, the words being argv and then the environment of
    this user's own processes (BSD ps `e` appends it): the macOS source of the functions below."""
    ps = subprocess.Popen(["ps", "-axeww", "-o", "pid=,ppid=,stat=,lstart=,command="], stdout=subprocess.PIPE)
    out, _ = ps.communicate()
    rows = []
    for line in out.splitlines():
        # lstart is five words: "Mon Oct 26 05:41:00 2026".
        parts = line.split(None, 8)
        # ps lists itself, a child of the caller: never a case process.
        if len(parts) == 9 and int(parts[0]) != ps.pid:
            rows.append((int(parts[0]), int(parts[1]), parts[2], b" ".join(parts[3:8]).decode(),
                         tuple(word for word in parts[8].decode("utf-8", "replace").split(" ") if word)))
    return rows


def _ps_process(row: Tuple[int, int, bytes, str, Tuple[str, ...]]) -> Optional[CaseProcess]:
    pid, ppid, state, start, words = row
    if state.startswith(b"Z"):
        return None
    # The environment follows the command: its first NAME=value word ends argv.
    end = next((i for i, word in enumerate(words) if ENV_WORD.match(word)), len(words))
    return CaseProcess(pid, ppid, start, words[:end])


def descendants(root: int, marker: str) -> List[CaseProcess]:
    """Every live descendant of `root`, whatever its environment. On macOS also every process that carries
    the case's marker: with no subreaper there, an orphan leaves the tree for launchd.

    Linux walks /proc/<pid>/task/*/children down from `root`, so a case reads its own few processes, never
    the host's whole process table (tens of thousands on the shared VM).
    """
    if not sys.platform.startswith("linux"):
        needle = f"{MARKER_ENV}={marker}"
        rows = _ps_table()
        children: Dict[int, List[int]] = {}
        for row in rows:
            children.setdefault(row[1], []).append(row[0])
        procs = {row[0]: _ps_process(row) for row in rows}
        wanted = {row[0] for row in rows if needle in row[4] and row[0] != root}
        stack = list(children.get(root, ()))
        while stack:
            pid = stack.pop()
            wanted.add(pid)
            stack.extend(children.get(pid, ()))
        return [procs[pid] for pid in sorted(wanted) if procs.get(pid) is not None]
    found, stack, seen = [], _linux_children(root), {root}
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        proc = _linux_process(pid)
        if proc is not None:
            found.append(proc)
        stack.extend(_linux_children(pid))
    return found


def vt_worker_kind(argv: Sequence[str]) -> Optional[str]:
    """`holder` or `terminal-host` for a process that runs terminals, else None. The rule of cmux-flow-trace's
    role_of: the standalone `cmux-holder` or `__holder` of a cmux binary is the holder, the slim `cmux-tui-host`
    or `__terminal-host` a terminal host."""
    stem = os.path.basename(argv[0]) if argv else ""
    first = argv[1] if len(argv) > 1 else ""
    if stem.startswith("cmux-holder") or first == "__holder":
        return "holder"
    if stem.startswith("cmux-tui-host") or first == "__terminal-host":
        return "terminal-host"
    return None


@dataclass(frozen=True)
class HostRecord:
    """The part of a terminal-host record (cmux-tui/spec/terminal-host.md) that a holder kill reads."""

    terminal_id: str
    supports_pty_custody: bool


def host_terminals(state: Path) -> Dict[int, HostRecord]:
    """The terminal-host records (`terminal-hosts-<install>/<terminal id>.json`) by host pid."""
    found: Dict[int, HostRecord] = {}
    for path in sorted(state.glob("terminal-hosts-*/*.json")):
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(record, dict) and isinstance(record.get("host_pid"), int) \
                and isinstance(record.get("terminal_id"), str):
            found[record["host_pid"]] = HostRecord(record["terminal_id"], record.get("supports_pty_custody") is True)
    return found


def daemon_custody(pid: int) -> Tuple[int, bool]:
    """(PTY masters the daemon process holds, whether its custody exchange still runs). Linux reads /proc; macOS
    lists the descriptors with lsof, which names no threads, so there an exchange never shows as running."""
    if not sys.platform.startswith("linux"):
        listing = subprocess.run(["lsof", "-a", "-p", str(pid), "-Fn"], capture_output=True, text=True, check=False)
        return sum(1 for line in listing.stdout.splitlines() if line.startswith("n") and line.endswith("ptmx")), False
    masters = 0
    for fd in glob.glob(f"/proc/{pid}/fd/*"):
        try:
            masters += os.readlink(fd).endswith("ptmx")
        except OSError:
            continue
    exchanging = False
    for comm in glob.glob(f"/proc/{pid}/task/*/comm"):
        try:
            with open(comm, encoding="utf-8") as handle:
                exchanging = exchanging or handle.read().strip() == CUSTODY_THREAD
        except OSError:
            continue
    return masters, exchanging


def log_lines(path: Path, offset: int) -> List[Dict[str, Any]]:
    """The JSON object lines appended to `path` after byte `offset`; a last line without its newline is still
    being written and waits for the next read."""
    try:
        with open(path, "rb") as handle:
            handle.seek(offset)
            data = handle.read()
    except FileNotFoundError:
        return []
    lines = []
    for raw in data.split(b"\n")[:-1]:
        try:
            value = json.loads(raw)
        except ValueError:
            continue
        if isinstance(value, dict):
            lines.append(value)
    return lines


def host_records(lines: Iterable[Mapping[str, Any]], ended: Mapping[int, str]) -> Dict[int, Mapping[str, Any]]:
    """The daemon's record of each ended host (`ended`: terminal id by host pid): the `host_replaced` line that
    names it as `old_host_pid`, or the host-loss line of its terminal (an `end` and no `event`)."""
    found: Dict[int, Mapping[str, Any]] = {}
    for line in lines:
        for pid, terminal in ended.items():
            if pid in found:
                continue
            replaced = line.get("event") == "host_replaced" and line.get("old_host_pid") == pid
            lost = "event" not in line and "end" in line and line.get("terminal_id") == terminal
            if replaced or lost:
                found[pid] = line
    return found


def still_running(known: Iterable[CaseProcess]) -> List[CaseProcess]:
    """The processes of `known` that still run: same pid and same start time."""
    if not sys.platform.startswith("linux"):
        rows = {row[0]: _ps_process(row) for row in _ps_table()}
        procs = (rows.get(p.pid) for p in known)
    else:
        procs = (_linux_process(p.pid) for p in known)
    starts = {p.pid: p.start for p in known}
    return [proc for proc in procs if proc is not None and proc.start == starts[proc.pid]]


def become_subreaper() -> bool:
    """Makes this process the reaper of its orphaned descendants (Linux 3.4+); False elsewhere."""
    if not sys.platform.startswith("linux"):
        return False
    import ctypes  # noqa: PLC0415 - Linux only

    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_CHILD_SUBREAPER)")
    return True


def reap_orphans(keep: Optional[int]) -> None:
    """Reaps the exited orphans a subreaper adopted (every exited child but `keep`, which subprocess owns)."""
    if not sys.platform.startswith("linux"):
        return
    for pid in _linux_children(os.getpid()):
        if pid == keep:
            continue
        try:
            os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            continue


def scan_markers() -> Dict[str, List[CaseProcess]]:
    """Every live process that carries a case marker, by marker: one pass over the whole process table.
    Only for a case whose worker did not finish, and for the smoke run's final check."""
    found: Dict[str, List[CaseProcess]] = {}
    prefix = f"{MARKER_ENV}="
    if not sys.platform.startswith("linux"):
        for row in _ps_table():
            marks = [word for word in row[4] if word.startswith(prefix)]
            proc = _ps_process(row) if marks else None
            if proc is not None:
                found.setdefault(marks[0][len(prefix):], []).append(proc)
        return found
    head = prefix.encode()
    for path in glob.glob("/proc/[0-9]*"):
        try:
            with open(f"{path}/environ", "rb") as handle:
                marks = [entry for entry in handle.read().split(b"\0") if entry.startswith(head)]
        except OSError:
            continue  # not this user's, or gone
        if marks:
            proc = _linux_process(int(path[6:]), marks[0])
            if proc is not None:
                found.setdefault(marks[0][len(head):].decode("utf-8", "replace"), []).append(proc)
    return found


def socket_paths(processes: Sequence[CaseProcess]) -> Set[str]:
    """Unix socket paths the processes name (`--socket PATH`) or listen on (Linux: the unix socket table
    of each process's own network namespace, so a case under the netns prefix is read in its own)."""
    paths: Set[str] = set()
    for proc in processes:
        for flag, value in zip(proc.argv, proc.argv[1:]):
            if flag == "--socket":
                paths.add(value)
    if not sys.platform.startswith("linux"):
        return paths
    inodes: Set[str] = set()
    # One live process per network namespace: /proc/<pid>/net/unix lists that namespace's sockets.
    tables: Dict[str, int] = {}
    for proc in processes:
        try:
            tables.setdefault(os.readlink(f"/proc/{proc.pid}/ns/net"), proc.pid)
        except OSError:
            continue  # gone
        for fd in glob.glob(f"/proc/{proc.pid}/fd/*"):
            try:
                target = os.readlink(fd)
            except OSError:
                continue
            if target.startswith("socket:["):
                inodes.add(target[8:-1])
    if not inodes:
        return paths
    for pid in tables.values():
        try:
            with open(f"/proc/{pid}/net/unix", "r", encoding="utf-8", errors="replace") as handle:
                rows = handle.read().splitlines()[1:]
        except OSError:
            continue  # the process exited; its sockets were named by the others or are gone with it
        for row in rows:
            # Num RefCount Protocol Flags Type St Inode [Path]; an abstract name starts with '@'.
            columns = row.split(None, 7)
            if len(columns) == 8 and columns[6] in inodes and columns[7].startswith("/"):
                paths.add(columns[7])
    return paths


def socket_files(root: Path) -> Set[str]:
    found = set()
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            path = os.path.join(dirpath, name)
            try:
                if os.lstat(path).st_mode & 0o170000 == 0o140000:
                    found.add(path)
            except OSError:
                continue
    return found


def has_listener(path: str) -> bool:
    """Whether a process accepts on the Unix socket file `path`. Only a refused connect (no listener, or
    no file) says no; any other answer counts as a listener, so a doubt fails the case."""
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.settimeout(1.0)
        probe.connect(path)
    except (ConnectionRefusedError, FileNotFoundError):
        return False
    except OSError:
        return True
    finally:
        probe.close()
    return True


def wait_for_exits(pids: Iterable[int], timeout: float) -> Set[int]:
    """Waits until every pid exited or `timeout` passed; returns the pids still alive.

    Exit events, not polling: a pidfd per process on Linux (readable once it exits), kqueue NOTE_EXIT
    elsewhere. A pid that is already gone counts as exited.
    """
    pending = set(pids)
    if not pending:
        return set()
    deadline = time.monotonic() + timeout
    if hasattr(os, "pidfd_open"):
        fds: Dict[int, int] = {}
        for pid in pending:
            try:
                fds[os.pidfd_open(pid)] = pid
            except ProcessLookupError:
                continue
        poller = select.poll()
        for fd in fds:
            poller.register(fd, select.POLLIN)
        try:
            while fds:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                for fd, _event in poller.poll(remaining * 1000):
                    poller.unregister(fd)
                    os.close(fd)
                    fds.pop(fd)
            return set(fds.values())
        finally:
            for fd in fds:
                os.close(fd)
    queue = select.kqueue()
    try:
        alive = set()
        for pid in pending:
            event = select.kevent(pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                  fflags=select.KQ_NOTE_EXIT)
            try:
                queue.control([event], 0, 0)
                alive.add(pid)
            except ProcessLookupError:
                continue
        while alive:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            for event in queue.control(None, len(alive), remaining):
                alive.discard(event.ident)
        return alive
    finally:
        queue.close()


def log_tail(path: Path) -> str:
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - LOG_TAIL_BYTES))
            return handle.read().decode("utf-8", "replace").strip()
    except OSError:
        return ""


# ---------------------------------------------------------------------------------------------------------
# The case daemon


@dataclass
class DaemonExit:
    step: str
    kind: str
    reason: str
    exit_code: Optional[int]


class Daemon:
    """One cmux-tui child on one state root, with its SDK clients."""

    def __init__(self, binary: str, paths: CasePaths, case_env: hermetic_env.CaseEnv, scale: float):
        self.binary = binary
        self.paths = paths
        self.case_env = case_env
        self.scale = scale
        self.proc: Optional[subprocess.Popen] = None
        self.conn: Optional[CaseConnection] = None
        # case-v1 `args.connection` -> its SDK connection; `main` is `conn`.
        self.case_conns: Dict[str, CaseConnection] = {}
        self.raw: Optional[CmuxClient] = None
        self.identity: Dict[str, Any] = {}
        self.starts = 0
        self.virtual_clock = False

    @property
    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def start(self, step: str) -> None:
        read_fd, write_fd = os.pipe()
        argv = [self.binary, "--headless", "--session", self.paths.session, "--socket", str(self.paths.socket),
                "--state", str(self.paths.state), "--owner-ready-fd", str(write_fd)]
        try:
            with open(self.paths.log, "ab") as log:
                self.proc = subprocess.Popen(
                    self.case_env.command(argv), env=dict(self.case_env.env), cwd=str(self.case_env.cwd),
                    pass_fds=(write_fd,), stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL, stderr=log, start_new_session=True,
                )
        except OSError as error:
            os.close(read_fd)
            raise CaseError("Crash", f"cannot start {self.binary}: {error}", step) from None
        finally:
            os.close(write_fd)
        self.starts += 1
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(read_fd, selectors.EVENT_READ)
                byte = os.read(read_fd, 1) if selector.select(READY_S * self.scale) else None
        finally:
            os.close(read_fd)
        if byte is None:
            raise CaseError("Timeout", f"the daemon did not report ready in {READY_S * self.scale:.0f} s", step)
        if not byte:
            self.proc.wait()
            raise CaseError("Crash", f"the daemon exited before it was ready ({self.exit_text()}): "
                                     f"{log_tail(self.paths.log)}", step)
        try:
            self.conn = CaseConnection(str(self.paths.socket), REQUEST_S * self.scale)
            # The daemon numbers clients as it registers them (public_client_id), so the resource connection
            # answers once before the control client connects: every start gives each connection the same id.
            self.conn.request("session.ping", SELECTORS, timeout=REQUEST_S * self.scale)
            self.raw = CmuxClient(str(self.paths.socket), timeout=REQUEST_S * self.scale)
            self.identity = self.command("identify", step)
        except CmuxError as error:
            raise CaseError("Crash", f"cannot connect to the daemon: {error}", step) from None
        self.virtual_clock = self.probe_clock(step)

    def exit_text(self) -> str:
        code = self.proc.returncode if self.proc is not None else None
        if code is None:
            return "running"
        if code < 0:
            return f"signal {signal.Signals(-code).name}"
        return f"exit {code}"

    def exit_code(self) -> Optional[int]:
        code = self.proc.returncode if self.proc is not None else None
        return code if code is not None and code >= 0 else None

    def request(self, method: str, params: Mapping[str, Any], key: Optional[str], timeout: float) -> Any:
        if self.conn is None:
            raise CmuxConnectionError("the daemon is not running")
        return self.conn.request(method, params, idempotency_key=key, timeout=timeout)

    def connection(self, name: str) -> CaseConnection:
        """The SDK connection of case connection `name`, opened at its first step: the daemon registers
        clients in connection order, so each run gives a case connection the same client id."""
        if self.conn is None:
            raise CmuxConnectionError("the daemon is not running")
        if name == case_connections.MAIN:
            return self.conn
        conn = self.case_conns.get(name)
        if conn is None or conn.closed:
            conn = CaseConnection(str(self.paths.socket), REQUEST_S * self.scale)
            self.case_conns[name] = conn
        return conn

    def command(self, cmd: str, step: str, **params: Any) -> Dict[str, Any]:
        """A daemon-control command; an unknown command raises KeyError, a refusal CaseError."""
        if self.raw is None:
            raise CmuxConnectionError("the daemon is not running")
        return self.reply(self.raw.request(cmd, **params), cmd, step)

    @staticmethod
    def reply(response: Dict[str, Any], cmd: str, step: str) -> Dict[str, Any]:
        if response.get("ok") is True:
            data = response.get("data")
            return data if isinstance(data, dict) else {}
        error = str(response.get("error", "unknown error"))
        if UNKNOWN_COMMAND.format(cmd) in error:
            raise KeyError(cmd)
        raise CaseError("Failure", f"{cmd} refused: {error[:300]}", step)

    def probe_clock(self, step: str) -> bool:
        """A daemon with the oracle virtual clock (p15-oracle-185) accepts an advance of 0 ms."""
        try:
            self.command("oracle-advance-clock", step, ms=0)
        except (KeyError, CaseError):
            return False
        return True

    def close_clients(self) -> None:
        for client in (*self.case_conns.values(), self.conn, self.raw):
            if client is not None:
                try:
                    client.close()
                except CmuxError:
                    pass
        self.case_conns = {}
        self.conn = None
        self.raw = None

    def reap(self, timeout: float) -> bool:
        """Waits for the child's exit event, then reaps it; False if it is still running."""
        if self.proc is None or self.proc.poll() is not None:
            return True
        if wait_for_exits([self.proc.pid], timeout):
            return False
        self.proc.wait()
        return True

    def kill(self, sig: int) -> None:
        if self.proc is None or self.proc.poll() is not None:
            return
        try:
            os.kill(self.proc.pid, sig)
        except ProcessLookupError:
            pass
        self.close_clients()
        if not self.reap(EXIT_S * self.scale) and sig != signal.SIGKILL:
            os.kill(self.proc.pid, signal.SIGKILL)
            self.reap(EXIT_S * self.scale)

    def stop(self, step: str, end_terminals: bool) -> None:
        """`shutdown-daemon` for this generation, then the child's exit. Ending the terminals waits for their
        hosts (up to 60 s, then 5 s after SIGKILL: mux/terminal_reap.rs), so the request gets the CLI's 120 s."""
        try:
            with CmuxClient(str(self.paths.socket), timeout=SHUTDOWN_S * self.scale) as client:
                self.reply(client.request("shutdown-daemon", pid=int(self.identity["pid"]),
                                          generation=str(self.identity["generation"]), force=True,
                                          end_terminals=end_terminals), "shutdown-daemon", step)
        except (CmuxError, KeyError) as error:
            raise CaseError("Crash", f"shutdown-daemon failed: {error!r}: {log_tail(self.paths.log)}", step) from None
        self.close_clients()
        if not self.reap(STOP_S * self.scale):
            raise CaseError("Timeout", f"the daemon did not exit {STOP_S * self.scale:.0f} s after shutdown-daemon",
                            step)


# ---------------------------------------------------------------------------------------------------------
# Pure helpers: selectors and step references (pointers and predicates: case_values.py)


class CaseReads:
    """`DaemonReads` over a case's daemon. The case runs as `oracle-<token>` only to isolate its install
    directory; the facet shows the fixture's session name, `oracle`."""

    def __init__(self, daemon: Daemon, case_session: str, timeout: float):
        self.daemon = daemon
        self.case_session = case_session
        self.timeout = timeout

    def command(self, cmd: str) -> Mapping[str, Any]:
        if self.daemon.raw is None:
            raise CmuxConnectionError("the daemon is not running")
        reply = self.daemon.raw.request(cmd)
        data = reply.get("data")
        if isinstance(data, dict):
            self.rename(data.get("session"))
            self.rename_panic_log(data.get("panicLog"))
        return reply

    def operation(self, operation: str, params: Mapping[str, Any]) -> Any:
        result = self.daemon.request(operation, params, None, self.timeout)
        if operation == "session.snapshot":
            self.rename(result)
        return result

    def rename(self, snapshot: Any) -> None:
        info = snapshot.get("session") if isinstance(snapshot, dict) else None
        if isinstance(info, dict) and info.get("name") == self.case_session:
            info["name"] = SESSION_NAME

    def rename_panic_log(self, panic_log: Any) -> None:
        """The owner names its panic log by the session (owner_panic_log.rs: `owner-panics-<session>.jsonl`), so
        the facet shows the fixture's name there too; two runs of one case then give the same path."""
        name = f"owner-panics-{self.case_session}."
        path = panic_log.get("path") if isinstance(panic_log, dict) else None
        if isinstance(path, str) and name in path:
            panic_log["path"] = path.replace(name, f"owner-panics-{SESSION_NAME}.")


def encode_selector(kind: str, value: Any) -> str:
    """A case handle as a resource selector: the fixture's machine and session are `current`, a typed id
    (or a value an earlier step returned) is sent as is, any other handle is a name selector."""
    if not isinstance(value, str):
        raise CaseError("Crash", f"target.{kind} is {value!r}, not a string")
    if (kind, value) in (("machine", "local"), ("session", "fixture")) or value == "current":
        return "current"
    if TYPED_ID.match(value) or value.startswith("name:"):
        return value
    return f"name:{value}"


def selector_params(spec: Mapping[str, Any], target: Mapping[str, Any], method: str) -> Dict[str, str]:
    accepted = (spec.get("params") or {}).get("selectors") or {}
    out = {}
    for kind, value in target.items():
        if kind == "process":
            continue
        if kind not in accepted:
            raise CaseError("Crash", f"{method} takes no {kind} selector (cmux-tui/spec/resource-operations-v2.json)")
        out[kind] = encode_selector(kind, value)
    for kind in ("machine", "session"):
        if accepted.get(kind) == "required" and kind not in out:
            out[kind] = "current"
    return out


def resolve_refs(value: Any, replies: Mapping[str, Any]) -> Any:
    """Substitutes `$step:<id>#<pointer>` strings with the value from that earlier step's reply."""
    if isinstance(value, str):
        match = STEP_REF.match(value)
        if not match:
            return value
        step, pointer = match.groups()
        if step not in replies:
            raise CaseError("Crash", f"{value}: step {step} has no reply")
        found = resolve_pointer(replies[step], pointer)
        if found is MISSING:
            raise CaseError("Failure", f"{value}: the reply of {step} has nothing at {pointer}")
        return found
    if isinstance(value, list):
        return [resolve_refs(item, replies) for item in value]
    if isinstance(value, dict):
        return {key: resolve_refs(item, replies) for key, item in value.items()}
    return value


def reply_facet(kind: str, detail: Any) -> Dict[str, Any]:
    """The reply facet of a step with an any outcome: ok with its mutation receipt's replayed flag, or the typed
    error code. The reply's value is left out: the daemon facet beside it holds the objects it names."""
    if kind == "error":
        return {"outcome": "error", "error": detail}
    out: Dict[str, Any] = {"outcome": "ok"}
    if isinstance(detail, dict) and isinstance(detail.get("replayed"), bool):
        out["replayed"] = detail["replayed"]
    return out


def not_comparable(reason: str, task: Optional[str] = None) -> Dict[str, str]:
    out = {"status": "not-comparable", "reason": reason}
    if task:
        out["task"] = task
    return out


def crash_allowed(entries: Sequence[Mapping[str, Any]], exits: Sequence[DaemonExit]) -> Optional[str]:
    """None when allow_crashes covers every exit, else why not (invariant I17's rule for the daemon kind)."""
    by_kind: Dict[str, List[DaemonExit]] = {}
    for item in exits:
        by_kind.setdefault(item.kind, []).append(item)
    for kind, items in sorted(by_kind.items()):
        mine = [e for e in entries if e.get("kind") == kind]
        for item in items:
            if not any("steps" not in e or item.step in e["steps"] for e in mine):
                return f"a {kind} exit at step {item.step} ({item.reason}) is not in allow_crashes"
        allowed = sum(int(e.get("max", 1)) for e in mine)
        if len(items) > allowed:
            return f"{len(items)} {kind} exits, allow_crashes allows {allowed}"
    return None


def receipt_kind(spec: Mapping[str, Any]) -> str:
    """The reply kind of an operation (case-v1 expect.receipt): its catalog result type in snake case,
    mutation_result for a mutation (gen_streams.receipt_kind writes the cases with the same rule)."""
    result = spec.get("result") or {}
    if result.get("kind") == "apply" and result.get("name") == "MutationResult":
        return "mutation_result"
    return re.sub(r"(?<!^)(?=[A-Z])", "_", str(result.get("name") or "result")).lower()


@lru_cache(maxsize=1)
def operations_spec() -> Dict[str, Any]:
    with open(OPERATIONS_SPEC, encoding="utf-8") as handle:
        return json.load(handle)["operations"]


@lru_cache(maxsize=4)
def load_snapshot_schema(path: str) -> Tuple[Optional[normalize.Schema], str]:
    """The snapshot schema as normalize.py loads it, or None and why it refused it (cached either way)."""
    try:
        return normalize.Schema.load(Path(path)), ""
    except normalize.OracleError as error:
        return None, str(error)


def host_meta() -> Dict[str, str]:
    model = "unknown"
    for path in ("/sys/devices/virtual/dmi/id/product_name", "/sys/firmware/devicetree/base/model"):
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                model = handle.read().strip("\0\n ") or model
            break
        except OSError:
            continue
    return {"os": f"{platform_mod.system()} {platform_mod.release()}", "arch": platform_mod.machine(),
            "model": model}


# ---------------------------------------------------------------------------------------------------------
# One case


@dataclass
class Capture:
    step: str
    checkpoint: str
    snapshot: Dict[str, Any]
    # The oracle-restore-preview reply at the daemon facet's cut (a traced case only).
    restore_preview: Optional[Dict[str, Any]] = None


@dataclass
class CaseState:
    replies: Dict[str, Any] = field(default_factory=dict)
    # The trace's steps (invariants.py cmux.oracle.trace/v1), by step id in case order.
    trace_steps: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    # The reply facet of each step with an any outcome, by step id.
    reply_facets: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    captures: List[Capture] = field(default_factory=list)
    exits: List[DaemonExit] = field(default_factory=list)
    killed_by: Optional[str] = None
    # I15: the daemon's resource_counts.py readings after setup and at teardown (a traced case only).
    resources: Tuple[Optional[Dict[str, Any]], Optional[Dict[str, Any]]] = (None, None)


class CaseRun:
    """One case in a worker process: the steps, then an orderly shutdown of everything it started."""

    def __init__(self, binary: str, sha: str, schema: normalize.Schema, case: Mapping[str, Any],
                 ctx: Mapping[str, Any], session_ctx: Mapping[str, Any], isolation: hermetic_env.Isolation):
        self.case = case
        self.schema = schema
        self.known: Dict[int, CaseProcess] = {}
        self.sockets: Set[str] = set()
        self.case_id = ctx.get("case_id") or f"{case.get('suite')}/{case.get('id')}"
        self.scale = float(ctx.get("timeout_multiplier") or 1)
        self.paths = CasePaths.for_case(ctx.get("state_root"), str(session_ctx.get("run_id") or "run"),
                                        str(ctx.get("key") or self.case_id))
        fixture = case.get("fixture") or {}
        seed = str(fixture.get("seed") or case.get("id") or "oracle")
        # A holder kill by ABRT is the terminal host's own abort (the crash seam), armed before the daemon starts.
        self.abort_seam = arms_abort_seam(case)
        self.case_env = case_environment(self.paths, seed, isolation, self.abort_seam)
        self.daemon = Daemon(binary, self.paths, self.case_env, self.scale)
        self.sha = sha
        # v0 facets (facets_v0.py): only the push-base methods and a wall clock, so a capture
        # of the push base and one of a later SHA compare.
        self.v0 = session_ctx.get("facets") == "v0"
        # `trace` in the session context (`run-case --trace`): the result's cmux.oracle.trace/v1 document (always
        # there, for I8) also has a restore preview at every capture (I9). Off by default: it takes a journal
        # checkpoint when the daemon first starts, one more journal record than the corpus expects.
        self.restore_previews = bool(session_ctx.get("trace")) and not self.v0
        self.state = CaseState()
        self.streams = case_connections.CaseStreams()
        self.host = host_meta()
        self.dirty = False
        self.ops: Dict[str, Callable[[int, Mapping[str, Any]], Any]] = {
            "resource.call": self.op_resource_call,
            "snapshot": self.op_snapshot,
            "settle": self.op_settle,
            "kill": self.op_kill,
            "restart": self.op_restart,
            "advance_clock": self.op_advance_clock,
        }

    # -- the run

    def run(self) -> Dict[str, Any]:
        status, message, at = "Pass", "", None
        problems: List[str] = []
        try:
            try:
                refusal = panic_logs_outside(self.case_env, self.paths.root)
                if refusal:
                    raise CaseError("Crash", f"I16: {refusal}", "setup")
                self.case_env.prepare()
                if self.abort_seam:
                    os.mkfifo(self.paths.abort_trigger, 0o600)
                self.daemon.start("setup")
                if self.restore_previews:
                    self.fixture_checkpoint()
                    self.state.resources = (self.daemon_resources("setup"), None)
                for index, step in enumerate(self.case.get("steps") or ()):
                    self.run_step(index, step)
                if self.restore_previews:
                    self.state.resources = (self.state.resources[0], self.daemon_resources("teardown"))
            except CaseError as error:
                status, message, at = error.status, error.message, error.step
            except CmuxError as error:
                status, message = "Crash", f"SDK error: {error!r}"
        finally:
            # Also when a driver bug raises: the worker reports it after the shutdown.
            self.streams.close(EXIT_S * self.scale)
            problems = self.shutdown()
        if problems:
            message = "; ".join(filter(None, [message, *problems]))
            if status == "Pass":
                status = "Failure"
        result: Dict[str, Any] = {"status": status, "message": message, "checkpoints": [],
                                  "sockets": sorted(self.sockets), "environment": self.case_env.receipt()}
        if at:
            result["step"] = at
        if self.dirty:
            result["session_dirty"] = True
        try:
            result["checkpoints"] = self.canonical_checkpoints()
        except normalize.OracleError as error:
            result.update(status="Crash", message="; ".join(filter(None, [message, f"snapshot refused: {error}"])))
        result["trace"] = self.trace_doc()
        found = self.i8(result["trace"])
        if found and result["status"] == "Pass":
            result.update(status="Failure", message="; ".join(filter(None, [result["message"], *found])))
        return result

    def trace_doc(self) -> Dict[str, Any]:
        """The case as invariants.py reads it: raw checkpoints, each step's replies, the event logs, and in a
        traced run I9's restore previews and the daemon's resource_counts.py readings after setup and at
        teardown (I15)."""
        rename = CaseReads(self.daemon, self.paths.session, 0).rename
        doc: Dict[str, Any] = {"schema": invariants.TRACE_SCHEMA, "case": self.case_id,
                               "steps": list(self.state.trace_steps.values()),
                               "eventLogs": self.streams.records(rename)}
        if self.case.get("allow_crashes"):
            doc["allow_crashes"] = list(self.case["allow_crashes"])
        setup, teardown = self.state.resources
        if setup is not None:
            doc["setup"] = {"daemonResources": setup}
        if teardown is not None:
            doc["teardown"] = {"daemonResources": teardown}
        return doc

    def daemon_resources(self, step: str) -> Optional[Dict[str, Any]]:
        """The case daemon's descriptors, threads and children now (I15), with its oracle-state liveObjects (a
        debug or oracle daemon), after a ping round trip on the driver's connection, so the daemon has answered
        every request the case sent before it; None when the daemon is not running or cannot be read."""
        if not self.daemon.running or self.daemon.raw is None:
            return None
        try:
            self.daemon.request("session.ping", SELECTORS, None, REQUEST_S * self.scale)
            state = self.daemon.raw.request(ORACLE_STATE)
        except CmuxError as error:
            raise self.sdk_failure(error, step, "the I15 reading") from None
        pid = self.daemon.identity.get("pid")
        reading = resource_counts.read(pid if isinstance(pid, int) else self.daemon.proc.pid)
        live = (state.get("data") or {}).get("liveObjects") if state.get("ok") is True else None
        if reading is not None and isinstance(live, dict):
            reading["liveObjects"] = live
        return reading

    def i8(self, trace: Mapping[str, Any]) -> List[str]:
        """I8's violations: its inputs, the raw daemon facets and the session event logs, are all in the trace.
        The other invariants wait for their inputs (the follow-up of 017 named in invariants.py)."""
        if not trace["eventLogs"] or not trace["steps"]:
            return []
        try:
            report = invariants.check_trace(trace, self.case, self.schema.doc)
        except invariants.TraceError as error:
            return [f"I8: the trace is malformed: {error}"]
        return [f"I8 at {v.step}/{v.checkpoint or '-'} {v.pointer}: {v.message}"
                for v in report.violations if v.invariant == "I8"]

    def fixture_checkpoint(self) -> None:
        """The journal checkpoint a traced case's restore previews reduce from (`session.journal.checkpoint
        .create`), taken once the daemon is ready, before the first step."""
        try:
            self.daemon.request("session.journal.checkpoint.create", SELECTORS, FIXTURE_CHECKPOINT_KEY,
                                REQUEST_S * self.scale)
        except CmuxError as error:
            raise self.sdk_failure(error, "setup", "fixture journal checkpoint") from None

    def run_step(self, index: int, step: Mapping[str, Any]) -> None:
        step_id = step["id"]
        op = step["op"]
        handler = self.ops.get(op)
        if handler is None:
            owner = OTHER_DRIVERS.get(op, "no driver")
            raise CaseError("Crash", f"op {op} is not a daemon-driver step; it runs in {owner}", step_id)
        self.check_alive(step_id)
        record: Dict[str, Any] = {"id": step_id, "op": op, "checkpoints": {}}
        record.update((key, step[key]) for key in ("readOnly", "expect") if key in step)
        self.state.trace_steps[step_id] = record
        checkpoints = step.get("checkpoint") or ["settled"]
        facets = tuple((step.get("args") or {}).get("facets") or FACETS) if op == "snapshot" else DEFAULT_FACETS
        any_outcome = (step.get("expect") or {}).get("outcome") == ANY_OUTCOME
        if any_outcome and "settled" not in checkpoints:
            raise CaseError("Crash", "an any outcome is the reply facet of the step's settled checkpoint; its "
                                     "checkpoint list needs settled", step_id)
        if "before" in checkpoints:
            self.capture(index, step_id, "before", facets)
        waiter = Waiter(self, step) if step.get("waitFor") else None
        try:
            outcome = handler(index, step)
            self.check_expect(step, outcome)
            if waiter is not None:
                waiter.finish()
        finally:
            if waiter is not None:
                waiter.close()
        if "settled" in checkpoints:
            self.capture(index, step_id, "settled", facets + (REPLY_FACET,) if any_outcome else facets)

    def check_alive(self, step: str) -> None:
        """A daemon that exited while nobody killed it is a Crash at the step that finds it."""
        if self.state.killed_by is None and self.daemon.proc is not None and not self.daemon.running:
            self.daemon.close_clients()
            self.streams.disconnected(EXIT_S * self.scale, step)
            self.state.exits.append(DaemonExit(step, "daemon", f"exited on its own ({self.daemon.exit_text()})",
                                               self.daemon.exit_code()))
            refusal = crash_allowed(self.case.get("allow_crashes") or (), self.state.exits)
            if refusal:
                raise CaseError("Crash", f"I17: {refusal}: {log_tail(self.paths.log)}", step)
            self.state.killed_by = step

    def sdk_failure(self, error: CmuxError, step: str, what: str) -> CaseError:
        if isinstance(error, SdkTimeout):
            return CaseError("Timeout", f"{what}: {error}", step)
        if isinstance(error, CmuxConnectionError):
            self.check_alive(step)
        return CaseError("Crash", f"{what}: {error!r}", step)

    # -- steps

    def op_resource_call(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        step_id = step["id"]
        args = resolve_refs(step["args"], self.state.replies)
        target = resolve_refs(step.get("target") or {}, self.state.replies)
        method = args["method"]
        spec = operations_spec().get(method)
        if spec is None:
            raise CaseError("Crash", f"{method} is not in cmux-tui/spec/resource-operations-v2.json", step_id)
        kind = spec["class"]
        if kind not in ("read", "mutation", "connection_control", "stream_open"):
            raise CaseError("Crash", f"{method} is a {kind} operation; resource.call sends reads, mutations, "
                                     f"connection controls and stream opens", step_id)
        key = args.get("idempotencyKey")
        if args.get("scope") == "connection" and key is not None:
            raise CaseError("Crash", f"{method}: a connection-scoped call has no idempotency key", step_id)
        in_flight = bool(args.get("inFlight"))
        if in_flight and kind == "stream_open":
            raise CaseError("Crash", f"{method}: a stream open is not sent in flight", step_id)
        params = dict(args.get("params") or {})
        selectors = selector_params(spec, target, method)
        clash = sorted(set(params) & set(selectors))
        if clash:
            raise CaseError("Crash", f"{', '.join(clash)} is both a param and a target selector", step_id)
        params.update(selectors)
        record = self.state.trace_steps[step_id]
        record.update(args=args, target=target, replies=[])
        if not self.daemon.running:
            raise CaseError("Failure", f"{method}: the daemon is not running (killed at {self.state.killed_by})",
                            step_id)
        connection = str(args.get("connection") or case_connections.MAIN)
        try:
            # Before the readOnly facet: a new connection is a new client row in the session.
            conn = self.daemon.connection(connection)
        except CmuxError as error:
            raise self.sdk_failure(error, step_id, f"{method}: connection {connection}") from None
        before = self.daemon_facet(step_id) if step.get("readOnly") else None
        timeout = REQUEST_S * self.scale
        try:
            if kind == "stream_open":
                reply = self.streams.open(conn, step_id, connection, method, params, timeout)
            elif in_flight:
                # The call waits for as long as the case may run; a later request.cancel or the teardown ends it.
                reply = self.streams.send_in_flight(conn, step_id, connection, method, params,
                                                    worker_bound(self.case, self.scale))
            else:
                reply = conn.request(method, params, idempotency_key=key, timeout=timeout)
            outcome: Tuple[str, Any] = ("ok", reply)
        except ResourceError as error:
            reply = {"error": {"code": error.code, "message": error.message, "retryable": error.retryable}}
            outcome = ("error", error.code)
        except CmuxError as error:
            raise self.sdk_failure(error, step_id, method) from None
        if method == "request.cancel" and outcome[0] == "ok":
            self.streams.canceled(conn, connection, params.get("request_id"), reply, EXIT_S * self.scale)
        self.state.replies[step_id] = reply
        if not in_flight:
            got: Dict[str, Any] = {"receipt": receipt_kind(spec)} if outcome[0] == "ok" \
                else {"error": outcome[1], "message": reply["error"]["message"]}
            if outcome[0] == "ok" and kind == "mutation":
                got["result"] = copy.deepcopy(reply)  # the MutationResult, `replayed` included, for I10
            record["replies"].append(got)
        if before is not None:
            self.check_read_only(index, step_id, before)
        if step.get("ends") and outcome[0] == "ok":
            self.await_planned_exit(step_id, step["ends"])
        return outcome

    def await_planned_exit(self, step_id: str, process: str) -> None:
        """A call that ends the daemon on purpose (case-v1 step `ends`): its exit belongs to this step, so I17
        checks it against allow_crashes here, and a later restart starts the daemon without stopping it. Only a
        normal termination passes (base/process/kill.h TERMINATION_STATUS_NORMAL_TERMINATION)."""
        if process != "daemon":
            raise CaseError("Crash", f"the daemon driver ends only the daemon, not a {process} process", step_id)
        self.remember()
        self.daemon.close_clients()
        self.streams.disconnected(EXIT_S * self.scale, step_id)
        if not self.daemon.reap(STOP_S * self.scale):
            raise CaseError("Timeout", f"the daemon did not exit {STOP_S * self.scale:.0f} s after the step that "
                                       f"ends it", step_id)
        how = self.daemon.exit_text()
        self.state.exits.append(DaemonExit(step_id, "daemon", f"ended by step {step_id} ({how})",
                                           self.daemon.exit_code()))
        self.state.killed_by = step_id
        refusal = crash_allowed(self.case.get("allow_crashes") or (), self.state.exits)
        if refusal:
            raise CaseError("Crash", f"I17: {refusal}", step_id)
        if self.daemon.exit_code() != 0:
            raise CaseError("Failure", f"the step ends the daemon, which exited abnormally ({how}): "
                                       f"{log_tail(self.paths.log)}", step_id)

    def check_read_only(self, index: int, step_id: str, before: Any) -> None:
        after = self.daemon_facet(step_id)
        pair = [self.snapshot(index, "before", {"daemon": before}), self.snapshot(index, "settled", {"daemon": after})]
        first, second = normalize.canonicalize_case(pair, self.schema, self.normalize_context())
        if first.value["facets"] != second.value["facets"]:
            raise CaseError("Failure", "readOnly step changed the daemon facet", step_id)

    def op_snapshot(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        return ("ok", {})

    def op_settle(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        if not self.daemon.running:
            return ("ok", {})
        bound = int(step.get("settleMaxMs") or REQUEST_S * 1000) / 1000 * self.scale
        try:
            reply = self.daemon.request("session.ping", SELECTORS, None, bound)
        except CmuxError as error:
            raise self.sdk_failure(error, step["id"], "settle") from None
        self.state.replies[step["id"]] = reply
        return ("ok", reply)

    def op_kill(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        step_id = step["id"]
        process = step["target"]["process"]
        name = (step.get("args") or {}).get("signal", "KILL")
        if process == "holder":
            reply = self.kill_terminal_workers(step_id, name)
            self.state.replies[step_id] = reply
            return ("ok", reply)
        if process != "daemon":
            raise CaseError("Crash", f"the daemon driver kills only the daemon and its terminal holder, not a "
                                     f"{process} process", step_id)
        if not self.daemon.running:
            raise CaseError("Failure", "kill: the daemon is not running", step_id)
        self.remember()
        self.daemon.kill(SIGNALS[name])
        self.streams.disconnected(EXIT_S * self.scale, step_id)
        self.state.exits.append(DaemonExit(step_id, "daemon", f"SIG{name} by step {step_id}", self.daemon.exit_code()))
        refusal = crash_allowed(self.case.get("allow_crashes") or (), self.state.exits)
        if refusal:
            raise CaseError("Crash", f"I17: {refusal}", step_id)
        self.state.killed_by = step_id
        reply = {"signal": name}
        self.state.replies[step_id] = reply
        return ("ok", reply)

    def kill_terminal_workers(self, step_id: str, name: str) -> Dict[str, Any]:
        """Ends every process that runs the case's terminals (crash kind `holder`), waits for their exits and then
        for the daemon's record of each ended terminal host. The reply: the signal, the kinds ended, and those
        records by host pid."""
        if not self.daemon.running:
            raise CaseError("Failure", "kill: the daemon is not running", step_id)
        tree = descendants(os.getpid(), str(self.paths.root))
        workers = sorted((proc for proc in tree if vt_worker_kind(proc.argv)), key=lambda proc: proc.pid)
        if not workers:
            raise CaseError("Failure", "kill: no terminal host or holder runs the case's terminals", step_id)
        self.remember()
        terminals = host_terminals(self.paths.state)
        hosts = [proc.pid for proc in workers if vt_worker_kind(proc.argv) == "terminal-host"]
        unknown = [pid for pid in hosts if pid not in terminals]
        if unknown:
            raise CaseError("Crash", f"kill: no terminal-host record names host pid {unknown[0]}", step_id)
        ended = {pid: terminals[pid].terminal_id for pid in hosts}
        self.await_custody(step_id, sum(terminals[pid].supports_pty_custody for pid in hosts))
        offset = self.paths.loss_log.stat().st_size if self.paths.loss_log.exists() else 0
        if not (name == "ABRT" and self.release_abort_seam(workers, step_id)):
            for proc in workers:
                try:
                    os.kill(proc.pid, SIGNALS[name])
                except ProcessLookupError:
                    pass
        bound = EXIT_S * self.scale
        alive = wait_for_exits([proc.pid for proc in workers], bound)
        if alive:
            raise CaseError("Timeout", f"kill: {len(alive)} of the terminal holder's processes still run "
                                       f"{bound:.0f} s after SIG{name}", step_id)
        for proc in workers:
            self.state.exits.append(DaemonExit(step_id, "holder", f"SIG{name} of a {vt_worker_kind(proc.argv)} by "
                                                                  f"step {step_id}", None))
        refusal = crash_allowed(self.case.get("allow_crashes") or (), self.state.exits)
        if refusal:
            raise CaseError("Crash", f"I17: {refusal}", step_id)
        records = self.await_host_records(step_id, ended, offset)
        return {"signal": name, "process": "holder", "ended": sorted({str(vt_worker_kind(p.argv)) for p in workers}),
                "records": [records[pid] for pid in sorted(ended)]}

    def await_custody(self, step_id: str, hosts: int) -> None:
        """Waits until the daemon holds the PTY master of each of `hosts` terminal hosts whose record advertises
        custody and its custody exchange has finished. The daemon takes custody after each launch, adoption and
        reconnect, and only with it does a dead host get its documented replacement (cmux-tui/spec/terminal-host.md,
        PTY custody and adoption). The holder model hands the daemon each master when it starts a terminal, so a
        holder kill does not wait."""
        if hosts == 0 or self.daemon.proc is None:
            return
        bound = REQUEST_S * self.scale
        deadline = time.monotonic() + bound
        while True:
            masters, exchanging = daemon_custody(self.daemon.proc.pid)
            if masters >= hosts and not exchanging:
                return
            if time.monotonic() >= deadline:
                raise CaseError("Timeout", f"kill: the daemon held {masters} of {hosts} terminal hosts' PTY masters "
                                           f"after {bound:.0f} s", step_id)
            time.sleep(DAEMON_POLL_S)

    def release_abort_seam(self, workers: Sequence[CaseProcess], step_id: str) -> bool:
        """Opens the crash seam's FIFO for the terminal host that waits on it; False when none waits (a case without
        the seam, a holder, a host after the first), and the caller sends SIGABRT. The seam ends one host only."""
        if not self.abort_seam:
            return False
        if len(workers) != 1:
            raise CaseError("Crash", f"kill: the crash seam aborts one terminal host, and {len(workers)} processes "
                                     f"run the case's terminals", step_id)
        try:
            trigger = os.open(self.paths.abort_trigger, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as error:
            if error.errno == errno.ENXIO:
                return False
            raise CaseError("Crash", f"kill: the crash seam's FIFO: {error}", step_id) from None
        os.close(trigger)
        return True

    def await_host_records(self, step_id: str, ended: Mapping[int, str],
                           offset: int) -> Dict[int, Mapping[str, Any]]:
        """The `host_replaced` or host-loss line the daemon appends for each ended terminal host (one for each
        dead host it owned: cmux-tui/spec/terminal-host.md), from the log bytes after `offset`."""
        bound = REQUEST_S * self.scale
        deadline = time.monotonic() + bound
        while True:
            found = host_records(log_lines(self.paths.loss_log, offset), ended)
            if len(found) == len(ended):
                return found
            if time.monotonic() >= deadline:
                missing = sorted(set(ended) - set(found))
                raise CaseError("Timeout", f"kill: the daemon recorded no replacement or loss of host pid "
                                           f"{missing[0]} in {LOSS_LOG} within {bound:.0f} s", step_id)
            time.sleep(DAEMON_POLL_S)

    def op_restart(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        step_id = step["id"]
        process = step["target"]["process"]
        if process != "daemon":
            raise CaseError("Crash", f"the daemon driver restarts only the daemon, not a {process} process", step_id)
        if self.daemon.running:
            self.remember()
            self.daemon.stop(step_id, end_terminals=False)
            self.streams.disconnected(EXIT_S * self.scale, step_id)
        self.daemon.start(step_id)
        self.state.killed_by = None
        self.state.replies[step_id] = dict(self.daemon.identity)
        self.state.trace_steps[step_id]["replies"] = [{"receipt": "identify"}]
        return ("ok", self.daemon.identity)

    def op_advance_clock(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        step_id = step["id"]
        ms = int(step["args"]["ms"])
        if self.v0:
            raise CaseError("Crash", "advance_clock: v0 facets run on the wall clock (the push base has no "
                                     "oracle-advance-clock; the virtual clock is p15-oracle-185)", step_id)
        if not self.daemon.running:
            raise CaseError("Failure", "advance_clock: the daemon is not running", step_id)
        try:
            reply = self.daemon.command("oracle-advance-clock", step_id, ms=ms)
        except KeyError:
            raise CaseError("Crash", "advance_clock: this cmux-tui has no oracle-advance-clock (the oracle "
                                     "virtual clock is p15-oracle-185)", step_id) from None
        except CmuxError as error:
            raise self.sdk_failure(error, step_id, "advance_clock") from None
        self.state.replies[step_id] = reply
        return ("ok", reply)

    def check_expect(self, step: Mapping[str, Any], outcome: Tuple[str, Any]) -> None:
        expect = step.get("expect")
        if not expect:
            return
        step_id = step["id"]
        kind, detail = outcome
        if expect["outcome"] == ANY_OUTCOME:
            if step["op"] != "resource.call":
                raise CaseError("Crash", f"an any outcome is a resource.call's, not a {step['op']} step's", step_id)
            self.state.reply_facets[step_id] = reply_facet(kind, detail)
            if kind == "error":
                return
        elif expect["outcome"] != kind:
            got = f"error {detail}" if kind == "error" else "ok"
            raise CaseError("Failure", f"expected {expect['outcome']}"
                                       f"{' ' + expect['error'] if 'error' in expect else ''}, got {got}", step_id)
        if kind == "error":
            if detail != expect["error"]:
                raise CaseError("Failure", f"expected error {expect['error']}, got {detail}", step_id)
            return
        receipt = expect.get("receipt")
        if receipt == "mutation_result":
            if not (isinstance(detail, dict) and {"value", "generation", "revision", "replayed"} <= set(detail)):
                raise CaseError("Failure", f"expected a mutation_result receipt, got {json.dumps(detail)[:200]}",
                                step_id)
        elif receipt == "identify":
            if not (isinstance(detail, dict) and "pid" in detail and "generation" in detail):
                raise CaseError("Failure", "expected an identify receipt", step_id)
        elif receipt is not None:
            spec = operations_spec().get((step.get("args") or {}).get("method")) if step["op"] == "resource.call" else None
            if spec is None or receipt_kind(spec) != receipt:
                raise CaseError("Crash", f"receipt kind {receipt} has no daemon reply"
                                         f"{'' if spec is None else ' (the operation replies ' + receipt_kind(spec) + ')'}",
                                step_id)
            if not isinstance(detail, dict):
                raise CaseError("Failure", f"expected a {receipt} object, got {json.dumps(detail)[:200]}", step_id)
        if "result" in expect:
            want = resolve_refs(expect["result"], self.state.replies)
            got = detail
            if expect.get("resultExcept"):
                want, got = (without_pointers(value, expect["resultExcept"]) for value in (want, got))
            difference = first_difference(want, got)
            if difference is not None:
                at, wanted, found = difference
                raise CaseError("Failure", f"result differs at {at or '/'}: {json.dumps(found, sort_keys=True)[:200]}, "
                                           f"not {json.dumps(wanted, sort_keys=True)[:200]}", step_id)

    # -- snapshots

    def daemon_facet(self, step: str) -> Any:
        """`capture_daemon_facet` on the case's daemon (one cut when it answers `oracle-state`)."""
        if not self.daemon.running:
            return not_comparable(f"the daemon is not running (killed at step {self.state.killed_by})")
        reads = CaseReads(self.daemon, self.paths.session, REQUEST_S * self.scale)
        try:
            return capture_daemon_facet(reads, self.schema.doc, v0=self.v0)
        except CmuxError as error:
            raise self.sdk_failure(error, step, "daemon facet") from None
        except DriverError as error:
            raise CaseError("Failure", str(error)[:300], step) from None

    def facets(self, names: Sequence[str], step: str) -> Dict[str, Any]:
        out = {}
        for name in names:
            if name == "daemon":
                out[name] = self.daemon_facet(step)
            elif name == REPLY_FACET and step in self.state.reply_facets:
                out[name] = self.state.reply_facets[step]
            else:
                out[name] = not_comparable(f"the daemon product has no {name} facet", FACET_TASKS.get(name))
        return out

    def snapshot(self, index: int, checkpoint: str, facets: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "schema": "cmux.oracle.snapshot/v1",
            "meta": {
                "case": self.case_id,
                "step": index,
                "checkpoint": checkpoint,
                "product": "daemon",
                "sha": self.sha,
                "host": self.host,
                "clock": "virtual" if self.daemon.virtual_clock and not self.v0 else "wall",
                "capturedAtMs": int(time.time() * 1000),
                "facets": list(facets),
            },
            "facets": facets,
        }

    def capture(self, index: int, step: str, checkpoint: str, names: Sequence[str]) -> None:
        self.check_alive(step)
        facets = self.facets(names, step)
        preview = None
        if self.restore_previews and self.daemon.running:
            try:
                preview = restore_preview_at(facets.get("daemon"), partial(self.daemon.command, step=step),
                                             self.paths.session)
            except CmuxError as error:
                raise self.sdk_failure(error, step, "restore preview") from None
        snapshot = self.snapshot(index, checkpoint, facets)
        self.state.captures.append(Capture(step, checkpoint, snapshot, preview))
        trace_capture(self.state.trace_steps[step], checkpoint, snapshot, preview)
        self.streams.drain()
        session = snapshot["facets"].get("daemon", {}).get("session")
        cursor = session.get("cursor") if isinstance(session, dict) else None
        if isinstance(cursor, dict) and cursor.get("generation") is not None and cursor.get("revision") is not None:
            # I8 compares each log's fold with this facet at this cursor; a log that never gets there fails I8.
            self.streams.read_logs_to(str(cursor["generation"]), int(cursor["revision"]), REQUEST_S * self.scale,
                                      step, checkpoint)
        else:
            self.streams.read_logs(step, checkpoint)

    def normalize_context(self) -> normalize.Context:
        roots = tuple(dict.fromkeys([str(self.paths.root), os.path.realpath(self.paths.root)]))
        return normalize.Context(root=roots, home=(str(self.paths.home),))

    def canonical_checkpoints(self) -> List[Dict[str, Any]]:
        captures = self.state.captures
        if not captures:
            return []
        results = normalize.canonicalize_case([c.snapshot for c in captures], self.schema,
                                              self.normalize_context(), [f"{c.step}/{c.checkpoint}" for c in captures])
        return [{"step": c.step, "checkpoint": c.checkpoint, "snapshot": r.value} for c, r in zip(captures, results)]

    # -- teardown and I6

    def remember(self) -> None:
        """Records the case's processes and the sockets they use, before a stop or a kill ends them."""
        tree = descendants(os.getpid(), str(self.paths.root))
        self.known.update((proc.pid, proc) for proc in tree)
        self.sockets |= socket_paths(tree)

    def case_processes(self) -> List[CaseProcess]:
        """The case's live processes: the worker's tree, and the recorded ones still running (on macOS an
        orphan leaves the tree)."""
        live = {proc.pid: proc for proc in descendants(os.getpid(), str(self.paths.root))}
        for proc in still_running(self.known.values()):
            live.setdefault(proc.pid, proc)
        return sorted(live.values(), key=lambda proc: proc.pid)

    def shutdown(self) -> List[str]:
        """Ends what the case started, in order, and proves its process tree empty; returns the problems.
        The session checks the sockets afterwards."""
        problems: List[str] = []
        self.remember()
        not_restarted = ""
        if self.daemon.identity and not self.daemon.running:
            # A daemon a step killed, or that died, left its terminal hosts and its endpoint files: a new one
            # adopts the hosts, rebinds the endpoints, and then ends and removes both.
            try:
                self.daemon.start("teardown")
            except CaseError as error:
                not_restarted = f" (the daemon did not start again to end them: {error.message})"
                self.daemon.kill(signal.SIGKILL)
            self.remember()
        if self.daemon.running:
            try:
                self.daemon.stop("teardown", end_terminals=True)
            except CaseError as error:
                problems.append(f"I6: {error.message}")
                self.daemon.kill(signal.SIGKILL)
        self.daemon.close_clients()
        # The hosts and shells the daemon ended exit on their own time.
        wait_for_exits([proc.pid for proc in self.case_processes()], EXIT_S * self.scale)
        left = self.case_processes()
        if left:
            problems.append(f"I6: processes left after teardown{not_restarted}: "
                            + "; ".join(proc.describe() for proc in left))
            self.sockets |= socket_paths(left)
            if end_processes(left, EXIT_S * self.scale):
                problems.append("I6: processes still alive after SIGKILL")
                self.dirty = True
        reap_orphans(self.daemon.proc.pid if self.daemon.proc is not None else None)
        return problems


def end_processes(procs: Sequence[CaseProcess], timeout: float) -> Set[int]:
    """SIGKILL, then the exit events; returns the pids still alive."""
    for proc in procs:
        try:
            os.kill(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return wait_for_exits([p.pid for p in procs], timeout)


@dataclass
class Proof:
    problems: List[str] = field(default_factory=list)
    # Files the daemon should have removed: no process listens on them, so they are not I6 leaks.
    debt: List[str] = field(default_factory=list)
    # A process survived SIGKILL.
    dirty: bool = False


def prove_clean(paths: CasePaths, sockets: Iterable[str], worker_finished: bool,
                scan: Callable[[], Dict[str, List[CaseProcess]]], timeout: float) -> Proof:
    """Invariant I6 for one case, after its worker. A worker that finished proved its own process tree
    empty; for one that did not, one marker scan of the process table stands in. Then the sockets the case
    used, its root's and its install directory's: one that still listens fails the case, a file with no
    listener is daemon debt. Everything left is killed and removed, so the next case shares nothing."""
    proof = Proof()
    found = set(sockets)
    if not worker_finished:
        left = scan().get(str(paths.root), [])
        if left:
            proof.problems.append("I6: processes left by a worker that did not finish: "
                                  + "; ".join(p.describe() for p in left))
            found |= socket_paths(left)
            if end_processes(left, timeout):
                proof.problems.append("I6: processes still alive after SIGKILL")
                proof.dirty = True
    found |= socket_files(paths.root) | socket_files(paths.install_dir)
    stale = sorted(path for path in found if os.path.lexists(path))
    live = [path for path in stale if has_listener(path)]
    if live:
        proof.problems.append("I6: sockets still listening after teardown: " + ", ".join(live))
    dead = [path for path in stale if path not in live]
    if dead:
        proof.debt.append("socket files with no listener after teardown (the daemon did not remove them): "
                          + ", ".join(dead))
    long = sorted(path for path in found if len(os.fsencode(path)) > SOCKET_LIMIT)
    if long:
        proof.problems.append(f"socket paths over {SOCKET_LIMIT} bytes: " + ", ".join(long))
    for path in stale:
        try:
            os.unlink(path)
        except OSError:
            pass
    shutil.rmtree(paths.root, ignore_errors=True)
    # The case's own install directory (CasePaths.session); the shared /tmp/cmux-th-<uid> stays.
    shutil.rmtree(paths.install_dir, ignore_errors=True)
    return proof


class Waiter:
    """waitFor on a daemon facet pointer, woken by session.events (Kombucha WaitForState)."""

    def __init__(self, run: CaseRun, step: Mapping[str, Any]):
        self.run = run
        self.step_id = step["id"]
        self.spec = step["waitFor"]
        self.pointer = self.spec["pointer"]
        self.facet = decode_pointer(self.pointer)[0]
        self.stream = None
        self.stream_start = -1
        self.baseline = self.value()
        self.open()

    def value(self) -> Any:
        facets = self.run.facets([self.facet], self.step_id)
        if facets[self.facet].get("status") == "not-comparable":
            return MISSING
        return resolve_pointer(facets, self.pointer)

    def open(self) -> None:
        """Subscribes before the step acts and again after a restart, so no change is missed."""
        self.close()
        daemon = self.run.daemon
        if self.facet != "daemon" or not daemon.running or daemon.conn is None:
            return
        try:
            self.stream = daemon.conn.open_stream("session.events", SELECTORS, lambda item: item,
                                                  timeout=REQUEST_S * self.run.scale)
        except CmuxError as error:
            raise self.run.sdk_failure(error, self.step_id, "session.events") from None
        self.stream_start = daemon.starts

    def close(self) -> None:
        if self.stream is not None:
            try:
                self.stream.close()
            except CmuxError:
                pass
            self.stream = None

    def finish(self) -> None:
        bound = self.spec["maxMs"] / 1000 * self.run.scale
        deadline = time.monotonic() + bound
        while True:
            if self.run.daemon.starts != self.stream_start:
                self.open()
            if predicate_holds(self.spec, self.value(), self.baseline):
                return
            remaining = deadline - time.monotonic()
            if self.stream is None or remaining <= 0:
                raise CaseError("Timeout", f"waitFor {self.pointer} did not hold within {bound * 1000:.0f} ms",
                                self.step_id)
            try:
                self.stream.next(timeout=remaining)
            except SdkTimeout:
                continue
            except (StreamError, StopIteration):
                self.stream_start = -1  # a gap or an end: subscribe again, then re-read
            except CmuxError as error:
                raise self.run.sdk_failure(error, self.step_id, "session.events") from None


# ---------------------------------------------------------------------------------------------------------
# Driver protocol (oracle.py)


class DaemonSession:
    """The daemon product's session. Each case runs in its own worker process (`case-worker`), as
    Chrome's test launcher runs each test in a child: hundreds of cases run in parallel without one
    interpreter lock or one descriptor table, and a hung or crashed worker fails only its case. The
    session itself gives out the state roots and checks each case's sockets after its worker; `scan` (the
    whole-table marker scan) runs only for a worker that did not finish. A driver that extends the case
    (driver_cli.py, driver_mcp.py) names its own file as `worker_script`, whose `case-worker` runs its case."""

    worker_script = Path(__file__).resolve()

    def __init__(self, session_ctx: Mapping[str, Any],
                 scan: Callable[[], Dict[str, List[CaseProcess]]] = scan_markers):
        binary = session_ctx.get("binary")
        if not binary:
            raise ValueError("the daemon driver needs --binary (the cmux-tui that linux_run.sh build prints)")
        if not os.access(str(binary), os.X_OK):
            raise ValueError(f"--binary {binary} is not an executable")
        require_lock_ranks(str(binary))
        if session_ctx.get("switches"):
            raise ValueError("the case driver runs the default arms only; `driver_daemon.py arms` applies and reads "
                             "back a daemon's switch arms (p15-oracle-049)")
        if session_ctx.get("facets") not in (None, "v0", "v1"):
            raise ValueError(f"facets {session_ctx.get('facets')!r} is v0 or v1")
        default_schema = normalize.DEFAULT_SCHEMA
        if session_ctx.get("facets") == "v0" and not session_ctx.get("snapshot_schema"):
            import facets_v0  # sibling: the v1 schema cut to the push-base methods

            default_schema = facets_v0.write_schema(Path(str(session_ctx.get("out_dir") or "/tmp/oracle")))
        self.schema_path = str(session_ctx.get("snapshot_schema") or default_schema)
        schema, refusal = load_snapshot_schema(self.schema_path)
        if schema is None:
            raise ValueError(f"normalize.py refuses the snapshot schema, so no snapshot can be canonical: {refusal}")
        try:
            self.isolation = session_isolation(session_ctx.get("isolation"))
        except hermetic_env.HermeticError as error:
            raise ValueError(f"no hermetic case environment on this host: {error}") from None
        self.scan = scan
        self.binary = os.path.realpath(str(binary))
        self.session_ctx = dict(session_ctx)
        self.sha = resolve_sha(session_ctx.get("ref"), self.binary)

    def run_case(self, case: Dict[str, Any], case_ctx: Dict[str, Any]) -> Dict[str, Any]:
        case_id = case_ctx.get("case_id") or f"{case.get('suite')}/{case.get('id')}"
        paths = CasePaths.for_case(case_ctx.get("state_root"), str(self.session_ctx.get("run_id") or "run"),
                                   str(case_ctx.get("key") or case_id))
        try:
            paths.check()
            paths.create()
        except CaseError as error:
            return {"status": error.status, "message": error.message, "checkpoints": []}
        scale = float(case_ctx.get("timeout_multiplier") or 1)
        result, finished = self.run_worker(case, {**case_ctx, "state_root": str(paths.root)}, scale)
        apply_panic_log(result, paths.root)
        proof = prove_clean(paths, result.pop("sockets", ()), finished, self.scan, EXIT_S * scale)
        if proof.problems:
            result["message"] = "; ".join(filter(None, [result.get("message"), *proof.problems]))
            if result["status"] == "Pass":
                result["status"] = "Failure"
        if proof.debt:
            result["daemon_debt"] = proof.debt
            result["message"] = "; ".join(filter(None, [result.get("message"),
                                                        *(f"daemon debt (not I6): {d}" for d in proof.debt)]))
        if proof.dirty:
            result["session_dirty"] = True
        return result

    def run_worker(self, case: Dict[str, Any], case_ctx: Dict[str, Any],
                   scale: float) -> Tuple[Dict[str, Any], bool]:
        """The worker's result, and whether it finished (then it proved its own process tree empty)."""
        payload = {"binary": self.binary, "sha": self.sha, "schema": self.schema_path, "case": case,
                   "ctx": case_ctx, "session": self.session_ctx, "isolation": self.isolation.describe()}
        bound = worker_bound(case, scale)
        worker = subprocess.Popen([sys.executable, "-I", str(self.worker_script), "case-worker"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            out, err = worker.communicate(json.dumps(payload).encode(), timeout=bound)
        except subprocess.TimeoutExpired:
            # SIGTERM first: the worker ends its process tree (end_tree_on_term), then the session kills it.
            worker.terminate()
            try:
                out, err = worker.communicate(timeout=EXIT_S * scale)
            except subprocess.TimeoutExpired:
                worker.kill()
                out, err = worker.communicate()
            return {"status": "Timeout", "checkpoints": [], "session_dirty": True,
                    "message": f"the case worker ran over its bound of {bound:.0f} s: {tail(err)}"}, False
        try:
            result = json.loads(out) if worker.returncode == 0 else None
        except ValueError:
            result = None
        if not isinstance(result, dict):
            return {"status": "Crash", "checkpoints": [], "session_dirty": True,
                    "message": f"the case worker failed (exit {worker.returncode}): {tail(err)}"}, False
        return result, True

    def close(self) -> None:
        """Nothing outlives a case: each run_case ends its worker and proves I6."""


def worker_bound(case: Mapping[str, Any], scale: float) -> float:
    """Seconds a case worker may take: every bound the case can wait on, so only a hang reaches it."""
    steps = case.get("steps") or ()
    waits = sum(((s.get("waitFor") or {}).get("maxMs", 0) + s.get("settleMaxMs", 0)) / 1000 for s in steps)
    stop = SHUTDOWN_S + STOP_S
    restarts = sum(1 for s in steps if s.get("op") == "restart") * (READY_S + stop)
    return scale * (2 * READY_S + 2 * stop + 6 * EXIT_S + len(steps) * 4 * REQUEST_S + waits + restarts)


def tail(data: bytes) -> str:
    return data[-LOG_TAIL_BYTES:].decode("utf-8", "replace").strip()


def case_worker(case_class: Callable[..., "CaseRun"] = CaseRun) -> int:
    """`case-worker`: one `case_class` case from the JSON payload on stdin; the result JSON on stdout."""
    payload = json.load(sys.stdin)
    schema, refusal = load_snapshot_schema(payload["schema"])
    if schema is None:
        raise SystemExit(f"driver_daemon.py case-worker: {refusal}")
    run = case_class(payload["binary"], payload["sha"], schema, payload["case"], payload["ctx"], payload["session"],
                  hermetic_env.Isolation.from_description(payload["isolation"]))
    # Every process the case starts stays in this worker's tree, whatever it does (I6).
    become_subreaper()
    signal.signal(signal.SIGTERM, partial(end_tree_on_term, str(run.paths.root)))
    json.dump(run.run(), sys.stdout)
    return 0


def end_tree_on_term(marker: str, signum: int, _frame: Any) -> None:
    """The session's SIGTERM to a worker over its bound: ends the case's processes, then the worker."""
    end_processes(descendants(os.getpid(), marker), EXIT_S)
    os._exit(128 + signum)


def session_isolation(value: Any) -> hermetic_env.Isolation:
    """The session's isolation: a description oracle.py resolved once for the whole run (no probe
    here), or a mode for this file's own CLI (probed once per command; netns when absent)."""
    if isinstance(value, Mapping):
        return hermetic_env.Isolation.from_description(value)
    return hermetic_env.isolation_for(str(value or "netns"), host_platform())


def open_session(session_ctx: Dict[str, Any]) -> DaemonSession:
    return DaemonSession(session_ctx)


def build_receipt_sha(binary: str) -> Optional[str]:
    """The full SHA of the build receipt beside the binary (linux_run.sh writes BUILD_RECEIPT), or None."""
    try:
        sha = json.loads((Path(binary).parent / BUILD_RECEIPT).read_text(encoding="utf-8")).get("sha")
    except (OSError, ValueError, AttributeError):
        return None
    return sha if isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha) else None


def resolve_sha(ref: Any, binary: str) -> str:
    """The SHA under test: a full-SHA ref, else the build receipt beside the binary (linux_run.sh)."""
    if isinstance(ref, str) and re.fullmatch(r"[0-9a-f]{40}", ref):
        return ref
    # meta.sha is volatile (diff.py prints it); an unknown build says so with zeros.
    return build_receipt_sha(binary) or "0" * 40


# ---------------------------------------------------------------------------------------------------------
# CLI


def noop_case(index: int) -> Dict[str, Any]:
    return {
        "corpusVersion": 1, "id": f"noop-{index}", "suite": "smoke",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"}, "environment": {},
        "fixture": {"seed": f"noop-{index}", "network": "offline", "clock": "fixed"},
        "preconditions": [], "requires": ["resource_api"], "platforms": ["linux", "mac"],
        "steps": [{"id": "noop", "op": "snapshot", "args": {"facets": ["daemon"]}}],
        "invariants": [], "teardown": ["stop the case daemon"],
    }


def remove_empty_dir(path: Path) -> None:
    """A run's state base, once its cases removed their roots (a root left behind keeps it)."""
    try:
        path.rmdir()
    except OSError:
        pass


def cmd_run_case(args: argparse.Namespace) -> int:
    case = json.loads(Path(args.case).read_text(encoding="utf-8"))
    run_id = args.run_id or f"rc-{os.getpid()}-{time.time_ns()}"
    session = open_session({"binary": args.binary, "run_id": run_id, "ref": args.ref,
                            **getattr(args, "session_extra", {})})
    base = args.state_base / short_token(run_id)
    ctx = {"case_id": f"{case['suite']}/{case['id']}", "key": "0", "state_root": str(base / short_token(case["id"]))}
    result = session.run_case(case, ctx)
    remove_empty_dir(base)
    trace = result.pop("trace", None)
    if getattr(args, "trace", None):
        if trace is None or not any(step.get("checkpoints") for step in trace["steps"]):
            print("driver_daemon.py: no step captured a checkpoint: no trace", file=sys.stderr)
            return 1
        Path(args.trace).write_text(json.dumps(trace, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=1, sort_keys=True))
    return 0 if result["status"] == "Pass" else 1


def cmd_smoke(args: argparse.Namespace) -> int:
    """N cases at once (no-op cases, or N copies of --case), then nothing of theirs may be left: the test
    of task 023. Checks the marker of every case root, `pgrep -f` of the run's state base, and the cases'
    roots and install directories. Daemon debt is reported; it does not fail the run."""
    run_id = args.run_id or f"smoke-{os.getpid()}-{time.time_ns()}"
    base = args.state_base / short_token(run_id)
    template = json.loads(Path(args.case).read_text(encoding="utf-8")) if args.case else None
    session = open_session({"binary": args.binary, "run_id": run_id, **getattr(args, "session_extra", {})})
    started = time.monotonic()

    roots = [base / f"{index:06d}"[-6:] for index in range(args.cases)]

    def one(index: int) -> Dict[str, Any]:
        case = noop_case(index) if template is None else {**template, "id": f"{template['id']}-{index}"}
        ctx = {"case_id": f"{case['suite']}/{case['id']}", "key": str(index), "state_root": str(roots[index])}
        return session.run_case(case, ctx)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(one, range(args.cases)))
    counts: Dict[str, int] = {}
    for result in results:
        counts[result["status"]] = counts.get(result["status"], 0) + 1
    marked = sorted(f"{p.pid} {marker}" for marker, procs in scan_markers().items()
                    if marker.startswith(f"{base}/") for p in procs)
    pgrep = subprocess.run(["pgrep", "-f", str(base)], check=False, stdout=subprocess.PIPE, text=True).stdout.split()
    leftover_roots = glob.glob(str(base / "*"))
    leftover_installs = [str(CasePaths(root).install_dir) for root in roots if CasePaths(root).install_dir.exists()]
    debt = [r for r in results if r.get("daemon_debt")]
    report = {
        "binary": session.binary, "sha": session.sha,
        "cases": args.cases, "jobs": args.jobs, "seconds": round(time.monotonic() - started, 1), "counts": counts,
        "marked_processes_left": marked, "pgrep_left": pgrep, "state_roots_left": leftover_roots,
        "install_dirs_left": leftover_installs,
        "failures": [r["message"][:300] for r in results if r["status"] != "Pass"][:5],
        "daemon_debt_cases": len(debt), "daemon_debt": [r["daemon_debt"][0][:300] for r in debt][:3],
    }
    print(json.dumps(report, indent=1, sort_keys=True))
    shutil.rmtree(base, ignore_errors=True)
    ok = (counts.get("Pass", 0) == args.cases and not marked and not pgrep and not leftover_roots
          and not leftover_installs)
    return 0 if ok else 1


# ------------------------------------------------------------------------------- the facet's self test


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

    def facet_errors(self, facet: Mapping[str, Any]) -> list:
        """The schema check on the example snapshot with this facet as its daemon facet.

        check_snapshot_schema.py's validator, not normalize.py's: at this base normalize.py refuses the
        schema's x-oracle-decimal, x-oracle-open-keys and x-oracle-id-unpatterned keywords.
        """
        snapshot = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        snapshot["facets"]["daemon"] = facet
        return check_snapshot_schema.check_snapshot(self.schema, snapshot, "facet")

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

    def test_every_receipt_of_the_streams_suite_is_its_operations_reply_kind(self) -> None:
        receipts = set()
        for path in sorted((REPO / "tests" / "oracle" / "corpus" / "streams").glob("*-*.json")):
            for step in json.loads(path.read_text(encoding="utf-8"))["steps"]:
                receipt = (step.get("expect") or {}).get("receipt")
                if receipt is not None:
                    self.assertEqual(receipt_kind(operations_spec()[step["args"]["method"]]), receipt, path.name)
                    receipts.add(receipt)
        self.assertLessEqual({"mutation_result", "stream_opened", "view_attachment_stream_opened",
                              "request_cancel_result", "empty_result"}, receipts)


class _ArmReads:
    """`identify` and `oracle-state` replies by command."""

    def __init__(self, identify: Mapping[str, Any], state: Mapping[str, Any]):
        self.replies = {IDENTIFY: identify, ORACLE_STATE: state}

    def command(self, cmd: str) -> Mapping[str, Any]:
        return self.replies[cmd]

    def operation(self, operation: str, params: Mapping[str, Any]) -> Any:
        raise AssertionError(f"no resource read is needed for the arms ({operation})")

    def __enter__(self) -> "_ArmReads":
        return self

    def __exit__(self, *_: object) -> None:
        pass


class _StubDaemon:
    """capture_wire_fixtures.Daemon as arms_check uses it: env, start, socket, stop."""

    def __init__(self, binary: Path, root: Path):
        self.env: Dict[str, str] = {}
        self.socket = str(root / "daemon.sock")
        self.started = self.stopped = False

    def start(self) -> None:
        self.started = True

    def stop(self) -> None:
        self.stopped = True


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
            self.assertEqual(plan.daemon_environment(), {self.switches.DAEMON_SWITCHES_ENV: f"holder={arm}"})
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
            code = arms_check(Path("/nonexistent/cmux-tui"), {"ghost": "new"}, self.roots, None)
        self.assertEqual(code, 2)
        self.assertIn("unknown switch: ghost", err.getvalue())

    def run_arms(self, reads: "_ArmReads", arm: str = "new") -> "tuple[int, Dict[str, Any], _StubDaemon]":
        import io
        import tempfile
        from contextlib import redirect_stdout

        daemons = []

        def make(binary: Path, root: Path) -> _StubDaemon:
            daemons.append(_StubDaemon(binary, root))
            return daemons[-1]

        with tempfile.TemporaryDirectory() as tmp:
            receipt = Path(tmp) / "arms.json"
            with redirect_stdout(io.StringIO()):
                code = arms_check(Path(sys.executable), {"holder": arm}, self.roots, receipt, make_daemon=make,
                                  open_reads=lambda path: reads)
            return code, json.loads(receipt.read_text(encoding="utf-8")), daemons[0]

    def test_arms_check_writes_the_applied_receipt(self) -> None:
        code, record, daemon = self.run_arms(_ArmReads(_identify(switches={"holder": "new"}), _state({"holder": "new"})))
        self.assertEqual(code, 0)
        self.assertEqual(record["verdict"], "applied")
        self.assertEqual(record["readback"], {"holder": "new"})
        self.assertEqual(daemon.env, {self.switches.DAEMON_SWITCHES_ENV: "holder=new"},
                         "a daemon started directly gets the raw name")
        self.assertTrue(daemon.started and daemon.stopped)

    def test_arms_check_tells_a_failed_readback_from_a_wrong_arm(self) -> None:
        no_switches = {"ok": True, "data": {k: v for k, v in EXTRAS_REPLY.items() if k != "switches"}}
        code, record, daemon = self.run_arms(_ArmReads(_identify(), no_switches))
        self.assertEqual(code, 3)
        self.assertEqual(record["verdict"], "readback-failed")
        self.assertIn("oracle-state gave no switches", record["problems"][0])
        self.assertTrue(daemon.stopped)
        code, record, _ = self.run_arms(_ArmReads(_identify(), _state({"holder": "old"})))
        self.assertEqual((code, record["verdict"]), (1, "arm-not-applied"))


def live_check(binary: Path, *, write: bool) -> int:
    """Run capture_wire_fixtures.py's op script on a hermetic daemon and compare the facet's oracle-state
    part with LIVE_EXPECTED. The session and settings are checked against the schema, not pinned: their
    ids and times are random until task 185's seeded ids and virtual clock. The expected panic log path
    is the Linux XDG state path, so this is a VM check."""
    import capture_wire_fixtures  # sibling of this file

    root = Path(tempfile.mkdtemp(prefix="oracle-021-", dir="/tmp"))
    daemon = capture_wire_fixtures.Daemon(binary.resolve(), root)
    try:
        daemon.start()
        capture_wire_fixtures.make_state(daemon)
        with SdkReads(daemon.socket) as reads:
            facet = capture_daemon_facet(reads)
    finally:
        daemon.stop()
        shutil.rmtree(root, ignore_errors=True)
    snapshot = json.loads(EXAMPLE.read_text(encoding="utf-8"))
    snapshot["facets"]["daemon"] = facet
    problems = check_snapshot_schema.check_snapshot(load_schema(), snapshot, "live facet")
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


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--selftest", action="store_true", help="run the offline facet self tests")
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("case-worker", help="internal: one case from a JSON payload on stdin (DaemonSession)")
    for name in ("run-case", "smoke"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--binary", required=True, help="the cmux-tui to run")
        cmd.add_argument("--snapshot-schema", help="the snapshot schema (default: normalize.py's)")
        cmd.add_argument("--state-base", type=Path, default=DEFAULT_STATE_BASE)
        cmd.add_argument("--run-id")
        cmd.add_argument("--isolation", choices=hermetic_env.ISOLATION_MODES, default="netns",
                         help="netns: unshare -rn, refuse a host without it (default); auto: netns when the host "
                              "allows it; none: no namespace (each result's environment says so)")
        if name == "run-case":
            cmd.add_argument("case", help="a case-v1 JSON file")
            cmd.add_argument("--ref", help="the SHA under test (meta.sha)")
            cmd.add_argument("--trace", help="write the case's cmux.oracle.trace/v1 document here (raw checkpoints "
                                             "and I9's restore previews, for invariants.py check)")
        else:
            cmd.add_argument("--cases", type=int, default=300)
            cmd.add_argument("--jobs", type=int, default=300)
            cmd.add_argument("--case", help="run N copies of this case-v1 file instead of no-op cases")
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
    if args.command == "case-worker":
        return case_worker()
    if args.command == "arms":
        switches = _sibling("switches")
        try:
            requested = switches.parse_requests(args.switch)
        except switches.UsageError as error:
            parser.error(str(error))
        roots = switches.Roots() if args.registry is None else switches.Roots(registry=args.registry.resolve())
        return arms_check(args.cmux, requested, roots, args.receipt)
    if args.command == "facet":
        with SdkReads(args.socket) as reads:
            value = capture_daemon_facet(reads)
        print(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
        return 0
    if args.command == "live-check":
        return live_check(args.cmux, write=args.write)
    if args.command is None:
        parser.print_usage(sys.stderr)
        return 2
    args.session_extra = {"isolation": args.isolation}
    if args.snapshot_schema:
        args.session_extra["snapshot_schema"] = args.snapshot_schema
    if getattr(args, "trace", None):
        args.session_extra["trace"] = True
    try:
        return cmd_run_case(args) if args.command == "run-case" else cmd_smoke(args)
    except ValueError as error:
        print(f"driver_daemon.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
