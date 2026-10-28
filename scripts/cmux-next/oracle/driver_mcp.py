#!/usr/bin/env python3
"""The oracle's MCP driver: `mcp` steps through `cmux mcp serve --all-tools` over stdio, in VM and fleet modes.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3D and 3F.4 and task 209. Stdlib plus the sibling
drivers, Python 3.9+, safe under `python3 -I`. It implements the driver protocol of oracle.py (`open_session`,
`session.run_case`, `session.close`) for `--product mcp`.

An mcp step is one MCP client session, as Claude Code or Codex opens one: `initialize`, the `initialized`
notification, one `tools/call` with the step's tool and arguments, then stdin closes and the server exits. The
server is the shipped `cmux` binary, so a tool call has the CLI's own transport (socket discovery, ids, keys).
`serve` refuses unless its settings file says `"mcp": {"enabled": true}`: VM mode gives the server a file of its
own (MCP_CONFIG in the case root, named by CMUX_NEXT_CONFIG_FILE for the server only), so the case daemon's own
settings file, and with it its settings facet, is the one every other product sees.

Two modes, chosen by the binary oracle.py gives:
- VM (`--binary CMUX_TUI`): the cmux-tui linux_run.sh built at the run SHA, run as `cmux`. Every case is
  driver_cli.py's case (its hermetic daemon, I6 proof, `cli` steps), plus `mcp` steps. An mcp step ends when the
  daemon has dropped every connection the server opened (driver_cli.CliCaseRun.await_departure), so its
  checkpoints never race the server's close.
- Fleet (`--binary "PATH/cmux DEV <tag>.app"`): driver_app.py's session (bench launch, settle, waitFor, app
  facets), whose mcp and cli steps run the bundle's own cmux on the app's socket and keep their receipts.

A step's receipt (invariant I1) is the `mcp` facet of its settled checkpoint (snapshot-v1 facets.mcp):
`{isError, result, error?}`, `result` being the tools/call result's structuredContent (its content when it has
none). A tool error's code is its envelope's `error.code` (a bare app control code becomes `control.<code>`,
as driver_app.typed_error names it); a JSON-RPC error is `mcp.rpc_error`. normalize.py canonicalizes the facet
with the case's other checkpoints and oracle.py hashes and diffs it like any facet. `expect.receipt:
mutation_result` asserts the daemon's mutation result; `expect.errorDetails` is a subset of the envelope's
`error.details`; `expect.result` is compared with the canonical facet's `result` after the case. `$step:`
references read the raw result.

Parity (spec 3F.4, product parity mcp vs cli): `parity RUN_DIR...` compares each pair of cases that
tests/oracle/corpus/mcp/coverage.json names (gen_mcp.py): an mcp case and its twin, the same steps with the
call through another entrypoint (the daemon-ops case's resource.call on the VM, the CLI twin's `cmux` verb on
the fleet). Both cases must end with the same result: a pair whose results differ (or whose case is missing
on one side) is divergent, and a pair that fails the same way on both sides is not compared. At every checkpoint
both have, the snapshots must be equal but for the receipt facets (cli, mcp) and the differences
`_parity.json` gives a reason for; a pair whose checkpoints from the entry step on are all masked whole by a
reason is not compared.

Chrome reference (chromium/src): third_party/blink/web_tests/external/wpt runs one test against several
products (third_party/blink/tools/run_wpt_tests.py --product), and content/browser/devtools/protocol's
browser tests drive the same DevTools domains over the pipe transport (--remote-debugging-pipe,
DevToolsPipeHandler) as over the websocket: one protocol client per test, and the result is the
protocol's own reply.

Usage:
  driver_mcp.py run-case --binary CMUX_TUI CASE.json [--isolation none]   one VM case, its result JSON
  driver_mcp.py run-case --binary "PATH/cmux DEV <tag>.app" CASE.json      one fleet case
  driver_mcp.py tools --binary CMUX_TUI [--out FILE | --check FILE]        the server's tool list (VM)
  driver_mcp.py parity RUN_DIR [RUN_DIR ...] [--coverage FILE]             MCP vs twin settled snapshots
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
CORPUS = REPO / "tests" / "oracle" / "corpus" / "mcp"
TOOLS_FILE = CORPUS / "_tools.json"
PARITY_FILE = CORPUS / "_parity.json"
COVERAGE_FILE = CORPUS / "coverage.json"

if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import normalize  # noqa: E402 - sibling of this file
import driver_cli  # noqa: E402 - the cli driver's case and receipts
import driver_daemon  # noqa: E402 - the daemon driver's case worker
from driver_cli import CLI_FACET, CliBinary, CliOutput, CliTimeout, VmCli  # noqa: E402
from driver_daemon import (  # noqa: E402
    DEFAULT_STATE_BASE,
    MISSING,
    SESSION_NAME,
    CaseError,
    not_comparable,
    remove_empty_dir,
    resolve_refs,
    short_token,
)

PRODUCT = "mcp"
MCP_FACET = "mcp"
RECEIPT_FACETS = (CLI_FACET, MCP_FACET)
SERVE_ARGV = ("mcp", "serve", "--all-tools")
TOOLS_ARGV = ("--json", "mcp", "tools")
# The newest MCP revision `cmux mcp` speaks (cli/mcp.rs PROTOCOL_VERSIONS).
PROTOCOL_VERSION = "2025-06-18"
CLIENT_INFO = {"name": "cmux-oracle", "version": "1"}
CALL_ID = 2
# The server's own settings file in the case root: only `mcp.enabled` (cli/mcp/config.rs).
MCP_CONFIG = "mcp-config.json"
MCP_SETTINGS = {"mcp": {"enabled": True}}
RPC_ERROR = "mcp.rpc_error"
TOOL_FAILED = "mcp.tool_failed"
ERROR_CODE = re.compile(r"^[a-z][a-z_]*(\.[a-z][a-z_]*)+$")
BARE_CODE = re.compile(r"^[a-z][a-z_]*$")
# Seconds one server session may take: agents_events and terminal_wait wait 30 s by default (v2_tools.rs).
MCP_S = 60.0
MUTATION_RESULT = "mutation_result"
MUTATION_KEYS = frozenset({"value", "generation", "revision", "replayed"})


# ---------------------------------------------------------------------------------------------------------
# One MCP client session


def session_input(tool: str, arguments: Mapping[str, Any]) -> str:
    """The client's lines: initialize, the initialized notification, one tools/call."""
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": PROTOCOL_VERSION, "capabilities": {}, "clientInfo": CLIENT_INFO}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": CALL_ID, "method": "tools/call",
         "params": {"name": tool, "arguments": dict(arguments)}},
    ]
    return "".join(json.dumps(message, sort_keys=True) + "\n" for message in messages)


def call_answer(stdout: str) -> Optional[Dict[str, Any]]:
    """The server's answer to the tools/call (its id), or None; notifications and other lines are skipped."""
    answer = None
    for line in stdout.splitlines():
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if isinstance(message, dict) and message.get("id") == CALL_ID and "method" not in message:
            answer = message
    return answer


def typed_code(error: Any) -> str:
    """A tool error envelope's code as case-v1's typed code: dotted as is, an app control code as control.<code>
    (driver_app.typed_error), anything else mcp.tool_failed."""
    code = error.get("code") if isinstance(error, dict) else None
    if isinstance(code, str) and ERROR_CODE.fullmatch(code):
        return code
    if isinstance(code, str) and BARE_CODE.fullmatch(code):
        return f"control.{code}"
    return TOOL_FAILED


@dataclass(frozen=True)
class McpReceipt:
    facet: Dict[str, Any]
    reply: Any
    outcome: Tuple[str, Any]


def receipt_of(answer: Mapping[str, Any], names: Mapping[str, str]) -> McpReceipt:
    """The mcp facet, the raw reply `$step:` references read, and the step's outcome."""
    if "error" in answer:
        error = answer["error"] if isinstance(answer["error"], dict) else {}
        facet = {"isError": True, "result": {"rpcCode": error.get("code")}, "error": RPC_ERROR}
        return McpReceipt(facet, {"error": error}, ("error", RPC_ERROR))
    result = answer.get("result") if isinstance(answer.get("result"), dict) else {}
    value = result["structuredContent"] if "structuredContent" in result else result.get("content")
    failed = result.get("isError") is True
    facet: Dict[str, Any] = {"isError": failed, "result": driver_cli.rename(value, names)}
    if failed:
        facet["error"] = typed_code(value.get("error") if isinstance(value, dict) else None)
        return McpReceipt(facet, value, ("error", facet["error"]))
    return McpReceipt(facet, value, ("ok", value))


def details_problem(want: Mapping[str, Any], got: Any, at: str = "") -> Optional[str]:
    """case-v1 errorDetails: each key present with an equal value, objects compared key by key."""
    if not isinstance(got, dict):
        return f"error details{at or ''} are {json.dumps(got)[:120]}, not an object"
    for key, value in want.items():
        if key not in got:
            return f"error details have no {at}/{key}"
        if isinstance(value, dict):
            problem = details_problem(value, got[key], f"{at}/{key}")
            if problem:
                return problem
        elif got[key] != value:
            return f"error details {at}/{key} is {json.dumps(got[key])[:120]}, not {json.dumps(value)[:120]}"
    return None


def check_outcome(step: Mapping[str, Any], receipt: McpReceipt, replies: Mapping[str, Any]) -> None:
    """expect at the step's turn: outcome, typed error, error details, receipt kind. `expect.result` needs the
    canonical facet, so check_results compares it after the case."""
    expect = step.get("expect")
    if not expect:
        return
    step_id = step["id"]
    kind, detail = receipt.outcome
    if expect["outcome"] != kind or (kind == "error" and detail != expect.get("error")):
        got = f"error {detail}: {json.dumps(receipt.reply)[:300]}" if kind == "error" else "ok"
        want = expect["outcome"] + (f" {expect['error']}" if "error" in expect else "")
        raise CaseError("Failure", f"expected {want}, got {got}", step_id)
    if kind == "error":
        if "errorDetails" in expect:
            error = receipt.reply.get("error") if isinstance(receipt.reply, dict) else None
            want_details = resolve_refs(expect["errorDetails"], replies)
            problem = details_problem(want_details, error.get("details") if isinstance(error, dict) else None)
            if problem:
                raise CaseError("Failure", problem, step_id)
        return
    wanted = expect.get("receipt")
    if wanted == MUTATION_RESULT:
        if not (isinstance(detail, dict) and MUTATION_KEYS <= set(detail)):
            raise CaseError("Failure", f"expected a {MUTATION_RESULT} receipt, got {json.dumps(detail)[:200]}", step_id)
    elif wanted is not None:
        raise CaseError("Crash", f"receipt kind {wanted}: an mcp step's receipt is a tool result "
                                 f"({MUTATION_RESULT} for a daemon mutation, else noReceiptReason)", step_id)


def check_mcp_step(step: Mapping[str, Any]) -> None:
    """An mcp step's receipt is its settled checkpoint's mcp facet, so the step must keep that checkpoint."""
    if "settled" not in (step.get("checkpoint") or ["settled"]):
        raise CaseError("Crash", "an mcp step's receipt is the mcp facet of its settled checkpoint; its checkpoint "
                                 "list needs settled", step["id"])


def check_results(case: Mapping[str, Any], checkpoints: Sequence[Mapping[str, Any]]) -> Optional[CaseError]:
    """`expect.result` of each mcp step against the canonical mcp facet's result at its settled checkpoint."""
    facets = {cp["step"]: cp["snapshot"]["facets"].get(MCP_FACET) for cp in checkpoints
              if cp["checkpoint"] == "settled"}
    for step in case.get("steps") or ():
        expect = step.get("expect") or {}
        if step.get("op") != "mcp" or "result" not in expect:
            continue
        got = facets.get(step["id"])
        if not isinstance(got, dict) or "result" not in got:
            return CaseError("Crash", "expect.result: the step has no mcp facet", step["id"])
        if normalize.canonical_json(got["result"]) != normalize.canonical_json(expect["result"]):
            return CaseError("Failure", f"result differs: {normalize.canonical_json(got['result'])[:300]}",
                             step["id"])
    return None


def apply_results(case: Mapping[str, Any], result: Dict[str, Any]) -> Dict[str, Any]:
    if result["status"] == "Pass":
        failure = check_results(case, result["checkpoints"])
        if failure is not None:
            result.update(status=failure.status, message=failure.message, step=failure.step)
    return result


Serve = Callable[[str, float], CliOutput]


@dataclass
class McpSteps:
    """The mcp step runner both modes share: `serve(stdin, timeout)` runs one server session."""

    serve: Serve
    describe: str
    names: Mapping[str, str] = field(default_factory=dict)
    scale: float = 1.0
    receipts: Dict[str, Dict[str, Any]] = field(default_factory=dict)

    def run(self, step: Mapping[str, Any], replies: Dict[str, Any]) -> Tuple[str, Any]:
        step_id = step["id"]
        try:
            args = resolve_refs(step["args"], replies)
        except CaseError as error:
            raise CaseError(error.status, error.message, error.step or step_id) from None
        bound = MCP_S * self.scale
        try:
            output = self.serve(session_input(args["tool"], args.get("arguments") or {}), bound)
        except CliTimeout as error:
            raise CaseError("Timeout", str(error), step_id) from None
        except OSError as error:
            raise CaseError("Crash", f"cannot run {self.describe}: {error}", step_id) from None
        answer = call_answer(output.stdout.decode("utf-8", "replace"))
        if answer is None:
            raise CaseError("Crash", f"`cmux mcp serve` gave no tools/call answer (exit {output.exit}): "
                                     f"{driver_cli.stderr_tail(output.stderr)}", step_id)
        receipt = receipt_of(answer, self.names)
        replies[step_id] = receipt.reply
        self.receipts[step_id] = receipt.facet
        check_outcome(step, receipt, replies)
        return receipt.outcome

    def facet(self, step: str) -> Dict[str, Any]:
        receipt = self.receipts.get(step)
        if receipt is None:
            return not_comparable("the mcp facet is the receipt of an mcp step", "p15-oracle-209")
        return receipt


def with_receipt(names: Sequence[str], checkpoint: str, step: str, facet: str,
                 receipts: Mapping[str, Any]) -> Tuple[str, ...]:
    """The facets of a checkpoint: a receipt facet joins the settled checkpoint of its step."""
    names = tuple(names)
    if checkpoint == "settled" and step in receipts and facet not in names:
        names += (facet,)
    return names


def write_mcp_config(path: Path) -> Path:
    """The server's settings file (only mcp.enabled), written once per case."""
    if not path.exists():
        path.write_text(json.dumps(MCP_SETTINGS) + "\n", encoding="utf-8")
    return path


# ---------------------------------------------------------------------------------------------------------
# VM mode: driver_cli.py's case with an mcp op


class McpCaseRun(driver_cli.CliCaseRun):
    """driver_cli.py's case (hermetic daemon, resource.call, cli, I6 teardown) plus `mcp` steps. The server is a
    control client of the case daemon like a `cmux` call, so a step ends when every connection it opened has
    left session.clients (CliCaseRun.await_departure), woken by the daemon's client-detached events."""

    def __init__(self, binary: str, sha: str, schema: normalize.Schema, case: Mapping[str, Any],
                 ctx: Mapping[str, Any], session_ctx: Mapping[str, Any], isolation: Any):
        super().__init__(binary, sha, schema, case, ctx, session_ctx, isolation)
        self.mcp_config = self.paths.root / MCP_CONFIG
        env = {**self.case_env.env, "CMUX_NEXT_CONFIG_FILE": str(self.mcp_config)}
        runner = VmCli(CliBinary(Path(binary)), env, str(self.paths.home))
        self.mcp = McpSteps(lambda stdin, timeout: runner.run(list(SERVE_ARGV), stdin, timeout),
                            runner.describe(), {self.paths.session: SESSION_NAME}, self.scale)
        self.ops["mcp"] = self.op_mcp

    def run_step(self, index: int, step: Mapping[str, Any]) -> None:
        if step["op"] == "mcp":
            check_mcp_step(step)
        super().run_step(index, step)

    def op_mcp(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        step_id = step["id"]
        write_mcp_config(self.mcp_config)
        if not self.daemon.running:
            return self.mcp.run(step, self.state.replies)
        self.watch_clients(step_id)
        known = self.client_ids(step_id)
        before = self.daemon_facet(step_id) if step.get("readOnly") else None
        outcome = self.mcp.run(step, self.state.replies)
        self.await_departure(known, step_id)
        if before is not None:
            self.check_read_only(index, step_id, before)
        return outcome

    def check_expect(self, step: Mapping[str, Any], outcome: Tuple[str, Any]) -> None:
        # op_mcp checked an mcp step's expect against its receipt; check_results compares expect.result.
        if step["op"] != "mcp":
            super().check_expect(step, outcome)

    def capture(self, index: int, step: str, checkpoint: str, names: Sequence[str]) -> None:
        super().capture(index, step, checkpoint, with_receipt(names, checkpoint, step, MCP_FACET, self.mcp.receipts))

    def facets(self, names: Sequence[str], step: str) -> Dict[str, Any]:
        out = super().facets([name for name in names if name != MCP_FACET], step)
        if MCP_FACET in names:
            out[MCP_FACET] = self.mcp.facet(step)
        return out

    def snapshot(self, index: int, checkpoint: str, facets: Dict[str, Any]) -> Dict[str, Any]:
        value = super().snapshot(index, checkpoint, facets)
        value["meta"]["product"] = PRODUCT
        return value

    def run(self) -> Dict[str, Any]:
        return apply_results(self.case, super().run())


class McpSession(driver_cli.CliSession):
    """The VM session: driver_cli.py's session whose case workers run McpCaseRun (this file's case-worker)."""

    worker_script = Path(__file__).resolve()


def case_worker() -> int:
    """`case-worker`: one McpCaseRun from the JSON payload on stdin (driver_daemon's subreaper worker, so the
    server processes stay in the case's tree: I6)."""
    return driver_daemon.case_worker(McpCaseRun)


# ---------------------------------------------------------------------------------------------------------
# Fleet mode: driver_app.py's session, with the mcp and cli receipts kept


def fleet_cli_error(stderr: bytes) -> str:
    """The typed code of the bundle CLI's JSON error on stderr: dotted as is, an app control code as
    control.<code> (the app's control errors are bare), else cli.failed."""
    for line in reversed(stderr.decode("utf-8", "replace").splitlines()):
        try:
            value = json.loads(line.strip())
        except ValueError:
            continue
        if isinstance(value, dict):
            code = typed_code(value.get("error") if isinstance(value.get("error"), dict) else value)
            if code != TOOL_FAILED:
                return code
    return driver_cli.FALLBACK_ERROR


def fleet_classes() -> Tuple[type, type]:
    """(session, case) classes over driver_app.py, imported only for a fleet run."""
    import driver_app

    class McpAppCaseRun(driver_app.CaseRun):
        """driver_app.py's case whose mcp and cli steps keep their receipts as the mcp and cli facets."""

        def __init__(self, session: Any, case: Mapping[str, Any], ctx: Mapping[str, Any]):
            super().__init__(session, case, ctx)

            def serve(stdin: str, timeout: float) -> CliOutput:
                done = self.run_cli(list(SERVE_ARGV), stdin, self.at or "mcp")
                return CliOutput(done.returncode, done.stdout.encode("utf-8"), done.stderr.encode("utf-8"))

            self.mcp = McpSteps(serve, "the bundle's cmux mcp serve", {}, self.scale)
            self.cli_receipts: Dict[str, Dict[str, Any]] = {}

        def run_step(self, index: int, step: Mapping[str, Any]) -> None:
            if step["op"] == "mcp":
                check_mcp_step(step)
            elif step["op"] == "cli":
                driver_cli.check_cli_step(step)
            super().run_step(index, step)

        def op_mcp(self, index: int, step: Mapping[str, Any]) -> Tuple[Tuple[str, Any], Any]:
            return self.mcp.run(step, self.state.replies), "sync"

        def op_cli(self, index: int, step: Mapping[str, Any]) -> Tuple[Tuple[str, Any], Any]:
            step_id = step["id"]
            args = resolve_refs(step["args"], self.state.replies)
            done = self.run_cli(list(args["argv"]), args.get("stdin"), step_id)
            output = CliOutput(done.returncode, done.stdout.encode("utf-8"), done.stderr.encode("utf-8"))
            receipt, reply = driver_cli.receipt_of(output, {})
            if output.exit != 0:
                receipt["error"] = reply["error"] = fleet_cli_error(output.stderr)
            self.cli_receipts[step_id] = receipt
            self.state.replies[step_id] = reply
            outcome = driver_cli.outcome_of(receipt)
            driver_cli.check_outcome(step, outcome, receipt, driver_cli.stderr_tail(output.stderr))
            return outcome, "sync"

        def check_expect(self, step: Mapping[str, Any], outcome: Tuple[str, Any]) -> None:
            # The mcp and cli runners checked expect against the receipt; check_results compares expect.result.
            if step["op"] not in ("mcp", "cli"):
                super().check_expect(step, outcome)

        def capture(self, index: int, step: str, checkpoint: str, names: Sequence[str]) -> None:
            self.check_alive(step)
            values = self.app_facets(names, step)
            if checkpoint == "settled" and step in self.mcp.receipts:
                values[MCP_FACET] = self.mcp.receipts[step]
            if checkpoint == "settled" and step in self.cli_receipts:
                values[CLI_FACET] = self.cli_receipts[step]
            self.state.captures.append(driver_app.Capture(index, step, checkpoint,
                                                          self.snapshot(index, checkpoint, values)))

        def snapshot(self, index: int, checkpoint: str, facets: Dict[str, Any]) -> Dict[str, Any]:
            value = super().snapshot(index, checkpoint, facets)
            value["meta"]["product"] = PRODUCT
            return value

        def run(self) -> Dict[str, Any]:
            result = apply_results(self.case, super().run())
            return driver_cli.apply_results(self.case, result)

    class McpAppSession(driver_app.AppSession):
        """driver_app.py's session (one bench launch for up to --batch-limit cases) running McpAppCaseRun."""

        case_class = McpAppCaseRun

    return McpAppSession, McpAppCaseRun


def is_app_bundle(binary: Any) -> bool:
    return isinstance(binary, str) and binary.rstrip("/").endswith(".app")


def open_session(session_ctx: Dict[str, Any]) -> Any:
    """Fleet mode for a tagged app bundle, VM mode for a cmux-tui binary."""
    binary = session_ctx.get("binary")
    if not binary:
        raise ValueError("the mcp driver needs --binary: the cmux-tui linux_run.sh built at the run SHA (VM) or a "
                         "tagged \"cmux DEV <tag>.app\" (fleet)")
    if is_app_bundle(binary):
        session_class, _ = fleet_classes()
        return session_class(session_ctx)
    return McpSession(session_ctx)


# ---------------------------------------------------------------------------------------------------------
# The tool list


def tool_entry(tool: Mapping[str, Any]) -> Dict[str, Any]:
    """What gen_mcp.py reads of one tools/list descriptor: its name, hints and arguments."""
    schema = tool.get("inputSchema") or {}
    hints = tool.get("annotations") or {}
    return {"name": tool["name"], "readOnly": hints.get("readOnlyHint") is True,
            "destructive": hints.get("destructiveHint") is True,
            "arguments": sorted((schema.get("properties") or {})), "required": sorted(schema.get("required") or ())}


def tools_document(listing: Mapping[str, Any]) -> Dict[str, Any]:
    """`cmux --json mcp tools` as the checked-in _tools.json: sorted, without descriptions."""
    return {
        "$comment": "`cmux --json mcp tools` of the daemon build (driver_mcp.py tools); gen_mcp.py reads it",
        "count": listing["count"],
        "app_actions": listing.get("app_actions") is True,
        "tools": sorted((tool_entry(t) for t in listing["tools"]), key=lambda t: t["name"]),
        "excluded": sorted(({"kind": e["kind"], "name": e["name"]} for e in listing.get("excluded") or ()),
                           key=lambda e: (e["kind"], e["name"])),
    }


def list_tools(binary: Path, timeout: float = MCP_S) -> Dict[str, Any]:
    """The tool list of a cmux-tui with no app and no daemon reachable (a scratch HOME and config)."""
    with tempfile.TemporaryDirectory(prefix="mcp-tools-") as scratch:
        env = {"PATH": "/usr/bin:/bin", "HOME": scratch, "XDG_RUNTIME_DIR": scratch, "TMPDIR": scratch,
               "CMUX_NEXT_CONFIG_FILE": str(write_mcp_config(Path(scratch) / MCP_CONFIG)),
               "CMUX_TUI_SOCKET": str(Path(scratch) / "none.sock")}
        output = VmCli(CliBinary(binary), env, scratch).run(list(TOOLS_ARGV), None, timeout)
    if output.exit != 0:
        raise ValueError(f"cmux mcp tools exited {output.exit}: {driver_cli.stderr_tail(output.stderr)}")
    return tools_document(json.loads(output.stdout))


# ---------------------------------------------------------------------------------------------------------
# Parity


@dataclass(frozen=True)
class Checkpoint:
    index: int
    snapshot: Dict[str, Any]


Runs = Dict[Tuple[str, str, str], Checkpoint]


def load_run(run_dir: Path) -> Runs:
    """(case id, step, checkpoint) -> the step's index and canonical snapshot, from a run dir's checkpoints.jsonl."""
    out: Runs = {}
    path = run_dir / "checkpoints.jsonl"
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        case = row["case"] if "/" in row["case"] else f"{row['suite']}/{row['case']}"
        out[(case, row["step"], row["checkpoint"])] = Checkpoint(int(row["index"]), row["snapshot"])
    return out


def load_results(run_dir: Path) -> Dict[str, str]:
    receipt = json.loads((run_dir / "receipt.json").read_text(encoding="utf-8"))
    return {case: info.get("result") or info.get("outcome") for case, info in (receipt.get("cases") or {}).items()}


def flat(value: Any, at: str = "") -> Dict[str, Any]:
    """Every leaf of `value` by its RFC 6901 pointer; an empty object or array is a leaf."""
    if isinstance(value, dict) and value:
        out: Dict[str, Any] = {}
        for key, item in value.items():
            out.update(flat(item, f"{at}/{str(key).replace('~', '~0').replace('/', '~1')}"))
        return out
    if isinstance(value, list) and value:
        out = {}
        for index, item in enumerate(value):
            out.update(flat(item, f"{at}/{index}"))
        return out
    return {at: value}


@dataclass(frozen=True)
class Reason:
    pointer: str
    reason: str
    tools: Tuple[str, ...] = ()
    at: Tuple[str, ...] = ()

    def covers(self, pointer: str, tool: str, at: str = "") -> bool:
        if self.tools and tool not in self.tools:
            return False
        if self.at and not any(fnmatch.fnmatchcase(at, pattern) for pattern in self.at):
            return False
        pattern = self.pointer.split("/")
        parts = pointer.split("/")
        if len(parts) < len(pattern):
            return False
        return all(p == "*" or fnmatch.fnmatchcase(q, p) for p, q in zip(pattern, parts))

    def masks_facet(self, facet: str, tool: str, at: str) -> bool:
        """The reason covers the whole facet at this checkpoint: nothing in it is compared there."""
        return self.pointer.count("/") == 1 and self.covers(f"/{facet}", tool, at)


def load_reasons(path: Path = PARITY_FILE) -> List[Reason]:
    """_parity.json: the reasoned differences, each a pointer pattern (`*` per segment; a prefix covers its
    subtree), its reason and, optionally, the tools and the `step/checkpoint` patterns it applies to."""
    doc = json.loads(path.read_text(encoding="utf-8"))
    out = []
    for item in doc.get("differences") or ():
        if not (isinstance(item.get("pointer"), str) and item["pointer"].startswith("/")
                and isinstance(item.get("reason"), str) and len(item["reason"]) >= 20):
            raise ValueError(f"{path}: {item!r} needs a pointer and a reason")
        out.append(Reason(item["pointer"], item["reason"], tuple(item.get("tools") or ()), tuple(item.get("at") or ())))
    return out


def compared_facets(snapshot: Mapping[str, Any]) -> Dict[str, Any]:
    return {name: value for name, value in (snapshot.get("facets") or {}).items() if name not in RECEIPT_FACETS}


def compare_pair(pair: Mapping[str, Any], runs: Runs, reasons: Sequence[Reason]) -> Dict[str, Any]:
    """One pair's verdict: the checkpoints compared, the unreasoned and the reasoned differences. Only the
    checkpoints from the entry step on are the entrypoint's: every step before it is the same in both cases, so
    a difference there is the case's own flake (`before_entry`, counted and never a parity divergence), as a CQ
    failure that also fails without the patch is not the CL's (base/test/launcher/test_launcher.cc retries). A
    checkpoint where reasons cover every compared facet whole compares nothing: it counts as `masked`, not as a
    compared checkpoint."""
    mcp, twin, tool = pair["mcp"], pair["twin"], pair.get("tool", "")
    keys = sorted({(step, cp) for (case, step, cp) in runs if case == mcp} &
                  {(step, cp) for (case, step, cp) in runs if case == twin},
                  key=lambda key: (runs[(mcp, *key)].index, key[1]))
    entry = runs.get((mcp, pair.get("step", ""), "settled")) or runs.get((mcp, pair.get("step", ""), "before"))
    first = entry.index if entry is not None else 0
    out: Dict[str, Any] = {"mcp": mcp, "twin": twin, "tool": tool, "checkpoints": 0, "masked": 0,
                           "differences": [], "reasoned": [], "before_entry": 0}
    for step, checkpoint in keys:
        index = runs[(mcp, step, checkpoint)].index
        a = flat(compared_facets(runs[(mcp, step, checkpoint)].snapshot))
        b = flat(compared_facets(runs[(twin, step, checkpoint)].snapshot))
        if index < first:
            out["before_entry"] += sum(1 for pointer in set(a) | set(b) if a.get(pointer, MISSING) != b.get(pointer, MISSING))
            continue
        at = f"{step}/{checkpoint}"
        facets = {pointer.split("/")[1] for pointer in set(a) | set(b)}
        if facets and all(any(r.masks_facet(facet, tool, at) for r in reasons) for facet in facets):
            out["masked"] += 1
            continue
        out["checkpoints"] += 1
        for pointer in sorted(set(a) | set(b)):
            left, right = a.get(pointer, MISSING), b.get(pointer, MISSING)
            if left == right:
                continue
            row = {"at": at, "pointer": pointer,
                   "mcp": None if left is MISSING else left, "twin": None if right is MISSING else right}
            reason = next((r for r in reasons if r.covers(pointer, tool, at)), None)
            if reason is None:
                out["differences"].append(row)
            else:
                out["reasoned"].append({**row, "reason": reason.reason})
    return out


def parity(run_dirs: Sequence[Path], coverage: Mapping[str, Any], reasons: Sequence[Reason]) -> Dict[str, Any]:
    runs: Runs = {}
    results: Dict[str, str] = {}
    for run_dir in run_dirs:
        runs.update(load_run(run_dir))
        results.update(load_results(run_dir))
    pairs, not_compared = [], []
    for pair in coverage.get("parity") or ():
        mcp, twin = results.get(pair["mcp"]), results.get(pair["twin"])
        if mcp != twin:
            # One entrypoint passed and the other did not, they failed differently, or one side did not run.
            pairs.append({**pair, "result": {"mcp": mcp, "twin": twin}, "differences": [], "reasoned": []})
            continue
        if mcp != "Pass":
            not_compared.append({**pair, "why": f"both results {mcp}"})
            continue
        verdict = compare_pair(pair, runs, reasons)
        if verdict["checkpoints"] == 0:
            why = ("every checkpoint from the entry step on is masked whole by _parity.json" if verdict["masked"]
                   else "no checkpoint in both runs")
            not_compared.append({**pair, "why": why})
            continue
        pairs.append(verdict)
    divergent = [p for p in pairs if p["differences"] or "result" in p]
    return {"compared": len(pairs), "divergent": len(divergent), "not_compared": not_compared,
            "reasoned": sum(len(p["reasoned"]) for p in pairs),
            "pairs": divergent + [p for p in pairs if p["reasoned"] and p not in divergent]}


# ---------------------------------------------------------------------------------------------------------
# CLI


def cmd_run_case(args: argparse.Namespace) -> int:
    case = json.loads(Path(args.case).read_text(encoding="utf-8"))
    run_id = args.run_id or f"mcp-{os.getpid()}-{time.time_ns()}"
    ctx: Dict[str, Any] = {"binary": args.binary, "run_id": run_id, "ref": args.ref, "isolation": args.isolation}
    session = open_session(ctx)
    base = args.state_base / short_token(run_id)
    case_ctx = {"case_id": f"{case['suite']}/{case['id']}", "key": "0",
                "state_root": str(base / short_token(case["id"]))}
    try:
        result = session.run_case(case, case_ctx)
    finally:
        session.close()
        remove_empty_dir(base)
    print(json.dumps(result, indent=1, sort_keys=True))
    return 0 if result["status"] == "Pass" else 1


def cmd_tools(args: argparse.Namespace) -> int:
    document = list_tools(Path(args.binary))
    text = json.dumps(document, indent=1, sort_keys=True) + "\n"
    if args.check:
        checked = Path(args.check).read_text(encoding="utf-8")
        if checked != text:
            print(f"driver_mcp.py: {args.check} differs from {args.binary}'s tool list; run `driver_mcp.py tools "
                  f"--binary BIN --out {args.check}`, then gen_mcp.py", file=sys.stderr)
            return 1
        print(f"{document['count']} tools, as {args.check} lists")
        return 0
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


def cmd_parity(args: argparse.Namespace) -> int:
    coverage = json.loads(Path(args.coverage).read_text(encoding="utf-8"))
    report = parity([Path(d) for d in args.run_dir], coverage, load_reasons(Path(args.reasons)))
    print(json.dumps(report, indent=1, sort_keys=True))
    return 0 if report["compared"] and not report["divergent"] else 1


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("case-worker", help="internal: one case from a JSON payload on stdin (McpSession)")
    run_case = sub.add_parser("run-case", help="one case; its result JSON")
    run_case.add_argument("case", help="a case-v1 JSON file")
    run_case.add_argument("--binary", required=True, help="the cmux-tui of the run SHA (VM) or a tagged app (fleet)")
    run_case.add_argument("--ref", help="the run SHA; the VM binary's build receipt must name it")
    run_case.add_argument("--isolation", default="netns", help="VM case isolation: netns, auto or none")
    run_case.add_argument("--state-base", type=Path, default=DEFAULT_STATE_BASE)
    run_case.add_argument("--run-id")
    tools = sub.add_parser("tools", help="the server's tool list as _tools.json")
    tools.add_argument("--binary", required=True)
    group = tools.add_mutually_exclusive_group()
    group.add_argument("--out", help="write the list here")
    group.add_argument("--check", help="exit 1 when this file differs from the binary's list")
    check = sub.add_parser("parity", help="MCP vs twin settled snapshots of finished runs")
    check.add_argument("run_dir", nargs="+", help="oracle.py run dirs that hold both cases of each pair")
    check.add_argument("--coverage", default=str(COVERAGE_FILE))
    check.add_argument("--reasons", default=str(PARITY_FILE))
    args = parser.parse_args(argv)
    if args.command == "case-worker":
        return case_worker()
    try:
        if args.command == "run-case":
            return cmd_run_case(args)
        if args.command == "tools":
            return cmd_tools(args)
        return cmd_parity(args)
    except ValueError as error:
        print(f"driver_mcp.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
