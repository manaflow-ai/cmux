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
ROW = f'[data-row-key="{KEY}"]'
SWITCH_SELECTORS = [f'{ROW} [role="switch"]', f'{ROW} input[type="checkbox"]', f"{ROW} button", ROW]
PAGE = "cmux.settings"


def page(sock: str, action: str, **params) -> dict:
    return lkr.rpc(sock, "debug.page", {"page": PAGE, "action": action, **params}, timeout=30)


def visible_text(sock: str) -> str:
    state = page(sock, "state")
    return json.dumps(state)[:20000]


def query(sock: str, selector: str) -> list:
    reply = page(sock, "query", selector=selector)
    for key in ("elements", "matches", "nodes", "value"):
        if isinstance(reply.get(key), list):
            return reply[key]
    return [reply] if reply and "error" not in reply else []


def in_view(sock: str) -> dict:
    """Whether the switch's row is on screen: its rect against the page's viewport, as query reports them."""
    nodes = query(sock, ROW)
    if not nodes:
        return {"present": False}
    node = nodes[0]
    rect = node.get("rect") or node.get("bounds") or {}
    view = page(sock, "state").get("viewport") or {}
    out = {"present": True, "rect": rect, "viewport": view}
    try:
        top, height = float(rect.get("y", rect.get("top"))), float(view.get("height"))
        out["visible"] = 0 <= top < height
    except (TypeError, ValueError):
        out["visible"] = None
    return out


def click_switch(sock: str) -> dict:
    for selector in SWITCH_SELECTORS:
        if query(sock, selector):
            reply = page(sock, "click", selector=selector)
            if reply.get("clicked"):
                return {"selector": selector, "reply": reply}
    return {"error": "no switch matched", "tried": SWITCH_SELECTORS}


def open_settings(sock: str) -> dict:
    reply = lkr.rpc(sock, "action.run", {"action": "openSettings", "focus": True}, timeout=30)
    ready = lkr.wait_for(lambda: "error" not in page(sock, "state"), 30, step=0.5)
    return {"reply": reply, "page_ready": bool(ready)}


def close_settings(sock: str) -> None:
    lkr.rpc(sock, "action.run", {"action": "closeTab", "focus": True}, timeout=15)
    time.sleep(1)


def walk(sock: str, pid: int, out: Path, name: str, search: bool) -> dict:
    folder = out / name
    steps, clicks, keys = [], 0, 0
    before = lkr.read_key(sock, KEY)
    steps.append({"step": "cold", "shots": lkr.shoot(pid, folder, "00-start")})
    steps.append({"step": "Cmd-, (openSettings)", **open_settings(sock)})
    keys += 1
    time.sleep(1.5)
    steps[-1]["shots"] = lkr.shoot(pid, folder, "01-settings")
    if search:
        steps.append({"step": "Cmd-F + type see-through", "focus": page(sock, "command", command="focusSearch"),
                      "type": page(sock, "type", text="see-through")})
        keys += 2  # Cmd-F and the typing
        time.sleep(1)
        steps[-1]["shots"] = lkr.shoot(pid, folder, "02-search")
    else:
        view = in_view(sock)
        steps.append({"step": "row in view before Advanced?", **view})
        if not view.get("visible"):
            reply = page(sock, "click", selector='[data-section-link="advanced"]')
            clicks += 1
            time.sleep(1)
            steps.append({"step": "click Advanced", "reply": reply, "shots": lkr.shoot(pid, folder, "02-advanced"),
                          **in_view(sock)})
            if not steps[-1].get("visible") and steps[-1].get("present"):
                page(sock, "scroll", selector=ROW, block="center")
                steps.append({"step": "scroll to the row (a wheel, not a click)", **in_view(sock)})
    flip = click_switch(sock)
    clicks += 1
    time.sleep(1)
    after = lkr.read_key(sock, KEY)
    steps.append({"step": "click See-Through Dock switch", **flip, "read_back": after,
                  "shots": lkr.shoot(pid, folder, "03-flipped")})
    ok = after is True and before is not True
    if after is True:  # put it back as it was
        click_switch(sock)
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
        receipt["settings_text_sample"] = visible_text(sock)[:4000]
    receipt["ok"] = any(p.get("ok") for p in receipt["paths"])
    receipt["fewest_clicks"] = min((p["clicks"] for p in receipt["paths"] if p.get("ok")), default=None)
    (out / "result.json").write_text(json.dumps(receipt, indent=2))
    lkr.say("CUSTOMIZER_TOGGLE_READBACK " + json.dumps(receipt)[:6000])
    return 0 if receipt["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
