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
  - every setting changed before the update reads the same value after it;
  - --tabless terminals with no tab, each held by an attach stream (an agent's terminal), more than the reap
    cap of 16: every process still alive more than one reap grace after the new owner took them over;
  - --agents acpmux agents at work (the test agent's "steps" turn, a tool call every 150 ms): the same agent
    process after the update, its turn still stepping, no take-over SIGTERM.
  - the updated build pauses the automatic updater (its log says so, Sparkle's automatic check is off).

report.json has relaunch_s (click to the new build's socket answering) and windows_back_s (click to every
window back), the two numbers a stopwatch on the film reads.

Leo, 2026-11-25 (c-68068a551d): "the newest nightly does it fix the transition on the next one? like, we need a
cutover that can... do the restart close andwhatever without being clumsy".

The whole run is filmed (screencapture -v) to --out/restart-to-update.mov, with report.json beside it.
Host rules match scripts/cmux-next/update-e2e.py: an Aqua GUI session for this user, no cmux NEXT installed or
running. The settings file is the real one (a person's Restart to Update has no launch environment), so an
existing one is kept aside and put back at the end.

  scripts/cmux-next/restart-to-update-migration.py --from BUILD [--to BUILD] [--out DIR] [--keep]
"""
import argparse, json, os, plistlib, re, shutil, socket, subprocess, sys, tempfile, time, urllib.request

HOME = os.path.expanduser("~")
# The NIGHTLY's identity is the product's, not this script's: it moved from com.cmuxterm.app.nightly.cmux-next ("cmux
# NEXT.app", /tmp/cmux-nightly-cmux-next.sock) to com.cmuxterm.app.nightly ("cmux NIGHTLY.app", its socket in
# ~/.local/state/cmux-next). Preflight refuses on any of them; after the install the socket comes from the bundle's own id.
KNOWN_BUNDLES = ("com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next")
SOCKET = None
FEED = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
DMG = "https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-{build}.dmg"
USER_AGENT = {"User-Agent": "cmux-restart-to-update-migration/1 (Sparkle-compatible test)"}

parser = argparse.ArgumentParser()
parser.add_argument("--from", dest="from_build", required=True, help="the build installed first (any published NIGHTLY)")
parser.add_argument("--to", dest="to_build", help="the build expected after the update (default: the feed's newest)")
parser.add_argument("--feed", default=FEED)
parser.add_argument("--out", default=os.path.join(os.getcwd(), ".build", "restart-to-update"))
parser.add_argument("--film-seconds", type=int, default=420, help="longest film (it stops early when the check ends)")
parser.add_argument("--tabless", type=int, default=20, help="tab-less terminals held by an attach stream (0: none)")
parser.add_argument("--agents", type=int, default=3, help="acpmux test agents at work across the update (0: none)")
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
    for name in ("cmux NIGHTLY.app", "cmux NEXT.app"):
        running = run("pgrep", "-fl", f"{name}/Contents/MacOS").stdout.strip()
        if running:
            sys.exit(f"refused: a {name} runs here:\n{running}")
    for bundle_id in KNOWN_BUNDLES:
        installed = [p for p in run("mdfind", f"kMDItemCFBundleIdentifier == '{bundle_id}'").stdout.splitlines()
                     if p.endswith(".app") and "/cmux-rtu-" not in p]
        if installed:
            sys.exit(f"refused: {bundle_id} is installed here: " + ", ".join(installed))
        for path in socket_candidates(bundle_id):
            if os.path.exists(path):
                sys.exit(f"refused: {path} exists")


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


def sanitize(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or None


def socket_candidates(bundle_id):
    """The control socket ControlSocketPath.resolve gives this bundle id: the /tmp name, moved into
    ~/.local/state/cmux-next when it fits sun_path (the app keeps the /tmp name as a symlink)."""
    tmp = None
    for channel_id, channel in (("com.cmuxterm.app.nightly", "nightly"), ("com.cmuxterm.app.rc", "rc"),
                                ("com.cmuxterm.app.staging", "staging")):
        if bundle_id == channel_id:
            tmp = f"/tmp/cmux-{channel}.sock"
        elif bundle_id.startswith(channel_id + ".") and sanitize(bundle_id[len(channel_id) + 1:]):
            tmp = f"/tmp/cmux-{channel}-{sanitize(bundle_id[len(channel_id) + 1:])}.sock"
    if not tmp:
        return []
    moved = os.path.join(HOME, ".local/state/cmux-next", tmp[len("/tmp/"):])
    return [moved, tmp] if len(moved.encode()) <= 103 else [tmp]


def use_bundle(app):
    """Point SOCKET at the installed bundle's control socket; returns its bundle id."""
    global SOCKET
    with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
        bundle_id = plistlib.load(f).get("CFBundleIdentifier", "")
    candidates = socket_candidates(bundle_id) or sys.exit(f"refused: no control socket rule for bundle {bundle_id!r}")
    SOCKET = next((c for c in candidates if os.path.exists(c)), candidates[0])
    return bundle_id


def find_socket(app):
    """The first candidate that exists now (the update may move it), kept in SOCKET."""
    global SOCKET
    with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
        candidates = socket_candidates(plistlib.load(f).get("CFBundleIdentifier", ""))
    found = next((c for c in candidates if os.path.exists(c)), None)
    if found:
        SOCKET = found
    return found


def launch(app, log):
    # No launch environment: Sparkle's relaunch has none either, so both launches read the same state.
    opened = run("open", "-n", "--stdout", log, "--stderr", log, app)
    if opened.returncode != 0:
        print(f"open failed: {opened.stderr}")
        return None
    return wait(lambda: find_socket(app) and rpc("updates.status").get("build"), 120)


def app_pids(app):
    # The app's own executables only: Sparkle's installer carries the app's path in its arguments too.
    prefix = os.path.realpath(app) + "/Contents/MacOS/"
    rows = (line.strip().split(None, 1) for line in run("ps", "-axo", "pid=,comm=").stdout.splitlines() if line.strip())
    return [int(r[0]) for r in rows if len(r) == 2 and os.path.realpath(r[1]).startswith(prefix)]


def processes(app):
    """Every process running from the bundle, with its start time: a restart between two reads shows here."""
    prefix = os.path.realpath(app) + "/Contents/"
    rows = run("ps", "-axo", "pid=,lstart=,command=").stdout.splitlines()
    return [r.strip() for r in rows if prefix in r or "cmux-tui" in r or "cmux-holder" in r]


def keep_crash_reports(since, out):
    """Copy the crash and hang reports macOS wrote for cmux since `since` into out/crash (read after a FAIL)."""
    kept = []
    for folder in (os.path.join(HOME, "Library/Logs/DiagnosticReports"), "/Library/Logs/DiagnosticReports"):
        try:
            names = os.listdir(folder)
        except OSError:
            continue
        for name in names:
            path = os.path.join(folder, name)
            try:
                if "cmux" in name.lower() and os.path.getmtime(path) >= since:
                    os.makedirs(os.path.join(out, "crash"), exist_ok=True)
                    shutil.copy2(path, os.path.join(out, "crash", name))
                    kept.append(name)
            except OSError:
                pass
    return kept


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


REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FAKE_AGENT = os.path.join(REPO, "cmux-tui/crates/acpmux/tests/fake_agent.py")
HARNESS = "rtufake"
# NEXT's own folder (`cmux-next` on macOS since #56195), and `cmux` for builds before it.
HARNESS_FILES = [os.path.join(HOME, ".config", name, "harnesses", f"{HARNESS}.toml") for name in ("cmux-next", "cmux")]
attachers = []  # the `terminal attach` CLIs this run started; only these are ended at the end


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def attach(app, term, work):
    """An attach stream on a terminal, as the app holds one on an agent's terminal with no tab."""
    env = {"HOME": HOME, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1"}
    log = open(os.path.join(work, f"attach-{term}.log"), "ab")
    proc = subprocess.Popen([os.path.join(app, "Contents/Resources/bin/cmux"), "--app-socket", SOCKET,
                             "terminal", term, "attach"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                            stderr=log, env=env, cwd=HOME)
    attachers.append(proc)
    return proc


def close_workspace(app, workspace):
    cli(app, "workspace", workspace, "focus")
    wait(lambda: rpc("snapshot.get", timeout=5), 2)
    reply = rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}, "focus": True, "origin": "script"}, 30)
    if "error" in reply:
        reply = rpc("action.run", {"id": "closeWorkspace", "args": {"confirm": True}}, 30)
    return wait(lambda: workspace not in {w.get("id") for w in (topology() or {}).get("workspaces") or []}, 15, 0.25), reply


def seed_tabless(app, work, count):
    """`count` terminals, each running a process, held by an attach stream, their workspace closed: no tab."""
    rows = []
    for n in range(count):
        made = cli(app, "workspace", "create", "--name", f"rtu-tabless-{n}")
        term = made.get("terminal_id") if isinstance(made, dict) else None
        if not term:
            print(f"tab-less {n}: workspace create answered {made}")
            continue
        pidfile = os.path.join(work, f"tabless-{n}.pid")
        cli(app, "terminal", term, "write", "--text", f"sh -c 'echo $$ > {pidfile}; exec sleep 86400'\n")
        if not wait(lambda: os.path.exists(pidfile) and open(pidfile).read().strip(), 20):
            print(f"tab-less {n}: the process never wrote its pid")
            continue
        attach(app, term, work)
        time.sleep(0.5)
        closed, reply = close_workspace(app, made["workspace_id"])
        rows.append({"terminal": term, "pid": int(open(pidfile).read().strip()), "closed": bool(closed),
                     **({} if closed else {"close": reply})})
    return rows


def write_harness(work):
    """The files this run wrote (only these are removed at the end); one already there is not ours: left."""
    written = []
    for path in HARNESS_FILES:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.exists(path):
            continue
        with open(path, "w") as f:
            f.write(f'schema = 1\nid = "{HARNESS}"\nname = "Restart to Update test agent"\nprotocol = "acp"\n'
                    f'command = "/usr/bin/python3"\nargs = [{json.dumps(FAKE_AGENT)}]\n'
                    f'[env]\nFAKE_STEP_LOG = {json.dumps(os.path.join(work, "steps.log"))}\n'
                    f'FAKE_CLASS_LOG = {json.dumps(os.path.join(work, "agents.jsonl"))}\n')
        os.chmod(path, 0o600)
        written.append(path)
    return written


def agent_pids(work):
    try:
        return [json.loads(line)["pid"] for line in open(os.path.join(work, "agents.jsonl")) if line.strip()]
    except (OSError, ValueError, KeyError):
        return []


def steps(work):
    try:
        return sum(1 for _ in open(os.path.join(work, "steps.log")))
    except OSError:
        return 0


def seed_agents(app, work, count):
    """`count` test agents in a "steps" turn: a finished tool call every 150 ms until cancelled."""
    out = {"profile_written": write_harness(work), "chats": []}
    cli(app, "harness", "reload")
    cli(app, "setup", "trust", work)
    ws = cli(app, "workspace", "create", "--name", "rtu-agents")
    for n in range(count):
        chat = cli(app, "agents", "chat", "new", "--workspace", (ws or {}).get("workspace_id", ""), "--harness", HARNESS,
                   "--cwd", work, "--name", f"rtu-agent-{n}", "--", "steps", timeout=90)
        out["chats"].append(chat.get("chat") if isinstance(chat, dict) and chat.get("chat") else {"error": chat})
    wait(lambda: len(agent_pids(work)) >= count and steps(work) >= 5 * count, 60, 0.5)
    out["pids"] = agent_pids(work)
    return out


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
        report["bundle_id"] = use_bundle(app)
        launched = launch(app, log)
        record("older build launched, control socket answers", bool(launched), f"{report['bundle_id']} at {SOCKET}: {launched}")
        if not launched:
            # Every later check needs the socket; stop here instead of reporting their empty reads.
            raise SystemExit(1)
        report["processes_launched"] = processes(app)
        launch_pids = app_pids(app)
        made = seed(app, work)
        report["seed"] = made
        report["processes_seeded"] = processes(app)
        tabless = seed_tabless(app, work, opts.tabless) if opts.tabless else []
        report["tabless"] = tabless
        if opts.tabless:
            held = [r for r in tabless if r["closed"] and alive(r["pid"])]
            record(f"seeded {opts.tabless} tab-less terminals held by an attach stream", len(held) == opts.tabless,
                   f"{len(held)} placed nowhere and alive")
        agents = seed_agents(app, work, opts.agents) if opts.agents else {}
        report["agents"] = agents
        if opts.agents:
            record(f"seeded {opts.agents} agents at work", len(agents["pids"]) >= opts.agents and steps(work) > 0,
                   f"pids {agents['pids']}, {steps(work)} steps")
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
        if opts.tabless:
            ended = [r["terminal"] for r in tabless if not alive(r["pid"])]
            record("tab-less terminals alive at the click (the attach streams hold them)", not ended and bool(tabless),
                   f"ended before the update: {ended}" if ended else f"{len(tabless)} alive")
        pids = app_pids(app)
        report["processes_at_click"] = processes(app)
        # The transition under test is the click's. An older build that installs by itself first (Update When
        # Idle, before the pause shipped) leaves nothing for the click to do, and every later check would read
        # that automatic install instead: say so here rather than pass on it.
        record("nothing installed or restarted before the click", bundle_build(app) == opts.from_build
               and bool(pids) and pids == launch_pids,
               f"bundle {bundle_build(app)}, app pids {launch_pids} at launch -> {pids} at the click")
        print("at the click:", json.dumps(report["processes_at_click"]), flush=True)
        steps_before = steps(work)
        clicked = time.time()
        report["clicked"] = clicked
        report["apply"] = rpc("action.run", {"id": "palette.applyUpdateIfAvailable"})
        gone = wait(lambda: not any(run("kill", "-0", str(p)).returncode == 0 for p in pids), 180)
        record("the older app quit for the install", bool(gone), f"pids {pids}")
        replaced = wait(lambda: bundle_build(app) == to_build, 300, 1)
        record("Sparkle replaced the bundle with the newest build", bool(replaced), bundle_build(app))
        # A new app process: the one running at the click answering with the new build is no relaunch.
        back = wait(lambda: set(app_pids(app)) - set(pids) and find_socket(app)
                    and rpc("updates.status").get("build") == to_build, 180, 1)
        report["relaunch_s"] = round(time.time() - clicked, 1) if back else None
        record("Sparkle relaunched the updated app by itself", bool(back),
               f"{report['relaunch_s']} s after the click" if back else f"no new app process within 180 s (pids {app_pids(app)})")
        settled = wait(lambda: len(windows_seen(topology())) >= len(before["topology_windows"]) and topology(), 60, 0.5)
        report["windows_back_s"] = round(time.time() - clicked, 1)
        # Leo, 2026-11-24: "so pasuse the auto updateer for now". The updated build itself, not the PR: its
        # updater logs the pause at start and keeps Sparkle's own automatic check off (AutomaticUpdatePause).
        status = rpc("updates.status")
        # The updated bundle's own id: the NIGHTLY's id moved between builds, so read it, never assume it.
        with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
            updated_id = plistlib.load(f).get("CFBundleIdentifier", "")
        checks = run("defaults", "read", updated_id, "SUEnableAutomaticChecks").stdout.strip()
        report["pause"] = {"logged": "automatic updates paused" in json.dumps(status), "SUEnableAutomaticChecks": checks}
        record("the updated build pauses the automatic updater", report["pause"]["logged"] and checks in ("0", "false"),
               json.dumps(report["pause"]))
        time.sleep(3)
        topo = topology()
        after = {"topology_windows": windows_seen(topo), "workspaces": workspace_names(topo),
                 "terminal": terminal_state(app, made),
                 "settings": {p: setting(p) for p in made["settings"]}}
        report["after"] = after
        print("after:", json.dumps(after), flush=True)
        record("windows: as many, each showing the same workspace", after["topology_windows"] == before["topology_windows"] and bool(before["topology_windows"]),
               f"{before['topology_windows']} -> {after['topology_windows']}" + ("" if settled else " (never settled)"))
        record("workspaces kept by name", set(before["workspaces"]) <= set(after["workspaces"]) and bool(before["workspaces"]),
               f"{before['workspaces']} -> {after['workspaces']}")
        record("terminal process survived the update", after["terminal"]["pid"] == before["terminal"]["pid"] and bool(after["terminal"]["pid"]),
               f"{before['terminal']} -> {after['terminal']}")
        record("terminal output kept", after["terminal"]["token_on_screen"], "")
        record("settings kept", after["settings"] == before["settings"] and bool(before["settings"]), f"{before['settings']} -> {after['settings']}")
        if opts.agents:
            pids_now = [p for p in agents["pids"] if alive(p)]
            mark = steps(work)
            stepping = wait(lambda: steps(work) > mark + 5, 30, 0.5)
            record("agents at work: the same processes after the update", pids_now == agents["pids"] and bool(pids_now),
                   f"{agents['pids']} -> alive {pids_now}; agents started since: {agent_pids(work)[len(agents['pids']):]}")
            record("agents at work: their turns kept stepping across the update", bool(stepping) and mark > steps_before,
                   f"{steps_before} steps at the click, {mark} after the relaunch, {steps(work)} now")
        if opts.tabless:
            # The app attaches again as it would (its CLI stand-ins quit with the old app's socket), then the check
            # waits out more than one reap grace from the new owner's start.
            for row in tabless:
                attach(app, row["terminal"], work)
            time.sleep(40)
            gone = [r for r in tabless if r["closed"] and not alive(r["pid"])]
            record(f"tab-less attach-held terminals alive past one grace on the new owner ({len(tabless)} > cap 16)",
                   not gone and bool(tabless), f"{len(tabless) - len(gone)} of {len(tabless)} alive"
                   + (f"; ended: {[r['terminal'] for r in gone]}" if gone else ""))
        time.sleep(4)  # the film shows the restored windows settle
    finally:
        if recorder:
            recorder.send_signal(2)  # screencapture finishes the file on SIGINT
            try:
                recorder.wait(30)
            except subprocess.TimeoutExpired:
                recorder.kill()
        for proc in attachers:
            if proc.poll() is None:
                proc.terminate()
        if opts.agents:
            for path in (report.get("agents") or {}).get("profile_written") or []:
                if path in HARNESS_FILES and os.path.exists(path):
                    os.unlink(path)
        failed = [r for r in results if r["state"] == "FAIL"]
        report["processes_end"] = processes(app) if app else []
        report["crash_reports"] = keep_crash_reports(report.get("film_started", time.time() - 3600) - 60, opts.out)
        if report["crash_reports"]:
            print("crash reports:", report["crash_reports"], flush=True)
        if failed:
            try:
                tail = open(log, errors="replace").read().splitlines()[-120:]
                print("app.log, last lines:\n" + "\n".join(tail), flush=True)
            except OSError:
                pass
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
