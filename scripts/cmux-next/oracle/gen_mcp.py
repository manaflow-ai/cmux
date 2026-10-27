#!/usr/bin/env python3
"""Generate the mcp suite: a case per tool `cmux mcp serve --all-tools` offers, and MCP-vs-twin parity pairs.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3D (suite mcp) and 3F.4 (product parity mcp vs cli),
task 209. Stdlib plus the sibling generators it reuses, Python 3.9+, safe under `python3 -I`. `oracle.py gen
--suite mcp` runs it with `--out <corpus>/mcp`. driver_mcp.py runs the cases (VM: `oracle.py run --product mcp
--suite mcp,daemon-ops`; fleet: the same with a tagged app's `--binary`) and `driver_mcp.py parity` compares the
pairs.

Chrome reference (chromium/src): third_party/blink/web_tests/external/wpt runs one test against several products
(third_party/blink/tools/run_wpt_tests.py --product), so a difference between two products is a difference in one
test's result; and third_party/blink/web_tests/VirtualTestSuites runs one directory again with other arguments,
keeping the base test as the reference. Here one generated step runs through the MCP entrypoint and its twin runs
the same steps through the resource API or the CLI.

The tool list is `_tools.json`: `cmux --json mcp tools` of a daemon build with no app (driver_mcp.py tools; a VM
check run compares it with the build). Each tool gets cases by its kind:

- a daemon mutation (`<op>` of cmux-tui/spec/resource-operations-v2.json, class mutation): the daemon-ops
  suite's `<op>-ok` and `<op>-error` cases (gen_daemon_ops.py, with their family tunings) with the step `call` sent
  as the MCP tool, its selectors, params and idempotency key as the tool's arguments. Every other step, the
  fixture seed and the idempotent `retry` (a resource.call with the call's key: invariant I10 holds the MCP
  call's reply to it) stay, so each case pairs with its daemon-ops twin step for step.
- a daemon read: `<op>-read`, the read on gen_daemon_ops.py's standard fixture (a terminal's content read on a
  terminal whose command printed one fixed text and then waits on its input, so its screen does not depend on a
  shell's start), then the
  same read as a resource.call whose `expect.result` is the MCP result (its `items` for an array): the MCP
  receipt and the resource API's reply are one value.
- any other tool (EXTRA_TOOLS): a VM case where the daemon alone answers it (a success, or the typed refusal a
  daemon with no app, acpmux or browser host gives), a fleet case where it needs the app, and the reason for
  each path no product can run yet.
- an app action the app offers to MCP (`app_<cli words>`): from the actions suite's case (gen_actions.py, its
  setup and family tuning), `<action>-mcp` runs the action as the MCP tool and `<action>-cli` as its `cmux` verb;
  the pair runs on the fleet. From the action-surfaces.json export every action is blocked as gen_actions.py
  blocks it (no live catalog).

A case no product can run yet is written whole into `_blocked.json` with its reason (oracle.py skips `_` files);
`coverage.json` lists every tool and every MCP-offered action with its cases or its reason (and, for `oracle.py
check --coverage`, their `total`, `covered`, `excluded` with the reason and `missing`), and `parity` the
pairs driver_mcp.py compares. `_parity.json` (hand-written, read here) gives each known MCP-vs-twin difference a
reason; gen refuses an entry without one.

Usage:
  gen_mcp.py --out DIR          write the cases, _blocked.json and coverage.json into DIR
  gen_mcp.py --out DIR --check  exit 1 when DIR differs from a fresh generation
  gen_mcp.py --selftest         offline tests
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import shutil
import sys
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import gen_actions  # noqa: E402  (the actions suite: setup, tuning, blocks)
import gen_daemon_ops  # noqa: E402  (the daemon-ops suite: fixture, request synthesis)

SUITE = "mcp"
GENERATOR = "scripts/cmux-next/oracle/gen_mcp.py"
CORPUS = REPO / "tests" / "oracle" / "corpus"
DEFAULT_OUT = CORPUS / SUITE
DAEMON_OPS = CORPUS / "daemon-ops"
ACTIONS = CORPUS / "actions"
CATALOG = REPO / "cmux-tui" / "spec" / "resource-operations-v2.json"
SURFACES = REPO / "plans" / "cmux-next" / "action-surfaces.json"
TOOLS = "_tools.json"
PARITY = "_parity.json"
BLOCKED = "_blocked.json"
COVERAGE = "coverage.json"
INPUTS = (TOOLS, PARITY)
SCHEMA_REF = "../../../../schemas/oracle/case-v1.schema.json"
SCOPE = gen_daemon_ops.SCOPE
CALL = gen_daemon_ops.CALL_STEP
# A VM case runs on the Linux daemon; the mcp product on a Mac is the tagged app (driver_mcp.py fleet mode).
VM_PLATFORMS = ["linux"]
FLEET_PLATFORMS = ["mac"]
VM_REQUIRES = ["resource_api", "mcp"]
FLEET_REQUIRES = ["mcp"]
# What the mcp product cannot give (oracle.py PRODUCTS["mcp"]): a case that needs one is blocked.
PRODUCT_CAPABILITIES = frozenset({"resource_api", "actions", "mcp", "restart"})
CAPABILITY_GAPS = {
    "chromium": "a daemon-rendered browser needs a cmux-browser provider, which the VM daemon has none of (the mcp "
                "product has no chromium capability, oracle.py PRODUCTS)",
    "git_repo": "no product builds fixture.repo yet (p15-oracle-243)",
    "keys": "the mcp product sends no keystrokes (oracle.py PRODUCTS)",
    "gui": "the mcp product has no gui capability (oracle.py PRODUCTS)",
    "tui": "the mcp product runs no TUI (oracle.py PRODUCTS)",
}
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
TOOL_NAME = re.compile(r"^[a-z][a-z0-9_]{0,63}$")

READ_RECEIPT_NOTE = ("the read again through the resource API: its reply is the MCP result (an array read's items), "
                     "so the MCP receipt is the daemon's own value")
ACTION_NO_RECEIPT = ("an app action's tool result is the action.run reply, which names no ActionEffect kind yet "
                     "(driver_app.py)")
VM_PRECONDITIONS = ["hermetic state root", "no other cmux-tui on the state root",
                    "the MCP server's own settings file turns it on (driver_mcp.py MCP_CONFIG)"]
FLEET_PRECONDITIONS = ["a fresh driver_app.py session: bench config with mcp.enabled, animations off",
                       "the launch's first workspace is shown with its terminal focused"]

# Terminal reads run on a terminal whose command printed a fixed text and then waits on its input (`exec cat`),
# so its screen, history and output are the same on every run (a shell draws its prompt when it gets to it) and
# nothing in the daemon facet moves after the text is there. A terminal.wait for the text holds the case until
# then.
PRINTED = "fx-printed"
PRINTED_SEEN = "fx-printed-seen"
TERMINAL_COMMAND = {"argv": ["/bin/sh", "-c", "printf oracle; exec cat"]}
TERMINAL_WAIT_MS = "10000"
TERMINAL_REF = f"$step:{PRINTED}#/value/terminal_id"
# Reads whose fields need a value the read can meet on that terminal; wait_exit on a running command times out
# at once (its reply says so).
READ_PARAMS: Dict[str, Dict[str, Any]] = {
    "terminal.wait": {"pattern": "oracle", "timeout_ms": TERMINAL_WAIT_MS},
    "terminal.wait_exit": {"timeout_ms": "1"},
}
# machine.get names its machine (v2_tools.rs selector_argument); no other tool takes a scope selector.
MACHINE_ARGUMENT = {"machine.get": ("machine",)}
# A read needs no engine: a daemon-rendered browser (fx-browser, chromium) is swapped for the app-drawn one.
READ_HANDLES = {"browser": "app_browser", "browser_tab": "app_browser_tab"}


@dataclass(frozen=True)
class Extra:
    """How a tool that is no daemon operation and no app action is covered. `vm`: the VM case's arguments,
    expected typed error (None: success), fixture handles and whether it changes state; `fleet`: the fleet
    case's arguments, or None; `gap`: why the path with no case cannot run yet."""

    vm: Optional[Dict[str, Any]] = None
    error: Optional[str] = None
    fixture: Tuple[str, ...] = ()
    mutation: bool = False
    fleet: Optional[Dict[str, Any]] = None
    gap: str = ""
    note: str = ""


NO_APP = "app.not_found"
NO_ACPMUX = "acpmux.transport"
NO_BROWSER_HOST = "browser_host.unavailable"
ACPMUX_GAP = ("its success needs an acpmux daemon with a harness; the oracle starts none (mock_chief.py serves the "
              "Chief only)")
BROWSER_HOST_GAP = ("its success needs `cmux-browser-host serve` (a Chromium host), which neither the VM nor the "
                    "bench launch starts for a case")
WS_REF = "$step:fx-workspace#/value/workspace_id"
PANE_REF = "$step:fx-workspace#/value/pane_id"
TAB_REF = "$step:fx-workspace#/value/tab_id"
EXTRA_TOOLS: Dict[str, Extra] = {
    "energy_status": Extra(vm={}, fleet={}, note="the daemon's energy state; the app half says no app answers"),
    "agents_snapshot": Extra(vm={}, fixture=("workspace",), fleet={}),
    "agents_terminal_list": Extra(vm={}, fixture=("workspace",), note="the fixture workspace's terminal"),
    "agents_doctor": Extra(vm={"checks": ["harness.claude"]},
                           note="one check: the hermetic PATH has no harness, so the finding is fixed"),
    "agents_events": Extra(vm={"timeout_seconds": 0}, fixture=("workspace",),
                           note="no wait: the events after the fixture, then timed_out"),
    "agents_wait": Extra(vm={"until": "idle"}, error="validation.invalid",
                         gap="its success waits on an agent's terminal: the mock agent pane is the fleet's",
                         note="until idle needs a target: refused before any wait"),
    "agents_workspace_create": Extra(vm={"name": "oracle", "empty": True,
                                         "idempotency_key": "mcp.agents-workspace-create"}, mutation=True,
                                     note="the composite surface's create: the daemon's workspace.create"),
    "agents_workspace_select": Extra(vm={"workspace": WS_REF, "idempotency_key": "mcp.agents-workspace-select"},
                                     fixture=("workspace",), mutation=True),
    "agents_terminal_split": Extra(vm={"direction": "right", "pane": PANE_REF,
                                       "idempotency_key": "mcp.agents-terminal-split"},
                                   fixture=("workspace",), mutation=True),
    "agents_tab_select": Extra(vm={"tab": TAB_REF, "idempotency_key": "mcp.agents-tab-select"},
                               fixture=("workspace",), mutation=True),
    "agents_terminal_focus": Extra(vm={"tab": TAB_REF, "idempotency_key": "mcp.agents-terminal-focus"},
                                   fixture=("workspace",), mutation=True),
    "agents_terminal_send": Extra(vm={"target": "term_" + "0" * 32, "text": "oracle"}, error="selector.not_found",
                                  mutation=True,
                                  gap="its success types into a live shell, whose screen depends on the shell's "
                                      "start; terminal_input_write covers the write on the fixed-output terminal",
                                  note="no such terminal: refused before any input"),
    "agents_palette_open": Extra(vm={"idempotency_key": "mcp.agents-palette-open"}, error=NO_APP, mutation=True,
                                 gap="its success opens the app's palette, which app_reset.py has no close for"),
    "agents_dialog_list": Extra(vm={}, error=NO_APP, fleet={}),
    "agents_dialog_answer": Extra(vm={"request_id": "oracle", "mode": "deny"}, error=NO_APP, mutation=True,
                                  gap="its success answers a pending agent dialog, which no fixture raises"),
    "agents_chat_read": Extra(vm={"target": "oracle"}, error="selector.not_found", gap=ACPMUX_GAP),
    "agents_chat_send": Extra(vm={"target": "oracle", "text": "oracle", "idempotency_key": "mcp.agents-chat-send"},
                              error="selector.not_found", mutation=True, gap=ACPMUX_GAP),
    "agent_briefs_list": Extra(vm={}, error=NO_ACPMUX, gap=ACPMUX_GAP),
    "agent_dispatch": Extra(vm={"brief": "oracle", "target": "oracle", "title": "oracle",
                                "idempotency_key": "mcp.agent-dispatch"}, error=NO_ACPMUX, mutation=True,
                            gap=ACPMUX_GAP),
    "agent_steer": Extra(vm={"brief_id": "oracle", "text": "oracle", "idempotency_key": "mcp.agent-steer"},
                         error=NO_ACPMUX, mutation=True, gap=ACPMUX_GAP),
    "agent_report": Extra(gap="it reports a dispatched brief's state: only an agent acpmux started has a brief "
                              "to report on; " + ACPMUX_GAP),
    "browser_repl_list": Extra(vm={}, error=NO_BROWSER_HOST, gap=BROWSER_HOST_GAP),
    "browser_repl_guide": Extra(vm={}, error=NO_BROWSER_HOST, gap=BROWSER_HOST_GAP),
    "browser_repl_open": Extra(vm={}, error=NO_BROWSER_HOST, mutation=True, gap=BROWSER_HOST_GAP),
    "browser_repl_eval": Extra(vm={"code": "1"}, error=NO_BROWSER_HOST, mutation=True, gap=BROWSER_HOST_GAP),
    "browser_repl_close": Extra(vm={"session": "oracle"}, error=NO_BROWSER_HOST, mutation=True, gap=BROWSER_HOST_GAP),
    "browser_repl_reset": Extra(vm={"session": "oracle"}, error=NO_BROWSER_HOST, mutation=True, gap=BROWSER_HOST_GAP),
    "window_list": Extra(vm={}, error=NO_APP, fleet={}),
    "keybinding_list": Extra(vm={}, error=NO_APP, fleet={}),
    "keybinding_resolve": Extra(vm={"keys": "cmd+t"}, error=NO_APP, fleet={"keys": "cmd+t"}),
    "context_keys": Extra(vm={}, error=NO_APP, fleet={}),
    "render": Extra(gap="its reply's card id is random per call (cli/mcp/render_tool.rs) and no x-oracle-id-patterns "
                        "entry labels it, so its receipt differs on every run until ids are seeded (p15-oracle-185)"),
}


class GenError(Exception):
    """The tool list, a sibling suite or the parity reasons cannot make the suite."""


# ------------------------------------------------------------------------------------------------ inputs


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise GenError(f"{path}: {error}") from None


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Tools:
    """_tools.json: each tool's name, hints and argument names."""

    def __init__(self, path: Path):
        self.path = path
        doc = load_json(path)
        self.sha256 = sha256(path)
        try:
            self.by_name = {t["name"]: t for t in doc["tools"]}
            self.excluded = {(e["kind"], e["name"]) for e in doc["excluded"]}
        except (KeyError, TypeError) as error:
            raise GenError(f"{path}: not driver_mcp.py's tool list: {error!r}") from None
        bad = sorted(n for n in self.by_name if not TOOL_NAME.match(n))
        if bad:
            raise GenError(f"{path}: tool names {bad[:5]} are not MCP tool names")


def check_parity_reasons(path: Path) -> Dict[str, Any]:
    """_parity.json: each difference a pointer pattern and a reason (driver_mcp.load_reasons reads it)."""
    doc = load_json(path)
    for index, item in enumerate(doc.get("differences") or ()):
        where = f"{path.name} differences[{index}]"
        if not (isinstance(item, dict) and isinstance(item.get("pointer"), str) and item["pointer"].startswith("/")):
            raise GenError(f"{where}: needs a JSON pointer pattern")
        if not (isinstance(item.get("reason"), str) and len(item["reason"]) >= 20):
            raise GenError(f"{where}: needs a reason (20 characters or more)")
        unknown = sorted(set(item) - {"pointer", "reason", "tools", "at"})
        if unknown:
            raise GenError(f"{where}: unknown keys {unknown}")
    return doc


def tool_name_of_action(cli_name: str) -> Optional[str]:
    """cli/mcp/action_tools.rs tool_name: `app_` and the CLI name's words (`app new-window` is app_new_window)."""
    words = cli_name.split()
    if words[:1] == ["app"]:
        words = words[1:]
    name = "app"
    for word in words:
        name += "_"
        for character in word:
            if character.isascii() and (character.islower() or character.isdigit()):
                name += character
            elif character.isascii() and character.isupper():
                name += character.lower()
            elif character in "-_.":
                name += "_"
            else:
                return None
    return name if len("app_") < len(name) <= 64 else None


def kebab(name: str) -> str:
    """An action argument's CLI flag: the camelCase name in kebab case (cli/app.rs argument_name reverses it)."""
    return re.sub(r"([A-Z])", lambda m: "-" + m.group(1).lower(), name)


# ------------------------------------------------------------------------------------------------ cases


def case_shell(case_id: str, title: str, *, surface: str, fixture: Mapping[str, Any], requires: Sequence[str],
               platforms: Sequence[str], steps: List[Dict[str, Any]], invariants: List[str],
               preconditions: Sequence[str], teardown: Sequence[str], **extra: Any) -> Dict[str, Any]:
    doc: Dict[str, Any] = {
        "$schema": SCHEMA_REF, "corpusVersion": 1, "id": case_id, "suite": SUITE, "title": title[:200],
        "surface": surface, "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        "environment": {}, "fixture": dict(fixture), "preconditions": list(preconditions),
        "requires": list(dict.fromkeys(requires)), "platforms": list(platforms)}
    for key in ("switches", "allow_crashes"):
        if extra.get(key):
            doc[key] = copy.deepcopy(extra[key])
    doc.update({"steps": steps, "invariants": invariants, "teardown": list(teardown)})
    if extra.get("untested"):
        doc["untested"] = list(extra["untested"])
    return doc


def capability_gap(requires: Sequence[str]) -> Optional[str]:
    missing = [cap for cap in requires if cap not in PRODUCT_CAPABILITIES]
    return "; ".join(CAPABILITY_GAPS.get(cap, f"the mcp product has no {cap}") for cap in missing) or None


def tool_arguments(target: Mapping[str, Any], params: Mapping[str, Any], key: Optional[str], tool: str,
                   scope_arguments: Sequence[str] = ()) -> Dict[str, Any]:
    """A v2 tool's arguments: the call's selectors, its params, its key. The machine and session scope is the
    server's own (v2_tools.rs sends `current`), but for a scope selector the tool takes (`machine` of machine_get)."""
    arguments = {name: value for name, value in target.items() if name not in SCOPE or name in scope_arguments}
    clash = sorted(set(arguments) & set(params))
    if clash:
        raise GenError(f"{tool}: {clash} is both a selector and a param")
    arguments.update(params)
    if key:
        arguments["idempotency_key"] = key
    return arguments


def unknown_arguments(arguments: Mapping[str, Any], entry: Mapping[str, Any]) -> List[str]:
    return sorted(set(arguments) - set(entry["arguments"]))


def mcp_step(step_id: str, tool: str, arguments: Mapping[str, Any], *, target: Optional[Mapping[str, Any]],
             expect: Mapping[str, Any], read_only: bool, checkpoint: Sequence[str] = ("before", "settled"),
             **extra: Any) -> Dict[str, Any]:
    step: Dict[str, Any] = {"id": step_id, "op": "mcp"}
    if target:
        step["target"] = dict(target)
    step["args"] = {"tool": tool, "arguments": dict(arguments)}
    if read_only:
        step["readOnly"] = True
    step["expect"] = dict(expect)
    for key in ("waitFor", "settleMaxMs"):
        if key in extra:
            step[key] = copy.deepcopy(extra[key])
    step["checkpoint"] = list(checkpoint)
    if extra.get("note"):
        step["note"] = extra["note"]
    return step


@dataclass
class Out:
    """What generation makes: case files, blocked cases, per-tool and per-action coverage, parity pairs."""

    files: Dict[str, Any]
    blocked: Dict[str, Any]
    tools: Dict[str, Any]
    actions: Dict[str, Any]
    parity: List[Dict[str, str]]

    def add(self, case: Dict[str, Any], reason: Optional[str], owner: str) -> str:
        name = case["id"]
        if not SLUG.match(name):
            raise GenError(f"{owner}: case id {name!r} is not a case-v1 slug")
        if f"{name}.json" in self.files or name in self.blocked:
            raise GenError(f"{owner}: case id {name!r} is made twice")
        if reason:
            case.setdefault("untested", []).insert(0, f"blocked: {reason}")
            self.blocked[name] = {"owner": owner, "reason": reason, "case": case}
        else:
            self.files[f"{name}.json"] = case
        return f"{SUITE}/{name}"


# -- daemon mutations: the daemon-ops cases with the call through MCP


def from_daemon_ops(source: Mapping[str, Any], tool: str, entry: Mapping[str, Any]) -> Tuple[Dict[str, Any], Optional[str]]:
    """The daemon-ops case with its `call` step as the MCP tool, and why it cannot run (or None)."""
    case = copy.deepcopy(dict(source))
    steps = case["steps"]
    index = next((i for i, step in enumerate(steps) if step["id"] == CALL), None)
    if index is None or steps[index]["op"] != "resource.call":
        raise GenError(f"daemon-ops/{source['id']}: no resource.call step {CALL}")
    call = steps[index]
    reasons = []
    if call.get("ends"):
        reasons.append(f"the call ends the {call['ends']}; no MCP tool ends a process")
    arguments = tool_arguments(call.get("target") or {}, call["args"].get("params") or {},
                               call["args"].get("idempotencyKey"), tool)
    unknown = unknown_arguments(arguments, entry)
    if unknown:
        reasons.append(f"{tool} takes no argument {', '.join(unknown)} (its input schema, _tools.json)")
    extra = {key: call[key] for key in ("waitFor", "settleMaxMs") if key in call}
    note = f"the daemon-ops call as the MCP tool {tool}" + (f"; {call['note']}" if call.get("note") else "")
    steps[index] = mcp_step(CALL, tool, arguments, target=call.get("target"), expect=call["expect"],
                            read_only=bool(call.get("readOnly")), checkpoint=call.get("checkpoint") or ["settled"],
                            note=note, **extra)
    requires = [*case["requires"], "mcp"]
    gap = capability_gap(requires)
    if gap:
        reasons.append(gap)
    doc = case_shell(
        source["id"], f"{tool}: {source['title']}", surface=source.get("surface", "cmux-next-daemon"),
        fixture=source["fixture"], requires=requires, platforms=VM_PLATFORMS, steps=steps,
        invariants=[f"generated by {GENERATOR} from daemon-ops/{source['id']} (its twin: the same steps, the call "
                    f"through the resource API)", *source.get("invariants", [])],
        preconditions=[*source.get("preconditions", []), VM_PRECONDITIONS[2]], teardown=source["teardown"],
        switches=source.get("switches"), allow_crashes=source.get("allow_crashes"), untested=source.get("untested"))
    return doc, "; ".join(reasons) or None


# -- daemon reads: the standard fixture, the read through MCP, the read again through the resource API


def read_case(synth: Any, wire: str, tool: str, entry: Mapping[str, Any], catalog: Mapping[str, Any]
              ) -> Tuple[Dict[str, Any], Optional[str]]:
    case_id = f"{gen_daemon_ops.slug(wire)}-read"
    request = gen_daemon_ops.base_request(synth, wire)
    reasons = []
    if gen_daemon_ops.known_gap(wire):
        reasons.append(gen_daemon_ops.known_gap(wire))
    elif request.placeholders:
        reasons.append(f"{', '.join(request.placeholders)} would be a fixed placeholder id, not a fixture object "
                       f"(gen_daemon_ops.py's standard fixture has none for it)")
    target = {name: (gen_daemon_ops.Handle(READ_HANDLES.get(value.name, value.name))
                     if isinstance(value, gen_daemon_ops.Handle) else value)
              for name, value in request.target.items()}
    params = {**request.params, **READ_PARAMS.get(wire, {})}
    terminal = isinstance(target.get("terminal"), gen_daemon_ops.Handle)
    if terminal:
        target = {"terminal": TERMINAL_REF}
    used = [*gen_daemon_ops.handles_in(target), *gen_daemon_ops.handles_in(params)] + (["pane"] if terminal else [])
    steps = []
    for step_id in gen_daemon_ops.fixture_closure(used):
        fx = gen_daemon_ops.FIXTURE_BY_ID[step_id]
        steps.append(gen_daemon_ops.call_step(case_id, fx.id, fx.operation,
                                              {s: gen_daemon_ops.Handle(h) for s, h in fx.target}, fx.params,
                                              gen_daemon_ops.OK))
    if terminal:
        steps.append(gen_daemon_ops.call_step(case_id, PRINTED, "pane.run", {"pane": gen_daemon_ops.Handle("pane")},
                                              TERMINAL_COMMAND, gen_daemon_ops.OK,
                                              note="a terminal that prints one fixed text, then waits on its input"))
        steps.append(read_step(PRINTED_SEEN, "terminal.wait", {**SCOPE, "terminal": TERMINAL_REF},
                               {"pattern": "oracle", "timeout_ms": TERMINAL_WAIT_MS}, {"outcome": "ok"},
                               "the text is on the screen, so the read sees the command's whole output"))
    selectors = catalog["operations"][wire]["params"]["selectors"]
    full_target = {**{k: v for k, v in SCOPE.items() if k in selectors}, **gen_daemon_ops.refs(target)}
    wire_params = gen_daemon_ops.refs(params)
    arguments = tool_arguments(full_target, wire_params, None, tool, MACHINE_ARGUMENT.get(wire, ()))
    unknown = unknown_arguments(arguments, entry)
    if unknown:
        reasons.append(f"{tool} takes no argument {', '.join(unknown)} (its input schema, _tools.json)")
    steps.append(mcp_step(CALL, tool, arguments, target=full_target, expect={"outcome": "ok"}, read_only=True,
                          note=f"the read as the MCP tool {tool}"))
    pointer = result_pointer(synth.catalog, catalog["operations"][wire]["result"])
    steps.append(read_step("resource", wire, full_target, wire_params,
                           {"outcome": "ok", "result": f"$step:{CALL}#{pointer}"}, READ_RECEIPT_NOTE))
    requires = list(VM_REQUIRES)
    if any(s["args"].get("method") == "tab.create_browser" for s in steps if s["op"] == "resource.call"):
        requires.append("chromium")
    gap = capability_gap(requires)
    if gap:
        reasons.append(gap)
    doc = case_shell(
        case_id, f"{tool}: the read {wire} through MCP equals the resource API's reply", surface="cmux-next-daemon",
        fixture={"seed": f"{SUITE}.{gen_daemon_ops.slug(wire)}", "network": "offline", "clock": "virtual"},
        requires=requires, platforms=VM_PLATFORMS, steps=steps,
        invariants=[f"generated by {GENERATOR} from the catalog type of {wire} on gen_daemon_ops.py's fixture",
                    "the MCP read changes no daemon facet (readOnly), and its result is the resource API's reply"],
        preconditions=VM_PRECONDITIONS, teardown=["stop the case daemon", "verify the socket and state root are gone"])
    return doc, "; ".join(reasons) or None


def read_step(step_id: str, wire: str, target: Mapping[str, Any], params: Mapping[str, Any],
              expect: Mapping[str, Any], note: str) -> Dict[str, Any]:
    """A readOnly resource.call (a read carries no idempotency key: case-v1); a read with no selector has no
    target."""
    step: Dict[str, Any] = {"id": step_id, "op": "resource.call"}
    if target:
        step["target"] = dict(target)
    step.update({"args": {"method": wire, "params": dict(params)}, "readOnly": True, "expect": dict(expect),
                 "checkpoint": ["settled"], "note": note})
    return step


def result_pointer(types: Any, result: Mapping[str, Any]) -> str:
    """Where the MCP result holds the read's reply (cli/mcp.rs `success`): an array is `{items}`, an object is
    itself, any other value is `{result}`."""
    resolved, _ = types.resolve(result, {})
    if resolved.get("kind") == "nullable":
        resolved, _ = types.resolve(resolved["value"], {})
    kind = resolved.get("kind")
    if kind == "array":
        return "/items"
    if kind in ("object", "map", "union"):
        return ""
    return "/result"


# -- other tools


FIXTURE_STEPS = {"workspace": "fx-workspace"}
# The coverage keys of a tool's case paths.
CASE_KINDS = ("ok", "error", "read", "vm", "fleet")


def extra_cases(tool: str, plan: Extra, entry: Mapping[str, Any]) -> List[Tuple[str, Dict[str, Any], Optional[str]]]:
    """(path, case, reason) of the tool's VM and fleet cases."""
    out = []
    slug = tool.replace("_", "-")
    if plan.vm is not None:
        case_id = f"tool-{slug}"
        steps = [gen_daemon_ops.call_step(case_id, FIXTURE_STEPS[h], "workspace.create", {},
                                          gen_daemon_ops.FIXTURE_BY_ID["fx-workspace"].params, gen_daemon_ops.OK)
                 for h in plan.fixture]
        expect = ({"outcome": "error", "error": plan.error} if plan.error else
                  {"outcome": "ok", "noReceiptReason": f"{tool} is a composite tool: its result is no daemon "
                                                       f"mutation_result"} if plan.mutation else {"outcome": "ok"})
        unknown = unknown_arguments(plan.vm, entry)
        steps.append(mcp_step(CALL, tool, plan.vm, target=dict(SCOPE) if plan.mutation else None, expect=expect,
                              read_only=not plan.mutation, note=plan.note or None))
        what = f"refused with {plan.error}" if plan.error else "answered"
        doc = case_shell(
            case_id, f"{tool}: {what} on a daemon with no app", surface="cmux-next-daemon",
            fixture={"seed": f"{SUITE}.{slug}", "network": "offline", "clock": "virtual"},
            requires=VM_REQUIRES, platforms=VM_PLATFORMS, steps=steps,
            invariants=[f"generated by {GENERATOR} from EXTRA_TOOLS[{tool!r}]"], preconditions=VM_PRECONDITIONS,
            teardown=["stop the case daemon", "verify the socket and state root are gone"])
        reason = f"{tool} takes no argument {', '.join(unknown)} (_tools.json)" if unknown else None
        out.append(("vm", doc, reason))
    if plan.fleet is not None:
        case_id = f"tool-{slug}-app"
        unknown = unknown_arguments(plan.fleet, entry)
        steps = [mcp_step(CALL, tool, plan.fleet, target=None, expect={"outcome": "ok"}, read_only=True)]
        doc = case_shell(
            case_id, f"{tool}: answered by the tagged app", surface="cmux-next-native",
            fixture={"seed": f"{SUITE}.{slug}-app", "network": "offline", "clock": "fixed", "agent": "mock"},
            requires=FLEET_REQUIRES, platforms=FLEET_PLATFORMS, steps=steps,
            invariants=[f"generated by {GENERATOR} from EXTRA_TOOLS[{tool!r}]"], preconditions=FLEET_PRECONDITIONS,
            teardown=["the driver resets the session before the next case (app_reset.py)"])
        reason = f"{tool} takes no argument {', '.join(unknown)} (_tools.json)" if unknown else None
        out.append(("fleet", doc, reason))
    return out


# -- app actions: the actions suite's case as an MCP twin and a CLI twin


def action_arguments(action: Mapping[str, Any], params: Mapping[str, Any]) -> Tuple[Dict[str, Any], List[str]]:
    """The action's params its descriptor declares (the MCP tool's input), and the ones it does not."""
    declared = {a.get("name") for a in action.get("arguments") or () if isinstance(a, dict)}
    kept = {name: value for name, value in params.items() if name in declared}
    return kept, sorted(set(params) - declared)


def cli_argv(cli_name: str, arguments: Mapping[str, Any]) -> List[str]:
    """`cmux --json <cli words> --<flag> VALUE ...`: the app's CLI verb (cli/app.rs parse of an action verb)."""
    argv = ["--json", *cli_name.split()]
    for name in sorted(arguments):
        value = arguments[name]
        flag = f"--{kebab(name)}"
        if value is True:
            argv.append(f"{flag}=true")
        elif value is False:
            argv.append(f"{flag}=false")
        elif isinstance(value, str):
            argv.append(f"{flag}={value}")
        else:
            argv.append(f"{flag}={json.dumps(value, sort_keys=True)}")
    return argv


def action_pair(source: Mapping[str, Any], action: Mapping[str, Any], cli_name: str, tool: str
                ) -> Tuple[Dict[str, Any], Dict[str, Any], List[str]]:
    """(the MCP twin, the CLI twin, the action params the tool cannot take) of an actions-suite case."""
    base = copy.deepcopy(dict(source))
    index = next(i for i, step in enumerate(base["steps"]) if step["id"] == "action")
    main = base["steps"][index]
    params = dict((main.get("args") or {}).get("params") or {}) if main["op"] == "action.run" else {}
    arguments, dropped = action_arguments(action, params)
    expect = dict(main["expect"])
    if expect.get("outcome") == "ok":
        expect = {"outcome": "ok", "noReceiptReason": ACTION_NO_RECEIPT}
    extra = {key: main[key] for key in ("waitFor", "settleMaxMs") if key in main}
    target = main.get("target") or {"window": "current"}
    twins = []
    for entrypoint in ("mcp", "cli"):
        steps = copy.deepcopy(base["steps"])
        if entrypoint == "mcp":
            steps[index] = mcp_step("action", tool, arguments, target=target, expect=expect, read_only=False,
                                    note=f"{action['id']} as the MCP tool {tool}", **extra)
        else:
            step = {"id": "action", "op": "cli", "target": dict(target),
                    "args": {"argv": cli_argv(cli_name, arguments)}, "expect": expect,
                    "checkpoint": ["before", "settled"], "note": f"{action['id']} as `cmux {cli_name}`"}
            for key, value in extra.items():
                step[key] = copy.deepcopy(value)
            steps[index] = step
        requires = ["resource_api", "actions", "mcp"]
        if any(step["op"] == "key" for step in steps):
            requires.append("keys")
        requires += [cap for cap in base["requires"] if cap not in ("gui", "keys", "actions")]
        twins.append(case_shell(
            f"{source['id']}-{entrypoint}", f"{action['id']}: through {'MCP ' + tool if entrypoint == 'mcp' else '`cmux ' + cli_name + '`'}",
            surface="cmux-next-native", fixture=base["fixture"], requires=requires, platforms=FLEET_PLATFORMS,
            steps=steps,
            invariants=[f"generated by {GENERATOR} from actions/{source['id']} (the twin runs the same steps with the "
                        f"action through the {'CLI' if entrypoint == 'mcp' else 'MCP tool'})",
                        *source.get("invariants", [])[1:]],
            preconditions=FLEET_PRECONDITIONS, teardown=base["teardown"], untested=base.get("untested")))
    return twins[0], twins[1], dropped


# ------------------------------------------------------------------------------------------------ the suite


def generate(tools: Tools, parity_doc: Mapping[str, Any], *, daemon_ops: Path = DAEMON_OPS,
             action_catalog: Optional[gen_actions.Catalog] = None, actions_dir: Path = ACTIONS,
             catalog_path: Path = CATALOG) -> Dict[str, Any]:
    catalog = load_json(catalog_path)
    operations = catalog["operations"]
    synth = gen_daemon_ops.Synth(gen_daemon_ops.Catalog.load(catalog_path))
    ops_coverage = load_json(daemon_ops / COVERAGE)
    excluded_ops = ops_coverage.get("excluded") or {}
    out = Out({}, {}, {}, {}, [])
    for tool, entry in sorted(tools.by_name.items()):
        wire = next((w for w in operations if w.replace(".", "_") == tool and ("operation", w) not in tools.excluded),
                    None)
        record: Dict[str, Any] = {}
        if wire is not None and operations[wire]["class"] == "mutation":
            record["kind"] = "operation"
            record["operation"] = wire
            for kind in ("ok", "error"):
                path = daemon_ops / f"{gen_daemon_ops.slug(wire)}-{kind}.json"
                if not path.is_file():
                    raise GenError(f"{tool}: daemon-ops has no {path.name} (gen_daemon_ops.py makes one per mutation)")
                case, reason = from_daemon_ops(load_json(path), tool, entry)
                if kind == "ok" and wire in excluded_ops:
                    reason = "; ".join(filter(None, [f"daemon-ops excludes it: {excluded_ops[wire]}", reason]))
                record[kind] = out.add(case, reason, tool)
                if reason:
                    record.setdefault("blocked", {})[kind] = reason
                else:
                    out.parity.append({"mcp": record[kind], "twin": f"daemon-ops/{case['id']}", "tool": tool,
                                       "entry": "resource.call", "step": CALL})
        elif wire is not None and operations[wire]["class"] == "read":
            record["kind"] = "operation"
            record["operation"] = wire
            case, reason = read_case(synth, wire, tool, entry, catalog)
            record["read"] = out.add(case, reason, tool)
            if reason:
                record["blocked"] = {"read": reason}
        elif tool.startswith("app_"):
            continue  # an app action: the action pairs below (a daemon build lists none)
        else:
            plan = EXTRA_TOOLS.get(tool)
            if plan is None:
                raise GenError(f"{tool}: _tools.json lists it, and it is no daemon operation, no app action and not in "
                               f"EXTRA_TOOLS: say how the suite covers it")
            record["kind"] = "tool"
            for where, case, reason in extra_cases(tool, plan, entry):
                record[where] = out.add(case, reason, tool)
                if reason:
                    record.setdefault("blocked", {})[where] = reason
            if plan.gap:
                record["gap"] = plan.gap
        out.tools[tool] = record
    stale = sorted(set(EXTRA_TOOLS) - set(tools.by_name))
    if stale:
        raise GenError(f"EXTRA_TOOLS names tools _tools.json does not list: {stale}")
    action_catalog = action_catalog or gen_actions.Catalog.load()
    add_actions(out, action_catalog, gen_actions.load_tuning(actions_dir, action_catalog))
    reasons = parity_doc.get("differences") or []
    covered_tools = sum(1 for record in out.tools.values() if tool_covered(record))
    out.files[BLOCKED] = {
        "$comment": f"Blocked cases of the mcp suite, written whole by {GENERATOR}; oracle.py does not run `_` files. "
                    f"Each moves to its own case file when its reason goes. Do not edit: regenerate.",
        "generator": GENERATOR,
        "cases": dict(sorted(out.blocked.items())),
    }
    action_runnable = sum(1 for a in out.actions.values() if "blocked" not in a)
    covered, excluded, missing = coverage_contract(out.tools, out.actions)
    out.files[COVERAGE] = {
        "generator": GENERATOR,
        "suite": SUITE,
        "tools_list": TOOLS,
        "tools_sha256": tools.sha256,
        "daemon_ops_coverage_sha256": hashlib.sha256(render(ops_coverage).encode("utf-8")).hexdigest(),
        "action_catalog": action_catalog_label(action_catalog),
        "verdicts": "not run",
        "total": len(out.tools) + len(out.actions),
        "covered": len(covered),
        "excluded": excluded,
        "missing": missing,
        "total_tools": len(out.tools),
        "covered_tools": covered_tools,
        "cases": len([n for n in out.files if n not in (BLOCKED, COVERAGE)]),
        "blocked_cases": len(out.blocked),
        "mcp_actions": len(out.actions),
        "runnable_action_pairs": action_runnable,
        "parity_pairs": len(out.parity),
        "reasoned_differences": len(reasons),
        "tools": out.tools,
        "actions": out.actions,
        "parity": out.parity,
    }
    return out.files


def tool_covered(record: Mapping[str, Any]) -> bool:
    return any(kind in record and kind not in record.get("blocked", {}) for kind in CASE_KINDS)


def coverage_contract(tools: Mapping[str, Mapping[str, Any]], actions: Mapping[str, Mapping[str, Any]]
                      ) -> Tuple[List[str], Dict[str, str], List[str]]:
    """oracle.py coverage_lines' keys over every tool (`tool:<name>`) and MCP-offered action (`action:<id>`): the
    covered ones (a tool with a runnable case, an action with its runnable pair), the excluded ones with their
    reason (a tool's gap or blocks, an action's block) and the missing ones (neither)."""
    covered: List[str] = []
    excluded: Dict[str, str] = {}
    missing: List[str] = []
    for name, record in sorted(tools.items()):
        key = f"tool:{name}"
        reason = "; ".join(filter(None, [record.get("gap"), *(f"{kind}: {why}" for kind, why in
                                                                sorted((record.get("blocked") or {}).items()))]))
        if tool_covered(record):
            covered.append(key)
        elif reason:
            excluded[key] = reason
        else:
            missing.append(key)
    for ident, record in sorted(actions.items()):
        key = f"action:{ident}"
        if "blocked" in record:
            excluded[key] = record["blocked"]
        elif "mcp" in record and "cli" in record:
            covered.append(key)
        else:
            missing.append(key)
    return covered, excluded, missing


def action_catalog_label(catalog: Optional[gen_actions.Catalog]) -> str:
    catalog = catalog or gen_actions.Catalog.load()
    return f"{catalog.label} ({'action.list' if catalog.live else 'action-surfaces export'}, sha256 {catalog.sha256})"


def add_actions(out: Out, catalog: gen_actions.Catalog, tuning: Mapping[str, Mapping[str, Any]]) -> None:
    """The MCP-offered app actions: a pair from each runnable actions-suite case, else its block."""
    gaps = gen_actions.Gaps.load()
    files = gen_actions.generate(catalog, gaps, tuning)
    entries = files[gen_actions.COVERAGE]["actions"]
    surfaces = {a["id"]: a for a in load_json(SURFACES)["actions"]}
    taken: Dict[str, str] = {}
    for action in catalog.actions:
        ident = action["id"]
        plan = action.get("surfaces") or {}
        if plan.get("mcp") != "offered" or plan.get("cli") != "offered":
            continue
        cli_name = action.get("cli_name") or (surfaces.get(ident) or {}).get("cli_name")
        tool = tool_name_of_action(cli_name or "")
        record: Dict[str, Any] = {"tool": tool}
        if tool is None:
            record["blocked"] = f"its CLI name {cli_name!r} makes no tool name (action_tools.rs excludes it)"
        elif tool in taken:
            record["blocked"] = f"{taken[tool]} has the same tool name (action_tools.rs excludes the second)"
        elif ident in gaps.excluded:
            record["blocked"] = f"every-action-gaps.json excludes it: {gaps.excluded[ident]}"
        elif "blocked" in entries.get(ident, {}):
            record["blocked"] = entries[ident]["blocked"]
            record["blocked_by"] = entries[ident].get("blocked_by")
        else:
            source = files[f"{gen_actions.slug(ident)}.json"]
            mcp_case, cli_case, dropped = action_pair(source, action, cli_name, tool)
            reason = capability_gap(mcp_case["requires"])
            if dropped:
                note = f"params {', '.join(dropped)} are no declared argument, so neither twin sends them"
                for case in (mcp_case, cli_case):
                    case.setdefault("untested", []).append(note)
            record["mcp"] = out.add(mcp_case, reason, ident)
            record["cli"] = out.add(cli_case, reason, ident)
            if reason:
                record["blocked"] = reason
            else:
                out.parity.append({"mcp": record["mcp"], "twin": record["cli"], "tool": tool, "entry": "cli",
                                   "step": "action"})
        if tool is not None:
            taken.setdefault(tool, ident)
        out.actions[ident] = record


def render(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def owned_files(out: Path) -> List[str]:
    """The files this generator writes (cases, _blocked.json, coverage.json); never its inputs."""
    if not out.is_dir():
        return []
    return sorted(p.name for p in out.glob("*.json") if p.name not in INPUTS)


def drift(out: Path, files: Mapping[str, Any]) -> List[str]:
    problems = []
    for name in sorted(set(owned_files(out)) | set(files)):
        path = out / name
        if name not in files:
            problems.append(f"{name}: stale (no longer generated)")
        elif not path.is_file():
            problems.append(f"{name}: missing")
        elif path.read_text(encoding="utf-8") != render(files[name]):
            problems.append(f"{name}: differs from a fresh generation")
    return problems


def write(out: Path, files: Mapping[str, Any]) -> Tuple[int, int]:
    out.mkdir(parents=True, exist_ok=True)
    removed = 0
    for name in owned_files(out):
        if name not in files:
            (out / name).unlink()
            removed += 1
    for name, value in files.items():
        (out / name).write_text(render(value), encoding="utf-8")
    return len(files), removed


def generate_dir(out: Path, **kwargs: Any) -> Dict[str, Any]:
    return generate(Tools(out / TOOLS), check_parity_reasons(out / PARITY), **kwargs)


# ------------------------------------------------------------------------------------------------ self test


class GenMcpSelfTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tools = Tools(DEFAULT_OUT / TOOLS)
        cls.parity_doc = check_parity_reasons(DEFAULT_OUT / PARITY)
        cls.files = generate(cls.tools, cls.parity_doc)
        cls.coverage = cls.files[COVERAGE]
        cls.live = gen_actions.live_catalog(gen_actions.LIVE_OVERRIDES)

    def cases(self) -> Dict[str, Dict[str, Any]]:
        return {name[:-5]: case for name, case in self.files.items() if name not in (BLOCKED, COVERAGE)}

    def all_cases(self) -> Dict[str, Dict[str, Any]]:
        out = dict(self.cases())
        out.update({name: item["case"] for name, item in self.files[BLOCKED]["cases"].items()})
        return out

    def test_every_listed_tool_has_coverage_or_a_reason(self) -> None:
        for name in self.tools.by_name:
            if name.startswith("app_"):
                continue
            record = self.coverage["tools"][name]
            paths = [record[k] for k in ("ok", "error", "read", "vm", "fleet") if k in record]
            self.assertTrue(paths or record.get("gap"), name)
            for kind, reason in (record.get("blocked") or {}).items():
                self.assertGreater(len(reason), 20, f"{name} {kind}")

    def test_cases_pass_the_case_schema(self) -> None:
        check = gen_actions.CaseCheck()
        for name, case in self.all_cases().items():
            self.assertEqual(check.problems(case), [], name)

    def test_mutation_cases_are_their_daemon_ops_twin_with_the_call_through_mcp(self) -> None:
        pairs = [p for p in self.coverage["parity"] if p["entry"] == "resource.call"]
        self.assertGreater(len(pairs), 100)
        for pair in pairs:
            mcp = self.cases()[pair["mcp"].split("/", 1)[1]]
            twin = load_json(DAEMON_OPS / f"{pair['twin'].split('/', 1)[1]}.json")
            self.assertEqual(mcp["fixture"], twin["fixture"], pair)
            self.assertEqual([s["id"] for s in mcp["steps"]], [s["id"] for s in twin["steps"]], pair)
            for a, b in zip(mcp["steps"], twin["steps"]):
                if a["id"] == CALL:
                    self.assertEqual(a["op"], "mcp")
                    self.assertEqual(a["args"]["tool"], pair["tool"])
                    self.assertEqual(a["args"]["arguments"].get("idempotency_key"), b["args"].get("idempotencyKey"))
                    self.assertEqual(a["expect"], b["expect"])
                else:
                    self.assertEqual(a, b, pair)

    def test_tool_arguments_drop_the_scope_and_refuse_a_clash(self) -> None:
        got = tool_arguments({"machine": "current", "session": "current", "workspace": "$step:a#/x"}, {"name": "n"},
                             "k", "workspace_rename")
        self.assertEqual(got, {"workspace": "$step:a#/x", "name": "n", "idempotency_key": "k"})
        with self.assertRaises(GenError):
            tool_arguments({"workspace": "a"}, {"workspace": "b"}, None, "x")

    def test_reads_check_the_mcp_result_against_the_resource_reply(self) -> None:
        reads = [r for r in self.coverage["tools"].values() if "read" in r]
        self.assertGreater(len(reads), 40)
        for record in reads:
            case = self.all_cases()[record["read"].split("/", 1)[1]]
            call, again = case["steps"][-2], case["steps"][-1]
            self.assertEqual((call["op"], call.get("readOnly")), ("mcp", True))
            self.assertEqual(again["args"]["method"], record["operation"])
            self.assertTrue(again["expect"]["result"].startswith(f"$step:{CALL}#"))

    def test_terminal_content_reads_use_the_fixed_output_terminal(self) -> None:
        case = self.cases()["terminal-screen-read-read"]
        ids = [s["id"] for s in case["steps"]]
        self.assertEqual(ids, ["fx-workspace", PRINTED, PRINTED_SEEN, CALL, "resource"])
        self.assertEqual(case["steps"][-2]["args"]["arguments"]["terminal"], TERMINAL_REF)

    def test_vm_cases_run_on_linux_and_fleet_cases_on_mac(self) -> None:
        for name, case in self.cases().items():
            fleet = name.endswith(("-app", "-mcp", "-cli"))
            self.assertEqual(case["platforms"], FLEET_PLATFORMS if fleet else VM_PLATFORMS, name)
            self.assertLessEqual(set(case["requires"]), PRODUCT_CAPABILITIES, name)

    def test_a_case_the_mcp_product_cannot_run_is_blocked(self) -> None:
        for name, item in self.files[BLOCKED]["cases"].items():
            self.assertTrue(item["case"]["untested"][0].startswith("blocked: "), name)
        self.assertIsNotNone(capability_gap(["resource_api", "chromium"]))
        self.assertIsNone(capability_gap(["resource_api", "mcp", "restart"]))

    def test_the_export_blocks_every_action_pair(self) -> None:
        self.assertGreater(self.coverage["mcp_actions"], 500)
        if not self.coverage["action_catalog"].startswith("plans/"):
            self.skipTest("a live catalog is checked in")
        self.assertEqual(self.coverage["runnable_action_pairs"], 0)
        for record in self.coverage["actions"].values():
            self.assertIn("blocked", record)

    def test_a_live_catalog_makes_mcp_and_cli_twins(self) -> None:
        out = Out({}, {}, {}, {}, [])
        # The self tests' live catalog declares no arguments, so the actions suite's tuned params cannot apply.
        add_actions(out, self.live, {})
        pairs = out.parity
        self.assertGreater(len(pairs), 100)
        for pair in pairs[:50]:
            mcp = out.files[pair["mcp"].split("/", 1)[1] + ".json"]
            cli = out.files[pair["twin"].split("/", 1)[1] + ".json"]
            self.assertEqual(mcp["fixture"], cli["fixture"])
            self.assertEqual([s["id"] for s in mcp["steps"]], [s["id"] for s in cli["steps"]])
            main_mcp = next(s for s in mcp["steps"] if s["id"] == "action")
            main_cli = next(s for s in cli["steps"] if s["id"] == "action")
            self.assertEqual(main_mcp["args"]["tool"], pair["tool"])
            self.assertEqual(main_cli["args"]["argv"][0], "--json")
            self.assertEqual(main_mcp["expect"], main_cli["expect"])
            self.assertNotIn("gui", mcp["requires"])
        check = gen_actions.CaseCheck()
        for name, case in list(out.files.items())[:200]:
            self.assertEqual(check.problems(case), [], name)

    def test_tool_names_follow_action_tools_rs(self) -> None:
        self.assertEqual(tool_name_of_action("app new-window"), "app_new_window")
        self.assertEqual(tool_name_of_action("workspace move-to-window"), "app_workspace_move_to_window")
        self.assertEqual(tool_name_of_action("tab-group close"), "app_tab_group_close")
        self.assertIsNone(tool_name_of_action("app"))
        self.assertIsNone(tool_name_of_action("workspace é"))

    def test_cli_argv_is_the_verb_with_kebab_flags(self) -> None:
        self.assertEqual(cli_argv("workspace rename", {"newName": "x", "focus": True, "count": 2}),
                         ["--json", "workspace", "rename", "--count=2", "--focus=true", "--new-name=x"])

    def test_extra_tools_are_listed_tools(self) -> None:
        self.assertLessEqual(set(EXTRA_TOOLS), set(self.tools.by_name))

    def test_parity_reasons_need_a_reason(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / PARITY
            path.write_text(json.dumps({"differences": [{"pointer": "/daemon/x", "reason": "short"}]}))
            with self.assertRaisesRegex(GenError, "reason"):
                check_parity_reasons(path)
            path.write_text(json.dumps({"differences": [{"pointer": "daemon", "reason": "x" * 30}]}))
            with self.assertRaisesRegex(GenError, "pointer"):
                check_parity_reasons(path)

    def test_the_oracle_coverage_check_counts_every_tool_and_action(self) -> None:
        import oracle  # noqa: E402  (oracle.py check --coverage reads coverage.json through coverage_lines)

        tools = [name for name in self.tools.by_name if not name.startswith("app_")]
        self.assertEqual(self.coverage["total"], len(tools) + self.coverage["mcp_actions"])
        self.assertEqual(self.coverage["covered"], self.coverage["covered_tools"] + self.coverage["runnable_action_pairs"])
        self.assertGreater(self.coverage["covered"], 100)
        self.assertEqual(self.coverage["missing"], [])
        self.assertEqual(self.coverage["covered"] + len(self.coverage["excluded"]), self.coverage["total"])
        self.assertIn("tool:render", self.coverage["excluded"])
        self.assertIn("tool:git_status", self.coverage["excluded"])
        self.assertEqual(sum(key.startswith("action:") for key in self.coverage["excluded"]),
                         self.coverage["mcp_actions"] - self.coverage["runnable_action_pairs"])
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / SUITE
            out.mkdir()
            (out / COVERAGE).write_text(render(self.coverage), encoding="utf-8")
            lines, errors = oracle.coverage_lines(Path(tmp))
            self.assertEqual(errors, [])
            self.assertEqual(lines, [f"{SUITE}: {self.coverage['covered']}/{self.coverage['total']} "
                                     f"({len(self.coverage['excluded'])} excluded with a reason)"])
            # A tool with no runnable case and no reason is uncovered, and the check says so.
            tools_doc = {name: dict(record) for name, record in self.coverage["tools"].items()}
            tools_doc["render"].pop("gap")
            covered, excluded, missing = coverage_contract(tools_doc, self.coverage["actions"])
            self.assertEqual(missing, ["tool:render"])
            (out / COVERAGE).write_text(render({**self.coverage, "covered": len(covered), "excluded": excluded,
                                                "missing": missing}), encoding="utf-8")
            _, errors = oracle.coverage_lines(Path(tmp))
            self.assertEqual(errors, [f"{SUITE}: 1 uncovered: tool:render"])

    def test_regeneration_is_byte_stable_and_check_finds_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / SUITE
            out.mkdir()
            for name in INPUTS:
                shutil.copy(DEFAULT_OUT / name, out / name)
            write(out, self.files)
            self.assertEqual(drift(out, generate_dir(out)), [])
            (out / "stale.json").write_text("{}\n")
            first = sorted(self.cases())[0]
            (out / f"{first}.json").write_text("{}\n")
            problems = drift(out, self.files)
            self.assertIn("stale.json: stale (no longer generated)", problems)
            self.assertIn(f"{first}.json: differs from a fresh generation", problems)
            write(out, self.files)
            self.assertFalse((out / "stale.json").exists())
            self.assertTrue((out / TOOLS).exists())


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--check", action="store_true", help="exit 1 when --out differs from a fresh generation")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)
    if args.selftest:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(GenMcpSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful() else 1
    try:
        files = generate_dir(args.out)
    except (GenError, gen_actions.GenError, gen_daemon_ops.GenError) as error:
        print(f"gen_mcp.py: {error}", file=sys.stderr)
        return 2
    if args.check:
        problems = drift(args.out, files)
        for problem in problems[:50]:
            print(f"gen_mcp.py: {problem}", file=sys.stderr)
        return 1 if problems else 0
    written, removed = write(args.out, files)
    coverage = files[COVERAGE]
    print(f"gen_mcp.py: {written} files ({coverage['cases']} cases, {coverage['blocked_cases']} blocked), {removed} "
          f"removed; {coverage['covered_tools']}/{coverage['total_tools']} tools, {coverage['parity_pairs']} parity "
          f"pairs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
