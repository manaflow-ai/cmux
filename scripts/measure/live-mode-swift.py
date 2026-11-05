#!/usr/bin/env python3
"""The app half of scripts/measure/live-mode-swift.sh: Swift live mode end to end on a tagged build.

A person's normal tagged build runs with a few workspaces, and they edit HomeHostView (Home red).
`live-mode.py start` builds the live code build of that commit, turns Labs > Live Code on (its
confirmation sheet is answered here through debug.dialog), restarts into it and patches the edit in
(Home red). A save while live (Home blue) is patched in by the watcher, in the same process.
`live-mode.py stop` restarts into the optimized build of the edited checkout (Home still blue).
Each restart's time, and whether every workspace, tab and running terminal came back, go into
result.json; each step's window is counted for red and blue pixels.

  live-mode-swift.py --app APP --tag TAG --out OUT
"""
import argparse
import importlib.util
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "measure"))
sys.path.insert(0, os.path.join(ROOT, "scripts", "cmux-next"))
from bench_launch import rpc_at, socket_candidates  # noqa: E402

LIVE_MODE = os.path.join(ROOT, "scripts/live-code/live-mode.py")
VIEW = os.path.join(ROOT, "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home/HomeHostView.swift")
ORIGINAL = "layer?.backgroundColor = nil"
RED = "layer?.backgroundColor = NSColor.systemRed.cgColor"
BLUE = "layer?.backgroundColor = NSColor.systemBlue.cgColor"
LIVE_LOG = os.path.expanduser("~/Library/Caches/cmux-next/live-code/live-code.log")


def socket(tag):
    """The tag's socket that answers (the state path, else its /tmp link)."""
    for path in socket_candidates(tag):
        try:
            rpc_at(path, "system.ping", timeout=2)
            return path
        except Exception:  # noqa: BLE001 (not up yet)
            continue
    return None


def wait_socket(tag, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        path = socket(tag)
        if path:
            return path
        time.sleep(0.5)
    sys.exit(f"live-mode-swift: cmux DEV {tag} did not answer in {seconds} s")


class Confirmer(threading.Thread):
    """Presses Confirm on Labs > Live Code's sheet while `live-mode.py` waits for it (a person's
    click; the Debug build's debug.dialog answers it). Stops when told to, or after 30 minutes."""

    def __init__(self, tag):
        super().__init__(daemon=True)
        self.tag, self.done, self.pressed = tag, threading.Event(), 0

    def run(self):
        deadline = time.time() + 1800
        while not self.done.is_set() and time.time() < deadline:
            path = socket(self.tag)
            try:
                dialogs = (rpc_at(path, "debug.dialog", {}, timeout=5) or {}).get("dialogs") or [] if path else []
                for dialog in dialogs:
                    text = json.dumps(dialog)
                    if dialog.get("visible") and "confirm" in text and ("Live Code" in text or "liveCode" in text):
                        reply = rpc_at(path, "debug.dialog", {"id": dialog["id"], "press": "confirm"}, timeout=5) or {}
                        self.pressed += bool(reply.get("pressed"))
            except Exception:  # noqa: BLE001 (the app is restarting)
                pass
            self.done.wait(0.5)


def live_mode(verb, tag, *extra):
    run = subprocess.run([sys.executable, LIVE_MODE, verb, "--tag", tag, "--tree", ROOT, "--json", *extra],
                         capture_output=True, text=True)
    print(run.stderr, end="", file=sys.stderr)
    try:
        return run.returncode, json.loads(run.stdout)
    except ValueError:
        return run.returncode, {"stdout": run.stdout}


def log_text():
    return open(LIVE_LOG).read() if os.path.exists(LIVE_LOG) else ""


def wait_log(pattern, since, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        match = re.search(pattern, log_text()[since:])
        if match:
            return match
        time.sleep(0.2)
    return None


def seed(path):
    """Two more workspaces, each with its terminal, beside the first."""
    for _ in range(2):
        rpc_at(path, "workspace.create", {}, timeout=30)
    time.sleep(3)


def pixels(png):
    """(red, blue) pixel counts, as scripts/measure/live-code-app.py counts them."""
    spec = importlib.util.spec_from_file_location("live_code_app", os.path.join(ROOT, "scripts/measure/live-code-app.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.pixels(png)


def snap(tag, out, name):
    path = socket(tag)
    png = os.path.join(out, f"{name}.png")
    try:
        rpc_at(path, "action.run", {"action": "home.show", "focus": True}, timeout=30)  # Home is what turns red or blue
        time.sleep(1)
        rpc_at(path, "debug.window_snapshot", {"kind": "main", "path": png}, timeout=60)
        red, blue = pixels(png)
        return {"png": os.path.basename(png), "red_px": red, "blue_px": blue}
    except Exception as error:  # noqa: BLE001 (evidence only)
        return {"error": str(error)}


def status_line(tag):
    return subprocess.run([sys.executable, LIVE_MODE, "status", "--tag", tag, "--tree", ROOT],
                          capture_output=True, text=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--build-seconds", type=int, default=0)
    opts = parser.parse_args()
    source = open(VIEW).read()
    if ORIGINAL not in source:
        sys.exit(f"live-mode-swift: {VIEW} no longer has {ORIGINAL}")
    result = {"tag": opts.tag, "normal_build_s": opts.build_seconds}
    subprocess.run(["open", "-n", "-g", opts.app], check=True)  # the person's normal build, as they start it
    path = wait_socket(opts.tag, 180)
    seed(path)
    result["normal_pid"] = rpc_at(path, "system.identify").get("pid")
    result["before"] = snap(opts.tag, opts.out, "before")
    confirmer = Confirmer(opts.tag)
    confirmer.start()
    try:
        # 1. An edit made before live mode (Home red) is in right away: start patches it in.
        with open(VIEW, "w") as f:
            f.write(source.replace(ORIGINAL, RED))
        since = len(log_text())
        started = time.time()
        code, result["start"] = live_mode("start", opts.tag)
        result["start"]["exit"], result["start"]["wall_s"] = code, round(time.time() - started, 1)
        path = wait_socket(opts.tag, 60)
        result["live_pid"] = rpc_at(path, "system.identify").get("pid")
        result["watching"] = bool(wait_log(r"live code: watching", since, 60))
        first = wait_log(r"applied \S+ functions=(\d+)", since, 60)
        time.sleep(1)
        result["start_edit"] = {"applied": bool(first), **snap(opts.tag, opts.out, "live-red")}
        result["status_live"] = status_line(opts.tag)

        # 2. A save while live (Home blue) is patched in by the watcher, in the same process.
        since = len(log_text())
        edited = time.time()
        with open(VIEW, "w") as f:
            f.write(source.replace(ORIGINAL, BLUE))
        applied = wait_log(r"applied \S+ functions=(\d+) load_ms=(\d+)", since, 90)
        time.sleep(1)
        result["save_edit"] = {"applied": bool(applied), "functions": int(applied.group(1)) if applied else None,
                               "save_to_applied_s": round(time.time() - edited, 2) if applied else None,
                               "same_pid": rpc_at(path, "system.identify").get("pid") == result["live_pid"],
                               **snap(opts.tag, opts.out, "live-blue")}
        result["status_saved"] = status_line(opts.tag)

        # 3. Stop: the optimized build of the edited checkout (blue kept), sessions kept.
        started = time.time()
        code, result["stop"] = live_mode("stop", opts.tag)
        result["stop"]["exit"], result["stop"]["wall_s"] = code, round(time.time() - started, 1)
        path = wait_socket(opts.tag, 60)
        time.sleep(2)
        result["after"] = snap(opts.tag, opts.out, "after-stop")
        result["status_after"] = status_line(opts.tag)
        result["confirm_presses"] = confirmer.pressed
    finally:
        with open(VIEW, "w") as f:
            f.write(source)
        confirmer.done.set()
        # Quit the step's own app (its pid from its socket), sessions kept: SIGTERM.
        try:
            os.kill(int(rpc_at(socket(opts.tag), "system.identify", timeout=5).get("pid")), signal.SIGTERM)
        except Exception:  # noqa: BLE001
            pass
    if os.path.exists(LIVE_LOG):
        subprocess.run(["cp", LIVE_LOG, os.path.join(opts.out, "live-code.log")])
    mode_log = os.path.expanduser(f"~/Library/Caches/cmux-next/live-mode/{opts.tag}/live-mode.log")
    if os.path.exists(mode_log):
        subprocess.run(["cp", mode_log, os.path.join(opts.out, "live-mode.log")])
    start, stop = result.get("start", {}), result.get("stop", {})
    base = result.get("before", {})
    red = result.get("start_edit", {})
    blue = result.get("save_edit", {})
    after = result.get("after", {})
    result["ok"] = bool(
        start.get("exit") == 0 and start.get("sessions", {}).get("all") and result.get("watching")
        and red.get("applied") and red.get("red_px", 0) > base.get("red_px", 0) + 1000
        and blue.get("applied") and blue.get("same_pid") and blue.get("blue_px", 0) > base.get("blue_px", 0) + 1000
        and stop.get("exit") == 0 and stop.get("sessions", {}).get("all")
        and after.get("blue_px", 0) > base.get("blue_px", 0) + 1000
        and "Swift live mode: on" in result.get("status_live", "")
        and "Swift live mode: off" in result.get("status_after", ""))
    with open(os.path.join(opts.out, "result.json"), "w") as f:
        json.dump(result, f, indent=2)
    print(json.dumps(result, indent=2))
    for verb in ("start", "stop"):
        step = result.get(verb, {})
        print(f"live-mode-swift: {verb}: restart {step.get('restart_s')} s (quit {step.get('quit_s')} s, launch "
              f"{step.get('launch_s')} s), sessions kept {step.get('sessions')}, wall {step.get('wall_s')} s")
    sys.exit(0 if result["ok"] else 1)


if __name__ == "__main__":
    main()
