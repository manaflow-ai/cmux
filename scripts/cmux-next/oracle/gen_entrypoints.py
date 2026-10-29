#!/usr/bin/env python3
"""Generate the entrypoints suite and compare its cases: one case per entrypoint of each action that has two or more.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3D (suite entrypoints, differential) and task 210. Stdlib
plus gen_actions.py and diff.py, Python 3.9+, safe under `python3 -I`. `oracle.py gen --suite entrypoints` runs it with
`--out <corpus>/entrypoints`.

Chrome reference (chromium/src): chrome/browser/ui/browser_commands.h routes an accelerator, a menu item and a toolbar
button through one chrome::ExecuteCommand(browser, id), and chrome/browser/command_updater_impl.cc keeps one enabled
state per command, so every way in does the same thing. cmux routes every entrypoint through ActionRegistry; this
suite checks that the settled state is the same whichever way the action came in.

An action's entrypoints are its catalog surfaces (plans/cmux-next/oracle-DESIGN.md section 2): `shortcut` (a default
single-stroke shortcut), `cli` and `mcp` (offered), `palette` (offered), `main-menu` (in the menu bar) and
`context-menu` (offered). The suite lists every action with two or more (986 in action-surfaces.json); an action with
one is never in it.

Per listed action, one case `<slug>--<entrypoint>.json` per entrypoint a case-v1 step can drive, every case with the
same steps as gen_actions.py's actions case except the one step under test, `action`:

  shortcut  a key step with the shortcut through debug.key (checkpoints before, turn, settled)
  cli       a cli step: `cmux <cli name> [--<argument> VALUE]... --focus` on the app's socket (before, settled)
  mcp       an mcp step: the `app_<cli name>` tool of `cmux mcp` with the arguments and focus: true (before, settled)

The setup (context, neighbor, prepare and the actions family's tuned `before` steps), the arguments and the restore
steps are the actions suite's for that action (gen_actions.build_case with action.run as its entry), so the cases
differ only in how the action is asked for. A socket run moves the person's view only when asked (`focus`,
plans/cmux-next/OWNERSHIP-PRINCIPLES.md "Clients are projections"); the cli and mcp cases ask, so their settled state
is comparable with a key press.

`palette`, `main-menu` and `context-menu` are listed but have no case: case-v1 has no step that picks a palette row,
clicks a menu bar item or opens a context menu (NO_STEP; p15-oracle-047 adds them). An entrypoint is also blocked
when its step cannot carry the run (a key has no arguments; the CLI sends only strings and bare flags; an argument
named like a control flag; a live-only value; no tool name). An action the actions suite tunes to a refusal gets a
case per entrypoint with that entrypoint's own refusal code (REFUSAL_CODES: cli.failed, mcp.tool_error), so a pair
shows one entrypoint running what another refuses; its key has none yet (KEY_REFUSAL). An action is excluded with
its reason when the actions suite blocks it, `no-step` when it has two runnable entrypoints only once p15-oracle-047
lands, `one-entrypoint` when fewer than two can carry the run otherwise, and `expect-differs` when no two are
expected to do the same (the sweep's EXPECT_BY_ENTRY: `palette.newAgentChat` docks a chat by key and opens a tab by
action.run). From action-surfaces.json (no live action.list) the actions suite blocks every action, so every listed
action is excluded `no-live-catalog` and no case is written.

coverage.json lists each action with its entrypoints, the case of each runnable one, why each other one is blocked,
and the `pairs` the comparison checks: the runnable entrypoints with the same sweep expectation.

`--compare RUN` reads an oracle run directory of this suite (receipt.json, checkpoints.jsonl; diff.load_run) and, for
each pair of each action in coverage.json, compares the settled checkpoints of the two cases from the `action` step
on. Each pair that differs is reported as (action, A, B, pointer) with the step, both values and the count of
differing leaves at that checkpoint; `/meta` (the case id, time) and `/facets/cli` (the CLI step's own receipt) are
not compared. A pair where exactly one of two real verdicts passes is a difference at `/result`; both failed, either
not run (absent or result None), Flaky (oracle.py classify leaves it out, as diff.py does) or Skip are listed apart.
Exit 0 no difference, 1 differences, 2 bad input.

Usage:
  gen_entrypoints.py --out DIR [--catalog PATH] [--actions DIR]          write the cases and coverage.json into DIR
  gen_entrypoints.py --out DIR [--catalog PATH] [--actions DIR] --check  exit 1 when DIR differs from a fresh generation
  gen_entrypoints.py --compare RUN [--out DIR] [--report FILE]           compare a run's entrypoint pairs
  gen_entrypoints.py --selftest                                          offline tests
"""

from __future__ import annotations

import argparse
import copy
import itertools
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import diff  # noqa: E402  (load_run, iter_differences: the comparison of two runs, here of two cases)
import gen_actions  # noqa: E402  (the actions suite: catalog, sweep plan, tuning, build_case)

DEFAULT_OUT = REPO / "tests" / "oracle" / "corpus" / "entrypoints"
ACTIONS_DIR = gen_actions.DEFAULT_OUT
SUITE = "entrypoints"
GENERATOR = "scripts/cmux-next/oracle/gen_entrypoints.py"
COVERAGE = "coverage.json"
REPORT_SCHEMA = "oracle-entrypoint-parity-v1"
# The catalog surfaces, in the order a pair names them (the first is A).
ENTRYPOINTS = ("shortcut", "cli", "mcp", "palette", "main-menu", "context-menu")
# The task that adds the case-v1 ops and driver_app.py steps an entrypoint below waits for.
NO_STEP_TASK = "p15-oracle-047"
# Why an entrypoint has no case: no case-v1 op drives it.
NO_STEP = {
    "palette": "case-v1 has no step that picks a palette row: a key step opens the palette but cannot choose this "
               "action's row by id, and action.run cannot claim the palette's origin (driver_app.py SOCKET_ORIGINS); "
               f"{NO_STEP_TASK} adds the palette step",
    "main-menu": "case-v1 has no step that clicks a menu bar item (a key equivalent is the shortcut case); "
                 f"{NO_STEP_TASK} adds the menu step over debug.menu_item",
    "context-menu": "case-v1 has no step that opens an object's context menu and picks its item; "
                    f"{NO_STEP_TASK} adds the context-menu step",
}
# The typed code driver_app.py gives each entrypoint's refusal, whatever the app's own code: op_cli reads only the
# exit (the CLI writes its error to stderr, cli/wire.rs print_local_error, so stdout has no code) and op_mcp reads
# only isError.
REFUSAL_CODES = {"cli": "cli.failed", "mcp": "mcp.tool_error"}
KEY_REFUSAL = ("a refused key run is no debug.key error: DebugKey.swift reports `action: null, refused_action: <id>`, "
               "which driver_app.py op_key reads as ok (key.refused is debug.key's own error), so no expect states the "
               f"refusal; {NO_STEP_TASK} reads refused_action")
REFUSAL_UNTESTED = {
    "cli": "which refusal: driver_app.py op_cli reads every nonzero exit as cli.failed, not the app's {code}",
    "mcp": "which refusal: driver_app.py op_mcp reads isError as mcp.tool_error, not the app's {code}",
}
# The sweep plan's entry whose expectation (EXPECT_WAITS) an entrypoint's step checks.
PLAN_ENTRY = {"shortcut": "key", "cli": "action", "mcp": "action"}
# Flags the CLI reads itself (cli/app.rs run_action), so an argument by that name cannot pass as `--<name>`.
CLI_FLAGS = frozenset({"target", "arg", "wait", "no-wait", "interactive", "focus"})
# Arguments the MCP action tool takes as its own controls (cli/mcp/action_tools.rs from_list).
MCP_CONTROLS = frozenset({"target", "idempotency_key"})
SOCKET_NO_RECEIPT = ("the {entry} reply carries no ActionEffect kind the driver reads (driver_app.py op_{entry}); the "
                     "settled state is the check")
FOCUS_NOTE = ("the {entry} run asks for focus, as a person's run moves the view (OWNERSHIP-PRINCIPLES.md: a socket "
              "run without focus keeps it), so its settled state compares with the key press")
# Snapshot parts that differ by case, not by behavior: the case id and capture time, and the CLI step's own receipt.
IGNORED = ("meta",)
IGNORED_FACETS = ("cli",)
PASSING = frozenset({"Pass", "Slow"})
SEPARATOR = "--"


class GenError(Exception):
    """The catalog, the actions suite or a run cannot make or check the suite."""


# ------------------------------------------------------------------------------------------------ entrypoints


def entrypoints_of(entry: Mapping[str, Any]) -> List[str]:
    """The catalog surfaces of one action, in ENTRYPOINTS order: an action-surfaces.json row (default_shortcut,
    top-level surface fields) or an action.list entry (shortcut_config, `surfaces`, main_menu when set)."""
    if "default_shortcut" in entry:
        surfaces: Mapping[str, Any] = entry
        shortcut = entry.get("default_shortcut") is not None
    else:
        surfaces = entry.get("surfaces") or {}
        shortcut = bool(entry.get("shortcut_config"))
    found = {
        "shortcut": shortcut,
        "cli": surfaces.get("cli") == "offered",
        "mcp": surfaces.get("mcp") == "offered",
        "palette": surfaces.get("palette") == "offered",
        "main-menu": bool(entry.get("main_menu")),
        "context-menu": surfaces.get("context_menu") == "offered",
    }
    return [name for name in ENTRYPOINTS if found[name]]


def raw_entries(catalog: gen_actions.Catalog) -> Dict[str, Mapping[str, Any]]:
    """Each action's catalog entry as written: gen_actions keeps an action.list entry whole, but lists an
    action-surfaces.json row without its main_menu and cli_name, so the export is read again."""
    if catalog.live:
        return dict(catalog.by_id)
    try:
        data = json.loads(catalog.path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise GenError(f"{catalog.path}: {error}") from None
    return {entry["id"]: entry for entry in data["actions"]}


def tool_name(cli_name: str) -> Optional[str]:
    """The MCP tool of an action (cli/mcp/action_tools.rs tool_name): `app_` and the CLI name's words, a leading
    `app` word dropped, `-`, `_` and `.` as `_`; None when a character does not fit or it is longer than 64."""
    words = cli_name.split()
    if words[:1] == ["app"]:
        words = words[1:]
    name = "app"
    for word in words:
        name += "_"
        for character in word:
            if "a" <= character <= "z" or "0" <= character <= "9":
                name += character
            elif "A" <= character <= "Z":
                name += character.lower()
            elif character in "-_.":
                name += "_"
            else:
                return None
    return name if len("app_") < len(name) <= 64 else None


def cli_flags(params: Mapping[str, Any]) -> Tuple[List[str], Optional[str]]:
    """The run's arguments as `cmux` flags (cli/app.rs run_action reads `--<name> VALUE` as the argument <name>, a
    bare `--<name>` as true), or why the CLI cannot send them: it sends every value as a string."""
    argv: List[str] = []
    for name in sorted(params):
        value = params[name]
        if name in CLI_FLAGS:
            return [], f"the argument `{name}` is a flag the CLI reads itself"
        if value is True:
            argv.append(f"--{name}")
        elif isinstance(value, bool):
            argv.extend([f"--{name}", "false"])
        elif isinstance(value, (str, int, float)):
            argv.extend([f"--{name}", str(value)])
        else:
            return [], f"the argument `{name}` is {type(value).__name__}: the CLI sends a string or a bare flag"
    return argv, None


def tool_names(entries: Mapping[str, Mapping[str, Any]]) -> Dict[str, List[str]]:
    """{tool name: action ids}: the MCP tools of the actions the CLI and MCP offer, to find a name two share."""
    names: Dict[str, List[str]] = {}
    for ident, entry in sorted(entries.items()):
        found = entrypoints_of(entry)
        name = tool_name(entry.get("cli_name") or "") if "mcp" in found and "cli" in found else None
        if name:
            names.setdefault(name, []).append(ident)
    return names


# ------------------------------------------------------------------------------------------------ cases


def case_id(ident: str, entry: str) -> str:
    return f"{gen_actions.slug(ident)}{SEPARATOR}{entry}"


def main_step(entry: str, ident: str, raw: Mapping[str, Any], row: Mapping[str, Any], params: Mapping[str, Any],
              spec: Mapping[str, Any], tools: Mapping[str, List[str]]) -> Tuple[Optional[Dict[str, Any]], str]:
    """The `action` step of one entrypoint's case, or (None, why it cannot carry this run). A tuned refusal
    (`error` in spec) expects the entrypoint's own refusal code (REFUSAL_CODES)."""
    target = {"window": "current"}
    refused = "error" in spec
    if entry == "shortcut":
        if refused:
            return None, KEY_REFUSAL
        key = row.get("key")
        stroke = gen_actions.keystroke(key) if key else None
        if not stroke:
            return None, (f"its shortcut {raw.get('shortcut_config') or raw.get('default_shortcut')!r} is not a single "
                          f"stroke debug.key sends (the sweep's key_of)")
        if params:
            return None, f"a key carries no arguments, and the run takes {', '.join(sorted(params))}"
        expect: Dict[str, Any] = ({"outcome": "ok", "receipt": spec["receipt"]} if "receipt" in spec
                                  else {"outcome": "ok", "noReceiptReason": gen_actions.NO_RECEIPT})
        return {"id": "action", "op": "key", "target": target, "args": {"keys": [stroke]}, "expect": expect,
                "checkpoint": ["before", "turn", "settled"]}, ""
    cli_name = raw.get("cli_name")
    if not cli_name:
        return None, "the catalog gives no cli_name"
    socket_expect = ({"outcome": "error", "error": REFUSAL_CODES[entry]} if refused
                     else {"outcome": "ok", "noReceiptReason": SOCKET_NO_RECEIPT.format(entry=entry)})
    if entry == "cli":
        flags, why = cli_flags(params)
        if why:
            return None, why
        argv = cli_name.split() + flags + ["--focus"]
        return {"id": "action", "op": "cli", "target": target, "args": {"argv": argv}, "expect": socket_expect,
                "checkpoint": ["before", "settled"]}, ""
    name = tool_name(cli_name)
    if not name:
        return None, f"its CLI name {cli_name!r} makes no MCP tool name (action_tools.rs tool_name)"
    if len(tools.get(name, ())) > 1:
        return None, f"the tool name {name} is also {', '.join(i for i in tools[name] if i != ident)}'s"
    taken = sorted(set(params) & MCP_CONTROLS)
    if taken:
        return None, f"the argument `{taken[0]}` is an MCP tool control argument"
    arguments = dict(params)
    arguments.setdefault("focus", True)
    return {"id": "action", "op": "mcp", "target": target, "args": {"tool": name, "arguments": arguments},
            "expect": socket_expect, "checkpoint": ["before", "settled"]}, ""


def variant(base: Mapping[str, Any], step: Mapping[str, Any], entry: str, ident: str, row: Mapping[str, Any],
            spec: Mapping[str, Any], catalog: gen_actions.Catalog, others: Sequence[str]) -> Dict[str, Any]:
    """The actions case `base` (action.run as its entry) with `step` as the step under test."""
    case = copy.deepcopy(dict(base))
    steps = case["steps"]
    index = next(i for i, s in enumerate(steps) if s["id"] == "action")
    old = steps[index]
    main = copy.deepcopy(dict(step))
    plan_entry = PLAN_ENTRY[entry]
    expected = (row.get("expect") or {}).get(plan_entry)
    refused = "error" in spec
    if "waitFor" in spec:
        main["waitFor"] = copy.deepcopy(spec["waitFor"])
    elif expected and not refused:
        main["waitFor"] = {"pointer": gen_actions.EXPECT_WAITS[expected], "predicate": "changed",
                           "maxMs": gen_actions.EXPECT_WAIT_MS}
    for key in ("settleMaxMs", "note"):
        if key in old:
            main[key] = old[key]
    steps[index] = main
    ident_title = (catalog.by_id[ident].get("title") or ident)
    case["id"] = case_id(ident, entry)
    case["suite"] = SUITE
    case["title"] = f"{ident}: {ident_title} through its {entry} entrypoint"[:200]
    case["fixture"]["seed"] = f"entrypoints.{ident}"
    requires = list(gen_actions.BASE_REQUIRES)
    ops = {s["op"] for s in steps}
    if "key" in ops:
        requires.append("keys")
    if "mcp" in ops:
        requires.append("mcp")
    if "chromium" in base["requires"]:
        requires.append("chromium")
    for capability in spec.get("requires") or ():
        if capability not in requires:
            requires.append(capability)
    case["requires"] = requires
    invariants = [f"generated by {GENERATOR} from {catalog.label} entry {ident} with gen_actions.py's setup: the "
                  f"settled checkpoints from the action step on equal those of {', '.join(case_id(ident, o) for o in others)} "
                  f"(gen_entrypoints.py --compare)"]
    if refused:
        invariants.append(f"the action is refused ({spec['error']}, {gen_actions.family_of(ident)}/"
                          f"{gen_actions.TUNING}) and changes nothing, whichever way it came in")
    elif expected and "waitFor" not in spec:
        invariants.append(f"{gen_actions.EXPECT_WORDS[expected]} (the action step's waitFor checks that "
                          f"{gen_actions.EXPECT_WAITS[expected]} changed)")
    if entry in ("cli", "mcp"):
        invariants.append(FOCUS_NOTE.format(entry=entry))
    invariants.extend(spec.get("invariants") or ())
    case["invariants"] = invariants
    untested = list(spec.get("untested") or ())
    if refused:
        untested.append(REFUSAL_UNTESTED[entry].format(code=spec["error"]))
    if entry == "shortcut":
        untested.append("which action the key ran: the turn checkpoint fails a key no action took, but driver_app.py "
                        "does not compare the debug.key reply's `action` with this action (p15-oracle-047)")
    if untested:
        case["untested"] = untested
    else:
        case.pop("untested", None)
    return case


def groups(runnable: Sequence[str], row: Mapping[str, Any]) -> List[List[str]]:
    """The pairs to compare: runnable entrypoints whose sweep expectation is the same (EXPECT_BY_ENTRY gives a key
    and action.run different ones when they do different things on purpose)."""
    expect = row.get("expect") or {}
    return [[a, b] for a, b in itertools.combinations(runnable, 2)
            if expect.get(PLAN_ENTRY[a]) == expect.get(PLAN_ENTRY[b])]


def generate(catalog: gen_actions.Catalog, gaps: gen_actions.Gaps, tuning: Mapping[str, Mapping[str, Any]],
             planner: Optional[gen_actions.Planner] = None) -> Dict[str, Any]:
    """{file name: JSON value}: the runnable cases and coverage.json."""
    planner = planner or (gen_actions.Planner(gen_actions.sweep_module()) if catalog.live else None)
    actions_files = gen_actions.generate(catalog, gaps, tuning, planner)
    actions_cov = actions_files[gen_actions.COVERAGE]["actions"]
    raws = raw_entries(catalog)
    tools = tool_names(raws)
    check = gen_actions.CaseCheck()
    files: Dict[str, Any] = {}
    actions: Dict[str, Any] = {}
    excluded: Dict[str, str] = {}
    counts = {name: {"listed": 0, "runnable": 0} for name in ENTRYPOINTS}
    excluded_by: Dict[str, int] = {}
    waiting = {"actions": 0, "entrypoints": 0}

    def exclude(ident: str, doc: Dict[str, Any], kind: str, reason: str, task: Optional[str] = None) -> None:
        doc["blocked"], doc["blocked_by"] = reason, kind
        if task:
            doc["task"] = task
        excluded[ident] = f"blocked: {reason}"
        excluded_by[kind] = excluded_by.get(kind, 0) + 1
        actions[ident] = doc

    for action in catalog.actions:
        ident = action["id"]
        listed = entrypoints_of(raws[ident])
        if len(listed) < 2:
            continue
        for name in listed:
            counts[name]["listed"] += 1
        doc: Dict[str, Any] = {"entrypoints": listed}
        if ident in gaps.excluded:
            exclude(ident, doc, "excluded", f"every-action-gaps.json excludes it: {gaps.excluded[ident]}")
            continue
        actions_entry = actions_cov[ident]
        if "blocked" in actions_entry:
            exclude(ident, doc, actions_entry["blocked_by"],
                    f"the actions suite blocks it ({actions_entry['blocked_by']}): {actions_entry['blocked']}")
            continue
        spec = tuning.get(ident) or {}
        row = planner.plan(action)
        base, _ = gen_actions.build_case(action, row, planner, catalog, {**spec, "entry": "action"}, None)
        base_main = next(s for s in base["steps"] if s["id"] == "action")
        params = (base_main["args"].get("params") or {})
        steps: Dict[str, Dict[str, Any]] = {}
        blocked: Dict[str, str] = {}
        for name in listed:
            if name in NO_STEP:
                blocked[name] = NO_STEP[name]
                continue
            step, why = main_step(name, ident, raws[ident], row, params, spec, tools)
            if step is None:
                blocked[name] = why
                continue
            live = gen_actions.placeholders(step.get("args", {}), "action.args")
            if live:
                blocked[name] = f"needs a live value: {', '.join(live)}"
                continue
            steps[name] = step
        runnable = [name for name in listed if name in steps]
        no_step = [name for name in listed if name in NO_STEP]
        waits = no_step + [name for name in listed if blocked.get(name) == KEY_REFUSAL]
        if waits:
            waiting["actions"] += 1
            waiting["entrypoints"] += len(waits)
        pairs = groups(runnable, row)
        compared = sorted({name for pair in pairs for name in pair}, key=ENTRYPOINTS.index)
        for name in runnable if len(runnable) > 1 else ():
            if name not in compared:
                blocked[name] = (f"the sweep expects its {PLAN_ENTRY[name]} run to do something else than the other "
                                 f"entrypoints' (EXPECT_BY_ENTRY), so it has nothing to compare with")
        doc["cases"] = {name: f"{SUITE}/{case_id(ident, name)}" for name in compared}
        if blocked:
            doc["blocked_entrypoints"] = {name: blocked[name] for name in listed if name in blocked}
        if not pairs:
            doc.pop("cases")
            if len(runnable) >= 2:
                exclude(ident, doc, "expect-differs", "no two of its runnable entrypoints are expected to do the same")
            elif len(runnable) + len(waits) >= 2:
                exclude(ident, doc, "no-step",
                        f"{len(runnable)} of its entrypoints {', '.join(listed)} run a case; case-v1 and driver_app.py "
                        f"have no step for {', '.join(waits)} yet ({NO_STEP_TASK} adds it, blocked_entrypoints)",
                        NO_STEP_TASK)
            else:
                exclude(ident, doc, "one-entrypoint",
                        f"fewer than two of its entrypoints run a case: {len(runnable)} of {', '.join(listed)}, the "
                        f"others cannot carry this run (blocked_entrypoints)")
            continue
        doc["pairs"] = pairs
        for name in compared:
            others = [o for o in compared if o != name]
            case = variant(base, steps[name], name, ident, row, spec, catalog, others)
            problems = check.problems(case)
            if problems:
                raise GenError(f"{ident} {name}: the case is not case-v1: {'; '.join(problems[:5])}")
            files[f"{case['id']}.json"] = case
            counts[name]["runnable"] += 1
        actions[ident] = doc
    files[COVERAGE] = {
        "generator": GENERATOR,
        "suite": SUITE,
        "catalog": catalog.label,
        "catalog_sha256": catalog.sha256,
        "catalog_kind": "action.list" if catalog.live else "action-surfaces",
        "gaps": "scripts/cmux-next/every-action-gaps.json",
        "gaps_sha256": gaps.sha256,
        "total": len(actions),
        "covered": len(actions) - len(excluded),
        "verdicts": "not run",
        "excluded": excluded,
        "blocked_by": dict(sorted(excluded_by.items())),
        "missing": [],
        "entrypoints": counts,
        "tasks": {NO_STEP_TASK: waiting},
        "cases": sum(1 for name in files if name != COVERAGE),
        "actions": actions,
    }
    return files


def render(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def owned_files(out: Path) -> List[str]:
    """The case files the last generation wrote (from its coverage.json)."""
    path = out / COVERAGE
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        return []
    return sorted(case.split("/", 1)[1] + ".json" for entry in (data.get("actions") or {}).values()
                  if isinstance(entry, dict) for case in (entry.get("cases") or {}).values() if isinstance(case, str))


def drift(out: Path, files: Mapping[str, Any]) -> List[str]:
    problems = []
    for name, value in sorted(files.items()):
        path = out / name
        if not path.is_file():
            problems.append(f"{name}: missing")
        elif path.read_text(encoding="utf-8") != render(value):
            problems.append(f"{name}: differs from a fresh generation")
    for name in owned_files(out):
        if name not in files and (out / name).exists():
            problems.append(f"{name}: generated earlier, now blocked or no longer in the catalog")
    return problems


def write(out: Path, files: Mapping[str, Any]) -> Tuple[int, int]:
    """Writes changed files and removes the cases an earlier generation wrote that this one does not; refuses to
    overwrite a case file it did not write."""
    out.mkdir(parents=True, exist_ok=True)
    owned = set(owned_files(out))
    for name in files:
        if name != COVERAGE and (out / name).exists() and name not in owned:
            raise GenError(f"{out / name}: exists and was not written by this generator")
    written = 0
    for name, value in sorted(files.items()):
        path = out / name
        text = render(value)
        if not path.is_file() or path.read_text(encoding="utf-8") != text:
            path.write_text(text, encoding="utf-8")
            written += 1
    removed = 0
    for name in sorted(owned - set(files)):
        (out / name).unlink(missing_ok=True)
        removed += 1
    return written, removed


# ------------------------------------------------------------------------------------------------ compare


def comparable(snapshot: Any) -> Any:
    """A settled snapshot without what differs by case and not by behavior (IGNORED, IGNORED_FACETS)."""
    if not isinstance(snapshot, dict):
        return snapshot
    value = {k: v for k, v in snapshot.items() if k not in IGNORED}
    facets = value.get("facets")
    if isinstance(facets, dict):
        value["facets"] = {k: v for k, v in facets.items() if k not in IGNORED_FACETS}
    return value


def settled_from_action(points: Sequence[Any]) -> Optional[Dict[int, Any]]:
    """{step index: settled checkpoint} of a case from its `action` step on, or None when it has no action step."""
    start = next((p.index for p in points if p.step == "action"), None)
    if start is None:
        return None
    return {p.index: p for p in points if p.index >= start and p.checkpoint == "settled"}


def verdict_of(run: Any, case: str) -> str:
    """How a case's result enters a comparison: "not-run" (absent, or result None: no launch ran it), "flaky"
    (oracle.py classify: left out of every comparison, as diff.compare_case does), "skipped" (an Expectations skip),
    else "pass" or "fail"."""
    result = run.results.get(case)
    if result is None:
        return "not-run"
    if result == "Flaky":
        return "flaky"
    if result == "Skip":
        return "skipped"
    return "pass" if result in PASSING else "fail"


def compare_pair(run: Any, ident: str, a: str, b: str) -> Tuple[str, Optional[Dict[str, Any]]]:
    """("compared" | "not-run" | "flaky" | "skipped" | "failed", the difference or None) of one pair of one action's
    cases. Only two real verdicts are compared: a difference at /result when exactly one of them passes."""
    ca, cb = f"{SUITE}/{case_id(ident, a)}", f"{SUITE}/{case_id(ident, b)}"
    found = {"action": ident, "a": a, "b": b, "cases": [ca, cb]}
    verdicts = (verdict_of(run, ca), verdict_of(run, cb))
    for status in ("not-run", "flaky", "skipped"):
        if status in verdicts:
            return status, None
    if verdicts == ("fail", "fail"):
        return "failed", None
    if "fail" in verdicts:
        return "compared", {**found, "step": None, "pointer": "/result", "a_value": run.results[ca],
                            "b_value": run.results[cb], "differences": 1}
    sa = settled_from_action(run.checkpoints.get(ca, ()))
    sb = settled_from_action(run.checkpoints.get(cb, ()))
    if sa is None or sb is None:
        return "compared", {**found, "step": "action", "pointer": "/checkpoints", "a_value": sa is not None,
                            "b_value": sb is not None, "differences": 1}
    for index in sorted(set(sa) | set(sb)):
        pa, pb = sa.get(index), sb.get(index)
        if pa is None or pb is None:
            step = (pa or pb).step
            return "compared", {**found, "step": step, "pointer": "", "a_value": pa is not None,
                                "b_value": pb is not None, "differences": 1}
        if pa.step != pb.step:
            return "compared", {**found, "step": pa.step, "pointer": "/step", "a_value": pa.step, "b_value": pb.step,
                                "differences": 1}
        differences = list(diff.iter_differences(comparable(pa.snapshot), comparable(pb.snapshot)))
        if differences:
            pointer, va, vb = differences[0]
            return "compared", {**found, "step": pa.step, "pointer": pointer,
                                "a_value": None if va is diff.MISSING else va,
                                "b_value": None if vb is diff.MISSING else vb, "differences": len(differences)}
    return "compared", None


def load_coverage(out: Path) -> Dict[str, Any]:
    path = out / COVERAGE
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise GenError(f"{path}: {error}") from None
    if data.get("suite") != SUITE or not isinstance(data.get("actions"), dict):
        raise GenError(f"{path}: not this suite's coverage.json")
    return data


def compare(run_dir: Path, coverage: Mapping[str, Any]) -> Dict[str, Any]:
    """The parity report of one run: every pair of every action coverage.json lists with pairs. An action with one
    entrypoint is never in coverage.json, and a case of the run that no pair names is not read."""
    try:
        run = diff.load_run(str(run_dir))
    except diff.InputError as error:
        raise GenError(str(error)) from None
    differences: List[Dict[str, Any]] = []
    apart: Dict[str, List[List[str]]] = {"not-run": [], "flaky": [], "skipped": [], "failed": []}
    compared = 0
    for ident, entry in sorted(coverage["actions"].items()):
        if len(entry.get("entrypoints") or ()) < 2:
            raise GenError(f"coverage.json lists {ident} with fewer than two entrypoints")
        for a, b in entry.get("pairs") or ():
            status, found = compare_pair(run, ident, a, b)
            if status in apart:
                apart[status].append([ident, a, b])
            else:
                compared += 1
                if found:
                    differences.append(found)
    return {"schema": REPORT_SCHEMA, "run": str(run_dir), "sha": run.sha, "host": run.host,
            "verdict": "divergent" if differences else "pass", "compared": compared, "differences": differences,
            "not_run": apart["not-run"], "flaky": apart["flaky"], "skipped": apart["skipped"],
            "failed": apart["failed"]}


# --------------------------------------------------------------------------------------------- self test


def live_catalog(overrides: Optional[Mapping[str, Mapping[str, Any]]] = None) -> gen_actions.Catalog:
    """gen_actions' self-test live catalog with what an action.list entry also has: cli_name and main_menu."""
    surfaces = json.loads(gen_actions.SURFACES.read_text(encoding="utf-8"))["actions"]
    extra: Dict[str, Dict[str, Any]] = {}
    for item in surfaces:
        fields: Dict[str, Any] = {"cli_name": item.get("cli_name")}
        if item.get("main_menu"):
            fields["main_menu"] = item["main_menu"]
        extra[item["id"]] = {**fields, **((overrides or {}).get(item["id"]) or {})}
    return gen_actions.live_catalog(extra)


LIVE_OVERRIDES = {**gen_actions.LIVE_OVERRIDES}


def fake_run(tmp: Path, cases: Mapping[str, Sequence[Tuple[str, str, Any]]],
             results: Optional[Mapping[str, str]] = None) -> Path:
    """A run directory: {case id: [(step, checkpoint, snapshot)]}, steps indexed in order."""
    rows = []
    for case, points in cases.items():
        index, last = -1, None
        for step, checkpoint, snapshot in points:
            if step != last:
                index, last = index + 1, step
            rows.append({"case": case, "step": step, "index": index, "checkpoint": checkpoint, "snapshot": snapshot})
    host = {"name": "h", "os": "macOS", "osVersion": "26", "arch": "arm64", "display": "none"}
    receipt = {"runId": "r", "sha": "abc", "host": host,
               "cases": {case: {"result": (results or {}).get(case, "Pass")} for case in cases}}
    (tmp / "receipt.json").write_text(json.dumps(receipt), encoding="utf-8")
    (tmp / "checkpoints.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    return tmp


def snap(case: str, **facets: Any) -> Dict[str, Any]:
    return {"schema": "cmux.oracle.snapshot/v1", "meta": {"case": case, "capturedAtMs": len(case)}, "facets": facets}


class GenEntrypointsSelfTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.gaps = gen_actions.Gaps.load()
        cls.export = gen_actions.Catalog.load(gen_actions.SURFACES)
        cls.export_files = generate(cls.export, cls.gaps, {})
        cls.catalog = live_catalog(LIVE_OVERRIDES)
        cls.files = generate(cls.catalog, cls.gaps, {})
        cls.coverage = cls.files[COVERAGE]

    def cases(self) -> Dict[str, Dict[str, Any]]:
        return {name: case for name, case in self.files.items() if name != COVERAGE}

    def test_the_suite_lists_the_986_actions_with_two_or_more_entrypoints(self) -> None:
        """oracle-DESIGN.md section 2: 986 actions of action-surfaces.json have 2+ of CLI, MCP, palette, menu, context
        menu and shortcut. From the export no case runs (the actions suite blocks all: no live action.list)."""
        coverage = self.export_files[COVERAGE]
        raws = raw_entries(self.export)
        multi = sorted(i for i, e in raws.items() if len(entrypoints_of(e)) >= 2)
        self.assertEqual(len(multi), 986)
        self.assertEqual(sorted(coverage["actions"]), multi)
        self.assertEqual(set(self.export_files), {COVERAGE})
        self.assertEqual((coverage["total"], coverage["covered"], len(coverage["excluded"])), (986, 0, 986))
        self.assertEqual(set(coverage["blocked_by"]), {"excluded", "gap", "no-live-catalog"})
        self.assertEqual(coverage["entrypoints"]["shortcut"]["listed"],
                         sum(1 for i in multi if raws[i].get("default_shortcut")))

    def test_a_single_entrypoint_action_is_never_listed(self) -> None:
        for files, catalog in ((self.files, self.catalog), (self.export_files, self.export)):
            raws = raw_entries(catalog)
            single = [i for i, e in raws.items() if len(entrypoints_of(e)) < 2]
            self.assertTrue(single)
            for ident in single:
                self.assertNotIn(ident, files[COVERAGE]["actions"], ident)
                self.assertFalse(any(n.startswith(gen_actions.slug(ident) + SEPARATOR) for n in files), ident)

    def test_each_runnable_action_has_one_case_per_compared_entrypoint_with_the_same_setup(self) -> None:
        compared = 0
        for ident, entry in self.coverage["actions"].items():
            if "blocked" in entry:
                continue
            compared += 1
            cases = [self.files[f"{case_id(ident, name)}.json"] for name in entry["cases"]]
            self.assertGreaterEqual(len(cases), 2, ident)
            without = [[s for s in c["steps"] if s["id"] != "action"] for c in cases]
            for other in without[1:]:
                self.assertEqual(other, without[0], ident)
            indexes = {next(i for i, s in enumerate(c["steps"]) if s["id"] == "action") for c in cases}
            self.assertEqual(len(indexes), 1, ident)
            for name, case in zip(entry["cases"], cases):
                main = next(s for s in case["steps"] if s["id"] == "action")
                self.assertEqual(main["op"], {"shortcut": "key", "cli": "cli", "mcp": "mcp"}[name], ident)
            for a, b in entry["pairs"]:
                self.assertIn(a, entry["cases"])
                self.assertIn(b, entry["cases"])
        self.assertGreater(compared, 400)
        self.assertEqual(compared, self.coverage["covered"])

    def test_steps_carry_the_run_the_way_each_entrypoint_takes_it(self) -> None:
        cli = self.files["workspace-new-in-new-group--cli.json"]
        main = next(s for s in cli["steps"] if s["id"] == "action")
        self.assertEqual(main["args"]["argv"], ["workspace", "new-in-new-group", "--focus"])
        self.assertEqual(main["checkpoint"], ["before", "settled"])
        mcp = self.files["workspace-new-in-new-group--mcp.json"]
        main = next(s for s in mcp["steps"] if s["id"] == "action")
        self.assertEqual(main["args"], {"tool": "app_workspace_new_in_new_group", "arguments": {"focus": True}})
        self.assertIn("mcp", mcp["requires"])
        raw = {"id": "closeTab", "cli_name": "tab close", "shortcut_config": "cmd+w"}
        row = {"key": ["w", ["cmd"]]}
        step, why = main_step("shortcut", "closeTab", raw, row, {"confirm": True}, {}, {})
        self.assertIsNone(step)
        self.assertIn("a key carries no arguments", why)
        step, _ = main_step("cli", "closeTab", raw, row, {"confirm": True}, {}, {})
        self.assertEqual(step["args"]["argv"], ["tab", "close", "--confirm", "--focus"])
        step, _ = main_step("mcp", "closeTab", raw, row, {"confirm": True}, {}, {})
        self.assertEqual(step["args"], {"tool": "app_tab_close", "arguments": {"confirm": True, "focus": True}})
        step, why = main_step("mcp", "closeTab", raw, row, {}, {}, {"app_tab_close": ["closeTab", "tab.close"]})
        self.assertIsNone(step)
        self.assertIn("also tab.close's", why)
        split = next(s for s in self.files["split-right--shortcut.json"]["steps"] if s["id"] == "action")
        self.assertEqual(split["checkpoint"], ["before", "turn", "settled"])
        self.assertEqual(split["waitFor"]["pointer"], gen_actions.WORKSPACES)

    def test_palette_and_menus_are_listed_with_why_they_have_no_case(self) -> None:
        settings = self.coverage["actions"]["openSettings"]
        self.assertEqual(settings["entrypoints"], ["shortcut", "palette", "main-menu"])
        self.assertEqual((settings["blocked_by"], settings["task"]), ("no-step", NO_STEP_TASK))
        self.assertEqual(settings["blocked_entrypoints"]["palette"], NO_STEP["palette"])
        self.assertFalse(any(name.startswith("open-settings--") for name in self.files))
        for name in ("palette", "main-menu", "context-menu"):
            self.assertEqual(self.coverage["entrypoints"][name]["runnable"], 0)
            self.assertGreater(self.coverage["entrypoints"][name]["listed"], 0)
            self.assertIn(NO_STEP_TASK, NO_STEP[name])

    def test_one_entrypoint_is_only_for_actions_no_step_would_not_unblock(self) -> None:
        """An action whose second runnable entrypoint waits for a palette, menu or context-menu step is `no-step`
        with the task that adds it, never `one-entrypoint`."""
        waiting = 0
        for ident, entry in self.coverage["actions"].items():
            kind = entry.get("blocked_by")
            if kind not in ("no-step", "one-entrypoint"):
                continue
            blocked = entry.get("blocked_entrypoints") or {}
            runnable = [n for n in entry["entrypoints"] if n not in blocked]
            waits = [n for n in entry["entrypoints"] if n in NO_STEP or blocked.get(n) == KEY_REFUSAL]
            self.assertLess(len(runnable), 2, ident)
            self.assertEqual(kind == "no-step", len(runnable) + len(waits) >= 2, ident)
            if kind == "no-step":
                waiting += 1
                self.assertEqual(entry["task"], NO_STEP_TASK, ident)
        self.assertGreater(waiting, 100)
        self.assertEqual(self.coverage["blocked_by"]["no-step"], waiting)
        self.assertGreaterEqual(self.coverage["tasks"][NO_STEP_TASK]["actions"], waiting)

    def test_entrypoints_expected_to_differ_are_not_paired(self) -> None:
        """palette.newAgentChat docks a chat by key and opens a tab by action.run (the sweep's EXPECT_BY_ENTRY)."""
        entry = self.coverage["actions"]["palette.newAgentChat"]
        for pair in entry.get("pairs") or ():
            self.assertNotIn("shortcut", pair)
        if "shortcut" in entry["entrypoints"]:
            self.assertIn("EXPECT_BY_ENTRY", entry["blocked_entrypoints"]["shortcut"])

    def test_a_tuned_refusal_expects_each_entrypoints_own_refusal_and_pairs_them(self) -> None:
        ident = "workspace.newInNewGroup"
        files = generate(self.catalog, self.gaps, {ident: {"error": "control.unavailable"}})
        entry = files[COVERAGE]["actions"][ident]
        self.assertNotIn("blocked", entry)
        self.assertIn(["cli", "mcp"], entry["pairs"])
        for name, code in REFUSAL_CODES.items():
            case = files[f"{case_id(ident, name)}.json"]
            main = next(s for s in case["steps"] if s["id"] == "action")
            self.assertEqual(main["expect"], {"outcome": "error", "error": code}, name)
            self.assertEqual(main["checkpoint"], ["before", "settled"], name)
            self.assertNotIn("waitFor", main, name)
            self.assertFalse(any(s["id"].startswith("restore-") for s in case["steps"]), name)
            self.assertTrue(any("control.unavailable" in u for u in case["untested"]), name)
            self.assertEqual(gen_actions.CaseCheck().problems(case), [], name)
        raw = {"id": "closeTab", "cli_name": "tab close", "shortcut_config": "cmd+w"}
        step, why = main_step("shortcut", "closeTab", raw, {"key": ["w", ["cmd"]]}, {}, {"error": "control.refused"}, {})
        self.assertIsNone(step)
        self.assertEqual(why, KEY_REFUSAL)

    def test_blocked_actions_are_excluded_with_their_reason(self) -> None:
        flagged = self.coverage["actions"]["tabGroup.close"]
        self.assertEqual(flagged["blocked_by"], "flag")
        for ident, reason in self.coverage["excluded"].items():
            self.assertTrue(reason.startswith("blocked: "), ident)

    def test_cli_values_and_tool_names(self) -> None:
        self.assertEqual(cli_flags({"title": "Build", "keepSessions": True, "count": 3, "on": False}),
                         (["--count", "3", "--keepSessions", "--on", "false", "--title", "Build"], None))
        self.assertIn("flag the CLI reads itself", cli_flags({"target": "tab_1"})[1])
        self.assertIn("list", cli_flags({"ids": [1]})[1])
        self.assertEqual(tool_name("app new-window"), "app_new_window")
        self.assertEqual(tool_name("workspace move-to-window"), "app_workspace_move_to_window")
        self.assertIsNone(tool_name("app"))
        self.assertIsNone(tool_name("tab rename…"))

    def test_cases_pass_the_case_schema(self) -> None:
        check = gen_actions.CaseCheck()
        for name, case in sorted(self.cases().items()):
            self.assertEqual(check.problems(case), [], name)
            self.assertEqual(case["id"] + ".json", name)
            self.assertRegex(case["id"], r"^[a-z0-9][a-z0-9-]{0,63}$")

    def test_regeneration_is_byte_stable_and_check_finds_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            write(out, self.files)
            self.assertEqual(drift(out, self.files), [])
            self.assertEqual(write(out, self.files), (0, 0))
            name = "split-right--cli.json"
            (out / name).write_text("{}\n", encoding="utf-8")
            self.assertEqual(drift(out, self.files), [f"{name}: differs from a fresh generation"])
            self.assertEqual(write(out, self.export_files)[1], len(self.cases()))
            self.assertEqual(sorted(p.name for p in out.iterdir()), [COVERAGE])
            (out / "hand-written.json").write_text("{}\n", encoding="utf-8")
            with self.assertRaises(GenError):
                write(out, {**self.files, "hand-written.json": {}})

    def test_compare_reports_action_a_b_and_pointer(self) -> None:
        ident = "workspace.newInNewGroup"
        a, b = (f"{SUITE}/{case_id(ident, n)}" for n in ("cli", "mcp"))
        coverage = {"suite": SUITE, "actions": {ident: {"entrypoints": ["cli", "mcp", "palette"],
                                                        "pairs": [["cli", "mcp"]]}}}
        same = {"topology": {"tab_count": 2}}
        with tempfile.TemporaryDirectory() as tmp:
            run = fake_run(Path(tmp), {
                a: [("prepare-1", "settled", snap(a, **same)), ("action", "before", snap(a, **same)),
                    ("action", "settled", snap(a, cli={"exit": 0, "stdout": None}, **same))],
                b: [("prepare-1", "settled", snap(b, **same)), ("action", "before", snap(b, **same)),
                    ("action", "settled", snap(b, **same))],
            })
            report = compare(run, coverage)
        self.assertEqual((report["verdict"], report["compared"], report["differences"]), ("pass", 1, []))
        with tempfile.TemporaryDirectory() as tmp:
            run = fake_run(Path(tmp), {
                a: [("action", "settled", snap(a, topology={"tab_count": 2}))],
                b: [("action", "settled", snap(b, topology={"tab_count": 3}))],
            })
            report = compare(run, coverage)
        self.assertEqual(report["verdict"], "divergent")
        found = report["differences"][0]
        self.assertEqual((found["action"], found["a"], found["b"], found["pointer"], found["a_value"], found["b_value"]),
                         (ident, "cli", "mcp", "/facets/topology/tab_count", 2, 3))

    def test_compare_reads_only_listed_pairs_and_reports_results(self) -> None:
        ident = "workspace.newInNewGroup"
        a, b = (f"{SUITE}/{case_id(ident, n)}" for n in ("cli", "mcp"))
        stray = f"{SUITE}/{case_id('openSettings', 'cli')}"
        coverage = {"suite": SUITE, "actions": {ident: {"entrypoints": ["cli", "mcp"], "pairs": [["cli", "mcp"]]}}}
        with tempfile.TemporaryDirectory() as tmp:
            run = fake_run(Path(tmp), {
                a: [("action", "settled", snap(a))], b: [("action", "settled", snap(b))],
                stray: [("action", "settled", snap(stray, topology={"x": 1}))],
            }, results={b: "Failure"})
            report = compare(run, coverage)
        self.assertEqual([(d["action"], d["pointer"], d["a_value"], d["b_value"]) for d in report["differences"]],
                         [(ident, "/result", "Pass", "Failure")])
        self.assertNotIn("openSettings", json.dumps(report))
        with tempfile.TemporaryDirectory() as tmp:
            run = fake_run(Path(tmp), {a: [("action", "settled", snap(a))]})
            self.assertEqual(compare(run, coverage)["not_run"], [[ident, "cli", "mcp"]])
        with self.assertRaises(GenError):
            compare(Path("/nonexistent-oracle-run"), coverage)

    def test_compare_leaves_flaky_skipped_and_not_run_cases_out(self) -> None:
        """oracle.py classify: Flaky is left out of every comparison, Skip is an Expectations skip and result None
        is a case no launch ran; none of them paired with a pass is a parity difference."""
        ident = "workspace.newInNewGroup"
        a, b = (f"{SUITE}/{case_id(ident, n)}" for n in ("cli", "mcp"))
        coverage = {"suite": SUITE, "actions": {ident: {"entrypoints": ["cli", "mcp"], "pairs": [["cli", "mcp"]]}}}
        points = {a: [("action", "settled", snap(a, topology={"x": 1}))],
                  b: [("action", "settled", snap(b, topology={"x": 2}))]}
        for result, bucket in (("Flaky", "flaky"), ("Skip", "skipped"), (None, "not_run")):
            for side in (a, b):
                with tempfile.TemporaryDirectory() as tmp:
                    report = compare(fake_run(Path(tmp), points, results={side: result}), coverage)
                self.assertEqual((report["verdict"], report["compared"], report["differences"]), ("pass", 0, []),
                                 (result, side))
                self.assertEqual(report[bucket], [[ident, "cli", "mcp"]], (result, side))
        with tempfile.TemporaryDirectory() as tmp:
            report = compare(fake_run(Path(tmp), points, results={a: "Slow"}), coverage)
        self.assertEqual(report["differences"][0]["pointer"], "/facets/topology/x")
        with tempfile.TemporaryDirectory() as tmp:
            run = fake_run(Path(tmp), {a: [("action", "settled", snap(a))]})
            lone = {"suite": SUITE, "actions": {ident: {"entrypoints": ["cli"], "pairs": [["cli", "mcp"]]}}}
            with self.assertRaises(GenError):
                compare(run, lone)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="the suite directory (default: the corpus)")
    parser.add_argument("--catalog", type=Path, help="an action.list reply or action-surfaces.json (gen_actions.py's "
                                                     "default when absent)")
    parser.add_argument("--gaps", type=Path, default=gen_actions.GAPS, help="the sweep's gap list")
    parser.add_argument("--actions", type=Path, default=ACTIONS_DIR,
                        help="the actions suite directory whose <family>/_tuning.json the cases take")
    parser.add_argument("--check", action="store_true", help="exit 1 when --out differs from a fresh generation")
    parser.add_argument("--compare", type=Path, metavar="RUN", help="compare the entrypoint pairs of an oracle run")
    parser.add_argument("--report", type=Path, help="with --compare: write the report JSON here")
    parser.add_argument("--selftest", action="store_true", help="run the offline self tests")
    args = parser.parse_args(argv)
    if args.selftest:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(GenEntrypointsSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    try:
        if args.compare:
            report = compare(args.compare, load_coverage(args.out))
            if args.report:
                args.report.write_text(render(report), encoding="utf-8")
            for found in report["differences"]:
                print(f"gen_entrypoints: {found['action']}: {found['a']} != {found['b']} at {found['step']} "
                      f"{found['pointer'] or '/'} ({json.dumps(found['a_value'])[:80]} vs "
                      f"{json.dumps(found['b_value'])[:80]})")
            print(f"gen_entrypoints: {report['compared']} pairs compared, {len(report['differences'])} differ, "
                  f"{len(report['failed'])} failed on both sides, {len(report['not_run'])} not run, "
                  f"{len(report['flaky'])} flaky, {len(report['skipped'])} skipped")
            return 1 if report["differences"] else 0
        catalog = gen_actions.Catalog.load(args.catalog)
        files = generate(catalog, gen_actions.Gaps.load(args.gaps), gen_actions.load_tuning(args.actions, catalog))
        coverage = files[COVERAGE]
        if args.check:
            problems = drift(args.out, files)
            for problem in problems:
                print(f"gen_entrypoints: {problem}", file=sys.stderr)
            print(f"gen_entrypoints: {coverage['covered']} compared + {len(coverage['excluded'])} excluded of "
                  f"{coverage['total']} actions, {'stale' if problems else 'up to date'}")
            return 1 if problems else 0
        written, removed = write(args.out, files)
    except (GenError, gen_actions.GenError) as error:
        print(f"gen_entrypoints: {error}", file=sys.stderr)
        return 2
    print(f"gen_entrypoints: {coverage['covered']} compared + {len(coverage['excluded'])} excluded of "
          f"{coverage['total']} actions, {coverage['cases']} cases, {written} files written, {removed} removed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
