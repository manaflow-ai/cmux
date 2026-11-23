#!/usr/bin/env python3
"""Throwaway repro (goal onboarding-new-person): does Open Cloud as Pane open anything in a fresh home?

np-open-cloud-repro.py --dmg DMG --out DIR

Launches the DMG's app with a fresh home (the fresh-home smoke's env), waits for Home, then runs over the control
socket, each with focus: openSettings, palette.openCloudPane (twice). After each it keeps the snapshot, a screenshot
and the reply. Prints NPOC lines; the app's unified log (cloud, page, tab lines) at the end."""
import argparse
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SMOKE_PATH = Path(__file__).resolve().parents[1] / "ci" / "fresh_home_launch_smoke.py"


def load_smoke():
    spec = importlib.util.spec_from_file_location("fresh_home_launch_smoke", SMOKE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def rpc(sock_path: Path, method: str, params: dict, timeout: float = 20.0):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(str(sock_path))
            sock.sendall((json.dumps({"id": 7, "method": method, "params": params}) + "\n").encode())
            buffer = b""
            while b"\n" not in buffer:
                chunk = sock.recv(1 << 20)
                if not chunk:
                    break
                buffer += chunk
        return json.loads(buffer.split(b"\n", 1)[0])
    except (OSError, ValueError) as error:
        return {"transport_error": str(error)}


def summary(snap) -> dict:
    if not isinstance(snap, dict):
        return {"snapshot": None}
    out = {"keys": sorted(snap.keys())[:40]}
    for key in ("windows", "workspaces", "tabs", "panes"):
        value = snap.get(key)
        if isinstance(value, list):
            out[key] = len(value)
    tabs = snap.get("tabs") if isinstance(snap.get("tabs"), list) else []
    out["tab_rows"] = [{k: t.get(k) for k in ("id", "kind", "page", "title", "pane", "workspace", "selected")
                        if isinstance(t, dict) and k in t} for t in tabs][:30]
    windows = snap.get("windows") if isinstance(snap.get("windows"), list) else []
    out["window_rows"] = [{k: w.get(k) for k in ("id", "workspace", "topPage", "top_page", "visible", "key")
                           if isinstance(w, dict) and k in w} for w in windows][:5]
    return out


def step(smoke, sock_path: Path, out: Path, name: str, method: str | None, params: dict | None, settle: float):
    reply = rpc(sock_path, method, params) if method else None
    time.sleep(settle)
    snap = smoke.snapshot(sock_path, timeout=10.0)
    (out / f"snap-{name}.json").write_text(json.dumps(snap, indent=1), encoding="utf-8")
    shot = out / f"shot-{name}.png"
    subprocess.run(["screencapture", "-x", str(shot)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    print("NPOC step", name, json.dumps({"reply": reply, **summary(snap)})[:6000], flush=True)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dmg", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    os.umask(0o022)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    smoke = load_smoke()
    problem = smoke.gui_session_problem()
    if problem:
        print(f"NPOC cannot run: {problem}", flush=True)
        return 3
    mount = Path(tempfile.mkdtemp(prefix="cmux-npoc-mnt-", dir="/tmp"))
    root = Path(tempfile.mkdtemp(prefix="cmux-npoc-", dir="/tmp"))
    process = None
    try:
        subprocess.run(["hdiutil", "attach", args.dmg, "-nobrowse", "-readonly", "-mountpoint", str(mount)],
                       check=True, stdout=subprocess.DEVNULL, timeout=300)
        source = sorted(mount.glob("*.app"))[0]
        bundle_id, executable = smoke.bundle_info(source)
        app = smoke.copy_app(source, root)
        print("NPOC app", bundle_id, executable, flush=True)
        sock_path = root / "c.sock"
        marks_read, marks_write = os.pipe()
        env = smoke.fresh_env(root, sock_path, marks_write)
        env.pop("CMUX_NEXT_NO_ACTIVATE", None)
        smoke.login_keychain(env)
        with smoke.DefaultsAside(bundle_id, root):
            app_log = open(out / "app.log", "wb")
            process = subprocess.Popen([str(app / "Contents" / "MacOS" / executable), "-ApplePersistenceIgnoreState", "YES"],
                                       env=env, cwd=env["HOME"], stdin=subprocess.DEVNULL, stdout=app_log,
                                       stderr=subprocess.STDOUT, pass_fds=(marks_write,), start_new_session=True)
            os.close(marks_write)
            started = time.time()
            seen = smoke.watch(process, marks_read, root / "marks", sock_path, 15.0, 120.0)
            print("NPOC home", json.dumps({"rendered_at": seen["rendered_at"], "exit": seen["exit"]}), flush=True)
            if seen["rendered_at"] is None:
                return 1
            time.sleep(10)
            step(smoke, sock_path, out, "0-home", None, None, 0)
            step(smoke, sock_path, out, "1-settings", "action.run", {"action": "openSettings", "focus": True}, 4)
            step(smoke, sock_path, out, "2-cloud", "action.run", {"action": "palette.openCloudPane", "focus": True}, 6)
            step(smoke, sock_path, out, "3-cloud-again", "action.run", {"action": "palette.openCloudPane", "focus": True}, 6)
            step(smoke, sock_path, out, "4-cloud-noarg", "action.run", {"action": "palette.openCloudPane"}, 6)
            minutes = max(2, int((time.time() - started) / 60) + 1)
            logged = subprocess.run(["log", "show", "--style", "compact", "--last", f"{minutes}m", "--info",
                                     "--predicate", f"processID == {process.pid}"],
                                    capture_output=True, text=True, timeout=180).stdout
            (out / "unified.log").write_text(logged, encoding="utf-8")
            words = ("cloud", "page", "tab", "refus", "fail", "error", "top")
            for line in logged.splitlines():
                if any(w in line.lower() for w in words):
                    print("NPOC log", line[:400], flush=True)
            smoke.stop_child(process)
            smoke.stop(smoke.own_pids(root))
            os.close(marks_read)
    finally:
        if process is not None and process.poll() is None:
            smoke.stop_child(process)
        smoke.detach(mount)
        shutil.rmtree(mount, ignore_errors=True)
        shutil.rmtree(root, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
