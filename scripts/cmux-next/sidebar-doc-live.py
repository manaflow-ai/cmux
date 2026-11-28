#!/usr/bin/env python3
"""Live behavior check of the sidebar document (sidebar-doc-v1) at the
daemon socket.

1. Seed a registry through the OLD verbs on a real daemon: this machine's
   workspaces, two other machines (put-session) with personal rows, groups
   (one of them pinned/saved), a workspace pin flag, a custom layout section
   and a sec_pinned tile.
2. Copy the registry and turn the copy back into the state an older daemon
   left (drop the sidebar document tables and its meta rows; the old tables
   are untouched), then start a daemon from the copy: it migrates once.
3. Assert, through sidebar.get / sidebar.* / sidebar_layout.get /
   workspace_group.* / workspace.create, the behaviors of slice S2:
   migrated doc, move into Pinned, group into a custom section,
   cross_machine refusal, undo with the returned inverse, order across a
   restart, migration twice is a no-op, the old layout shows the pin, old
   group verbs and new workspaces follow into the doc.
4. Slice 2 (doc2): section `scroll` defaults and `section.update {scroll,
   max_rows}`, the region move of a default scroll, the CLI verbs
   `sidebar section-scroll` / `section-max-rows`, the url body `icon_url`
   (migrated from an old item's `extra.icon_url`, `item.update`, lifted on
   `item.add`, restated for old clients in `sidebar_layout`).
5. Doc slice 3: a new workspace and a workspace.place send a reader that
   echoed placement-shift-v1 only the new or moved placement, and an
   old-protocol reader (also one that echoes only sidebar-doc-v1) every
   placement the change shifted.
6. Doc slice 4 (parity with the old layout), on a second copy of the seed:
   section `align` and `gap` migrated from the old layout (the workspaces
   section's onto every machine section), copied once at open into a
   document migrated before sections had them, set and cleared through
   `section.update`, followed from an old `sidebar_layout.update`;
   `item.remove_ref` (url and workspace refs); `sidebar.reset` (default
   sections, workspaces and groups kept in their machine sections, closed
   workspaces dropped, undo with the inverse, a second reset is a no-op)
   and the old `layout.reset` following into the document.
7. One order: after a sidebar.move and a sidebar.pin, `cmux workspace list`
   (and protocol-2 `workspace.list`) list this machine's workspaces in the
   sidebar.get order; `--order session` and the private raw
   `list-workspaces` tree (whose deltas carry session indexes) keep the
   session order.

Usage: sidebar-doc-live.py --binary path/to/cmux-tui [--workdir DIR]
Prints one PASS/FAIL line per check; exits 1 on any FAIL.
"""

from __future__ import annotations

import argparse
import itertools
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

PROTOCOL = "cmux.protocol/2"
SESSION = "sbdoc"
FAVICON = "https://example.com/favicon.ico"
_ids = itertools.count(1)
failures: list[str] = []


def check(name: str, ok: bool, detail: object = "") -> None:
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f" :: {detail}"), flush=True)
    if not ok:
        failures.append(name)


class Daemon:
    def __init__(self, binary: Path, state: Path, socket_path: Path) -> None:
        self.binary, self.state, self.socket_path = binary, state, socket_path
        self.process: subprocess.Popen[str] | None = None
        self.log = state.parent / f"{state.name}.log"

    def start(self) -> None:
        if self.socket_path.exists():
            self.socket_path.unlink()
        log = open(self.log, "a")
        self.process = subprocess.Popen(
            [str(self.binary), "--headless", "--session", SESSION, "--socket",
             str(self.socket_path), "--state", str(self.state)],
            stdout=log, stderr=subprocess.STDOUT, text=True,
        )
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise SystemExit(f"daemon exited {self.process.returncode}: {self.log.read_text()[-2000:]}")
            try:
                self.raw({"cmd": "identify"})
                return
            except OSError:
                time.sleep(0.05)
        raise SystemExit("daemon did not answer identify")

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.process = None

    def _line(self, message: dict) -> dict:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(20)
            connection.connect(str(self.socket_path))
            connection.sendall(json.dumps(message).encode() + b"\n")
            buffer = b""
            while b"\n" not in buffer:
                chunk = connection.recv(1 << 16)
                if not chunk:
                    break
                buffer += chunk
        return json.loads(buffer.split(b"\n", 1)[0])

    def raw(self, message: dict) -> dict:
        message = {"id": next(_ids), **message}
        reply = self._line(message)
        if not reply.get("ok"):
            raise RuntimeError(f"{message['cmd']} failed: {reply}")
        return reply.get("data")

    def v2(self, operation: str, params: dict | None = None, mutate: bool = False) -> dict:
        envelope = {
            "protocol": PROTOCOL, "type": "request", "id": f"r{next(_ids)}",
            "operation": operation,
            "params": {"machine": "current", "session": "current", **(params or {})},
        }
        if mutate:
            envelope["idempotency_key"] = f"sbdoc-{next(_ids)}"
        return self._line(envelope)

    def ok(self, operation: str, params: dict | None = None, mutate: bool = False):
        reply = self.v2(operation, params, mutate)
        if not reply.get("ok"):
            raise RuntimeError(f"{operation} failed: {reply.get('error')}")
        return reply["result"]


def cli(daemon: Daemon, *args: str) -> subprocess.CompletedProcess:
    """The `cmux` CLI (the same binary) against the daemon's socket."""
    env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_")}
    return subprocess.run([str(daemon.binary), "--socket", str(daemon.socket_path), "--json", *args],
                          capture_output=True, text=True, timeout=30, env=env)


def reason_of(reply: dict) -> str | None:
    return (reply.get("error") or {}).get("details", {}).get("reason")


def sidebar_batch(daemon: Daemon, action) -> dict | None:
    """Open session.events, run `action`, return the first delta with a
    sidebar_doc change (or None after 15 s)."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(15)
        stream.connect(str(daemon.socket_path))
        request = {"protocol": PROTOCOL, "type": "request", "id": f"r{next(_ids)}",
                   "operation": "session.events",
                   "params": {"machine": "current", "session": "current",
                              "stream_id": f"stream_{os.urandom(16).hex()}"}}
        stream.sendall(json.dumps(request).encode() + b"\n")
        buffer = b""

        def lines(timeout: float):
            nonlocal buffer
            stream.settimeout(timeout)
            while True:
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    yield json.loads(line)
                try:
                    chunk = stream.recv(1 << 20)
                except TimeoutError:
                    return
                if not chunk:
                    return
                buffer += chunk

        # Drain the response and the snapshot, then act and read deltas.
        for message in lines(1.0):
            if os.environ.get("SBDOC_DEBUG"):
                print("drain:", json.dumps(message)[:300], flush=True)
        action()
        for message in lines(15.0):
            if os.environ.get("SBDOC_DEBUG"):
                print("event:", json.dumps(message)[:400], flush=True)
            item = message.get("item") or {}
            changes = item.get("changes") or []
            if any(change.get("resource") == "sidebar_doc" for change in changes):
                return item
    return None


class EventStream:
    """One `session.events` stream on its own connection. `echo`: the
    capabilities the connection echoes in `set-client-info` first (a client
    that reads the order from the sidebar document echoes sidebar-doc-v1)."""

    def __init__(self, daemon: Daemon, echo: list[str] | None = None) -> None:
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.connect(str(daemon.socket_path))
        self.buffer = b""
        if echo is not None:
            self.socket.sendall(json.dumps({"id": next(_ids), "cmd": "set-client-info",
                                            "capabilities": echo}).encode() + b"\n")
            reply = next(self.lines(10.0), {})
            if not reply.get("ok"):
                raise RuntimeError(f"set-client-info failed: {reply}")
        request = {"protocol": PROTOCOL, "type": "request", "id": f"r{next(_ids)}",
                   "operation": "session.events",
                   "params": {"machine": "current", "session": "current",
                              "stream_id": f"stream_{os.urandom(16).hex()}"}}
        self.socket.sendall(json.dumps(request).encode() + b"\n")
        for _ in self.lines(1.0):
            pass

    def lines(self, timeout: float):
        self.socket.settimeout(timeout)
        while True:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                yield json.loads(line)
            try:
                chunk = self.socket.recv(1 << 20)
            except TimeoutError:
                return
            if not chunk:
                return
            self.buffer += chunk

    def delta_with(self, resource: str, value_id: str, index: int | None = None) -> dict | None:
        """The first delta (within 15 s) with an upsert of `resource` `value_id`
        (at `index`, when given)."""
        for message in self.lines(15.0):
            item = message.get("item") or {}
            if any(change.get("resource") == resource and change.get("id") == value_id
                   and (index is None or (change.get("value") or {}).get("index") == index)
                   for change in item.get("changes") or []):
                return item
        return None

    def close(self) -> None:
        self.socket.close()


def placements_of(item: dict | None) -> dict[str, int]:
    """The workspace_placement upserts of a delta: placement id -> index."""
    return {change["id"]: change["value"]["index"] for change in (item or {}).get("changes") or []
            if change.get("resource") == "workspace_placement" and change.get("kind") == "state_upsert"}


def registry_file(state: Path) -> Path:
    for path in state.rglob("*"):
        if not path.is_file() or path.suffix in {".log", ".json", ".sock"}:
            continue
        try:
            with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as db:
                if db.execute("SELECT 1 FROM sqlite_master WHERE name='personal_workspaces'").fetchone():
                    return path
        except sqlite3.DatabaseError:
            continue
    raise SystemExit(f"no registry under {state}")


def items_by_id(doc: dict) -> dict[str, dict]:
    return {item["id"]: item for item in doc["items"]}


def ws_item(doc: dict, session: str, workspace: str) -> dict | None:
    for item in doc["items"]:
        ref = item["body"].get("ref") if item["body"].get("type") == "workspace" else None
        if ref and ref["session_id"] == session and (
            ref["workspace_id"] == workspace or ref.get("extra", {}).get("workspace_ref") == workspace
        ):
            return item
    return None


def group_item(doc: dict, name: str) -> dict | None:
    return next((i for i in doc["items"] if i["body"].get("type") == "group" and i["body"]["name"] == name), None)


def children(doc: dict, parent: str) -> list[dict]:
    kids = [i for i in doc["items"] if i.get("parent") == parent]
    return sorted(kids, key=lambda i: (i["order"], i["id"]))


def top(doc: dict, section: str) -> list[dict]:
    rows = [i for i in doc["items"] if i["section"] == section and not i.get("parent")]
    return sorted(rows, key=lambda i: (i["order"], i["id"]))


def seed(daemon: Daemon) -> dict:
    """The old verbs only (no sidebar.*)."""
    ident = daemon.raw({"cmd": "identify"})
    local = ident["registry_id"]
    names = ["w1", "w2", "w3", "w4", "w5", "w6"]
    ids = {}
    for name in names:
        created = daemon.ok("workspace.create", {"name": name, "initial_content": "empty"}, mutate=True)
        ids[name] = created["value"]["workspace_id"]
    keys = {}
    listed = daemon.raw({"cmd": "list-workspaces"})
    for workspace in listed["workspaces"] if isinstance(listed, dict) else listed:
        if workspace.get("name") in ids:
            keys[workspace["name"]] = workspace["key"]
    for session, machine in (("remote-a", "build-box"), ("remote-b", "cloud-vm")):
        daemon.raw({"cmd": "put-session", "session_id": session, "machine_name": machine,
                    "transport": {"kind": "ssh", "host": machine}})
    for session, key in (("remote-a", "ra1"), ("remote-a", "ra2"), ("remote-a", "ra3"),
                         ("remote-b", "rb1"), ("remote-b", "rb2")):
        daemon.raw({"cmd": "set-personal-workspace", "session_id": session, "workspace_key": key})
    frontend = daemon.ok("workspace_group.create", {"name": "Frontend"}, mutate=True)["value"]["id"]
    for name in ("w2", "w3"):
        daemon.ok("workspace.place", {"workspace": ids[name], "group": frontend}, mutate=True)
    remote = daemon.ok("workspace_group.create", {"name": "Remote"}, mutate=True)["value"]["id"]
    for key in ("ra2", "ra3"):
        daemon.raw({"cmd": "set-personal-workspace", "session_id": "remote-a", "workspace_key": key, "group": remote})
    saved = daemon.ok("workspace_group.create", {"name": "Saved"}, mutate=True)["value"]["id"]
    daemon.ok("workspace.place", {"workspace": ids["w4"], "group": saved}, mutate=True)
    daemon.ok("workspace_group.update", {"workspace_group": saved, "pinned": True}, mutate=True)
    daemon.raw({"cmd": "set-workspace-metadata", "key": keys["w5"], "pinned": True})
    # An old group name longer than the document's title limit (80).
    daemon.ok("workspace_group.create", {"name": "Long " + "n" * 115}, mutate=True)
    custom = {"id": "sec_work", "title": "Work", "region": "middle", "look": "list", "content": "items",
              "arrangement": {"layout": "list", "align": "center", "gap": 6},
              "items": [{"id": "itm_docs", "ref": {"kind": "url", "value": "https://example.com/docs"},
                         "icon_url": FAVICON}]}
    daemon.ok("sidebar_layout.update", {"op": {"kind": "section.add", "section": custom, "index": 99}}, mutate=True)
    # Old arrangement values on the workspaces section and the bottom band.
    daemon.ok("sidebar_layout.update", {"op": {"kind": "section.update", "id": "sec_workspaces",
                                               "patch": {"align": "trailing", "gap": 3}}}, mutate=True)
    daemon.ok("sidebar_layout.update", {"op": {"kind": "section.update", "id": "sec_bottom",
                                               "patch": {"gap": 4}}}, mutate=True)
    # The app's pin: item.add when its layout shows sec_pinned, else section.add.
    tile = {"id": "itm_tile_w6", "ref": {"kind": "workspace", "value": f"{local}:{ids['w6']}"}}
    layout = daemon.ok("sidebar_layout.get")
    if any(section["id"] == "sec_pinned" for section in layout["sections"]):
        op = {"kind": "item.add", "item": tile, "section": "sec_pinned", "index": 1 << 31}
    else:
        op = {"kind": "section.add", "index": 1, "section": {
            "id": "sec_pinned", "region": "top", "look": "built_in", "content": "items",
            "arrangement": {"layout": "grid", "align": "leading"}, "shows_title": False, "items": [tile]}}
    daemon.ok("sidebar_layout.update", {"op": op}, mutate=True)
    return {"local": local, "ids": ids, "keys": keys, "frontend": frontend, "remote": remote, "saved": saved}


def as_older_daemon_left_it(registry: Path) -> None:
    with sqlite3.connect(registry) as db:
        db.execute("DROP TABLE IF EXISTS sidebar_sections")
        db.execute("DROP TABLE IF EXISTS sidebar_items")
        db.execute("DELETE FROM meta WHERE key LIKE 'sidebar_doc_%'")


def sections_of(doc: dict) -> dict[str, dict]:
    return {section["id"]: section for section in doc["sections"]}


def strip_arrangement(registry: Path) -> None:
    """The document as a daemon from before section align/gap left it."""
    with sqlite3.connect(registry) as db:
        for section_id, text in db.execute("SELECT id, section_json FROM sidebar_sections").fetchall():
            section = json.loads(text)
            section.pop("align", None)
            section.pop("gap", None)
            db.execute("UPDATE sidebar_sections SET section_json = ? WHERE id = ?", [json.dumps(section), section_id])
        db.execute("DELETE FROM meta WHERE key = 'sidebar_doc_arrangement_v1'")


def doc_slice_4(binary: Path, seed_state: Path, state: Path, sock: Path, seeded: dict) -> None:
    """Parity with the old layout: align, gap, item.remove_ref, reset."""
    local, ids = seeded["local"], seeded["ids"]
    machines = [f"sec_m_{s}" for s in (local, "remote-a", "remote-b")]
    shutil.rmtree(state, ignore_errors=True)
    shutil.copytree(seed_state, state)
    registry = registry_file(state)
    as_older_daemon_left_it(registry)
    daemon = Daemon(binary, state, sock)
    daemon.start()
    try:
        sections = sections_of(daemon.ok("sidebar.get"))
        check("doc4: a custom section's old align and gap are migrated",
              (sections["sec_work"].get("align"), sections["sec_work"].get("gap")) == ("center", 6),
              sections["sec_work"])
        check("doc4: the old workspaces section's align and gap are on every machine section",
              all((sections[m].get("align"), sections[m].get("gap")) == ("trailing", 3) for m in machines),
              {m: (sections[m].get("align"), sections[m].get("gap")) for m in machines})
        check("doc4: the bottom band's old gap is migrated; align is always on the wire",
              sections["sec_bottom"].get("gap") == 4 and sections["sec_bottom"].get("align") == "leading"
              and sections["sec_pinned"].get("align") == "leading" and "gap" not in sections["sec_pinned"],
              {"bottom": sections["sec_bottom"], "pinned": sections["sec_pinned"]})
    finally:
        daemon.stop()
    # A document migrated before sections had align/gap gets them once at open.
    strip_arrangement(registry)
    daemon.start()
    try:
        doc = daemon.ok("sidebar.get")
        sections = sections_of(doc)
        check("doc4: align and gap are copied once at open into an older migrated document",
              (sections["sec_work"].get("align"), sections["sec_work"].get("gap")) == ("center", 6)
              and all((sections[m].get("align"), sections[m].get("gap")) == ("trailing", 3) for m in machines)
              and sections["sec_bottom"].get("gap") == 4,
              {k: (v.get("align"), v.get("gap")) for k, v in sections.items()})

        # section.update: set, clear, refuse, keep a newer value.
        daemon.ok("sidebar.section.update", {"id": "sec_work", "patch": {"align": "fill", "gap": 10}}, mutate=True)
        work = sections_of(daemon.ok("sidebar.get"))["sec_work"]
        check("doc4: section.update sets align and gap",
              (work.get("align"), work.get("gap")) == ("fill", 10), work)
        old_work = next((s for s in daemon.ok("sidebar_layout.get")["sections"] if s["id"] == "sec_work"), {})
        check("doc4: old sidebar_layout.get shows the document's align and gap",
              (old_work.get("arrangement") or {}).get("align") == "fill"
              and (old_work.get("arrangement") or {}).get("gap") == 10, old_work)
        daemon.ok("sidebar.section.update", {"id": "sec_work", "patch": {"gap": None}}, mutate=True)
        work = sections_of(daemon.ok("sidebar.get"))["sec_work"]
        check("doc4: section.update gap null clears it and keeps align",
              "gap" not in work and work.get("align") == "fill", work)
        refused = daemon.v2("sidebar.section.update", {"id": "sec_work", "patch": {"gap": 33}}, mutate=True)
        check("doc4: a gap over 32 is refused invalid_value",
              not refused.get("ok") and reason_of(refused) == "invalid_value", refused)
        refused = daemon.v2("sidebar.section.update", {"id": "sec_work", "patch": {"gap": -1}}, mutate=True)
        check("doc4: a negative gap is refused invalid_value",
              not refused.get("ok") and reason_of(refused) == "invalid_value", refused)
        daemon.ok("sidebar.section.update", {"id": "sec_work", "patch": {"align": "diagonal"}}, mutate=True)
        work = sections_of(daemon.ok("sidebar.get"))["sec_work"]
        check("doc4: a newer align value is kept verbatim", work.get("align") == "diagonal", work)
        # An old client's section.update follows: only the field it changed.
        daemon.ok("sidebar_layout.update", {"op": {"kind": "section.update", "id": "sec_work",
                                                   "patch": {"gap": 12}}}, mutate=True)
        work = sections_of(daemon.ok("sidebar.get"))["sec_work"]
        check("doc4: an old sidebar_layout.update gap follows into the document (align untouched)",
              (work.get("align"), work.get("gap")) == ("diagonal", 12), work)
        daemon.ok("sidebar_layout.update", {"op": {"kind": "section.update", "id": "sec_workspaces",
                                                   "patch": {"align": "center"}}}, mutate=True)
        sections = sections_of(daemon.ok("sidebar.get"))
        check("doc4: an old workspaces-section align follows onto every machine section",
              all((sections[m].get("align"), sections[m].get("gap")) == ("center", 3) for m in machines),
              {m: (sections[m].get("align"), sections[m].get("gap")) for m in machines})

        # item.remove_ref ("Remove from Sidebar").
        daemon.ok("sidebar.item.remove_ref", {"ref": {"kind": "url", "value": "https://example.com/docs"}},
                  mutate=True)
        doc = daemon.ok("sidebar.get")
        check("doc4: item.remove_ref removes the url item", "itm_docs" not in items_by_id(doc))
        refused = daemon.v2("sidebar.item.remove_ref", {"ref": {"kind": "url", "value": "https://example.com/docs"}},
                            mutate=True)
        check("doc4: item.remove_ref of a ref no item shows is refused unknown_item",
              not refused.get("ok") and reason_of(refused) == "unknown_item", refused)
        daemon.ok("sidebar.item.remove_ref", {"ref": {"kind": "workspace", "value": f"{local}:{ids['w1']}"}},
                  mutate=True)
        check("doc4: item.remove_ref of a workspace ref removes its item",
              ws_item(daemon.ok("sidebar.get"), local, ids["w1"]) is None)

        # Reset: put things where a reset must undo them first.
        doc = daemon.ok("sidebar.get")
        frontend, saved = group_item(doc, "Frontend"), group_item(doc, "Saved")
        daemon.ok("sidebar.move", {"items": [frontend["id"]], "to": {"section": "sec_work"}}, mutate=True)
        daemon.ok("sidebar.section.add", {"section": {"id": "sec_extra", "kind": {"type": "custom"},
                                                      "title": "Extra", "region": "top"}}, mutate=True)
        daemon.ok("sidebar.item.add", {"item": {"id": "itm_extra_url", "body": {"type": "url", "url": "https://example.net"}},
                                       "to": {"section": "sec_extra"}}, mutate=True)
        w3 = ws_item(doc, local, ids["w3"])
        daemon.ok("sidebar.move", {"items": [w3["id"]], "to": {"section": "sec_extra"}}, mutate=True)
        daemon.ok("sidebar.item.add", {"item": {"id": "itm_pinned_url", "body": {"type": "url", "url": "https://example.org"}},
                                       "to": {"section": "sec_pinned"}}, mutate=True)
        daemon.ok("sidebar.section.update", {"id": "sec_top", "patch": {"gap": 7}}, mutate=True)
        daemon.ok("sidebar.item.remove", {"id": "itm_app_store"}, mutate=True)
        daemon.ok("workspace.close", {"workspace": ids["w5"]}, mutate=True)
        doc = daemon.ok("sidebar.get")
        check("doc4: before reset w5 (closed) stays in Pinned and the custom sections hold their rows",
              (ws_item(doc, local, ids["w5"]) or {}).get("section") == "sec_pinned"
              and items_by_id(doc)[frontend["id"]]["section"] == "sec_work"
              and (ws_item(doc, local, ids["w3"]) or {}).get("section") == "sec_extra",
              [i["id"] + "@" + i["section"] for i in doc["items"]])
        before = doc
        reset = daemon.ok("sidebar.reset", {}, mutate=True)
        after = daemon.ok("sidebar.get")
        order = [s["id"] for s in after["sections"]]
        expected = ["sec_top", "sec_pinned", *machines, "sec_recents", "sec_bottom"]
        check("doc4: reset leaves exactly the default sections in order", order == expected, order)
        sections = sections_of(after)
        check("doc4: reset restores the default looks (top/bottom built-in, bottom inline, no gaps, machine leading)",
              sections["sec_top"]["kind"]["type"] == "builtin" and "gap" not in sections["sec_top"]
              and sections["sec_bottom"]["kind"]["type"] == "builtin" and sections["sec_bottom"]["arrangement"] == "inline"
              and "gap" not in sections["sec_bottom"] and sections["sec_recents"]["kind"]["type"] == "app"
              and all(sections[m].get("align") == "leading" and "gap" not in sections[m] for m in machines),
              sections)
        check("doc4: reset keeps machine section titles",
              sections["sec_m_remote-a"].get("title") == "build-box", sections["sec_m_remote-a"])
        check("doc4: reset restores Home and App Store on top and the account at the bottom; Pinned is empty",
              [i["id"] for i in top(after, "sec_top")] == ["itm_home", "itm_app_store"]
              and [i["id"] for i in top(after, "sec_bottom")] == ["itm_account"]
              and top(after, "sec_pinned") == [],
              {"top": top(after, "sec_top"), "bottom": top(after, "sec_bottom"), "pinned": top(after, "sec_pinned")})
        home = f"sec_m_{local}"
        w6, w4, w3 = (ws_item(after, local, ids[n]) for n in ("w6", "w4", "w3"))
        frontend_after, saved_after = items_by_id(after).get(frontend["id"]), items_by_id(after).get(saved["id"])
        tail = [i["id"] for i in top(after, home)][-4:]
        check("doc4: reset moves Pinned, then the other sections' workspaces and groups, to the end of their machine section",
              w6 is not None and w3 is not None
              and tail == [w6["id"], saved["id"], w3["id"], frontend["id"]], {"tail": tail})
        check("doc4: reset keeps groups with their items (Saved from Pinned, Frontend from a custom section)",
              saved_after is not None and saved_after["section"] == home
              and [c["id"] for c in children(after, saved["id"])] == [w4 and w4["id"]]
              and frontend_after is not None and frontend_after["section"] == home
              and all(c["section"] == home for c in children(after, frontend["id"]))
              and len(children(after, frontend["id"])) == len(children(before, frontend["id"])),
              {"saved": saved_after, "frontend": frontend_after})
        remote = group_item(after, "Remote")
        check("doc4: reset leaves machine sections' rows in place (Remote group in remote-a)",
              remote is not None and remote["section"] == "sec_m_remote-a"
              and [c["id"] for c in children(after, remote["id"])] == [c["id"] for c in children(before, remote["id"])],
              remote)
        check("doc4: reset drops this machine's closed workspaces and the removed sections' url items",
              ws_item(after, local, ids["w5"]) is None
              and not {"itm_extra_url", "itm_pinned_url"} & set(items_by_id(after)), sorted(items_by_id(after)))
        refs = [(i["body"]["ref"]["session_id"], i["body"]["ref"]["workspace_id"])
                for i in after["items"] if i["body"].get("type") == "workspace"]
        check("doc4: after reset each workspace is placed once", len(refs) == len(set(refs)), refs)
        again = daemon.ok("sidebar.reset", {}, mutate=True)
        check("doc4: a second reset changes nothing (same revision, empty inverse)",
              again["value"]["revision"] == after["revision"] and again["value"]["inverse"] == [], again["value"])
        daemon.ok("sidebar.apply", {"ops": reset["value"]["inverse"]}, mutate=True)
        undone = daemon.ok("sidebar.get")
        strip = lambda d: {"sections": d["sections"], "items": d["items"]}
        check("doc4: sidebar.apply with reset's inverse restores the document", strip(undone) == strip(before))
        # The old app's layout.reset is the document's reset.
        daemon.ok("sidebar_layout.update", {"op": {"kind": "layout.reset"}}, mutate=True)
        old_reset = daemon.ok("sidebar.get")
        check("doc4: an old layout.reset follows into the document",
              [s["id"] for s in old_reset["sections"]] == expected and top(old_reset, "sec_pinned") == []
              and (ws_item(old_reset, local, ids["w6"]) or {}).get("section") == home,
              [s["id"] for s in old_reset["sections"]])
        # The old layout is the defaults now; a section only the document has
        # still goes with an old layout.reset.
        daemon.ok("sidebar.section.add", {"section": {"id": "sec_doc_only", "kind": {"type": "custom"},
                                                      "title": "Doc only"}}, mutate=True)
        daemon.ok("sidebar_layout.update", {"op": {"kind": "layout.reset"}}, mutate=True)
        check("doc4: an old layout.reset of a default old layout still resets the document",
              "sec_doc_only" not in sections_of(daemon.ok("sidebar.get")),
              [s["id"] for s in daemon.ok("sidebar.get")["sections"]])
    finally:
        daemon.stop()


def one_order(daemon: Daemon, local: str) -> None:
    """`cmux workspace list` follows the sidebar document: after a sidebar.move and a sidebar.pin, the CLI order is the
    order of this machine's live workspaces in sidebar.get (Pinned keeps
    closed workspaces; those are not listed)."""

    def doc_order(live: set[str]) -> list[str]:
        return [i["body"]["ref"]["workspace_id"] for i in daemon.ok("sidebar.get")["items"]
                if i["body"].get("type") == "workspace" and i["body"]["ref"].get("session_id") == local
                and i["body"]["ref"]["workspace_id"] in live]

    def cli_order(*verb: str, field: str) -> list[str] | str:
        ran = cli(daemon, *verb)
        if ran.returncode != 0:
            return f"exit {ran.returncode}: {ran.stderr.strip()[-300:]}"
        data = json.loads(ran.stdout)
        if isinstance(data, dict):
            data = data.get("workspaces", data.get("value", data.get("result", data)))
            if isinstance(data, dict):
                data = data.get("workspaces", data)
        return [w[field] for w in data]

    raw_list = ("raw", "command", "--request-json", json.dumps({"cmd": "list-workspaces"}))
    verbs = ((("workspace", "list"), "id", "workspace list"),
             (("workspace", "list", "--order", "personal"), "id", "workspace list --order personal"))

    def same(step: str) -> list[str]:
        v2 = [w["id"] for w in daemon.ok("workspace.list")]
        expected = doc_order(set(v2))
        check(f"one order: workspace.list (protocol 2) == sidebar.get order after {step}",
              v2 == expected, {"v2": v2, "doc": expected})
        for verb, field, label in verbs:
            got = cli_order(*verb, field=field)
            check(f"one order: `cmux {label}` == sidebar.get order after {step}",
                  got == expected, {"cli": got, "doc": expected})
        return expected

    before = same("restart")
    doc = daemon.ok("sidebar.get")
    machine = f"sec_m_{local}"
    rows = top(doc, machine)
    loose = [i for i in rows if i["body"].get("type") == "workspace"]
    check("one order: this machine's section has a loose workspace and another row",
          len(loose) >= 1 and len(rows) >= 2, rows)
    if not loose or len(rows) < 2:
        return
    mover = loose[0]
    index = len(rows) - 1 if rows[0]["id"] == mover["id"] else 0
    daemon.ok("sidebar.move", {"items": [mover["id"]], "to": {"section": machine, "index": index}}, mutate=True)
    moved = same("sidebar.move")
    pinned_ws = mover["body"]["ref"]["workspace_id"]
    check("one order: the moved workspace changed place in the listed order",
          pinned_ws in moved and pinned_ws in before and moved.index(pinned_ws) != before.index(pinned_ws),
          {"before": before, "after": moved})
    daemon.ok("sidebar.pin", {"items": [mover["id"]]}, mutate=True)
    listed = same("sidebar.pin")
    in_machine = {i["body"]["ref"]["workspace_id"] for i in daemon.ok("sidebar.get")["items"]
                  if i["section"] == machine and i["body"].get("type") == "workspace"}
    check("one order: the pinned workspace is listed before every machine-section workspace",
          pinned_ws in listed and all(listed.index(pinned_ws) < listed.index(w) for w in in_machine if w in listed),
          listed)
    session = cli_order("workspace", "list", "--order", "session", field="id")
    indexes = cli_order("workspace", "list", "--order", "session", field="index")
    check("one order: `--order session` keeps the session order (rows by session index)",
          isinstance(session, list) and sorted(session) == sorted(listed)
          and isinstance(indexes, list) and indexes == sorted(indexes), {"session": session, "index": indexes})
    # The private tree keeps the session order: its tree deltas
    # (workspace-added/moved) carry session indexes that delta readers apply.
    tree = cli_order(*raw_list, field="resource_id")
    check("one order: raw list-workspaces keeps the session order of its index deltas",
          tree == session, {"tree": tree, "session": session})

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--workdir", type=Path)
    args = parser.parse_args()
    work = args.workdir or Path(tempfile.mkdtemp(prefix="sbdoc-"))
    work.mkdir(parents=True, exist_ok=True)
    seed_state, state = work / "seed-state", work / "state"
    for path in (seed_state, state):
        shutil.rmtree(path, ignore_errors=True)
        path.mkdir(mode=0o700)
    sock = Path(tempfile.mkdtemp(prefix="sb", dir="/tmp")) / "s.sock"
    seeder = Daemon(args.binary.resolve(), seed_state, sock)
    seeder.start()
    try:
        seeded = seed(seeder)
    finally:
        seeder.stop()
    local, ids = seeded["local"], seeded["ids"]
    # The copy, as an older daemon left it: old tables only.
    shutil.rmtree(state)
    shutil.copytree(seed_state, state)
    registry = registry_file(state)
    as_older_daemon_left_it(registry)
    with sqlite3.connect(registry) as db:
        # The old order the migration must keep: the stored sec_pinned tiles
        # and the Frontend group's members by personal position.
        layout_json = db.execute("SELECT document_json FROM sidebar_layout").fetchone()[0]
        old_tiles = [item["ref"]["value"].split(":", 1)[1]
                     for section in json.loads(layout_json)["sections"] if section["id"] == "sec_pinned"
                     for item in section["items"] if item["ref"]["kind"] == "workspace"]
        key_to_id = {key: ids[name] for name, key in seeded["keys"].items()}
        old_frontend = [key_to_id[key] for (key,) in db.execute(
            "SELECT workspace_key FROM personal_workspaces WHERE group_id = ? ORDER BY position",
            [seeded["frontend"]])]
        rows = db.execute("SELECT COUNT(*) FROM personal_workspaces").fetchone()[0]
        groups = db.execute("SELECT COUNT(*) FROM personal_groups").fetchone()[0]
        no_doc = not db.execute("SELECT 1 FROM sqlite_master WHERE name='sidebar_items'").fetchone()
    check("seed copy holds old rows and no sidebar document", rows >= 11 and groups == 4 and no_doc,
          {"rows": rows, "groups": groups})

    daemon = Daemon(args.binary.resolve(), state, sock)
    daemon.start()
    try:
        caps = daemon.raw({"cmd": "identify"})["capabilities"]
        check("capability sidebar-doc-v1 advertised", "sidebar-doc-v1" in caps)
        doc = daemon.ok("sidebar.get")
        sections = {s["id"]: s for s in doc["sections"]}
        check("migrated doc is revision 0", doc["revision"] == "0", doc["revision"])
        check("one machine section per machine",
              all(f"sec_m_{s}" in sections for s in (local, "remote-a", "remote-b")), list(sections))
        check("machine sections carry machine titles",
              sections.get("sec_m_remote-a", {}).get("title") == "build-box", sections.get("sec_m_remote-a"))
        check("Pinned section exists with no title", sections.get("sec_pinned", {}).get("shows_title") is False)
        check("custom section kept", sections.get("sec_work", {}).get("kind", {}).get("type") == "custom")
        pinned = [i["id"] for i in top(doc, "sec_pinned")]
        w5, w6 = ws_item(doc, local, ids["w5"]), ws_item(doc, local, ids["w6"])
        saved = group_item(doc, "Saved")
        check("tile w6 migrated into Pinned", w6 is not None and w6["section"] == "sec_pinned", w6)
        check("pin flag w5 migrated into Pinned", w5 is not None and w5["section"] == "sec_pinned", w5)
        check("pinned group migrated into Pinned with its member",
              saved is not None and saved["section"] == "sec_pinned"
              and [c["body"]["ref"]["workspace_id"] for c in children(doc, saved["id"])] == [ids["w4"]], saved)
        long_group = next((i for i in doc["items"] if i["body"].get("type") == "group"
                           and i["body"]["name"].startswith("Long ")), None)
        check("an old group name over the title limit is migrated cut to 80 characters",
              long_group is not None and len(long_group["body"]["name"]) == 80, long_group)
        tile_ids = [ws_item(doc, local, workspace)["id"] for workspace in old_tiles]
        flag_ids = [w5["id"]] if ids["w5"] not in old_tiles else []
        check("Pinned order: the old tiles, then pin flags, then the pinned group",
              pinned == tile_ids + flag_ids + [saved and saved["id"]], {"pinned": pinned, "tiles": old_tiles})
        frontend = group_item(doc, "Frontend")
        members = [c["body"]["ref"]["workspace_id"] for c in children(doc, frontend["id"])] if frontend else []
        check("group Frontend in this machine's section with its members in the old order",
              frontend is not None and frontend["section"] == f"sec_m_{local}"
              and members == old_frontend and sorted(members) == sorted([ids["w2"], ids["w3"]]),
              {"members": members, "old": old_frontend})
        remote = group_item(doc, "Remote")
        check("group Remote in remote-a's section with ra2, ra3 placed by reference",
              remote is not None and remote["section"] == "sec_m_remote-a"
              and [c["body"]["ref"]["extra"].get("workspace_ref") for c in children(doc, remote["id"])] == ["ra2", "ra3"],
              remote)
        rb = [i["body"]["ref"]["extra"].get("workspace_ref") for i in top(doc, "sec_m_remote-b")]
        check("remote-b rows in their machine section", rb == ["rb1", "rb2"], rb)
        url = items_by_id(doc).get("itm_docs")
        check("custom section url item migrated", url is not None and url["section"] == "sec_work", url)
        w1 = ws_item(doc, local, ids["w1"])
        check("w1 loose in this machine's section", w1 is not None and w1["section"] == f"sec_m_{local}", w1)
        refs = [(i["body"]["ref"]["session_id"], i["body"]["ref"]["workspace_id"])
                for i in doc["items"] if i["body"].get("type") == "workspace"]
        check("each workspace placed once", len(refs) == len(set(refs)), refs)
        check("migration moves an old url item's extra.icon_url into the body",
              url is not None and url["body"].get("icon_url") == FAVICON
              and "icon_url" not in url.get("extra", {}), url)
        check("scroll defaults: Pinned fixed, machine sections flow, middle custom flow",
              sections["sec_pinned"].get("scroll") == "fixed"
              and all(sections[f"sec_m_{s}"].get("scroll") == "flow" for s in (local, "remote-a", "remote-b"))
              and sections["sec_work"].get("scroll") == "flow",
              {k: v.get("scroll") for k, v in sections.items()})
        builtin = [v for v in sections.values() if v["kind"]["type"] == "builtin"]
        check("scroll defaults: built-in sections fixed",
              all(v.get("scroll") == "fixed" for v in builtin), [(v["id"], v.get("scroll")) for v in builtin])

        # The current app clears a pin flag after it shows the tile: that is
        # not an unpin.
        daemon.raw({"cmd": "set-workspace-metadata", "key": seeded["keys"]["w5"], "pinned": False})
        cleared = ws_item(daemon.ok("sidebar.get"), local, ids["w5"])
        check("a cleared pin flag leaves the workspace in Pinned",
              cleared is not None and cleared["section"] == "sec_pinned", cleared)

        # Move a workspace into Pinned (between nothing: at the end).
        def personal_row(key: str) -> dict:
            listed = daemon.raw({"cmd": "list-personal"})["workspaces"]
            return next(r for r in listed if r["session_id"] == local and r["workspace_key"] == key)

        w1_row = personal_row(seeded["keys"]["w1"])
        moved = daemon.ok("sidebar.move", {"items": [w1["id"]], "to": {"section": "sec_pinned"}}, mutate=True)
        after_pin = daemon.ok("sidebar.get")
        w1_pinned_row = personal_row(seeded["keys"]["w1"])
        check("write-back: a pin keeps the old row's group and place",
              (w1_pinned_row.get("group"), w1_pinned_row["index"]) == (w1_row.get("group"), w1_row["index"]),
              {"before": w1_row, "after": w1_pinned_row})
        check("sidebar.move puts w1 into Pinned at the end",
              [i["id"] for i in top(after_pin, "sec_pinned")][-1] == w1["id"], top(after_pin, "sec_pinned"))
        check("sidebar.move returns revision and inverse",
              moved["value"]["revision"] == "1" and len(moved["value"]["inverse"]) >= 1, moved["value"])
        layout = daemon.ok("sidebar_layout.get")
        tiles = next((s for s in layout["sections"] if s["id"] == "sec_pinned"), {"items": []})["items"]
        tile_values = [t["ref"]["value"] for t in tiles]
        # The old app drags the custom section's url tile into Pinned, then back.
        daemon.ok("sidebar_layout.update", {"op": {"kind": "item.move", "id": "itm_docs",
                                                   "section": "sec_pinned", "index": 0}}, mutate=True)
        url_moved = items_by_id(daemon.ok("sidebar.get")).get("itm_docs")
        check("old item.move of a custom-section tile into Pinned moves the document item",
              url_moved is not None and url_moved["section"] == "sec_pinned", url_moved)
        daemon.ok("sidebar_layout.update", {"op": {"kind": "item.move", "id": "itm_docs",
                                                   "section": "sec_work", "index": 0}}, mutate=True)
        check("old sidebar_layout.get shows the moved workspace as a sec_pinned tile",
              f"{local}:{ids['w1']}" in tile_values, tile_values)

        # The session.events batch of a sidebar mutation.
        key_holder: dict = {}

        def move_back() -> None:
            envelope_key = f"sbdoc-events-{next(_ids)}"
            key_holder["key"] = envelope_key
            envelope = {"protocol": PROTOCOL, "type": "request", "id": f"r{next(_ids)}",
                        "operation": "sidebar.move", "idempotency_key": envelope_key,
                        "params": {"machine": "current", "session": "current", "items": [w1["id"]],
                                   "to": {"section": "sec_pinned", "index": 0}}}
            key_holder["reply"] = daemon._line(envelope)

        batch = sidebar_batch(daemon, move_back)
        marker = next((c for c in (batch or {}).get("changes", []) if c.get("resource") == "sidebar_doc"), {})
        kinds = {(c.get("kind"), c.get("resource")) for c in (batch or {}).get("changes", [])}
        check("session.events batch carries sidebar_item upserts and the sidebar_doc revision and key",
              ("state_upsert", "sidebar_item") in kinds
              and marker.get("value", {}).get("idempotency_key") == key_holder.get("key")
              and marker.get("value", {}).get("revision") == key_holder["reply"]["result"]["value"]["revision"],
              {"kinds": sorted(map(str, kinds)), "marker": marker})

        # A group into a custom section, then undo with the inverse.
        before_group = daemon.ok("sidebar.get")
        grouped = daemon.ok("sidebar.move", {"items": [frontend["id"]], "to": {"section": "sec_work", "index": 0}},
                            mutate=True)
        after_group = daemon.ok("sidebar.get")
        moved_group = items_by_id(after_group)[frontend["id"]]
        kids = [c["section"] for c in children(after_group, frontend["id"])]
        check("group moves into a custom section with its workspaces",
              moved_group["section"] == "sec_work" and kids == ["sec_work", "sec_work"]
              and top(after_group, "sec_work")[0]["id"] == frontend["id"], moved_group)

        # cross_machine refusals.
        ra1 = ws_item(after_group, "remote-a", "ra1")
        refused = daemon.v2("sidebar.move", {"items": [ra1["id"]], "to": {"section": f"sec_m_{local}"}}, mutate=True)
        reason = (refused.get("error") or {}).get("details", {}).get("reason")
        check("remote-a workspace into this machine's section is refused cross_machine",
              not refused.get("ok") and refused["error"]["code"] == "validation.invalid" and reason == "cross_machine",
              refused)
        refused = daemon.v2("sidebar.move", {"items": [remote["id"]], "to": {"section": "sec_m_remote-b"}},
                            mutate=True)
        check("remote-a group into remote-b's section is refused cross_machine",
              not refused.get("ok") and (refused.get("error") or {}).get("details", {}).get("reason") == "cross_machine",
              refused)
        unchanged = daemon.ok("sidebar.get")
        check("a refusal writes nothing", unchanged == after_group)

        undone = daemon.ok("sidebar.apply", {"ops": grouped["value"]["inverse"]}, mutate=True)
        after_undo = daemon.ok("sidebar.get")
        strip = lambda d: {"sections": d["sections"], "items": d["items"]}
        check("sidebar.apply with the inverse restores the document", strip(after_undo) == strip(before_group))
        check("undo returns the redo", len(undone["value"]["inverse"]) == len(grouped["value"]["inverse"]))

        # Slice 2: section scroll and row limit, url favicons.
        revision = int(daemon.ok("sidebar.get")["revision"])
        daemon.ok("sidebar.section.update", {"id": "sec_work", "patch": {"scroll": "fixed", "max_rows": 6}},
                  mutate=True)
        work_section = {s["id"]: s for s in daemon.ok("sidebar.get")["sections"]}["sec_work"]
        check("section.update sets scroll and max_rows",
              work_section.get("scroll") == "fixed" and work_section.get("max_rows") == 6, work_section)
        refused = daemon.v2("sidebar.section.update", {"id": "sec_work", "patch": {"max_rows": 51}}, mutate=True)
        check("max_rows over 50 is refused invalid_value",
              not refused.get("ok") and reason_of(refused) == "invalid_value", refused)
        refused = daemon.v2("sidebar.section.update", {"id": "sec_work", "patch": {"scroll": "sticky"}},
                            mutate=True)
        check("an unknown scroll value is refused", not refused.get("ok"), refused)
        ran = cli(daemon, "sidebar", "section-scroll", "sec_work", "flow")
        ran_rows = cli(daemon, "sidebar", "section-max-rows", "sec_work", "3")
        work_section = {s["id"]: s for s in daemon.ok("sidebar.get")["sections"]}["sec_work"]
        check("cmux sidebar section-scroll / section-max-rows update the section",
              ran.returncode == 0 and ran_rows.returncode == 0
              and work_section.get("scroll") == "flow" and work_section.get("max_rows") == 3,
              {"scroll": (ran.returncode, ran.stderr[-300:]), "rows": (ran_rows.returncode, ran_rows.stderr[-300:]),
               "section": work_section})
        bad = cli(daemon, "sidebar", "section-max-rows", "sec_work", "99")
        bad_scroll = cli(daemon, "sidebar", "section-scroll", "sec_work", "sideways")
        none = cli(daemon, "sidebar", "section-max-rows", "sec_work", "none")
        work_section = {s["id"]: s for s in daemon.ok("sidebar.get")["sections"]}["sec_work"]
        check("the CLI refuses bad values and `none` clears max_rows",
              bad.returncode != 0 and bad_scroll.returncode != 0 and none.returncode == 0
              and "max_rows" not in work_section, {"bad": bad.returncode, "bad_scroll": bad_scroll.returncode,
                                           "none": (none.returncode, none.stderr[-300:]), "section": work_section})
        daemon.ok("sidebar.section.move", {"id": "sec_work", "place": {"region": "top"}}, mutate=True)
        moved_top = {s["id"]: s for s in daemon.ok("sidebar.get")["sections"]}["sec_work"]
        daemon.ok("sidebar.section.move", {"id": "sec_work", "place": {"region": "middle"}}, mutate=True)
        moved_back = {s["id"]: s for s in daemon.ok("sidebar.get")["sections"]}["sec_work"]
        check("a default scroll follows the region of a section.move (top fixed, middle flow)",
              moved_top.get("scroll") == "fixed" and moved_back.get("scroll") == "flow",
              {"top": moved_top.get("scroll"), "back": moved_back.get("scroll")})
        new_icon = "https://example.com/new.ico"
        daemon.ok("sidebar.item.update", {"id": "itm_docs", "patch": {"icon_url": new_icon}}, mutate=True)
        docs = items_by_id(daemon.ok("sidebar.get"))["itm_docs"]
        check("item.update sets a url item's icon_url", docs["body"].get("icon_url") == new_icon, docs)
        w6_item = ws_item(daemon.ok("sidebar.get"), local, ids["w6"])
        refused = daemon.v2("sidebar.item.update", {"id": w6_item["id"], "patch": {"icon_url": new_icon}},
                            mutate=True)
        check("icon_url on a workspace item is refused invalid_value",
              not refused.get("ok") and reason_of(refused) == "invalid_value", refused)
        daemon.ok("sidebar.item.add", {"item": {"id": "itm_news", "body": {"type": "url", "url": "https://example.org"},
                                                "extra": {"icon_url": FAVICON}},
                                       "to": {"section": "sec_pinned"}}, mutate=True)
        news = items_by_id(daemon.ok("sidebar.get"))["itm_news"]
        check("item.add lifts an old client's extra.icon_url into the body",
              news["body"].get("icon_url") == FAVICON and "icon_url" not in news.get("extra", {}), news)
        layout = daemon.ok("sidebar_layout.get")
        news_tile = next((t for s in layout["sections"] if s["id"] == "sec_pinned" for t in s["items"]
                          if t["id"] == "itm_news"), None)
        check("old sidebar_layout.get restates a Pinned url's icon_url for old clients",
              news_tile is not None and news_tile.get("icon_url") == FAVICON, news_tile)
        daemon.ok("sidebar.item.update", {"id": "itm_news", "patch": {"icon_url": None}}, mutate=True)
        news = items_by_id(daemon.ok("sidebar.get"))["itm_news"]
        check("item.update icon_url null clears it", "icon_url" not in news["body"], news)
        daemon.ok("sidebar.item.remove", {"id": "itm_news"}, mutate=True)
        check("slice 2 mutations advanced the revision",
              int(daemon.ok("sidebar.get")["revision"]) > revision)

        # Old verbs and new workspaces follow into the document.
        old_group = daemon.ok("workspace_group.create", {"name": "Old verbs"}, mutate=True)["value"]["id"]
        created = daemon.ok("workspace.create", {"name": "w7", "initial_content": "empty"}, mutate=True)
        w7 = created["value"]["workspace_id"]
        followed = daemon.ok("sidebar.get")
        check("old workspace_group.create shows as a group item",
              any(i["id"] == f"itm_g_{old_group}" for i in followed["items"]))
        new_item = ws_item(followed, local, w7)
        check("a new workspace is adopted into its machine section",
              new_item is not None and new_item["section"] == f"sec_m_{local}", new_item)
        # Closes: a machine-section workspace leaves the doc; a pinned one stays.
        daemon.ok("workspace.close", {"workspace": w7}, mutate=True)
        daemon.ok("workspace.close", {"workspace": ids["w5"]}, mutate=True)
        closed = daemon.ok("sidebar.get")
        check("a closed workspace is removed from its machine section", ws_item(closed, local, w7) is None)
        kept = ws_item(closed, local, ids["w5"])
        check("a closed workspace in Pinned stays", kept is not None and kept["section"] == "sec_pinned", kept)

        # Write-back: old readers (list-personal) see document moves and groups.
        w3 = ws_item(closed, local, ids["w3"])
        daemon.ok("sidebar.move", {"items": [w3["id"]], "to": {"section": f"sec_m_{local}", "index": 0}},
                  mutate=True)
        made = daemon.ok("sidebar.group.create", {"name": "DocGroup", "items": [ws_item(closed, local, ids["w2"])["id"]]},
                         mutate=True)
        daemon.ok("sidebar.move", {"items": [w1["id"]], "to": {"section": f"sec_m_{local}",
                                                               "parent": frontend["id"]}}, mutate=True)
        personal = daemon.raw({"cmd": "list-personal"})
        rows = [r for r in personal["workspaces"] if r["session_id"] == local]
        by_key = {r["workspace_key"]: r for r in rows}
        keys = seeded["keys"]
        groups_by_name = {g["name"]: g["id"] for g in personal["groups"]}
        check("write-back: a document move out of a group ungroups the old row",
              by_key[keys["w3"]].get("group") in (None, ""), by_key[keys["w3"]])
        check("write-back: sidebar.group.create makes an old group holding its workspace",
              "DocGroup" in groups_by_name and by_key[keys["w2"]].get("group") == groups_by_name["DocGroup"],
              {"groups": list(groups_by_name), "w2": by_key[keys["w2"]]})
        check("write-back: a move into a group sets the old row's group",
              by_key[keys["w1"]].get("group") == seeded["frontend"], by_key[keys["w1"]])
        after_moves = daemon.ok("sidebar.get")
        id_to_key = {ids[name]: key for name, key in keys.items()}
        doc_loose = [id_to_key[i["body"]["ref"]["workspace_id"]] for i in top(after_moves, f"sec_m_{local}")
                     if i["body"].get("type") == "workspace" and i["body"]["ref"]["workspace_id"] in id_to_key]
        old_loose = [r["workspace_key"] for r in sorted(rows, key=lambda r: r["index"])
                     if not r.get("group") and r["workspace_key"] in doc_loose]
        check("write-back: the old order of this machine's loose rows matches the document",
              old_loose == doc_loose and doc_loose[:1] == [keys["w3"]], {"old": old_loose, "doc": doc_loose})
        assert made["value"]["revision"]
        # Gap positions: a personal move writes the moved row only.
        def positions() -> dict:
            with sqlite3.connect(f"file:{registry}?mode=ro", uri=True) as db:
                return {(s, k): p for s, k, p in db.execute(
                    "SELECT session_id, workspace_key, position FROM personal_workspaces")}
        before_place = positions()
        daemon.ok("workspace.place", {"workspace": ids["w6"], "index": 1}, mutate=True)
        daemon.ok("workspace.place", {"workspace": ids["w1"], "index": 0}, mutate=True)
        after_place = positions()
        rewritten = sorted(k for k in before_place if before_place[k] != after_place.get(k))
        check("workspace.place writes only the moved rows (no renumbering of the others)",
              rewritten == sorted([(local, keys["w6"]), (local, keys["w1"])]), rewritten)
        listed = daemon.raw({"cmd": "list-personal"})["workspaces"]
        first = min(listed, key=lambda r: r["index"])
        check("the moved row is first in the old personal order",
              (first["session_id"], first["workspace_key"]) == (local, keys["w1"]), first)
        order = [w["id"] for w in daemon.ok("workspace.list", {"order": "personal"})]
        check("workspace.list personal order follows the document (Pinned first)",
              order.index(ids["w6"]) < order.index(ids["w3"]), order)
        # Placement shift (doc3): a new top workspace or a move shifts the
        # other rows' ordinals; a placement-shift-v1 reader gets only the new
        # or moved placement, an old-protocol reader every shifted one, and a
        # reader that echoes only sidebar-doc-v1 is an old-protocol reader.
        check("capability placement-shift-v1 advertised", "placement-shift-v1" in caps)
        doc_reader = EventStream(daemon, ["placement-shift-v1", "sidebar-doc-v1"])
        old_reader = EventStream(daemon)
        doc_only_reader = EventStream(daemon, ["sidebar-doc-v1"])
        try:
            known = {(r["session_id"], r["workspace_key"])
                     for r in daemon.raw({"cmd": "list-personal"})["workspaces"]}
            created = daemon.ok("workspace.create", {"name": "w8", "initial_content": "empty"}, mutate=True)
            w8 = created["value"]["workspace_id"]
            rows = daemon.raw({"cmd": "list-personal"})["workspaces"]
            w8_row = next(r for r in rows if (r["session_id"], r["workspace_key"]) not in known)
            w8_id = f"{local}/{w8_row['workspace_key']}"
            expected = {f"{r['session_id']}/{r['workspace_key']}": r["index"] for r in rows
                        if r["index"] > w8_row["index"]}
            doc_batch = placements_of(doc_reader.delta_with("workspace_placement", w8_id))
            old_batch = placements_of(old_reader.delta_with("workspace_placement", w8_id))
            doc_only_batch = placements_of(doc_only_reader.delta_with("workspace_placement", w8_id))
            check("create: a reader that echoes only sidebar-doc-v1 still gets every shifted placement",
                  bool(expected) and all(doc_only_batch.get(pid) == index for pid, index in expected.items()),
                  {"missing": sorted(set(expected) - set(doc_only_batch))[:5]})
            check("create: a placement-shift-v1 reader gets only the new workspace's placement (no restatement)",
                  doc_batch == {w8_id: w8_row["index"]} and expected, {"doc": doc_batch, "shifted": len(expected)})
            check("create: an old-protocol reader still gets every shifted placement at its new index",
                  all(old_batch.get(pid) == index for pid, index in expected.items())
                  and old_batch.get(w8_id) == w8_row["index"],
                  {"missing": sorted(set(expected) - set(old_batch))[:5],
                   "wrong": {p: (old_batch.get(p), i) for p, i in expected.items() if old_batch.get(p) not in (None, i)}})
            target = w8_row["index"] + 3
            check("place: the target index is inside the order", target < len(rows),
                  {"target": target, "rows": len(rows)})
            daemon.ok("workspace.place", {"workspace": w8, "index": min(target, len(rows) - 1)}, mutate=True)
            rows = daemon.raw({"cmd": "list-personal"})["workspaces"]
            moved = next(r for r in rows if f"{r['session_id']}/{r['workspace_key']}" == w8_id)
            between = {f"{r['session_id']}/{r['workspace_key']}": r["index"] for r in rows
                       if w8_row["index"] <= r["index"] <= moved["index"]}
            doc_place = placements_of(doc_reader.delta_with("workspace_placement", w8_id, moved["index"]))
            old_place = placements_of(old_reader.delta_with("workspace_placement", w8_id, moved["index"]))
            check("place: a placement-shift-v1 reader gets only the moved placement",
                  doc_place == {w8_id: moved["index"]}, doc_place)
            check("place: an old-protocol reader gets every placement between the old and new index",
                  len(between) > 1 and all(old_place.get(pid) == index for pid, index in between.items()),
                  {"between": between, "got": old_place})
            daemon.ok("workspace.close", {"workspace": w8}, mutate=True)
        finally:
            doc_reader.close()
            old_reader.close()
            doc_only_reader.close()
        final = daemon.ok("sidebar.get")
    finally:
        daemon.stop()

    # Restart: order survives, and the migration does not run again.
    daemon.start()
    try:
        restarted = daemon.ok("sidebar.get")
        check("order and revision survive a daemon restart", restarted == final,
              {"before": final["revision"], "after": restarted["revision"]})
        check("migration twice is a no-op (no duplicate sections or items)",
              len(restarted["items"]) == len(final["items"]) and len(restarted["sections"]) == len(final["sections"]))
        layout = daemon.ok("sidebar_layout.get")
        tiles = next((s for s in layout["sections"] if s["id"] == "sec_pinned"), {"items": []})["items"]
        check("old sidebar_layout.get still shows the pinned items after restart",
              f"{local}:{ids['w6']}" in [t["ref"]["value"] for t in tiles], tiles)
        one_order(daemon, local)
    finally:
        daemon.stop()
    doc_slice_4(args.binary.resolve(), seed_state, work / "state4", sock, seeded)
    print(f"{'FAILED' if failures else 'OK'}: {len(failures)} failure(s); workdir {work}", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
