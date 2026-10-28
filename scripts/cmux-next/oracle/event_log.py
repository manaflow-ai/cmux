#!/usr/bin/env python3
"""The oracle's event log: `session.events` recorded through the Python SDK, and the client model it folds to.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md section 3F, invariant I8 ("a client model folded from
`session.events` == daemon facet at the same sequence"), task 204. Stdlib plus the repo's Python SDK
(cmux-tui/bindings/python, the one daemon client); safe under `python3 -I`.

Chrome reference (chromium/src): a mirror fed by a change stream is checked against the source of truth it
mirrors, as components/sync/test/fake_server/fake_server_verifier.cc checks a client's synced model against the
fake server's entities, and the sync integration tests (chrome/browser/sync/test/integration/
updated_progress_marker_checker.cc) wait for the client to reach the server's progress marker before they
compare. Here the progress marker is the stream cursor: the fold is compared with the daemon facet only at the
facet's own `session.cursor`.

`EventLog` opens `session.events` with the SDK's `ResourceStream` (cmux/_protocol.py; cmux/aio.py adapts the
same stream for asyncio). The log keeps each raw item, which is what the fold reads; the fold refuses an item
whose shape it cannot apply. `EventLog.record()` is the trace
member `eventLogs[n]` (invariants.py):

    {"name": "driver" | <step id>, "connection"?: <case connection>, "openedAt"?: <step id>,
     "endedAt"?: {"step": <step id>, "checkpoint"?: <checkpoint>},
     "items": [{"sequence": <stream item sequence>, "item": <raw SessionEventItem>}],
     "end"?: {"reason": "completed|canceled|closed|gap|error" | ORACLE_TEARDOWN, "cursor"?: Cursor}}

`openedAt` is the step during which the stream opened: that step's `before` checkpoint and every checkpoint of an
earlier step were taken before the stream existed (a client connecting changes the session without moving
its revision, so the cursor alone cannot tell). `endedAt` ({"step", "checkpoint"?}) is where the driver saw
the end: the checkpoint whose capture read it, or with no checkpoint the step whose handler closed the
connection; that checkpoint (or the step's checkpoints after `before`) and every later one come after the
end. `end` is the end the daemon or the SDK reported (StreamEnd.reason; `closed` when the connection failed). A
stream still open when the oracle cancels it at teardown, after every checkpoint, ends with ORACLE_TEARDOWN,
which I8 reads as open: a daemon that stopped delivering is then a violation, never a skipped cut.

`SessionFold` is the client model: a snapshot item resets it, a delta applies its changes in order after it
checks the delta's generation and `previous_revision` (the protocol's gap rule, the same checks as the Rust
mirror in cmux-tui/bindings/rust-daemon-client/src/mirror.rs). Resources are tables keyed by id; the state
resources of `extra.state` are keyed as the daemon keys their `state_upsert` and `state_delete` changes
(STATE_TABLES). The sidebar document folds from its item, section and doc changes. A change of a kind the
snapshot has no place for (a pairing request, a stash) is counted in `unmodeled`, not compared.

`delta_between(a, b)` is the delta a correct daemon sends from snapshot `a` to snapshot `b`: the self tests of
this file and of invariants.py build event logs with it.

Usage:
  event_log.py --selftest
"""

from __future__ import annotations

import copy
import sys
import unittest
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SDK = REPO / "cmux-tui" / "bindings" / "python"

STREAM = "session.events"
# The end reason of a log the oracle canceled at teardown, not one the stream reported.
ORACLE_TEARDOWN = "oracle_teardown"
# Seconds `read_queued` waits for an item the SDK does not hold yet.
QUEUED_WAIT_S = 0.001
SELECTORS = {"machine": "current", "session": "current"}

# ResourceKind -> the ResourceSnapshot array that holds it. machine and session are single objects.
RESOURCE_TABLES: Dict[str, str] = {
    "workspace": "workspaces", "screen": "screens", "pane": "panes", "tab": "tabs", "terminal": "terminals",
    "browser": "browsers", "client": "clients", "notification": "notifications", "agent": "agents",
    "frontend_projection": "frontend_projections", "sidebar_view": "sidebar_views",
}
SINGLE_RESOURCES = ("machine", "session")
TABLES = tuple(RESOURCE_TABLES.values())


def _by(name: str) -> Callable[[Mapping[str, Any]], str]:
    return lambda value: str(value[name])


def _placement_id(value: Mapping[str, Any]) -> str:
    """personal_state_store.rs placement_id: `<session registry id>/<workspace ref>`."""
    ref = value["workspace"]
    return f"{ref['session_id']}/{ref['workspace_ref']}"


# StateResourceKind -> (extra.state array, the id its changes carry, read from a snapshot item). store.rs
# state_snapshot builds the arrays; the *_store.rs files that call state_upsert name the ids.
STATE_TABLES: Dict[str, Tuple[str, Callable[[Mapping[str, Any]], str]]] = {
    "tab_group": ("tab_groups", _by("id")),
    "saved_tab_group": ("saved_tab_groups", _by("id")),
    "workspace_group": ("workspace_groups", _by("id")),
    "workspace_placement": ("workspace_placements", _placement_id),
    "room": ("rooms", _by("id")),
    "screen_group": ("screen_groups", _by("id")),
    "closed": ("closed", _by("id")),
    "workspace_status": ("workspace_status", _by("workspace_id")),
    "workspace_checklist": ("workspace_checklist", _by("workspace_id")),
    "window_record": ("window_records", _by("id")),
}
# sidebar_layout_store.rs: one document, id `user`, replaced whole.
SIDEBAR_LAYOUT = "sidebar_layout"
# sidebar_doc_store.rs write_changes: section and item rows by id, then the `sidebar_doc` revision marker.
SIDEBAR_DOC = "sidebar"
SIDEBAR_ROWS = {"sidebar_section": "sections", "sidebar_item": "items"}
SIDEBAR_MARKER = "sidebar_doc"
STATE_KEYS = tuple(table for table, _ in STATE_TABLES.values()) + (SIDEBAR_LAYOUT, SIDEBAR_DOC)


class FoldError(Exception):
    """An item the fold cannot apply: the stream broke its own protocol."""


def revision_of(cursor: Any) -> Optional[int]:
    if not isinstance(cursor, Mapping):
        return None
    value = cursor.get("revision")
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


@dataclass(frozen=True)
class EventRef:
    """Where a change came from: the log item and the change inside a delta (None for a snapshot item)."""

    item: int
    sequence: str
    change: Optional[int] = None

    def describe(self) -> str:
        where = f"stream item {self.sequence} (items/{self.item}"
        return where + (f", change {self.change})" if self.change is not None else ", snapshot)")


@dataclass
class SessionFold:
    """The client model one `session.events` stream folds to."""

    generation: Optional[str] = None
    revision: Optional[int] = None
    base_revision: Optional[int] = None
    single: Dict[str, Any] = field(default_factory=dict)
    tables: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    state: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    sidebar_layout: Any = None
    sidebar: Dict[str, Any] = field(default_factory=dict)
    # (table or state key, id) -> the last event that set or removed it; ("session",) etc. for singles.
    touched: Dict[Tuple[str, ...], EventRef] = field(default_factory=dict)
    snapshot_ref: Optional[EventRef] = None
    unmodeled: Dict[str, int] = field(default_factory=dict)

    # ---------------------------------------------------------------------------------------------- apply

    def apply(self, index: int, entry: Mapping[str, Any]) -> None:
        item = entry.get("item") if isinstance(entry, Mapping) else None
        sequence = str(entry.get("sequence")) if isinstance(entry, Mapping) else "?"
        if not isinstance(item, Mapping):
            raise FoldError("the log entry has no item object")
        kind = item.get("kind")
        if kind == "snapshot":
            self.reset(item, EventRef(index, sequence))
        elif kind == "delta":
            self.apply_delta(item, index, sequence)
        else:
            self.unmodeled[f"item:{kind}"] = self.unmodeled.get(f"item:{kind}", 0) + 1

    def reset(self, item: Mapping[str, Any], ref: EventRef) -> None:
        snapshot = item.get("snapshot")
        cursor = item.get("cursor")
        if not isinstance(snapshot, Mapping) or revision_of(cursor) is None:
            raise FoldError("a snapshot item needs a snapshot and a cursor")
        self.generation = str(cursor.get("generation"))
        self.revision = self.base_revision = revision_of(cursor)
        self.single = {name: copy.deepcopy(snapshot.get(name)) for name in SINGLE_RESOURCES}
        self.tables = {table: {str(row["id"]): copy.deepcopy(row) for row in snapshot.get(table) or []}
                       for table in TABLES}
        state = ((snapshot.get("extra") or {}).get("state") or {}) if isinstance(snapshot.get("extra"), Mapping) else {}
        self.state = {table: {key(row): copy.deepcopy(row) for row in state.get(table) or []}
                      for table, key in STATE_TABLES.values()}
        self.sidebar_layout = copy.deepcopy(state.get(SIDEBAR_LAYOUT))
        doc = state.get(SIDEBAR_DOC) or {}
        self.sidebar = {"revision": doc.get("revision"),
                        **{rows: {str(row["id"]): copy.deepcopy(row) for row in doc.get(rows) or []}
                           for rows in SIDEBAR_ROWS.values()}}
        self.touched = {}
        self.snapshot_ref = ref

    def apply_delta(self, item: Mapping[str, Any], index: int, sequence: str) -> None:
        if self.revision is None:
            raise FoldError("a delta before any snapshot item")
        cursor = item.get("cursor")
        if not isinstance(cursor, Mapping) or str(cursor.get("generation")) != self.generation:
            raise FoldError(f"a delta of generation {(cursor or {}).get('generation')!r} on a fold of "
                            f"{self.generation!r} without a snapshot item")
        previous = _int(item.get("previous_revision"))
        revision = _int(item.get("revision"))
        if previous != self.revision:
            raise FoldError(f"gap: the delta starts at revision {item.get('previous_revision')}, the fold is at "
                            f"{self.revision}")
        if revision is None or revision < previous or revision_of(cursor) != revision:
            raise FoldError(f"the delta ends at revision {item.get('revision')}, its cursor at "
                            f"{cursor.get('revision')}")
        changes = item.get("changes")
        if not isinstance(changes, list):
            raise FoldError("a delta without a changes array")
        for n, change in enumerate(changes):
            self.apply_change(change, EventRef(index, sequence, n))
        self.revision = revision

    def apply_change(self, change: Any, ref: EventRef) -> None:
        if not isinstance(change, Mapping):
            raise FoldError(f"change {ref.change} is not an object")
        kind, resource, ident = change.get("kind"), change.get("resource"), change.get("id")
        if kind not in ("upsert", "delete", "state_upsert", "state_delete"):
            self.unmodeled[f"change:{kind}"] = self.unmodeled.get(f"change:{kind}", 0) + 1
            return
        if not isinstance(resource, str) or not isinstance(ident, str):
            raise FoldError(f"change {ref.change} ({kind}) has no resource or id")
        upsert = kind in ("upsert", "state_upsert")
        if upsert and "value" not in change:
            raise FoldError(f"change {ref.change} ({kind} {resource} {ident}) has no value")
        value = copy.deepcopy(change.get("value"))
        if kind in ("upsert", "delete"):
            self._resource(resource, ident, value if upsert else None, ref)
        else:
            self._state(resource, ident, value if upsert else None, ref)

    def _resource(self, resource: str, ident: str, value: Any, ref: EventRef) -> None:
        if resource in SINGLE_RESOURCES:
            self.single[resource] = value
            self.touched[(resource,)] = ref
            return
        table = RESOURCE_TABLES.get(resource)
        if table is None:
            self.unmodeled[resource] = self.unmodeled.get(resource, 0) + 1
            return
        if value is not None and str(value.get("id")) != ident:
            raise FoldError(f"change {ref.change}: upsert {resource} {ident} carries value id {value.get('id')!r}")
        _put(self.tables[table], ident, value)
        self.touched[(table, ident)] = ref

    def _state(self, resource: str, ident: str, value: Any, ref: EventRef) -> None:
        if resource in STATE_TABLES:
            table, _ = STATE_TABLES[resource]
            _put(self.state[table], ident, value)
            self.touched[(table, ident)] = ref
        elif resource == SIDEBAR_LAYOUT:
            self.sidebar_layout = value
            self.touched[(SIDEBAR_LAYOUT,)] = ref
        elif resource in SIDEBAR_ROWS:
            _put(self.sidebar[SIDEBAR_ROWS[resource]], ident, value)
            self.touched[(SIDEBAR_DOC, SIDEBAR_ROWS[resource], ident)] = ref
        elif resource == SIDEBAR_MARKER:
            if value is not None:
                self.sidebar["revision"] = value.get("revision")
            self.touched[(SIDEBAR_DOC, "revision")] = ref
        else:
            self.unmodeled[resource] = self.unmodeled.get(resource, 0) + 1

    # ---------------------------------------------------------------------------------------------- read

    def render(self) -> Dict[str, Any]:
        """The fold as a ResourceSnapshot: rows in id order, `cursor` at the fold's revision."""
        out: Dict[str, Any] = {name: copy.deepcopy(self.single.get(name)) for name in SINGLE_RESOURCES}
        for table in TABLES:
            out[table] = [copy.deepcopy(self.tables[table][k]) for k in sorted(self.tables[table])]
        state: Dict[str, Any] = {table: [copy.deepcopy(rows[k]) for k in sorted(rows)]
                                 for table, rows in self.state.items()}
        state[SIDEBAR_LAYOUT] = copy.deepcopy(self.sidebar_layout)
        state[SIDEBAR_DOC] = {"revision": self.sidebar.get("revision"),
                              **{rows: [copy.deepcopy(self.sidebar[rows][k]) for k in sorted(self.sidebar[rows])]
                                 for rows in SIDEBAR_ROWS.values()}}
        out["extra"] = {"state": state}
        out["cursor"] = {"generation": self.generation, "revision": str(self.revision)}
        return out

    def event_for(self, key: Tuple[str, ...]) -> str:
        """The last event that set `key`, or the snapshot item it comes from unchanged."""
        ref = self.touched.get(key)
        if ref is not None:
            return f"last event {ref.describe()}"
        base = self.snapshot_ref.describe() if self.snapshot_ref else "no snapshot"
        return f"no event since {base}"


def _int(value: Any) -> Optional[int]:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _put(rows: Dict[str, Any], ident: str, value: Any) -> None:
    if value is None:
        rows.pop(ident, None)
    else:
        rows[ident] = value


def keyed(snapshot: Mapping[str, Any]) -> Dict[str, Any]:
    """A ResourceSnapshot (or a rendered fold) as tables keyed the way changes key them. Only what the fold
    models is kept: the extra.state arrays of STATE_KEYS, never another extra member."""
    out: Dict[str, Any] = {name: snapshot.get(name) for name in SINGLE_RESOURCES}
    for table in TABLES:
        out[table] = {str(row["id"]): row for row in snapshot.get(table) or [] if isinstance(row, Mapping)}
    extra = snapshot.get("extra") if isinstance(snapshot.get("extra"), Mapping) else {}
    state = extra.get("state") if isinstance(extra.get("state"), Mapping) else {}
    keyed_state: Dict[str, Any] = {}
    for table, key in STATE_TABLES.values():
        keyed_state[table] = {key(row): row for row in state.get(table) or [] if isinstance(row, Mapping)}
    keyed_state[SIDEBAR_LAYOUT] = state.get(SIDEBAR_LAYOUT)
    doc = state.get(SIDEBAR_DOC) if isinstance(state.get(SIDEBAR_DOC), Mapping) else {}
    keyed_state[SIDEBAR_DOC] = {"revision": doc.get("revision"),
                                **{rows: {str(r["id"]): r for r in doc.get(rows) or [] if isinstance(r, Mapping)}
                                   for rows in SIDEBAR_ROWS.values()}}
    out["extra"] = {"state": keyed_state}
    return out


def row_index(snapshot: Mapping[str, Any], tokens: List[str]) -> Optional[List[Any]]:
    """The ResourceSnapshot path of a keyed path (`tabs/<id>/name` -> `tabs/<index>/name`), or None when the id
    is not in the snapshot."""
    def index_in(rows: Any, ident: str, key: Callable[[Mapping[str, Any]], str]) -> Optional[int]:
        for i, row in enumerate(rows or []):
            if isinstance(row, Mapping) and key(row) == ident:
                return i
        return None

    if len(tokens) >= 2 and tokens[0] in TABLES:
        i = index_in(snapshot.get(tokens[0]), tokens[1], _by("id"))
        return None if i is None else [tokens[0], i, *tokens[2:]]
    if len(tokens) >= 4 and tokens[:2] == ["extra", "state"]:
        state = (snapshot.get("extra") or {}).get("state") or {}
        for table, key in STATE_TABLES.values():
            if tokens[2] == table:
                i = index_in(state.get(table), tokens[3], key)
                return None if i is None else [*tokens[:3], i, *tokens[4:]]
        if tokens[2] == SIDEBAR_DOC and len(tokens) >= 5 and tokens[3] in SIDEBAR_ROWS.values():
            i = index_in((state.get(SIDEBAR_DOC) or {}).get(tokens[3]), tokens[4], _by("id"))
            return None if i is None else [*tokens[:4], i, *tokens[5:]]
    return list(tokens)


def touched_key(tokens: List[str]) -> Tuple[str, ...]:
    """The `SessionFold.touched` key of a keyed path."""
    if tokens and tokens[0] in SINGLE_RESOURCES:
        return (tokens[0],)
    if len(tokens) >= 2 and tokens[0] in TABLES:
        return (tokens[0], tokens[1])
    if len(tokens) >= 3 and tokens[:2] == ["extra", "state"]:
        if tokens[2] == SIDEBAR_LAYOUT:
            return (SIDEBAR_LAYOUT,)
        if tokens[2] == SIDEBAR_DOC:
            return (SIDEBAR_DOC, *tokens[3:5]) if len(tokens) >= 5 and tokens[3] != "revision" else (SIDEBAR_DOC, "revision")
        if len(tokens) >= 4:
            return (tokens[2], tokens[3])
    return tuple(tokens[:2])


# ---------------------------------------------------------------------------------------------- deltas


def delta_between(a: Mapping[str, Any], b: Mapping[str, Any], *, sequence_start: int = 0) -> Dict[str, Any]:
    """The `delta` item a correct daemon sends from ResourceSnapshot `a` to `b` (both raw, same generation)."""
    ka, kb = keyed(a), keyed(b)
    changes: List[Dict[str, Any]] = []

    def add(kind: str, resource: str, ident: str, value: Any = None) -> None:
        change: Dict[str, Any] = {"kind": kind, "sequence": sequence_start + len(changes), "resource": resource,
                                  "id": ident}
        if kind.endswith("upsert"):
            change["value"] = copy.deepcopy(value)
        changes.append(change)

    for name in SINGLE_RESOURCES:
        if ka[name] != kb[name]:
            add("upsert", name, str((kb[name] or {}).get("id")), kb[name])
    for resource, table in RESOURCE_TABLES.items():
        _diff(ka[table], kb[table], lambda k, i, v=None, r=resource: add(k, r, i, v), "upsert", "delete")
    sa, sb = ka["extra"]["state"], kb["extra"]["state"]
    for resource, (table, _) in STATE_TABLES.items():
        _diff(sa[table], sb[table], lambda k, i, v=None, r=resource: add(k, r, i, v), "state_upsert", "state_delete")
    if sa[SIDEBAR_LAYOUT] != sb[SIDEBAR_LAYOUT] and sb[SIDEBAR_LAYOUT] is not None:
        add("state_upsert", SIDEBAR_LAYOUT, "user", sb[SIDEBAR_LAYOUT])
    for resource, rows in SIDEBAR_ROWS.items():
        _diff(sa[SIDEBAR_DOC][rows], sb[SIDEBAR_DOC][rows], lambda k, i, v=None, r=resource: add(k, r, i, v),
              "state_upsert", "state_delete")
    if sa[SIDEBAR_DOC]["revision"] != sb[SIDEBAR_DOC]["revision"]:
        add("state_upsert", SIDEBAR_MARKER, "sidebar", {"revision": sb[SIDEBAR_DOC]["revision"]})
    return {"kind": "delta", "cursor": copy.deepcopy(b["cursor"]), "previous_revision": a["cursor"]["revision"],
            "revision": b["cursor"]["revision"], "changes": changes}


def _diff(a: Mapping[str, Any], b: Mapping[str, Any], add: Callable[..., None], upsert: str, delete: str) -> None:
    for ident in sorted(b):
        if a.get(ident) != b[ident]:
            add(upsert, ident, b[ident])
    for ident in sorted(set(a) - set(b)):
        add(delete, ident)


def log_of(snapshots: List[Mapping[str, Any]], name: str = "driver") -> Dict[str, Any]:
    """An `eventLogs` entry for a run whose daemon went through `snapshots` (ResourceSnapshots in order): a
    snapshot item for the first, a delta for each later one that changed the revision."""
    first = snapshots[0]
    items = [{"sequence": "0", "item": {"kind": "snapshot", "cursor": copy.deepcopy(first["cursor"]),
                                        "reset_reason": "initial", "snapshot": copy.deepcopy(first)}}]
    previous = first
    for snapshot in snapshots[1:]:
        if revision_of(snapshot["cursor"]) == revision_of(previous["cursor"]):
            continue
        items.append({"sequence": str(len(items)), "item": delta_between(previous, snapshot)})
        previous = snapshot
    return {"name": name, "items": items}


# ---------------------------------------------------------------------------------------------- recorder


class EventLog:
    """One `session.events` stream through the SDK, kept raw for the fold.

    `connection` is the SDK's cmux._protocol.ProtocolConnection (driver_daemon.SdkReads holds one). The item
    decoder keeps the raw object: the SDK's typed decoder (cmux/resources.py `_event_item`) refuses a terminal
    snapshot with the catalog's `stream_revision` field, so it cannot read today's daemon; the fold checks the
    item shape it reads."""

    def __init__(self, connection: Any, name: str = "driver", case_connection: Optional[str] = None,
                 selectors: Mapping[str, Any] = SELECTORS, timeout: Optional[float] = None,
                 opened_at: Optional[str] = None):
        if str(SDK) not in sys.path:
            sys.path.insert(0, str(SDK))
        self.name = name
        self.case_connection = case_connection
        self.opened_at = opened_at
        self.items: List[Dict[str, Any]] = []
        self.end: Optional[Dict[str, Any]] = None
        # The first checkpoint the driver took after it saw the end ({"step", "checkpoint"?}); see the module doc.
        self.ended_at: Optional[Dict[str, str]] = None
        from cmux.errors import CmuxError, TimeoutError as SdkTimeout

        self._timeout = SdkTimeout
        # StreamError (an error or gap end) and ProtocolError (a connection failure) both end the log.
        self._stream_error = CmuxError
        self._stream = connection.open_stream(STREAM, dict(selectors), copy.deepcopy, timeout=timeout)

    @property
    def stream(self) -> Any:
        """The SDK's ResourceStream (its id names the stream in stream.cancel)."""
        return self._stream

    def read_until(self, generation: str, revision: int, timeout: float) -> bool:
        """Read items until one carries cursor (generation, >= revision), then what is already queued. False when
        the stream ended or `timeout` seconds passed first; the stream stays open after a timeout."""
        reached = self._read(lambda: self._reached(generation, revision), timeout)
        self.read_queued()
        return reached

    def read_queued(self) -> None:
        """Read what the SDK already holds, an end included, without waiting for more."""
        self._read(lambda: False, QUEUED_WAIT_S)

    def read_to_end(self, timeout: float) -> bool:
        """Read what the stream still holds after its connection closed (it then ends at once); False when it
        did not end within `timeout` seconds."""
        self._read(lambda: False, timeout)
        return self.end is not None

    def _read(self, done: Callable[[], bool], timeout: float) -> bool:
        """Read until `done()`, the stream's end or `timeout` seconds; True when `done()` held."""
        import time

        deadline = time.monotonic() + timeout
        while not done():
            left = deadline - time.monotonic()
            if self.end is not None or left <= 0:
                return False
            try:
                value = self._stream.next(left)
            except self._timeout:
                return False
            except (StopIteration, self._stream_error):
                self._ended()
                return False
            self.items.append({"sequence": str(value.sequence), "item": value.item})
        return True

    def _reached(self, generation: str, revision: int) -> bool:
        if not self.items:
            return False
        cursor = self.items[-1]["item"].get("cursor") or {}
        current = revision_of(cursor)
        return str(cursor.get("generation")) == generation and current is not None and current >= revision

    def _ended(self) -> None:
        end = self._stream.end
        self.end = {"reason": getattr(end, "reason", "closed")}
        cursor = getattr(end, "cursor", None)
        if cursor is not None:
            self.end["cursor"] = {"generation": str(cursor.generation), "revision": str(cursor.revision)}

    def record(self) -> Dict[str, Any]:
        out: Dict[str, Any] = {"name": self.name, "items": copy.deepcopy(self.items)}
        if self.case_connection:
            out["connection"] = self.case_connection
        if self.opened_at:
            out["openedAt"] = self.opened_at
        if self.end is not None:
            out["end"] = dict(self.end)
        if self.ended_at is not None:
            out["endedAt"] = dict(self.ended_at)
        return out

    def close(self) -> None:
        """The oracle's teardown cancel. A stream that ended keeps the end it reported."""
        self.read_queued()
        if self.end is None:
            self.end = {"reason": ORACLE_TEARDOWN}
            try:
                self._stream.cancel()
            except self._stream_error:
                pass  # the connection is already gone; the log stays as read


# ---------------------------------------------------------------------------------------------- self test


def _session(revision: int, **tables: List[Dict[str, Any]]) -> Dict[str, Any]:
    snapshot: Dict[str, Any] = {
        "machine": {"id": "machine_1", "name": "m"},
        "session": {"id": "session_1", "generation": "g", "revision": str(revision)},
        **{table: [] for table in TABLES},
        "extra": {"state": {"tab_groups": [], "workspace_placements": [], "sidebar_layout": {"revision": "1"},
                            "sidebar": {"revision": "1", "items": [], "sections": []}}},
        "cursor": {"generation": "g", "revision": str(revision)},
    }
    snapshot.update(copy.deepcopy(tables))
    return snapshot


def _fold(log: Mapping[str, Any]) -> SessionFold:
    fold = SessionFold()
    for i, entry in enumerate(log["items"]):
        fold.apply(i, entry)
    return fold


class EventLogSelfTest(unittest.TestCase):
    def test_a_fold_of_deltas_equals_the_last_snapshot(self) -> None:
        tab = {"id": "tab_1", "pane_id": "pane_1", "name": None}
        a = _session(1, tabs=[tab])
        b = _session(2, tabs=[{**tab, "name": "x"}, {"id": "tab_2", "pane_id": "pane_1", "name": None}])
        b["extra"]["state"]["tab_groups"] = [{"id": "tgrp_1", "tab_ids": ["tab_1"]}]
        b["extra"]["state"]["workspace_placements"] = [
            {"workspace": {"session_id": "s", "workspace_ref": "w", "workspace_id": None}, "index": 0}]
        b["extra"]["state"]["sidebar"]["items"] = [{"id": "itm_1", "section": "sec_top"}]
        b["extra"]["state"]["sidebar"]["revision"] = "2"
        c = _session(3, tabs=[{**tab, "name": "x"}])
        log = log_of([a, b, c])
        self.assertEqual(len(log["items"]), 3)
        fold = _fold(log)
        self.assertEqual(fold.revision, 3)
        self.assertEqual(keyed(fold.render()), keyed(c))
        self.assertEqual(fold.touched[("tabs", "tab_2")].item, 2, "the delete of tab_2 is the last event")
        partial = SessionFold()
        partial.apply(0, log["items"][0])
        partial.apply(1, log["items"][1])
        self.assertEqual(keyed(partial.render()), keyed(b))
        self.assertEqual(partial.state["workspace_placements"].keys(), {"s/w"})

    def test_gaps_generations_and_bad_changes_are_fold_errors(self) -> None:
        a, b, c = _session(1), _session(2, tabs=[{"id": "tab_1"}]), _session(3)
        log = log_of([a, b, c])
        with self.assertRaisesRegex(FoldError, "gap"):
            _fold({"items": [log["items"][0], log["items"][2]]})
        with self.assertRaisesRegex(FoldError, "before any snapshot"):
            _fold({"items": [log["items"][1]]})
        other = copy.deepcopy(log["items"][1])
        other["item"]["cursor"]["generation"] = "h"
        with self.assertRaisesRegex(FoldError, "generation"):
            _fold({"items": [log["items"][0], other]})
        wrong = copy.deepcopy(log["items"][1])
        next(c for c in wrong["item"]["changes"] if c["resource"] == "tab")["value"]["id"] = "tab_9"
        with self.assertRaisesRegex(FoldError, "value id"):
            _fold({"items": [log["items"][0], wrong]})

    def test_a_snapshot_item_resets_and_unknown_kinds_are_counted(self) -> None:
        a = _session(1, tabs=[{"id": "tab_1"}])
        restarted = _session(1)
        restarted["cursor"]["generation"] = restarted["session"]["generation"] = "h"
        log = log_of([a])
        log["items"].append({"sequence": "1", "item": {"kind": "snapshot", "cursor": restarted["cursor"],
                                                        "reset_reason": "generation_changed", "snapshot": restarted}})
        log["items"].append({"sequence": "2", "item": {"kind": "delta", "cursor": {"generation": "h", "revision": "2"},
                                                        "previous_revision": "1", "revision": "2", "changes": [
                                                            {"kind": "state_upsert", "sequence": 0, "resource": "stash",
                                                             "id": "stash_1", "value": {}},
                                                            {"kind": "future", "sequence": 1}]}})
        fold = _fold(log)
        self.assertEqual((fold.generation, fold.revision), ("h", 2))
        self.assertEqual(fold.tables["tabs"], {})
        self.assertEqual(fold.unmodeled, {"stash": 1, "change:future": 1})
        self.assertIn("no event since stream item 1", fold.event_for(("tabs", "tab_1")))

    def test_row_index_maps_a_keyed_path_back_to_the_snapshot(self) -> None:
        snap = _session(1, tabs=[{"id": "tab_1"}, {"id": "tab_2"}])
        snap["extra"]["state"]["workspace_placements"] = [
            {"workspace": {"session_id": "s", "workspace_ref": "w"}, "index": 0}]
        self.assertEqual(row_index(snap, ["tabs", "tab_2", "name"]), ["tabs", 1, "name"])
        self.assertIsNone(row_index(snap, ["tabs", "tab_9"]))
        self.assertEqual(row_index(snap, ["extra", "state", "workspace_placements", "s/w", "index"]),
                         ["extra", "state", "workspace_placements", 0, "index"])
        self.assertEqual(touched_key(["extra", "state", "sidebar", "items", "itm_1", "order"]),
                         ("sidebar", "items", "itm_1"))

    def test_the_recorder_reads_to_the_cursor_and_records_the_end(self) -> None:
        if str(SDK) not in sys.path:
            sys.path.insert(0, str(SDK))
        from types import SimpleNamespace

        from cmux.errors import StreamError, TimeoutError as SdkTimeout

        wire = _wire_snapshot()
        revision = revision_of(wire["cursor"])
        generation = str(wire["cursor"]["generation"])
        first = {"kind": "snapshot", "cursor": wire["cursor"], "reset_reason": "initial", "snapshot": wire}
        later = {"kind": "delta", "cursor": {"generation": generation, "revision": str(revision + 1)},
                 "previous_revision": str(revision), "revision": str(revision + 1), "changes": []}

        class FakeStream:
            def __init__(self, decode: Callable[[Any], Any]):
                # Each read_until ends with a read of what is queued: the quiet reads after an item.
                self.script: List[Any] = [decode(first), SdkTimeout("queued"), SdkTimeout("quiet"),
                                          SdkTimeout("queued"), decode(later), StreamError("gap")]
                self.end: Any = None
                self.canceled = False

            def next(self, timeout: float) -> Any:
                value = self.script.pop(0)
                if isinstance(value, StreamError):
                    self.end = SimpleNamespace(reason="gap", cursor=None)
                if isinstance(value, Exception):
                    raise value
                return SimpleNamespace(sequence=str(6 - len(self.script)), item=value)

            def cancel(self) -> None:
                self.canceled = True

        streams: List[FakeStream] = []

        class FakeConnection:
            def open_stream(self, operation: str, params: Mapping[str, Any], decode: Callable[[Any], Any],
                            timeout: Optional[float] = None) -> Any:
                assert (operation, dict(params)) == (STREAM, SELECTORS)
                streams.append(FakeStream(decode))
                return streams[-1]

        log = EventLog(FakeConnection(), "open", "viewer")
        self.assertTrue(log.read_until(generation, revision, 1.0))
        self.assertEqual(log.items[0]["item"], first)
        self.assertIsNot(log.items[0]["item"], first, "the log keeps its own copy")
        self.assertFalse(log.read_until(generation, revision + 1, 1.0), "a quiet stream times out")
        self.assertIsNone(log.end, "a timeout leaves the stream open")
        self.assertTrue(log.read_until(generation, revision + 1, 1.0))
        self.assertEqual(log.end, {"reason": "gap"}, "the end already queued is read with the item")
        self.assertFalse(log.read_until(generation, revision + 2, 1.0))
        record = log.record()
        self.assertEqual((record["name"], record["connection"], record["end"]), ("open", "viewer", {"reason": "gap"}))
        self.assertEqual([entry["sequence"] for entry in record["items"]], ["1", "5"])
        log.close()
        self.assertFalse(streams[0].canceled, "an ended stream is not canceled again")
        self.assertEqual(log.record()["end"], {"reason": "gap"}, "the reported end stays")
        self.assertEqual(_fold(record).revision, revision + 1)
        still_open = EventLog(FakeConnection())
        self.assertTrue(still_open.read_until(generation, revision, 1.0))
        still_open.close()
        self.assertTrue(streams[1].canceled)
        self.assertEqual(still_open.record()["end"], {"reason": ORACLE_TEARDOWN},
                         "the oracle's cancel is not a reported end (I8 reads it as open)")


def _wire_snapshot() -> Dict[str, Any]:
    import json

    path = REPO / "schemas" / "oracle" / "fixtures" / "wire" / "session.snapshot.json"
    return json.loads(path.read_text(encoding="utf-8"))["result"]


def main(argv: Optional[List[str]] = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv == ["--selftest"]:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(EventLogSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    print(__doc__.strip().splitlines()[-1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
