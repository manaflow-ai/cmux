#!/usr/bin/env python3
"""Live captures of the browser's Extensions bubble in a fleet-built tagged app.

    nx-remote --needs gui --app-from-fleet cmux --tag <tag> --ref <sha> -- \
        python3 scripts/cmux-next/extensions-menu-live.py
    extensions-menu-live.py --app "<path>/cmux DEV <tag>.app" --tag <tag> --out DIR   # a leased capture mini

Runs on a GUI host with the job's NX_APP, NX_APP_SOCKET, NX_APP_STOP, NX_CAPTURE and
NX_ARTIFACTS, or with --app and --tag (the socket is /tmp/cmux-debug-<tag>.sock; the app's own
window snapshot, `debug.window_snapshot`, takes the pictures). It writes unpacked test extensions (an all-sites one, one for example.com, a side
panel one that runs on a click, one that needs no site, a long name), launches the app with them
(CMUX_NEXT_CEF_LOAD_EXTENSIONS), opens https://example.com/ in a Chromium tab, opens the bubble,
pins two extensions and saves 2x window captures with the bubble:

  few-dark.png, few-light.png, few-accent.png   the five extensions (accent: the theme's hue)
  many-dark.png                                 sixteen extensions: the list scrolls
  none-dark.png                                 no extensions (the bundled uBlock Origin off): the empty state

It checks only that each bubble opened and listed what was loaded; the pictures are the proof.
Self-contained (no imports from this folder), so a base commit can run the head's copy for a
before/after. Exits 1 when a bubble did not open.
"""
import argparse
import json
import os
import plistlib
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib

parser = argparse.ArgumentParser()
parser.add_argument("--app", default=os.environ.get("NX_APP"))
parser.add_argument("--tag")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="extensions-menu-"))
opts = parser.parse_args()
if not opts.app:
    sys.exit("no app: pass --app or run under nx-remote --app-from-fleet")
OUT = opts.out
os.makedirs(OUT, exist_ok=True)
APP = opts.app
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock" if opts.tag else os.environ["NX_APP_SOCKET"]
failures = []


def log(message):
    print(f"[extensions-menu] {message}", flush=True)


def check(ok, what):
    log(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def bounded_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.3)
    return None


def png(color, size=32):
    """A round icon of `color` (r, g, b) as PNG bytes."""
    rows = []
    center = (size - 1) / 2
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            inside = (x - center) ** 2 + (y - center) ** 2 <= (size / 2 - 1) ** 2
            row += bytes(color + (255,)) if inside else bytes(4)
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b"")


FEW = [
    ("Page Highlighter", (66, 133, 244), {"host_permissions": ["<all_urls>"], "action": {"default_popup": "popup.html"}}),
    ("Example Notes", (52, 168, 83), {"host_permissions": ["https://example.com/*"], "action": {}}),
    ("Sidebar Assistant", (217, 119, 87), {"permissions": ["activeTab", "sidePanel"], "side_panel": {"default_path": "panel.html"},
                                           "action": {}, "background": {"service_worker": "background.js"}}),
    ("Tab Counter", (171, 71, 188), {"permissions": ["tabs"], "action": {"default_popup": "popup.html"}}),
    ("A Very Long Extension Name That Does Not Fit In The Menu", (0, 150, 136), {"permissions": ["activeTab"], "action": {}}),
]


def write_extensions(root, specs):
    paths = []
    for index, (name, color, extra) in enumerate(specs):
        folder = os.path.join(root, f"ext{index}")
        os.makedirs(folder, exist_ok=True)
        manifest = {"manifest_version": 3, "name": name, "version": "1.0", "icons": {"32": "icon.png"}}
        manifest.update(extra)
        if "action" in manifest:
            manifest["action"] = {**manifest["action"], "default_icon": {"32": "icon.png"}}
        with open(os.path.join(folder, "manifest.json"), "w") as f:
            json.dump(manifest, f)
        with open(os.path.join(folder, "icon.png"), "wb") as f:
            f.write(png(color))
        for page in ("popup.html", "panel.html"):
            with open(os.path.join(folder, page), "w") as f:
                f.write(f"<!doctype html><title>{name}</title><p>{name}</p>")
        if "background" in manifest:
            # As side panel extensions do: a click on the action opens the panel.
            with open(os.path.join(folder, "background.js"), "w") as f:
                f.write("chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: true});\n")
        paths.append(folder)
    return paths


def launch(extensions, config):
    with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
        binary = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
    config_path = os.path.join(OUT, "cmux.json")
    with open(config_path, "w") as f:
        json.dump(config, f)
    env = {
        "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_CHIEF_ISOLATED": "1",
        "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": config_path,
        "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,760",
    }
    if "NX_JOB_ID" in os.environ:
        env["NX_JOB_ID"] = os.environ["NX_JOB_ID"]
    if extensions:
        env["CMUX_NEXT_CEF_LOAD_EXTENSIONS"] = ":".join(extensions)
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    process = subprocess.Popen([binary], env=env, stdout=open(os.path.join(OUT, "app.log"), "a"), stderr=subprocess.STDOUT,
                               stdin=subprocess.DEVNULL)
    up = bounded_wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 180)
    check(bool(up), "app socket")
    if not (rpc("debug.focus") or {}).get("windows"):
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    bounded_wait(lambda: (rpc("debug.focus") or {}).get("windows"), 60)
    return process


def stop(process):
    if os.environ.get("NX_APP_STOP"):
        subprocess.run([os.environ["NX_APP_STOP"]], check=False)
    else:
        process.terminate()  # the app this script started, by its own pid


def shot(process, name):
    path = os.path.join(OUT, f"{name}.png")
    capture = os.environ.get("NX_CAPTURE")
    if capture:
        done = subprocess.run(["bash", capture, "shot", "--pid", str(process.pid), "--with-popups", "--out", path],
                              capture_output=True, text=True)
        log(f"capture {name} rc={done.returncode} saved={os.path.exists(path)} {done.stderr.strip()[:200]}")
        return
    # The app's own composited window with its child panels (the bubble); no Screen Recording grant.
    result = rpc("debug.window_snapshot", {"kind": "main", "path": path}, timeout=60)
    log(f"snapshot {name}: {json.dumps(result)[:300]}")


def scenario(name, specs, pin=(), modes=(("dark", "Catppuccin Mocha", "neutral"),), ad_blocker=True):
    root = tempfile.mkdtemp(prefix=f"ext-{name}-")
    folders = write_extensions(root, specs)
    process = launch(folders, {"appearance": {"theme": modes[0][1]}, "browser": {"builtInAdBlocker": ad_blocker}})
    try:
        opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": "https://example.com/"},
                                    "focus": True, "origin": "remote"})
        log(f"open tab: {json.dumps(opened)[:300]}")
        listed = bounded_wait(lambda: len((rpc("browser.extensions") or {}).get("extensions") or []) >= len(specs) or None, 120)
        check(bool(listed) or not specs, f"{name}: Chromium lists the {len(specs)} test extensions")
        ids = {e.get("name"): e.get("id") for e in (rpc("browser.extensions") or {}).get("extensions") or []}
        time.sleep(3)  # proof capture only: the page and the toolbar settle
        rpc("debug.extensions.click", {"button": "extensions"})
        menu = bounded_wait(lambda: (lambda m: m if m.get("open") else None)(rpc("debug.extensions.menu") or {}), 15)
        check(bool(menu), f"{name}: the Extensions bubble opens")
        for title in pin:
            if ids.get(title):
                rpc("debug.extensions.menu", {"choose": "pin", "extension": ids[title]})
        log(f"{name} menu: {json.dumps(rpc('debug.extensions.menu'))[:1500]}")
        for mode, theme, accent in modes:
            rpc("settings.set", {"path": "appearance.theme", "value": theme})
            rpc("settings.set", {"path": "appearance.accent", "value": accent})
            rpc("debug.appearance", {"mode": "light" if mode == "light" else "dark"})
            time.sleep(1.5)  # proof capture only: the theme repaint
            shot(process, f"{name}-{mode}")
        rpc("debug.extensions.menu", {"dismiss": True})
    finally:
        stop(process)
        bounded_wait(lambda: process.poll() is not None, 30)


scenario("few", FEW, pin=("Example Notes", "Sidebar Assistant"),
         modes=(("dark", "Catppuccin Mocha", "neutral"), ("light", "Catppuccin Latte", "neutral"),
                ("accent", "Catppuccin Mocha", "theme")))
MANY = FEW + [(f"Helper {n}", (60 + n * 10, 120, 200 - n * 8), {"permissions": ["activeTab"] if n % 2 else [], "action": {}})
              for n in range(11)]
scenario("many", MANY, pin=("Example Notes",))
scenario("none", [], ad_blocker=False)  # the bundled uBlock Origin off: nothing installed
log(f"artifacts in {OUT}")
sys.exit(1 if failures else 0)
