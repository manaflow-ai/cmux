#!/usr/bin/env python3
"""The app half of scripts/measure/customizer-toggle-readback.sh: from a cold start of a NIGHTLY side instance, walk
the shortest path a person takes to the See-Through Dock switch (experiments.seeThroughDock, #53569) and count it.

  customizer-toggle-readback.py --app APP --pid-file F --out DIR [--control-socket S] [--dmg URL]

Paths, each step a window and a desktop shot (look-keys-readback.py's shoot):
  nav     Cmd-, (action.run openSettings: a key press, not a click) -> click the Advanced section link
          ([data-section-link="advanced"]) -> click the switch in [data-row-key="experiments.seeThroughDock"]
  search  Cmd-, -> type "see-through" in the search field (focusSearch, Cmd-F: keys) -> click the switch
Clicks are what the path needs a pointer for; key presses are counted apart. A step the switch is already in view
for is skipped and not counted (whether the row is in view is read from its rect against the page's viewport). The
switch is read back with settings.get after each flip and flipped back off at the end, so the copy ends as it began.
Writes OUT/result.json and prints `CUSTOMIZER_TOGGLE_READBACK {json}`. Exit 0 when the switch read back on after a
flip on some path, 1 otherwise.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import plistlib
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("lkr", HERE / "look-keys-readback.py")
lkr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lkr)

KEY = "experiments.seeThroughDock"
TITLE = "see-through dock"


def ax_elements(pid: int) -> list:
    """Every AX element of the copy's windows, in tree order: dicts with role, a label and a token to click it by.
    A release NIGHTLY has no debug.page (DEBUG and CMUX_BENCH_HOOKS only), so the page is read and driven the way a
    person's pointer does: through the accessibility tree cua-driver reports."""
    found: list = []

    def visit(node, window_id):
        if isinstance(node, dict):
            if "role" in node and ("element_token" in node or "element_index" in node):
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
    for key in ("label", "title", "value", "description", "name"):
        if str(element.get(key) or "").strip():
            return str(element[key]).strip()
    return ""


def is_toggle(element: dict) -> bool:
    role = str(element.get("role", "")).lower()
    return any(word in role for word in ("switch", "checkbox", "toggle"))


def find_switch(pid: int) -> dict | None:
    """The See-Through Dock switch: a switch or checkbox named for it, else the first one after its text."""
    elements = ax_elements(pid)
    for element in elements:
        if is_toggle(element) and TITLE in label_of(element).lower():
            return element
    for i, element in enumerate(elements):
        if TITLE in label_of(element).lower():
            return next((e for e in elements[i:i + 12] if is_toggle(e)), None)
    return None


def find_labelled(pid: int, text: str, toggle: bool = False) -> dict | None:
    return next((e for e in ax_elements(pid) if text in label_of(e).lower() and (not toggle or is_toggle(e))), None)


def press(pid: int, element: dict) -> dict:
    token = {"element_token": element["element_token"]} if "element_token" in element else {"element_index": element["element_index"]}
    return lkr.cua("click", {"pid": pid, "window_id": element["_window"], **token})


def outline(pid: int) -> list:
    return [f"{e.get('role')} | {label_of(e)}"[:100] for e in ax_elements(pid)][:150]


def open_settings(sock: str, pid: int) -> dict:
    reply = lkr.rpc(sock, "action.run", {"action": "openSettings", "focus": True}, timeout=30)
    ready = lkr.wait_for(lambda: find_labelled(pid, "advanced") or find_labelled(pid, TITLE), 30, step=1)
    return {"reply": reply, "page_ready": bool(ready)}


def close_settings(sock: str) -> None:
    lkr.rpc(sock, "action.run", {"action": "closeTab", "focus": True}, timeout=15)
    time.sleep(1)


def click_switch(pid: int) -> dict:
    switch = find_switch(pid)
    if not switch:
        return {"error": "no switch matched", "outline": outline(pid)}
    return {"clicked": label_of(switch), "role": switch.get("role"), "reply": press(pid, switch)}


def walk(sock: str, pid: int, out: Path, name: str, search: bool) -> dict:
    folder = out / name
    steps, clicks, keys = [], 0, 0
    before = lkr.read_key(sock, KEY)
    steps.append({"step": "cold", "shots": lkr.shoot(pid, folder, "00-start")})
    steps.append({"step": "Cmd-, (openSettings)", **open_settings(sock, pid)})
    keys += 1
    time.sleep(1.5)
    steps[-1]["shots"] = lkr.shoot(pid, folder, "01-settings")
    if search:
        window = next((e["_window"] for e in ax_elements(pid) if "search" in label_of(e).lower()), None)
        hotkey = lkr.cua("hotkey", {"pid": pid, **({"window_id": window} if window else {}), "keys": ["cmd", "f"]})
        typed = lkr.cua("type_text", {"text": "see-through", "scope": "desktop"})
        steps.append({"step": "Cmd-F + type see-through", "hotkey": hotkey, "type": typed})
        keys += 2  # Cmd-F and the typing
        time.sleep(1.5)
        steps[-1]["shots"] = lkr.shoot(pid, folder, "02-search")
    elif not find_switch(pid):
        link = find_labelled(pid, "advanced")
        reply = press(pid, link) if link else {"error": "no Advanced link", "outline": outline(pid)}
        clicks += 1
        time.sleep(1.5)
        steps.append({"step": "click Advanced", "reply": reply, "shots": lkr.shoot(pid, folder, "02-advanced"),
                      "present": bool(find_switch(pid))})
    flip = click_switch(pid)
    clicks += 1
    time.sleep(1)
    after = lkr.read_key(sock, KEY)
    steps.append({"step": "click See-Through Dock switch", **flip, "read_back": after,
                  "shots": lkr.shoot(pid, folder, "03-flipped")})
    ok = after is True and before is not True
    if after is True:  # put it back as it was
        click_switch(pid)
        steps.append({"step": "flip back", "read_back": lkr.read_key(sock, KEY)})
    close_settings(sock)
    return {"path": name, "clicks": clicks, "key_presses": keys, "before": before, "after": after, "ok": ok,
            "steps": steps}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--control-socket")
    parser.add_argument("--dmg", default="")
    args = parser.parse_args()
    app, out = Path(args.app), Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    with open(app / "Contents/Info.plist", "rb") as handle:
        info = plistlib.load(handle)
    pid = int(Path(args.pid_file).read_text().strip())
    receipt: dict = {"host": os.uname().nodename, "dmg": args.dmg, "app_version": info.get("CFBundleVersion"),
                     "app_short_version": info.get("CFBundleShortVersionString"), "app_commit": info.get("CMUXCommit"),
                     "key": KEY, "paths": []}
    sock = lkr.wait_for(lambda: lkr.control_socket(pid, args.control_socket), 120, step=0.5)
    if not sock:
        receipt["error"] = "the copy's control socket never answered"
    else:
        time.sleep(4)  # the first window settles
        for name, search in (("nav", False), ("search", True)):
            try:
                receipt["paths"].append(walk(sock, pid, out, name, search))
            except Exception as error:  # one path's failure is recorded; the next still runs
                receipt["paths"].append({"path": name, "ok": False, "error": f"{type(error).__name__}: {error}"})
        receipt["outline"] = outline(pid)
    receipt["ok"] = any(p.get("ok") for p in receipt["paths"])
    receipt["fewest_clicks"] = min((p["clicks"] for p in receipt["paths"] if p.get("ok")), default=None)
    (out / "result.json").write_text(json.dumps(receipt, indent=2))
    lkr.say("CUSTOMIZER_TOGGLE_READBACK " + json.dumps(receipt)[:6000])
    return 0 if receipt["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
