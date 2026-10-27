#!/usr/bin/env python3
"""Oracle invariants I1-I7 (p15-oracle-110), I9 (p15-oracle-205), I10 (p15-oracle-206) and I17-I18
(p15-oracle-188) over one case trace.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md section 3F ("Invariants at every checkpoint") and
plans/cmux-next/oracle-DESIGN.md. Stdlib only, Python 3.9+, safe under `python3 -I`. Later tasks add
I8 (204), I11-I15 (217) and I16 (236) to INVARIANTS and Checker.run.

| Id | Rule                                                                  | Reads                          |
| I1 | each mutation gives exactly one receipt or one typed error            | step replies                   |
| I2 | ids stay stable unless the step created or closed them               | topology + daemon facets       |
| I3 | turn projection == settled, or settled == before + a refusal          | turn/settled/before + intents  |
| I4 | app topology == daemon tree at the same sequence                      | topology + daemon facets       |
| I5 | 0 `debug.desync` violations                                           | invariants facet               |
| I6 | no orphan processes or sockets at teardown                            | teardown record                |
| I7 | a hidden-workspace change does no view work                           | step layoutCounters + topology |
| I9 | journal restore_preview == live daemon facet on the restorable sections | restorePreviews + daemon facet |
| I10| a same-key retry: same result, replayed, same journal head and facets | replies + retry before/settled |
| I17| 0 unexpected child exits unless `allow_crashes` covers the kind       | crashes facet + case            |
| I18| live-object counts return to the fixture baseline after teardown      | liveObjects + daemon.oracle    |

Chrome reference (chromium/src): content/public/test/browser_test_base.h checks invariants after every
browser test (NoRendererCrashesAssertion, the leak checks of content/public/test/test_launcher.h) the
way these run on every case, not per case; base/test/launcher/test_launcher.cc reports a leaked child
process of a test as a failure of that test (I6). NoRendererCrashesAssertion fails a test on a renderer
crash that no ScopedAllowRendererCrashes covers (I17, the case's `allow_crashes`), and Blink's leak
detector compares InstanceCounters after a web test with the counts before it
(third_party/blink/renderer/core/testing/internals.cc; I18). A failed check names its value, as gtest's
EXPECT_EQ prints both sides; here every violation names its JSON pointer. I10 is the contract of
net/http/http_request_info.h `idempotency`: HttpNetworkTransaction::ShouldResendRequest
(net/http/http_network_transaction.cc) resends a request on a reset connection only when it is idempotent,
because sending it twice must have the effect of sending it once.

I10 finds a retry by its key: a mutating resource.call whose idempotencyKey, method, params and target equal
an earlier step's (gen_daemon_ops.py adds one, step `retry`, to each operation's success case but those whose
success ends the daemon). The same key with another request is idempotency.conflict's case, not a retry. When
the first call got a receipt, the retry's reply equals the first reply, its MutationResult included except
`replayed`: that flag is false on the first call (a key the trace never sent) and true on the retry, the
daemon's own word that it answered from its receipt. The daemon journal head (raw `daemon.journalHead`,
volatile in the canonical form) is the same at the retry's settled checkpoint as at its before checkpoint (no
new record); and every model facet of the two checkpoints is equal under I3's projection. A refused first call
recorded no effect to replay: its retry is not checked.

I17 reads `crashes.counts`, totals since the app launched (holder: since the owner started): an exit is
a rise of a kind's total from one comparable reading to the next. A rise first seen at a step's turn or
settled checkpoint happened during that step; one first seen at its before checkpoint happened after the
previous step, and belongs to it. When checkpoints between two readings are missing or not comparable
(a kill step's reconnect), the rise belongs to every step it could have happened in, and an entry that
covers any of them accepts it. The baseline is the first step's before checkpoint; without it the
first step's exits are not checked. A total that falls was reset (a new owner counts from 0): its value
is the rise.
I9 reads the daemon's `oracle-restore-preview` reply (spec/commands.md): the latest journal checkpoint
reduced through the journal head on a read-only journal reader, with the daemon's section map. At a
checkpoint whose daemon facet has the preview's head as its `journalHead` (one cut), each section the map
does not exclude with a reason must equal the live `session` facet's, after the facet's capture rules and
volatile mask; a required record the reducer cannot apply fails too, and so does a state change it does not
reduce (`stateChangesNotReduced`: `extra` is then the checkpoint's, so it is reported instead of compared).
The daemon driver asks for the preview `through` the facet's `journalHead`, so both are one cut. This is
Chromium's session restore
check (chrome/browser/sessions/session_restore_browsertest.cc restores the commands SessionService wrote and
compares the restored windows and tabs with the ones that wrote them), run on every checkpoint instead of
once per test. A preview at another sequence, or with no journal checkpoint yet, is not checked.
I18 compares the owned-object counts of `liveObjects` and `daemon.oracle.liveObjects` at the teardown
checkpoint with those at the case's first checkpoint, the fixture baseline. `subscriptions` and `tasks`
are timing state (armed observations, pending deadlines), not owned objects: a difference there is
reported as not checked, never a failure.

The checks run on raw checkpoints, before normalize.py: I4 pairs the cut by the raw sequences that the
canonical form drops (x-oracle-volatile), and ids of one run need no relabeling to be compared with
each other. I3 compares projections (`Projector`) that apply normalize.py's value rules to turn and
settled alike: volatile fields out, numbers rounded to x-oracle-precision, x-oracle-order: set arrays
sorted. Raw ids stay, so commit counters, set order and float jitter never count as a difference.

Trace (`cmux.oracle.trace/v1`), for the product drivers (driver_daemon.py 023, driver_app.py 047):
    {"schema": "cmux.oracle.trace/v1", "case": "suite/name",
     "steps": [{"id", "op", "readOnly"?, "expect"?, "args"?,
                "target"?: {kind: public id}      (handles and $step refs already resolved),
                "action"?: action id              (a key step: the action its keys ran, for I3's lastRefusal),
                "replies": [{"receipt": KIND, "result"?: MutationResult} | {"error": CODE}, ...]
                                                  (every reply the step got; `result` is the reply's result as
                                                  the daemon sent it, for a mutation the MutationResult
                                                  {value, generation, revision, replayed} of
                                                  cmux-tui-core/src/resource_router.rs mutation_result),
                "checkpoints": {"before"?|"turn"?|"settled"?: snapshot-v1 (raw)},
                "layoutCounters"?: {"before": {name: n}, "after": {name: n}},  (debug.layout_counters)
                "restorePreviews"?: {"before"?|"turn"?|"settled"?: oracle-restore-preview reply}}],
     "allow_crashes"?: [case-v1 allowCrash],
     "teardown"?: {"processes": [{"pid", "command"}], "sockets": [path],
                   "checkpoint"?: snapshot-v1 (raw, after the case's teardown and a settle)}}
Step fields missing from the trace come from the case (`--case`), matched by step id; so does
`allow_crashes` when the trace has none.

Not run by oracle.py yet: its driver protocol (017) returns canonical checkpoints only. `driver_daemon.py
run-case --trace TRACE.json` writes a partial trace (each step's id, op, raw checkpoints and I9's
restorePreviews, through the facet's journalHead after a journal checkpoint at setup), so I9 runs on daemon
cases. Replies, layoutCounters and teardown are in no driver trace yet. A follow-up of 017, 023 and 047
carries them in the driver result and makes `perform_run` turn a violation into a case Failure; until then
`invariants.py check` runs on a trace file and `--selftest` on synthetic traces.

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
# `python3 -I` does not put the script's directory on sys.path; normalize.py owns the value rules I3 reuses,
# check_snapshot_schema.py the capture rules I9 applies to the raw restore preview.
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
from check_snapshot_schema import capture  # noqa: E402
from normalize import MAX_SAFE_INT, _precision_decimals, canonical_json  # noqa: E402
SNAPSHOT_SCHEMA = REPO / "schemas" / "oracle" / "snapshot-v1.schema.json"
EXAMPLE_SNAPSHOT = REPO / "schemas" / "oracle" / "fixtures" / "snapshot-example.json"

TRACE_SCHEMA = "cmux.oracle.trace/v1"
REPORT_SCHEMA = "cmux.oracle.invariants/v1"
CHECKPOINT_ORDER = ("before", "turn", "settled")
# MutationResult's flag (spec generics.MutationResult): false on a call that ran, true on a same-key replay (I10).
REPLAY_FLAG = "replayed"
# Typed outcomes, the patterns of case-v1 $defs.expect.error and .receipt.
ERROR_CODE = re.compile(r"^[a-z][a-z_]*(\.[a-z][a-z_]*)+$")
RECEIPT_KIND = re.compile(r"^[a-z][A-Za-z0-9]*([._][a-z][A-Za-z0-9]*)*$")
# Ops that change the model (I2 attributes id changes to them, I7 checks their view work).
MUTATING_OPS = frozenset({"resource.call", "action.run", "key", "cli", "mcp", "tui.key"})
# Process lifecycle ops: case-v1 lists them as always mutating with an expected outcome, so I1 holds
# their receipt (a restart's identify) or noReceiptReason; they may change no structural id (I2).
LIFECYCLE_OPS = frozenset({"kill", "restart"})
READ_CAPABLE_OPS = frozenset({"resource.call", "cli", "mcp"})
KEY_OPS = frozenset({"key", "tui.key"})
# Facets that count the pipeline, not the model: a pending intent at the turn becomes applied at the
# settle, tasks finish, hit counters move. I3 compares the other facets.
# liveObjects members that count timing state, not owned objects (I18): armed observations and the main
# thread's pending deadlines (app), live event subscriptions (daemon).
TIMING_LIVE_KINDS = frozenset({"subscriptions", "tasks"})
BOOKKEEPING_FACETS = frozenset({"intents", "switches", "liveObjects", "crashes", "invariants"})
# The crash kinds of the crashes facet and case-v1 `crashKind`, in schema order.
CRASH_KINDS = ("renderer", "gpu", "browser", "utility", "daemon", "holder")
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
    Invariant("I9", "journal restore_preview == live daemon facet on the restorable sections",
              "snapshot: /daemon/session/<section>/... (the live value the restore misses) or /daemon/journalHead",
              "p15-oracle-205"),
    Invariant("I10", "a same-key retry gives the first call's result with replayed true, no new journal record and "
              "no facet change",
              "step: /replies/0/... of the retry (/replies/0/result/replayed: the flag); snapshot: /daemon/journalHead "
              "or the first facet value that differs",
              "p15-oracle-206"),
    Invariant("I17", "0 unexpected child exits unless allow_crashes covers the kind",
              "snapshot: /crashes/exits/<n> (an exit the app saw) or /crashes/counts/<kind>", "p15-oracle-188"),
    Invariant("I18", "live-object counts return to the fixture baseline after teardown",
              "snapshot: /liveObjects/<kind> or /daemon/oracle/liveObjects/<kind> of the teardown checkpoint",
              "p15-oracle-188"),
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
    def answers(self) -> bool:
        """I1 holds its replies: a mutation, a kill or a restart."""
        return self.mutating or self.op in LIFECYCLE_OPS

    @property
    def action_id(self) -> Optional[str]:
        """The action an action.run ran, or the action a key step's keys resolved to (from the driver)."""
        value = (self.record.get("args") or {}).get("action") if self.op == "action.run" else self.record.get("action")
        return value if isinstance(value, str) else None

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
    allow_crashes: List[Mapping[str, Any]] = field(default_factory=list)

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
    if teardown is not None and "checkpoint" in teardown and not isinstance(teardown["checkpoint"], Mapping):
        raise TraceError("teardown/checkpoint: want a snapshot object")
    allow = document.get("allow_crashes", (case or {}).get("allow_crashes", []))
    if not isinstance(allow, list) or not all(isinstance(entry, Mapping) and entry.get("kind") in CRASH_KINDS
                                               for entry in allow):
        raise TraceError(f"allow_crashes: want a list of {{kind, reason, steps?, max?}} with kind in {CRASH_KINDS}")
    return Trace(str(name), steps, teardown, list(allow))


# ---------------------------------------------------------------------------------------------- volatile mask


class Projector:
    """normalize.py's value rules on a raw facet, ids kept: step 1 drops the fields the schema marks
    `x-oracle-volatile` and the members of open objects that match a volatile `x-oracle-open-keys`
    pattern, step 4 rounds numbers to `x-oracle-precision` (`x-oracle-precision-default` where no schema
    covers them), step 5 sorts `x-oracle-order: set` arrays by each item's canonical JSON. Branches of
    oneOf, anyOf and allOf all apply: the facet branches are an object or notComparable, which share no
    field."""

    def __init__(self, schema: Mapping[str, Any]):
        self.schema = schema
        self.definitions = schema.get("definitions", {})
        self.facets = schema["properties"]["facets"]["properties"]
        self.open_volatile = [re.compile(e["key"]) for e in schema.get("x-oracle-open-keys", [])
                              if "x-oracle-volatile" in e]
        self.default_decimals = _precision_decimals(schema.get("x-oracle-precision-default", 0.001))

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
            out_items = [self.strip(item, item_node) for item in value]
            if any(b.get("x-oracle-order") == "set" for b in branches):
                out_items.sort(key=canonical_json)
            return out_items
        if isinstance(value, float):
            return self.round(value, branches)
        return value

    def restore_section(self, name: str, live: Any, restored: Any) -> Tuple[Any, Any]:
        """I9's projections of one `session.snapshot` section: the live value is the daemon facet's (already
        captured), the restored one is raw wire, so it takes the facet's capture rules first
        (check_snapshot_schema.capture: a `derive: sha256` field holds the hash); both then lose their
        volatile fields and round as the daemon facet's schema says."""
        node = (self.facets["daemon"]["oneOf"][0]["properties"]["session"]["properties"]).get(name)
        if node is not None:
            restored = capture(self.schema, node, restored)
        return self.strip(live, node), self.strip(restored, node)

    def round(self, value: float, branches: List[Mapping[str, Any]]) -> Any:
        """normalize.py's step 4: an open number takes the default precision, a typed one its own."""
        if not branches:
            decimals: Optional[int] = self.default_decimals
        else:
            steps = [b["x-oracle-precision"] for b in branches if "x-oracle-precision" in b]
            decimals = _precision_decimals(steps[0]) if steps else None
        if decimals is None:
            return value
        rounded = round(value, decimals) or 0.0  # -0.0 and 0.0 are one value
        return int(rounded) if rounded.is_integer() and abs(rounded) < MAX_SAFE_INT else rounded


def without_replay_flag(reply: Any) -> Any:
    """A reply with its MutationResult's `replayed` taken out: the one field a replay changes (I10)."""
    if isinstance(reply, Mapping) and isinstance(reply.get("result"), Mapping) and REPLAY_FLAG in reply["result"]:
        return {**reply, "result": {k: v for k, v in reply["result"].items() if k != REPLAY_FLAG}}
    return reply


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


Graph = Dict[str, Set[str]]


def parent_graph(sources: Iterable[Mapping[str, Node]]) -> Graph:
    """Every id's containers over all sources: a workspace is in its window (topology) and in its session
    (daemon), so a window or a session target covers it whichever facet holds it."""
    graph: Graph = {}
    for nodes in sources:
        for key, node in nodes.items():
            parents = graph.setdefault(key, set())
            if node.parent:
                parents.add(node.parent)
    return graph


def ancestors(graph: Mapping[str, Set[str]], start: str) -> Set[str]:
    out: Set[str] = set()
    todo = list(graph.get(start, ()))
    while todo:
        parent = todo.pop()
        if parent not in out:
            out.add(parent)
            todo.extend(graph.get(parent, ()))
    return out


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
    def __init__(self, trace: Trace, projector: "Projector"):
        self.trace = trace
        self.projector = projector
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
            if not step.answers:
                continue
            self.checked("I1")
            replies = step.record.get("replies")
            if not isinstance(replies, list):
                self.violate("I1", step, None, "/replies", "the trace has no replies for this step", "step")
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
    def roots(self, step: Step, known: Set[str]) -> Set[str]:
        """The objects a mutating step acts on: its targets, the ids its replies name and, for a key, the
        focused pane and tab its keys go to. A key's window target only says which window has the keys:
        a root covers its children's closes, and the whole window would cover every tab in it."""
        out = set(self.acted_targets(step))
        if step.op in KEY_OPS:
            out |= set(self.focused_ids(step))
        out |= {s for s in strings_in(step.record.get("replies") or []) if s in known}
        return out

    @staticmethod
    def target_ids(step: Step) -> List[str]:
        return [v for k, v in step.target.items() if k != "process" and isinstance(v, str)]

    @staticmethod
    def acted_targets(step: Step) -> List[str]:
        """The targets the step acts on; a key's window or workspace target only routes its keys."""
        skip = ("process", "window", "workspace") if step.op in KEY_OPS else ("process",)
        return [v for k, v in step.target.items() if k not in skip and isinstance(v, str)]

    def focused_ids(self, step: Step) -> List[str]:
        """The pane and tab a key acts on, from the before state: the targeted window's focused pane and its
        selected tab, and the topology focus when the key targets the focused window or no window. Their
        containers (screen, workspace, window) come into `may` as their ancestors."""
        prior = self.before_state(step)
        tree = ((facet(prior.snapshot, "topology") or {}).get("topology") or {}) if prior else {}
        windows = {w.get("id"): w for w in tree.get("windows") or [] if isinstance(w, Mapping)}
        focus = tree.get("focus") or {}
        targeted = [v for k, v in step.target.items() if k == "window" and v in windows]
        out: List[Any] = []
        if not targeted or focus.get("window") in targeted:
            out += [focus.get("pane"), focus.get("tab")]
            targeted = targeted or [focus.get("window")]
        selected = {pane["id"]: pane.get("selected_tab")
                    for ws in tree.get("workspaces") or [] for screen in ws.get("screens") or []
                    for pane in screen.get("panes") or []}
        for window in (windows[w] for w in targeted if w in windows):
            out += [window.get("focused_pane"), selected.get(window.get("focused_pane"))]
        return [v for v in out if isinstance(v, str)]

    def owner(self, index: int) -> Step:
        """The step that changes the state from checkpoint index-1 to index: changes up to a before
        checkpoint are the previous step's late effects."""
        state = self.states[index]
        return self.states[index - 1].step if state.checkpoint == "before" and index > 0 else state.step

    def i2(self) -> None:
        """Each source is compared with the last earlier state that has it, so a checkpoint without the
        daemon facet (a turn holds only the armed facets) never breaks the daemon's id chain."""
        sources = [id_sources(state.snapshot) for state in self.states]
        last: Dict[str, int] = {}
        for j, current in enumerate(self.states):
            reported: Set[str] = set()
            for source in ("topology", "daemon"):
                if source not in sources[j]:
                    continue
                i, last[source] = last.get(source), j
                if i is None:
                    continue
                self.checked("I2")
                previous = self.states[i]
                owners: List[Step] = []
                for k in range(i + 1, j + 1):
                    if all(o.index != self.owner(k).index for o in owners):
                        owners.append(self.owner(k))
                mutating = [o for o in owners if o.mutating]
                if j - i > 1 and len(owners) > 1 and mutating:
                    self.skip("I2", current.step,
                              f"the {source} facet is missing between {previous.step.id}/{previous.checkpoint} and "
                              f"{current.step.id}/{current.checkpoint}: its id changes are checked against steps "
                              f"{', '.join(o.id for o in owners)} together, not each one")
                graph = parent_graph([*sources[i].values(), *sources[j].values()])
                roots: Set[str] = set()
                may: Set[str] = set()
                # The direct containers of explicit targets: "close other tabs" closes a target's siblings.
                beside: Set[str] = set()
                for step in mutating:
                    roots |= self.roots(step, set(graph))
                    may |= set(self.target_ids(step))
                    for target in self.acted_targets(step):
                        beside |= graph.get(target, set())
                may |= roots
                for root in roots:
                    may |= ancestors(graph, root)
                by = " or ".join(f"step {o.id} ({o.op})" for o in owners)
                a, b = sources[i][source], sources[j][source]
                for key in sorted(set(a) - set(b)):
                    node = a[key]
                    if node.parent in a and node.parent not in b:
                        continue  # closed with its container
                    # The step closed it: a target or a container of one, a child of a target (close a pane's
                    # tabs) or a sibling of an explicit target (close other tabs).
                    if key in may or roots & ancestors(graph, key) or graph.get(key, set()) & beside or key in reported:
                        continue
                    reported.add(key)
                    self.violate("I2", current.step, current.checkpoint, node.pointer,
                                 f"{node.kind} {key} disappeared, but {by} did not close it "
                                 f"(it was at {node.pointer} in {previous.step.id}/{previous.checkpoint})")
                for key in sorted(set(b) - set(a)):
                    node = b[key]
                    if node.parent in b and node.parent not in a:
                        continue  # created with its container
                    if key in may or graph.get(key, set()) & may or key in reported:
                        continue
                    reported.add(key)
                    self.violate("I2", current.step, current.checkpoint, node.pointer,
                                 f"{node.kind} {key} appeared, but {by} did not create it")

    # I3 -----------------------------------------------------------------------------------------------
    def projection(self, snapshot: Mapping[str, Any], names: Iterable[str]) -> Dict[str, Any]:
        return {name: self.projector.facet(name, facet(snapshot, name)) for name in names}

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
            refusal, named = self.refusal(step, prior.snapshot if prior else None, turn, settled)
            reverted = prior is not None and first_difference(
                self.projection(prior.snapshot, names), self.projection(settled, names)) is None
            if reverted and refusal == "own":
                continue
            if reverted and refusal == "unknown":
                self.skip("I3", step, f"settled equals before after a refusal ({named}), but the key step names "
                                      "no action id to match it to")
                continue
            at, turn_value, settled_value = found
            if refusal == "own":
                why = f"this step's refusal ({named}) was counted but settled is not the before state"
            elif reverted and refusal == "foreign":
                why = (f"settled equals before, but the counted refusal ({named}) names neither this step's "
                       "action nor an intent pending at its turn")
            elif reverted:
                why = "settled equals before but no refusal or rollback was counted"
            elif prior is None:
                why = "no before checkpoint to check a refusal against"
            else:
                why = "settled is neither the turn projection nor the before state"
            self.violate("I3", step, "settled", at,
                         f"turn {json.dumps(turn_value)[:120]} vs settled {json.dumps(settled_value)[:120]}: {why}")

    @staticmethod
    def refusal(step: Step, before: Optional[Mapping[str, Any]], turn: Mapping[str, Any],
                settled: Mapping[str, Any]) -> Tuple[str, str]:
        """("none" | "own" | "foreign" | "unknown", the lastRefusal it read). A refused or rolledBack delta
        is this step's only when the raw settled lastRefusal names it: a refused perform turn by the step's
        action id, a rollback by the case name of an intent that its turn added to the pending log."""
        a, b = facet(before, "intents"), facet(settled, "intents")
        if a is None or b is None:
            return "none", ""
        ta, tb = a.get("totals") or {}, b.get("totals") or {}
        refused, rolled_back = (int(tb.get(k, 0)) > int(ta.get(k, 0)) for k in ("refused", "rolledBack"))
        if not (refused or rolled_back):
            return "none", ""
        last = b.get("lastRefusal") or {}
        named = f"lastRefusal action {last.get('action')}, intent {last.get('intent')}"
        if refused and step.action_id is not None and last.get("action") == step.action_id:
            return "own", named
        if rolled_back and last.get("intent") is not None:
            earlier = {p.get("intent") for p in a.get("pending") or []}
            added = {p.get("op") for p in (facet(turn, "intents") or {}).get("pending") or []
                     if p.get("intent") not in earlier}
            if last["intent"] in added:
                return "own", named
        if refused and step.action_id is None and step.op in KEY_OPS:
            return "unknown", named
        return "foreign", named

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
            chain = [value, *ancestors(parent_graph([nodes]), value)]
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

    # I9 -----------------------------------------------------------------------------------------------
    def i9(self) -> None:
        replied = False
        for state in self.states:
            reply = (state.step.record.get("restorePreviews") or {}).get(state.checkpoint)
            if reply is None:
                continue
            replied = True
            daemon = facet(state.snapshot, "daemon")
            head = (daemon or {}).get("journalHead")
            preview = reply.get("preview") if isinstance(reply, Mapping) else None
            if not isinstance(head, int):
                self.skip("I9", state.step, f"the {state.checkpoint} checkpoint's daemon facet has no journalHead")
                continue
            if not isinstance(preview, Mapping):
                self.skip("I9", state.step, f"no journal checkpoint at {state.checkpoint}: nothing to restore from")
                continue
            if preview.get("headSequence") != head:
                self.skip("I9", state.step, f"the preview reduced through {preview.get('headSequence')}, the "
                                            f"{state.checkpoint} daemon facet is at {head}: not one cut")
                continue
            self.checked("I9")
            if preview.get("unsupportedCount"):
                self.violate("I9", state.step, state.checkpoint, "/daemon/journalHead",
                             f"{preview['unsupportedCount']} required journal record(s) the restore cannot apply: "
                             f"{json.dumps(preview.get('unsupported'))[:200]}")
            dropped = preview.get("stateChangesNotReduced")
            if dropped:
                self.violate("I9", state.step, state.checkpoint, pointer("daemon", "session", "extra"),
                             f"{dropped} state_upsert/state_delete change(s) the restore does not reduce: it keeps "
                             f"the checkpoint's extra.state")
            restored = preview.get("session") or {}
            live = daemon.get("session") or {}
            for name in compared_sections(reply.get("sections") or {}, live):
                if name == "extra" and dropped:
                    continue
                if name not in restored:
                    self.violate("I9", state.step, state.checkpoint, pointer("daemon", "session", name),
                                 f"{name} is a restorable section the preview lacks")
                    continue
                a, b = self.projector.restore_section(name, live.get(name), restored[name])
                for at, message in section_differences(name, a, b):
                    self.violate("I9", state.step, state.checkpoint, at, message)
        if not replied:
            self.skip("I9", None, "no checkpoint has an oracle-restore-preview reply")

    # I10 ----------------------------------------------------------------------------------------------
    @staticmethod
    def request(step: Step) -> Tuple[Any, ...]:
        args = step.record.get("args") or {}
        return args.get("method"), args.get("params") or {}, dict(step.target)

    def retries(self) -> Iterator[Tuple[Step, Step]]:
        """(first call, retry) for each mutating resource.call that repeats an earlier step's key and request."""
        first: Dict[str, Step] = {}
        for step in self.trace.steps:
            key = (step.record.get("args") or {}).get("idempotencyKey")
            if step.op != "resource.call" or not step.mutating or not isinstance(key, str):
                continue
            original = first.setdefault(key, step)
            if original is not step and self.request(original) == self.request(step):
                yield original, step

    def i10(self) -> None:
        for original, retry in self.retries():
            replies, again = original.record.get("replies"), retry.record.get("replies")
            if not (isinstance(replies, list) and replies and isinstance(again, list) and again):
                self.skip("I10", retry, f"the trace has no reply for {original.id} or its retry (I1 holds that)")
                continue
            if not (isinstance(replies[0], Mapping) and "receipt" in replies[0]):
                self.skip("I10", retry, f"{original.id} was refused ({replies[0]!r:.80}): no effect to replay")
                continue
            self.checked("I10")
            found = first_difference(without_replay_flag(replies[0]), without_replay_flag(again[0]), "/replies/0")
            if found is not None:
                at, was, now = found
                self.violate("I10", retry, None, at, f"retry of {original.id} with its key replied "
                             f"{json.dumps(now)[:120]}, the first call {json.dumps(was)[:120]}", "step")
            self.replay_flags(original, retry, replies[0], again[0])
            before, after = self.before_state(retry), self.after_state(retry)
            if before is None or after is None:
                self.skip("I10", retry, "the retry has no settled checkpoint or no checkpoint before it")
                continue
            heads = [(facet(state.snapshot, "daemon") or {}).get("journalHead") for state in (before, after)]
            if not all(isinstance(head, int) for head in heads):
                self.skip("I10", retry, "no daemon journalHead at both the retry's before and settled checkpoints")
            elif heads[0] != heads[1]:
                self.violate("I10", retry, after.checkpoint, pointer("daemon", "journalHead"),
                             f"journal head {heads[0]} -> {heads[1]}: the retry of {original.id} added "
                             f"{heads[1] - heads[0]} record(s)")
            names = sorted(n for n in (after.snapshot.get("facets") or {})
                           if n not in BOOKKEEPING_FACETS and facet(before.snapshot, n) is not None
                           and facet(after.snapshot, n) is not None)
            if not names:
                self.skip("I10", retry, "the retry's before and settled checkpoints share no model facet")
                continue
            found = first_difference(self.projection(before.snapshot, names), self.projection(after.snapshot, names))
            if found is not None:
                at, was, now = found
                self.violate("I10", retry, after.checkpoint, at, f"{json.dumps(was)[:120]} -> {json.dumps(now)[:120]}: "
                             f"the retry of {original.id} changed the state")

    def replay_flags(self, original: Step, retry: Step, first: Mapping[str, Any], again: Any) -> None:
        """I10's direct signal: `replayed` false on the first call, true on its same-key retry."""
        result = first.get("result")
        if "result" not in first:
            self.skip("I10", retry, f"the replies of {original.id} carry no result: only the receipt kind is compared")
            return
        if not (isinstance(result, Mapping) and REPLAY_FLAG in result):
            self.skip("I10", retry, f"the result of {original.id} has no `{REPLAY_FLAG}` flag: not a MutationResult")
            return
        at = f"/replies/0/result/{REPLAY_FLAG}"
        if result[REPLAY_FLAG] is not False:
            self.violate("I10", original, None, at, f"the first call with its key replied {REPLAY_FLAG} "
                         f"{json.dumps(result[REPLAY_FLAG])}, not false", "step")
        retried = again.get("result") if isinstance(again, Mapping) else None
        flag = retried.get(REPLAY_FLAG) if isinstance(retried, Mapping) else None
        if flag is not True:
            self.violate("I10", retry, None, at, f"the retry of {original.id} replied {REPLAY_FLAG} "
                         f"{json.dumps(flag)}, not true: the daemon ran the call again instead of replaying its "
                         "receipt", "step")

    # I17 ----------------------------------------------------------------------------------------------
    def exit_step(self, state: State) -> Optional[Step]:
        """The step during which an exit first seen at `state` happened (None: before the first step)."""
        if state.checkpoint != "before":
            return state.step
        return self.trace.steps[state.step.index - 1] if state.step.index > 0 else None

    def exit_span(self, previous: State, skipped: List[State], state: Optional[State]) -> List[Optional[Step]]:
        """Every step an exit between the reading at `previous` and the one at `state` (None: the teardown)
        could have happened in, in case order: the step each skipped checkpoint and the reading names, and
        the steps between with no checkpoint at all. The teardown is a None at the end. A reading follows
        the first one, which is at or before its own step, so only the teardown gives None."""
        last = state.step.index if state is not None else len(self.trace.steps)
        steps = [self.exit_step(s) for s in skipped] + self.trace.steps[previous.step.index + 1:last]
        if state is not None:
            steps.append(self.exit_step(state))
        by_index = {step.index: step for step in steps if step is not None}
        span: List[Optional[Step]] = [by_index[i] for i in sorted(by_index)]
        return span if state is not None else [*span, None]

    @staticmethod
    def span_text(span: List[Optional[Step]]) -> str:
        names = ["the teardown" if s is None else f"step {s.id}" for s in span]
        return names[0] if len(names) == 1 else f"one of {', '.join(names)}"

    def i17(self) -> None:
        states = self.states
        readings = [(i, value) for i, state in enumerate(states) if (value := facet(state.snapshot, "crashes")) is not None]
        if not readings:
            self.skip("I17", None, "no checkpoint has the crashes facet")
            return
        first, previous = readings[0]
        if states[first].step.index != 0 or states[first].checkpoint != "before":
            unchecked = self.trace.steps[:states[first].step.index + 1]
            self.skip("I17", states[first].step,
                      f"no crashes reading before {unchecked[0].id}: exits up to {states[first].checkpoint} of "
                      f"{states[first].step.id} are not checked")
        allowances = [{"kind": e["kind"], "steps": set(e["steps"]) if e.get("steps") else None,
                       "left": int(e.get("max", 1))} for e in self.trace.allow_crashes]
        self.checked("I17")
        teardown = facet((self.trace.teardown or {}).get("checkpoint"), "crashes")
        later: List[Tuple[Optional[int], Mapping[str, Any]]] = list(readings[1:])
        if teardown is not None:
            later.append((None, teardown))  # an exit during the teardown: only a whole-case entry covers it
        last = first
        for index, value in later:
            state = states[index] if index is not None else None
            skipped = states[last + 1:index if index is not None else len(states)]
            span = self.exit_span(states[last], skipped, state)
            step = span[-1]
            checkpoint = state.checkpoint if state is not None else "teardown"
            exits = value.get("exits") or []
            seen = len(previous.get("exits") or [])
            counts, before = value.get("counts") or {}, previous.get("counts") or {}
            for kind in CRASH_KINDS:
                now, then = int(counts.get(kind, 0)), int(before.get(kind, 0))
                rise = now if now < then else now - then
                listed = [i for i in range(seen, len(exits)) if exits[i].get("kind") == kind]
                for n in range(rise):
                    if self.allow(allowances, kind, span):
                        continue
                    named = listed[n] if n < len(listed) else None
                    at = pointer("crashes", "counts", kind) if named is None else pointer("crashes", "exits", named)
                    reason = "" if named is None else f" ({exits[named].get('reason')})"
                    during = self.span_text(span)
                    self.violate("I17", step, checkpoint, at,
                                 f"{kind} exit{reason} during {during} that no allow_crashes entry covers")
            previous = value
            if index is not None:
                last = index

    @staticmethod
    def allow(allowances: List[Dict[str, Any]], kind: str, span: List[Optional[Step]]) -> bool:
        """Takes one exit of `kind` from the first entry that covers a step of `span` and has some left."""
        ids = {step.id for step in span if step is not None}
        for entry in allowances:
            covers = entry["steps"] is None or bool(ids & entry["steps"])
            if entry["kind"] == kind and covers and entry["left"] > 0:
                entry["left"] -= 1
                return True
        return False

    # I18 ----------------------------------------------------------------------------------------------
    @staticmethod
    def live_counts(snapshot: Optional[Mapping[str, Any]]) -> Dict[Tuple[str, ...], Mapping[str, Any]]:
        """The snapshot's live-object count maps by their facet-rooted path."""
        out: Dict[Tuple[str, ...], Mapping[str, Any]] = {}
        app = facet(snapshot, "liveObjects")
        if app is not None:
            out[("liveObjects",)] = app
        daemon = facet(snapshot, "daemon")
        extras = (daemon or {}).get("oracle")
        if isinstance(extras, Mapping) and isinstance(extras.get("liveObjects"), Mapping):
            out[("daemon", "oracle", "liveObjects")] = extras["liveObjects"]
        return out

    def i18(self) -> None:
        end = (self.trace.teardown or {}).get("checkpoint")
        if end is None:
            self.skip("I18", None, "the trace has no teardown checkpoint")
            return
        after = self.live_counts(end)
        baselines: Dict[Tuple[str, ...], Mapping[str, Any]] = {}
        for state in self.states:
            for path, counts in self.live_counts(state.snapshot).items():
                baselines.setdefault(path, counts)
        paths = [path for path in after if path in baselines]
        if not paths:
            self.skip("I18", None, "no live-object counts at both the fixture baseline and the teardown")
            return
        self.checked("I18")
        for path in paths:
            for kind in sorted(set(baselines[path]) | set(after[path])):
                base, now = baselines[path].get(kind), after[path].get(kind)
                if base == now:
                    continue
                what = (f"{now - base} more" if now > base else f"{base - now} fewer") \
                    if isinstance(base, int) and isinstance(now, int) else "a different count"
                message = f"{kind}: {now} after teardown, {base} at the fixture baseline ({what})"
                if kind in TIMING_LIVE_KINDS:
                    self.skip("I18", None, f"{pointer(*path, kind)} is timing state, not compared: {message}")
                    continue
                self.violate("I18", None, "teardown", pointer(*path, kind), message)

    def run(self) -> Report:
        for check in (self.i1, self.i2, self.i3, self.i4, self.i5, self.i6, self.i7, self.i9, self.i10, self.i17,
                      self.i18):
            check()
        return self.report


def compared_sections(sections: Mapping[str, Any], live: Mapping[str, Any]) -> List[str]:
    """The `session.snapshot` sections I9 compares: every section of the live session and of the daemon's
    section map that the map does not exclude with a reason. An exclusion without a reason is compared."""
    out = []
    for name in sorted(set(live) | set(sections)):
        entry = sections.get(name)
        excluded = isinstance(entry, Mapping) and entry.get("restore") == "excluded" \
            and isinstance(entry.get("reason"), str) and entry["reason"].strip()
        if not excluded:
            out.append(name)
    return out


def section_differences(name: str, live: Any, restored: Any) -> List[Tuple[str, str]]:
    """Where a restored section differs from the live one. A list of objects with ids compares by id: the
    restore reducer orders a collection by `index` then id, the live snapshot by topology, and each item's
    `index` and parent ids already hold its place."""
    at = ("daemon", "session", name)
    live_rows = rows_by_id(live)
    restored_rows = rows_by_id(restored)
    if live_rows is None or restored_rows is None:
        found = first_difference(live, restored)
        if found is None:
            return []
        where, a, b = found
        return [(pointer(*at) + where, f"live {json.dumps(a)[:120]}, restored {json.dumps(b)[:120]}")]
    out = []
    for key in sorted(set(live_rows) | set(restored_rows)):
        if key not in restored_rows:
            out.append((pointer(*at, live_rows[key][0]), f"{key} is live but the restore lacks it"))
        elif key not in live_rows:
            out.append((pointer(*at), f"the restore has {key}, which is not live"))
        else:
            found = first_difference(live_rows[key][1], restored_rows[key][1])
            if found is not None:
                where, a, b = found
                out.append((pointer(*at, live_rows[key][0]) + where,
                            f"{key}: live {json.dumps(a)[:120]}, restored {json.dumps(b)[:120]}"))
    return out


def rows_by_id(value: Any) -> Optional[Dict[str, Tuple[int, Any]]]:
    """{id: (index in the list, row)} of a list of objects with string ids, else None."""
    if not isinstance(value, list):
        return None
    out: Dict[str, Tuple[int, Any]] = {}
    for i, row in enumerate(value):
        if not isinstance(row, Mapping) or not isinstance(row.get("id"), str) or row["id"] in out:
            return None
        out[row["id"]] = (i, row)
    return out


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
    """I1-I7, I9, I10 and I17-I18 over one cmux.oracle.trace/v1 document. Raises TraceError on a malformed trace."""
    trace = load_trace(document, case)
    return Checker(trace, Projector(schema if schema is not None else load_schema())).run()


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
WIN = "win_000000000000000000000000000000a1"
PANE3 = "pane_000000000000000000000000000000d3"
TAB3 = "tab_000000000000000000000000000000e3"
TERM3 = "term_000000000000000000000000000000f3"
REOPEN_ARGS = {"method": "closed.reopen", "params": {}, "idempotencyKey": "selftest.reopen"}


def _add_tab(snapshot: Dict[str, Any], pane_id: str, tab_id: str, terminal: str) -> Dict[str, Any]:
    """The snapshot plus a terminal tab at the end of pane `pane_id`, in both facets."""
    snap = copy.deepcopy(snapshot)
    tree = snap["facets"]["topology"]["topology"]
    template = tree["workspaces"][0]["screens"][0]["panes"][0]["tabs"][0]
    for screen in tree["workspaces"][0]["screens"]:
        for pane in screen["panes"]:
            if pane["id"] == pane_id:
                pane["tabs"].append({**copy.deepcopy(template), "id": tab_id, "surface": tab_id, "terminal": terminal})
    session = snap["facets"]["daemon"]["session"]
    index = sum(1 for t in session["tabs"] if t["pane_id"] == pane_id)
    session["tabs"].append({**copy.deepcopy(session["tabs"][0]), "id": tab_id, "pane_id": pane_id, "index": index,
                            "focused": False, "content_id": terminal})
    session["terminals"].append({**copy.deepcopy(session["terminals"][0]), "id": terminal, "tab_id": tab_id,
                                 "tab_ids": [tab_id]})
    return snap


def _add_pane(snapshot: Dict[str, Any], pane_id: str, tab_id: str, terminal: str) -> Dict[str, Any]:
    """The snapshot after a split of screen c1: a new pane with one terminal tab, in both facets."""
    snap = copy.deepcopy(snapshot)
    screen = snap["facets"]["topology"]["topology"]["workspaces"][0]["screens"][0]
    screen["panes"].append({**copy.deepcopy(screen["panes"][0]), "id": pane_id, "selected_tab": tab_id, "tabs": []})
    session = snap["facets"]["daemon"]["session"]
    session["panes"].append({**session["panes"][0], "id": pane_id, "focused": False})
    return _add_tab(snap, pane_id, tab_id, terminal)


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


# The daemon's I9 section map (oracle_state.rs RESTORE_SECTIONS).
RESTORE_SECTIONS = {
    **{name: {"restore": "compared"} for name in (
        "session", "workspaces", "screens", "panes", "tabs", "terminals", "browsers", "notifications", "agents",
        "frontend_projections", "sidebar_views", "cursor", "extra")},
    "machine": {"restore": "excluded", "reason": "the host the daemon runs on, not session state"},
    "clients": {"restore": "excluded", "reason": "the connections of this daemon process"},
}


def _restorable(schema: Mapping[str, Any], snapshot: Dict[str, Any]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    """(snapshot, raw session): the example's daemon session as raw wire, with plain text where the facet
    holds a capture hash, and the snapshot whose daemon facet is that wire captured."""
    snap = copy.deepcopy(snapshot)
    raw = copy.deepcopy(snap["facets"]["daemon"]["session"])
    for row in raw.get("terminals") or []:
        if row.get("title") is not None:
            row["title"] = f"title of {row['id']}"
    for row in raw.get("notifications") or []:
        for key in ("title", "subtitle", "body"):
            if row.get(key) is not None:
                row[key] = f"{key} of {row['id']}"
    node = schema["properties"]["facets"]["properties"]["daemon"]["oneOf"][0]["properties"]["session"]
    snap["facets"]["daemon"]["session"] = capture(schema, node, raw)
    return snap, raw


def _restore_reply(raw: Mapping[str, Any], head: int, unsupported: Sequence[Any] = (),
                   sections: Optional[Mapping[str, Any]] = None, state_changes: int = 0) -> Dict[str, Any]:
    """An oracle-restore-preview reply that restores `raw` through `head`."""
    sections = RESTORE_SECTIONS if sections is None else sections
    restored = {name: copy.deepcopy(value) for name, value in raw.items()
                if (sections.get(name) or {}).get("restore") != "excluded"}
    return {"sections": copy.deepcopy(sections),
            "preview": {"checkpointId": "checkpoint_1", "checkpointSequence": 1, "headSequence": head,
                        "unsupportedCount": len(unsupported), "unsupported": list(unsupported),
                        "stateChangesNotReduced": state_changes, "session": restored}}


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

    @staticmethod
    def core(report: Report) -> List[NotChecked]:
        """The notChecked entries of I1-I7: their tests' traces carry no crashes facet or teardown checkpoint."""
        return [n for n in report.not_checked if BY_ID[n.invariant].task == "p15-oracle-110"]

    def test_every_invariant_has_an_id_a_rule_and_a_pointer(self) -> None:
        self.assertEqual([inv.id for inv in INVARIANTS], [*(f"I{n}" for n in range(1, 8)), "I9", "I10", "I17", "I18"])
        for inv in INVARIANTS:
            self.assertTrue(inv.rule and inv.pointer.split(":")[0] in {"step", "snapshot", "teardown"}, inv)

    def test_a_clean_trace_has_no_violation_and_checks_every_invariant(self) -> None:
        closed = _bump_sequences(_close_tab2(self.base), 1)
        restorable, raw = _restorable(self.schema, closed)
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
             "checkpoints": {"settled": restorable},
             "restorePreviews": {"settled": _restore_reply(raw, restorable["facets"]["daemon"]["journalHead"])}},
            {"id": "reopen", "op": "resource.call", "target": {"pane": PANE1}, "args": REOPEN_ARGS,
             "replies": [{"receipt": "mutation_result", "result": {"value": {"tab_id": TAB2}, "replayed": False}}],
             "checkpoints": {"settled": _bump_sequences(self.base, 1)}},
            {"id": "reopen-retry", "op": "resource.call", "target": {"pane": PANE1}, "args": REOPEN_ARGS,
             "replies": [{"receipt": "mutation_result", "result": {"value": {"tab_id": TAB2}, "replayed": True}}],
             "checkpoints": {"before": _bump_sequences(self.base, 1), "settled": _bump_sequences(self.base, 1)}},
            {"id": "new-hidden", "op": "resource.call", "target": {"session": "session_00000000000000000000000000000002"},
             "replies": [{"receipt": "mutation_result", "result": {"workspace": HIDDEN_WS}}],
             "checkpoints": {"settled": hidden_before}},
            {"id": "rename-hidden", "op": "resource.call", "target": {"workspace": HIDDEN_WS},
             "replies": [{"receipt": "mutation_result"}],
             "checkpoints": {"before": hidden_before, "settled": renamed},
             "layoutCounters": {"before": {"pane_snapshots": 4, "indicator_resyncs": 1},
                                "after": {"pane_snapshots": 4, "indicator_resyncs": 2}}},
        )
        doc["teardown"]["checkpoint"] = self.base
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

    def test_i1_ignores_reads_and_settles_and_allows_no_receipt_with_a_reason(self) -> None:
        steps = [
            {"id": "read", "op": "resource.call", "readOnly": True},
            {"id": "settle", "op": "settle"},
            {"id": "kill-daemon", "op": "kill", "target": {"process": "daemon"}, "replies": [],
             "expect": {"outcome": "ok", "noReceiptReason": "a killed process answers nothing"}},
            {"id": "quiet", "op": "action.run", "target": {"tab": TAB1}, "replies": [],
             "expect": {"outcome": "ok", "noReceiptReason": "focus moves only in the app"}},
        ]
        report = self.check(_trace(*steps))
        self.assertEqual([v for v in report.violations if v.invariant == "I1"], [])
        self.assertEqual(report.checked["I1"], 2)

    def test_i1_holds_a_restart_to_its_receipt(self) -> None:
        # case-example-daemon.json restart-daemon: expect.receipt identify.
        restart = {"id": "restart-daemon", "op": "restart", "target": {"process": "daemon"},
                   "expect": {"outcome": "ok", "receipt": "identify"}}
        steps = [dict(restart, id="silent", replies=[]),
                 dict(restart, id="twice", replies=[{"receipt": "identify"}, {"receipt": "identify"}]),
                 dict(restart, id="wrong", replies=[{"receipt": "mutation_result"}]),
                 dict(restart, id="ok", replies=[{"receipt": "identify"}])]
        report = self.check(_trace(*steps))
        self.assertEqual([(v.step, v.pointer) for v in report.violations if v.invariant == "I1"],
                         [("silent", "/replies"), ("twice", "/replies/1"), ("wrong", "/replies/0")])

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

    def i2(self, report: Report) -> List[Tuple[Optional[str], str]]:
        return [(v.step, v.pointer) for v in report.violations if v.invariant == "I2"]

    def test_i2_a_key_acts_on_the_focus_of_its_target_window_and_a_read_changes_nothing(self) -> None:
        # case-example-app.json split-key: op key, target {window: main}, keys [cmd+d]; case-v1 requires the target.
        key = {"op": "key", "target": {"window": WIN}, "replies": [{"receipt": "action.done"}]}
        split = _add_pane(self.base, PANE3, TAB3, TERM3)
        report = self.check(_trace(dict(key, id="split-key", args={"keys": ["cmd+d"]},
                                        checkpoints={"before": self.base, "settled": split})))
        self.assertEqual(self.i2(report), [])
        new_tab = _add_tab(self.base, PANE1, TAB3, TERM3)
        report = self.check(_trace(dict(key, id="new-tab", args={"keys": ["cmd+t"]},
                                        checkpoints={"before": self.base, "settled": new_tab})))
        self.assertEqual(self.i2(report), [])
        closed = _close_tab2(self.base)
        focused = copy.deepcopy(self.base)
        focused["facets"]["topology"]["topology"]["focus"].update(pane=PANE2, tab=TAB2)
        focused["facets"]["topology"]["topology"]["windows"][0]["focused_pane"] = PANE2
        close = dict(key, id="close-key", args={"keys": ["cmd+w"]})
        report = self.check(_trace(dict(close, checkpoints={"before": focused, "settled": closed})))
        self.assertEqual(self.i2(report), [])
        # The same cmd+w with the focus on d1 closed the tab of another pane.
        report = self.check(_trace(dict(close, checkpoints={"before": self.base, "settled": closed})))
        self.assertEqual(self.i2(report), [("close-key", "/topology/topology/workspaces/0/screens/0/panes/1")])
        read = self.check(_trace({"id": "r", "op": "resource.call", "readOnly": True, "target": {"tab": TAB2},
                                  "checkpoints": {"before": self.base, "settled": closed}}))
        self.assertEqual([v.invariant for v in read.violations], ["I2"])

    def test_i2_a_step_closes_its_targets_children_and_siblings_but_not_a_cousin(self) -> None:
        three = _add_tab(self.base, PANE1, TAB3, TERM3)
        for name, target in (("close-pane-tabs", {"pane": PANE1}), ("close-other-tabs", {"tab": TAB1})):
            report = self.check(_trace({"id": name, "op": "action.run", "target": target,
                                        "replies": [{"receipt": "action.done"}],
                                        "checkpoints": {"before": three, "settled": self.base}}))
            self.assertEqual(self.i2(report), [], name)
        cousin = _add_tab(self.base, PANE2, TAB3, TERM3)
        report = self.check(_trace({"id": "close-other-tabs", "op": "action.run", "target": {"tab": TAB1},
                                    "replies": [{"receipt": "action.done"}],
                                    "checkpoints": {"before": cousin, "settled": self.base}}))
        self.assertEqual(self.i2(report), [("close-other-tabs", "/topology/topology/workspaces/0/screens/0/panes/1/tabs/1")])

    def test_i2_a_window_target_covers_a_new_workspace_in_both_facets(self) -> None:
        report = self.check(_trace({"id": "new-workspace", "op": "action.run", "target": {"window": WIN},
                                    "args": {"action": "newWorkspace"}, "replies": [{"receipt": "action.done"}],
                                    "checkpoints": {"before": self.base, "settled": _with_hidden_workspace(self.base)}}))
        self.assertEqual(self.i2(report), [])

    def test_i2_a_turn_without_the_daemon_facet_keeps_the_daemon_id_chain(self) -> None:
        replaced = copy.deepcopy(self.base)
        session = replaced["facets"]["daemon"]["session"]
        session["browsers"][0]["id"] = session["tabs"][1]["content_id"] = "browser_000000000000000000000000000000ff"
        turn = copy.deepcopy(self.base)
        turn["facets"] = {k: turn["facets"][k] for k in ("topology", "intents")}
        turn["meta"]["facets"] = ["topology", "intents"]
        report = self.check(_trace({"id": "focus", "op": "action.run", "target": {"tab": TAB1},
                                    "replies": [{"receipt": "action.applied"}],
                                    "checkpoints": {"before": self.base, "turn": turn, "settled": replaced}}))
        self.assertEqual(self.i2(report), [("focus", "/daemon/session/browsers/0")] * 2)
        self.assertEqual([n for n in report.not_checked if n.invariant == "I2"], [])
        app_only = copy.deepcopy(self.base)
        del app_only["facets"]["daemon"]
        app_only["meta"]["facets"] = [f for f in app_only["meta"]["facets"] if f != "daemon"]
        report = self.check(_trace({"id": "a", "op": "settle", "checkpoints": {"settled": self.base}},
                                   {"id": "b", "op": "action.run", "target": {"tab": TAB1},
                                    "replies": [{"receipt": "action.done"}], "checkpoints": {"settled": app_only}},
                                   {"id": "c", "op": "settle", "checkpoints": {"settled": replaced}}))
        self.assertEqual(self.i2(report), [("c", "/daemon/session/browsers/0")] * 2)
        self.assertEqual([n.step for n in report.not_checked if n.invariant == "I2"], ["c"])

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

    def test_i3_a_rolled_back_turn_passes_only_with_its_own_counted_refusal(self) -> None:
        turn = copy.deepcopy(self.base)
        turn["facets"]["topology"]["topology"]["focus"]["pane"] = PANE2
        turn["facets"]["intents"]["pending"] = [{"intent": "intent_7", "op": "focusPane", "target": PANE2}]
        settled = copy.deepcopy(self.base)
        settled["facets"]["intents"]["totals"]["rolledBack"] += 1
        settled["facets"]["intents"]["lastRefusal"]["intent"] = "focusPane"
        step = {"id": "focus", "op": "action.run", "target": {"pane": PANE2}, "args": {"action": "pane.focus"},
                "replies": [{"error": "intent.rolled_back"}],
                "checkpoints": {"before": self.base, "turn": turn, "settled": settled}}
        self.assertEqual(self.check(_trace(step)).violations, [])
        half = copy.deepcopy(settled)
        half["facets"]["layout"] = {"status": "not-comparable", "reason": "x"}
        half["facets"]["topology"]["topology"]["focus"]["tab"] = TAB2
        report = self.check(_trace(dict(step, checkpoints={**step["checkpoints"], "settled": half})))
        self.assertEqual([v.invariant for v in report.violations], ["I3"])
        self.assertIn("not the before state", report.violations[0].message)
        # A scripted rename of a background workspace was rolled back in the same step: not this step's refusal.
        other = copy.deepcopy(settled)
        other["facets"]["intents"]["lastRefusal"]["intent"] = "renameWorkspace"
        report = self.check(_trace(dict(step, checkpoints={**step["checkpoints"], "settled": other})))
        self.assertEqual(self.ids(report), [("I3", "/topology/topology/focus/pane")])
        self.assertIn("names neither", report.violations[0].message)

    def test_i3_a_refused_turn_is_matched_by_its_action_id(self) -> None:
        turn = copy.deepcopy(self.base)
        turn["facets"]["topology"]["topology"]["focus"]["pane"] = PANE2
        settled = copy.deepcopy(self.base)
        settled["facets"]["intents"]["totals"]["refused"] += 1
        settled["facets"]["intents"]["lastRefusal"]["action"] = "pane.focus"
        step = {"id": "focus", "op": "action.run", "target": {"pane": PANE2}, "args": {"action": "pane.focus"},
                "replies": [{"error": "action.refused"}],
                "checkpoints": {"before": self.base, "turn": turn, "settled": settled}}
        self.assertEqual(self.check(_trace(step)).violations, [])
        report = self.check(_trace(dict(step, args={"action": "workspace.rename"})))
        self.assertEqual(self.ids(report), [("I3", "/topology/topology/focus/pane")])
        key = dict(step, op="key", target={"window": WIN}, args={"keys": ["cmd+opt+right"]})
        report = self.check(_trace(key))
        self.assertEqual(report.violations, [])
        self.assertEqual([n.invariant for n in self.core(report)], ["I3"])
        self.assertEqual(self.check(_trace(dict(key, action="pane.focus"))).violations, [])

    def test_i3_set_order_and_float_jitter_do_not_count(self) -> None:
        turn = copy.deepcopy(self.base)
        turn["facets"]["layout"]["screens"].reverse()
        turn["facets"]["layout"]["screens"][-1]["root"]["ratios"] = [0.49999999, 0.50000001]
        turn["facets"]["daemon"]["session"]["panes"].reverse()
        self.assertIsNotNone(first_difference(turn["facets"]["layout"], self.base["facets"]["layout"]))
        step = {"id": "focus", "op": "action.run", "target": {"pane": PANE1}, "replies": [{"receipt": "action.applied"}],
                "checkpoints": {"before": self.base, "turn": turn, "settled": self.base}}
        report = self.check(_trace(step))
        self.assertEqual([v for v in report.violations if v.invariant == "I3"], [])
        self.assertEqual(report.checked["I3"], 1)

    def test_i3_volatile_fields_and_bookkeeping_facets_do_not_count(self) -> None:
        mask = Projector(self.schema)
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
        self.assertEqual([(n.invariant, n.step) for n in self.core(report)], [("I4", "s")])

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
        self.assertEqual([n.invariant for n in self.core(report)], ["I6"])

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
        self.assertEqual([(n.invariant, n.step) for n in self.core(report)], [("I7", "tab-in-hidden")])

    # I10
    @staticmethod
    def created(tab: str, replayed: bool) -> Dict[str, Any]:
        """The reply of tab.create_terminal as the daemon sends it: a receipt and its MutationResult."""
        return {"receipt": "mutation_result",
                "result": {"value": {"tab_id": tab}, "generation": "gen-1", "revision": "7", "replayed": replayed}}

    def retry_trace(self, retry_reply: Dict[str, Any], retry_settled: Dict[str, Any], **change: Any) -> Dict[str, Any]:
        """tab.create_terminal makes TAB3, then its same-key retry, recorded before and settled."""
        args = {"method": "tab.create_terminal", "params": {}, "idempotencyKey": "selftest.call"}
        created = _bump_sequences(_add_tab(self.base, PANE1, TAB3, TERM3), 1)
        call = {"id": "call", "op": "resource.call", "target": {"pane": PANE1}, "args": args,
                "replies": [self.created(TAB3, False)],
                "checkpoints": {"before": self.base, "settled": created}}
        retry = {**call, "id": "retry", "replies": [retry_reply],
                 "checkpoints": {"before": created, "settled": retry_settled}, **change}
        return _trace(call, retry)

    def i10(self, report: Report) -> Tuple[List[Tuple[str, str]], List[str]]:
        return ([(v.invariant, v.pointer) for v in report.violations if v.invariant == "I10"],
                [n.reason for n in report.not_checked if n.invariant == "I10"])

    def test_i10_a_replayed_retry_holds(self) -> None:
        # The daemon's replay: the same value, generation and revision, and replayed false then true.
        doc = self.retry_trace(self.created(TAB3, True), _bump_sequences(_add_tab(self.base, PANE1, TAB3, TERM3), 1))
        report = self.check(doc)
        self.assertEqual(self.i10(report), ([], []))
        self.assertEqual(report.checked["I10"], 1)

    def test_i10_a_double_create_breaks_the_result_the_flag_the_journal_and_the_facets(self) -> None:
        # The double-create mutant: the retry runs the handler again, so a second tab, a new id and a new record,
        # and the daemon says replayed false twice.
        tab4, term4 = "tab_000000000000000000000000000000e4", "term_000000000000000000000000000000f4"
        twice = _bump_sequences(_add_tab(_add_tab(self.base, PANE1, TAB3, TERM3), PANE1, tab4, term4), 2)
        report = self.check(self.retry_trace(self.created(tab4, False), twice))
        violations, _ = self.i10(report)
        self.assertEqual([at for _, at in violations[:3]],
                         ["/replies/0/result/value/tab_id", "/replies/0/result/replayed", "/daemon/journalHead"])
        self.assertEqual(len(violations), 4, violations)
        self.assertTrue(violations[3][1].startswith("/"), violations)
        self.assertEqual({v.step for v in report.violations if v.invariant == "I10"}, {"retry"})
        journal = next(v.message for v in report.violations if v.pointer == "/daemon/journalHead")
        self.assertIn("added 1 record(s)", journal)

    def test_i10_a_retry_that_says_it_ran_again_is_caught_on_the_flag_alone(self) -> None:
        # Same value and no new record, but the daemon did not answer from its receipt.
        doc = self.retry_trace(self.created(TAB3, False), _bump_sequences(_add_tab(self.base, PANE1, TAB3, TERM3), 1))
        report = self.check(doc)
        self.assertEqual(self.i10(report), ([("I10", "/replies/0/result/replayed")], []))
        flag = next(v for v in report.violations if v.invariant == "I10")
        self.assertEqual((flag.step, flag.where), ("retry", "step"))
        self.assertIn("replied replayed false, not true", flag.message)

    def test_i10_a_first_call_that_says_replayed_is_caught_on_that_call(self) -> None:
        doc = self.retry_trace(self.created(TAB3, True), _bump_sequences(_add_tab(self.base, PANE1, TAB3, TERM3), 1))
        doc["steps"][0]["replies"] = [self.created(TAB3, True)]
        report = self.check(doc)
        self.assertEqual(self.i10(report), ([("I10", "/replies/0/result/replayed")], []))
        self.assertEqual(next(v.step for v in report.violations if v.invariant == "I10"), "call")

    def test_i10_skips_a_refused_first_call_and_missing_inputs(self) -> None:
        created = _bump_sequences(_add_tab(self.base, PANE1, TAB3, TERM3), 1)
        doc = self.retry_trace({"error": "validation.invalid"}, created)
        doc["steps"][0]["replies"] = [{"error": "validation.invalid"}]
        self.assertEqual(self.i10(self.check(doc))[0], [])
        self.assertIn("no effect to replay", self.i10(self.check(doc))[1][0])
        bare = self.retry_trace({"receipt": "mutation_result"}, created)
        bare["steps"][0]["replies"] = [{"receipt": "mutation_result"}]
        del bare["steps"][1]["checkpoints"]["settled"]
        self.assertEqual(self.i10(self.check(bare)),
                         ([], ["the replies of call carry no result: only the receipt kind is compared",
                               "the retry has no settled checkpoint or no checkpoint before it"]))
        flagless = self.retry_trace({"receipt": "mutation_result", "result": {"tab": TAB3}}, created)
        flagless["steps"][0]["replies"] = [{"receipt": "mutation_result", "result": {"tab": TAB3}}]
        self.assertEqual(self.i10(self.check(flagless)),
                         ([], ["the result of call has no `replayed` flag: not a MutationResult"]))
        headless = self.retry_trace(self.created(TAB3, True), created)
        for state in (headless["steps"][1]["checkpoints"]["before"], headless["steps"][1]["checkpoints"]["settled"]):
            state["facets"]["daemon"].pop("journalHead")
        self.assertEqual(self.i10(self.check(headless)),
                         ([], ["no daemon journalHead at both the retry's before and settled checkpoints"]))

    def test_i10_another_request_under_the_same_key_is_not_a_retry(self) -> None:
        twice = _bump_sequences(_add_tab(self.base, PANE1, TAB3, TERM3), 2)
        doc = self.retry_trace({"error": "idempotency.conflict"}, twice, target={"pane": PANE2})
        report = self.check(doc)
        self.assertEqual(self.i10(report), ([], []))
        self.assertEqual(report.checked["I10"], 0)

    # I17
    def crash_trace(self, *rises: Tuple[str, str, Optional[Dict[str, int]]], allow: Optional[List[Dict[str, Any]]] = None,
                    exits: Optional[List[Dict[str, Any]]] = None) -> Dict[str, Any]:
        """A settle step per (step id, checkpoint, counts); each later snapshot also lists `exits` seen so far.
        None counts is a not-comparable crashes facet (the daemon reconnecting); "-" a step with no checkpoint."""
        steps = []
        seen: List[Dict[str, Any]] = []
        for step_id, checkpoint, counts in rises:
            if checkpoint == "-":
                steps.append({"id": step_id, "op": "snapshot", "checkpoints": {}})
                continue
            snap = copy.deepcopy(self.base)
            if counts is None:
                snap["facets"]["crashes"] = {"status": "not-comparable", "reason": "the daemon is not connected",
                                             "task": "p15-oracle-188"}
                existing = next((s for s in steps if s["id"] == step_id), None)
                if existing is None:
                    existing = {"id": step_id, "op": "snapshot", "checkpoints": {}}
                    steps.append(existing)
                existing["checkpoints"][checkpoint] = snap
                continue
            total = {kind: counts.get(kind, 0) for kind in CRASH_KINDS}
            for e in exits or []:
                if len([x for x in seen if x["kind"] == e["kind"]]) < total[e["kind"]] and e not in seen:
                    seen.append(e)
            snap["facets"]["crashes"] = {"counts": total, "exits": list(seen)}
            existing = next((s for s in steps if s["id"] == step_id), None)
            if existing is None:
                existing = {"id": step_id, "op": "snapshot", "checkpoints": {}}
                steps.append(existing)
            existing["checkpoints"][checkpoint] = snap
        doc = _trace(*steps)
        if allow is not None:
            doc["allow_crashes"] = allow
        return doc

    def test_i17_a_renderer_crash_without_allow_crashes_fails(self) -> None:
        crash = {"kind": "renderer", "reason": "crashed", "exitCode": 11}
        doc = self.crash_trace(("open", "settled", {}), ("crash", "settled", {"renderer": 1}), exits=[crash])
        report = self.check(doc)
        self.assertEqual([(v.invariant, v.step, v.pointer) for v in report.violations],
                         [("I17", "crash", "/crashes/exits/0")])
        self.assertIn("renderer exit (crashed) during step crash", report.violations[0].message)
        allowed = self.crash_trace(("open", "settled", {}), ("crash", "settled", {"renderer": 1}), exits=[crash],
                                   allow=[{"kind": "renderer", "reason": "chrome://crash on purpose", "steps": ["crash"]}])
        self.assertEqual(self.check(allowed).violations, [])
        self.assertEqual(self.check(allowed).checked["I17"], 1)

    def test_i17_scope_kind_and_max_of_each_entry(self) -> None:
        allow = [{"kind": "renderer", "reason": "chrome://crash on purpose", "steps": ["crash"]}]
        # Outside the entry's steps, of another kind, and one more than its max.
        elsewhere = self.crash_trace(("open", "settled", {}), ("crash", "settled", {}), ("after", "settled", {"renderer": 1}),
                                     allow=allow)
        self.assertEqual([(v.step, v.pointer) for v in self.check(elsewhere).violations],
                         [("after", "/crashes/counts/renderer")])
        gpu = self.crash_trace(("open", "settled", {}), ("crash", "settled", {"gpu": 1}), allow=allow)
        self.assertEqual([v.pointer for v in self.check(gpu).violations], ["/crashes/counts/gpu"])
        twice = self.crash_trace(("open", "settled", {}), ("crash", "settled", {"renderer": 2}), allow=allow)
        self.assertEqual(len(self.check(twice).violations), 1)
        whole = self.crash_trace(("open", "settled", {}), ("crash", "settled", {"holder": 2}),
                                 allow=[{"kind": "holder", "reason": "the case kills holders", "max": 2}])
        self.assertEqual(self.check(whole).violations, [])

    def test_i17_an_exit_during_teardown_needs_a_whole_case_entry(self) -> None:
        doc = self.crash_trace(("open", "settled", {}), ("close", "settled", {}))
        end = copy.deepcopy(self.base)
        end["facets"]["crashes"] = {"counts": {**{k: 0 for k in CRASH_KINDS}, "utility": 1},
                                    "exits": [{"kind": "utility", "reason": "abnormal", "exitCode": 256}]}
        doc["teardown"]["checkpoint"] = end
        doc["allow_crashes"] = [{"kind": "utility", "reason": "the network service ends", "steps": ["close"]}]
        self.assertEqual([(v.step, v.checkpoint, v.pointer) for v in self.check(doc).violations],
                         [(None, "teardown", "/crashes/exits/0")])
        doc["allow_crashes"] = [{"kind": "utility", "reason": "the network service ends"}]
        self.assertEqual([v for v in self.check(doc).violations if v.invariant == "I17"], [])

    def test_i17_an_exit_at_a_before_checkpoint_belongs_to_the_step_before(self) -> None:
        allow = [{"kind": "holder", "reason": "the kill step ends a holder", "steps": ["kill"]}]
        doc = self.crash_trace(("kill", "settled", {}), ("next", "before", {"holder": 1}), allow=allow)
        self.assertEqual(self.check(doc).violations, [])

    def test_i17_a_rise_after_unread_checkpoints_belongs_to_every_step_it_spans(self) -> None:
        allow = [{"kind": "holder", "reason": "the kill step ends a holder", "steps": ["kill"]}]
        # The kill step's settled crashes facet is not comparable (the daemon reconnects); the rise first
        # shows at the next step's settled checkpoint.
        reconnect = self.crash_trace(("open", "before", {}), ("kill", "settled", None), ("next", "settled", {"holder": 1}),
                                     allow=allow)
        self.assertEqual(self.check(reconnect).violations, [])
        # The kill step has no checkpoint at all.
        unread = self.crash_trace(("open", "before", {}), ("kill", "-", None), ("next", "settled", {"holder": 1}), allow=allow)
        self.assertEqual(self.check(unread).violations, [])
        # Without an entry for any step of the span the exit fails, and the message names the span.
        report = self.check(self.crash_trace(("open", "before", {}), ("kill", "settled", None),
                                             ("next", "settled", {"holder": 1})))
        self.assertEqual([(v.step, v.pointer) for v in report.violations], [("next", "/crashes/counts/holder")])
        self.assertIn("during one of step kill, step next", report.violations[0].message)
        # Adjacent readings keep the step's own scope: an entry for kill does not cover next.
        adjacent = self.crash_trace(("open", "before", {}), ("kill", "settled", {}), ("next", "settled", {"holder": 1}),
                                    allow=allow)
        self.assertEqual([v.step for v in self.check(adjacent).violations], ["next"])

    def test_i17_the_baseline_is_before_the_first_step(self) -> None:
        crash = {"kind": "renderer", "reason": "crashed", "exitCode": 11}
        # The first step's exit is in its own first reading: not checked, never taken as the baseline silently.
        late = self.crash_trace(("crash", "settled", {"renderer": 1}), ("read", "settled", {"renderer": 1}), exits=[crash])
        report = self.check(late)
        self.assertEqual([v for v in report.violations if v.invariant == "I17"], [])
        self.assertIn(("I17", "crash"), [(n.invariant, n.step) for n in report.not_checked])
        # With a before checkpoint of the first step, the same exit fails.
        early = self.crash_trace(("crash", "before", {}), ("crash", "settled", {"renderer": 1}), exits=[crash])
        report = self.check(early)
        self.assertEqual([(v.step, v.pointer) for v in report.violations], [("crash", "/crashes/exits/0")])
        self.assertNotIn(("I17", "crash"), [(n.invariant, n.step) for n in report.not_checked])

    def test_i17_totals_since_launch_count_only_their_rise_and_a_reset(self) -> None:
        doc = self.crash_trace(("open", "settled", {"renderer": 4, "daemon": 2}), ("read", "settled", {"renderer": 4, "daemon": 2}))
        self.assertEqual(self.check(doc).violations, [])
        reset = self.crash_trace(("open", "settled", {"holder": 5}), ("restart", "settled", {"holder": 1}))
        self.assertEqual([v.pointer for v in self.check(reset).violations], ["/crashes/counts/holder"])

    def test_i17_reads_allow_crashes_from_the_case_and_skips_without_the_facet(self) -> None:
        doc = self.crash_trace(("open", "settled", {}), ("crash", "settled", {"renderer": 1}))
        case = {"allow_crashes": [{"kind": "renderer", "reason": "chrome://crash on purpose"}]}
        self.assertEqual(self.check(doc, case).violations, [])
        report = self.check(_trace({"id": "s", "op": "settle"}))
        self.assertIn(("I17", None), [(n.invariant, n.step) for n in report.not_checked])

    # I18
    def test_i18_a_leaked_tab_fails_and_a_balanced_case_passes(self) -> None:
        opened = copy.deepcopy(self.base)
        opened["facets"]["liveObjects"]["pageViews"] += 1
        opened["facets"]["liveObjects"]["cefBrowsers"] += 1
        opened["facets"]["daemon"]["oracle"]["liveObjects"]["terminals"] += 1
        doc = _trace({"id": "open-tab", "op": "snapshot", "checkpoints": {"before": self.base, "settled": opened}})
        doc["teardown"]["checkpoint"] = opened
        report = self.check(doc)
        self.assertEqual([(v.invariant, v.checkpoint, v.pointer) for v in report.violations],
                         [("I18", "teardown", "/liveObjects/cefBrowsers"), ("I18", "teardown", "/liveObjects/pageViews"),
                          ("I18", "teardown", "/daemon/oracle/liveObjects/terminals")])
        self.assertIn("pageViews: 1 after teardown, 0 at the fixture baseline (1 more)", [v.message for v in report.violations])
        doc["teardown"]["checkpoint"] = self.base
        report = self.check(doc)
        self.assertEqual(report.violations, [])
        self.assertEqual(report.checked["I18"], 1)

    def test_i18_timing_counts_are_reported_not_failed(self) -> None:
        pending = copy.deepcopy(self.base)
        pending["facets"]["liveObjects"]["tasks"] += 1
        pending["facets"]["liveObjects"]["subscriptions"] += 2
        pending["facets"]["daemon"]["oracle"]["liveObjects"]["subscriptions"] += 1
        doc = _trace({"id": "close-tab", "op": "snapshot", "checkpoints": {"before": self.base}})
        doc["teardown"]["checkpoint"] = pending
        report = self.check(doc)
        self.assertEqual([v for v in report.violations if v.invariant == "I18"], [])
        skipped = [n.reason for n in report.not_checked if n.invariant == "I18"]
        self.assertEqual(len(skipped), 3)
        self.assertTrue(any("/liveObjects/tasks is timing state" in r and "1 more" in r for r in skipped))

    def test_i18_without_a_teardown_checkpoint_is_not_checked(self) -> None:
        report = self.check(_trace({"id": "s", "op": "settle", "checkpoints": {"settled": self.base}}))
        self.assertIn(("I18", None), [(n.invariant, n.step) for n in report.not_checked])

    # I9
    def i9_trace(self, snapshot: Dict[str, Any], reply: Any) -> Dict[str, Any]:
        return _trace({"id": "settle", "op": "settle", "checkpoints": {"settled": snapshot},
                       "restorePreviews": {"settled": reply}})

    def test_i9_a_restore_equal_to_the_live_session_passes(self) -> None:
        snapshot, raw = _restorable(self.schema, self.base)
        head = snapshot["facets"]["daemon"]["journalHead"]
        reply = _restore_reply(raw, head)
        restored = reply["preview"]["session"]
        restored["tabs"].reverse()  # the reducer's order: index, then id
        restored["cursor"]["revision"] = "7"  # volatile in the facet: counts commits, not state
        restored["machine"] = {"id": "machine_elsewhere"}  # excluded with a reason
        report = self.check(self.i9_trace(snapshot, reply))
        self.assertEqual([v for v in report.violations if v.invariant == "I9"], [])
        self.assertEqual(report.checked["I9"], 1)
        self.assertEqual([n for n in report.not_checked if n.invariant == "I9"], [])

    def test_i9_catches_the_skip_journal_append_mutant(self) -> None:
        """A step whose journal record was never appended: the restore stops before its changes."""
        _, raw_before = _restorable(self.schema, self.base)
        after, raw_after = _restorable(self.schema, _bump_sequences(_with_hidden_workspace(self.base), 1))
        head = after["facets"]["daemon"]["journalHead"]
        report = self.check(self.i9_trace(after, _restore_reply(raw_before, head)))
        live = after["facets"]["daemon"]["session"]
        index = [w["id"] for w in live["workspaces"]].index(HIDDEN_WS)
        self.assertIn(("I9", f"/daemon/session/workspaces/{index}"), self.ids(report))
        self.assertTrue(any(v.pointer.startswith("/daemon/session/tabs/") for v in report.violations), report)

        # A rename whose record was skipped: the restore keeps the old name.
        renamed = copy.deepcopy(after)
        renamed["facets"]["daemon"]["session"]["workspaces"][index]["name"] = "renamed"
        report = self.check(self.i9_trace(renamed, _restore_reply(raw_after, head)))
        self.assertEqual(self.ids(report), [("I9", f"/daemon/session/workspaces/{index}/name")])

    def test_i9_another_cut_or_no_checkpoint_is_not_checked(self) -> None:
        snapshot, raw = _restorable(self.schema, self.base)
        head = snapshot["facets"]["daemon"]["journalHead"]
        for reply in (_restore_reply(raw, head + 1), {"sections": RESTORE_SECTIONS, "preview": None}):
            report = self.check(self.i9_trace(snapshot, reply))
            self.assertEqual((report.checked["I9"], self.ids(report)), (0, []))
            self.assertEqual([n.step for n in report.not_checked if n.invariant == "I9"], ["settle"])
        report = self.check(_trace({"id": "s", "op": "settle", "checkpoints": {"settled": snapshot}}))
        self.assertIn(("I9", None), [(n.invariant, n.step) for n in report.not_checked])

    def test_i9_a_record_the_restore_cannot_apply_fails(self) -> None:
        snapshot, raw = _restorable(self.schema, self.base)
        head = snapshot["facets"]["daemon"]["journalHead"]
        unsupported = [{"sequence": str(head), "event_id": "event_x", "kind": "plugin.change"}]
        report = self.check(self.i9_trace(snapshot, _restore_reply(raw, head, unsupported)))
        self.assertEqual(self.ids(report), [("I9", "/daemon/journalHead")])

    def test_i9_an_exclusion_without_a_reason_is_compared(self) -> None:
        snapshot, raw = _restorable(self.schema, self.base)
        head = snapshot["facets"]["daemon"]["journalHead"]
        sections = {**RESTORE_SECTIONS, "machine": {"restore": "excluded", "reason": " "}}
        report = self.check(self.i9_trace(snapshot, _restore_reply(raw, head, sections=sections)))
        self.assertEqual(self.ids(report), [("I9", "/daemon/session/machine")])

    def test_i9_a_state_change_the_restore_does_not_reduce_fails(self) -> None:
        """`extra` is compared while no state change followed the checkpoint; a dropped one fails once."""
        snapshot, raw = _restorable(self.schema, self.base)
        head = snapshot["facets"]["daemon"]["journalHead"]
        stale = copy.deepcopy(raw)
        stale["extra"] = {"state": {"closed": [{"id": "closed_1"}]}}
        report = self.check(self.i9_trace(snapshot, _restore_reply(stale, head)))
        extra = [at for _, at in self.ids(report)]
        self.assertTrue(extra and all(at.startswith("/daemon/session/extra") for at in extra), extra)
        report = self.check(self.i9_trace(snapshot, _restore_reply(stale, head, state_changes=2)))
        self.assertEqual(self.ids(report), [("I9", "/daemon/session/extra")])
        self.assertIn("2 state_upsert/state_delete", report.violations[0].message)

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
