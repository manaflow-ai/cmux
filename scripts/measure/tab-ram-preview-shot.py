#!/usr/bin/env python3
"""The app half of scripts/measure/tab-ram-preview-shot.sh: one picture of three merged fixes on a NIGHTLY copy.

  tab-ram-preview-shot.py --app APP --pid-file F --control-socket S --harness ID --cwd DIR --out DIR
      [--dmg URL] [--chats N]

Opens a workspace with N agent chats (default 14) on the stand-in harness ID, so its tab strip is crowded; each
chat's first turn is echoed, so it has words to picture. Then, through the copy's own cmux Computer Use only:
lists the copy's windows, captures the main window (the crowded strip), reads its UI tree for a chat tab, rests the
pointer on that tab, and captures the copy's windows and the display while the tab's hover card shows (its chat
picture and its Memory line). The OCR of each picture is kept beside it. A Computer Use refusal ends the run: no
other capture path.

Writes OUT/result.json and prints `TAB_RAM_PREVIEW {json}`. Exit 0 when the chats opened and a hovered capture
exists; `memory_line` says whether the OCR read "Memory" with a number beside it.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import plistlib
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
NAMES = ["Kiwi", "Mango", "Plum", "Fig", "Lime", "Pear", "Date", "Yuzu", "Guava", "Quince", "Melon", "Olive",
         "Peach", "Cherry", "Apricot", "Lemon", "Grape", "Papaya"]
MEMORY = re.compile(r"Memory\s*[:\-]?\s*([0-9][0-9.,]*\s*(?:KB|MB|GB|K|M|G))", re.IGNORECASE)


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


lkr = load("lkr", HERE / "look-keys-readback.py")
hot = load("hot_apply", ROOT / "scripts/cmux-next/hot-apply.py")
cli_json = load("ext_reload_nightly", HERE / "ext-reload-nightly.py").cli_json


class Copy:
    def __init__(self, app: Path, daemon: str, control: str, out: Path):
        self.cli = (app / hot.BIN / "cmux").resolve()
        self.globals_ = ["--socket", daemon, "--app-socket", control]
        self.out = out
        self.log: list = []

    def run(self, args: list, timeout: float = 90) -> dict:
        reply = cli_json(self.cli, self.globals_, args, timeout=timeout)
        self.log.append(reply)
        return reply

    def cu(self, tool: str, args: dict, timeout: float = 60) -> dict:
        return self.run(["--json", "computer-use", "call", tool, "--args", json.dumps(args)], timeout=timeout)

    def shot(self, path: Path, window: str | None = None) -> dict:
        argv = ["computer-use", "screenshot", "--out", str(path)] + (["--window", window] if window else [])
        reply = self.run(argv, timeout=60)
        reply["png"] = str(path) if path.is_file() and path.stat().st_size else None
        return reply


def find(value, key: str):
    """The first value of KEY anywhere in VALUE."""
    if isinstance(value, dict):
        if key in value:
            return value[key]
        for inner in value.values():
            got = find(inner, key)
            if got is not None:
                return got
    elif isinstance(value, list):
        for inner in value:
            got = find(inner, key)
            if got is not None:
                return got
    return None


def nodes(value) -> list:
    """Every dict in VALUE that names an element (an id with words)."""
    found: list = []
    if isinstance(value, dict):
        if any(k in value for k in ("element_id", "id")) and any(
                str(value.get(k) or "").strip() for k in ("label", "title", "value", "name", "description")):
            found.append(value)
        for inner in value.values():
            found.extend(nodes(inner))
    elif isinstance(value, list):
        for inner in value:
            found.extend(nodes(inner))
    return found


def words(node: dict) -> str:
    return " ".join(str(node.get(k) or "") for k in ("label", "title", "value", "name", "description"))


def top(node: dict) -> float:
    frame = node.get("frame") or node.get("bounds") or {}
    return float(frame.get("y", 1e9)) if isinstance(frame, dict) else 1e9


def ocr(png: str | None, tool: Path) -> str:
    if not png or not tool.exists():
        return ""
    read = subprocess.run([str(tool), png], capture_output=True, text=True, timeout=60)
    text = read.stdout if read.returncode == 0 else ""
    Path(png).with_suffix(".txt").write_text(text)
    return text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--control-socket")
    parser.add_argument("--harness", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--dmg", default="")
    parser.add_argument("--chats", type=int, default=14)
    args = parser.parse_args()
    app, out = Path(args.app), Path(args.out)
    shots = out / "shots"
    shots.mkdir(parents=True, exist_ok=True)
    with open(app / "Contents/Info.plist", "rb") as handle:
        info = plistlib.load(handle)
    bundle_id = info["CFBundleIdentifier"]
    receipt: dict = {"dmg": args.dmg, "app_version": info.get("CFBundleVersion"),
                     "app_short_version": info.get("CFBundleShortVersionString"),
                     "app_commit": info.get("CMUXCommit"), "bundle_id": bundle_id, "ok": False}

    def finish(code: int, error: str | None = None) -> int:
        if error:
            receipt["error"] = error
        (out / "result.json").write_text(json.dumps(receipt, indent=2, default=str))
        if copy is not None:
            (out / "calls.json").write_text(json.dumps(copy.log, indent=2, default=str))
        lkr.say("TAB_RAM_PREVIEW " + json.dumps(receipt, default=str)[:8000])
        return code

    copy = None
    pid = int(Path(args.pid_file).read_text().strip())
    control = lkr.wait_for(lambda: lkr.control_socket(pid, args.control_socket), 120, step=0.5)
    if not control:
        return finish(3, "rig: the copy's control socket never answered")
    cli = (app / hot.BIN / "cmux").resolve()
    daemon = lkr.wait_for(lambda: hot.find_socket(app, cli), 120, step=1)
    if not daemon:
        return finish(3, "rig: the copy's daemon socket was not found")
    copy = Copy(app, daemon, control, out)
    time.sleep(3)

    status = copy.run(["--json", "computer-use", "status"], timeout=45)
    receipt["computer_use_status"] = status.get("json") or status.get("output")

    # The crowd: one workspace, N chats on the stand-in agent.
    copy.run(["setup", "trust", args.cwd])
    made = copy.run(["--json", "workspace", "create", "--name", "Leo tabs"])
    workspace = find(made.get("json"), "workspace_id") or find(made.get("json"), "id")
    if not workspace:
        return finish(1, f"workspace create: {json.dumps(made)[:400]}")
    copy.run(["workspace", str(workspace), "focus"])
    names = (NAMES * 3)[: args.chats]
    opened = []
    for index, name in enumerate(names):
        label = name if index < len(NAMES) else f"{name} {index}"
        reply = copy.run(["--json", "agents", "chat", "new", "--workspace", str(workspace), "--harness", args.harness,
                          "--cwd", args.cwd, "--name", label, "--", f"Hello from {label}, a stand-in agent chat."],
                         timeout=120)
        chat = find(reply.get("json"), "chat")
        if chat:
            opened.append({"name": label, "chat": chat})
    receipt["chats_asked"], receipt["chats_opened"] = len(names), len(opened)
    if not opened:
        return finish(1, "no chat opened on the stand-in agent")
    time.sleep(6)  # first turns answered, the resource sampler has a reading

    # Computer Use: the copy's windows.
    listed = copy.cu("list_windows", {"app_id": bundle_id})
    windows = find(listed.get("json"), "windows")
    if listed.get("exit") != 0 or not isinstance(windows, list):
        return finish(3, "Computer Use did not list the copy's windows (refusal is terminal)")
    owned = [w for w in windows if isinstance(w, dict) and w.get("app_id") == bundle_id and not w.get("denied")]
    if not owned:
        return finish(3, "Computer Use listed no window of the copy it may read")

    def area(w: dict) -> float:
        f = w.get("frame") or w.get("bounds") or {}
        return float(f.get("width", f.get("w", 0)) or 0) * float(f.get("height", f.get("h", 0)) or 0)

    main_window = str(max(owned, key=area).get("window_id"))
    receipt["windows_before"] = [{k: w.get(k) for k in ("window_id", "title", "frame")} for w in owned]
    tool = out / "ocr"
    built = subprocess.run(["xcrun", "swiftc", str(ROOT / "scripts/e2e/ocr.swift"), "-o", str(tool)],
                           capture_output=True, text=True, timeout=180)
    receipt["ocr_built"] = built.returncode == 0

    strip = copy.shot(shots / "01-strip-window.png", main_window)
    if not strip.get("png"):
        return finish(3, "Computer Use did not capture the copy's window (refusal is terminal)")
    receipt["strip"] = {"png": strip["png"], "ocr": ocr(strip["png"], tool)[:3000]}

    tree = copy.cu("get_ui_tree", {"window_id": main_window, "max_nodes": 5000}, timeout=90)
    (out / "ui-tree.json").write_text(json.dumps(tree.get("json") or tree, indent=2, default=str))
    elements = nodes(tree.get("json"))
    wanted = [o["name"] for o in opened]
    # A tab carries the chat's name; the strip sits above the chat, so the topmost match of a name is its tab.
    pick_order = wanted[len(wanted) // 2:] + wanted[: len(wanted) // 2]
    hovered = []
    for name in pick_order[:4]:
        matches = sorted((n for n in elements if name.lower() in words(n).lower()), key=top)
        if not matches:
            continue
        element = matches[0]
        element_id = element.get("element_id", element.get("id"))
        moved = copy.cu("move_pointer", {"window_id": main_window, "element_id": element_id,
                                         "delivery": "foreground"})
        attempt = {"name": name, "element": {k: element.get(k) for k in ("element_id", "id", "role", "label",
                                                                          "title", "frame")},
                   "moved": {k: moved.get(k) for k in ("exit", "json", "output", "stderr")}}
        hovered.append(attempt)
        if moved.get("exit") != 0:
            continue
        time.sleep(2.0)  # the card's show delay and its picture
        after = copy.cu("list_windows", {"app_id": bundle_id})
        after_windows = [w for w in (find(after.get("json"), "windows") or [])
                         if isinstance(w, dict) and w.get("app_id") == bundle_id and not w.get("denied")]
        attempt["windows_after"] = [{k: w.get(k) for k in ("window_id", "title", "frame")} for w in after_windows]
        tag = name.lower()
        display = copy.shot(shots / f"02-hover-{tag}-display.png")
        attempt["display"] = {"png": display.get("png"), "ocr": ocr(display.get("png"), tool)[:4000]}
        attempt["windows"] = []
        for w in after_windows:
            wid = str(w.get("window_id"))
            shot = copy.shot(shots / f"03-hover-{tag}-window-{wid}.png", wid)
            attempt["windows"].append({"window_id": wid, "png": shot.get("png"), "ocr": ocr(shot.get("png"), tool)[:3000]})
        text = " ".join([attempt["display"]["ocr"]] + [w["ocr"] for w in attempt["windows"]])
        found = MEMORY.search(" ".join(text.split()))
        attempt["memory_line"] = found.group(0) if found else None
        if found:
            break
    receipt["hovered"] = hovered
    receipt["memory_line"] = next((h["memory_line"] for h in hovered if h.get("memory_line")), None)
    captured = any((h.get("display") or {}).get("png") or any(w.get("png") for w in h.get("windows", []))
                   for h in hovered)
    receipt["ok"] = bool(opened) and captured
    if not hovered:
        return finish(1, "no chat tab found in the copy's UI tree")
    return finish(0 if receipt["ok"] else 1)


if __name__ == "__main__":
    raise SystemExit(main())
