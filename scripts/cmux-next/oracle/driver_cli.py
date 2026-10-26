#!/usr/bin/env python3
"""The oracle's CLI driver: `cli` steps through the shipped `cmux` binary, in VM and fleet modes.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3D and task 048. Stdlib plus the sibling
drivers, Python 3.9+, safe under `python3 -I`. It implements the driver protocol of oracle.py
(`open_session`, `session.run_case`, `session.close`) for `--product cli`.

Two modes, chosen by the session context oracle.py gives:
- VM (`--binary`): the cargo-built cmux-tui at the run SHA (linux_run.sh's build, refused when its
  build.json names another SHA), run as `cmux` (argv[0], as the app bundles it in Resources/bin/cmux).
  Every case is driver_daemon.py's case (p15-oracle-023): its own state root, hermetic environment,
  `cmux-tui --headless` daemon, subreaper worker and I6 proof. `cli` steps run the binary with that
  case's environment, so `CMUX_TUI_SOCKET` names the case's daemon and nothing else is reachable;
  resource.call, kill, restart, settle and snapshot steps are the daemon driver's.
- Fleet (`--tag`): `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh ARGV`, the one supported way to reach a
  tagged build (repo CLAUDE.md). The app's facets come from driver_app.py (p15-oracle-047); until it
  lands every facet of a fleet snapshot is not comparable and only the receipts say what the CLI did.
The result's `receipts` list (one per cli step: exit, normalized stdout, error, sha256) is beside the
checkpoints; oracle.py hashes only checkpoints today, so a base/head diff of receipts needs oracle.py to
carry them (task 017's result format).
Neither mode ever runs `/tmp/cmux-cli` (a stale untagged copy that reaches whatever app is running):
`CliBinary` refuses that path, and fleet mode resolves the CLI only through cmux-debug-cli.sh.

A `cli` step's receipt (invariant I1) is its exit code and its normalized stdout: stdout parsed as JSON
(one value, or JSON lines as a list) or kept as text, then case root and home rewritten to `$ROOT` and
`$HOME` (normalize.py's rewriter) and every id that matches the snapshot schema's x-oracle-id-patterns
relabeled `kind#N` in first-seen order of a sorted-key traversal, with labels shared by all steps of the
case. Exit 0 is outcome `ok`; any other exit is outcome `error` with the typed code of the CLI's JSON
error (`--json` writes `{code, message, details, retryable}` to stderr: cli/wire.rs print_local_error),
or `cli.failed` when stderr has none. `expect.receipt: cli.exit` asserts a receipt exists and
`expect.result` compares the normalized receipt `{exit, stdout}` exactly. `$step:` references read the
raw stdout, so a later step can pass an id an earlier `cmux ... --json` printed.

Chrome reference (chromium/src): base/test/launcher/test_launcher.cc runs each test in a child process and
keeps its exit code and output as the result (TestResult::output_snippet, written by
base/test/launcher/test_results_tracker.cc); here the child is the shipped `cmux` binary and the result is
its exit code and normalized stdout.

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
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from functools import partial
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
DEBUG_CLI = REPO / "scripts" / "cmux-debug-cli.sh"

if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import normalize  # noqa: E402 - sibling of this file (p15-oracle-013)

try:
    from driver_daemon import (  # noqa: E402 - the daemon driver's case runner (p15-oracle-023)
        DEFAULT_STATE_BASE,
        EXIT_S,
        FACETS,
        SESSION_NAME,
        CaseError,
        CaseRun,
        DaemonSession,
        become_subreaper,
        end_tree_on_term,
        host_meta,
        load_snapshot_schema,
        not_comparable,
        remove_empty_dir,
        resolve_refs,
        short_token,
        tail,
        worker_bound,
    )
except ImportError as _error:  # pragma: no cover - a checkout from before task 023
    raise ImportError("driver_cli.py runs its VM cases on driver_daemon.py's case runner (p15-oracle-023), "
                      f"which this checkout lacks: {_error}") from _error

PRODUCT = "cli"
CLI_ARGV0 = "cmux"
# The stale copy agents used to drop in /tmp: it reaches whichever app answers, never the case's daemon.
FORBIDDEN_CLI = Path("/tmp/cmux-cli")
RECEIPT_KIND = "cli.exit"
FALLBACK_ERROR = "cli.failed"
ERROR_CODE = re.compile(r"^[a-z][a-z_]*(\.[a-z][a-z_]*)+$")
SHA = re.compile(r"^[0-9a-f]{40}$")
# Seconds a `cmux` call may take before its step is a Timeout; a Slow expectation multiplies it.
CLI_S = 30.0
FLEET_OPS = frozenset({"cli", "settle", "snapshot"})


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
# Receipts: exit code and normalized stdout


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


class IdLabels:
    """`kind#N` labels for the ids a case's CLI output shows, in first-seen order, shared by its steps."""

    _EDGE_BEFORE = r"(?<![A-Za-z0-9_])"
    _EDGE_AFTER = r"(?![A-Za-z0-9_])"

    def __init__(self, schema: normalize.Schema):
        parts = []
        self.kinds: List[str] = []
        for kind, regex in schema.id_patterns:
            body = regex.pattern
            body = body[1:] if body.startswith("^") else body
            body = body[:-1] if body.endswith("$") else body
            parts.append(f"(?P<k{len(self.kinds)}>{body})")
            self.kinds.append(kind)
        self.search = re.compile(self._EDGE_BEFORE + "(?:" + "|".join(parts) + ")" + self._EDGE_AFTER) if parts else None
        self.labels: Dict[str, str] = {}
        self.counts: Dict[str, int] = {}

    def label(self, kind: str, raw: str) -> str:
        if raw not in self.labels:
            self.counts[kind] = self.counts.get(kind, 0) + 1
            self.labels[raw] = f"{kind}#{self.counts[kind]}"
        return self.labels[raw]

    def text(self, value: str) -> str:
        if self.search is None:
            return value

        def swap(match: "re.Match[str]") -> str:
            index = int(match.lastgroup[1:])
            return self.label(self.kinds[index], match.group(0))

        return self.search.sub(swap, value)


# Keys whose values are wall-clock readings (`created_at_ms`, `at_ms`, `exited_at`, `connected_seconds`): the
# snapshot schema marks the same daemon fields x-oracle-time. A daemon without the oracle virtual clock
# (p15-oracle-185) prints the host's clock there, so on a wall-clock run they read WALL_TIME.
WALL_TIME_KEY = re.compile(r"(?:^|_)at(?:_ms)?$|_seconds$")
WALL_TIME = "$WALL_TIME"
DECIMAL = re.compile(r"^-?[0-9]+$")


def _always() -> bool:
    return True


@dataclass
class StdoutNormalizer:
    """normalize.py's path rewrite ($ROOT, $HOME), the case's own session name as the fixture's, wall-clock
    readings on a wall-clock run, then ids as `kind#N` (one labeling for all steps of a case)."""

    ids: IdLabels
    context: normalize.Context
    names: Mapping[str, str] = field(default_factory=dict)
    wall_clock: Callable[[], bool] = _always

    def __post_init__(self) -> None:
        self.rewriter = normalize._Rewriter(self.context)  # the one path rewriter (normalize.py rule 2)
        self.name_search = (re.compile(r"(?<![A-Za-z0-9])(" + "|".join(map(re.escape, self.names))
                                       + r")(?![A-Za-z0-9])") if self.names else None)

    def text_names(self, value: str) -> str:
        """The case's own session name as the fixture's (paths and ids untouched)."""
        if self.name_search is None:
            return value
        return self.name_search.sub(lambda match: self.names[match.group(1)], value)

    def text(self, value: str) -> str:
        return self.ids.text(self.text_names(self.rewriter.apply("url", value)[0]))

    def value(self, value: Any, key: Optional[str] = None) -> Any:
        """A parsed stdout in a sorted-key traversal, so labels do not follow the CLI's print order."""
        if key is not None and WALL_TIME_KEY.search(key) and self.wall_clock() and (
                (isinstance(value, int) and not isinstance(value, bool))
                or (isinstance(value, str) and DECIMAL.fullmatch(value))):
            return WALL_TIME
        if isinstance(value, str):
            return self.text(value)
        if isinstance(value, list):
            return [self.value(item, key) for item in value]
        if isinstance(value, dict):
            return {self.text(name): self.value(value[name], name) for name in sorted(value)}
        return value


def receipt_of(output: CliOutput, normalizer: StdoutNormalizer) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    """(the normalized receipt, the raw reply that `$step:` references read)."""
    raw = parse_stdout(output.stdout)
    receipt: Dict[str, Any] = {"exit": output.exit, "stdout": normalizer.value(raw)}
    reply: Dict[str, Any] = {"exit": output.exit, "stdout": raw}
    if output.exit != 0:
        receipt["error"] = reply["error"] = error_code(output.stderr)
    return receipt, reply


def outcome_of(receipt: Mapping[str, Any]) -> Tuple[str, Any]:
    return ("ok", receipt) if receipt["exit"] == 0 else ("error", receipt["error"])


def check_cli_expect(step: Mapping[str, Any], outcome: Tuple[str, Any], receipt: Mapping[str, Any]) -> None:
    """expect for a cli step: outcome, typed error, `cli.exit` receipt, exact normalized result."""
    expect = step.get("expect")
    if not expect:
        return
    step_id = step["id"]
    kind, detail = outcome
    if expect["outcome"] != kind or (kind == "error" and detail != expect.get("error")):
        got = f"error {detail} (exit {receipt['exit']})" if kind == "error" else "ok"
        want = expect["outcome"] + (f" {expect['error']}" if "error" in expect else "")
        raise CaseError("Failure", f"expected {want}, got {got}", step_id)
    if kind == "ok":
        kind_wanted = expect.get("receipt")
        if kind_wanted is not None and kind_wanted != RECEIPT_KIND:
            raise CaseError("Crash", f"receipt kind {kind_wanted}: a cli step's receipt is {RECEIPT_KIND}", step_id)
    if "result" in expect and normalize.canonical_json(dict(receipt)) != normalize.canonical_json(expect["result"]):
        raise CaseError("Failure", f"result differs: {normalize.canonical_json(dict(receipt))[:300]}", step_id)


def step_argv(step: Mapping[str, Any], replies: Mapping[str, Any]) -> Tuple[List[str], Optional[str]]:
    """The step's argv and stdin with `$step:` references resolved (a non-string value as its JSON)."""
    args = resolve_refs(step["args"], replies)
    argv = [a if isinstance(a, str) else normalize.canonical_json(a) for a in args["argv"]]
    stdin = args.get("stdin")
    return argv, stdin if isinstance(stdin, str) else None


@dataclass
class CliSteps:
    """The cli step runner both modes share: one runner, one id labeling, the case's receipts."""

    runner: CliRunner
    normalizer: StdoutNormalizer
    scale: float = 1.0
    receipts: List[Dict[str, Any]] = field(default_factory=list)

    def run(self, step: Mapping[str, Any], replies: Dict[str, Any]) -> Tuple[Tuple[str, Any], Dict[str, Any]]:
        step_id = step["id"]
        try:
            argv, stdin = step_argv(step, replies)
        except CaseError as error:
            raise CaseError(error.status, error.message, error.step or step_id) from None
        try:
            output = self.runner.run(argv, stdin, CLI_S * self.scale)
        except CliTimeout as error:
            raise CaseError("Timeout", str(error), step_id) from None
        except OSError as error:
            raise CaseError("Crash", f"cannot run {self.runner.describe()}: {error}", step_id) from None
        receipt, reply = receipt_of(output, self.normalizer)
        replies[step_id] = reply
        digest = hashlib.sha256(normalize.canonical_json(receipt).encode("utf-8")).hexdigest()
        self.receipts.append({"step": step_id, **receipt, "sha256": digest})
        outcome = outcome_of(receipt)
        if outcome[0] == "error":
            lines = output.stderr.decode("utf-8", "replace").strip().splitlines()
            # Diagnostic only, outside the hashed receipt.
            self.receipts[-1]["stderrTail"] = self.normalizer.text(lines[-1][:300]) if lines else ""
        check_cli_expect(step, outcome, receipt)
        return outcome, receipt


# ---------------------------------------------------------------------------------------------------------
# VM mode: driver_daemon.py's case with a cli op


def build_sha(binary: Path) -> Optional[str]:
    """The SHA in linux_run.sh's build receipt beside the binary (build.json), if there is one."""
    try:
        sha = json.loads((binary.parent / "build.json").read_text(encoding="utf-8")).get("sha")
    except (OSError, ValueError):
        return None
    return sha if isinstance(sha, str) and SHA.fullmatch(sha) else None


class CliCaseRun(CaseRun):
    """driver_daemon.py's case (hermetic daemon, steps, I6 teardown) plus `cli` steps."""

    def __init__(self, binary: str, sha: str, schema: normalize.Schema, case: Mapping[str, Any],
                 ctx: Mapping[str, Any], session_ctx: Mapping[str, Any]):
        super().__init__(binary, sha, schema, case, ctx, session_ctx)
        runner = VmCli(CliBinary(Path(binary)), self.env, str(self.paths.home))
        normalizer = StdoutNormalizer(IdLabels(schema), self.normalize_context(), {self.paths.session: SESSION_NAME},
                                      lambda: not self.daemon.virtual_clock)
        self.cli = CliSteps(runner, normalizer, self.scale)
        self.ops["cli"] = self.op_cli

    def op_cli(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        step_id = step["id"]
        before = self.daemon_facet(step_id) if step.get("readOnly") and self.daemon.running else None
        outcome, _ = self.cli.run(step, self.state.replies)
        if before is not None:
            self.check_read_only(index, step_id, before)
        return outcome

    def check_expect(self, step: Mapping[str, Any], outcome: Tuple[str, Any]) -> None:
        # op_cli checked its own expect against the receipt.
        if step["op"] != "cli":
            super().check_expect(step, outcome)

    def snapshot(self, index: int, checkpoint: str, facets: Dict[str, Any]) -> Dict[str, Any]:
        value = super().snapshot(index, checkpoint, facets)
        value["meta"]["product"] = PRODUCT
        return value

    def daemon_facet(self, step: str) -> Any:
        """The daemon driver's facet with the case's session name as the fixture's in the panic log path too
        (driver_daemon.py renames it in `session.name` only), so two runs of a case hash equal."""
        facet = super().daemon_facet(step)
        panic = facet.get("oracle", {}).get("panicLog") if isinstance(facet, dict) else None
        if isinstance(panic, dict) and isinstance(panic.get("path"), str):
            panic["path"] = self.cli.normalizer.text_names(panic["path"])
        return facet

    def run(self) -> Dict[str, Any]:
        result = super().run()
        result["receipts"] = self.cli.receipts
        return result


class CliSession(DaemonSession):
    """The VM session: driver_daemon.py's session whose case workers run CliCaseRun."""

    def __init__(self, session_ctx: Mapping[str, Any]):
        binary = CliBinary(Path(str(session_ctx.get("binary") or "")))
        ref = session_ctx.get("ref")
        built = build_sha(binary.path)
        if isinstance(ref, str) and SHA.fullmatch(ref) and built and built != ref:
            raise ValueError(f"--binary {binary.path} was built at {built}, not at the run SHA {ref}")
        super().__init__(session_ctx)
        if self.sha == "0" * 40 and built:
            self.sha = built

    def run_worker(self, case: Dict[str, Any], case_ctx: Dict[str, Any],
                   scale: float) -> Tuple[Dict[str, Any], bool]:
        payload = {"binary": self.binary, "sha": self.sha, "schema": self.schema_path, "case": case,
                   "ctx": case_ctx, "session": self.session_ctx}
        return run_case_worker(Path(__file__).resolve(), payload, worker_bound(case, scale), scale)


def run_case_worker(script: Path, payload: Mapping[str, Any], bound: float,
                    scale: float) -> Tuple[Dict[str, Any], bool]:
    """`script case-worker` on `payload`: its result, and whether it finished (then it proved its tree empty)."""
    worker = subprocess.Popen([sys.executable, "-I", str(script), "case-worker"],
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


def case_worker() -> int:
    """`case-worker`: one CliCaseRun from the JSON payload on stdin; the result JSON on stdout."""
    payload = json.load(sys.stdin)
    schema, refusal = load_snapshot_schema(payload["schema"])
    if schema is None:
        raise SystemExit(f"driver_cli.py case-worker: {refusal}")
    run = CliCaseRun(payload["binary"], payload["sha"], schema, payload["case"], payload["ctx"], payload["session"])
    # Every process the case starts, the cmux calls included, stays in this worker's tree (I6).
    become_subreaper()
    signal.signal(signal.SIGTERM, partial(end_tree_on_term, str(run.paths.root)))
    json.dump(run.run(), sys.stdout)
    return 0


# ---------------------------------------------------------------------------------------------------------
# Fleet mode: a tagged app on a mini


class FleetSession:
    """cli, settle and snapshot steps against `CMUX_TAG=<tag>`'s running app. Launching and resetting the app
    and its facets are driver_app.py's (p15-oracle-047); this session never launches anything."""

    def __init__(self, session_ctx: Mapping[str, Any], runner: Optional[CliRunner] = None):
        schema_path = str(session_ctx.get("snapshot_schema") or normalize.DEFAULT_SCHEMA)
        schema, refusal = load_snapshot_schema(schema_path)
        if schema is None:
            raise ValueError(f"normalize.py refuses the snapshot schema: {refusal}")
        self.schema = schema
        self.runner = runner or FleetCli(str(session_ctx.get("tag") or ""))
        ref = session_ctx.get("ref")
        self.sha = ref if isinstance(ref, str) and SHA.fullmatch(ref) else "0" * 40
        self.home = os.environ.get("HOME", "")
        self.host = host_meta()

    def context(self) -> normalize.Context:
        return normalize.Context(home=(self.home,) if self.home.rstrip("/") else ())

    def run_case(self, case: Dict[str, Any], case_ctx: Dict[str, Any]) -> Dict[str, Any]:
        case_id = case_ctx.get("case_id") or f"{case.get('suite')}/{case.get('id')}"
        scale = float(case_ctx.get("timeout_multiplier") or 1)
        steps = CliSteps(self.runner, StdoutNormalizer(IdLabels(self.schema), self.context()), scale)
        replies: Dict[str, Any] = {}
        snapshots: List[Tuple[str, str, Dict[str, Any]]] = []
        status, message, at = "Pass", "", None
        try:
            for index, step in enumerate(case.get("steps") or ()):
                if step["op"] not in FLEET_OPS:
                    raise CaseError("Crash", f"op {step['op']} runs in driver_app.py (p15-oracle-047), not in the "
                                             f"fleet CLI session", step["id"])
                names = tuple((step.get("args") or {}).get("facets") or FACETS) if step["op"] == "snapshot" \
                    else ("daemon",)
                checkpoints = step.get("checkpoint") or ["settled"]
                if "before" in checkpoints:
                    snapshots.append((step["id"], "before", self.snapshot(case_id, index, "before", names)))
                if step["op"] == "cli":
                    steps.run(step, replies)
                if "settled" in checkpoints:
                    snapshots.append((step["id"], "settled", self.snapshot(case_id, index, "settled", names)))
        except CaseError as error:
            status, message, at = error.status, error.message, error.step
        result: Dict[str, Any] = {"status": status, "message": message, "checkpoints": [],
                                  "receipts": steps.receipts}
        if at:
            result["step"] = at
        if snapshots:
            canonical = normalize.canonicalize_case([s for _, _, s in snapshots], self.schema, self.context(),
                                                    [f"{step}/{cp}" for step, cp, _ in snapshots])
            result["checkpoints"] = [{"step": step, "checkpoint": cp, "snapshot": r.value}
                                     for (step, cp, _), r in zip(snapshots, canonical)]
        return result

    def snapshot(self, case_id: str, index: int, checkpoint: str, names: Sequence[str]) -> Dict[str, Any]:
        facets = {name: not_comparable("the fleet CLI session reads no app facet; driver_app.py captures them",
                                       "p15-oracle-047") for name in names}
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

# Each case runs on a fresh hermetic daemon. A step is (kind, argv): `read` is readOnly (its daemon facet must
# not move), `mutate` targets the current session and expects a cli.exit receipt, `error:<code>` is readOnly
# and expects that typed error. `$W`, `$P`, `$T` and `$R` stand for the workspace, pane, terminal and room id
# the case's first step printed. Left out until their output is stable: `client list` (clients print in raw id
# order, random until p15-oracle-185 seeds ids) and checklist items (`chk_` ids are not in the snapshot
# schema's x-oracle-id-patterns).
NO_SUCH = {kind: f"{prefix}_{'0' * 32}" for kind, prefix in (("ws", "ws"), ("pane", "pane"), ("tab", "tab"),
                                                                ("term", "term"))}
SmokeStep = Tuple[str, Tuple[str, ...]]
MAKE_EMPTY: SmokeStep = ("mutate", ("workspace", "create", "--empty", "--name", "a"))
MAKE_TERMINAL: SmokeStep = ("mutate", ("workspace", "create", "--name", "a"))
SMOKE: Tuple[Tuple[str, Tuple[SmokeStep, ...]], ...] = (
    ("machine-list", (("read", ("machine", "list")),)),
    ("machine-show", (("read", ("machine", "current", "show")),)),
    ("session-list", (("read", ("session", "list")),)),
    ("session-show", (("read", ("session", "current", "show")),)),
    ("session-ping", (("read", ("session", "current", "ping")),)),
    ("workspace-list", (("read", ("workspace", "list")),)),
    ("screen-list", (("read", ("screen", "list")),)),
    ("pane-list", (("read", ("pane", "list")),)),
    ("tab-list", (("read", ("tab", "list")),)),
    ("terminal-list", (("read", ("terminal", "list")),)),
    ("notification-list", (("read", ("notification", "list")),)),
    ("agent-list", (("read", ("agent", "list")),)),
    ("room-list", (("read", ("room", "list")),)),
    ("closed-list", (("read", ("closed", "list")),)),
    ("tab-group-list", (("read", ("tab", "group", "list")),)),
    ("screen-group-list", (("read", ("screen", "group", "list")),)),
    ("journal-producers", (("read", ("session", "current", "journal", "producer", "list")),)),
    ("journal-hooks", (("read", ("session", "current", "journal", "hook", "list")),)),
    ("journal-checkpoints", (("read", ("session", "current", "journal", "checkpoint", "list")),)),
    ("settings-needs-app", (("error:socket.no_app", ("settings", "list")),)),
    ("keybinding-needs-app", (("error:socket.no_app", ("keybinding", "list")),)),
    ("window-needs-app", (("error:socket.no_app", ("window", "list")),)),
    ("workspace-not-found", (("error:selector.not_found", ("workspace", NO_SUCH["ws"], "show")),)),
    ("pane-not-found", (("error:selector.not_found", ("pane", NO_SUCH["pane"], "show")),)),
    ("tab-not-found", (("error:selector.not_found", ("tab", NO_SUCH["tab"], "show")),)),
    ("terminal-not-found", (("error:selector.not_found", ("terminal", NO_SUCH["term"], "show")),)),
    ("bad-option", (("error:usage.invalid", ("workspace", "create", "--bogus")),)),
    ("create-empty-list", (MAKE_EMPTY, ("read", ("workspace", "list")))),
    ("create-terminal-list", (MAKE_TERMINAL, ("read", ("terminal", "list")))),
    ("create-show", (MAKE_EMPTY, ("read", ("workspace", "$W", "show")))),
    ("create-rename", (MAKE_EMPTY, ("mutate", ("workspace", "$W", "rename", "b")), ("read", ("workspace", "$W", "show")))),
    ("create-close", (MAKE_EMPTY, ("mutate", ("workspace", "$W", "close")), ("read", ("workspace", "list")))),
    ("create-move", (MAKE_EMPTY, ("mutate", ("workspace", "create", "--empty", "--name", "b")),
                     ("mutate", ("workspace", "$W", "move", "--index", "1")), ("read", ("workspace", "list")))),
    ("create-title", (MAKE_EMPTY, ("mutate", ("workspace", "$W", "update", "--title", "T")),
                      ("read", ("workspace", "$W", "show")))),
    ("workspace-status", (MAKE_EMPTY, ("mutate", ("workspace", "$W", "status", "set", "build", "ok")),
                          ("read", ("workspace", "$W", "status", "list")))),
    ("workspace-log", (MAKE_EMPTY, ("mutate", ("workspace", "$W", "log", "append", "hello")),
                       ("read", ("workspace", "$W", "log", "list")))),
    ("workspace-color", (MAKE_EMPTY, ("mutate", ("workspace", "$W", "update", "--color", "red")),
                         ("read", ("workspace", "$W", "show")))),
    ("workspace-focus", (MAKE_EMPTY, ("mutate", ("workspace", "create", "--empty", "--name", "b", "--focus")),
                         ("mutate", ("workspace", "$W", "focus")), ("read", ("workspace", "list")))),
    ("workspace-progress", (MAKE_EMPTY, ("mutate", ("workspace", "$W", "progress", "set", "0.5")),
                            ("mutate", ("workspace", "$W", "progress", "clear")))),
    ("notification-create", (("mutate", ("notification", "create", "--title", "t", "--body", "b")),
                             ("read", ("notification", "list")))),
    ("notification-clear", (("mutate", ("notification", "create", "--title", "t", "--body", "b")),
                            ("mutate", ("notification", "clear")), ("read", ("notification", "list")))),
    ("room-create", (("mutate", ("room", "create", "--name", "r")), ("read", ("room", "list")))),
    ("room-update", (("mutate", ("room", "create", "--name", "r")), ("mutate", ("room", "$R", "update", "--name", "s")),
                     ("read", ("room", "list")))),
    ("room-delete", (("mutate", ("room", "create", "--name", "r")), ("mutate", ("room", "$R", "delete")),
                     ("read", ("room", "list")))),
    ("terminal-panes", (MAKE_TERMINAL, ("read", ("pane", "list", "--workspace", "$W")))),
    ("terminal-split", (MAKE_TERMINAL, ("mutate", ("pane", "$P", "split", "--right")),
                        ("read", ("pane", "list", "--workspace", "$W")))),
    ("terminal-tabs", (MAKE_TERMINAL, ("read", ("tab", "list", "--workspace", "$W")))),
    ("ephemeral", (("mutate", ("workspace", "create", "--empty", "--ephemeral", "--name", "e")),
                   ("read", ("workspace", "list")))),
    ("terminal-close-reopen", (MAKE_TERMINAL, ("mutate", ("workspace", "$W", "close")), ("read", ("closed", "list")))),
    ("terminal-show", (MAKE_TERMINAL, ("read", ("terminal", "$T", "show")))),
)
REFS = {"$W": "/stdout/value/workspace_id", "$P": "/stdout/value/pane_id", "$T": "/stdout/value/terminal_id",
        "$R": "/stdout/value/id"}


def smoke_case(name: str, spec: Sequence[SmokeStep]) -> Dict[str, Any]:
    """A case-v1 case of `cmux --json` steps on a fresh daemon; a settled snapshot after each step."""
    steps = []
    for index, (kind, argv) in enumerate(spec):
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
    passes with the I6 proof, both attempts of a case give equal receipt and checkpoint hashes, and nothing of
    the run is left (pgrep -f of its state base, its state roots)."""
    run_id = args.run_id or f"cli-smoke-{os.getpid()}-{time.time_ns()}"
    base = args.state_base / short_token(run_id)
    session = open_session({"binary": args.binary, "run_id": run_id, "ref": args.ref})
    cases = [c for c in smoke_cases() if not args.only or any(o in c["id"] for o in args.only)]
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
        counts[result["status"]] = counts.get(result["status"], 0) + 1
        if result["status"] != "Pass":
            failures.append(f"{case['id']}#{attempt} at {result.get('step')}: {result['message'][:400]}")
        hashes.setdefault(case["id"], []).append(attempt_hashes(result))
    unstable = sorted(cid for cid, attempts in hashes.items() if any(h != attempts[0] for h in attempts))
    leftovers = sorted(str(p) for p in base.glob("*"))
    pgrep = subprocess.run(["pgrep", "-f", str(base)], check=False, stdout=subprocess.PIPE, text=True).stdout.split()
    report = {
        "binary": session.binary, "sha": session.sha, "cases": len(cases), "attempts": len(work), "jobs": args.jobs,
        "seconds": round(time.monotonic() - started, 1), "counts": counts,
        "receipts": {cid: attempts[0] for cid, attempts in sorted(hashes.items())},
        "unstable": unstable, "failures": failures[:20], "pgrep_left": pgrep, "state_roots_left": leftovers,
    }
    print(json.dumps(report, indent=1, sort_keys=True))
    if args.verbose:
        for (case, attempt), result in zip(work, results):
            if attempt == 0:
                print(json.dumps({"case": case["id"], "receipts": result.get("receipts")}, sort_keys=True))
    shutil.rmtree(base, ignore_errors=True)
    ok = counts.get("Pass", 0) == len(work) and not unstable and not pgrep and not leftovers
    return 0 if ok else 1


def attempt_hashes(result: Mapping[str, Any]) -> List[str]:
    """One attempt's receipt hashes, then its checkpoint hashes (oracle.py's sha256 of canonical JSON)."""
    receipts = [r["sha256"] for r in result.get("receipts") or ()]
    snapshots = [hashlib.sha256(normalize.canonical_json(cp["snapshot"]).encode("utf-8")).hexdigest()
                 for cp in result.get("checkpoints") or ()]
    return receipts + snapshots


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
    smoke.add_argument("--verbose", action="store_true", help="also print each case's receipts")
    for cmd in (run_case, smoke):
        cmd.add_argument("--ref", help="the run SHA (checked against the binary's build.json)")
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
