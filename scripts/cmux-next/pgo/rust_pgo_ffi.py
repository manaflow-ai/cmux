"""The cmux-app-ffi scenarios beyond the palette, the focus rules and motion (rust_pgo_scenarios.py ffi).

Every C ABI the app calls (the Swift sources name it and the library exports it) is driven here the way the app
drives it, so `-Cprofile-use` never sees a hot app path with zero counts (LLVM would then compile it as cold code,
optimized for size). coverage() checks that after the run.

  sidebar   the sidebar document mirror (SidebarMirror.swift): load, view, drag_begin, intents and the daemon's echo
            batches (confirm, stale, gapped then reload, rejected), through the typed calls the app uses.
  focus     the window focus machine (FocusMachine.swift): topology, every event kind, the history reads and a
            journal checkpoint (export, import).
  layout    the other reducer ops: the drop and drag resolvers on a laid-out sidebar, sidebar_layout_reduce on the
            shared app cases and tasks_preview on the Tasks pane's mirror.
  rd        the remote desktop core on loopback: the upstream sender's shards (the same packetizer and FEC as the
            host's) relabelled as host video into a receiver and a two-stream session on both carriers, with loss,
            NACKs, feedback back into the sender, input with its acks, and a bulk transfer with credit.
  rb        the remote tab client: the shared vectors of schemas/remote-tab/client.json.

Each answer is checked, so a wrong shape fails the run instead of training the profile on an error path.
"""
import ctypes
import json
import os
import re
import subprocess

OK = 0
ERR_STREAM = -7

U8P = ctypes.POINTER(ctypes.c_uint8)
SIZE_P = ctypes.POINTER(ctypes.c_size_t)


class ScenarioError(Exception):
    pass


def encode(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()


def load_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


# ---------- C types (the headers under cmux-tui/crates/*/include) ----------


class SidebarStrings(ctypes.Structure):
    _fields_ = [("bytes", U8P), ("offsets", ctypes.POINTER(ctypes.c_uint32)), ("count", ctypes.c_uint32)]


class SidebarRow(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "key", "kind", "section", "parent", "item", "ref_session", "ref_workspace")] + [
        ("depth", ctypes.c_uint8), ("flags", ctypes.c_uint8), ("reserved", ctypes.c_uint16)]


class SidebarRows(ctypes.Structure):
    _fields_ = [("ok", ctypes.c_uint8), ("rows", ctypes.POINTER(SidebarRow)), ("row_count", ctypes.c_uint32),
                ("strings", SidebarStrings)]


class SidebarAcceptance(ctypes.Structure):
    _fields_ = [("key", ctypes.c_uint32), ("refusal", ctypes.c_uint32), ("flags", ctypes.c_uint8),
                ("reserved", ctypes.c_uint8 * 3)]


class SidebarAcceptanceTable(ctypes.Structure):
    _fields_ = [("ok", ctypes.c_uint8), ("entries", ctypes.POINTER(SidebarAcceptance)), ("count", ctypes.c_uint32),
                ("strings", SidebarStrings)]


class SidebarReply(ctypes.Structure):
    _fields_ = [("ok", ctypes.c_uint8), ("stale", ctypes.c_uint8), ("refetch", ctypes.c_uint8),
                ("has_revision", ctypes.c_uint8), ("revision", ctypes.c_uint64),
                ("refusal", U8P), ("refusal_len", ctypes.c_size_t), ("ops", U8P), ("ops_len", ctypes.c_size_t)]


class FocusStr(ctypes.Structure):
    _fields_ = [("offset", ctypes.c_uint32), ("len", ctypes.c_uint32)]


FOCUS_NONE = 0xFFFFFFFF
NO_STR = FocusStr(FOCUS_NONE, 0)


class FocusEvent(ctypes.Structure):
    _fields_ = [("kind", ctypes.c_uint8), ("source", ctypes.c_uint8), ("target", ctypes.c_uint8),
                ("target_keyboard", ctypes.c_uint8), ("value", ctypes.c_uint8), ("reserved", ctypes.c_uint8 * 3),
                ("list_count", ctypes.c_uint32), ("reserved2", ctypes.c_uint32), ("generation", ctypes.c_uint64),
                ("a", FocusStr), ("b", FocusStr), ("c", FocusStr), ("list", ctypes.POINTER(FocusStr))]


class FocusTab(ctypes.Structure):
    _fields_ = [("id", FocusStr), ("surface", FocusStr), ("kind", ctypes.c_uint32), ("reserved", ctypes.c_uint32)]


class FocusPane(ctypes.Structure):
    _fields_ = [("id", FocusStr), ("selected", FocusStr), ("tab_start", ctypes.c_uint32),
                ("tab_count", ctypes.c_uint32)]


class FocusColumn(ctypes.Structure):
    _fields_ = [("id", FocusStr), ("screen", ctypes.c_uint32), ("pane_start", ctypes.c_uint32),
                ("pane_count", ctypes.c_uint32), ("reserved", ctypes.c_uint32)]


class FocusTopology(ctypes.Structure):
    _fields_ = [("workspace", FocusStr), ("panes", ctypes.POINTER(FocusPane)), ("tabs", ctypes.POINTER(FocusTab)),
                ("columns", ctypes.POINTER(FocusColumn)), ("column_panes", ctypes.POINTER(FocusStr)),
                ("pane_count", ctypes.c_uint32), ("tab_count", ctypes.c_uint32), ("column_count", ctypes.c_uint32),
                ("column_pane_count", ctypes.c_uint32), ("screen_count", ctypes.c_uint32),
                ("reserved", ctypes.c_uint32)]


class FocusResolved(ctypes.Structure):
    _fields_ = [("kind", ctypes.c_uint8), ("overlay", ctypes.c_uint8), ("reserved", ctypes.c_uint8 * 6),
                ("pane", FocusStr), ("tab", FocusStr)]


class FocusEffect(ctypes.Structure):
    _fields_ = [("kind", ctypes.c_uint8), ("context", ctypes.c_uint8), ("active", ctypes.c_uint8),
                ("reserved", ctypes.c_uint8 * 5), ("pane", FocusStr), ("tab", FocusStr), ("resolved", FocusResolved)]


class FocusReply(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint8) for name in (
        "ok", "changed", "window_key", "app_active", "sidebar_hidden", "target", "target_keyboard", "context",
        "browser_focus_mode_active", "dragging", "has_expectation", "expectation_key", "expectation_target",
        "expectation_target_keyboard")] + [
        ("reserved", ctypes.c_uint8 * 2), ("generation", ctypes.c_uint64),
        ("expectation_generation", ctypes.c_uint64), ("pane", FocusStr), ("workspace", FocusStr),
        ("expectation_id", FocusStr), ("expectation_away_from", FocusStr), ("resolved", FocusResolved),
        ("underlying", FocusResolved), ("overlays", U8P), ("effects", ctypes.POINTER(FocusEffect)),
        ("strings", U8P), ("overlay_count", ctypes.c_uint32), ("effect_count", ctypes.c_uint32),
        ("strings_len", ctypes.c_uint32), ("reserved2", ctypes.c_uint32)]


class FocusStrings(ctypes.Structure):
    _fields_ = [("items", ctypes.POINTER(FocusStr)), ("bytes", U8P), ("count", ctypes.c_uint32),
                ("bytes_len", ctypes.c_uint32)]


class RdFrame(ctypes.Structure):
    _fields_ = [("t_capture_us", ctypes.c_uint64), ("data", U8P), ("len", ctypes.c_size_t),
                ("frame", ctypes.c_uint32), ("ref_frame", ctypes.c_uint32), ("flags", ctypes.c_uint8)]


class RdMessage(ctypes.Structure):
    _fields_ = [("data", U8P), ("len", ctypes.c_size_t), ("kind", ctypes.c_uint8)]


class RdStats(ctypes.Structure):
    _fields_ = [("frames_released", ctypes.c_uint64), ("frames_lost", ctypes.c_uint64),
                ("acked_frame", ctypes.c_uint32), ("need_recovery", ctypes.c_bool)]


class RdInputEvent(ctypes.Structure):
    _fields_ = [("kind", ctypes.c_uint32), ("usage", ctypes.c_uint32), ("x", ctypes.c_int32), ("y", ctypes.c_int32),
                ("dx", ctypes.c_int32), ("dy", ctypes.c_int32), ("text", ctypes.c_char_p),
                ("text_len", ctypes.c_size_t), ("button", ctypes.c_uint8), ("down", ctypes.c_uint8),
                ("precise", ctypes.c_uint8), ("service_flags", ctypes.c_uint8)]


class RdUpstreamStats(ctypes.Structure):
    _fields_ = [("frames_sent", ctypes.c_uint64), ("frames_dropped", ctypes.c_uint64),
                ("acked_frame", ctypes.c_uint32), ("loss_ppm", ctypes.c_uint32),
                ("keyframe_requested", ctypes.c_bool), ("consent", ctypes.c_bool)]


class RdBulkChunk(ctypes.Structure):
    _fields_ = [("transfer", ctypes.c_uint64), ("offset", ctypes.c_uint64), ("bytes", U8P),
                ("len", ctypes.c_size_t)]


def bind(lib):
    """Declares the C signatures these scenarios call."""
    vp, u8, u16, u32, u64, i32 = (ctypes.c_void_p, ctypes.c_uint8, ctypes.c_uint16, ctypes.c_uint32,
                                  ctypes.c_uint64, ctypes.c_int32)
    # Byte inputs are void pointers: they take Python bytes and the pointers in replies (a message's data).
    size, b, cp = ctypes.c_size_t, ctypes.c_bool, ctypes.c_void_p
    p = ctypes.POINTER
    sigs = {
        "cmux_layout_reducer_ffi_abi_version": (u32, []),
        "cmux_sidebar_mirror_new": (vp, []),
        "cmux_sidebar_mirror_free": (None, [vp]),
        "cmux_sidebar_mirror_load_typed": (p(SidebarReply), [vp, cp, size]),
        "cmux_sidebar_mirror_apply_batch_typed": (p(SidebarReply), [vp, cp, size]),
        "cmux_sidebar_mirror_apply_intent_typed": (p(SidebarReply), [vp, cp, size]),
        "cmux_sidebar_mirror_view_typed": (p(SidebarRows), [vp, cp, size]),
        "cmux_sidebar_mirror_drag_begin_typed": (p(SidebarAcceptanceTable), [vp, cp, size]),
        "cmux_focus_new": (vp, []),
        "cmux_focus_free": (None, [vp]),
        "cmux_focus_send": (p(FocusReply), [vp, p(FocusEvent), cp, size]),
        "cmux_focus_set_topology": (p(FocusReply), [vp, p(FocusTopology), cp, size]),
        "cmux_focus_current": (p(FocusReply), [vp]),
        "cmux_focus_set_close_focus": (None, [vp, u8]),
        "cmux_focus_changes_view": (u8, [p(FocusEvent), cp, size]),
        "cmux_focus_recent_panes": (p(FocusStrings), [vp, cp, size, u8]),
        "cmux_focus_remembered": (p(FocusStrings), [vp]),
        "cmux_focus_export_json": (ctypes.POINTER(ctypes.c_char), [vp]),
        "cmux_focus_import_json": (i32, [vp, cp, size]),
        "cmux_focus_string_free": (None, [ctypes.POINTER(ctypes.c_char)]),
        "cmux_rd_ffi_abi_version": (u32, []),
        "cmux_rd_receiver_new": (vp, [u32, u64, u64]),
        "cmux_rd_receiver_free": (None, [vp]),
        "cmux_rd_receiver_push_datagram": (i32, [vp, cp, size, u64]),
        "cmux_rd_receiver_push_stream": (i32, [vp, cp, size, u64]),
        "cmux_rd_receiver_tick": (i32, [vp, u64]),
        "cmux_rd_receiver_pop_frame": (i32, [vp, p(RdFrame)]),
        "cmux_rd_receiver_pop_message": (i32, [vp, p(RdMessage)]),
        "cmux_rd_receiver_note_decode": (i32, [vp, u32]),
        "cmux_rd_receiver_request_keyframe": (i32, [vp]),
        "cmux_rd_receiver_feedback": (i32, [vp, u64, vp, size, SIZE_P]),
        "cmux_rd_receiver_next_deadline_us": (u64, [vp]),
        "cmux_rd_receiver_stats": (i32, [vp, p(RdStats)]),
        "cmux_rd_encode_stream_frame": (i32, [u32, cp, size, vp, size, SIZE_P]),
        "cmux_rd_input_new": (vp, [u32, u64]),
        "cmux_rd_input_free": (None, [vp]),
        "cmux_rd_input_push": (i32, [vp, p(RdInputEvent), p(u32)]),
        "cmux_rd_input_ack": (i32, [vp, cp, size]),
        "cmux_rd_input_packet": (i32, [vp, u64, vp, size, SIZE_P]),
        "cmux_rd_input_next_deadline_us": (u64, [vp]),
        "cmux_rd_session_new": (vp, [u32, u64, u64]),
        "cmux_rd_session_free": (None, [vp]),
        "cmux_rd_session_open_stream": (i32, [vp, u16]),
        "cmux_rd_session_close_stream": (i32, [vp, u16]),
        "cmux_rd_session_push_datagram": (i32, [vp, cp, size, u64]),
        "cmux_rd_session_push_stream": (i32, [vp, cp, size, u64]),
        "cmux_rd_session_tick": (i32, [vp, u64]),
        "cmux_rd_session_pop_frame": (i32, [vp, p(RdFrame), p(u16)]),
        "cmux_rd_session_pop_message": (i32, [vp, p(RdMessage)]),
        "cmux_rd_session_note_decode": (i32, [vp, u16, u32]),
        "cmux_rd_session_request_keyframe": (i32, [vp, u16]),
        "cmux_rd_session_feedback": (i32, [vp, u64, vp, size, SIZE_P]),
        "cmux_rd_session_next_deadline_us": (u64, [vp]),
        "cmux_rd_session_stats": (i32, [vp, u16, p(RdStats)]),
        "cmux_rd_upstream_new": (vp, [u32, u16, u32, u32, u32, u64, u64, u64, b]),
        "cmux_rd_upstream_free": (None, [vp]),
        "cmux_rd_upstream_set_consent": (i32, [vp, u32, b]),
        "cmux_rd_upstream_send_frame": (i32, [vp, cp, size, u64, b, u64]),
        "cmux_rd_upstream_on_datagram": (i32, [vp, cp, size, u64]),
        "cmux_rd_upstream_pop_datagram": (i32, [vp, vp, size, SIZE_P]),
        "cmux_rd_upstream_set_path": (i32, [vp, u32]),
        "cmux_rd_upstream_stats": (i32, [vp, p(RdUpstreamStats)]),
        "cmux_rd_bulk_sender_new": (vp, [u64]),
        "cmux_rd_bulk_sender_free": (None, [vp]),
        "cmux_rd_bulk_sender_queue": (i32, [vp, u64, cp, size]),
        "cmux_rd_bulk_sender_on_credit": (i32, [vp, u64, u64]),
        "cmux_rd_bulk_sender_on_control": (i32, [vp, cp, size]),
        "cmux_rd_bulk_sender_cancel": (i32, [vp, u64]),
        "cmux_rd_bulk_sender_pop_frame": (i32, [vp, u64, b, vp, size, SIZE_P]),
        "cmux_rd_bulk_sender_next_deadline_us": (u64, [vp]),
        "cmux_rd_bulk_sender_queued_bytes": (u64, [vp]),
        "cmux_rd_bulk_receiver_new": (vp, []),
        "cmux_rd_bulk_receiver_free": (None, [vp]),
        "cmux_rd_bulk_receiver_accept": (i32, [vp, cp, size, p(RdBulkChunk), vp, size, SIZE_P]),
        "cmux_rd_bulk_receiver_finish": (i32, [vp, u64]),
        "cmux_rb_client_new": (vp, []),
        "cmux_rb_client_free": (None, [vp]),
        "cmux_rb_client_apply": (i32, [vp, cp, size, p(U8P), SIZE_P]),
    }
    for name, (restype, argtypes) in sigs.items():
        fn = getattr(lib, name)
        fn.restype = restype
        fn.argtypes = argtypes
    return lib


def reducer_json(lib, operation, request):
    """One cmux_layout_reducer_json call (bound by rust_pgo_scenarios.bind)."""
    body = encode(request)
    capacity = 1 << 16
    while True:
        output = ctypes.create_string_buffer(capacity)
        length = ctypes.c_size_t(0)
        code = lib.cmux_layout_reducer_json(body, len(body), operation.encode(), output, capacity,
                                            ctypes.byref(length))
        if code == -3 and length.value > capacity:
            capacity = length.value
            continue
        if code != OK:
            raise ScenarioError(f"{operation}: code {code} for {body[:200]!r}")
        return json.loads(output.raw[:length.value])


# ---------- the sidebar document mirror ----------

DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
SESSION = "sess_local"


def order_key(index):
    """A valid fractional order key (base 62, no trailing 0) that sorts by index."""
    return DIGITS[1 + index // 60] + DIGITS[1 + index % 60]


def workspace_item(index, section="sec_machine", parent=None, order=None):
    item = {"id": f"itm_w_{SESSION}_ws{index}", "section": section, "order": order or order_key(index),
            "body": {"type": "workspace", "ref": {"session_id": SESSION, "workspace_id": f"ws{index}"}}}
    if parent:
        item["parent"] = parent
    return item


def sidebar_doc(workspaces):
    sections = [
        {"id": "sec_pinned", "kind": {"type": "pinned"}, "order": "1", "keeps_closed": True},
        {"id": "sec_machine", "kind": {"type": "machine", "session_id": SESSION}, "order": "2"},
        {"id": "sec_custom", "kind": {"type": "custom"}, "title": "Work", "order": "3", "keeps_closed": True},
    ]
    group = {"id": "itm_group_build", "section": "sec_machine", "order": order_key(workspaces),
             "body": {"type": "group", "name": "Build", "color": "#3366ff"}}
    items = [workspace_item(i) for i in range(workspaces)]
    items.append(group)
    items += [workspace_item(workspaces + i, parent=group["id"], order=order_key(i)) for i in range(4)]
    items.append({"id": "itm_url_docs", "section": "sec_custom", "order": "V",
                  "body": {"type": "url", "url": "https://cmux.com/docs", "title": "Docs"}})
    return {"revision": "1", "sections": sections, "items": items}


def typed_reply(pointer, what):
    if not pointer:
        raise ScenarioError(f"sidebar {what}: null reply")
    reply = pointer.contents
    refusal = ctypes.string_at(reply.refusal, reply.refusal_len).decode() if reply.refusal else ""
    ops = ctypes.string_at(reply.ops, reply.ops_len) if reply.ops else b""
    return reply, refusal, ops


def sidebar(lib, workspaces=40):
    calls = 0
    mirror = lib.cmux_sidebar_mirror_new()
    if not mirror:
        raise ScenarioError("cmux_sidebar_mirror_new returned null")

    def call(fn, value):
        nonlocal calls
        calls += 1
        body = encode(value)
        return fn(mirror, body, len(body))

    def load(doc):
        reply, refusal, _ = typed_reply(call(lib.cmux_sidebar_mirror_load_typed, doc), "load")
        if not reply.ok or refusal:
            raise ScenarioError(f"sidebar load refused: {refusal}")
        return reply.revision

    live = [{"session_id": SESSION, "workspace_id": f"ws{i}", "title": f"workspace {i}"}
            for i in range(workspaces + 6)]  # two live workspaces have no item yet

    def view(**extra):
        request = dict({"live": live, "window": {}}, **extra)
        rows = call(lib.cmux_sidebar_mirror_view_typed, request)
        if not rows or not rows.contents.ok or rows.contents.row_count == 0:
            raise ScenarioError(f"sidebar view {extra} drew nothing")
        return rows.contents.row_count

    def intent(key, ops, expect_ok=True):
        reply, refusal, stamped = typed_reply(call(lib.cmux_sidebar_mirror_apply_intent_typed,
                                                   {"idempotency_key": key, "ops": ops}), "intent")
        if expect_ok and (not reply.ok or refusal):
            raise ScenarioError(f"sidebar intent {ops} refused: {refusal}")
        return json.loads(stamped) if stamped else None

    def batch(value, expect):
        reply, refusal, _ = typed_reply(call(lib.cmux_sidebar_mirror_apply_batch_typed, value), "batch")
        got = "refetch" if reply.refetch else "stale" if reply.stale else "ok" if reply.ok else refusal or "error"
        if got != expect:
            raise ScenarioError(f"sidebar batch answered {got}, expected {expect}: {value}")
        return reply

    def marker(revision, key=None):
        value = {"revision": str(revision), "previous_revision": str(revision - 1)}
        if key:
            value["idempotency_key"] = key
        return {"kind": "state_upsert", "resource": "sidebar_doc", "id": "doc", "value": value}

    def upsert(item):
        return {"kind": "state_upsert", "resource": "sidebar_item", "id": item["id"], "value": item}

    try:
        doc = sidebar_doc(workspaces)
        revision = load(doc)
        view()
        view(collapsed=["itm_group_build"])
        view(filter="workspace 1")
        dragged = [f"itm_w_{SESSION}_ws{i}" for i in (3, 4)]
        table = call(lib.cmux_sidebar_mirror_drag_begin_typed, {"items": dragged})
        if not table or not table.contents.ok or table.contents.count == 0:
            raise ScenarioError("sidebar drag_begin answered no acceptance table")
        # A drag reorders within the section; the daemon echoes the moved row with its new order key.
        for step in range(8):
            moved = workspace_item(step, order=order_key(workspaces + 10 + step))
            key = f"move-{step}"
            intent(key, [{"op": "move", "items": [moved["id"]], "to": {"section": "sec_machine",
                                                                      "after": f"itm_w_{SESSION}_ws{workspaces - 1}"}}])
            view()
            revision += 1
            batch({"changes": [upsert(moved), marker(revision, key)]}, "ok")
        # Pin, group, archive and add as intents, each confirmed by its echo (marker only: the row values are the
        # daemon's, the mirror keeps showing the pending result until the echo drops it).
        for key, ops in (
            ("pin", [{"op": "pin", "items": [f"itm_w_{SESSION}_ws10"]}]),
            ("group", [{"op": "group.create", "name": "Review", "items": [f"itm_w_{SESSION}_ws11",
                                                                         f"itm_w_{SESSION}_ws12"]}]),
            ("archive", [{"op": "archive", "items": [f"itm_w_{SESSION}_ws13"]}]),
            ("adopt", [{"op": "adopt", "refs": [{"session_id": SESSION, "workspace_id": f"ws{workspaces + 4}"}]}]),
            ("add", [{"op": "item.add", "item": {"body": {"type": "url", "url": "https://example.com"}},
                      "to": {"section": "sec_custom"}}]),
            ("collapse", [{"op": "group.update", "id": "itm_group_build", "patch": {"collapsed": True}}]),
        ):
            intent(key, ops)
            view()
            call(lib.cmux_sidebar_mirror_drag_begin_typed, {"items": [f"itm_w_{SESSION}_ws20"]})
        for key in ("pin", "group", "archive"):
            revision += 1
            batch({"changes": [marker(revision, key)]}, "ok")
        batch({"idempotency_key": "adopt", "rejected": True}, "ok")
        # A late echo is stale; a gap makes the app refetch and load again (pending intents replay).
        batch({"changes": [marker(revision)]}, "stale")
        batch({"changes": [marker(revision + 2)]}, "refetch")
        doc["revision"] = str(revision + 2)
        revision = load(doc)
        view()
        # An unknown item is refused, as the app shows it.
        intent("bad", [{"op": "move", "items": ["itm_missing"], "to": {"section": "sec_machine"}}], expect_ok=False)
    finally:
        lib.cmux_sidebar_mirror_free(mirror)
    return calls


# ---------- the window focus machine ----------


class Strings:
    """The byte buffer and ranges of one focus call."""

    def __init__(self):
        self.data = bytearray()

    def add(self, text):
        if text is None:
            return NO_STR
        raw = text.encode()
        start = len(self.data)
        self.data += raw
        return FocusStr(start, len(raw))

    def raw(self):
        return bytes(self.data)


def focus_topology(panes, workspace):
    """panes: [(pane id, [(tab id, kind)])] in two columns on one screen."""
    strings = Strings()
    tab_list, pane_list = [], []
    for pane_id, tabs in panes:
        start = len(tab_list)
        for tab_id, kind in tabs:
            tab_list.append(FocusTab(strings.add(tab_id), strings.add(f"surf-{tab_id}"), kind, 0))
        pane_list.append(FocusPane(strings.add(pane_id), strings.add(tabs[0][0]), start, len(tabs)))
    half = (len(panes) + 1) // 2
    column_panes = [strings.add(pane_id) for pane_id, _ in panes]
    columns = [FocusColumn(strings.add("col-a"), 0, 0, half, 0)]
    if len(panes) > half:
        columns.append(FocusColumn(strings.add("col-b"), 0, half, len(panes) - half, 0))
    keep = (
        (FocusPane * len(pane_list))(*pane_list), (FocusTab * len(tab_list))(*tab_list),
        (FocusColumn * len(columns))(*columns), (FocusStr * len(column_panes))(*column_panes),
    )
    topology = FocusTopology(strings.add(workspace), keep[0], keep[1], keep[2], keep[3], len(pane_list),
                             len(tab_list), len(columns), len(column_panes), 1, 0)
    return topology, strings.raw(), keep


def focus_event(kind, a=None, b=None, c=None, source=1, target=0, keyboard=0, value=0, generation=0, items=()):
    strings = Strings()
    ranges = (FocusStr * max(1, len(items)))(*[strings.add(item) for item in items])
    event = FocusEvent(kind=kind, source=source, target=target, target_keyboard=keyboard, value=value,
                       list_count=len(items), generation=generation, a=strings.add(a), b=strings.add(b),
                       c=strings.add(c), list=ranges)
    return event, strings.raw(), ranges


def focus_machine(lib):
    calls = 0
    panes = [("pane-1", [("tab-1", 0), ("tab-2", 1)]), ("pane-2", [("tab-3", 2), ("tab-4", 4)]),
             ("pane-3", [("tab-5", 3)]), ("pane-4", [("tab-6", 0), ("tab-7", 5)])]
    machine = lib.cmux_focus_new()
    if not machine:
        raise ScenarioError("cmux_focus_new returned null")
    try:
        def checked(reply, what):
            nonlocal calls
            calls += 1
            if not reply or not reply.contents.ok:
                raise ScenarioError(f"focus {what} did not apply")
            return reply.contents

        def send(*args, **kwargs):
            event, raw, keep = focus_event(*args, **kwargs)
            lib.cmux_focus_changes_view(ctypes.byref(event), raw, len(raw))
            checked(lib.cmux_focus_send(machine, ctypes.byref(event), raw, len(raw)), f"event {args}")
            del keep

        lib.cmux_focus_set_close_focus(machine, 0)
        for workspace in ("ws-a", "ws-b"):
            topology, raw, keep = focus_topology(panes, workspace)
            checked(lib.cmux_focus_set_topology(machine, ctypes.byref(topology), raw, len(raw)), "topology")
            del keep
            send(4, value=1)  # window key
            send(5, value=1)  # app active
            send(15, a="pane-1", c=workspace)  # restored pane
            for index in range(24):
                pane_id, tabs = panes[index % len(panes)]
                send(0, a=pane_id, c=workspace, source=index % 5)  # focus pane
                send(1, a=pane_id, b=tabs[-1][0], c=workspace)  # select tab
                send(12, a=pane_id)  # content presented
                send(3, a=pane_id, value=index % 4)  # responder: content, address bar, find bar, dev tools
            send(2, target=1)  # focus the address bar
            send(2, target=4, keyboard=1)  # the sidebar, from the keyboard
            send(2, target=0)
            for overlay in range(4):
                send(6, value=overlay)
                send(7, value=overlay)
            send(8)  # begin intent
            send(9, a="surf-tab-3", target=0, generation=7)  # expect a surface
            send(0, a="pane-2", c=workspace)
            send(10, a="pane-2", items=("tab-3",))  # drag began
            send(11, value=1, items=("tab-3",), b="pane-2")  # dropped
            send(10, a="pane-1", items=("tab-2",))
            send(11, value=0)  # cancelled
            send(13, a="tab-2")  # browser focus mode
            send(13, a="tab-2")
            send(14, value=1)
            send(14, value=0)
            send(3, value=7)  # window or none
            send(4, value=0)
            send(4, value=1)
        # A pane closes: the topology without it moves focus by the close policy.
        lib.cmux_focus_set_close_focus(machine, 1)
        topology, raw, keep = focus_topology(panes[:3], "ws-b")
        checked(lib.cmux_focus_set_topology(machine, ctypes.byref(topology), raw, len(raw)), "closed pane")
        del keep
        checked(lib.cmux_focus_current(machine), "current")
        for workspace in (b"ws-a", None):
            recent = lib.cmux_focus_recent_panes(machine, workspace, len(workspace or b""), 1 if workspace else 0)
            if not recent or recent.contents.count == 0:
                raise ScenarioError("cmux_focus_recent_panes is empty after focus changes")
        if not lib.cmux_focus_remembered(machine) or lib.cmux_focus_remembered(machine).contents.count == 0:
            raise ScenarioError("cmux_focus_remembered is empty after focus changes")
        # A journal checkpoint replays into a new machine.
        exported = lib.cmux_focus_export_json(machine)
        if not exported:
            raise ScenarioError("cmux_focus_export_json returned null")
        text = ctypes.string_at(exported)
        lib.cmux_focus_string_free(exported)
        restored = lib.cmux_focus_new()
        try:
            if lib.cmux_focus_import_json(restored, text, len(text)) != OK:
                raise ScenarioError("cmux_focus_import_json refused its own export")
            checked(lib.cmux_focus_current(restored), "imported current")
        finally:
            lib.cmux_focus_free(restored)
        calls += 6
    finally:
        lib.cmux_focus_free(machine)
    return calls


# ---------- the other reducer ops ----------


def drop_layout(workspaces=24):
    """The drop resolvers' rows and sections: Pinned, then a machine section with a group (as DropResolver.swift
    sends them)."""
    pinned, machine = {"kind": "pinned"}, {"kind": "machine", "id": SESSION}
    rows, y = [], 0.0

    def row(key, section, height=28.0, **fields):
        nonlocal y
        base = {"key": key, "y": y, "height": height, "section": section, "group": None, "workspace": None,
                "sibling_index": 0, "parent_index": None, "is_last_in_group": False, "is_collapsed": False,
                "child_count": 0}
        base.update(fields)
        rows.append(base)
        y += height

    row({"kind": "section", "id": pinned}, pinned, 24.0)
    row({"kind": "workspace", "id": "ws-pinned"}, pinned, workspace="ws-pinned")
    row({"kind": "section", "id": machine}, machine, 24.0)
    loose = [f"ws{i}" for i in range(workspaces)]
    grouped = ["ws-g1", "ws-g2", "ws-g3"]
    for index, ws in enumerate(loose[:workspaces // 2]):
        row({"kind": "workspace", "id": ws}, machine, workspace=ws, sibling_index=index)
    group_index = workspaces // 2
    row({"kind": "group", "id": "grp"}, machine, group="grp", sibling_index=group_index, child_count=len(grouped))
    for index, ws in enumerate(grouped):
        row({"kind": "workspace", "id": ws}, machine, group="grp", workspace=ws, sibling_index=index,
            parent_index=group_index, is_last_in_group=index == len(grouped) - 1)
        row({"kind": "tab", "workspace": ws, "id": f"{ws}-tab"}, machine, 22.0, group="grp", workspace=ws)
    for index, ws in enumerate(loose[workspaces // 2:]):
        row({"kind": "workspace", "id": ws}, machine, workspace=ws, sibling_index=group_index + 1 + index)
    nodes = [{"kind": "workspace", "workspace": {"id": ws, "machine": SESSION}} for ws in loose[:workspaces // 2]]
    nodes.append({"kind": "group", "id": "grp", "machine": SESSION,
                  "workspaces": [{"id": ws, "machine": SESSION} for ws in grouped]})
    nodes += [{"kind": "workspace", "workspace": {"id": ws, "machine": SESSION}} for ws in loose[workspaces // 2:]]
    sections = [
        {"id": pinned, "machine": None, "nodes": [{"kind": "workspace", "workspace": {"id": "ws-pinned",
                                                                                      "machine": SESSION}}]},
        {"id": machine, "machine": SESSION, "nodes": nodes},
    ]
    return rows, sections, y


TASKS_ME = "usr_pgo"


def tasks_mirror():
    """The Tasks pane's mirror, as the Swift pane holds it (cmux-layout-reducer-ffi/tests/tasks_preview.rs)."""
    statuses = [
        {"id": "st_backlog", "name": "Backlog", "category": "backlog", "position": 1, "color": 8},
        {"id": "st_todo", "name": "Todo", "category": "unstarted", "position": 2, "color": 7},
        {"id": "st_in_progress", "name": "In Progress", "category": "started", "position": 3, "color": 3},
    ]
    tasks = [{"id": f"task_{i}", "key": f"CMX-{i}", "number": i, "title": f"Task {i}",
              "status": statuses[i % 3]["id"], "category": statuses[i % 3]["category"],
              "priority": ("high", "none", "low")[i % 3], "labels": ["lbl_bug"] if i % 4 == 0 else [],
              "sort_key": order_key(i), "updated_at": i, "archived": False, "deleted": False,
              "assignee": {"kind": "user", "id": TASKS_ME}} for i in range(1, 31)]
    return {"seq": 30, "me": {"kind": "user", "id": TASKS_ME}, "settings": {"key_prefix": "CMX"},
            "statuses": statuses, "labels": [{"id": "lbl_bug", "name": "bug", "color": 1, "archived": False}],
            "projects": [{"id": "prj_app", "name": "App", "archived": False}], "tasks": tasks, "sessions": []}


def layout(lib, layout_cases):
    calls = 0
    rows, sections, height = drop_layout()
    common = {"rows": rows, "sections": sections, "group_edge_fraction": 0.25, "group_exit_fraction": 0.25,
              "section_top_fraction": 0.35}
    payloads = ({"kind": "workspaces", "ids": ["ws2"]}, {"kind": "workspaces", "ids": ["ws3", "ws-g2"]},
                {"kind": "group", "id": "grp"})
    y = 0.0
    while y < height:  # a drag sweeps the list
        for payload in payloads:
            request = dict(common, y=y, payload=payload, workspace_onto_start=0.3, workspace_onto_end=0.7)
            reducer_json(lib, "resolve", request)
            reducer_json(lib, "resolve_drag", dict(request, centre_y=y + 14.0, leading_y=y, gap_y=height / 2,
                                                   gap_height=28.0))
            calls += 2
        reducer_json(lib, "base_y", {"display_y": y, "gap_y": height / 2, "gap_height": 28.0})
        for machine in (SESSION, "sess_remote"):
            tab = dict(common, y=y, source_machine=machine, reorders_tab_rows=True)
            reducer_json(lib, "tab_drop", tab)
            reducer_json(lib, "tab_refusal", tab)
            calls += 2
        calls += 1
        y += 7.0
    defaults = reducer_json(lib, "sidebar_layout_reduce", {"document": {"revision": 0, "sections": []},
                                                           "op": {"kind": "layout.reset"}})
    if "document" not in defaults:
        raise ScenarioError(f"sidebar_layout_reduce layout.reset answered {defaults}")
    document = defaults["document"]
    for case in layout_cases["cases"]:
        reply = reducer_json(lib, "sidebar_layout_reduce", {"document": document, "op": case["op"]})
        calls += 1
        if case["expect"] == "accept" and "reject" in reply:
            raise ScenarioError(f"sidebar_layout_reduce {case['name']}: rejected {reply['reject']}")
        if case["expect"] == "reject" and reply.get("reject") != case["reason"]:
            raise ScenarioError(f"sidebar_layout_reduce {case['name']}: answered {reply}")
    mirror = tasks_mirror()
    intents = []
    for step in range(12):
        task = f"task_{step + 1}"
        intents.append(({"key": f"k{step}-move", "op": "task.move", "params": {"task": task, "before": "task_1"}},
                        {"key": f"k{step}-status", "op": "task.update",
                         "params": {"task": task, "status": "st_in_progress"}},
                        {"key": f"k{step}-create", "op": "task.create",
                         "params": {"id": f"task_new_{step}", "title": "New"}})[step % 3])
        preview = reducer_json(lib, "tasks_preview", {"mirror": mirror, "intents": intents, "now": 5})
        if len(preview.get("tasks", [])) < 30:
            raise ScenarioError(f"tasks_preview answered {str(preview)[:200]}")
        calls += 1
    return calls


# ---------- the remote desktop core ----------

CARRIER_DATAGRAM, CARRIER_STREAM = 0, 1
KIND_VIDEO, KIND_FEC, KIND_INPUT_ACK = 1, 2, 5
MESSAGE_CONTROL, MESSAGE_DATAGRAM, MESSAGE_BULK = 1, 2, 3
MEDIA_SCREEN = 3
FRAME_US = 16_667


def as_host_video(datagram):
    """An upstream shard (UpMedia) relabelled as the host's video (data) or parity shard: the same header,
    packetizer and FEC."""
    raw = bytearray(datagram)
    index = int.from_bytes(raw[8:10], "little")
    count = int.from_bytes(raw[10:12], "little")
    raw[1] = KIND_VIDEO if index < count else KIND_FEC
    return bytes(raw)


def input_ack(seq):
    header = bytes([0x10, KIND_INPUT_ACK]) + bytes(14)
    return header + seq.to_bytes(4, "little")


class Rd:
    def __init__(self, lib):
        self.lib = lib
        self.buffer = ctypes.create_string_buffer(1 << 17)
        self.length = ctypes.c_size_t(0)
        self.calls = 0

    def drain(self, fn, *args):
        """Calls a writer (feedback, packet, pop_datagram) until it returns 0; returns the bytes it wrote."""
        out = []
        while True:
            self.calls += 1
            code = fn(*args, self.buffer, len(self.buffer), ctypes.byref(self.length))
            if code == 0:
                return out
            if code != 1:
                raise ScenarioError(f"{fn.__name__} returned {code}")
            out.append(self.buffer.raw[:self.length.value])

    def stream_frame(self, kind, payload):
        code = self.lib.cmux_rd_encode_stream_frame(kind, payload, len(payload), self.buffer, len(self.buffer),
                                                     ctypes.byref(self.length))
        if code != OK:
            raise ScenarioError(f"cmux_rd_encode_stream_frame returned {code}")
        return self.buffer.raw[:self.length.value]


def frame_bytes(frame, size):
    return bytes((i * 31 + frame) & 0xFF for i in range(size))


def rd_upstream(lib, stream, carrier=CARRIER_DATAGRAM):
    upstream = lib.cmux_rd_upstream_new(carrier, stream, MEDIA_SCREEN, 1152, 1, 0, 0, 0, True)
    if not upstream:
        raise ScenarioError("cmux_rd_upstream_new returned null")
    if lib.cmux_rd_upstream_send_frame(upstream, b"x", 1, 0, True, 0) != -8:
        raise ScenarioError("an upstream sender without consent sent")
    if lib.cmux_rd_upstream_set_consent(upstream, MEDIA_SCREEN, True) != OK:
        raise ScenarioError("cmux_rd_upstream_set_consent refused")
    lib.cmux_rd_upstream_set_path(upstream, 1)
    return upstream


def rd_receiver(lib, rd, frames=120):
    """One display stream over the datagram carrier: frames with loss in, NACK resends and feedback back."""
    upstream = rd_upstream(lib, 0)
    receiver = lib.cmux_rd_receiver_new(CARRIER_DATAGRAM, 200_000, 5_000)
    inp = lib.cmux_rd_input_new(CARRIER_DATAGRAM, 30_000)
    stats, up_stats, frame_out, message = RdStats(), RdUpstreamStats(), RdFrame(), RdMessage()
    released = sent = 0
    try:
        now = 1_000_000
        for index in range(frames):
            now += FRAME_US
            keyframe = index % 60 == 0
            size = 24_000 if keyframe else 2_000 + (index * 97) % 4_000
            data = frame_bytes(index, size)
            if lib.cmux_rd_upstream_send_frame(upstream, data, len(data), now - 3_000, keyframe, now) > 0:
                sent += 1
            for number, datagram in enumerate(rd.drain(lib.cmux_rd_upstream_pop_datagram, upstream)):
                if (index * 7 + number) % 13 == 5:
                    continue  # lost on the path
                code = lib.cmux_rd_receiver_push_datagram(receiver, *bytes_args(as_host_video(datagram)), now)
                if code < 0:
                    raise ScenarioError(f"cmux_rd_receiver_push_datagram returned {code}")
            lib.cmux_rd_receiver_tick(receiver, now)
            while lib.cmux_rd_receiver_pop_frame(receiver, ctypes.byref(frame_out)) == 1:
                released += 1
                lib.cmux_rd_receiver_note_decode(receiver, 900 + index % 300)
            # Input goes out; the host's ack comes back through the receiver as a datagram message.
            event = RdInputEvent(kind=2, x=index * 3, y=index * 2)
            seq = ctypes.c_uint32(0)
            lib.cmux_rd_input_push(inp, ctypes.byref(event), ctypes.byref(seq))
            if index % 10 == 0:
                key = RdInputEvent(kind=1, usage=(7 << 16) | 4, down=1)
                lib.cmux_rd_input_push(inp, ctypes.byref(key), ctypes.byref(seq))
                text = b"hello"
                typed = RdInputEvent(kind=5, text=text, text_len=len(text))
                lib.cmux_rd_input_push(inp, ctypes.byref(typed), ctypes.byref(seq))
            rd.drain(lib.cmux_rd_input_packet, inp, now)
            lib.cmux_rd_input_next_deadline_us(inp)
            ack = input_ack(seq.value)
            lib.cmux_rd_receiver_push_datagram(receiver, ack, len(ack), now)
            while lib.cmux_rd_receiver_pop_message(receiver, ctypes.byref(message)) == 1:
                if message.kind == MESSAGE_DATAGRAM:
                    lib.cmux_rd_input_ack(inp, message.data, message.len)
            if index % 40 == 39:
                lib.cmux_rd_receiver_request_keyframe(receiver)
            for feedback in rd.drain(lib.cmux_rd_receiver_feedback, receiver, now):
                code = lib.cmux_rd_upstream_on_datagram(upstream, feedback, len(feedback), now)
                if code < 0 and code != ERR_STREAM:
                    raise ScenarioError(f"cmux_rd_upstream_on_datagram returned {code}")
            for resend in rd.drain(lib.cmux_rd_upstream_pop_datagram, upstream):
                lib.cmux_rd_receiver_push_datagram(receiver, *bytes_args(as_host_video(resend)), now)
            lib.cmux_rd_receiver_next_deadline_us(receiver)
            lib.cmux_rd_receiver_stats(receiver, ctypes.byref(stats))
            lib.cmux_rd_upstream_stats(upstream, ctypes.byref(up_stats))
            rd.calls += 12
    finally:
        lib.cmux_rd_input_free(inp)
        lib.cmux_rd_receiver_free(receiver)
        lib.cmux_rd_upstream_free(upstream)
    if released < sent // 2:
        raise ScenarioError(f"the receiver released {released} of {sent} frames")
    return released


def bytes_args(data):
    return data, len(data)


def rd_session(lib, rd, frames=90):
    """Two display streams and a bulk download in one session over the stream carrier, and the same session over
    the datagram carrier."""
    released = 0
    frame_out, stream_out, message, stats = RdFrame(), ctypes.c_uint16(0), RdMessage(), RdStats()
    for carrier in (CARRIER_STREAM, CARRIER_DATAGRAM):
        session = lib.cmux_rd_session_new(carrier, 200_000, 5_000)
        upstreams = [rd_upstream(lib, stream) for stream in (0, 1)]
        sender = lib.cmux_rd_bulk_sender_new(1_000)
        receiver = lib.cmux_rd_bulk_receiver_new()
        chunk, credit, credit_len = RdBulkChunk(), ctypes.create_string_buffer(256), ctypes.c_size_t(0)
        try:
            if lib.cmux_rd_session_open_stream(session, 1) != OK:
                raise ScenarioError("cmux_rd_session_open_stream refused stream 1")
            transfer = 7
            payload = frame_bytes(3, 3 << 20)
            if lib.cmux_rd_bulk_sender_queue(sender, transfer, payload, len(payload)) != OK:
                raise ScenarioError("cmux_rd_bulk_sender_queue refused")
            received = 0
            now = 2_000_000
            for index in range(frames):
                now += FRAME_US
                for stream, upstream in enumerate(upstreams):
                    keyframe = index % 45 == 0
                    data = frame_bytes(index + stream, 12_000 if keyframe else 1_500 + (index * 53) % 2_500)
                    lib.cmux_rd_upstream_send_frame(upstream, data, len(data), now - 2_000, keyframe, now)
                    for number, datagram in enumerate(rd.drain(lib.cmux_rd_upstream_pop_datagram, upstream)):
                        video = as_host_video(datagram)
                        if carrier == CARRIER_STREAM:
                            framed = rd.stream_frame(MESSAGE_DATAGRAM, video)
                            code = lib.cmux_rd_session_push_stream(session, framed, len(framed), now)
                        elif (index + number) % 11 == 3:
                            continue  # lost on the path
                        else:
                            code = lib.cmux_rd_session_push_datagram(session, video, len(video), now)
                        if code < 0:
                            raise ScenarioError(f"session push returned {code} (carrier {carrier})")
                if carrier == CARRIER_STREAM:
                    # Control and bulk ride the stream: the host's bulk frames come through the session.
                    control = rd.stream_frame(MESSAGE_CONTROL, encode({"t": "stats", "frame": index}))
                    lib.cmux_rd_session_push_stream(session, control, len(control), now)
                    for framed in rd.drain(lib.cmux_rd_bulk_sender_pop_frame, sender, now, False):
                        lib.cmux_rd_session_push_stream(session, framed, len(framed), now)
                    lib.cmux_rd_bulk_sender_next_deadline_us(sender)
                    lib.cmux_rd_bulk_sender_queued_bytes(sender)
                lib.cmux_rd_session_tick(session, now)
                while lib.cmux_rd_session_pop_frame(session, ctypes.byref(frame_out), ctypes.byref(stream_out)) == 1:
                    released += 1
                    lib.cmux_rd_session_note_decode(session, stream_out.value, 1_100)
                while lib.cmux_rd_session_pop_message(session, ctypes.byref(message)) == 1:
                    if message.kind != MESSAGE_BULK:
                        continue
                    code = lib.cmux_rd_bulk_receiver_accept(receiver, message.data, message.len, ctypes.byref(chunk),
                                                            credit, len(credit), ctypes.byref(credit_len))
                    if code != OK:
                        raise ScenarioError(f"cmux_rd_bulk_receiver_accept returned {code}")
                    received += chunk.len
                    if credit_len.value:
                        # The framed bulk_credit goes back to the host's sender as its control payload.
                        lib.cmux_rd_bulk_sender_on_control(sender, credit.raw[5:credit_len.value],
                                                           credit_len.value - 5)
                if index % 30 == 29:
                    lib.cmux_rd_session_request_keyframe(session, index % 2)
                for feedback in rd.drain(lib.cmux_rd_session_feedback, session, now):
                    for upstream in upstreams:
                        if lib.cmux_rd_upstream_on_datagram(upstream, feedback, len(feedback), now) != ERR_STREAM:
                            break
                for upstream in upstreams:
                    for resend in rd.drain(lib.cmux_rd_upstream_pop_datagram, upstream):
                        video = as_host_video(resend)
                        if carrier == CARRIER_STREAM:
                            framed = rd.stream_frame(MESSAGE_DATAGRAM, video)
                            lib.cmux_rd_session_push_stream(session, framed, len(framed), now)
                        else:
                            lib.cmux_rd_session_push_datagram(session, video, len(video), now)
                lib.cmux_rd_session_next_deadline_us(session)
                for stream in (0, 1):
                    lib.cmux_rd_session_stats(session, stream, ctypes.byref(stats))
                rd.calls += 10
            if carrier == CARRIER_STREAM:
                if received == 0:
                    raise ScenarioError("the bulk download delivered nothing")
                lib.cmux_rd_bulk_sender_on_credit(sender, transfer, received + (1 << 20))
                lib.cmux_rd_bulk_sender_cancel(sender, transfer)
                lib.cmux_rd_bulk_receiver_finish(receiver, transfer)
            lib.cmux_rd_session_close_stream(session, 1)
        finally:
            lib.cmux_rd_bulk_receiver_free(receiver)
            lib.cmux_rd_bulk_sender_free(sender)
            for upstream in upstreams:
                lib.cmux_rd_upstream_free(upstream)
            lib.cmux_rd_session_free(session)
    if released == 0:
        raise ScenarioError("the session released no frame")
    return released


def rd_stream_receiver(lib, rd, frames=60):
    """A receiver on the stream carrier (one display, no loss)."""
    upstream = rd_upstream(lib, 0)
    receiver = lib.cmux_rd_receiver_new(CARRIER_STREAM, 200_000, 5_000)
    frame_out, message = RdFrame(), RdMessage()
    released = 0
    try:
        now = 3_000_000
        for index in range(frames):
            now += FRAME_US
            data = frame_bytes(index, 16_000 if index % 30 == 0 else 3_000)
            lib.cmux_rd_upstream_send_frame(upstream, data, len(data), now, index % 30 == 0, now)
            chunk = b"".join(rd.stream_frame(MESSAGE_DATAGRAM, as_host_video(d))
                             for d in rd.drain(lib.cmux_rd_upstream_pop_datagram, upstream))
            control = rd.stream_frame(MESSAGE_CONTROL, encode({"t": "cursor", "frame": index}))
            stream = chunk + control
            # The stream arrives in pieces that split frames.
            for start in range(0, len(stream), 4_000):
                piece = stream[start:start + 4_000]
                if lib.cmux_rd_receiver_push_stream(receiver, piece, len(piece), now) < 0:
                    raise ScenarioError("cmux_rd_receiver_push_stream refused")
            lib.cmux_rd_receiver_tick(receiver, now)
            while lib.cmux_rd_receiver_pop_frame(receiver, ctypes.byref(frame_out)) == 1:
                released += 1
            while lib.cmux_rd_receiver_pop_message(receiver, ctypes.byref(message)) == 1:
                pass
            for feedback in rd.drain(lib.cmux_rd_receiver_feedback, receiver, now):
                lib.cmux_rd_upstream_on_datagram(upstream, feedback, len(feedback), now)
            rd.drain(lib.cmux_rd_upstream_pop_datagram, upstream)
    finally:
        lib.cmux_rd_receiver_free(receiver)
        lib.cmux_rd_upstream_free(upstream)
    if released == 0:
        raise ScenarioError("the stream receiver released no frame")
    return released


def remote_desktop(lib):
    if lib.cmux_rd_ffi_abi_version() < 1:
        raise ScenarioError("cmux_rd_ffi_abi_version is 0")
    rd = Rd(lib)
    rd_receiver(lib, rd)
    rd_stream_receiver(lib, rd)
    rd_session(lib, rd)
    return rd.calls


# ---------- the remote tab client ----------


def remote_tab(lib, vectors):
    calls = 0
    outcome, length = U8P(), ctypes.c_size_t(0)
    for case in vectors["cases"]:
        client = lib.cmux_rb_client_new()
        if not client:
            raise ScenarioError("cmux_rb_client_new returned null")
        try:
            for index, step in enumerate(case["steps"]):
                body = encode(step["input"])
                code = lib.cmux_rb_client_apply(client, body, len(body), ctypes.byref(outcome), ctypes.byref(length))
                if code != OK:
                    raise ScenarioError(f"rb client {case['name']} step {index}: code {code}")
                answer = json.loads(ctypes.string_at(outcome, length.value))
                expect = step["expect"]
                if any(answer.get(field) != expect.get(field) for field in ("effects", "note", "reject")):
                    raise ScenarioError(f"rb client {case['name']} step {index}: answered {answer}")
                calls += 1
        finally:
            lib.cmux_rb_client_free(client)
    return calls


# ---------- the run and its check ----------


def corpora(repo):
    return {
        "layout": load_json(os.path.join(repo, "Packages", "macOS", "CmuxNext", "Tests", "CmuxNextSidebarTests",
                                         "Fixtures", "sidebar-layout-cases.json")),
        "rb": load_json(os.path.join(repo, "schemas", "remote-tab", "client.json")),
    }


def run_round(lib, data):
    """One round of every scenario here; returns {name: calls}."""
    return {
        "sidebar": sidebar(lib),
        "focus machine": focus_machine(lib),
        "layout": layout(lib, data["layout"]),
        "remote desktop": remote_desktop(lib),
        "remote tab": remote_tab(lib, data["rb"]),
    }


SWIFT_NAME = re.compile(r"\bcmux_[a-z0-9_]+\b")


def app_exports(lib, repo):
    """The C functions the app's Swift sources name that the library exports."""
    try:
        text = subprocess.run(["git", "-C", repo, "grep", "-ohE", r"\bcmux_[a-z0-9_]+\b", "--", "*.swift"],
                              check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise ScenarioError(f"cannot list the app's C calls with git grep in {repo}: {error}") from error
    names = set(SWIFT_NAME.findall(text))
    return sorted(name for name in names if hasattr(lib, name))


def covered_functions(tool, profile):
    """The functions of an indexed profile with a non-zero count (llvm-profdata show --covered)."""
    try:
        out = subprocess.run([tool, "show", "--covered", profile], check=True, capture_output=True,
                             text=True).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise ScenarioError(f"llvm-profdata show --covered {profile} failed: {error}") from error
    return {line.strip() for line in out.splitlines() if line.strip()}


def coverage(lib, repo, tool, profile):
    """Fails unless every C ABI the app calls has counts in the profile. Returns the number checked."""
    exports = app_exports(lib, repo)
    if not exports:
        raise ScenarioError("found no app C call that the library exports; the check would prove nothing")
    covered = covered_functions(tool, profile)
    cold = [name for name in exports if name not in covered]
    if cold:
        raise ScenarioError("the scenarios never call these app C ABIs, so PGO would compile them as cold code; "
                            "add them to scripts/cmux-next/pgo/rust_pgo_ffi.py: " + ", ".join(cold))
    return len(exports)
