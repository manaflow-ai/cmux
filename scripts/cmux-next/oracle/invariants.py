#!/usr/bin/env python3
"""Oracle invariants I1-I7 over one case trace (p15-oracle-110).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md section 3F ("Invariants at every checkpoint") and
plans/cmux-next/oracle-DESIGN.md. Stdlib only, Python 3.9+, safe under `python3 -I`. Later tasks add
I8 (204), I9 (205), I10 (206), I11-I15 (217), I16 (236) and I17-I18 (188) to INVARIANTS and CHECKS.

| Id | Rule                                                                  | Reads                          |
| I1 | each mutation gives exactly one receipt or one typed error            | step replies                   |
| I2 | ids stay stable unless the step created or closed them               | topology + daemon facets       |
| I3 | turn projection == settled, or settled == before + a refusal          | turn/settled/before + intents  |
| I4 | app topology == daemon tree at the same sequence                      | topology + daemon facets       |
| I5 | 0 `debug.desync` violations                                           | invariants facet               |
| I6 | no orphan processes or sockets at teardown                            | teardown record                |
| I7 | a hidden-workspace change does no view work                           | step layoutCounters + topology |

Chrome reference (chromium/src): content/public/test/browser_test_base.h checks invariants after every
browser test (NoRendererCrashesAssertion, the leak checks of content/public/test/test_launcher.h) the
way these run on every case, not per case; base/test/launcher/test_launcher.cc reports a leaked child
process of a test as a failure of that test (I6). A failed check names its value, as gtest's
EXPECT_EQ prints both sides; here every violation names its JSON pointer.

The checks run on raw checkpoints, before normalize.py: I4 pairs the cut by the raw sequences that the
canonical form drops (x-oracle-volatile), and ids of one run need no relabeling to be compared with
each other. I3 compares projections with the schema's volatile fields removed (`VolatileMask`), so
commit counters do not count as a difference.

Trace (`cmux.oracle.trace/v1`), written by the product drivers (driver_daemon.py 023, driver_app.py 050):
    {"schema": "cmux.oracle.trace/v1", "case": "suite/name",
     "steps": [{"id", "op", "readOnly"?, "expect"?, "args"?,
                "target"?: {kind: public id}      (handles and $step refs already resolved),
                "replies": [{"receipt": KIND} | {"error": CODE}, ...]   (every reply the step got),
                "checkpoints": {"before"?|"turn"?|"settled"?: snapshot-v1 (raw)},
                "layoutCounters"?: {"before": {name: n}, "after": {name: n}}   (debug.layout_counters)}],
     "teardown"?: {"processes": [{"pid", "command"}], "sockets": [path]}}
Step fields missing from the trace come from the case (`--case`), matched by step id.

Report (`cmux.oracle.invariants/v1`): {"case", "violations": [{"invariant", "step", "checkpoint",
"in": "snapshot"|"step"|"teardown", "pointer", "message"}], "notChecked": [{"invariant", "step",
"reason"}], "checked": {id: count}}. A snapshot pointer is facet-rooted like the Expectations pointer
suffix (`/topology/topology/workspaces/0`); a step pointer points into the step's trace record and a
teardown pointer into `teardown`. An invariant that applies but lacks its input is notChecked, never
passed.

Usage:
  invariants.py check TRACE.json [--case CASE.json] [--json]   exit 0 clean, 1 violations, 2 bad input
  invariants.py --list                                         the invariants, their rule and pointer
  invariants.py --selftest                                     synthetic violation of each invariant
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
import unittest
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, List, Mapping, Optional, Sequence, Set, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SNAPSHOT_SCHEMA = REPO / "schemas" / "oracle" / "snapshot-v1.schema.json"
EXAMPLE_SNAPSHOT = REPO / "schemas" / "oracle" / "fixtures" / "snapshot-example.json"

TRACE_SCHEMA = "cmux.oracle.trace/v1"
REPORT_SCHEMA = "cmux.oracle.invariants/v1"
CHECKPOINT_ORDER = ("before", "turn", "settled")
# Typed outcomes, the patterns of case-v1 $defs.expect.error and .receipt.
ERROR_CODE = re.compile(r"^[a-z][a-z_]*(\.[a-z][a-z_]*)+$")
RECEIPT_KIND = re.compile(r"^[a-z][A-Za-z0-9]*([._][a-z][A-Za-z0-9]*)*$")
# Ops that change state; the rest (settle, snapshot, kill, restart, advance_clock) give no receipt.
MUTATING_OPS = frozenset({"resource.call", "action.run", "key", "cli", "mcp", "tui.key"})
READ_CAPABLE_OPS = frozenset({"resource.call", "cli", "mcp"})
KEY_OPS = frozenset({"key", "tui.key"})
# Facets that count the pipeline, not the model: a pending intent at the turn becomes applied at the
# settle, tasks finish, hit counters move. I3 compares the other facets.
BOOKKEEPING_FACETS = frozenset({"intents", "switches", "liveObjects", "crashes", "invariants"})
# debug.layout_counters values that count view work (DebugLayoutCounters.swift). Left out:
# topology_sends (the control topology, a model), indicator_resyncs (the sidebar shows hidden
# workspaces' rows), pane_count_changes and sources (not counters).
VIEW_WORK_COUNTERS = (
    "pane_snapshots",
    "workspace_applies",
    "workspace_window_entries",
    "layout_root_layouts",
    "pane_chrome_updates",
    "update_visibility",
    "terminal_window_updates",
    "terminal_grid_reports",
)
# Containment kinds whose ids I2 holds stable. Clients, notifications, splits and streams are not
# identities a step keeps: a reconnect gives a new client, a layout edit a new split.
STRUCTURAL_KINDS = ("session", "window", "workspace", "screen", "pane", "tab", "terminal", "browser")


@dataclass(frozen=True)
class Invariant:
    id: str
    rule: str
    pointer: str
    task: str


INVARIANTS: Tuple[Invariant, ...] = (
    Invariant("I1", "each mutation gives exactly one receipt or one typed error",
              "step: /replies/<n> (or /replies when one is missing)", "p15-oracle-110"),
    Invariant("I2", "ids stay stable unless the step created or closed them",
              "snapshot: where the id was (closed) or is (created), /topology/... or /daemon/session/...",
              "p15-oracle-110"),
    Invariant("I3", "optimistic prefix: turn projection == settled projection, or settled == before + refusal",
              "snapshot: first value where the turn and settled projections differ", "p15-oracle-110"),
    Invariant("I4", "app topology == daemon tree at the same sequence",
              "snapshot: the app value that differs, /topology/topology/workspaces/...", "p15-oracle-110"),
    Invariant("I5", "0 debug.desync violations",
              "snapshot: /invariants/violations/<n> or /invariants/windowInvariants/<n>", "p15-oracle-110"),
    Invariant("I6", "no orphan processes or sockets at teardown",
              "teardown: /processes/<n> or /sockets/<n>", "p15-oracle-110"),
    Invariant("I7", "a hidden-workspace change does no view work (debug.layout_counters)",
              "step: /layoutCounters/after/<counter>", "p15-oracle-110"),
)
BY_ID = {inv.id: inv for inv in INVARIANTS}


class TraceError(Exception):
    """The trace is not a cmux.oracle.trace/v1 document."""


@dataclass
class Violation:
    invariant: str
    step: Optional[str]
    checkpoint: Optional[str]
    pointer: str
    message: str
    where: str = "snapshot"

    def to_json(self) -> Dict[str, Any]:
        value = asdict(self)
        value["in"] = value.pop("where")
        return value


@dataclass
class NotChecked:
    invariant: str
    step: Optional[str]
    reason: str


@dataclass
class Report:
    case: str
    violations: List[Violation] = field(default_factory=list)
    not_checked: List[NotChecked] = field(default_factory=list)
    checked: Dict[str, int] = field(default_factory=lambda: {inv.id: 0 for inv in INVARIANTS})

    def to_json(self) -> Dict[str, Any]:
        return {
            "schema": REPORT_SCHEMA,
            "case": self.case,
            "violations": [v.to_json() for v in self.violations],
            "notChecked": [asdict(n) for n in self.not_checked],
            "checked": dict(self.checked),
        }


# ---------------------------------------------------------------------------------------------- inputs


def escape(token: Any) -> str:
    return str(token).replace("~", "~0").replace("/", "~1")


def pointer(*tokens: Any) -> str:
    return "".join(f"/{escape(t)}" for t in tokens)


def facet(snapshot: Optional[Mapping[str, Any]], name: str) -> Optional[Mapping[str, Any]]:
    """The facet object, or None when the snapshot lacks it or it is not comparable."""
    if not isinstance(snapshot, Mapping):
        return None
    value = (snapshot.get("facets") or {}).get(name)
    if not isinstance(value, Mapping) or value.get("status") == "not-comparable":
        return None
    return value


@dataclass
class Step:
    index: int
    id: str
    op: str
    record: Mapping[str, Any]

    @property
    def read_only(self) -> bool:
        return self.op in READ_CAPABLE_OPS and self.record.get("readOnly") is True

    @property
    def mutating(self) -> bool:
        return self.op in MUTATING_OPS and not self.read_only

    @property
    def checkpoints(self) -> Mapping[str, Any]:
        return self.record.get("checkpoints") or {}

    @property
    def target(self) -> Mapping[str, Any]:
        return self.record.get("target") or {}


@dataclass
class State:
    """One recorded checkpoint in case order."""

    step: Step
    checkpoint: str
    snapshot: Mapping[str, Any]


@dataclass
class Trace:
    case: str
    steps: List[Step]
    teardown: Optional[Mapping[str, Any]]

    def states(self) -> List[State]:
        out = []
        for step in self.steps:
            for name in CHECKPOINT_ORDER:
                snapshot = step.checkpoints.get(name)
                if snapshot is not None:
                    out.append(State(step, name, snapshot))
        return out


def load_trace(document: Any, case: Optional[Mapping[str, Any]] = None) -> Trace:
    if not isinstance(document, Mapping) or document.get("schema") != TRACE_SCHEMA:
        raise TraceError(f"not a {TRACE_SCHEMA} document")
    raw_steps = document.get("steps")
    if not isinstance(raw_steps, list) or not raw_steps:
        raise TraceError("steps: want a non-empty list")
    case_steps = {s.get("id"): s for s in (case or {}).get("steps", []) if isinstance(s, Mapping)}
    steps = []
    for index, raw in enumerate(raw_steps):
        if not isinstance(raw, Mapping) or not isinstance(raw.get("id"), str):
            raise TraceError(f"steps/{index}: want an object with a string id")
        record = {**case_steps.get(raw["id"], {}), **raw}
        if not isinstance(record.get("op"), str):
            raise TraceError(f"steps/{index}: no op in the trace or the case")
        checkpoints = record.get("checkpoints", {})
        if not isinstance(checkpoints, Mapping) or set(checkpoints) - set(CHECKPOINT_ORDER):
            raise TraceError(f"steps/{index}/checkpoints: want an object keyed by {', '.join(CHECKPOINT_ORDER)}")
        steps.append(Step(index, record["id"], record["op"], record))
    name = document.get("case") or (case or {}).get("id") or "?"
    teardown = document.get("teardown")
    if teardown is not None and not isinstance(teardown, Mapping):
        raise TraceError("teardown: want an object")
    return Trace(str(name), steps, teardown)


# ---------------------------------------------------------------------------------------------- volatile mask


class VolatileMask:
    """Removes the fields the snapshot schema marks `x-oracle-volatile`, and the members of open objects
    that match a volatile `x-oracle-open-keys` pattern (normalize.py's step 1). Branches of oneOf, anyOf
    and allOf all apply: the facet branches are an object or notComparable, which share no field."""

    def __init__(self, schema: Mapping[str, Any]):
        self.definitions = schema.get("definitions", {})
        self.facets = schema["properties"]["facets"]["properties"]
        self.open_volatile = [re.compile(e["key"]) for e in schema.get("x-oracle-open-keys", [])
                              if "x-oracle-volatile" in e]

    def _resolve(self, node: Any) -> Any:
        while isinstance(node, Mapping) and "$ref" in node:
            node = self.definitions[node["$ref"].rsplit("/", 1)[-1]]
        return node

    def _branches(self, node: Any) -> List[Mapping[str, Any]]:
        node = self._resolve(node)
        if not isinstance(node, Mapping):
            return []
        out = [node]
        for key in ("oneOf", "anyOf", "allOf"):
            for branch in node.get(key, []):
                out.extend(self._branches(branch))
        return out

    def facet(self, name: str, value: Any) -> Any:
        return self.strip(value, self.facets.get(name))

    def strip(self, value: Any, node: Any) -> Any:
        branches = self._branches(node) if node is not None else []
        if isinstance(value, Mapping):
            out = {}
            for key, member in value.items():
                typed = [self._resolve(b["properties"][key]) for b in branches if key in b.get("properties", {})]
                if typed:
                    if any(isinstance(t, Mapping) and "x-oracle-volatile" in t for t in typed):
                        continue
                    out[key] = self.strip(member, {"anyOf": typed})
                    continue
                if any(p.search(key) for p in self.open_volatile):
                    continue
                extra = [b["additionalProperties"] for b in branches if isinstance(b.get("additionalProperties"), Mapping)]
                out[key] = self.strip(member, {"anyOf": extra} if extra else None)
            return out
        if isinstance(value, list):
            items = [b["items"] for b in branches if isinstance(b.get("items"), Mapping)]
            item_node = {"anyOf": items} if items else None
            return [self.strip(item, item_node) for item in value]
        return value


def first_difference(a: Any, b: Any, at: str = "") -> Optional[Tuple[str, Any, Any]]:
    """The first (pointer, a, b) of a sorted-key walk where the values differ; a bool never equals a number."""
    if isinstance(a, Mapping) and isinstance(b, Mapping):
        for key in sorted(set(a) | set(b)):
            if key not in a or key not in b:
                return f"{at}/{escape(key)}", a.get(key), b.get(key)
            found = first_difference(a[key], b[key], f"{at}/{escape(key)}")
            if found:
                return found
        return None
    if isinstance(a, list) and isinstance(b, list):
        for i in range(max(len(a), len(b))):
            if i >= len(a) or i >= len(b):
                return f"{at}/{i}", a[i] if i < len(a) else None, b[i] if i < len(b) else None
            found = first_difference(a[i], b[i], f"{at}/{i}")
            if found:
                return found
        return None
    if type(a) is bool or type(b) is bool:
        return None if type(a) is type(b) and a == b else (at, a, b)
    return None if a == b else (at, a, b)


# ---------------------------------------------------------------------------------------------- id graph


@dataclass
class Node:
    kind: str
    parent: Optional[str]
    pointer: str


def topology_ids(topology: Mapping[str, Any]) -> Dict[str, Node]:
    """Structural ids of the topology facet (snapshot.get), each with its container and pointer."""
    nodes: Dict[str, Node] = {}
    tree = topology.get("topology") or {}
    window_of: Dict[str, str] = {}
    for wi, window in enumerate(tree.get("windows") or []):
        nodes[window["id"]] = Node("window", None, pointer("topology", "topology", "windows", wi))
        for workspace in window.get("workspaces") or []:
            window_of.setdefault(workspace, window["id"])
    for session in tree.get("sessions") or []:
        nodes.setdefault(session["id"], Node("session", None, pointer("topology", "topology", "sessions")))
    for wsi, ws in enumerate(tree.get("workspaces") or []):
        at = ("topology", "topology", "workspaces", wsi)
        nodes[ws["id"]] = Node("workspace", window_of.get(ws["id"], ws.get("session")), pointer(*at))
        for si, screen in enumerate(ws.get("screens") or []):
            nodes[screen["id"]] = Node("screen", ws["id"], pointer(*at, "screens", si))
            for pi, pane in enumerate(screen.get("panes") or []):
                nodes[pane["id"]] = Node("pane", screen["id"], pointer(*at, "screens", si, "panes", pi))
                for ti, tab in enumerate(pane.get("tabs") or []):
                    tab_at = (*at, "screens", si, "panes", pi, "tabs", ti)
                    nodes[tab["id"]] = Node("tab", pane["id"], pointer(*tab_at))
                    if tab.get("terminal"):
                        nodes.setdefault(tab["terminal"], Node("terminal", tab["id"], pointer(*tab_at, "terminal")))
    return nodes


DAEMON_TABLES = (
    ("workspaces", "workspace", "session_id"),
    ("screens", "screen", "workspace_id"),
    ("panes", "pane", "screen_id"),
    ("tabs", "tab", "pane_id"),
    ("terminals", "terminal", "tab_id"),
    ("browsers", "browser", "tab_id"),
)


def daemon_ids(daemon: Mapping[str, Any]) -> Dict[str, Node]:
    """Structural ids of the daemon facet's session.snapshot."""
    session = daemon.get("session") or {}
    nodes: Dict[str, Node] = {}
    own = (session.get("session") or {}).get("id")
    if own:
        nodes[own] = Node("session", None, pointer("daemon", "session", "session", "id"))
    for table, kind, parent_key in DAEMON_TABLES:
        for i, row in enumerate(session.get(table) or []):
            nodes[row["id"]] = Node(kind, row.get(parent_key), pointer("daemon", "session", table, i))
    return nodes


def id_sources(snapshot: Mapping[str, Any]) -> Dict[str, Dict[str, Node]]:
    out = {}
    topology = facet(snapshot, "topology")
    if topology is not None:
        out["topology"] = topology_ids(topology)
    daemon = facet(snapshot, "daemon")
    if daemon is not None:
        out["daemon"] = daemon_ids(daemon)
    return out


def merged_ids(snapshot: Mapping[str, Any]) -> Dict[str, Node]:
    nodes: Dict[str, Node] = {}
    for source in id_sources(snapshot).values():
        for key, node in source.items():
            nodes.setdefault(key, node)
    return nodes


def ancestors(nodes: Mapping[str, Node], start: str) -> Iterator[str]:
    seen: Set[str] = set()
    current = nodes.get(start)
    while current is not None and current.parent and current.parent not in seen:
        seen.add(current.parent)
        yield current.parent
        current = nodes.get(current.parent)


def strings_in(value: Any) -> Iterator[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, Mapping):
        for member in value.values():
            yield from strings_in(member)
    elif isinstance(value, list):
        for item in value:
            yield from strings_in(item)


# ---------------------------------------------------------------------------------------------- checks


class Checker:
    def __init__(self, trace: Trace, mask: VolatileMask):
        self.trace = trace
        self.mask = mask
        self.report = Report(trace.case)
        self.states = trace.states()

    def violate(self, inv: str, step: Optional[Step], checkpoint: Optional[str], at: str, message: str,
                where: str = "snapshot") -> None:
        self.report.violations.append(Violation(inv, step.id if step else None, checkpoint, at, message, where))

    def skip(self, inv: str, step: Optional[Step], reason: str) -> None:
        self.report.not_checked.append(NotChecked(inv, step.id if step else None, reason))

    def checked(self, inv: str) -> None:
        self.report.checked[inv] += 1

    def before_state(self, step: Step) -> Optional[State]:
        """The step's before checkpoint, else the last checkpoint recorded before the step."""
        prior = None
        for state in self.states:
            if state.step.index == step.index and state.checkpoint == "before":
                return state
            if state.step.index >= step.index:
                break
            prior = state
        return prior

    def after_state(self, step: Step) -> Optional[State]:
        for name in ("settled", "turn"):
            if name in step.checkpoints:
                return State(step, name, step.checkpoints[name])
        return None

    # I1 -----------------------------------------------------------------------------------------------
    def i1(self) -> None:
        for step in self.trace.steps:
            if not step.mutating:
                continue
            self.checked("I1")
            replies = step.record.get("replies")
            if not isinstance(replies, list):
                self.violate("I1", step, None, "/replies", "the trace has no replies for this mutation", "step")
                continue
            expect = step.record.get("expect") or {}
            keys = (step.record.get("args") or {}).get("keys")
            want = len(keys) if step.op in KEY_OPS and isinstance(keys, list) and keys else 1
            no_receipt = "noReceiptReason" in expect
            for i, reply in enumerate(replies):
                at = f"/replies/{i}"
                if not isinstance(reply, Mapping) or len(set(reply) & {"receipt", "error"}) != 1:
                    self.violate("I1", step, None, at, f"reply is not one receipt or one error: {reply!r:.200}", "step")
                elif "error" in reply and not (isinstance(reply["error"], str) and ERROR_CODE.match(reply["error"])):
                    self.violate("I1", step, None, at, f"error {reply['error']!r} is not a typed error code", "step")
                elif "receipt" in reply and not (isinstance(reply["receipt"], str) and RECEIPT_KIND.match(reply["receipt"])):
                    self.violate("I1", step, None, at, f"receipt {reply['receipt']!r} is not a typed receipt kind", "step")
                elif "receipt" in reply and no_receipt:
                    self.violate("I1", step, None, at,
                                 f"receipt {reply['receipt']} where the case says none exists: {expect['noReceiptReason']}", "step")
                elif "receipt" in reply and expect.get("receipt") and reply["receipt"] != expect["receipt"]:
                    self.violate("I1", step, None, at, f"receipt {reply['receipt']}, the case wants {expect['receipt']}", "step")
            if len(replies) > want:
                self.violate("I1", step, None, f"/replies/{want}",
                             f"{len(replies)} replies for {want} mutation(s): exactly one each", "step")
            elif len(replies) < want and not no_receipt:
                self.violate("I1", step, None, "/replies",
                             f"{len(replies)} replies for {want} mutation(s): neither a receipt nor a typed error", "step")

    # I2 -----------------------------------------------------------------------------------------------
    def covered(self, step: Step, before: Mapping[str, Node], after: Mapping[str, Node]) -> Set[str]:
        """Ids the step may create under or close: its targets, their containers, the ids its replies name
        and, for a key with no target, the focused objects it acts on."""
        roots = {v for v in self.target_ids(step) if isinstance(v, str)}
        roots |= {s for s in strings_in(step.record.get("replies") or []) if s in before or s in after}
        out = set(roots)
        for root in roots:
            out |= set(ancestors(before, root)) | set(ancestors(after, root))
        return out

    def target_ids(self, step: Step) -> List[str]:
        targets = [v for k, v in step.target.items() if k != "process" and isinstance(v, str)]
        if targets or step.op not in KEY_OPS:
            return targets
        prior = self.before_state(step)
        focus = ((facet(prior.snapshot, "topology") or {}).get("topology") or {}).get("focus") if prior else None
        return [v for v in (focus or {}).values() if isinstance(v, str)]

    def i2(self) -> None:
        for previous, current in zip(self.states, self.states[1:]):
            # Changes up to a before checkpoint are the previous step's late effects.
            owner = current.step if current.checkpoint != "before" else previous.step
            a_sources, b_sources = id_sources(previous.snapshot), id_sources(current.snapshot)
            shared = [s for s in ("topology", "daemon") if s in a_sources and s in b_sources]
            if not shared:
                continue
            self.checked("I2")
            a_all, b_all = merged_ids(previous.snapshot), merged_ids(current.snapshot)
            may = self.covered(owner, a_all, b_all) if owner.mutating else set()
            reported: Set[str] = set()
            for source in shared:
                a, b = a_sources[source], b_sources[source]
                for key in sorted(set(a) - set(b)):
                    node = a[key]
                    if node.parent in a and node.parent not in b:
                        continue  # closed with its container
                    if key in may or key in reported:
                        continue
                    reported.add(key)
                    self.violate("I2", current.step, current.checkpoint, node.pointer,
                                 f"{node.kind} {key} disappeared, but step {owner.id} ({owner.op}) did not close it "
                                 f"(it was at {node.pointer} in {previous.step.id}/{previous.checkpoint})")
                for key in sorted(set(b) - set(a)):
                    node = b[key]
                    if node.parent in b and node.parent not in a:
                        continue  # created with its container
                    if key in may or node.parent in may or key in reported:
                        continue
                    reported.add(key)
                    self.violate("I2", current.step, current.checkpoint, node.pointer,
                                 f"{node.kind} {key} appeared, but step {owner.id} ({owner.op}) did not create it")

    # I3 -----------------------------------------------------------------------------------------------
    def projection(self, snapshot: Mapping[str, Any], names: Iterable[str]) -> Dict[str, Any]:
        return {name: self.mask.facet(name, facet(snapshot, name)) for name in names}

    def i3(self) -> None:
        for step in self.trace.steps:
            turn, settled = step.checkpoints.get("turn"), step.checkpoints.get("settled")
            if turn is None:
                continue
            if settled is None:
                self.skip("I3", step, "the step has a turn checkpoint but no settled checkpoint")
                continue
            names = sorted(n for n in (turn.get("facets") or {})
                           if n not in BOOKKEEPING_FACETS and facet(turn, n) is not None and facet(settled, n) is not None)
            if not names:
                self.skip("I3", step, "the turn checkpoint holds no model facet the settled checkpoint has")
                continue
            self.checked("I3")
            found = first_difference(self.projection(turn, names), self.projection(settled, names))
            if found is None:
                continue
            prior = self.before_state(step)
            refusal = self.refusal(prior.snapshot if prior else None, settled)
            reverted = prior is not None and first_difference(
                self.projection(prior.snapshot, names), self.projection(settled, names)) is None
            if reverted and refusal:
                continue
            at, turn_value, settled_value = found
            if refusal and prior is not None:
                why = "a refusal was counted but settled is not the before state"
            elif reverted:
                why = "settled equals before but no refusal or rollback was counted"
            elif prior is None:
                why = "no before checkpoint to check a refusal against"
            else:
                why = "settled is neither the turn projection nor the before state"
            self.violate("I3", step, "settled", at,
                         f"turn {json.dumps(turn_value)[:120]} vs settled {json.dumps(settled_value)[:120]}: {why}")

    @staticmethod
    def refusal(before: Optional[Mapping[str, Any]], settled: Mapping[str, Any]) -> bool:
        a, b = facet(before, "intents"), facet(settled, "intents")
        if a is None or b is None:
            return False
        ta, tb = a.get("totals") or {}, b.get("totals") or {}
        return any(int(tb.get(k, 0)) > int(ta.get(k, 0)) for k in ("refused", "rolledBack"))

    # I4 -----------------------------------------------------------------------------------------------
    def i4(self) -> None:
        for state in self.states:
            topology, daemon = facet(state.snapshot, "topology"), facet(state.snapshot, "daemon")
            if topology is None or daemon is None:
                if state.checkpoint == "settled" and (topology is None) != (daemon is None):
                    self.skip("I4", state.step, "the settled checkpoint has only one of the topology and daemon facets")
                continue
            head = daemon.get("journalHead")
            if not isinstance(head, int):
                if state.checkpoint == "settled":
                    self.skip("I4", state.step, "the daemon facet has no journalHead (v0 or pre-021 daemon): no cut to pair")
                continue
            applied = topology.get("sequence")
            if applied != head:
                if state.checkpoint == "settled":
                    self.checked("I4")
                    self.violate("I4", state.step, state.checkpoint, "/topology/sequence",
                                 f"settled app applied daemon sequence {applied}, the daemon is at {head}")
                continue
            self.checked("I4")
            for at, message in tree_differences(topology, daemon):
                self.violate("I4", state.step, state.checkpoint, at, message)

    # I5 -----------------------------------------------------------------------------------------------
    def i5(self) -> None:
        previous: Set[Tuple[str, str]] = set()
        for state in self.states:
            value = facet(state.snapshot, "invariants")
            if value is None:
                continue
            self.checked("I5")
            now: Set[Tuple[str, str]] = set()
            for member in ("violations", "windowInvariants"):
                for i, name in enumerate(value.get(member) or []):
                    now.add((member, str(name)))
                    if (member, str(name)) not in previous:
                        self.violate("I5", state.step, state.checkpoint, pointer("invariants", member, i),
                                     f"debug.desync reports {name}")
            previous = now

    # I6 -----------------------------------------------------------------------------------------------
    def i6(self) -> None:
        teardown = self.trace.teardown
        if teardown is None:
            self.skip("I6", None, "the trace has no teardown record")
            return
        self.checked("I6")
        for i, process in enumerate(teardown.get("processes") or []):
            self.violate("I6", None, None, f"/processes/{i}",
                         f"process {process.get('pid')} ({process.get('command', '?')}) outlived the case", "teardown")
        for i, path in enumerate(teardown.get("sockets") or []):
            self.violate("I6", None, None, f"/sockets/{i}", f"socket {path} outlived the case", "teardown")

    # I7 -----------------------------------------------------------------------------------------------
    def hidden_workspace(self, step: Step) -> Optional[str]:
        """The workspace a mutating step changes when no visible window shows it before or after."""
        prior, after = self.before_state(step), self.after_state(step)
        if prior is None or after is None:
            return None
        a, b = facet(prior.snapshot, "topology"), facet(after.snapshot, "topology")
        if a is None or b is None:
            return None
        nodes = {**topology_ids(b), **topology_ids(a)}
        workspaces = set()
        for value in step.target.values():
            if not isinstance(value, str) or value not in nodes:
                continue
            chain = [value, *ancestors(nodes, value)]
            workspaces |= {k for k in chain if nodes.get(k) and nodes[k].kind == "workspace"}
        shown = shown_workspaces(a) | shown_workspaces(b)
        hidden = sorted(workspaces - shown)
        return hidden[0] if len(workspaces) == 1 and hidden else None

    def i7(self) -> None:
        for step in self.trace.steps:
            if not step.mutating:
                continue
            workspace = self.hidden_workspace(step)
            if workspace is None:
                continue
            counters = step.record.get("layoutCounters")
            if not isinstance(counters, Mapping) or not all(isinstance(counters.get(k), Mapping) for k in ("before", "after")):
                self.skip("I7", step, f"the step changes hidden workspace {workspace} but has no layoutCounters")
                continue
            self.checked("I7")
            before, after = counters["before"], counters["after"]
            for name in VIEW_WORK_COUNTERS:
                if name not in before or name not in after:
                    continue
                delta = int(after[name]) - int(before[name])
                if delta > 0:
                    self.violate("I7", step, None, f"/layoutCounters/after/{name}",
                                 f"{name} +{delta} while the step changed hidden workspace {workspace}", "step")

    def run(self) -> Report:
        for check in (self.i1, self.i2, self.i3, self.i4, self.i5, self.i6, self.i7):
            check()
        return self.report


def shown_workspaces(topology: Mapping[str, Any]) -> Set[str]:
    windows = (topology.get("topology") or {}).get("windows") or []
    return {w["workspace"] for w in windows if w.get("visible") and w.get("workspace")}


DAEMON_TAB_KINDS = {"terminal": "terminal", "browser": "browser"}


def by_index(rows: Iterable[Mapping[str, Any]]) -> List[Mapping[str, Any]]:
    return sorted(rows, key=lambda r: (r.get("index", 0), r["id"]))


def tree_differences(topology: Mapping[str, Any], daemon: Mapping[str, Any]) -> List[Tuple[str, str]]:
    """Where the app's topology of the daemon's session differs from the daemon's tree: workspaces,
    each workspace's screen order, each screen's panes and zoomed pane, each pane's tab order and each
    tab's kind and terminal. The window's selected tab is an app fact and is not compared."""
    session = daemon.get("session") or {}
    own = (session.get("session") or {}).get("id")
    out: List[Tuple[str, str]] = []
    d_ws = {w["id"] for w in session.get("workspaces") or [] if w.get("session_id") == own}
    d_screens: Dict[str, List[str]] = {}
    for s in by_index(session.get("screens") or []):
        d_screens.setdefault(s.get("workspace_id"), []).append(s["id"])
    d_zoom = {s["id"]: (s.get("layout") or {}).get("zoomed_pane_id") for s in session.get("screens") or []}
    d_panes: Dict[str, Set[str]] = {}
    for p in session.get("panes") or []:
        d_panes.setdefault(p.get("screen_id"), set()).add(p["id"])
    d_tabs: Dict[str, List[str]] = {}
    for t in by_index(session.get("tabs") or []):
        d_tabs.setdefault(t.get("pane_id"), []).append(t["id"])
    d_tab = {t["id"]: t for t in session.get("tabs") or []}

    tree = topology.get("topology") or {}
    a_ws = set()
    for wi, ws in enumerate(tree.get("workspaces") or []):
        if ws.get("session") != own:
            continue
        at = ("topology", "topology", "workspaces", wi)
        a_ws.add(ws["id"])
        if ws["id"] not in d_ws:
            out.append((pointer(*at), f"workspace {ws['id']} is not in the daemon's session {own}"))
            continue
        screens = ws.get("screens") or []
        if [s["id"] for s in screens] != d_screens.get(ws["id"], []):
            out.append((pointer(*at, "screens"), f"screens {[s['id'] for s in screens]}, daemon {d_screens.get(ws['id'], [])}"))
            continue
        for si, screen in enumerate(screens):
            s_at = (*at, "screens", si)
            panes = screen.get("panes") or []
            if {p["id"] for p in panes} != d_panes.get(screen["id"], set()):
                out.append((pointer(*s_at, "panes"),
                            f"panes {sorted(p['id'] for p in panes)}, daemon {sorted(d_panes.get(screen['id'], set()))}"))
                continue
            if screen.get("zoomed_pane") != d_zoom.get(screen["id"]):
                out.append((pointer(*s_at, "zoomed_pane"),
                            f"zoomed pane {screen.get('zoomed_pane')}, daemon {d_zoom.get(screen['id'])}"))
            for pi, pane in enumerate(panes):
                p_at = (*s_at, "panes", pi)
                tabs = pane.get("tabs") or []
                if [t["id"] for t in tabs] != d_tabs.get(pane["id"], []):
                    out.append((pointer(*p_at, "tabs"), f"tabs {[t['id'] for t in tabs]}, daemon {d_tabs.get(pane['id'], [])}"))
                    continue
                for ti, tab in enumerate(tabs):
                    row = d_tab[tab["id"]]
                    d_kind = DAEMON_TAB_KINDS.get(row.get("content_kind"))
                    if d_kind and tab.get("kind") != d_kind:
                        out.append((pointer(*p_at, "tabs", ti, "kind"), f"kind {tab.get('kind')}, daemon {d_kind}"))
                    d_terminal = row.get("content_id") if row.get("content_kind") == "terminal" else None
                    if tab.get("terminal") != d_terminal:
                        out.append((pointer(*p_at, "tabs", ti, "terminal"),
                                    f"terminal {tab.get('terminal')}, daemon {d_terminal}"))
    for missing in sorted(d_ws - a_ws):
        out.append((pointer("topology", "topology", "workspaces"), f"daemon workspace {missing} is not in the app topology"))
    return out


def load_schema(path: Path = SNAPSHOT_SCHEMA) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def check_trace(document: Any, case: Optional[Mapping[str, Any]] = None,
                schema: Optional[Mapping[str, Any]] = None) -> Report:
    """I1-I7 over one cmux.oracle.trace/v1 document. Raises TraceError on a malformed trace."""
    trace = load_trace(document, case)
    return Checker(trace, VolatileMask(schema if schema is not None else load_schema())).run()


# ---------------------------------------------------------------------------------------------- self test


def _example() -> Dict[str, Any]:
    return json.loads(EXAMPLE_SNAPSHOT.read_text(encoding="utf-8"))


def _trace(*steps: Dict[str, Any], teardown: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    doc: Dict[str, Any] = {"schema": TRACE_SCHEMA, "case": "selftest/case", "steps": list(steps)}
    doc["teardown"] = {"processes": [], "sockets": []} if teardown is None else teardown
    return doc


WS = "ws_000000000000000000000000000000b1"
SCREEN = "screen_000000000000000000000000000000c1"
PANE1 = "pane_000000000000000000000000000000d1"
PANE2 = "pane_000000000000000000000000000000d2"
TAB1 = "tab_000000000000000000000000000000e1"
TAB2 = "tab_000000000000000000000000000000e2"
HIDDEN_WS = "ws_000000000000000000000000000000b9"


def _with_hidden_workspace(snapshot: Dict[str, Any]) -> Dict[str, Any]:
    """The example plus a second workspace of the same window that no window shows, in both facets."""
    snap = copy.deepcopy(snapshot)
    tree = snap["facets"]["topology"]["topology"]
    ws = copy.deepcopy(tree["workspaces"][0])
    ws["id"] = ws["key"] = HIDDEN_WS
    ws["screens"][0]["id"] = "screen_000000000000000000000000000000c9"
    ws["screens"][0]["panes"] = [ws["screens"][0]["panes"][0]]
    pane = ws["screens"][0]["panes"][0]
    pane["id"] = "pane_000000000000000000000000000000d9"
    pane["tabs"][0].update(id="tab_000000000000000000000000000000e9", terminal="term_000000000000000000000000000000f9")
    tree["workspaces"].append(ws)
    tree["windows"][0]["workspaces"].append(HIDDEN_WS)
    session = snap["facets"]["daemon"]["session"]
    session["workspaces"].append({**session["workspaces"][0], "id": HIDDEN_WS, "index": 1, "focused": False})
    session["screens"].append({**copy.deepcopy(session["screens"][0]), "id": "screen_000000000000000000000000000000c9",
                               "workspace_id": HIDDEN_WS})
    session["screens"][-1]["layout"]["zoomed_pane_id"] = None
    session["panes"].append({**session["panes"][0], "id": "pane_000000000000000000000000000000d9",
                             "screen_id": "screen_000000000000000000000000000000c9"})
    session["tabs"].append({**copy.deepcopy(session["tabs"][0]), "id": "tab_000000000000000000000000000000e9",
                            "pane_id": "pane_000000000000000000000000000000d9",
                            "content_id": "term_000000000000000000000000000000f9"})
    return snap


def _close_tab2(snapshot: Dict[str, Any]) -> Dict[str, Any]:
    """The example after closing tab e2: its pane d2 and its browser close with it."""
    snap = copy.deepcopy(snapshot)
    screen = snap["facets"]["topology"]["topology"]["workspaces"][0]["screens"][0]
    screen["panes"] = [p for p in screen["panes"] if p["id"] != PANE2]
    session = snap["facets"]["daemon"]["session"]
    session["panes"] = [p for p in session["panes"] if p["id"] != PANE2]
    session["tabs"] = [t for t in session["tabs"] if t["id"] != TAB2]
    session["browsers"] = []
    snap["facets"]["topology"]["tab_count"] = 1
    return snap


def _bump_sequences(snapshot: Dict[str, Any], by: int) -> Dict[str, Any]:
    snap = copy.deepcopy(snapshot)
    snap["facets"]["topology"]["sequence"] += by
    snap["facets"]["topology"]["topology"]["sequence"] += by
    snap["facets"]["topology"]["generation"] += by
    snap["facets"]["daemon"]["journalHead"] += by
    return snap


class InvariantsSelfTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.schema = load_schema()
        cls.base = _example()

    def check(self, doc: Dict[str, Any], case: Optional[Dict[str, Any]] = None) -> Report:
        return check_trace(doc, case, self.schema)

    def ids(self, report: Report) -> List[Tuple[str, str]]:
        return [(v.invariant, v.pointer) for v in report.violations]

    def test_every_invariant_has_an_id_a_rule_and_a_pointer(self) -> None:
        self.assertEqual([inv.id for inv in INVARIANTS], [f"I{n}" for n in range(1, 8)])
        for inv in INVARIANTS:
            self.assertTrue(inv.rule and inv.pointer.split(":")[0] in {"step", "snapshot", "teardown"}, inv)

    def test_a_clean_trace_has_no_violation_and_checks_every_invariant(self) -> None:
        closed = _bump_sequences(_close_tab2(self.base), 1)
        hidden_before = _bump_sequences(_with_hidden_workspace(self.base), 2)
        renamed = _bump_sequences(hidden_before, 1)
        renamed["facets"]["daemon"]["session"]["workspaces"][1]["name"] = "renamed"
        turn = copy.deepcopy(closed)
        turn["facets"] = {k: turn["facets"][k] for k in ("topology", "intents")}
        turn["meta"]["facets"] = ["topology", "intents"]
        doc = _trace(
            {"id": "close", "op": "action.run", "target": {"tab": TAB2}, "replies": [{"receipt": "action.applied"}],
             "checkpoints": {"before": self.base, "turn": turn, "settled": closed}},
            {"id": "read", "op": "resource.call", "readOnly": True, "replies": [],
             "checkpoints": {"settled": closed}},
            {"id": "reopen", "op": "resource.call", "target": {"pane": PANE1},
             "replies": [{"receipt": "mutation_result", "result": {"tab": TAB2}}],
             "checkpoints": {"settled": _bump_sequences(self.base, 1)}},
            {"id": "new-hidden", "op": "resource.call", "target": {"session": "session_00000000000000000000000000000002"},
             "replies": [{"receipt": "mutation_result", "result": {"workspace": HIDDEN_WS}}],
             "checkpoints": {"settled": hidden_before}},
            {"id": "rename-hidden", "op": "resource.call", "target": {"workspace": HIDDEN_WS},
             "replies": [{"receipt": "mutation_result"}],
             "checkpoints": {"before": hidden_before, "settled": renamed},
             "layoutCounters": {"before": {"pane_snapshots": 4, "indicator_resyncs": 1},
                                "after": {"pane_snapshots": 4, "indicator_resyncs": 2}}},
        )
        report = self.check(doc)
        self.assertEqual(report.violations, [], [v.to_json() for v in report.violations])
        self.assertEqual(report.not_checked, [])
        self.assertTrue(all(report.checked[inv.id] > 0 for inv in INVARIANTS), report.checked)

    # I1
    def test_i1_missing_extra_untyped_and_wrong_receipts(self) -> None:
        steps = [
            {"id": "none", "op": "action.run", "target": {"tab": TAB1}, "replies": []},
            {"id": "two", "op": "resource.call", "target": {"tab": TAB1},
             "replies": [{"receipt": "mutation_result"}, {"error": "validation.invalid"}]},
            {"id": "untyped", "op": "resource.call", "target": {"tab": TAB1}, "replies": [{"error": "boom"}]},
            {"id": "both", "op": "cli", "replies": [{"receipt": "action.done", "error": "a.b"}]},
            {"id": "wrong", "op": "action.run", "target": {"tab": TAB1}, "expect": {"outcome": "ok", "receipt": "action.done"},
             "replies": [{"receipt": "action.applied"}]},
            {"id": "keys", "op": "key", "args": {"keys": ["cmd+t", "cmd+w"]}, "replies": [{"receipt": "action.done"}]},
            {"id": "said-none", "op": "action.run", "target": {"tab": TAB1},
             "expect": {"outcome": "ok", "noReceiptReason": "focus moves only in the app"},
             "replies": [{"receipt": "action.done"}]},
            {"id": "lost", "op": "mcp"},
        ]
        report = self.check(_trace(*steps))
        got = [(v.step, v.pointer) for v in report.violations if v.invariant == "I1"]
        self.assertEqual(got, [("none", "/replies"), ("two", "/replies/1"), ("untyped", "/replies/0"),
                               ("both", "/replies/0"), ("wrong", "/replies/0"), ("keys", "/replies"),
                               ("said-none", "/replies/0"), ("lost", "/replies")])
        self.assertTrue(all(v.where == "step" for v in report.violations if v.invariant == "I1"))

    def test_i1_ignores_reads_settles_and_kills_and_allows_no_receipt_with_a_reason(self) -> None:
        steps = [
            {"id": "read", "op": "resource.call", "readOnly": True},
            {"id": "settle", "op": "settle"},
            {"id": "kill", "op": "kill", "target": {"process": "holder"}},
            {"id": "quiet", "op": "action.run", "target": {"tab": TAB1}, "replies": [],
             "expect": {"outcome": "ok", "noReceiptReason": "focus moves only in the app"}},
        ]
        report = self.check(_trace(*steps))
        self.assertEqual([v for v in report.violations if v.invariant == "I1"], [])

    def test_i1_reads_op_and_expect_from_the_case(self) -> None:
        case = {"id": "c", "steps": [{"id": "s", "op": "action.run", "expect": {"outcome": "ok", "receipt": "action.done"}}]}
        report = self.check(_trace({"id": "s", "replies": [{"receipt": "action.applied"}]}), case)
        self.assertEqual(self.ids(report), [("I1", "/replies/0")])

    # I2
    def test_i2_an_untargeted_close_and_a_replaced_id(self) -> None:
        closed = _close_tab2(self.base)
        report = self.check(_trace(
            {"id": "a", "op": "settle", "checkpoints": {"settled": self.base}},
            {"id": "b", "op": "action.run", "target": {"tab": TAB1}, "replies": [{"receipt": "action.done"}],
             "checkpoints": {"settled": closed}},
        ))
        got = [v for v in report.violations if v.invariant == "I2"]
        self.assertEqual([v.pointer for v in got], ["/topology/topology/workspaces/0/screens/0/panes/1"])
        self.assertIn(PANE2, got[0].message)
        renamed = copy.deepcopy(self.base)
        renamed["facets"]["topology"]["topology"]["workspaces"][0]["screens"][0]["panes"][0]["tabs"][0]["id"] = \
            "tab_000000000000000000000000000000ee"
        report = self.check(_trace({"id": "r", "op": "restart", "target": {"process": "daemon"},
                                    "checkpoints": {"before": self.base, "settled": renamed}}))
        got = sorted((v.pointer, v.message.split()[1]) for v in report.violations if v.invariant == "I2")
        self.assertEqual(got, [("/topology/topology/workspaces/0/screens/0/panes/0/tabs/0", TAB1),
                               ("/topology/topology/workspaces/0/screens/0/panes/0/tabs/0",
                                "tab_000000000000000000000000000000ee")])

    def test_i2_a_key_acts_on_focus_and_a_read_changes_nothing(self) -> None:
        closed = _close_tab2(self.base)
        focused = copy.deepcopy(self.base)
        focused["facets"]["topology"]["topology"]["focus"].update(pane=PANE2, tab=TAB2)
        ok = self.check(_trace({"id": "w", "op": "key", "args": {"keys": ["cmd+w"]}, "replies": [{"receipt": "action.done"}],
                                "checkpoints": {"before": focused, "settled": closed}}))
        self.assertEqual([v for v in ok.violations if v.invariant == "I2"], [])
        read = self.check(_trace({"id": "r", "op": "resource.call", "readOnly": True, "target": {"tab": TAB2},
                                  "checkpoints": {"before": self.base, "settled": closed}}))
        self.assertEqual([v.invariant for v in read.violations], ["I2"])

    # I3
    def test_i3_a_turn_that_settles_elsewhere_without_a_refusal(self) -> None:
        turn = copy.deepcopy(self.base)
        turn["facets"]["topology"]["topology"]["focus"]["pane"] = PANE2
        settled = _bump_sequences(self.base, 3)  # volatile counters only: equal projections
        step = {"id": "focus", "op": "action.run", "target": {"pane": PANE2}, "replies": [{"receipt": "action.applied"}],
                "checkpoints": {"before": self.base, "turn": turn, "settled": settled}}
        report = self.check(_trace(step))
        self.assertEqual(self.ids(report), [("I3", "/topology/topology/focus/pane")])
        self.assertIn("no refusal", report.violations[0].message)

    def test_i3_a_rolled_back_turn_passes_only_with_a_counted_refusal(self) -> None:
        turn = copy.deepcopy(self.base)
        turn["facets"]["topology"]["topology"]["focus"]["pane"] = PANE2
        settled = copy.deepcopy(self.base)
        settled["facets"]["intents"]["totals"]["rolledBack"] += 1
        step = {"id": "focus", "op": "action.run", "target": {"pane": PANE2}, "replies": [{"error": "intent.rolled_back"}],
                "checkpoints": {"before": self.base, "turn": turn, "settled": settled}}
        self.assertEqual(self.check(_trace(step)).violations, [])
        half = copy.deepcopy(settled)
        half["facets"]["layout"] = {"status": "not-comparable", "reason": "x"}
        half["facets"]["topology"]["topology"]["focus"]["tab"] = TAB2
        step["checkpoints"]["settled"] = half
        report = self.check(_trace(step))
        self.assertEqual([v.invariant for v in report.violations], ["I3"])
        self.assertIn("not the before state", report.violations[0].message)

    def test_i3_volatile_fields_and_bookkeeping_facets_do_not_count(self) -> None:
        mask = VolatileMask(self.schema)
        a = mask.facet("topology", self.base["facets"]["topology"])
        b = mask.facet("topology", _bump_sequences(self.base, 9)["facets"]["topology"])
        self.assertIsNone(first_difference(a, b))
        self.assertNotIn("sequence", a)
        d = mask.facet("daemon", self.base["facets"]["daemon"])
        self.assertNotIn("journalHead", d)
        self.assertNotIn("revision", d["session"]["session"])
        self.assertNotIn("name_revision", d["session"]["tabs"][0]["extra"])

    # I4
    def test_i4_a_paired_cut_with_a_missing_tab_and_an_unpaired_settle(self) -> None:
        self.assertEqual(tree_differences(self.base["facets"]["topology"], self.base["facets"]["daemon"]), [])
        drift = copy.deepcopy(self.base)
        drift["facets"]["daemon"]["session"]["tabs"][0]["content_id"] = "term_000000000000000000000000000000ff"
        report = self.check(_trace({"id": "s", "op": "settle", "checkpoints": {"settled": drift}}))
        self.assertEqual(self.ids(report), [("I4", "/topology/topology/workspaces/0/screens/0/panes/0/tabs/0/terminal")])
        lag = copy.deepcopy(self.base)
        lag["facets"]["daemon"]["journalHead"] = 43
        report = self.check(_trace({"id": "s", "op": "settle", "checkpoints": {"settled": lag}}))
        self.assertEqual(self.ids(report), [("I4", "/topology/sequence")])
        moved = copy.deepcopy(self.base)
        moved["facets"]["daemon"]["session"]["tabs"][1]["pane_id"] = PANE1
        report = self.check(_trace({"id": "s", "op": "settle", "checkpoints": {"settled": moved}}))
        self.assertEqual([p for i, p in self.ids(report) if i == "I4"],
                         ["/topology/topology/workspaces/0/screens/0/panes/0/tabs",
                          "/topology/topology/workspaces/0/screens/0/panes/1/tabs"])

    def test_i4_without_a_journal_head_is_not_checked(self) -> None:
        v0 = copy.deepcopy(self.base)
        del v0["facets"]["daemon"]["journalHead"]
        report = self.check(_trace({"id": "s", "op": "settle", "checkpoints": {"settled": v0}}))
        self.assertEqual(report.violations, [])
        self.assertEqual([(n.invariant, n.step) for n in report.not_checked], [("I4", "s")])

    # I5
    def test_i5_reports_each_desync_where_it_first_shows(self) -> None:
        bad = copy.deepcopy(self.base)
        bad["facets"]["invariants"]["violations"] = ["focus.single-first-responder"]
        bad["facets"]["invariants"]["windowInvariants"] = ["key-window-not-main"]
        report = self.check(_trace({"id": "a", "op": "settle", "checkpoints": {"before": self.base, "settled": bad}},
                                   {"id": "b", "op": "settle", "checkpoints": {"settled": bad}}))
        self.assertEqual([(v.invariant, v.step, v.pointer) for v in report.violations],
                         [("I5", "a", "/invariants/violations/0"), ("I5", "a", "/invariants/windowInvariants/0")])

    # I6
    def test_i6_orphans_and_a_missing_teardown(self) -> None:
        report = self.check(_trace({"id": "s", "op": "settle"},
                                   teardown={"processes": [{"pid": 4242, "command": "cmux-tui daemon"}],
                                             "sockets": ["/tmp/o/abc/def/cmux.sock"]}))
        self.assertEqual([(v.invariant, v.where, v.pointer) for v in report.violations],
                         [("I6", "teardown", "/processes/0"), ("I6", "teardown", "/sockets/0")])
        doc = _trace({"id": "s", "op": "settle"})
        del doc["teardown"]
        report = self.check(doc)
        self.assertEqual(report.violations, [])
        self.assertEqual([n.invariant for n in report.not_checked], ["I6"])

    # I7
    def test_i7_view_work_for_a_hidden_workspace(self) -> None:
        before = _with_hidden_workspace(self.base)
        after = _bump_sequences(before, 1)
        counters = {"before": {"pane_snapshots": 4, "layout_root_layouts": 10, "topology_sends": 2},
                    "after": {"pane_snapshots": 5, "layout_root_layouts": 10, "topology_sends": 3}}
        step = {"id": "tab-in-hidden", "op": "resource.call", "target": {"pane": "pane_000000000000000000000000000000d9"},
                "replies": [{"receipt": "mutation_result"}], "checkpoints": {"before": before, "settled": after},
                "layoutCounters": counters}
        report = self.check(_trace(step))
        self.assertEqual(self.ids(report), [("I7", "/layoutCounters/after/pane_snapshots")])
        visible = dict(step, target={"pane": PANE1})
        self.assertEqual(self.check(_trace(visible)).violations, [])
        del step["layoutCounters"]
        report = self.check(_trace(step))
        self.assertEqual([(n.invariant, n.step) for n in report.not_checked], [("I7", "tab-in-hidden")])

    def test_cli_exit_codes(self) -> None:
        import io
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            good = Path(tmp) / "good.json"
            good.write_text(json.dumps(_trace({"id": "s", "op": "settle", "checkpoints": {"settled": self.base}})))
            bad = Path(tmp) / "bad.json"
            bad.write_text(json.dumps(_trace({"id": "s", "op": "action.run", "replies": []})))
            junk = Path(tmp) / "junk.json"
            junk.write_text("{}")
            out = io.StringIO()
            self.assertEqual(main(["check", str(good)], out=out), 0)
            self.assertEqual(main(["check", str(bad), "--json"], out=out), 1)
            self.assertEqual(main(["check", str(junk)], out=out, err=io.StringIO()), 2)


# ---------------------------------------------------------------------------------------------- CLI


def print_report(report: Report, out: Any) -> None:
    for v in report.violations:
        where = "/".join(x for x in (v.step, v.checkpoint) if x) or "case"
        print(f"{v.invariant} {report.case} {where} {v.where}:{v.pointer}  {v.message}", file=out)
    for n in report.not_checked:
        print(f"{n.invariant} {report.case} {n.step or 'case'} not checked: {n.reason}", file=out)
    checked = " ".join(f"{k}={n}" for k, n in report.checked.items())
    print(f"{report.case}: {len(report.violations)} violation(s); checked {checked}", file=out)


def main(argv: Optional[Sequence[str]] = None, out: Any = None, err: Any = None) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--selftest", action="store_true", help="run the synthetic violation tests")
    parser.add_argument("--list", action="store_true", help="print each invariant's id, rule and pointer")
    sub = parser.add_subparsers(dest="command")
    check = sub.add_parser("check", help="check one trace")
    check.add_argument("trace", type=Path)
    check.add_argument("--case", type=Path, help="the corpus case, for step fields the trace leaves out")
    check.add_argument("--schema", type=Path, default=SNAPSHOT_SCHEMA)
    check.add_argument("--json", action="store_true", help="print the report as JSON")
    args = parser.parse_args(argv)
    if args.selftest:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(InvariantsSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.list:
        for inv in INVARIANTS:
            print(f"{inv.id}\t{inv.rule}\t{inv.pointer}\t{inv.task}", file=out)
        return 0
    if args.command != "check":
        parser.print_usage(err)
        return 2
    try:
        document = json.loads(args.trace.read_text(encoding="utf-8"))
        case = json.loads(args.case.read_text(encoding="utf-8")) if args.case else None
        report = check_trace(document, case, load_schema(args.schema))
    except (OSError, ValueError, TraceError, KeyError, TypeError) as error:
        print(f"invariants.py: {args.trace}: {error}", file=err)
        return 2
    if args.json:
        print(json.dumps(report.to_json(), sort_keys=True), file=out)
    else:
        print_report(report, out)
    return 1 if report.violations else 0


if __name__ == "__main__":
    sys.exit(main())
