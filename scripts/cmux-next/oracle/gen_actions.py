#!/usr/bin/env python3
"""Generate the actions suite: one case per action of the catalog the every-action sweep does not exclude.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3D (suite actions) and task 071. Stdlib plus the
sweep it reuses, Python 3.9+, safe under `python3 -I`. `oracle.py gen --suite actions` runs it with
`--out <corpus>/actions`.

Chrome reference (chromium/src): chrome/browser/ui/views/accelerator_table_unittest.cc walks every entry of the
accelerator table instead of one hand-written test per shortcut, and chrome/test/interaction/
interactive_browser_test.h gives every interactive UI test one shared setup and verb set. Here the table is the
catalog and the shared setup is the sweep's: every-action-sweep.py's plan of the action (Sweep.plan and plan_row,
loaded through action_fixtures.load_sweep where it is) gives its entrypoint, registry context, arguments and
PREPARE steps. The catalog is a live `action.list` reply checked in as tests/oracle/fixtures/actions/
action-list.json when a fleet run has captured one, else plans/cmux-next/action-surfaces.json, which has no
registry contexts or arguments (coverage.json `contexts` says which).

Per action that every-action-gaps.json does not exclude, one case `<slug>.json`:

  context-N   the tab kind the action's registry context needs (CONTEXT_STEPS), when the catalog says it
  neighbor-N  a pane beside the focused one, for a directional move (NEIGHBOR_STEPS)
  prepare-N   the sweep's PREPARE steps (and a family fixture's), as action.run
  ...         a family's tuned `before` steps
  action      the real entrypoint: its default single-stroke shortcut as a key step through debug.key, else
              action.run (the CLI and palette path), as the sweep plans it; checkpoints before, turn, settled
              (the settled checkpoint is debug.oracle.settle then the snapshot)
  restore-N   the sweep's restore of what no reset sees: a toggle runs again, a fit is undone (UNDO)

An action is blocked, not runnable (BLOCK_KINDS), when every-action-gaps.json lists it as a gap (no fixture yet:
tasks 082-087 close them), when the sweep's plan skips it with this catalog, or when an argument has only a live
value (the sweep's `<base.*>` or `<fixture ...>` placeholders). A blocked case is written whole into `_blocked.json`
(oracle.py skips `_` files), with its reason in `untested`; when its gap closes, regeneration moves it to its own
file. coverage.json counts the runnable cases as covered and each blocked action as excluded with its reason.

The families of tasks 072-081 tune their actions in `<family>/_tuning.json` (FAMILIES), which this generator
reads, so regeneration keeps the tuning and stays byte-stable: {"actions": {id: {entry, params, receipt, error,
before, waitFor, settleMaxMs, invariants, untested, requires, note}}}. Every case, tuned or not, is checked
against schemas/oracle/case-v1.schema.json before anything is written.

Usage:
  gen_actions.py --out DIR [--catalog PATH]          write the cases, _blocked.json and coverage.json into DIR
  gen_actions.py --out DIR [--catalog PATH] --check  exit 1 when DIR differs from a fresh generation
  gen_actions.py --selftest                          offline tests against the checked-in catalog
"""

from __future__ import annotations

import argparse
import atexit
import copy
import hashlib
import json
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import action_fixtures  # noqa: E402  (the sweep's loader, shared with every-action-sweep.py)

SURFACES = REPO / "plans" / "cmux-next" / "action-surfaces.json"
# A live action.list reply checked in from a fleet run (a sweep run's OUT/action-list.json). It has what the export
# lacks: each action's registry contexts, arguments and flags, so the sweep plans their setup. The default catalog
# when present, else SURFACES.
LIVE_CATALOG = REPO / "tests" / "oracle" / "fixtures" / "actions" / "action-list.json"
GAPS = REPO / "scripts" / "cmux-next" / "every-action-gaps.json"
DEFAULT_OUT = REPO / "tests" / "oracle" / "corpus" / "actions"
CASE_SCHEMA = REPO / "schemas" / "oracle" / "case-v1.schema.json"
SUITE = "actions"
GENERATOR = "scripts/cmux-next/oracle/gen_actions.py"
SCHEMA_REF = "../../../../schemas/oracle/case-v1.schema.json"
COVERAGE = "coverage.json"
BLOCKED = "_blocked.json"
TUNING = "_tuning.json"
# The session whose plan a case takes: the oracle launches one fresh session per batch, as the sweep's light one.
SESSION = "light"

# Tasks 072-081: the family directory of an action is picked by its prefix (family_prefix). A prefix no family
# names is misc's (task 081, the remaining small families).
FAMILIES: Dict[str, Tuple[str, ...]] = {
    "browser": ("browser", "browserProfile", "devtools"),
    "palette": ("palette", "paletteKey"),
    "appearance": ("appearance", "toggle"),
    "sidebar": ("sidebar", "workspaceGroup"),
    "workspace": ("workspace", "home", "space"),
    "layout": ("screen", "screenGroup", "column", "layout", "split", "resize", "swap", "move"),
    "tabs": ("tabGroup", "tab", "newTab", "close", "reopen", "new"),
    "agents": ("agentPane", "agentChat", "agent", "chief"),
    "focus": ("terminal", "find", "focus", "focusRing", "pane"),
    "misc": (),
}
FAMILY_OF = {prefix: family for family, prefixes in FAMILIES.items() for prefix in prefixes}
FAMILY_TASK = {"browser": "p15-oracle-072", "palette": "p15-oracle-073", "appearance": "p15-oracle-074",
               "sidebar": "p15-oracle-075", "workspace": "p15-oracle-076", "layout": "p15-oracle-077",
               "tabs": "p15-oracle-078", "agents": "p15-oracle-079", "focus": "p15-oracle-080", "misc": "p15-oracle-081"}
GAP_TASKS = "p15-oracle-082..087 (gap fixtures in oracle/action_fixtures/<family>.py)"

# The tab kind a registry context needs (the sweep's CONTEXT_SETUP values) as action.run steps on a fresh session.
# The launch's first workspace shows its terminal (perf-stress-session build_light: a new workspace starts with
# one), so `terminal` needs none. The action path of New Agent Chat opens a chat tab (the sweep's EXPECT_BY_ENTRY).
CONTEXT_STEPS: Dict[str, Tuple[Tuple[str, Dict[str, Any]], ...]] = {
    "terminal": (),
    "chromium": (("openBrowser.chromium", {}),),
    "omnibar": (("openBrowser.chromium", {}), ("focusLocation", {})),
    "chat": (("palette.newAgentChat", {}),),
}
# A neighbor pane the way a directional move goes (the sweep's DIRECTIONS): its light grid has one, a fresh
# session has a single pane. A split focuses the new pane, so a move left or up starts from it.
NEIGHBOR_STEPS: Dict[str, Tuple[Tuple[str, Dict[str, Any]], ...]] = {
    "left": (("splitRight", {}),),
    "right": (("splitRight", {}), ("focusLeft", {})),
    "up": (("splitDown", {}),),
    "down": (("splitDown", {}), ("focusUp", {})),
}
# The sweep's checked expectations, in words for the case's reviewer.
EXPECT_WORDS = {
    "pane+": "the settled layout has one pane more than before the input",
    "pane-": "the settled layout has one pane fewer than before the input",
    "tab+": "the settled layout has one tab more than before the input",
    "tab-": "the settled layout has one tab fewer than before the input",
    "workspace+": "the settled topology has one workspace more than before the input",
    "workspace-": "the settled topology has one workspace fewer than before the input",
    "window+": "the settled topology has one window more than before the input",
    "focus": "the focused pane moved to the neighbor that way",
    "chat_dock+": "the workspace docks its agent chat; the grid's tab count does not change",
}
ACTION_RECEIPTS = ("action.done", "action.applied", "action.waiting")
NO_RECEIPT = ("no app reply carries the ActionEffect kind yet (driver_app.py); the family task names the receipt in "
              "<family>/_tuning.json")
SETUP_NO_RECEIPT = "a setup step: the case checks the action under test, not its setup"
RESTORE_NO_RECEIPT = "a restore step: it puts back what the action under test changed"
# case-v1 $defs/keystroke.
KEYSTROKE = re.compile(r"^((cmd|ctrl|opt|alt|shift|fn)\+)*([a-z0-9]|[-=\[\];',./`\\]|plus|f[1-9]|f1[0-9]|return|escape|"
                       r"tab|space|backspace|delete|left|right|up|down|home|end|pageup|pagedown)$")
# The sweep's debug.key modifier names -> case-v1's.
MODIFIER_OF = {"cmd": "cmd", "shift": "shift", "option": "opt", "control": "ctrl"}
# The sweep's key names (shortcut_config tokens) -> case-v1's: the config's `delete` is the backspace character
# (ShortcutBindingFormat.configToken), which driver_app sends to debug.key as `delete` again.
KEY_OF = {"+": "plus", "delete": "backspace"}
STEP_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
ERROR_CODE = re.compile(r"^[a-z][a-z_]*(\.[a-z][a-z_]*)+$")
PLACEHOLDER = re.compile(r"<(base\.[a-z_]+|fixture [^>]+)>")
# Why a case is blocked: a gap of every-action-gaps.json (no fixture yet); the sweep's plan skips the action with this
# catalog (an exclusion the reviewed list does not name, or a context the sweep does not set up); or an argument has
# only a live value.
BLOCK_KINDS = ("gap", "plan", "live-value")
TUNING_KEYS = frozenset({"entry", "params", "receipt", "error", "before", "waitFor", "settleMaxMs", "invariants",
                         "untested", "requires", "note"})
TUNING_CAPABILITIES = frozenset({"keys", "gui", "chromium", "mcp"})
BEFORE_OPS = frozenset({"action.run", "key", "cli", "mcp", "settle", "snapshot"})


class GenError(Exception):
    """The catalog, the gap list, the sweep's plan or a tuning file cannot make the suite."""


# ------------------------------------------------------------------------------------------------ catalog

# ShortcutBindingFormat.configToken (CmuxNextSettings/ShortcutBinding.swift): AppKit function-key characters.
CONFIG_TOKENS = {"": "left", "": "right", "": "up", "": "down", "": "home",
                 "": "end", "": "pageup", "": "pagedown", "\t": "tab", "\r": "return",
                 "\x1b": "escape", "\x08": "delete", "\x7f": "delete", " ": "space", "+": "plus",
                 **{chr(0xF704 + n): f"f{n + 1}" for n in range(20)}}


def config_string(stroke: Mapping[str, Any]) -> str:
    """An action-surfaces `default_shortcut` as action.list's `shortcut_config` (ShortcutBindingFormat.configString:
    cmd, shift, opt, ctrl, then the key's config token)."""
    mods = set(stroke.get("modifiers") or ())
    unknown = sorted(mods - {"cmd", "shift", "opt", "ctrl"})
    if unknown:
        raise GenError(f"shortcut {stroke!r}: unknown modifiers {unknown}")
    key = stroke.get("key")
    if not isinstance(key, str) or not key:
        raise GenError(f"shortcut {stroke!r}: no key")
    parts = [m for m in ("cmd", "shift", "opt", "ctrl") if m in mods]
    return "+".join(parts + [CONFIG_TOKENS.get(key, key)])


def default_catalog() -> Path:
    return LIVE_CATALOG if LIVE_CATALOG.is_file() else SURFACES


def listed(entry: Mapping[str, Any]) -> Dict[str, Any]:
    """An action-surfaces.json entry in the action.list shape the sweep's plan reads. The export has no registry
    contexts, arguments or flags: those plans have no context and no arguments (a live --catalog has them)."""
    stroke = entry.get("default_shortcut")
    return {"id": entry["id"], "title": entry.get("title") or entry["id"],
            "shortcut_config": config_string(stroke) if stroke else None,
            "surfaces": {k: entry.get(k) for k in ("palette", "cli", "context_menu", "mcp")},
            "requires": [], "arguments": [], "targets": []}


class Catalog:
    """The actions, in the action.list shape, sorted by id: action-surfaces.json converted, or an action.list
    reply (a sweep run's OUT/action-list.json) as it is."""

    def __init__(self, path: Path, text: str):
        self.path = path
        self.sha256 = hashlib.sha256(text.encode("utf-8")).hexdigest()
        try:
            data = json.loads(text)
            entries = data["actions"]
        except (ValueError, KeyError, TypeError) as error:
            raise GenError(f"{path}: not action-surfaces.json or an action.list reply: {error!r}") from None
        if not isinstance(entries, list) or not all(isinstance(e, dict) and isinstance(e.get("id"), str) for e in entries):
            raise GenError(f"{path}: `actions` is a list of objects with an id")
        self.live = bool(entries) and "default_shortcut" not in entries[0]
        actions = [dict(e) if self.live else listed(e) for e in entries]
        self.actions = sorted(actions, key=lambda a: a["id"])
        ids = [a["id"] for a in self.actions]
        if len(set(ids)) != len(ids):
            raise GenError(f"{path}: an action id is listed twice")
        self.by_id = {a["id"]: a for a in self.actions}

    @classmethod
    def load(cls, path: Optional[Path] = None) -> "Catalog":
        path = path or default_catalog()
        try:
            return cls(path, path.read_text(encoding="utf-8"))
        except OSError as error:
            raise GenError(f"{path}: {error}") from None

    @property
    def label(self) -> str:
        try:
            return self.path.resolve().relative_to(REPO).as_posix()
        except ValueError:
            return self.path.name


class Gaps:
    """every-action-gaps.json: the reviewed exclusions and the gaps (no fixture yet), each with its reason."""

    def __init__(self, path: Path, text: str):
        self.path = path
        self.sha256 = hashlib.sha256(text.encode("utf-8")).hexdigest()
        try:
            data = json.loads(text)
            self.excluded: Dict[str, str] = dict(data["excluded"])
            self.gaps: Dict[str, str] = dict(data["gaps"])
        except (ValueError, KeyError, TypeError) as error:
            raise GenError(f"{path}: not the sweep's gap list: {error!r}") from None
        both = sorted(set(self.excluded) & set(self.gaps))
        if both:
            raise GenError(f"{path}: excluded and a gap at once: {both[:5]}")

    @classmethod
    def load(cls, path: Path = GAPS) -> "Gaps":
        try:
            return cls(path, path.read_text(encoding="utf-8"))
        except OSError as error:
            raise GenError(f"{path}: {error}") from None


# ------------------------------------------------------------------------------------------------ sweep plan

_SWEEP: Optional[ModuleType] = None


def sweep_module() -> ModuleType:
    """every-action-sweep.py as a module in --plan-only mode (action_fixtures.load_sweep): its plan, PREPARE, the
    families' fixtures and key_of, where they are. Loaded once per process; its scratch dirs go at exit."""
    global _SWEEP
    if _SWEEP is None:
        out = tempfile.mkdtemp(prefix="gen-actions-plan-")
        try:
            module = action_fixtures.load_sweep(["--plan-only", "--catalog", str(SURFACES), "--out", out])
        except action_fixtures.FixtureError as error:
            shutil.rmtree(out, ignore_errors=True)
            raise GenError(f"every-action-sweep.py: {error}") from None
        for scratch in (out, getattr(module, "SCRATCH", None)):
            if scratch:
                atexit.register(shutil.rmtree, scratch, True)
        _SWEEP = module
    return _SWEEP


class Planner:
    """The sweep's plan of one action in its light session, read with no app (plan_row, as --plan-only)."""

    def __init__(self, module: ModuleType):
        self.module = module
        self.sweep = module.Sweep(None, SESSION, None)
        self.sweep.base, self.sweep.fixtures = dict(module.PLAN_BASE), module.PLAN_FIXTURES

    def plan(self, action: Mapping[str, Any]) -> Dict[str, Any]:
        return self.module.plan_row(self.sweep, dict(action))

    def unplanned(self, action: Mapping[str, Any]) -> Dict[str, Any]:
        """The row of an action the plan skips, for its blocked case: its shortcut, else action.run, no setup."""
        ident = action["id"]
        key = self.module.key_of(action)
        return {"id": ident, "entry": "key" if key else "action", "key": list(key) if key else None, "args": {},
                "context": None, "prepare": [], "toggled": False, "expect": {}}

    def owner(self, context: str) -> Optional[str]:
        return self.module.FAMILIES.owners.get(context)


# ------------------------------------------------------------------------------------------------ cases


def family_prefix(ident: str) -> str:
    """The id's first segment (`browserProfile.create` -> browserProfile), or the first word of a camel-case id
    (`newTab` -> new)."""
    if "." in ident:
        return ident.split(".", 1)[0]
    match = re.match(r"^([a-z]+)[A-Z0-9]", ident)
    return match.group(1) if match else ident


def family_of(ident: str) -> str:
    return FAMILY_OF.get(family_prefix(ident), "misc")


def slug(ident: str) -> str:
    """`browser.tabGroup.close` -> browser-tab-group-close: the case id and file name."""
    text = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", ident)
    text = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1-\2", text)
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def keystroke(key: Sequence[Any]) -> Optional[str]:
    """The sweep's (key, debug.key modifiers) as a case-v1 keystroke (`cmd+shift+d`), or None when the grammar has
    no such key."""
    name, mods = key
    if any(m not in MODIFIER_OF for m in mods):
        return None
    stroke = "+".join([MODIFIER_OF[m] for m in mods] + [KEY_OF.get(name, name)])
    return stroke if KEYSTROKE.match(stroke) else None


def run_step(step_id: str, action: str, params: Mapping[str, Any], no_receipt: str) -> Dict[str, Any]:
    args: Dict[str, Any] = {"action": action}
    if params:
        args["params"] = dict(params)
    return {"id": step_id, "op": "action.run", "target": {"window": "current"}, "args": args,
            "expect": {"outcome": "ok", "noReceiptReason": no_receipt}}


def placeholders(value: Any, path: str) -> List[str]:
    """`params.<name>` = the sweep's placeholder for each argument only a live app can give."""
    found: List[str] = []
    if isinstance(value, str):
        match = PLACEHOLDER.search(value)
        if match:
            found.append(f"{path} = <{match.group(1)}>")
    elif isinstance(value, dict):
        for key in sorted(value):
            found.extend(placeholders(value[key], f"{path}.{key}"))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found.extend(placeholders(item, f"{path}[{index}]"))
    return found


def merged(params: Mapping[str, Any], tuned: Mapping[str, Any]) -> Dict[str, Any]:
    out = dict(params)
    for key, value in tuned.items():
        if value is None:
            out.pop(key, None)
        else:
            out[key] = value
    return out


def build_case(action: Mapping[str, Any], row: Mapping[str, Any], planner: Planner, catalog: Catalog,
               spec: Mapping[str, Any], blocked: Optional[str]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    """(case, coverage entry) of one action from its plan row and tuning; `blocked` is why it cannot run yet."""
    ident = action["id"]
    case_id = slug(ident)
    family = family_of(ident)
    task = FAMILY_TASK[family]
    steps: List[Dict[str, Any]] = []
    setup: List[str] = []

    def add_setup(prefix: str, items: Sequence[Sequence[Any]]) -> None:
        for number, (name, params) in enumerate(items, 1):
            step_id = f"{prefix}-{number}"
            steps.append(run_step(step_id, name, params, SETUP_NO_RECEIPT))
            setup.append(f"{step_id} {name}")

    context = row.get("context")
    if context is not None and context not in CONTEXT_STEPS:
        raise GenError(f"{ident}: the sweep's context {context!r} has no CONTEXT_STEPS entry")
    add_setup("context", CONTEXT_STEPS.get(context, ()) if context else ())
    add_setup("neighbor", NEIGHBOR_STEPS.get(row.get("direction") or "", ()))
    add_setup("prepare", [(name, params) for name, params in row.get("prepare") or ()])
    for item in spec.get("before") or ():
        steps.append(copy.deepcopy(item))
        setup.append(f"{item['id']} {item.get('args', {}).get('action') or item['op']}")

    stroke = keystroke(row["key"]) if row.get("entry") == "key" and row.get("key") else None
    entry = spec.get("entry") or ("key" if stroke else "action")
    if entry == "key" and not stroke:
        raise GenError(f"{ident}: entry key, but the action has no single-stroke shortcut case-v1 can send")
    params = dict(row.get("args") or {})
    if action.get("destructive"):
        params["confirm"] = True  # the script caller's confirm, as the sweep's act() gives it
    params = merged(params, spec.get("params") or {})
    if entry == "key":
        if spec.get("params"):
            raise GenError(f"{ident}: params tune action.run, and the case's entry is its key")
        main: Dict[str, Any] = {"id": "action", "op": "key", "target": {"window": "current"},
                                "args": {"keys": [stroke]}}
    else:
        main = {"id": "action", "op": "action.run", "target": {"window": "current"}, "args": {"action": ident}}
        if params:
            main["args"]["params"] = params
    if "error" in spec:
        main["expect"] = {"outcome": "error", "error": spec["error"]}
    elif "receipt" in spec:
        main["expect"] = {"outcome": "ok", "receipt": spec["receipt"]}
    else:
        main["expect"] = {"outcome": "ok", "noReceiptReason": NO_RECEIPT}
    main["checkpoint"] = ["before", "turn", "settled"]
    for key in ("waitFor", "settleMaxMs", "note"):
        if key in spec:
            main[key] = copy.deepcopy(spec[key])
    steps.append(main)

    restore: List[Tuple[str, Dict[str, Any]]] = []
    if row.get("toggled"):
        restore.append((ident, params if entry == "action" else {}))
    if row.get("undo"):
        name, undo_params = row["undo"]
        restore.append((name, dict(undo_params)))
    for number, (name, restore_params) in enumerate(restore, 1):
        steps.append(run_step(f"restore-{number}", name, restore_params, RESTORE_NO_RECEIPT))

    taken: Dict[str, int] = {}
    for step in steps:
        taken[step["id"]] = taken.get(step["id"], 0) + 1
    twice = sorted(k for k, n in taken.items() if n > 1)
    if twice:
        raise GenError(f"{ident}: step ids {twice} are used twice (a tuned before step takes a generated id)")

    requires = ["actions"]
    if any(step["op"] == "key" for step in steps):
        requires.append("keys")
    for capability in spec.get("requires") or ():
        if capability not in requires:
            requires.append(capability)
    title = action.get("title") or ident
    how = f"its shortcut {stroke}" if entry == "key" else "action.run"
    fixture: Dict[str, Any] = {"seed": f"actions.{ident}", "network": "offline", "clock": "fixed", "agent": "mock"}
    owners = sorted({o for o in (planner.owner(k) for k in row.get("families") or ()) if o})
    if len(owners) > 1:
        raise GenError(f"{ident}: contexts of families {owners}; case-v1 has one fixture.setup")
    if owners:
        fixture["setup"] = owners[0]
    invariants = [f"generated by {GENERATOR} from {catalog.label} entry {ident} (family {family}, {task}) with "
                  f"every-action-sweep.py's plan"]
    expected = (row.get("expect") or {}).get("key" if entry == "key" else "action")
    if expected in EXPECT_WORDS:
        invariants.append(EXPECT_WORDS[expected])
    invariants.extend(spec.get("invariants") or ())
    untested = list(spec.get("untested") or ())
    if row.get("expected_refusal") and "error" not in spec:
        untested.append(f"the sweep expects the app to refuse it for a script caller ({row['expected_refusal']}); "
                        f"{task} names the typed error")
    if blocked:
        untested.insert(0, f"blocked: {blocked}")
    case: Dict[str, Any] = {
        "$schema": SCHEMA_REF,
        "corpusVersion": 1,
        "id": case_id,
        "suite": SUITE,
        "title": f"{ident}: {title} through {how}"[:200],
        "surface": "cmux-next-native",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        "environment": {},
        "fixture": fixture,
        "preconditions": ["a fresh driver_app.py session: bench config, animations off, the mock agent pane",
                          "the launch's first workspace is shown with its terminal focused"],
        "requires": requires,
        "platforms": ["mac"],
        "steps": steps,
        "invariants": invariants,
        "teardown": (["the restore steps put back what the action toggled or fit"] if restore else [])
        + ["the driver resets the session before the next case (app_reset.py)"],
    }
    if untested:
        case["untested"] = untested
    entry_doc: Dict[str, Any] = {"family": family, "case": f"{SUITE}/{case_id}", "entry": entry}
    if entry == "key":
        entry_doc["key"] = stroke
    if setup:
        entry_doc["setup"] = setup
    if spec:
        entry_doc["tuned"] = sorted(spec)
    if blocked:
        entry_doc["blocked"] = blocked
    return case, entry_doc


# ------------------------------------------------------------------------------------------------ tuning


def load_tuning(out: Path, catalog: Catalog) -> Dict[str, Dict[str, Any]]:
    """`<out>/<family>/_tuning.json`: {"actions": {id: spec}}, each spec's keys in TUNING_KEYS:
    entry (key|action), params (merged into action.run's; null removes a key), receipt (an ActionEffect kind) or
    error (a typed error: the correct answer is a refusal), before (case-v1 steps between the setup and the
    action), waitFor and settleMaxMs and note (on the action step), invariants (added), untested (the reasons),
    requires (capabilities beyond actions and keys)."""
    tuning: Dict[str, Dict[str, Any]] = {}
    for family in FAMILIES:
        path = out / family / TUNING
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except ValueError as error:
            raise GenError(f"{path}: {error}") from None
        extra = sorted(set(data) - {"actions", "$comment"}) if isinstance(data, dict) else ["<not an object>"]
        if extra:
            raise GenError(f"{path}: unknown keys {extra}")
        for ident, spec in sorted((data.get("actions") or {}).items()):
            where = f"{path}: {ident}"
            if ident not in catalog.by_id:
                raise GenError(f"{where}: not an action of {catalog.label}")
            if family_of(ident) != family:
                raise GenError(f"{where}: belongs to family {family_of(ident)}")
            check_spec(where, spec)
            tuning[ident] = spec
    return tuning


def check_spec(where: str, spec: Any) -> None:
    if not isinstance(spec, dict) or not set(spec) <= TUNING_KEYS:
        raise GenError(f"{where}: a tuning takes only {sorted(TUNING_KEYS)}")
    if spec.get("entry", "key") not in ("key", "action"):
        raise GenError(f"{where}: entry is key or action")
    if not isinstance(spec.get("params", {}), dict):
        raise GenError(f"{where}: params is an object")
    if "receipt" in spec and "error" in spec:
        raise GenError(f"{where}: a step gives a receipt or a typed error, not both")
    if "receipt" in spec and spec["receipt"] not in ACTION_RECEIPTS:
        raise GenError(f"{where}: receipt is one of {list(ACTION_RECEIPTS)}")
    if "error" in spec and not (isinstance(spec["error"], str) and ERROR_CODE.match(spec["error"])):
        raise GenError(f"{where}: error is a typed code (area.code)")
    for key in ("invariants", "untested"):
        items = spec.get(key, [])
        if not isinstance(items, list) or not all(isinstance(i, str) and i for i in items):
            raise GenError(f"{where}: {key} is a list of statements")
    requires = spec.get("requires", [])
    if not isinstance(requires, list) or not set(requires) <= TUNING_CAPABILITIES:
        raise GenError(f"{where}: requires takes only {sorted(TUNING_CAPABILITIES)}")
    before = spec.get("before", [])
    if not isinstance(before, list):
        raise GenError(f"{where}: before is a list of case-v1 steps")
    for item in before:
        if not (isinstance(item, dict) and isinstance(item.get("id"), str) and STEP_ID.match(item["id"])
                and item.get("op") in BEFORE_OPS):
            raise GenError(f"{where}: a before step is a case-v1 step with an id and an op of {sorted(BEFORE_OPS)}, "
                           f"not {item!r}")
        if item["id"] == "action" or re.match(r"^(context|neighbor|prepare|restore)-[0-9]+$", item["id"]):
            raise GenError(f"{where}: before step id {item['id']!r} is a generated step's")


# ------------------------------------------------------------------------------------------------ suite


class CaseCheck:
    """case-v1 (normalize.validate) and its x-oracle checks (case_checks), on every case before it is written."""

    def __init__(self) -> None:
        import case_checks
        import normalize
        self.normalize, self.checks = normalize, case_checks
        self.schema = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
        self.rules = case_checks.Rules(self.schema)

    def problems(self, case: Mapping[str, Any]) -> List[str]:
        return list(self.normalize.validate(case, self.schema)) + [str(f) for f in self.checks.check_case(case, self.rules)]


def generate(catalog: Catalog, gaps: Gaps, tuning: Mapping[str, Mapping[str, Any]],
             planner: Optional[Planner] = None) -> Dict[str, Any]:
    """{file name: JSON value} for the whole suite: the runnable cases, _blocked.json and coverage.json."""
    planner = planner or Planner(sweep_module())
    check = CaseCheck()
    files: Dict[str, Any] = {}
    blocked_cases: Dict[str, Any] = {}
    actions: Dict[str, Any] = {}
    excluded: Dict[str, str] = {}
    families = {family: {"runnable": 0, "blocked": 0} for family in FAMILIES}
    entries = {"key": 0, "action": 0}
    blocked_by = {kind: 0 for kind in BLOCK_KINDS}
    seen: Dict[str, str] = {}
    for action in catalog.actions:
        ident = action["id"]
        if ident in gaps.excluded:
            continue
        case_id = slug(ident)
        if not SLUG.match(case_id):
            raise GenError(f"{ident}: case id {case_id!r} is not a case-v1 slug")
        if case_id in seen:
            raise GenError(f"{ident} and {seen[case_id]} make one case id {case_id!r}")
        seen[case_id] = ident
        row = planner.plan(action)
        blocked, kind = None, None
        if ident in gaps.gaps:
            blocked, kind = f"{gaps.gaps[ident]} (every-action-gaps.json; {GAP_TASKS})", "gap"
        if "skipped" in row:
            if not blocked:
                blocked, kind = f"the sweep's plan skips it ({row.get('skip_kind')}): {row['skipped']}", "plan"
            row = planner.unplanned(action)
        spec = tuning.get(ident) or {}
        case, entry = build_case(action, row, planner, catalog, spec, blocked)
        live = [p for step in case["steps"] for p in placeholders(step.get("args", {}), f"{step['id']}.args")]
        if live and not blocked:
            blocked, kind = f"needs a live value: {', '.join(live)}; {FAMILY_TASK[entry['family']]} tunes it", \
                "live-value"
            case, entry = build_case(action, row, planner, catalog, spec, blocked)
        problems = check.problems(case)
        if problems:
            raise GenError(f"{ident}: the case is not case-v1: {'; '.join(problems[:5])}")
        family = entry["family"]
        if blocked:
            blocked_cases[case_id] = {"action": ident, "family": family, "reason": blocked, "case": case}
            excluded[ident] = f"blocked: {blocked}"
            families[family]["blocked"] += 1
            blocked_by[kind] += 1
            entry["blocked_by"] = kind
        else:
            files[f"{case_id}.json"] = case
            families[family]["runnable"] += 1
            entries[entry["entry"]] += 1
        actions[ident] = entry
    unknown = sorted(set(tuning) - set(actions))
    if unknown:
        raise GenError(f"tuning names excluded actions: {unknown}")
    stale = sorted(set(gaps.excluded) - set(catalog.by_id)) + sorted(set(gaps.gaps) - set(catalog.by_id))
    files[BLOCKED] = {
        "$comment": f"Blocked action cases of the actions suite, written whole by {GENERATOR}; oracle.py does not run "
                    f"`_` files. Each moves to its own case file when its reason goes (a gap fixture lands and "
                    f"every-action-gaps.json drops the gap). Do not edit: regenerate.",
        "generator": GENERATOR,
        "cases": blocked_cases,
    }
    files[COVERAGE] = {
        "generator": GENERATOR,
        "suite": SUITE,
        "catalog": catalog.label,
        "catalog_sha256": catalog.sha256,
        "catalog_kind": "action.list" if catalog.live else "action-surfaces",
        "contexts": "from the catalog" if catalog.live else
                    f"not set up: action-surfaces.json has no registry contexts or arguments; check in a fleet run's "
                    f"action.list as {LIVE_CATALOG.relative_to(REPO).as_posix()} and regenerate",
        "gaps": "scripts/cmux-next/every-action-gaps.json",
        "gaps_sha256": gaps.sha256,
        "total": len(actions),
        "covered": len(actions) - len(excluded),
        "verdicts": "not run",
        "excluded": excluded,
        "blocked_by": blocked_by,
        "missing": [],
        "not_in_suite": sum(1 for a in catalog.actions if a["id"] in gaps.excluded),
        "stale_gap_ids": stale,
        "families": families,
        "entries": entries,
        "actions": actions,
    }
    return files


def render(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def owned_files(out: Path) -> List[str]:
    """The runnable case files the last generation wrote (from its coverage.json)."""
    path = out / COVERAGE
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        return []
    return sorted(entry["case"].split("/", 1)[1] + ".json" for entry in (data.get("actions") or {}).values()
                  if isinstance(entry, dict) and "blocked" not in entry and isinstance(entry.get("case"), str))


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
    """Writes changed files; removes the case files an earlier generation wrote that this one does not (an action
    that became blocked or left the catalog). Refuses to overwrite a case file it did not write."""
    out.mkdir(parents=True, exist_ok=True)
    owned = set(owned_files(out))
    for name in files:
        if name not in (COVERAGE, BLOCKED) and (out / name).exists() and name not in owned:
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


# --------------------------------------------------------------------------------------------- self test


class GenActionsSelfTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.catalog = Catalog.load(SURFACES)
        cls.gaps = Gaps.load()
        cls.files = generate(cls.catalog, cls.gaps, {})
        cls.coverage = cls.files[COVERAGE]

    def cases(self) -> Dict[str, Dict[str, Any]]:
        return {name: case for name, case in self.files.items() if name not in (COVERAGE, BLOCKED)}

    def test_every_non_excluded_action_is_runnable_or_blocked(self) -> None:
        """Task 071's acceptance at the checked-in catalog: of 985 actions (1,201 - 216 excluded), the 84 gaps are
        blocked, and so are 15 the sweep's own plan never runs: 14 paletteKey actions (palette-internal: they run
        inside the open palette) and agentPane.revealCwdInFinder (a SKIPS pattern: it opens Finder; the reviewed
        excluded list does not name it yet). The task's 901 counted those 15 as runnable. A catalog or gap-list
        change moves these numbers: update them with it."""
        ids = [a["id"] for a in self.catalog.actions if a["id"] not in self.gaps.excluded]
        self.assertEqual(self.coverage["total"], len(ids))
        self.assertEqual(len(self.cases()), self.coverage["covered"])
        self.assertEqual(len(self.files[BLOCKED]["cases"]), len(self.coverage["excluded"]))
        gap_ids = sorted(i for i, e in self.coverage["actions"].items() if e.get("blocked_by") == "gap")
        self.assertEqual(gap_ids, sorted(set(ids) & set(self.gaps.gaps)))
        plan_ids = sorted(i for i, e in self.coverage["actions"].items() if e.get("blocked_by") == "plan")
        self.assertEqual(plan_ids, ["agentPane.revealCwdInFinder"]
                         + sorted(i for i in ids if i.startswith("paletteKey.")))
        self.assertEqual((self.coverage["total"], self.coverage["covered"], len(self.coverage["excluded"])),
                         (985, 886, 99))
        self.assertEqual(self.coverage["blocked_by"], {"gap": 84, "plan": 15, "live-value": 0})
        self.assertEqual(self.coverage["not_in_suite"], 216)
        self.assertEqual(self.coverage["stale_gap_ids"], [])

    def test_each_case_runs_its_action_through_its_real_entrypoint(self) -> None:
        module = sweep_module()
        for ident, entry in self.coverage["actions"].items():
            case = self.files[f"{entry['case'].split('/')[1]}.json"] if "blocked" not in entry else \
                self.files[BLOCKED]["cases"][entry["case"].split("/")[1]]["case"]
            main = next(step for step in case["steps"] if step["id"] == "action")
            self.assertEqual(main["checkpoint"], ["before", "turn", "settled"], ident)
            key = module.key_of(self.catalog.by_id[ident])
            if key:
                self.assertEqual((main["op"], main["args"]["keys"]), ("key", [keystroke(key)]), ident)
                self.assertIn("keys", case["requires"], ident)
            else:
                self.assertEqual((main["op"], main["args"]["action"]), ("action.run", ident), ident)

    def test_cases_pass_the_case_schema(self) -> None:
        check = CaseCheck()
        for name, case in sorted(self.cases().items()):
            self.assertEqual(check.problems(case), [], name)
            self.assertEqual(case["id"] + ".json", name)
        for name, blocked in self.files[BLOCKED]["cases"].items():
            self.assertEqual(check.problems(blocked["case"]), [], name)
            self.assertTrue(blocked["case"]["untested"][0].startswith("blocked: "), name)

    def test_the_sweeps_setup_is_the_cases_setup(self) -> None:
        moves = self.files["tab-move-to-new-column.json"]["steps"]
        self.assertEqual([(s["id"], s["args"].get("action")) for s in moves],
                         [("prepare-1", "newSurface"), ("action", "tab.moveToNewColumn")])
        right = self.files["column-move-right.json"]["steps"]
        self.assertEqual([s["args"].get("action") for s in right[:2]], ["newColumn", "column.focusLeft"])
        left = self.files["focus-right.json"]["steps"]
        self.assertEqual([s["args"].get("action", s["args"].get("keys")) for s in left],
                         ["splitRight", "focusLeft", ["cmd+opt+right"]])

    def test_restore_steps_put_back_toggles_and_fits(self) -> None:
        module = sweep_module()
        for name, case in self.cases().items():
            main = next(s for s in case["steps"] if s["id"] == "action")
            ident = main["args"].get("action") or self.coverage_id(case)
            restores = [s for s in case["steps"] if s["id"].startswith("restore-")]
            expected = int(module.toggles(ident)) + int(ident in module.UNDO)
            self.assertEqual(len(restores), expected, name)
        fit = self.files["browser-fit.json"]["steps"]
        self.assertEqual(fit[-1]["args"], {"action": "browserFit", "params": {"fit": "off"}})

    def coverage_id(self, case: Mapping[str, Any]) -> str:
        return next(i for i, e in self.coverage["actions"].items() if e["case"] == f"{SUITE}/{case['id']}")

    def test_keystrokes_map_config_tokens(self) -> None:
        self.assertEqual(config_string({"key": "", "modifiers": ["opt", "cmd"]}), "cmd+opt+left")
        self.assertEqual(config_string({"key": "\t", "modifiers": ["ctrl", "shift"]}), "shift+ctrl+tab")
        self.assertEqual(config_string({"key": "=", "modifiers": ["cmd"]}), "cmd+=")
        self.assertEqual(keystroke(("left", ["cmd", "option"])), "cmd+opt+left")
        self.assertEqual(keystroke(("+", ["cmd"])), "cmd+plus")
        self.assertEqual(keystroke(("delete", ["control"])), "ctrl+backspace")
        self.assertIsNone(keystroke(("§", ["cmd"])))
        self.assertIsNone(keystroke(("x", ["hyper"])))
        self.assertEqual(slug("browserProfile.tabGroup.closeAll"), "browser-profile-tab-group-close-all")
        self.assertEqual(slug("toggleURLBar"), "toggle-url-bar")

    def test_families_cover_the_task_split(self) -> None:
        self.assertEqual(family_of("browserProfile.create"), "browser")
        self.assertEqual(family_of("newTab"), "tabs")
        self.assertEqual(family_of("screenGroup.close"), "layout")
        self.assertEqual(family_of("bookmark.add"), "misc")
        counts = self.coverage["families"]
        self.assertEqual(sum(c["runnable"] + c["blocked"] for c in counts.values()), self.coverage["total"])

    def test_regeneration_is_byte_stable_and_check_finds_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            write(out, self.files)
            again = generate(self.catalog, self.gaps, load_tuning(out, self.catalog))
            self.assertEqual(drift(out, again), [])
            self.assertEqual(write(out, again), (0, 0))
            name = "open-settings.json"
            (out / name).write_text("{}\n", encoding="utf-8")
            self.assertEqual(drift(out, again), [f"{name}: differs from a fresh generation"])
            (out / "hand-written.json").write_text("{}\n", encoding="utf-8")
            with self.assertRaises(GenError):
                write(out, {**again, "hand-written.json": {}})

    def test_a_new_gap_moves_a_case_to_blocked_and_removes_its_file(self) -> None:
        gaps = copy.deepcopy(self.gaps)
        gaps.gaps["openSettings"] = "needs context the sweep does not set up: example"
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            write(out, self.files)
            files = generate(self.catalog, gaps, {})
            self.assertNotIn("open-settings.json", files)
            self.assertIn("open-settings", files[BLOCKED]["cases"])
            self.assertEqual(drift(out, files)[-1], "open-settings.json: generated earlier, now blocked or no longer "
                                                    "in the catalog")
            self.assertEqual(write(out, files)[1], 1)
            self.assertFalse((out / "open-settings.json").exists())

    def test_tuning_names_the_receipt_and_adds_steps(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            (out / "appearance").mkdir()
            spec = {"receipt": "action.done", "invariants": ["the settings facet shows the new value"],
                    "before": [{"id": "wait-ready", "op": "settle"}], "requires": ["gui"]}
            ident = next(a for a in self.coverage["actions"] if family_of(a) == "appearance"
                         and "blocked" not in self.coverage["actions"][a])
            (out / "appearance" / TUNING).write_text(json.dumps({"actions": {ident: spec}}), encoding="utf-8")
            files = generate(self.catalog, self.gaps, load_tuning(out, self.catalog))
            case = files[f"{slug(ident)}.json"]
            main = next(s for s in case["steps"] if s["id"] == "action")
            self.assertEqual(main["expect"], {"outcome": "ok", "receipt": "action.done"})
            self.assertIn("wait-ready", [s["id"] for s in case["steps"]])
            self.assertIn("the settings facet shows the new value", case["invariants"])
            self.assertIn("gui", case["requires"])
            self.assertEqual(files[COVERAGE]["actions"][ident]["tuned"], sorted(spec))

    def test_tuning_refusals(self) -> None:
        ident = next(a for a in self.coverage["actions"] if family_of(a) == "appearance")
        bad = [
            ({"actions": {ident: {"colour": 1}}}, "a tuning takes only"),
            ({"actions": {ident: {"receipt": "mutation_result"}}}, "receipt is one of"),
            ({"actions": {ident: {"receipt": "action.done", "error": "control.failed"}}}, "not both"),
            ({"actions": {ident: {"error": "Failed"}}}, "typed code"),
            ({"actions": {ident: {"before": [{"id": "action", "op": "settle"}]}}}, "generated step's"),
            ({"actions": {ident: {"before": [{"id": "x", "op": "kill"}]}}}, "a before step is"),
            ({"actions": {"noSuchAction": {}}}, "not an action of"),
            ({"actions": {"newTab": {}}}, "belongs to family tabs"),
            ({"other": {}}, "unknown keys"),
        ]
        for data, words in bad:
            with tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp)
                (out / "appearance").mkdir()
                (out / "appearance" / TUNING).write_text(json.dumps(data), encoding="utf-8")
                with self.assertRaises(GenError) as raised:
                    load_tuning(out, self.catalog)
                self.assertIn(words, str(raised.exception), data)

    def test_a_tuned_step_that_breaks_case_v1_is_refused(self) -> None:
        ident = next(a for a, e in self.coverage["actions"].items() if family_of(a) == "appearance" and "blocked" not in e)
        with self.assertRaises(GenError) as raised:
            generate(self.catalog, self.gaps, {ident: {"before": [{"id": "x", "op": "action.run"}]}})
        self.assertIn("not case-v1", str(raised.exception))

    def test_a_live_catalog_sets_up_contexts_and_blocks_live_arguments(self) -> None:
        live = {"actions": [
            {"id": "browserReload", "title": "Reload", "shortcut_config": None, "requires": ["browserFocused"],
             "arguments": [], "targets": [], "surfaces": {"palette": "offered"}},
            {"id": "tab.focus", "title": "Focus Tab", "shortcut_config": None, "requires": [], "targets": [],
             "arguments": [{"name": "tab", "kind": "target", "target_kind": "tab", "required": True}],
             "surfaces": {"palette": "offered"}},
            {"id": "closeTab", "title": "Close Tab", "shortcut_config": "cmd+w", "requires": [], "arguments": [],
             "targets": [], "destructive": True, "surfaces": {"palette": "offered"}},
        ]}
        catalog = Catalog(Path("action-list.json"), json.dumps(live))
        gaps = Gaps(Path("gaps.json"), json.dumps({"excluded": {}, "gaps": {}}))
        files = generate(catalog, gaps, {})
        reload = files["browser-reload.json"]["steps"]
        self.assertEqual([s["args"].get("action") for s in reload], ["openBrowser.chromium", "browserReload"])
        self.assertIn("tab-focus", files[BLOCKED]["cases"])
        self.assertIn("args.params.tab = <base.tab>", files[BLOCKED]["cases"]["tab-focus"]["reason"])
        self.assertEqual(files["close-tab.json"]["steps"][-1]["args"], {"keys": ["cmd+w"]})
        self.assertEqual(files[COVERAGE]["catalog_kind"], "action.list")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="the suite directory (default: the corpus)")
    parser.add_argument("--catalog", type=Path,
                        help="an action.list reply (a sweep run's action-list.json) or action-surfaces.json (default: "
                             "tests/oracle/fixtures/actions/action-list.json when present, else action-surfaces.json)")
    parser.add_argument("--gaps", type=Path, default=GAPS, help="the sweep's gap list")
    parser.add_argument("--check", action="store_true", help="exit 1 when --out differs from a fresh generation")
    parser.add_argument("--selftest", action="store_true", help="run the offline self tests")
    args = parser.parse_args(argv)
    if args.selftest:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(GenActionsSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    try:
        catalog = Catalog.load(args.catalog)
        files = generate(catalog, Gaps.load(args.gaps), load_tuning(args.out, catalog))
        coverage = files[COVERAGE]
        if args.check:
            problems = drift(args.out, files)
            for problem in problems:
                print(f"gen_actions: {problem}", file=sys.stderr)
            print(f"gen_actions: {coverage['covered']} runnable + {len(coverage['excluded'])} blocked of "
                  f"{coverage['total']} actions, {'stale' if problems else 'up to date'}")
            return 1 if problems else 0
        written, removed = write(args.out, files)
    except GenError as error:
        print(f"gen_actions: {error}", file=sys.stderr)
        return 2
    print(f"gen_actions: {coverage['covered']} runnable + {len(coverage['excluded'])} blocked of {coverage['total']} "
          f"actions ({coverage['entries']['key']} by key, {coverage['entries']['action']} by action.run), "
          f"{written} files written, {removed} removed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
