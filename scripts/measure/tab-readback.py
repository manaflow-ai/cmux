#!/usr/bin/env python3
"""The app half of scripts/measure/tab-readback.sh: two merged fixes read back on a running NIGHTLY side instance.

  tab-readback.py --app APP --pid-file F --out DIR [--control-socket S] [--dmg URL] [--tabs N]

tabs (#52099, ask-3fda3b3a7e)
    One pane gets new tabs one at a time (`action.run newTab.default`, the strip's + and Cmd-T path) until it holds
    N (default 24), 0.8 s apart, then a burst of 4 with no pause, while the display is recorded (the .sh). Window
    shots at 4, 12, N tabs and after the burst; the tab titles as the accessibility tree reports them. The judge of
    "the end bit the text has a weird rewritten thing" is the recording and the shots, so this part passes when
    the tabs opened and the shots exist; the reader looks at them.
pin (#52050, ask c-b5d3e0efb6, task #134 "Mango")
    Through the copy's own daemon (its socket found as hot-apply.py does): a group Leads holding Kiwi, Mango and
    Plum; Mango then flagged pinned inside the group (`extra.pinned`, first among Leads' members), the pin an older
    daemon made. Its hover Unpin (AX "Unpin workspace", after the pointer rests on the row) is pressed, else its
    menu's Unpin Workspace. Pass: after it, Mango's sidebar item is still in Leads (same section and parent), no
    longer flagged, and no "Unpin" control shows for the row under the pointer. Shots before, hovered, after.
Writes OUT/result.json and prints `TAB_READBACK {json}`. Exit 0 when both parts pass.
"""
from __future__ import annotations

import argparse
import importlib.util
import itertools
import json
import os
import plistlib
import socket
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


lkr = load("lkr", HERE / "look-keys-readback.py")
hot = load("hot_apply", ROOT / "scripts/cmux-next/hot-apply.py")
PROTOCOL = "cmux.protocol/2"
_ids = itertools.count(1)


def mark(what: str) -> None:
    """A timestamp the reader matches against the recording (its READY epoch_ms)."""
    lkr.say(f"MARK epoch_ms={int(time.time() * 1000)} {what}")


# ---------------------------------------------------------------- daemon


def v2(sock: str, operation: str, params: dict | None = None, mutate: bool = False) -> dict:
    envelope = {"protocol": PROTOCOL, "type": "request", "id": f"r{next(_ids)}", "operation": operation,
                "params": {"machine": "current", "session": "current", **(params or {})}}
    if mutate:
        envelope["idempotency_key"] = f"tabrb-{os.getpid()}-{next(_ids)}"
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(20)
            conn.connect(sock)
            conn.sendall(json.dumps(envelope).encode() + b"\n")
            buf = b""
            while True:
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    reply = json.loads(line)
                    if reply.get("id") == envelope["id"] or reply.get("type") == "response":
                        return reply
                chunk = conn.recv(1 << 20)
                if not chunk:
                    return {"ok": False, "error": "socket closed"}
                buf += chunk
    except (OSError, ValueError) as error:
        return {"ok": False, "error": str(error)}


def ok(sock: str, operation: str, params: dict | None = None, mutate: bool = False):
    reply = v2(sock, operation, params, mutate)
    if not reply.get("ok"):
        raise RuntimeError(f"{operation}: {json.dumps(reply.get('error'))[:600]}")
    return reply.get("result")


def doc_item(doc: dict, workspace_id: str) -> dict | None:
    """The sidebar item that shows WORKSPACE_ID (its ref names it)."""
    for item in doc.get("items") or []:
        body = json.dumps(item.get("body") or item.get("ref") or {})
        if workspace_id in body:
            return item
    return None


def placement(item: dict | None) -> dict | None:
    if not item:
        return None
    return {"id": item.get("id"), "section": item.get("section"), "parent": item.get("parent"),
            "order": item.get("order"), "pinned_flag": (item.get("extra") or {}).get("pinned"),
            "unpin_to": (item.get("extra") or {}).get("unpin_to")}


def members(doc: dict, parent: str | None) -> list[str]:
    rows = [i for i in doc.get("items") or [] if parent and i.get("parent") == parent]
    return [i["id"] for i in sorted(rows, key=lambda i: (str(i.get("order") or ""), i["id"]))]


# ---------------------------------------------------------------- AX


def ax_elements(pid: int) -> list:
    found: list = []

    def visit(node, window_id):
        if isinstance(node, dict):
            if "role" in node and ("element_token" in node or "element_index" in node or "frame" in node):
                found.append(dict(node, _window=window_id))
            for value in node.values():
                visit(value, window_id)
        elif isinstance(node, list):
            for value in node:
                visit(value, window_id)

    for window in lkr.cua("list_windows", {"pid": pid}).get("windows") or []:
        if isinstance(window, dict) and window.get("window_id") is not None:
            state = lkr.cua("get_window_state", {"pid": pid, "window_id": window["window_id"],
                                                 "include_screenshot": False, "max_depth": 80, "max_elements": 8000})
            visit(state, window["window_id"])
    return found


def label_of(element: dict) -> str:
    for key in ("label", "title", "value", "description", "name", "identifier"):
        if str(element.get(key) or "").strip():
            return str(element[key]).strip()
    return ""


def labels(element: dict) -> str:
    return " ".join(str(element.get(k) or "") for k in ("label", "title", "value", "description", "name",
                                                         "identifier")).lower()


def press(pid: int, element: dict, button: str = "left") -> dict:
    if "element_token" in element or "element_index" in element:
        token = ({"element_token": element["element_token"]} if "element_token" in element
                 else {"element_index": element["element_index"]})
        args = {"pid": pid, "window_id": element["_window"], **token}
        if button != "left":
            args["button"] = button
        return lkr.cua("click", args)
    f = element.get("frame") or {}
    return lkr.cua("click", {"x": f["x"] + f["w"] / 2, "y": f["y"] + f["h"] / 2, "scope": "desktop",
                             **({"button": button} if button != "left" else {})})


def frame_of(element: dict) -> dict | None:
    f = element.get("frame") or element.get("bounds")
    if isinstance(f, dict) and {"x", "y"} <= f.keys():
        w = f.get("w", f.get("width"))
        h = f.get("h", f.get("height"))
        if w is not None and h is not None:
            return {"x": f["x"], "y": f["y"], "w": w, "h": h}
    return None


def hover(element: dict, scale: float) -> list:
    """Rest the pointer on ELEMENT's center (desktop scope), in points and, when that shows nothing, in pixels."""
    f = frame_of(element)
    if not f:
        return [{"error": "no frame", "element": {k: element.get(k) for k in ("role", "label", "title")}}]
    x, y = f["x"] + f["w"] * 0.4, f["y"] + f["h"] / 2
    return [lkr.cua("move_cursor", {"x": round(x * s), "y": round(y * s), "scope": "desktop"}) for s in (scale,)]


def unpin_controls(pid: int) -> list:
    return [e for e in ax_elements(pid) if "unpin" in labels(e)]


# ---------------------------------------------------------------- parts


def tabs_part(sock: str, pid: int, out: Path, count: int) -> dict:
    folder = out / "tabs"
    steps: list = []
    first = lkr.rpc(sock, "action.run", {"action": "newTab", "focus": True}, timeout=30)  # its own workspace
    steps.append({"step": "new workspace", "reply": first})
    time.sleep(2)
    steps.append({"step": "start", "shots": lkr.shoot(pid, folder, "00-start")})
    mark("tabs: one at a time")
    opened = 0
    for n in range(1, count + 1):
        reply = lkr.rpc(sock, "action.run", {"action": "newTab.default", "focus": True}, timeout=30)
        opened += 0 if reply.get("error") else 1
        time.sleep(0.8)
        if n in (4, 12, count):
            time.sleep(1.2)  # at rest
            steps.append({"step": f"{n} tabs", "reply": reply, "shots": lkr.shoot(pid, folder, f"{n:02d}-tabs")})
    mark("tabs: burst of 4")
    for _ in range(4):
        reply = lkr.rpc(sock, "action.run", {"action": "newTab.default", "focus": True}, timeout=30)
        opened += 0 if reply.get("error") else 1
    time.sleep(0.25)
    steps.append({"step": "burst, mid-motion", "shots": lkr.shoot(pid, folder, "burst-1-mid")})
    time.sleep(2)
    steps.append({"step": "burst, at rest", "shots": lkr.shoot(pid, folder, "burst-2-rest")})
    mark("tabs: done")
    titles = [label_of(e) for e in ax_elements(pid) if "tab" in str(e.get("role", "")).lower()
              or "tab" in str(e.get("subrole", "")).lower()]
    shots_ok = all(s.get("shots", {}).get("window") or s.get("shots", {}).get("desktop")
                   for s in steps if "shots" in s)
    return {"part": "tabs", "pr": 52099, "asked": count + 4, "opened": opened, "tab_titles_ax": titles[:80],
            "ok": opened >= count and shots_ok, "steps": steps}


def pin_part(sock: str, daemon: str, pid: int, out: Path, scale: float) -> dict:
    folder = out / "pin"
    steps: list = []
    names = {}
    for name in ("Kiwi", "Mango", "Plum"):
        created = ok(daemon, "workspace.create", {"name": name, "initial_content": "empty"}, mutate=True)
        names[name] = (created.get("value") or created).get("workspace_id")
    group = ok(daemon, "workspace_group.create", {"name": "Leads"}, mutate=True)
    group_id = (group.get("value") or group).get("id")
    for name in ("Kiwi", "Mango", "Plum"):
        ok(daemon, "workspace.place", {"workspace": names[name], "group": group_id}, mutate=True)
    time.sleep(1.5)
    doc = ok(daemon, "sidebar.get")
    mango = doc_item(doc, names["Mango"])
    if not mango:
        return {"part": "pin", "ok": False, "error": "no sidebar item for Mango", "names": names}
    # The pin an older daemon made inside the group: the member flagged pinned, first among its members.
    item = dict(mango)
    item["extra"] = dict(item.get("extra") or {}, pinned=True)
    to = {"section": item["section"], "index": 0, **({"parent": item["parent"]} if item.get("parent") else {})}
    seeded = v2(daemon, "sidebar.apply", {"ops": [{"op": "item.put", "item": item},
                                                  {"op": "move", "items": [item["id"]], "to": to}]}, mutate=True)
    steps.append({"step": "seed legacy in-group pin", "ok": seeded.get("ok"), "error": seeded.get("error")})
    time.sleep(2)
    doc = ok(daemon, "sidebar.get")
    before = placement(doc_item(doc, names["Mango"]))
    before_members = members(doc, before and before["parent"])
    steps.append({"step": "before", "placement": before, "group_members": before_members,
                  "shots": lkr.shoot(pid, folder, "00-before")})
    mark("pin: before unpin")
    rows = [e for e in ax_elements(pid) if "mango" in labels(e) and frame_of(e)]
    row = min(rows, key=lambda e: frame_of(e)["w"] * frame_of(e)["h"] * -1) if rows else None
    via, reply = None, None
    if row:
        steps.append({"step": "hover Mango", "row": {k: row.get(k) for k in ("role", "label", "title", "frame")},
                      "move": hover(row, 1.0)})
        time.sleep(1.0)
        controls = unpin_controls(pid)
        if not controls:  # a frame in pixels: try the scaled point
            steps.append({"step": "hover Mango (scaled)", "move": hover(row, scale)})
            time.sleep(1.0)
            controls = unpin_controls(pid)
        steps[-1]["shots"] = lkr.shoot(pid, folder, "01-hovered")
        steps[-1]["unpin_controls"] = [label_of(c) for c in controls]
        if controls:
            via, reply = "hover Unpin", press(pid, controls[0])
        else:
            menu = press(pid, row, button="right")
            time.sleep(1.0)
            item_ = next((e for e in ax_elements(pid) if "unpin workspace" in labels(e)), None)
            steps.append({"step": "right-click Mango", "reply": menu, "shots": lkr.shoot(pid, folder, "01b-menu"),
                          "menu_unpin": bool(item_)})
            if item_:
                via, reply = "menu Unpin Workspace", press(pid, item_)
            else:
                lkr.cua("press_key", {"pid": pid, "key": "escape"})
    else:
        steps.append({"step": "find Mango row", "error": "no AX element named Mango with a frame",
                      "sample": [{k: e.get(k) for k in ("role", "label", "title", "frame")} for e in
                                 ax_elements(pid)[:60]]})
    steps.append({"step": "unpin", "via": via, "reply": reply})
    mark(f"pin: unpinned via {via}")
    time.sleep(1.5)
    doc = ok(daemon, "sidebar.get")
    after = placement(doc_item(doc, names["Mango"]))
    after_members = members(doc, after and after["parent"])
    steps.append({"step": "after", "placement": after, "group_members": after_members,
                  "shots": lkr.shoot(pid, folder, "02-after")})
    still_unpin = []
    if row:
        rows = [e for e in ax_elements(pid) if "mango" in labels(e) and frame_of(e)]
        row2 = min(rows, key=lambda e: frame_of(e)["w"] * frame_of(e)["h"] * -1) if rows else row
        hover(row2, 1.0)
        time.sleep(1.0)
        still_unpin = [label_of(c) for c in unpin_controls(pid)]
        steps.append({"step": "hover after", "unpin_controls": still_unpin,
                      "shots": lkr.shoot(pid, folder, "03-hover-after")})
    in_place = bool(before and after and after["section"] == before["section"]
                    and after["parent"] == before["parent"] and before["parent"])
    unflagged = bool(before and before["pinned_flag"] and after and not after["pinned_flag"])
    return {"part": "pin", "pr": 52050, "names": names, "group": group_id, "via": via, "in_place": in_place,
            "unflagged": unflagged, "unpin_gone": via is not None and not still_unpin,
            "ok": bool(via) and in_place and unflagged and not still_unpin, "steps": steps}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--control-socket")
    parser.add_argument("--dmg", default="")
    parser.add_argument("--tabs", type=int, default=24)
    args = parser.parse_args()
    app, out = Path(args.app), Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    with open(app / "Contents/Info.plist", "rb") as handle:
        info = plistlib.load(handle)
    pid = int(Path(args.pid_file).read_text().strip())
    receipt: dict = {"host": os.uname().nodename, "dmg": args.dmg, "app_version": info.get("CFBundleVersion"),
                     "app_short_version": info.get("CFBundleShortVersionString"),
                     "app_commit": info.get("CMUXCommit"), "parts": []}
    sock = lkr.wait_for(lambda: lkr.control_socket(pid, args.control_socket), 120, step=0.5)
    if not sock:
        receipt["error"] = "the copy's control socket never answered"
    else:
        time.sleep(4)
        scale = float(lkr.cua("get_screen_size", {}).get("scale_factor") or 2.0)
        receipt["scale"] = scale
        try:
            receipt["parts"].append(tabs_part(sock, pid, out, args.tabs))
        except Exception as error:
            receipt["parts"].append({"part": "tabs", "ok": False, "error": f"{type(error).__name__}: {error}"})
        cli = (app / hot.BIN / "cmux").resolve()
        daemon = lkr.wait_for(lambda: hot.find_socket(app, cli), 120, step=1)
        receipt["daemon_socket"] = daemon
        try:
            if not daemon:
                raise RuntimeError("the copy's daemon socket was not found")
            receipt["parts"].append(pin_part(sock, daemon, pid, out, scale))
        except Exception as error:
            receipt["parts"].append({"part": "pin", "ok": False, "error": f"{type(error).__name__}: {error}"})
    receipt["ok"] = len(receipt["parts"]) == 2 and all(p.get("ok") for p in receipt["parts"])
    (out / "result.json").write_text(json.dumps(receipt, indent=2))
    lkr.say("TAB_READBACK " + json.dumps(receipt)[:8000])
    return 0 if receipt["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
