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
    custom = {"id": "sec_work", "title": "Work", "region": "middle", "look": "list", "content": "items",
              "items": [{"id": "itm_docs", "ref": {"kind": "url", "value": "https://example.com/docs"}}]}
    daemon.ok("sidebar_layout.update", {"op": {"kind": "section.add", "section": custom, "index": 99}}, mutate=True)
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
    check("seed copy holds old rows and no sidebar document", rows >= 11 and groups == 3 and no_doc,
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

        # Move a workspace into Pinned (between nothing: at the end).
        moved = daemon.ok("sidebar.move", {"items": [w1["id"]], "to": {"section": "sec_pinned"}}, mutate=True)
        after_pin = daemon.ok("sidebar.get")
        check("sidebar.move puts w1 into Pinned at the end",
              [i["id"] for i in top(after_pin, "sec_pinned")][-1] == w1["id"], top(after_pin, "sec_pinned"))
        check("sidebar.move returns revision and inverse",
              moved["value"]["revision"] == "1" and len(moved["value"]["inverse"]) >= 1, moved["value"])
        layout = daemon.ok("sidebar_layout.get")
        tiles = next((s for s in layout["sections"] if s["id"] == "sec_pinned"), {"items": []})["items"]
        tile_values = [t["ref"]["value"] for t in tiles]
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
        order = [w["id"] for w in daemon.ok("workspace.list", {"order": "personal"})]
        check("workspace.list personal order follows the document (Pinned first)",
              order.index(ids["w6"]) < order.index(ids["w3"]), order)
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
    finally:
        daemon.stop()
    print(f"{'FAILED' if failures else 'OK'}: {len(failures)} failure(s); workdir {work}", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
