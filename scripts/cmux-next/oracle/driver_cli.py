#!/usr/bin/env python3
"""The oracle's CLI driver: `cli` steps through the shipped `cmux` binary, in VM and fleet modes.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3D and task 048. Stdlib plus the sibling
drivers, Python 3.9+, safe under `python3 -I`. It implements the driver protocol of oracle.py
(`open_session`, `session.run_case`, `session.close`) for `--product cli`.

Two modes, chosen by the session context oracle.py gives:
- VM (`--binary`): the cmux-tui that linux_run.sh built at the run SHA, run as `cmux` (argv[0], as the app
  bundles it in Resources/bin/cmux). Its build receipt (driver_daemon.BUILD_RECEIPT beside the binary) must
  name the run SHA: a binary without one, or built at another SHA, is refused. Every case is
  driver_daemon.py's case (p15-oracle-023): its own state root, hermetic environment, `cmux-tui --headless`
  daemon, subreaper worker and I6 proof. `cli` steps run the binary with that case's environment, so
  `CMUX_TUI_SOCKET` names the case's daemon and nothing else is reachable. A cli step ends when the daemon
  has dropped the call's own connection from `session.clients` (CliCaseRun), so its checkpoints never race
  that close; resource.call, kill, restart, settle and snapshot steps are the daemon driver's.
- Fleet (`--tag`): `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh ARGV`, the one supported way to reach a
  tagged build (repo CLAUDE.md). Only `cli` and `snapshot` steps without `waitFor` or `readOnly`: the app's
  facets, settling and waits are driver_app.py's (p15-oracle-047), so every other facet of a fleet snapshot
  is not comparable and a step that needs more is a Crash that names driver_app.py.
Neither mode ever runs `/tmp/cmux-cli` (a stale untagged copy that reaches whatever app is running):
`CliBinary` refuses that path, and fleet mode resolves the CLI only through cmux-debug-cli.sh. Neither
mode applies switch arms yet (p15-oracle-049), so both refuse a session with switches or a non-default arm.

A `cli` step's receipt (invariant I1) is the `cli` facet of its settled checkpoint (snapshot-v1
facets.cli): `{exit, stdout, error?}`, with stdout parsed as one JSON value, JSON lines as a list, or the
text, and the case's own session name as the fixture's (`oracle`). normalize.py canonicalizes it with the
case's other checkpoints, so ids get the labels the daemon facet gives them, an id-keyed map is ordered by
its contents, and times and volatile keys follow the schema's x-oracle-open-keys; oracle.py hashes and
diffs it like any facet. Exit 0 is outcome `ok`; any other exit is outcome `error` with the typed code of
the CLI's JSON error (`--json` writes `{code, message, details, retryable}` to stderr: cli/wire.rs
print_local_error), or `cli.failed` when stderr has none. `expect.receipt: cli.exit` asserts a receipt
exists; `expect.result` is compared exactly with the canonical facet after the case. `$step:` references
read the raw stdout, so a later step can pass an id an earlier `cmux ... --json` printed.

Chrome reference (chromium/src): base/test/launcher/test_launcher.cc runs each test in a child process and
keeps its exit code and output as the result (TestResult::output_snippet, written by
base/test/launcher/test_results_tracker.cc); here the child is the shipped `cmux` binary and the result is
its exit code and stdout, compared as part of the checkpoint.

Usage:
  driver_cli.py run-case --binary CMUX_TUI CASE.json [--ref SHA]   one VM case, its result JSON
  driver_cli.py run-case --tag TAG CASE.json                      one fleet case against a tagged app
  driver_cli.py smoke --binary CMUX_TUI [--repeat 2] [--jobs 100] the 50 daemon CLI cases, twice each (VM)
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Set, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
DEBUG_CLI = REPO / "scripts" / "cmux-debug-cli.sh"

if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import normalize  # noqa: E402 - sibling of this file

try:
    import driver_daemon  # noqa: E402 - the daemon driver's case runner
    from driver_daemon import (  # noqa: E402
        BUILD_RECEIPT,
        DEFAULT_STATE_BASE,
        FACETS,
        MISSING,
        REQUEST_S,
        SELECTORS,
        SESSION_NAME,
        CaseError,
        CaseRun,
        CmuxError,
        DaemonSession,
        SdkTimeout,
        build_receipt_sha,
        host_meta,
        load_snapshot_schema,
        not_comparable,
        remove_empty_dir,
        resolve_pointer,
        resolve_refs,
        short_token,
    )
    if not hasattr(DaemonSession, "worker_script"):
        raise ImportError("DaemonSession.worker_script is missing")
    # The repo's Python SDK, on sys.path once driver_daemon.py is imported.
    from cmux.errors import CmuxConnectionError, CommandError  # noqa: E402
    from cmux.transport import JsonLineConnection  # noqa: E402
except ImportError as _error:  # pragma: no cover - a checkout from before task 023's case runner
    raise ImportError("driver_cli.py runs its VM cases on driver_daemon.py's case runner (p15-oracle-023: "
                      "DaemonSession.worker_script, case_worker(case_class), build_receipt_sha), which this "
                      f"checkout lacks: {_error}") from _error

PRODUCT = "cli"
CLI_FACET = "cli"
CLI_ARGV0 = "cmux"
# The stale copy agents used to drop in /tmp: it reaches whichever app answers, never the case's daemon.
FORBIDDEN_CLI = Path("/tmp/cmux-cli")
RECEIPT_KIND = "cli.exit"
FALLBACK_ERROR = "cli.failed"
ERROR_CODE = re.compile(r"^[a-z][a-z_]*(\.[a-z][a-z_]*)+$")
SHA = re.compile(r"^[0-9a-f]{40}$")
UNKNOWN_SHA = "0" * 40
# Seconds a `cmux` call may take before its step is a Timeout; a Slow expectation multiplies it.
CLI_S = 30.0
GIT_S = 30.0
FLEET_OPS = frozenset({"cli", "snapshot"})
APP_DRIVER = "driver_app.py (p15-oracle-047)"
DEFAULT_ARMS = (None, "default")
# The daemon's event when a control client's connection is gone (cmux-tui server/disconnect.rs).
CLIENT_DETACHED = "client-detached"
SUBSCRIPTION_OVERFLOW = "overflow"


class BuildMismatch(ValueError):
    """The binary is not the build of the run SHA (no build receipt, another SHA, or a ref that names none)."""


def refuse_switch_arms(session_ctx: Mapping[str, Any]) -> None:
    """Neither mode applies a switch arm yet, so an arm run would compare two runs of the default build."""
    if session_ctx.get("switches") or session_ctx.get("arm") not in DEFAULT_ARMS:
        raise ValueError(f"switch arms (arm {session_ctx.get('arm')!r}, switches {session_ctx.get('switches')!r}) "
                         "reach the daemon and the app in p15-oracle-049; the cli driver runs the default arm only")


# ---------------------------------------------------------------------------------------------------------
# Running the CLI


@dataclass(frozen=True)
class CliOutput:
    exit: int
    stdout: bytes
    stderr: bytes


class CliTimeout(Exception):
    """The CLI ran over its bound; it was killed."""


class CliRunner:
    """Runs one `cmux ARGV` and returns its output. `VmCli` and `FleetCli` are the two modes."""

    def run(self, argv: Sequence[str], stdin: Optional[str], timeout: float) -> CliOutput:
        raise NotImplementedError

    def describe(self) -> str:
        raise NotImplementedError


def forbidden_cli(path: Path) -> bool:
    """True for /tmp/cmux-cli or anything under or beside it with that name (also through symlinks)."""
    candidates = {Path(os.path.abspath(path)), Path(os.path.realpath(path))}
    banned = {FORBIDDEN_CLI, Path(os.path.realpath(FORBIDDEN_CLI))}
    return any(c == b or b in c.parents or c.name == FORBIDDEN_CLI.name for c in candidates for b in banned)


@dataclass(frozen=True)
class CliBinary:
    """The cmux-tui binary a VM run executes as `cmux`."""

    path: Path

    def __post_init__(self) -> None:
        if forbidden_cli(self.path):
            raise ValueError(f"{self.path} is the untagged /tmp/cmux-cli; the oracle runs the cargo-built cmux of "
                             f"the run SHA (VM) or CMUX_TAG=<tag> scripts/cmux-debug-cli.sh (fleet)")
        if not os.access(str(self.path), os.X_OK):
            raise ValueError(f"{self.path} is not an executable")


def spawn(argv: Sequence[str], *, executable: Optional[str], env: Mapping[str, str], cwd: Optional[str],
          stdin: Optional[str], timeout: float) -> CliOutput:
    """One process to its exit; over `timeout` it is killed and CliTimeout raised."""
    proc = subprocess.Popen(list(argv), executable=executable, env=dict(env), cwd=cwd,
                            stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        out, err = proc.communicate(stdin.encode("utf-8") if stdin is not None else None, timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        raise CliTimeout(f"cmux {' '.join(argv[1:])[:200]} ran over {timeout:.0f} s") from None
    return CliOutput(proc.returncode, out, err)


class VmCli(CliRunner):
    """The run SHA's cmux-tui as `cmux`, with the case's whole environment (its socket, home, XDG dirs)."""

    def __init__(self, binary: CliBinary, env: Mapping[str, str], cwd: str):
        self.binary = binary
        self.env = dict(env)
        self.cwd = cwd

    def run(self, argv: Sequence[str], stdin: Optional[str], timeout: float) -> CliOutput:
        return spawn([CLI_ARGV0, *argv], executable=str(self.binary.path), env=self.env, cwd=self.cwd,
                     stdin=stdin, timeout=timeout)

    def describe(self) -> str:
        return f"{self.binary.path} (as {CLI_ARGV0})"


def fleet_environment(base: Mapping[str, str], tag: str) -> Dict[str, str]:
    """The caller's environment with CMUX_TAG set; cmux-debug-cli.sh unsets every route a terminal leaks."""
    env = {k: v for k, v in base.items() if k != "CMUX_TAG"}
    env["CMUX_TAG"] = tag
    return env


class FleetCli(CliRunner):
    """`CMUX_TAG=<tag> scripts/cmux-debug-cli.sh ARGV`: the tagged build's own bundled CLI and socket."""

    def __init__(self, tag: str, env: Optional[Mapping[str, str]] = None, script: Path = DEBUG_CLI):
        if not re.fullmatch(r"[A-Za-z0-9._-]+", tag or ""):
            raise ValueError(f"--tag {tag!r} is not a cmux tag (letters, digits, '.', '_', '-')")
        self.tag = tag
        self.script = script
        self.env = fleet_environment(os.environ if env is None else env, tag)

    def run(self, argv: Sequence[str], stdin: Optional[str], timeout: float) -> CliOutput:
        return spawn(["bash", str(self.script), *argv], executable=None, env=self.env, cwd=str(REPO),
                     stdin=stdin, timeout=timeout)

    def describe(self) -> str:
        return f"CMUX_TAG={self.tag} {self.script}"


# ---------------------------------------------------------------------------------------------------------
# The run SHA


def resolve_ref(ref: str, repo: Path = REPO) -> str:
    """The full SHA of `ref` in this checkout (a full SHA as is); BuildMismatch when it names no commit."""
    if SHA.fullmatch(ref):
        return ref
    if ref.startswith("-"):
        raise BuildMismatch(f"--ref {ref} is not a ref")
    try:
        done = subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=GIT_S,
                              check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BuildMismatch(f"--ref {ref}: git rev-parse failed: {error}") from None
    sha = done.stdout.strip()
    if done.returncode != 0 or not SHA.fullmatch(sha):
        raise BuildMismatch(f"--ref {ref} names no commit in {repo}")
    return sha


def run_sha(binary: Path, ref: Optional[str], resolve: Callable[[str], str] = resolve_ref) -> str:
    """The SHA the binary's build receipt names, after checking that it is the run SHA `ref` (when given)."""
    built = build_receipt_sha(str(binary))
    if built is None:
        raise BuildMismatch(f"--binary {binary} has no build receipt ({BUILD_RECEIPT} beside it with a full sha): "
                            "the oracle runs the cmux-tui `linux_run.sh build REF` built at the run SHA")
    if ref:
        wanted = resolve(ref)
        if wanted != built:
            raise BuildMismatch(f"--binary {binary} was built at {built}, not at the run SHA {wanted} (--ref {ref})")
    return built


# ---------------------------------------------------------------------------------------------------------
# Receipts: exit code and stdout, as the cli facet


def parse_stdout(raw: bytes) -> Any:
    """One JSON value, JSON lines as a list, or the text (also for invalid UTF-8, replaced)."""
    text = raw.decode("utf-8", "replace")
    stripped = text.strip()
    if not stripped:
        return ""
    try:
        return normalize.parse_json(stripped)
    except normalize.OracleError:
        pass
    lines = [line for line in stripped.splitlines() if line.strip()]
    if len(lines) > 1:
        try:
            return [normalize.parse_json(line) for line in lines]
        except normalize.OracleError:
            pass
    return text


def error_code(stderr: bytes) -> str:
    """The typed code of the CLI's JSON error on stderr (the last line that is one), else cli.failed."""
    for line in reversed(stderr.decode("utf-8", "replace").splitlines()):
        try:
            value = normalize.parse_json(line.strip())
        except normalize.OracleError:
            continue
        if isinstance(value, dict) and isinstance(value.get("error"), dict):
            value = value["error"]
        code = value.get("code") if isinstance(value, dict) else None
        if isinstance(code, str) and ERROR_CODE.fullmatch(code):
            return code
    return FALLBACK_ERROR


def stderr_tail(stderr: bytes) -> str:
    """The last line of stderr, for a Failure message (messages are not hashed)."""
    lines = stderr.decode("utf-8", "replace").strip().splitlines()
    return lines[-1][:300] if lines else ""


def rename(value: Any, names: Mapping[str, str]) -> Any:
    """`value` with each name in `names` (the case's own session name) replaced, in strings and keys."""
    if not names:
        return value
    search = re.compile(r"(?<![A-Za-z0-9])(" + "|".join(map(re.escape, names)) + r")(?![A-Za-z0-9])")

    def walk(item: Any) -> Any:
        if isinstance(item, str):
            return search.sub(lambda match: names[match.group(1)], item)
        if isinstance(item, list):
            return [walk(member) for member in item]
        if isinstance(item, dict):
            return {walk(key): walk(member) for key, member in item.items()}
        return item

    return walk(value)


def receipt_of(output: CliOutput, names: Mapping[str, str]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    """(the cli facet, the raw reply that `$step:` references read)."""
    raw = parse_stdout(output.stdout)
    receipt: Dict[str, Any] = {"exit": output.exit, "stdout": rename(raw, names)}
    reply: Dict[str, Any] = {"exit": output.exit, "stdout": raw}
    if output.exit != 0:
        receipt["error"] = reply["error"] = error_code(output.stderr)
    return receipt, reply


def outcome_of(receipt: Mapping[str, Any]) -> Tuple[str, Any]:
    return ("ok", receipt) if receipt["exit"] == 0 else ("error", receipt["error"])


def check_outcome(step: Mapping[str, Any], outcome: Tuple[str, Any], receipt: Mapping[str, Any],
                  stderr: str) -> None:
    """expect for a cli step at its turn: outcome, typed error, `cli.exit` receipt. `expect.result` needs the
    canonical facet, so check_results compares it after the case."""
    expect = step.get("expect")
    if not expect:
        return
    step_id = step["id"]
    kind, detail = outcome
    if expect["outcome"] != kind or (kind == "error" and detail != expect.get("error")):
        got = f"error {detail} (exit {receipt['exit']}: {stderr})" if kind == "error" else "ok"
        want = expect["outcome"] + (f" {expect['error']}" if "error" in expect else "")
        raise CaseError("Failure", f"expected {want}, got {got}", step_id)
    kind_wanted = expect.get("receipt")
    if kind == "ok" and kind_wanted is not None and kind_wanted != RECEIPT_KIND:
        raise CaseError("Crash", f"receipt kind {kind_wanted}: a cli step's receipt is {RECEIPT_KIND}", step_id)


def check_cli_step(step: Mapping[str, Any]) -> None:
    """A cli step's receipt is its settled checkpoint's cli facet, so the step must keep that checkpoint."""
    if "settled" not in (step.get("checkpoint") or ["settled"]):
        raise CaseError("Crash", "a cli step's receipt is the cli facet of its settled checkpoint; its checkpoint "
                                 "list needs settled", step["id"])


def check_results(case: Mapping[str, Any], checkpoints: Sequence[Mapping[str, Any]]) -> Optional[CaseError]:
    """`expect.result` of each cli step against the canonical cli facet of its settled checkpoint."""
    facets = {cp["step"]: cp["snapshot"]["facets"].get(CLI_FACET) for cp in checkpoints
              if cp["checkpoint"] == "settled"}
    for step in case.get("steps") or ():
        expect = step.get("expect") or {}
        if step.get("op") != "cli" or "result" not in expect:
            continue
        got = facets.get(step["id"])
        if got is None:
            return CaseError("Crash", "expect.result: the step has no cli facet", step["id"])
        if normalize.canonical_json(got) != normalize.canonical_json(expect["result"]):
            return CaseError("Failure", f"result differs: {normalize.canonical_json(got)[:300]}", step["id"])
    return None


def apply_results(case: Mapping[str, Any], result: Dict[str, Any]) -> Dict[str, Any]:
    if result["status"] == "Pass":
        failure = check_results(case, result["checkpoints"])
        if failure is not None:
            result.update(status=failure.status, message=failure.message, step=failure.step)
    return result


@dataclass
class CliSteps:
    """The cli step runner both modes share: one runner, the case's receipts by step id."""

    runner: CliRunner
    names: Mapping[str, str] = field(default_factory=dict)
    scale: float = 1.0
    receipts: Dict[str, Dict[str, Any]] = field(default_factory=dict)

    def run(self, step: Mapping[str, Any], replies: Dict[str, Any]) -> Tuple[str, Any]:
        step_id = step["id"]
        try:
            args = resolve_refs(step["args"], replies)
        except CaseError as error:
            raise CaseError(error.status, error.message, error.step or step_id) from None
        argv = [a if isinstance(a, str) else normalize.canonical_json(a) for a in args["argv"]]
        stdin = args.get("stdin")
        try:
            output = self.runner.run(argv, stdin if isinstance(stdin, str) else None, CLI_S * self.scale)
        except CliTimeout as error:
            raise CaseError("Timeout", str(error), step_id) from None
        except OSError as error:
            raise CaseError("Crash", f"cannot run {self.runner.describe()}: {error}", step_id) from None
        receipt, reply = receipt_of(output, self.names)
        replies[step_id] = reply
        self.receipts[step_id] = receipt
        outcome = outcome_of(receipt)
        check_outcome(step, outcome, receipt, stderr_tail(output.stderr))
        return outcome

    def facet(self, step: str) -> Dict[str, Any]:
        receipt = self.receipts.get(step)
        if receipt is None:
            return not_comparable("the cli facet is the receipt of a cli step", "p15-oracle-048")
        return receipt


def with_cli_facet(names: Sequence[str], checkpoint: str, step: str, steps: CliSteps) -> Tuple[str, ...]:
    """The facets of a checkpoint: the cli facet joins the settled checkpoint of a cli step."""
    names = tuple(names)
    if checkpoint == "settled" and step in steps.receipts and CLI_FACET not in names:
        names += (CLI_FACET,)
    return names


# ---------------------------------------------------------------------------------------------------------
# VM mode: driver_daemon.py's case with a cli op


class ClientEvents:
    """The case daemon's `subscribe` stream read as raw JSON lines: only the event name matters here, so the
    fields a newer daemon adds to an event never fail the read (the SDK's typed stream refuses them)."""

    REQUEST_ID = 1

    def __init__(self, socket_path: str, timeout: float):
        self.conn = JsonLineConnection(socket_path, timeout)
        try:
            self.conn.send({"id": self.REQUEST_ID, "cmd": "subscribe"})
            while True:
                frame = self.conn.recv()
                if "event" not in frame and frame.get("id") == self.REQUEST_ID:
                    break
            if frame.get("ok") is not True:
                raise CommandError(f"subscribe refused: {frame.get('error')}", frame)
        except BaseException:
            self.conn.close()
            raise

    def next_detach(self, deadline: float) -> bool:
        """True at the next client-detached event, False at the deadline; CmuxError when the stream ends."""
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            self.conn.set_timeout(remaining)
            try:
                event = self.conn.recv().get("event")
            except SdkTimeout:
                return False
            if event == CLIENT_DETACHED:
                return True
            if event == SUBSCRIPTION_OVERFLOW:
                raise CmuxConnectionError("the client-event subscription overflowed")

    def close(self) -> None:
        self.conn.close()


class CliCaseRun(CaseRun):
    """driver_daemon.py's case (hermetic daemon, steps, I6 teardown) plus `cli` steps.

    A `cmux` call is a control client of the case daemon, which drops it from `session.clients` when it
    handles the connection's close, after the process has exited. So a cli step ends when every client the
    call added has left: woken by the daemon's `client-detached` events on one subscription that lives for
    the case (Chrome learns that a child's channel is gone the same way, from the channel's own error:
    content/common/child_process_host_impl.cc ChildProcessHostImpl::OnChannelError), never by a sleep."""

    def __init__(self, binary: str, sha: str, schema: normalize.Schema, case: Mapping[str, Any],
                 ctx: Mapping[str, Any], session_ctx: Mapping[str, Any], isolation: Any):
        super().__init__(binary, sha, schema, case, ctx, session_ctx, isolation)
        runner = VmCli(CliBinary(Path(binary)), self.case_env.env, str(self.paths.home))
        self.cli = CliSteps(runner, {self.paths.session: SESSION_NAME}, self.scale)
        self.ops["cli"] = self.op_cli
        self.client_events: Any = None
        self.client_events_start = -1

    def run_step(self, index: int, step: Mapping[str, Any]) -> None:
        if step["op"] == "cli":
            check_cli_step(step)
        super().run_step(index, step)

    def op_cli(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        step_id = step["id"]
        if not self.daemon.running:
            return self.cli.run(step, self.state.replies)
        self.watch_clients(step_id)
        known = self.client_ids(step_id)
        before = self.daemon_facet(step_id) if step.get("readOnly") else None
        outcome = self.cli.run(step, self.state.replies)
        self.await_departure(known, step_id)
        if before is not None:
            self.check_read_only(index, step_id, before)
        return outcome

    # -- the call's own connection

    def watch_clients(self, step: str) -> Set[str]:
        """The case's client-event subscription, opened when there is none for the running daemon (first cli
        step, a restart, an overflow); the client ids it added, which are known ones from then on."""
        if self.client_events is not None and self.client_events_start == self.daemon.starts:
            return set()
        self.close_client_events()
        before = self.client_ids(step)
        try:
            self.client_events = ClientEvents(str(self.paths.socket), REQUEST_S * self.scale)
        except CmuxError as error:
            raise self.sdk_failure(error, step, "subscribe") from None
        self.client_events_start = self.daemon.starts
        return self.client_ids(step) - before

    def close_client_events(self) -> None:
        if self.client_events is not None:
            self.client_events.close()
            self.client_events = None

    def client_ids(self, step: str) -> Set[str]:
        try:
            session = self.daemon.request("session.snapshot", SELECTORS, None, REQUEST_S * self.scale)
        except CmuxError as error:
            raise self.sdk_failure(error, step, "session.snapshot") from None
        clients = session.get("clients") if isinstance(session, dict) else None
        return {c["id"] for c in clients or () if isinstance(c, dict) and isinstance(c.get("id"), str)}

    def await_departure(self, known: Set[str], step: str) -> None:
        bound = REQUEST_S * self.scale
        deadline = time.monotonic() + bound
        while self.daemon.running:
            left = self.client_ids(step) - known
            if not left:
                return
            try:
                woke = self.client_events.next_detach(deadline)
            except CmuxError:
                # The subscription ended (overflow, or the daemon went away): a new one, then a fresh read.
                self.client_events = None
                if self.daemon.running:
                    known = known | self.watch_clients(step)
                continue
            if not woke:
                raise CaseError("Timeout", f"the cmux call's {len(left)} connection(s) stayed in session.clients "
                                           f"for {bound:.0f} s after it exited", step)

    def shutdown(self) -> List[str]:
        self.close_client_events()
        return super().shutdown()

    def check_expect(self, step: Mapping[str, Any], outcome: Tuple[str, Any]) -> None:
        # op_cli checked a cli step's expect against its receipt; check_results compares expect.result.
        if step["op"] != "cli":
            super().check_expect(step, outcome)

    def capture(self, index: int, step: str, checkpoint: str, names: Sequence[str]) -> None:
        super().capture(index, step, checkpoint, with_cli_facet(names, checkpoint, step, self.cli))

    def facets(self, names: Sequence[str], step: str) -> Dict[str, Any]:
        out = super().facets([name for name in names if name != CLI_FACET], step)
        if CLI_FACET in names:
            out[CLI_FACET] = self.cli.facet(step)
        return out

    def snapshot(self, index: int, checkpoint: str, facets: Dict[str, Any]) -> Dict[str, Any]:
        value = super().snapshot(index, checkpoint, facets)
        value["meta"]["product"] = PRODUCT
        return value

    def run(self) -> Dict[str, Any]:
        return apply_results(self.case, super().run())


class CliSession(DaemonSession):
    """The VM session: driver_daemon.py's session whose case workers run CliCaseRun (this file's case-worker)."""

    worker_script = Path(__file__).resolve()

    def __init__(self, session_ctx: Mapping[str, Any], resolve: Callable[[str], str] = resolve_ref):
        refuse_switch_arms(session_ctx)
        binary = CliBinary(Path(str(session_ctx.get("binary") or "")))
        ref = session_ctx.get("ref")
        sha = run_sha(binary.path, ref if isinstance(ref, str) else None, resolve)
        super().__init__({**session_ctx, "ref": sha})


def case_worker() -> int:
    """`case-worker`: one CliCaseRun from the JSON payload on stdin (driver_daemon.case_worker's subreaper
    worker, so every process the case starts, the cmux calls included, stays in its tree: I6)."""
    return driver_daemon.case_worker(CliCaseRun)


# ---------------------------------------------------------------------------------------------------------
# Fleet mode: a tagged app on a mini


class FleetSession:
    """cli and snapshot steps against `CMUX_TAG=<tag>`'s running app. Launching, resetting, settling, waiting
    and the app's facets are driver_app.py's (p15-oracle-047); this session never launches anything."""

    def __init__(self, session_ctx: Mapping[str, Any], runner: Optional[CliRunner] = None,
                 resolve: Callable[[str], str] = resolve_ref):
        refuse_switch_arms(session_ctx)
        schema_path = str(session_ctx.get("snapshot_schema") or normalize.DEFAULT_SCHEMA)
        schema, refusal = load_snapshot_schema(schema_path)
        if schema is None:
            raise ValueError(f"normalize.py refuses the snapshot schema: {refusal}")
        self.schema = schema
        self.runner = runner or FleetCli(str(session_ctx.get("tag") or ""))
        ref = session_ctx.get("ref")
        self.sha = resolve(ref) if isinstance(ref, str) and ref else UNKNOWN_SHA
        self.home = os.environ.get("HOME", "")
        self.host = host_meta()

    def context(self) -> normalize.Context:
        return normalize.Context(home=(self.home,) if self.home.rstrip("/") else ())

    @staticmethod
    def check_step(step: Mapping[str, Any]) -> None:
        if step["op"] not in FLEET_OPS:
            raise CaseError("Crash", f"op {step['op']} runs in {APP_DRIVER}, not in the fleet CLI session", step["id"])
        for key in ("waitFor", "readOnly"):
            if step.get(key):
                raise CaseError("Crash", f"{key} reads the app's facets; it runs in {APP_DRIVER}, not in the fleet "
                                         f"CLI session", step["id"])
        if step["op"] == "cli":
            check_cli_step(step)

    def run_case(self, case: Dict[str, Any], case_ctx: Dict[str, Any]) -> Dict[str, Any]:
        case_id = case_ctx.get("case_id") or f"{case.get('suite')}/{case.get('id')}"
        scale = float(case_ctx.get("timeout_multiplier") or 1)
        steps = CliSteps(self.runner, {}, scale)
        replies: Dict[str, Any] = {}
        snapshots: List[Tuple[str, str, Dict[str, Any]]] = []
        status, message, at = "Pass", "", None
        try:
            for index, step in enumerate(case.get("steps") or ()):
                self.check_step(step)
                names = tuple((step.get("args") or {}).get("facets") or FACETS) if step["op"] == "snapshot" \
                    else ("daemon",)
                checkpoints = step.get("checkpoint") or ["settled"]
                if "before" in checkpoints:
                    snapshots.append((step["id"], "before", self.snapshot(case_id, index, "before", names, steps,
                                                                          step["id"])))
                if step["op"] == "cli":
                    steps.run(step, replies)
                if "settled" in checkpoints:
                    snapshots.append((step["id"], "settled", self.snapshot(case_id, index, "settled", names, steps,
                                                                           step["id"])))
        except CaseError as error:
            status, message, at = error.status, error.message, error.step
        result: Dict[str, Any] = {"status": status, "message": message, "checkpoints": []}
        if at:
            result["step"] = at
        if snapshots:
            try:
                canonical = normalize.canonicalize_case([s for _, _, s in snapshots], self.schema, self.context(),
                                                        [f"{step}/{cp}" for step, cp, _ in snapshots])
            except normalize.OracleError as error:
                result.update(status="Crash", message="; ".join(filter(None, [message, f"snapshot refused: {error}"])))
                return result
            result["checkpoints"] = [{"step": step, "checkpoint": cp, "snapshot": r.value}
                                     for (step, cp, _), r in zip(snapshots, canonical)]
        return apply_results(case, result)

    def snapshot(self, case_id: str, index: int, checkpoint: str, names: Sequence[str], steps: CliSteps,
                 step: str) -> Dict[str, Any]:
        names = with_cli_facet(names, checkpoint, step, steps)
        facets: Dict[str, Any] = {name: not_comparable(f"the fleet CLI session reads no app facet; {APP_DRIVER} "
                                                       f"captures them", "p15-oracle-047")
                                  for name in names if name != CLI_FACET}
        if CLI_FACET in names:
            facets[CLI_FACET] = steps.facet(step)
        return {
            "schema": "cmux.oracle.snapshot/v1",
            "meta": {"case": case_id, "step": index, "checkpoint": checkpoint, "product": PRODUCT, "sha": self.sha,
                     "host": self.host, "clock": "wall", "capturedAtMs": int(time.time() * 1000),
                     "facets": list(names)},
            "facets": facets,
        }

    def close(self) -> None:
        """The tagged app belongs to whoever launched it; nothing to end here."""


def open_session(session_ctx: Dict[str, Any]) -> Any:
    """VM mode with `binary`, fleet mode with `tag` (never both: one run measures one build)."""
    binary, tag = session_ctx.get("binary"), session_ctx.get("tag")
    if binary and tag:
        raise ValueError("--binary (VM) and --tag (fleet) are two modes; give one")
    if tag:
        return FleetSession(session_ctx)
    if binary:
        return CliSession(session_ctx)
    raise ValueError("the cli driver needs --binary (the cmux-tui linux_run.sh built at the run SHA) or --tag "
                     "(a tagged fleet build, run through scripts/cmux-debug-cli.sh)")


# ---------------------------------------------------------------------------------------------------------
# The VM test: 50 daemon CLI cases

# Each case runs on a fresh hermetic daemon. A step is (kind, argv[, checks]): `read` is readOnly (its daemon
# facet must not move), `mutate` targets the current session and expects a cli.exit receipt, `error:<code>`
# is readOnly and expects that typed error. `$W`, `$S`, `$P`, `$T` and `$R` stand for the workspace, screen,
# pane, terminal and room id the case's first step printed. `checks` are (pointer into the canonical cli facet, op, value)
# with op `==` or `len`: what the mutation before the read must have done. Left out until their output is
# stable: `client list` and `tab list` of a split workspace (both print in raw id order, random until
# p15-oracle-185 seeds ids), `daemon status` (the daemon's pid) and checklist items (`chk_` ids are not in the snapshot schema's x-oracle-id-patterns).
NO_SUCH = {kind: f"{prefix}_{'0' * 32}" for kind, prefix in (("ws", "ws"), ("pane", "pane"), ("tab", "tab"),
                                                                ("term", "term"))}
Check = Tuple[str, str, Any]
SmokeStep = Tuple[Any, ...]
MAKE_EMPTY: SmokeStep = ("mutate", ("workspace", "create", "--empty", "--name", "a"))
MAKE_TERMINAL: SmokeStep = ("mutate", ("workspace", "create", "--name", "a"))
ROOM: SmokeStep = ("mutate", ("room", "create", "--name", "r"))
NOTIFY: SmokeStep = ("mutate", ("notification", "create", "--title", "t", "--body", "b"))
SMOKE: Tuple[Tuple[str, Tuple[SmokeStep, ...]], ...] = (
    ("machine-list", (("read", ("machine", "list"), (("/stdout", "len", 1),)),)),
    ("machine-show", (("read", ("machine", "current", "show")),)),
    ("workspace-list", (("read", ("workspace", "list"), (("/stdout", "len", 0),)),)),
    ("screen-list", (("read", ("screen", "list")),)),
    ("pane-list", (("read", ("pane", "list")),)),
    ("tab-list", (("read", ("tab", "list")),)),
    ("terminal-list", (("read", ("terminal", "list"), (("/stdout", "len", 0),)),)),
    ("notification-list", (("read", ("notification", "list"), (("/stdout", "len", 0),)),)),
    ("agent-list", (("read", ("agent", "list")),)),
    ("room-list", (("read", ("room", "list"), (("/stdout", "len", 1), ("/stdout/0/id", "==", "default"))),)),
    ("closed-list", (("read", ("closed", "list"), (("/stdout", "len", 0),)),)),
    ("tab-group-list", (("read", ("tab", "group", "list")),)),
    ("screen-group-list", (("read", ("screen", "group", "list")),)),
    ("status-list-all", (("read", ("status", "list", "--all")),)),
    ("settings-needs-app", (("error:socket.no_app", ("settings", "list")),)),
    ("keybinding-needs-app", (("error:socket.no_app", ("keybinding", "list")),)),
    ("window-needs-app", (("error:socket.no_app", ("window", "list")),)),
    ("workspace-not-found", (("error:selector.not_found", ("workspace", NO_SUCH["ws"], "show")),)),
    ("pane-not-found", (("error:selector.not_found", ("pane", NO_SUCH["pane"], "show")),)),
    ("tab-not-found", (("error:selector.not_found", ("tab", NO_SUCH["tab"], "show")),)),
    ("terminal-not-found", (("error:selector.not_found", ("terminal", NO_SUCH["term"], "show")),)),
    ("bad-option", (("error:usage.invalid", ("workspace", "create", "--bogus")),)),
    ("unknown-scope", (("error:usage.invalid", ("session", "list")),)),
    ("create-empty-list", (MAKE_EMPTY, ("read", ("workspace", "list"),
                                        (("/stdout", "len", 1), ("/stdout/0/name", "==", "a"))))),
    ("create-terminal-list", (MAKE_TERMINAL, ("read", ("terminal", "list"), (("/stdout", "len", 1),)))),
    ("create-show", (MAKE_EMPTY, ("read", ("workspace", "$W", "show"), (("/stdout/name", "==", "a"),)))),
    ("create-rename", (MAKE_EMPTY, ("mutate", ("workspace", "$W", "rename", "b")),
                       ("read", ("workspace", "$W", "show"), (("/stdout/name", "==", "b"),)))),
    ("create-close", (MAKE_EMPTY, ("mutate", ("workspace", "$W", "close")),
                      ("read", ("workspace", "list"), (("/stdout", "len", 0),)))),
    ("create-move", (MAKE_EMPTY, ("mutate", ("workspace", "create", "--empty", "--name", "b")),
                     ("mutate", ("workspace", "$W", "move", "--index", "1")),
                     ("read", ("workspace", "$W", "show"), (("/stdout/index", "==", 1),)))),
    ("create-title", (MAKE_EMPTY, ("mutate", ("workspace", "$W", "update", "--title", "T")),
                      ("read", ("workspace", "$W", "show"), (("/stdout/extra/title", "==", "T"),)))),
    ("workspace-status", (MAKE_EMPTY, ("mutate", ("workspace", "$W", "status", "set", "build", "ok")),
                          ("read", ("workspace", "$W", "status", "list"),
                           (("/stdout/0/entries", "len", 1), ("/stdout/0/entries/0/key", "==", "build"),
                            ("/stdout/0/entries/0/text", "==", "ok"))))),
    ("workspace-log", (MAKE_EMPTY, ("mutate", ("workspace", "$W", "log", "append", "hello")),
                       ("read", ("workspace", "$W", "log", "list"),
                        (("/stdout", "len", 1), ("/stdout/0/text", "==", "hello"))))),
    ("workspace-color", (MAKE_EMPTY, ("mutate", ("workspace", "$W", "update", "--color", "red")),
                         ("read", ("workspace", "$W", "show"), (("/stdout/extra/color", "==", "red"),)))),
    ("workspace-focus", (MAKE_EMPTY, ("mutate", ("workspace", "create", "--empty", "--name", "b", "--focus")),
                         ("mutate", ("workspace", "$W", "focus")),
                         ("read", ("workspace", "$W", "show"), (("/stdout/focused", "==", True),)))),
    ("workspace-progress", (MAKE_EMPTY, ("mutate", ("workspace", "$W", "progress", "set", "0.5")),
                            ("read", ("workspace", "$W", "status", "list"), (("/stdout/0/progress/value", "==", 0.5),)),
                            ("mutate", ("workspace", "$W", "progress", "clear")),
                            ("read", ("workspace", "$W", "status", "list"), (("/stdout/0/progress", "==", None),)))),
    ("notification-create", (NOTIFY, ("read", ("notification", "list"),
                                      (("/stdout", "len", 1), ("/stdout/0/title", "==", "t"),
                                       ("/stdout/0/body", "==", "b"))))),
    ("notification-clear", (NOTIFY, ("mutate", ("notification", "clear")),
                            ("read", ("notification", "list"), (("/stdout", "len", 0),)))),
    ("room-create", (ROOM, ("read", ("room", "list"), (("/stdout", "len", 2), ("/stdout/1/name", "==", "r"))))),
    ("room-update", (ROOM, ("mutate", ("room", "$R", "update", "--name", "s")),
                     ("read", ("room", "list"), (("/stdout", "len", 2), ("/stdout/1/name", "==", "s"))))),
    ("room-delete", (ROOM, ("mutate", ("room", "$R", "delete")),
                     ("read", ("room", "list"), (("/stdout", "len", 1), ("/stdout/0/id", "==", "default"))))),
    ("terminal-panes", (MAKE_TERMINAL, ("read", ("pane", "list", "--workspace", "$W"), (("/stdout", "len", 1),)))),
    ("terminal-split", (MAKE_TERMINAL, ("mutate", ("pane", "$P", "split", "--right")),
                        ("read", ("pane", "list", "--workspace", "$W"), (("/stdout", "len", 2),)))),
    ("screen-rename", (MAKE_TERMINAL, ("mutate", ("screen", "$S", "rename", "main")),
                       ("read", ("screen", "$S", "show"), (("/stdout/name", "==", "main"),)))),
    ("terminal-screens", (MAKE_TERMINAL, ("read", ("screen", "list"), (("/stdout", "len", 1),)))),
    ("terminal-tabs", (MAKE_TERMINAL, ("read", ("tab", "list", "--workspace", "$W"), (("/stdout", "len", 1),)))),
    ("ephemeral", (("mutate", ("workspace", "create", "--empty", "--ephemeral", "--name", "e")),
                   ("read", ("workspace", "list"), (("/stdout", "len", 1), ("/stdout/0/extra/ephemeral", "==", True))))),
    ("terminal-close-reopen", (MAKE_TERMINAL, ("mutate", ("workspace", "$W", "close")),
                               ("read", ("closed", "list"), (("/stdout", "len", 1),)))),
    ("terminal-show", (MAKE_TERMINAL, ("read", ("terminal", "$T", "show"), (("/stdout/running", "==", True),)))),
    ("notification-two", (NOTIFY, ("mutate", ("notification", "create", "--title", "u", "--body", "c")),
                          ("read", ("notification", "list"), (("/stdout", "len", 2),)))),
    ("two-workspaces", (MAKE_EMPTY, ("mutate", ("workspace", "create", "--empty", "--name", "b")),
                        ("read", ("workspace", "list"), (("/stdout", "len", 2),)))),
)
REFS = {"$W": "/stdout/value/workspace_id", "$S": "/stdout/value/screen_id", "$P": "/stdout/value/pane_id",
        "$T": "/stdout/value/terminal_id", "$R": "/stdout/value/id"}


def smoke_case(name: str, spec: Sequence[SmokeStep]) -> Dict[str, Any]:
    """A case-v1 case of `cmux --json` steps on a fresh daemon; a settled snapshot after each step."""
    steps = []
    for index, (kind, argv, *_) in enumerate(spec):
        args = [f"$step:s0#{REFS[a]}" if a in REFS else a for a in argv]
        step: Dict[str, Any] = {"id": f"s{index}", "op": "cli", "args": {"argv": ["--json", *args]}}
        if kind == "mutate":
            step.update(target={"session": "current"}, expect={"outcome": "ok", "receipt": RECEIPT_KIND})
        elif kind == "read":
            step.update(readOnly=True, expect={"outcome": "ok"})
        else:
            step.update(readOnly=True, expect={"outcome": "error", "error": kind.split(":", 1)[1]})
        steps.append(step)
    return {
        "corpusVersion": 1, "id": f"cli-smoke-{name}", "suite": "cli",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"}, "environment": {},
        "fixture": {"seed": f"cli-smoke-{name}", "network": "offline", "clock": "fixed"},
        "preconditions": [], "requires": ["resource_api"], "platforms": ["linux", "mac"],
        "steps": steps, "invariants": [], "teardown": ["stop the case daemon"],
    }


def smoke_cases() -> List[Dict[str, Any]]:
    return [smoke_case(name, spec) for name, spec in SMOKE]


def smoke_checks() -> Dict[str, Dict[str, Tuple[Check, ...]]]:
    """case id -> step id -> the checks on its canonical cli facet."""
    return {f"cli-smoke-{name}": {f"s{index}": tuple(entry[2]) for index, entry in enumerate(spec) if len(entry) > 2}
            for name, spec in SMOKE}


def check_problems(checkpoints: Sequence[Mapping[str, Any]], checks: Mapping[str, Sequence[Check]]) -> List[str]:
    """What the checks find wrong in one attempt's canonical cli facets."""
    facets = {cp["step"]: cp["snapshot"]["facets"].get(CLI_FACET) for cp in checkpoints
              if cp["checkpoint"] == "settled"}
    problems = []
    for step, entries in checks.items():
        for pointer, op, want in entries:
            got = resolve_pointer(facets.get(step), pointer)
            if op == "len":
                ok = isinstance(got, list) and len(got) == want
            else:
                ok = got is not MISSING and normalize.canonical_json(got) == normalize.canonical_json(want)
            if not ok:
                shown = "nothing" if got is MISSING else normalize.canonical_json(got)[:200]
                problems.append(f"{step} {pointer} {op} {json.dumps(want)}: got {shown}")
    return problems


def cmd_run_case(args: argparse.Namespace) -> int:
    case = json.loads(Path(args.case).read_text(encoding="utf-8"))
    run_id = args.run_id or f"cli-{os.getpid()}-{time.time_ns()}"
    session = open_session({"binary": args.binary, "tag": args.tag, "run_id": run_id, "ref": args.ref})
    base = args.state_base / short_token(run_id)
    ctx = {"case_id": f"{case['suite']}/{case['id']}", "key": "0", "state_root": str(base / short_token(case["id"]))}
    try:
        result = session.run_case(case, ctx)
    finally:
        session.close()
        remove_empty_dir(base)
    print(json.dumps(result, indent=1, sort_keys=True))
    return 0 if result["status"] == "Pass" else 1


def cmd_smoke(args: argparse.Namespace) -> int:
    """The VM test of task 048: the 50 SMOKE cases, each twice on its own daemon, all at once. Every attempt
    passes with the I6 proof and its checks, both attempts of a case give equal checkpoint hashes (the cli
    facets included), and nothing of the run is left (pgrep -f of its state base, its state roots)."""
    run_id = args.run_id or f"cli-smoke-{os.getpid()}-{time.time_ns()}"
    base = args.state_base / short_token(run_id)
    session = open_session({"binary": args.binary, "run_id": run_id, "ref": args.ref})
    cases = [c for c in smoke_cases() if not args.only or any(o in c["id"] for o in args.only)]
    checks = smoke_checks()
    work = [(case, attempt) for attempt in range(args.repeat) for case in cases]
    started = time.monotonic()

    def one(index: int) -> Dict[str, Any]:
        case, attempt = work[index]
        ctx = {"case_id": f"cli/{case['id']}", "key": f"{index}", "attempt": attempt,
               "state_root": str(base / f"{index:06d}")}
        return session.run_case(case, ctx)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(one, range(len(work))))
    counts: Dict[str, int] = {}
    hashes: Dict[str, List[List[str]]] = {}
    failures = []
    for (case, attempt), result in zip(work, results):
        problems = check_problems(result.get("checkpoints") or (), checks[case["id"]]) \
            if result["status"] == "Pass" else []
        status = "Failure" if problems else result["status"]
        counts[status] = counts.get(status, 0) + 1
        if status != "Pass":
            detail = "; ".join(problems) or result["message"]
            failures.append(f"{case['id']}#{attempt} at {result.get('step')}: {detail[:400]}")
        hashes.setdefault(case["id"], []).append(attempt_hashes(result))
    unstable = sorted(cid for cid, attempts in hashes.items() if any(h != attempts[0] for h in attempts))
    leftovers = sorted(str(p) for p in base.glob("*"))
    pgrep = subprocess.run(["pgrep", "-f", str(base)], check=False, stdout=subprocess.PIPE, text=True).stdout.split()
    report = {
        "binary": session.binary, "sha": session.sha, "cases": len(cases), "attempts": len(work), "jobs": args.jobs,
        "seconds": round(time.monotonic() - started, 1), "counts": counts,
        "checkpoints": {cid: attempts[0] for cid, attempts in sorted(hashes.items())},
        "unstable": unstable, "failures": failures[:20], "pgrep_left": pgrep, "state_roots_left": leftovers,
    }
    print(json.dumps(report, indent=1, sort_keys=True))
    if args.verbose:
        for (case, attempt), result in zip(work, results):
            if attempt == 0:
                facets = {cp["step"]: cp["snapshot"]["facets"].get(CLI_FACET) for cp in result.get("checkpoints") or ()
                          if cp["checkpoint"] == "settled"}
                print(json.dumps({"case": case["id"], "cli": facets}, sort_keys=True))
    shutil.rmtree(base, ignore_errors=True)
    ok = counts.get("Pass", 0) == len(work) and not unstable and not pgrep and not leftovers
    return 0 if ok else 1


def attempt_hashes(result: Mapping[str, Any]) -> List[str]:
    """One attempt's checkpoint hashes (oracle.py's sha256 of canonical JSON); the cli facets are in them."""
    return [hashlib.sha256(normalize.canonical_json(cp["snapshot"]).encode("utf-8")).hexdigest()
            for cp in result.get("checkpoints") or ()]


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("case-worker", help="internal: one case from a JSON payload on stdin (CliSession)")
    run_case = sub.add_parser("run-case", help="one case; its result JSON")
    run_case.add_argument("case", help="a case-v1 JSON file")
    mode = run_case.add_mutually_exclusive_group(required=True)
    mode.add_argument("--binary", help="VM: the cmux-tui built at the run SHA")
    mode.add_argument("--tag", help="fleet: the tagged build's CMUX_TAG")
    smoke = sub.add_parser("smoke", help="the 50 daemon CLI cases, each attempt hashing equal (VM)")
    smoke.add_argument("--binary", required=True, help="the cmux-tui built at the run SHA")
    smoke.add_argument("--repeat", type=int, default=2, help="attempts per case; all must hash equal")
    smoke.add_argument("--jobs", type=int, default=100)
    smoke.add_argument("--only", action="append", help="run the cases whose id contains this text")
    smoke.add_argument("--verbose", action="store_true", help="also print each case's canonical cli facets")
    for cmd in (run_case, smoke):
        cmd.add_argument("--ref", help=f"the run SHA (a ref git rev-parse resolves); the binary's {BUILD_RECEIPT} "
                                       "must name it")
        cmd.add_argument("--state-base", type=Path, default=DEFAULT_STATE_BASE)
        cmd.add_argument("--run-id")
    args = parser.parse_args(argv)
    if args.command == "case-worker":
        return case_worker()
    try:
        return cmd_run_case(args) if args.command == "run-case" else cmd_smoke(args)
    except ValueError as error:
        print(f"driver_cli.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
