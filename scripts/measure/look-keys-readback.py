#!/usr/bin/env python3
"""The app half of scripts/measure/look-keys-readback.sh: look keys read back on a published NIGHTLY side instance.

    look-keys-readback.py prepare --config DIR
    look-keys-readback.py run --app APP --pid-file F --config DIR --cases FILE --out DIR
                              [--control-socket SOCK] [--only NAME,NAME] [--dmg URL]

`prepare` (before the copy launches) points the copy's cmux-next.json at an empty theme file of the run's own
(DIR/themes/look-readback.json, `appearance.themeFile: "look-readback"`), so each case only rewrites that file and
the app's own theme file watcher applies it, with no relaunch and no settings write.

`run` drives the running copy over its control socket with the NIGHTLY's own release methods only (`action.run`,
`settings.get`; a NIGHTLY has no debug.* methods). For each case, in the file's order:

  1. setup: its `setup` actions (`action.run`), then a window and a desktop shot (before/)
  2. every `theme` key read before (`settings.get`: the effective settings, theme file applied)
  3. the case's files written: `theme` as the theme file, `agent_pane_css` as DIR/agent-pane/theme.css
     (`:root { --token: value; }`, the chat stylesheet the app pushes to open chats on save), `files` as is;
     `settings` keys are written with `settings.set` into the copy's own cmux-next.json (for a key no theme file
     may set) and read back the same way as `theme` keys
  4. every `theme` key read until it equals the case's value (15 s), then the after/ shots. A value is any JSON
     (string, number, boolean, object); numbers match by value, booleans only booleans. A key passes only when its
     before value differs, so a case sets a value off the default (e.g. `"appearance.metrics.spacingScale": 1.5`)
  5. `expect_color`: the shots before and after are probed for that color (each channel within `tolerance`,
     default 24); the case passes the probe when the before shot has fewer than `min_pixels` (default 400) and an
     after shot at least that many. This is how a value no socket method reads (a CSS token) is read back.
  6. the files it wrote are removed, the theme file emptied again and `settings` keys reset (`keep: true` leaves them for the next case)

The cases file (JSON):

    {"cases": [{"name": "tab-shape", "pr": 46780,
                "setup": [{"action": "newTab"}, {"action": "newTab", "wait": 1}],
                "theme": {"appearance.tabShape": "rounded"}},
               {"name": "menu-tokens", "pr": 46846,
                "setup": [{"action": "palette.newAgentChat", "focus": true, "wait": 8},
                          {"action": "agentPane.switchModel", "wait": 2}],
                "agent_pane_css": {"--menu-fill": "#ff00ff"},
                "expect_color": {"rgb": "#ff00ff", "min_pixels": 400}}]}

A setup step is `{"action": ID, ...params, "wait": S}` (action.run with the other keys as its params, then S
seconds), `{"rpc": METHOD, "params": {...}, "wait": S}`, or `{"sleep": S}`.

Shots: CuaDriver (the fleet's Screen Recording grant: get_window_state of the copy's largest window, and
get_desktop_state), else screencapture. Writes OUT/result.json and prints `LOOK_KEYS_READBACK {json}`:
{host, dmg, app_version, app_commit, cases: [{name, pr, ok, readback: {KEY: {before, after, want, ok}},
color: {...}, shots: {...}, steps: [...]}], ok}. Exit 0 only when every case read back.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import plistlib
import pwd
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

THEME_NAME = "look-readback"
CUA_PATHS = ["/Applications/CuaDriver.app/Contents/MacOS/cua-driver", "~/.local/bin/cua-driver"]


def say(*parts):
    print(*parts, flush=True)


def real_home() -> str:
    try:
        return pwd.getpwuid(os.getuid()).pw_dir
    except KeyError:
        return os.path.expanduser("~")


def rpc(path: str, method: str, params: dict | None = None, timeout: float = 30) -> dict:
    """One newline-JSON request on the copy's control socket: its result, or {"error": ...}."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(path)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error), "unreachable": True}
    if reply.get("ok"):
        result = reply.get("result")
        return result if isinstance(result, dict) else {"value": result}
    return {"error": reply.get("error")}


def control_socket(pid: int, named: str | None) -> str | None:
    """The copy's control socket: the one whose system.identify names the copy's pid."""
    candidates = [named] if named else []
    candidates += sorted(set(glob.glob("/tmp/cmux-*.sock"))
                         | set(glob.glob(os.path.join(os.environ.get("TMPDIR", "/tmp"), "cmux-side-*.sock"))))
    for sock in candidates:
        if sock and os.path.exists(sock):
            reply = rpc(sock, "system.identify", timeout=5)
            if reply.get("pid") == pid:
                return sock
    return None


def wait_for(probe, seconds: float, step: float = 0.25):
    deadline = time.monotonic() + seconds
    while True:
        value = probe()
        if value or time.monotonic() > deadline:
            return value
        time.sleep(step)


# ---------------------------------------------------------------- shots


def cua_binary() -> str | None:
    for path in CUA_PATHS:
        path = path.replace("~", real_home(), 1)
        if os.access(path, os.X_OK):
            return path
    return None


def cua(tool: str, args: dict, timeout: float = 90) -> dict:
    binary = cua_binary()
    if not binary:
        return {"error": "no cua-driver"}
    env = dict(os.environ, HOME=real_home())  # it proxies to the granted daemon under the account's real HOME
    env.pop("CFFIXED_USER_HOME", None)
    try:
        run = subprocess.run([binary, "call", tool, json.dumps(args)], capture_output=True, text=True,
                             timeout=timeout, env=env)
    except (OSError, subprocess.SubprocessError) as error:
        return {"error": str(error)}
    try:
        value = json.loads(run.stdout)
        return value if isinstance(value, dict) else {"value": value}
    except ValueError:
        return {"error": f"exit {run.returncode}: {(run.stdout + run.stderr)[-400:]}"}


def window_of(pid: int) -> int | None:
    windows = cua("list_windows", {"pid": pid}).get("windows") or []
    size = lambda w: (w.get("bounds") or {}).get("width", 0) * (w.get("bounds") or {}).get("height", 0)
    windows = [w for w in windows if isinstance(w, dict) and size(w) > 100 * 60]
    return max(windows, key=size).get("window_id") if windows else None


def shoot(pid: int, folder: Path, name: str) -> dict:
    """A window shot and a desktop shot into FOLDER: {window, desktop, how, errors}."""
    folder.mkdir(parents=True, exist_ok=True)
    out: dict = {"errors": []}
    window, desktop = folder / f"{name}-window.png", folder / f"{name}-desktop.png"
    if cua_binary():
        wid = window_of(pid)
        if wid is not None:
            reply = cua("get_window_state", {"pid": pid, "window_id": wid, "screenshot_out_file": str(window)})
            if window.is_file() and window.stat().st_size:
                out["window"], out["how"] = str(window), "cua-driver"
            else:
                out["errors"].append(f"cua window: {json.dumps(reply)[:300]}")
        else:
            out["errors"].append("cua: no window of the copy")
        reply = cua("get_desktop_state", {"screenshot_out_file": str(desktop)})
        if desktop.is_file() and desktop.stat().st_size:
            out["desktop"] = str(desktop)
        else:
            out["errors"].append(f"cua desktop: {json.dumps(reply)[:300]}")
    if "desktop" not in out:
        done = subprocess.run(["screencapture", "-x", "-o", str(desktop)], capture_output=True, text=True, timeout=30)
        if desktop.is_file() and desktop.stat().st_size:
            out["desktop"] = str(desktop)
            out.setdefault("how", "screencapture")
        else:
            out["errors"].append(f"screencapture: {(done.stderr or done.stdout)[-200:]}")
    if not out["errors"]:
        del out["errors"]
    return out


def bmp_pixels(path: str):
    """(width, height, bytes per pixel, channel offsets r,g,b, rows) of a PNG through sips' BMP."""
    with tempfile.TemporaryDirectory() as scratch:
        bmp = os.path.join(scratch, "shot.bmp")
        subprocess.run(["sips", "-s", "format", "bmp", path, "--out", bmp], capture_output=True, timeout=60)
        data = Path(bmp).read_bytes()
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0] // 8
    compression = struct.unpack_from("<I", data, 30)[0]
    order = (2, 1, 0)  # BGR(A)
    if compression in (3, 6) and bpp == 4:
        masks = struct.unpack_from("<III", data, 54)
        order = tuple({0xFF: 0, 0xFF00: 1, 0xFF0000: 2, 0xFF000000: 3}.get(m, 0) for m in masks)
    stride = (width * bpp + 3) & ~3
    return abs(width), abs(height), bpp, order, data[offset:], stride


def count_color(path: str | None, rgb: str, tolerance: int) -> int | None:
    """Pixels of PATH within TOLERANCE of RGB (#rrggbb), every other pixel and row (a count, not a mask)."""
    if not path or not os.path.isfile(path):
        return None
    try:
        width, height, bpp, (ri, gi, bi), body, stride = bmp_pixels(path)
    except (OSError, struct.error, subprocess.SubprocessError) as error:
        say(f"color probe of {path} failed: {error}")
        return None
    want = tuple(int(rgb.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
    lo = [max(0, c - tolerance) for c in want]
    hi = [min(255, c + tolerance) for c in want]
    found = 0
    for y in range(0, height, 2):
        row = body[y * stride:(y * stride) + width * bpp]
        for x in range(0, len(row) - bpp + 1, bpp * 2):
            r, g, b = row[x + ri], row[x + gi], row[x + bi]
            if lo[0] <= r <= hi[0] and lo[1] <= g <= hi[1] and lo[2] <= b <= hi[2]:
                found += 1
    return found * 4  # sampled every other pixel and row


# ---------------------------------------------------------------- cases


def theme_path(config: Path) -> Path:
    return config / "themes" / f"{THEME_NAME}.json"


def prepare(config: Path) -> int:
    config.mkdir(parents=True, exist_ok=True)
    theme_path(config).parent.mkdir(parents=True, exist_ok=True)
    theme_path(config).write_text("{}\n")
    settings = config / "cmux-next.json"
    root = {}
    if settings.is_file() and settings.read_text().strip():
        try:
            root = json.loads(settings.read_text())
        except ValueError as error:
            say(f"look-keys-readback: {settings} is not plain JSON ({error}); refusing to rewrite it")
            return 3
    root.setdefault("appearance", {})["themeFile"] = THEME_NAME
    settings.write_text(json.dumps(root, indent=2) + "\n")
    say(f"prepared {settings}: appearance.themeFile = {THEME_NAME}")
    return 0


def run_steps(sock: str, steps: list) -> list:
    done = []
    for step in steps or []:
        step = dict(step)
        wait = float(step.pop("wait", 0) or 0)
        if "sleep" in step:
            time.sleep(float(step["sleep"]))
            done.append({"sleep": step["sleep"]})
            continue
        if "action" in step:
            reply = rpc(sock, "action.run", step, timeout=30)
            done.append({"action": step["action"], "reply": reply})
        elif "rpc" in step:
            reply = rpc(sock, step["rpc"], step.get("params") or {}, timeout=30)
            done.append({"rpc": step["rpc"], "reply": reply})
        say("step", json.dumps(done[-1])[:400])
        if wait:
            time.sleep(wait)
    return done


def same(a, b) -> bool:
    """A setting's read value against the wanted one: strings, CSS tokens, nested JSON, and numbers by value
    (12 and 12.0 match), but a boolean matches only a boolean (Python's True == 1 does not count)."""
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(float(a) - float(b)) < 1e-9
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b


def read_key(sock: str, key: str):
    reply = rpc(sock, "settings.get", {"path": key}, timeout=10)
    return reply.get("value") if "error" not in reply else {"error": reply.get("error")}


def run_case(sock: str, pid: int, config: Path, out: Path, case: dict) -> dict:
    name = case["name"]
    folder = out / name
    result: dict = {"name": name, "pr": case.get("pr")}
    result["steps"] = run_steps(sock, case.get("setup") or [])
    theme = case.get("theme") or {}
    settings = case.get("settings") or {}
    result["readback"] = {key: {"want": value, "before": read_key(sock, key), "via": via}
                          for via, keys in (("theme", theme), ("settings", settings)) for key, value in keys.items()}
    result["shots"] = {"before": shoot(pid, folder, "before")}
    written = []
    if theme:
        theme_path(config).write_text(json.dumps(theme, indent=2) + "\n")
        written.append(str(theme_path(config)))
    css = case.get("agent_pane_css") or {}
    if css:
        sheet = config / "agent-pane" / "theme.css"
        sheet.parent.mkdir(parents=True, exist_ok=True)
        sheet.write_text(":root {\n" + "".join(f"  {k}: {v};\n" for k, v in css.items()) + "}\n")
        written.append(str(sheet))
    for rel, text in (case.get("files") or {}).items():
        path = (config / rel).resolve()
        if config.resolve() not in path.parents:
            raise SystemExit(f"look-keys-readback: {rel} is outside the copy's config folder")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        written.append(str(path))
    for key, value in settings.items():
        reply = rpc(sock, "settings.set", {"path": key, "value": value}, timeout=30)
        result["readback"][key]["set"] = reply.get("error") or "ok"
    result["written"] = written
    started = time.monotonic()
    for key, row in result["readback"].items():
        # A wanted false or 0 is falsy, so the poll returns the match as a one-item list.
        wait_for(lambda: [v] if same(v := read_key(sock, key), row["want"]) else None, 15)
        row["after"] = read_key(sock, key)
        row["ok"] = same(row["after"], row["want"]) and not same(row["before"], row["want"])
        row["applied_ms"] = round((time.monotonic() - started) * 1000) if same(row["after"], row["want"]) else None
    time.sleep(float(case.get("settle", 2)))
    probe = case.get("expect_color")
    if probe:
        tolerance = int(probe.get("tolerance", 24))
        need = int(probe.get("min_pixels", 400))
        before = result["shots"]["before"]
        color = {"rgb": probe["rgb"], "tolerance": tolerance, "min_pixels": need,
                 "before": {k: count_color(before.get(k), probe["rgb"], tolerance) for k in ("window", "desktop")}}
        after_counts: dict = {}

        def seen():
            shots = shoot(pid, folder, "after")
            result["shots"]["after"] = shots
            after_counts.update({k: count_color(shots.get(k), probe["rgb"], tolerance) for k in ("window", "desktop")})
            return any((v or 0) >= need for v in after_counts.values())

        wait_for(seen, float(probe.get("wait", 10)), step=1)
        color["after"] = after_counts
        color["ok"] = all((v or 0) < need for v in color["before"].values()) and \
            any((v or 0) >= need for v in after_counts.values())
        result["color"] = color
    else:
        result["shots"]["after"] = shoot(pid, folder, "after")
    checks = [row["ok"] for row in result["readback"].values()]
    if probe:
        checks.append(result["color"]["ok"])
    result["ok"] = bool(checks) and all(checks)
    if not case.get("keep"):
        for path in written:
            if path == str(theme_path(config)):
                theme_path(config).write_text("{}\n")
            else:
                Path(path).unlink(missing_ok=True)
        for key in settings:
            rpc(sock, "settings.reset", {"path": key}, timeout=30)
    say(f"case {name}: ok={result['ok']} readback={json.dumps(result['readback'])} "
        f"color={json.dumps(result.get('color'))}")
    return result


def run(args) -> int:
    app, out, config = Path(args.app), Path(args.out), Path(args.config)
    out.mkdir(parents=True, exist_ok=True)
    cases = json.loads(Path(args.cases).read_text()).get("cases") or []
    only = [n for n in (args.only or "").split(",") if n]
    if only:
        cases = [c for c in cases if c.get("name") in only]
    with open(app / "Contents/Info.plist", "rb") as handle:
        info = plistlib.load(handle)
    pid = int(Path(args.pid_file).read_text().strip())
    receipt: dict = {"host": os.uname().nodename, "dmg": args.dmg, "app": str(app),
                     "app_version": info.get("CFBundleVersion"), "app_short_version": info.get("CFBundleShortVersionString"),
                     "app_commit": info.get("CMUXCommit"), "cua_driver": cua_binary(), "cases": []}
    sock = wait_for(lambda: control_socket(pid, args.control_socket), 120, step=0.5)
    if not sock:
        receipt["error"] = "the copy's control socket never answered"
        receipt["ok"] = False
    else:
        receipt["control_socket"] = sock
        receipt["theme_file"] = read_key(sock, "appearance.themeFile")
        time.sleep(3)  # the first window settles
        for case in cases:
            try:
                receipt["cases"].append(run_case(sock, pid, config, out, case))
            except Exception as error:  # one case's failure is recorded; the next still runs
                receipt["cases"].append({"name": case.get("name"), "pr": case.get("pr"), "ok": False,
                                         "error": f"{type(error).__name__}: {error}"})
        receipt["ok"] = bool(receipt["cases"]) and all(c.get("ok") for c in receipt["cases"])
    (out / "result.json").write_text(json.dumps(receipt, indent=2))
    say("LOOK_KEYS_READBACK " + json.dumps(receipt))
    return 0 if receipt["ok"] else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare")
    prep.add_argument("--config", required=True)
    go = sub.add_parser("run")
    go.add_argument("--app", required=True)
    go.add_argument("--pid-file", required=True)
    go.add_argument("--config", required=True)
    go.add_argument("--cases", required=True)
    go.add_argument("--out", required=True)
    go.add_argument("--control-socket")
    go.add_argument("--only", default="")
    go.add_argument("--dmg", default="")
    args = parser.parse_args()
    if args.command == "prepare":
        return prepare(Path(args.config))
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
