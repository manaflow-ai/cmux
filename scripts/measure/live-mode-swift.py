#!/usr/bin/env python3
"""The app half of scripts/measure/live-mode-swift.sh: Swift live mode end to end on a tagged build.

A person's normal tagged build runs with a few workspaces, and they edit HomeHostView (Home red).
`live-mode.py start` builds the live code build of that commit, turns Labs > Live Code on (its
confirmation sheet is answered here through debug.dialog), restarts into it and patches the edit in
(Home red). A save while live (Home blue) is patched in by the watcher, in the same process.
Then a patch that cannot load is refused with the app unchanged, and a rollback undoes the save's
patch (Home red again), all in the same process. Two terminals run a command throughout; each must
be the same live shell after start and after stop.
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
import tarfile
import threading
import time

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "measure"))
sys.path.insert(0, os.path.join(ROOT, "scripts", "cmux-next"))
from bench_launch import account_home, rpc_at, socket_candidates  # noqa: E402

LIVE_MODE = os.path.join(ROOT, "scripts/live-code/live-mode.py")
VIEW = os.path.join(ROOT, "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home/HomeHostView.swift")
ORIGINAL = "layer?.backgroundColor = nil"
RED = "layer?.backgroundColor = NSColor.systemRed.cgColor"
BLUE = "layer?.backgroundColor = NSColor.systemBlue.cgColor"
LIVE_LOG = os.path.join(account_home(), "Library/Caches/cmux-next/live-code/live-code.log")  # the app's home, not the step's $HOME


def socket(tag):
    """The tag's socket that answers (the state path, else its /tmp link)."""
    for path in socket_candidates(tag):
        reply = rpc_at(path, "system.ping", timeout=2)  # rpc_at answers errors as a dict, never raises
        if not (isinstance(reply, dict) and reply.get("unreachable")):
            return path
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


def ids_in(value, prefix):
    """Every string id in a socket answer that starts with `prefix`."""
    if isinstance(value, str):
        return {value} if value.startswith(prefix) else set()
    items = value.values() if isinstance(value, dict) else value if isinstance(value, list) else []
    return set().union(*(ids_in(item, prefix) for item in items)) if items else set()


def seed(path, out):
    """Two terminals in a second workspace (NEXT's newSurface action), each running a long command
    and with its shell's pid in a file: a terminal kept across a restart is the same shell, so the
    same pid. Returns the files."""
    # In their own workspace: a terminal split beside Home would leave Home's view off the full window,
    # and its red and blue are what the snapshots count.
    home = rpc_at(path, "snapshot.get", timeout=10) or {}
    first = next((w.get("id") for w in (home.get("topology") or {}).get("workspaces") or [] if w.get("id")), None)
    had = ids_in(home, "tab_")
    created = rpc_at(path, "action.run", {"action": "workspace.newAtBottom"}, timeout=30) or {}
    print(f"live-mode-swift: seed: workspace.newAtBottom answered {json.dumps(created)[:400]}", flush=True)
    workspace = next((str(i) for i in created.get("created") or [] if str(i).startswith("ws_")), None)
    if workspace:
        rpc_at(path, "action.run", {"action": "goToWorkspace", "args": {"workspace": workspace}}, timeout=30)
    tabs = [str(i) for i in created.get("created") or [] if str(i).startswith("tab_")]
    for _ in range(4):
        if len(tabs) >= 2:
            break
        made = rpc_at(path, "action.run", {"action": "newSurface"}, timeout=30) or {}
        print(f"live-mode-swift: seed: newSurface answered {json.dumps(made)[:400]}", flush=True)
        tabs += [str(i) for i in made.get("created") or [] if str(i).startswith("tab_") and str(i) not in tabs]
    time.sleep(3)
    # An answer without the ids it made: the tabs the snapshot has now and had not before.
    if len(tabs) < 2:
        tabs += [t for t in sorted(ids_in(rpc_at(path, "snapshot.get", timeout=10) or {}, "tab_") - had) if t not in tabs]
    print(f"live-mode-swift: seed: tabs {tabs}", flush=True)
    files = []
    for n, tab in enumerate(tabs):
        pid_file = os.path.join(out, f"shell-{n}.pid")
        # The shell writes its pid, then runs a command that outlives every restart in the test.
        rpc_at(path, "action.run", {"action": "terminal.sendText", "target": f"tab:{tab}",
                                    "args": {"text": f"echo $$ > '{pid_file}'; sleep 86400\r"}}, timeout=10)
        files.append(pid_file)
    time.sleep(2)
    if first:
        rpc_at(path, "action.run", {"action": "goToWorkspace", "args": {"workspace": first}}, timeout=30)
    return files


def shells(files):
    """{file: the shell pid it holds, and whether that process still runs}."""
    out = {}
    for name in files:
        try:
            pid = int(open(name).read().strip())
            os.kill(pid, 0)
            out[os.path.basename(name)] = {"pid": pid, "alive": True}
        except (OSError, ValueError):
            out[os.path.basename(name)] = {"pid": None, "alive": False}
    return out


def terminals_kept(result):
    """At least two terminals ran a command before start, and each is the same live shell after
    start and after stop (the daemon holds terminals; the app only reattaches)."""
    before = result.get("shells_before") or {}
    if sum(v["alive"] for v in before.values()) < 2:
        return False
    return all(result.get(phase, {}).get(name) == shell
               for phase in ("shells_live", "shells_after") for name, shell in before.items() if shell["alive"])


def forced_rollback(tag, out, live_pid):
    """A patch that cannot load (not a Mach-O file) is refused and the app keeps the code it runs;
    then a rollback undoes the newest patch (the save), so Home goes back to the live build's red."""
    folder = os.path.dirname(LIVE_LOG)
    stamp = int(time.time() * 1000)
    since = len(log_text())
    with open(os.path.join(folder, f"zz-bad-{stamp}.dylib"), "wb") as f:
        f.write(b"not a dylib\n")
    refused = wait_log(rf"zz-bad-{stamp}\.dylib refused", since, 60)
    time.sleep(1)
    path = socket(tag)
    bad = {"refused": bool(refused), "same_pid": rpc_at(path, "system.identify").get("pid") == live_pid,
           **snap(tag, out, "bad-patch")}
    since = len(log_text())
    with open(os.path.join(folder, f"zz-undo-{stamp}.rollback"), "w") as f:
        f.write("")
    undone = wait_log(r"rolled back \S+ functions=(\d+) rollback_ms=(\d+)", since, 60)
    time.sleep(1)
    back = {"rolled_back": bool(undone), "functions": int(undone.group(1)) if undone else None,
            "rollback_ms": int(undone.group(2)) if undone else None,
            "same_pid": rpc_at(socket(tag), "system.identify").get("pid") == live_pid, **snap(tag, out, "rolled-back")}
    return bad, back


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
    pid_files = seed(path, opts.out)
    result["shells_before"] = shells(pid_files)
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
        # The edit is in one of two ways: patched in after the restart (the commit's live code build was
        # already built), or compiled into that build (its first start builds from the checkout as it is).
        compiled = bool(result["start"].get("built_s")) and not (result["start"].get("edits") or {}).get("files")
        result["start_edit"] = {"applied": bool(first), "via": "patch" if first else ("live build" if compiled else None),
                                **snap(opts.tag, opts.out, "live-red")}
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
        result["shells_live"] = shells(pid_files)

        # 3. Forced rollback: a patch that fails to load, then the app back to its last good code.
        result["bad_patch"], result["rollback"] = forced_rollback(opts.tag, opts.out, result["live_pid"])

        # 4. Stop: the optimized build of the edited checkout (blue kept), sessions kept.
        started = time.time()
        code, result["stop"] = live_mode("stop", opts.tag)
        result["stop"]["exit"], result["stop"]["wall_s"] = code, round(time.time() - started, 1)
        path = wait_socket(opts.tag, 60)
        time.sleep(2)
        result["after"] = snap(opts.tag, opts.out, "after-stop")
        result["status_after"] = status_line(opts.tag)
        result["shells_after"] = shells(pid_files)
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
    mode_log = os.path.join(account_home(), f"Library/Caches/cmux-next/live-mode/{opts.tag}/live-mode.log")
    if os.path.exists(mode_log):
        subprocess.run(["cp", mode_log, os.path.join(opts.out, "live-mode.log")])
    start, stop = result.get("start", {}), result.get("stop", {})
    base = result.get("before", {})
    red = result.get("start_edit", {})
    blue = result.get("save_edit", {})
    after = result.get("after", {})
    result["ok"] = bool(
        start.get("exit") == 0 and start.get("sessions", {}).get("all") and result.get("watching")
        and red.get("via") and red.get("red_px", 0) > base.get("red_px", 0) + 1000
        and blue.get("applied") and blue.get("same_pid") and blue.get("blue_px", 0) > base.get("blue_px", 0) + 1000
        and stop.get("exit") == 0 and stop.get("sessions", {}).get("all")
        and after.get("blue_px", 0) > base.get("blue_px", 0) + 1000
        and "Swift live mode: on" in result.get("status_live", "")
        and "Swift live mode: off" in result.get("status_after", "")
        and terminals_kept(result)
        and result.get("bad_patch", {}).get("refused") and result["bad_patch"].get("same_pid")
        and result["bad_patch"].get("blue_px", 0) > base.get("blue_px", 0) + 1000
        and result.get("rollback", {}).get("rolled_back") and result["rollback"].get("same_pid")
        and result["rollback"].get("red_px", 0) > base.get("red_px", 0) + 1000)
    with open(os.path.join(opts.out, "result.json"), "w") as f:
        json.dump(result, f, indent=2)
    # One file for the step's artifact (cmux-ci uploads a regular file, not a folder).
    with tarfile.open(os.path.join(opts.out, "live-mode-e2e.tar.gz"), "w:gz") as bundle:
        for name in sorted(os.listdir(opts.out)):
            if name != "live-mode-e2e.tar.gz":
                bundle.add(os.path.join(opts.out, name), arcname=name)
    print(json.dumps(result, indent=2))
    for verb in ("start", "stop"):
        step = result.get(verb, {})
        print(f"live-mode-swift: {verb}: restart {step.get('restart_s')} s (quit {step.get('quit_s')} s, launch "
              f"{step.get('launch_s')} s), sessions kept {step.get('sessions')}, wall {step.get('wall_s')} s")
    sys.exit(0 if result["ok"] else 1)


if __name__ == "__main__":
    main()
