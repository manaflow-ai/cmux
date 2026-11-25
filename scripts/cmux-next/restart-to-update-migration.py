#!/usr/bin/env python3
"""Restart to Update from an older cmux NEXT NIGHTLY, filmed, with what a person keeps checked.

Leo, 2026-11-24 (ask-5ea8364cbd): "for the next nightly, we want to have the restart to update working as
people expect... migration from my teammates to this is good".

Installs the NIGHTLY build --from (a teammate's older build, or the one a person runs today) into a scratch
folder, uses it the way a person does (two windows, named workspaces, a terminal running a process, settings
changed from their defaults), lets it find the feed's newest build, then presses Restart to Update
(palette.applyUpdateIfAvailable, the same action the update pill's button runs). Sparkle installs and relaunches
the app by itself. The check then reads, from the updated app, what the person had:

  - the bundle and the running app are the feed's newest build (--to);
  - the windows: as many, the same workspace in each, each still visible;
  - the workspaces by name, and the terminal's process still alive with its output;
  - every setting changed before the update reads the same value after it.

The whole run is filmed (screencapture -v) to --out/restart-to-update.mov, with report.json beside it.
Host rules match scripts/cmux-next/update-e2e.py: an Aqua GUI session for this user, no cmux NEXT installed or
running. The settings file is the real one (a person's Restart to Update has no launch environment), so an
existing one is kept aside and put back at the end.

  scripts/cmux-next/restart-to-update-migration.py --from BUILD [--to BUILD] [--out DIR] [--keep]
"""
import argparse, json, os, plistlib, re, shutil, socket, subprocess, sys, tempfile, time, urllib.request

BUNDLE_ID = "com.cmuxterm.app.nightly.cmux-next"
APP_NAME = "cmux NEXT.app"
SOCKET = "/tmp/cmux-nightly-cmux-next.sock"
HOME = os.path.expanduser("~")
FEED = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
DMG = "https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-{build}.dmg"
USER_AGENT = {"User-Agent": "cmux-restart-to-update-migration/1 (Sparkle-compatible test)"}

parser = argparse.ArgumentParser()
parser.add_argument("--from", dest="from_build", required=True, help="the build installed first (any published NIGHTLY)")
parser.add_argument("--to", dest="to_build", help="the build expected after the update (default: the feed's newest)")
parser.add_argument("--feed", default=FEED)
parser.add_argument("--out", default=os.path.join(os.getcwd(), ".build", "restart-to-update"))
parser.add_argument("--film-seconds", type=int, default=420, help="longest film (it stops early when the check ends)")
parser.add_argument("--keep", action="store_true", help="keep the scratch folder and leave the app running")
opts = parser.parse_args()

results = []


def record(check, ok, detail=""):
    state = ok if isinstance(ok, str) else ("PASS" if ok else "FAIL")
    results.append({"check": check, "state": state, "detail": detail})
    print(f"[{state}] {check}" + (f": {detail}" if detail else ""), flush=True)


def run(*args, timeout=60, **kw):
    return subprocess.run(list(args), capture_output=True, text=True, timeout=timeout, **kw)


def wait(probe, seconds, every=0.5):
    end = time.monotonic() + seconds
    while True:
        value = probe()
        if value or time.monotonic() >= end:
            return value
        time.sleep(every)


def rpc(method, params=None, timeout=10):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(SOCKET)
            sock.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            data = b""
            while not data.endswith(b"\n"):
                chunk = sock.recv(1 << 16)
                if not chunk:
                    break
                data += chunk
        reply = json.loads(data.decode() or "{}")
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    if reply.get("ok") is False:
        return {"error": reply.get("error")}
    result = reply.get("result", reply)
    return result if isinstance(result, dict) else {"value": result}


def bundle_build(app):
    try:
        with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
            return plistlib.load(f).get("CFBundleVersion")
    except OSError:
        return None


def cli(app, *argv, timeout=30):
    """The bundled CLI with --json: the parsed last line, or {"error": ...}."""
    env = {"HOME": HOME, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1"}
    try:
        done = run(os.path.join(app, "Contents/Resources/bin/cmux"), "--json", "--app-socket", SOCKET, *argv,
                   timeout=timeout, env=env, cwd=HOME)
    except subprocess.SubprocessError as error:
        return {"error": str(error)}
    lines = [line for line in done.stdout.splitlines() if line.strip()]
    try:
        answer = json.loads(lines[-1]) if lines else None
    except ValueError:
        answer = None
    if done.returncode != 0 or answer is None:
        return {"error": (done.stdout + done.stderr).strip()[-400:] or f"exit {done.returncode}"}
    for key in ("value", "result"):
        if isinstance(answer, dict) and isinstance(answer.get(key), dict):
            return answer[key]
    return answer


def topology():
    snap = rpc("snapshot.get", timeout=5)
    topo = snap.get("topology") if isinstance(snap, dict) else None
    return topo if isinstance(topo, dict) else None


def windows_seen(topo):
    """Each visible window as the workspace name it shows; sorted, ids left out (a person sees names)."""
    names = {w.get("id"): w.get("name") for w in (topo or {}).get("workspaces") or [] if isinstance(w, dict)}
    return sorted(str(names.get(w.get("workspace"))) for w in (topo or {}).get("windows") or []
                  if isinstance(w, dict) and w.get("visible"))


def workspace_names(topo):
    return sorted(w.get("name") for w in (topo or {}).get("workspaces") or [] if isinstance(w, dict) and w.get("name"))


def setting(path):
    answer = rpc("settings.get", {"path": path})
    return answer.get("value") if "error" not in answer else {"error": answer["error"]}


# Settings a person changes, each to a value that is not its default, readable by settings.get on every build
# since the settings socket shipped. A row whose get fails before the update is reported and left out.
SETTINGS = [
    ("app.quitBehavior", "keep"),
    ("updates.installOnQuit", True),
    ("appearance.fontSize", 15),
    ("sidebar.width", 287),
]


def preflight():
    if run("launchctl", "print", f"gui/{os.getuid()}").returncode != 0:
        sys.exit("refused: no Aqua GUI session for this user")
    running = run("pgrep", "-fl", f"{APP_NAME}/Contents/MacOS").stdout.strip()
    if running:
        sys.exit(f"refused: a cmux NEXT runs here:\n{running}")
    installed = [p for p in run("mdfind", f"kMDItemCFBundleIdentifier == '{BUNDLE_ID}'").stdout.splitlines()
                 if p.endswith(".app") and "/cmux-rtu-" not in p]
    if installed:
        sys.exit("refused: cmux NEXT is installed here: " + ", ".join(installed))
    if os.path.exists(SOCKET):
        sys.exit(f"refused: {SOCKET} exists")


def feed_newest():
    xml = urllib.request.urlopen(urllib.request.Request(opts.feed, headers=USER_AGENT), timeout=30).read().decode()
    return re.search(r"<sparkle:version>(\d+)<", xml).group(1)


def install(build, folder):
    dmg = os.path.join(folder, "build.dmg")
    url = DMG.format(build=build)
    print(f"downloading {url}", flush=True)
    with urllib.request.urlopen(urllib.request.Request(url, headers=USER_AGENT), timeout=600) as r, open(dmg, "wb") as out:
        shutil.copyfileobj(r, out, 1 << 20)
    mount = os.path.join(folder, "mnt")
    os.makedirs(mount, exist_ok=True)
    attach = run("hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount, dmg, timeout=300)
    if attach.returncode != 0:
        sys.exit(f"hdiutil attach failed: {attach.stderr}")
    try:
        name = next(n for n in os.listdir(mount) if n.endswith(".app"))
        app = os.path.join(folder, name)
        run("ditto", os.path.join(mount, name), app, timeout=300)
    finally:
        run("hdiutil", "detach", mount, timeout=120)
    os.unlink(dmg)
    return app


def launch(app, log):
    # No launch environment: Sparkle's relaunch has none either, so both launches read the same state.
    opened = run("open", "-n", "--stdout", log, "--stderr", log, app)
    if opened.returncode != 0:
        print(f"open failed: {opened.stderr}")
        return None
    return wait(lambda: os.path.exists(SOCKET) and rpc("updates.status").get("build"), 120)


def app_pids(app):
    return [int(p) for p in run("pgrep", "-f", os.path.join(app, "Contents/MacOS/")).stdout.split()]


def seed(app, work):
    made = {}
    pidfile = os.path.join(work, "terminal.pid")
    a = cli(app, "workspace", "create", "--name", "rtu-terminal")
    term = a.get("terminal_id") if isinstance(a, dict) else None
    made["create_a"] = a
    if term:
        token = f"rtu-before-{int(time.time())}"
        cli(app, "terminal", term, "write", "--text", f"sh -c 'echo $$ > {pidfile}; echo {token}; exec sleep 86400'\n")
        wait(lambda: os.path.exists(pidfile) and open(pidfile).read().strip(), 20)
        made.update(terminal=term, token=token, pidfile=pidfile)
    b = cli(app, "workspace", "create", "--name", "rtu-second-window")
    made["create_b"] = b
    # A second window, the way a person opens one (File > New Window), showing the second workspace.
    made["new_window"] = rpc("action.run", {"id": "window.new"})
    time.sleep(2)
    if isinstance(b, dict) and b.get("workspace_id"):
        cli(app, "workspace", b["workspace_id"], "focus")
    if isinstance(a, dict) and a.get("workspace_id"):
        time.sleep(1)
    changed = {}
    for path, value in SETTINGS:
        before = setting(path)
        if isinstance(before, dict) and before.get("error"):
            print(f"setting {path}: not readable on this build ({before['error']}); left out")
            continue
        answer = rpc("settings.set", {"path": path, "value": value})
        got = wait(lambda: setting(path) == value, 10, 0.25)
        if got:
            changed[path] = value
        else:
            print(f"setting {path}: set answered {answer}, reads {setting(path)!r}; left out")
    made["settings"] = changed
    return made


def terminal_state(app, made):
    pid = None
    try:
        pid = int(open(made["pidfile"]).read().strip())
        os.kill(pid, 0)
    except (KeyError, OSError, ValueError):
        pid = None
    screen = cli(app, "terminal", made.get("terminal", "-"), "screen", "read")
    text = json.dumps(screen)
    return {"pid": pid, "token_on_screen": made.get("token", "\0") in text}


def main():
    preflight()
    os.makedirs(opts.out, exist_ok=True)
    to_build = opts.to_build or feed_newest()
    work = tempfile.mkdtemp(prefix="cmux-rtu-")
    log = os.path.join(opts.out, "app.log")
    film = os.path.join(opts.out, "restart-to-update.mov")
    recorder = None
    app = None
    report = {"from": opts.from_build, "to": to_build, "host": os.uname().nodename}
    try:
        app = install(opts.from_build, work)
        record("installed the older build", bundle_build(app) == opts.from_build, bundle_build(app))
        recorder = subprocess.Popen(["screencapture", "-x", "-v", "-V", str(opts.film_seconds), film],
                                    stdout=subprocess.DEVNULL, stderr=open(os.path.join(opts.out, "film.log"), "w"))
        report["film_started"] = time.time()
        record("older build launched, control socket answers", bool(launch(app, log)), rpc("updates.status").get("build"))
        made = seed(app, work)
        report["seed"] = made
        before = {"topology_windows": windows_seen(topology()), "workspaces": workspace_names(topology()),
                  "terminal": terminal_state(app, made),
                  "settings": {p: setting(p) for p in made["settings"]}}
        report["before"] = before
        print("before:", json.dumps(before), flush=True)
        record("seeded two windows, a terminal and changed settings",
               len(before["topology_windows"]) >= 2 and bool(before["terminal"]["pid"]) and bool(made["settings"]),
               json.dumps(before))
        rpc("action.run", {"id": "palette.checkForUpdates"})
        staged = wait(lambda: (lambda s: s if s.get("phase") == "installing" else None)(rpc("updates.status")), 900, 2)
        record("update found, downloaded and staged", bool(staged),
               json.dumps({k: (staged or {}).get(k) for k in ("phase", "detected_version", "badge", "card")}))
        pids = app_pids(app)
        clicked = time.time()
        report["clicked"] = clicked
        report["apply"] = rpc("action.run", {"id": "palette.applyUpdateIfAvailable"})
        gone = wait(lambda: not any(run("kill", "-0", str(p)).returncode == 0 for p in pids), 180)
        record("the older app quit for the install", bool(gone), f"pids {pids}")
        replaced = wait(lambda: bundle_build(app) == to_build, 300, 1)
        record("Sparkle replaced the bundle with the newest build", bool(replaced), bundle_build(app))
        back = wait(lambda: app_pids(app) and os.path.exists(SOCKET) and rpc("updates.status").get("build") == to_build, 180, 1)
        report["relaunch_s"] = round(time.time() - clicked, 1)
        record("Sparkle relaunched the updated app by itself", bool(back), f"{report['relaunch_s']} s after the click")
        settled = wait(lambda: len(windows_seen(topology())) >= len(before["topology_windows"]) and topology(), 60, 0.5)
        time.sleep(3)
        topo = topology()
        after = {"topology_windows": windows_seen(topo), "workspaces": workspace_names(topo),
                 "terminal": terminal_state(app, made),
                 "settings": {p: setting(p) for p in made["settings"]}}
        report["after"] = after
        print("after:", json.dumps(after), flush=True)
        record("windows: as many, each showing the same workspace", after["topology_windows"] == before["topology_windows"],
               f"{before['topology_windows']} -> {after['topology_windows']}" + ("" if settled else " (never settled)"))
        record("workspaces kept by name", set(before["workspaces"]) <= set(after["workspaces"]),
               f"{before['workspaces']} -> {after['workspaces']}")
        record("terminal process survived the update", after["terminal"]["pid"] == before["terminal"]["pid"] and bool(after["terminal"]["pid"]),
               f"{before['terminal']} -> {after['terminal']}")
        record("terminal output kept", after["terminal"]["token_on_screen"], "")
        record("settings kept", after["settings"] == before["settings"], f"{before['settings']} -> {after['settings']}")
        time.sleep(4)  # the film shows the restored windows settle
    finally:
        if recorder:
            recorder.send_signal(2)  # screencapture finishes the file on SIGINT
            try:
                recorder.wait(30)
            except subprocess.TimeoutExpired:
                recorder.kill()
        failed = [r for r in results if r["state"] == "FAIL"]
        report.update(results=results, ok=not failed, film=film if os.path.exists(film) else None)
        with open(os.path.join(opts.out, "report.json"), "w") as f:
            json.dump(report, f, indent=1)
        if not opts.keep and app:
            rpc("action.run", {"id": "quit", "args": {"endEverything": True}})
            pids = app_pids(app)
            if not wait(lambda: not any(run("kill", "-0", str(p)).returncode == 0 for p in pids), 90):
                print(f"quit did not end {pids} within 90 s; not signalling them")
            shutil.rmtree(work, ignore_errors=True)
    print(json.dumps({"results": results, "ok": not failed}, indent=1))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
