#!/usr/bin/env python3
"""Live check: a launch of cmux NEXT asks for no macOS permission (LAUNCH-NO-TCC-PROMPTS).

  scripts/cmux-next/launch-no-tcc-prompts-live.py --app PATH [--out DIR] [--seconds 45]
      [--phases first,restore] [--folder ~/Downloads]

The rule (Lawrence, 2026-10-30): cmux never asks for a permission at launch. Every permission
(Files and Folders, Contacts, Calendars, Photos, Microphone, Camera, Screen Recording,
Accessibility, Automation, Notifications, Local Network, Bluetooth, Full Disk Access) is asked
only when the person does the thing that needs it.

For each phase the script resets every macOS privacy answer of the app's bundle id
(`tccutil reset All <bundle id>`), streams tccd's log, launches the app through LaunchServices
(`open -n`, so the app is its own responsible process, as when the person opens it from the Dock
or Finder) and leaves it alone for `--seconds`. tccd logs every check a process makes with the
app as its responsible process, whether or not it would prompt (AUTHREQ_CTX, AUTHREQ_ATTRIBUTION,
AUTHREQ_RESULT). A check with `preflight=no` after a reset is a prompt the person would see.

  1. `first`: the first launch of this build (onboarding, Home, the daemons, the agent probes).
  2. `restore`: before it quits, the first phase opens a terminal in `--folder` (default
     ~/Downloads, the folder of the 2026-10-30 report). That is the person's own action, so a
     prompt there is allowed. The relaunch restores that terminal: nothing may read the folder
     until the person shows the terminal.

Fails (exit 1) when a phase logs a non-preflight check of the app (any service) or a
UserNotifications authorization request. Each phase writes `tcc-<phase>.log` (the raw stream),
`requests-<phase>.json` (one row per check: service, preflight, the requesting binary and pid,
the result) and `screen-<phase>-<n>.png` stills when `screencapture` may record the screen.

GUI host only: a capture mini or a Mac with a logged-in console session, run over SSH. The script
never touches another app's privacy answers. It quits the app and ends the tag's daemons at the end.
"""
import argparse, json, os, plistlib, re, shutil, signal, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_names  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="launch-no-tcc-"))
parser.add_argument("--seconds", type=float, default=45)
parser.add_argument("--phases", default="first,restore")
parser.add_argument("--folder", default="~/Downloads")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = os.path.abspath(opts.app.rstrip("/"))
FOLDER = os.path.expanduser(opts.folder)
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BUNDLE = plistlib.load(f)["CFBundleIdentifier"]
HOME = os.path.expanduser("~")
SOCKETS = build_names.socket_paths(build_names.of_app(APP, HOME)["socket"], HOME)
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def rpc(method, params=None, timeout=20):
    for path in SOCKETS:
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(timeout)
            conn.connect(path)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
            conn.close()
            reply = json.loads(buf)
            return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
        except (OSError, ValueError):
            continue
    return {"error": "no socket answers"}


def wait_until(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.5)
    return None


def app_pids():
    out = subprocess.run(["pgrep", "-f", os.path.join(APP, "Contents/MacOS/")], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


REQUEST = re.compile(r"AUTHREQ_(CTX|ATTRIBUTION|RESULT): msgID=(\S+?), (.*)")


def requests(log_text):
    """One row per tccd check whose responsible process is the app (or one of its bundle's ids)."""
    rows = {}
    for line in log_text.splitlines():
        m = REQUEST.search(line)
        if not m:
            continue
        kind, msg, rest = m.groups()
        row = rows.setdefault(msg, {"msg": msg, "time": line[:23]})
        if kind == "CTX":
            row["service"] = (re.search(r"service=(\w+)", rest) or [None, None])[1]
            row["preflight"] = (re.search(r"preflight=(\w+)", rest) or [None, None])[1]
        elif kind == "ATTRIBUTION":
            resp = re.search(r"responsible=\{TCCDProcess: identifier=([^,]+), pid=(\d+).*?binary_path=([^}]+)\}", rest)
            req = re.search(r"requesting=\{TCCDProcess: identifier=([^,]+), pid=(\d+).*?binary_path=([^}]+)\}", rest)
            if resp:
                row["responsible"], row["responsible_path"] = resp.group(1), resp.group(3)
            if req:
                row["requesting"], row["requesting_pid"], row["requesting_path"] = req.group(1), int(req.group(2)), req.group(3)
        else:
            row["auth_value"] = (re.search(r"authValue=(\d+)", rest) or [None, None])[1]
    root = BUNDLE.split(".helper")[0]
    return [r for r in rows.values() if (r.get("responsible") or "").startswith(root)
            or APP in (r.get("responsible_path") or "")]


def screenshot(phase, n):
    path = os.path.join(opts.out, f"screen-{phase}-{n}.png")
    subprocess.run(["screencapture", "-x", path], capture_output=True, timeout=20)
    return path if os.path.exists(path) else None


def launch():
    env = {"CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
    args = ["open", "-n", "-a", APP]
    for k, v in env.items():
        args += ["--env", f"{k}={v}"]
    subprocess.run(args, check=True, timeout=30)


def quit_app():
    rpc("action.run", {"action": "quit", "wait": False}, timeout=10)
    if wait_until(lambda: not app_pids(), 20) is None:
        for pid in app_pids():
            os.kill(pid, signal.SIGTERM)  # the app this script launched, by its bundle path
        wait_until(lambda: not app_pids(), 10)


def run_phase(phase, teardown):
    subprocess.run(["tccutil", "reset", "All", BUNDLE], capture_output=True, timeout=30)
    log_path = os.path.join(opts.out, f"tcc-{phase}.log")
    stream = subprocess.Popen(
        ["/usr/bin/log", "stream", "--info", "--style", "compact", "--predicate",
         'subsystem == "com.apple.TCC" OR (process == "usernoted" AND eventMessage CONTAINS[c] "authoriz")'],
        stdout=open(log_path, "w"), stderr=subprocess.STDOUT)
    time.sleep(2)  # log stream attaches before the launch it must see
    try:
        launch()
        up = wait_until(lambda: "error" not in (rpc("debug.focus") or {"error": 1}), 90)
        check(up is not None, f"{phase}: the app answers its socket")
        teardown.remember()
        shots, started, n = [], time.monotonic(), 0
        while time.monotonic() - started < opts.seconds:  # the person does nothing for --seconds
            time.sleep(min(10, max(0.1, opts.seconds - (time.monotonic() - started))))
            n += 1
            shots.append(screenshot(phase, n))
        stream.send_signal(signal.SIGINT)
        stream.wait(timeout=10)
        with open(log_path) as f:
            text = f.read()
        rows = requests(text)
        with open(os.path.join(opts.out, f"requests-{phase}.json"), "w") as f:
            json.dump(rows, f, indent=2)
        for r in rows:
            print(f"  {r.get('time')} {r.get('service')} preflight={r.get('preflight')} "
                  f"auth={r.get('auth_value')} by {r.get('requesting_path')} (pid {r.get('requesting_pid')})", flush=True)
        prompts = [r for r in rows if r.get("preflight") == "no"]
        named = sorted({"%s by %s" % (r.get("service"), os.path.basename(r.get("requesting_path") or "?")) for r in prompts})
        check(not prompts, f"{phase}: no privacy check that prompts ({len(prompts)} of {len(rows)} checks: {', '.join(named)})")
        notif = [l for l in text.splitlines() if "usernoted" in l and BUNDLE in l]
        check(not notif, f"{phase}: no notification authorization request ({len(notif)} lines)")
        print(f"  stills: {[s for s in shots if s]}", flush=True)
        return True
    finally:
        if stream.poll() is None:
            stream.kill()


def open_terminal_in_folder():
    reply = rpc("action.run", {"action": "splitRight", "args": {"cwd": FOLDER}, "focus": True})
    print("terminal in", FOLDER, json.dumps(reply)[:300], flush=True)
    time.sleep(3)  # the shell starts in the folder (the person's own action: a prompt here is fine)


teardown = TagTeardown(APP)
teardown.install()
try:
    phases = [p for p in opts.phases.split(",") if p]
    for i, phase in enumerate(phases):
        run_phase(phase, teardown)
        if phase == "first" and "restore" in phases[i + 1:]:
            open_terminal_in_folder()
        quit_app()
        # A relaunch after a restart: the terminal daemons end too, so the relaunch restores the
        # terminal (a new shell in its folder) instead of finding its shell still running.
        teardown.end()
finally:
    quit_app()
    teardown.end()
print(json.dumps({"bundle": BUNDLE, "failures": failures, "out": opts.out}), flush=True)
sys.exit(1 if failures else 0)
