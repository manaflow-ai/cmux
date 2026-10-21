#!/usr/bin/env python3
"""Live proof that an automation launch leaves the host's notification center alone (cx-zkxzp).

  scripts/cmux-next/automation-notifications-quiet-live.py --tag <tag> [--app PATH] [--out DIR]

Launches the tagged app as e2e scripts and GUI proofs do (CMUX_NEXT_NO_ACTIVATE=1,
CMUX_NEXT_SOCKET_MODE=automation, scratch cmux.json), posts one agent notice through the
bundled CLI (`cmux notify`), and checks:

- the app decided to post the banner (`debug.notifications` banners holds the title), so the
  banner path ran;
- `debug.notifications` authorization is "automation" (the app never asked for authorization);
- macOS registered neither the app's bundle id nor its CEF Alerts helper with the notification
  service (usernoted's app table; a registration is what shows the first-run
  "Notifications may include alerts, sounds, and icon badges" banner);
- the bundle has no Dock tile plug-in (NSDockTilePlugIn, Contents/PlugIns).

Use a tag that never ran on this host: usernoted keeps an app's row after the app is gone.
The registration check adds evidence; the authorization check is the one that fails on a launch
that asks. The script's python must be able to read usernoted's database (exits "inconclusive"
when it cannot). GUI host only. Quits the app and stops the tag's daemons at the end; writes report.json.
"""
import argparse, glob, json, os, plistlib, sqlite3, subprocess, sys, tempfile, time, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", default=os.environ.get("NX_APP"), help="tagged .app (default: $NX_APP or DerivedData)")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="automation-notifications-"))
parser.add_argument("--settle", type=float, default=10.0, help="seconds to watch for a registration after the banner")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
BUNDLE_ID = INFO["CFBundleIdentifier"]
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
USERNOTED_DB = os.path.expanduser("~/Library/Group Containers/group.com.apple.usernoted/db2/db")
SCRATCH = tempfile.mkdtemp(prefix=f"automation-notifications-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
report = {"app": APP, "tag": opts.tag, "bundle_id": BUNDLE_ID}
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)
    return ok


def registered():
    """usernoted app rows for this bundle id and its helpers (read-only); None when unreadable."""
    try:
        db = sqlite3.connect(f"file:{USERNOTED_DB}?mode=ro", uri=True)
        try:
            rows = db.execute("select identifier from app where identifier = ? or identifier like ?",
                              (BUNDLE_ID, BUNDLE_ID + ".%")).fetchall()
        finally:
            db.close()
    except sqlite3.Error as error:
        print(f"usernoted db: {error}", flush=True)
        return None
    return sorted(row[0] for row in rows)


def daemon_socket():
    roots = {os.environ.get("TMPDIR", "/tmp"), "/tmp"}
    darwin_tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    if darwin_tmp:
        roots.add(darwin_tmp)
    for root in roots:
        found = glob.glob(os.path.join(root, "cmux-tui-*", f"cmux-app-{opts.tag}.sock"))
        if found:
            return found[0]
    return None


def cli(*args, timeout=30, daemon=False):
    sock = daemon_socket() if daemon else None
    target = ["--socket", sock] if sock else ["--app-socket", SOCKET]
    try:
        return subprocess.run([CLI, *target, *args], capture_output=True, text=True, timeout=timeout, env=CLI_ENV)
    except subprocess.TimeoutExpired as error:
        return subprocess.CompletedProcess(error.cmd, 124, "", "timeout")


def rpc(method, params=None):
    r = cli("--json", "app", "call", method, json.dumps(params or {}))
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def wait_for(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded harness wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.5)
    return None


report["dock_tile_plugin"] = INFO.get("NSDockTilePlugIn")
plugins = os.path.join(APP, "Contents/PlugIns")
report["plugins"] = sorted(os.listdir(plugins)) if os.path.isdir(plugins) else []
check(report["dock_tile_plugin"] is None and not any(p.lower().startswith("cmuxdocktile") for p in report["plugins"]),
      f"no Dock tile plug-in in the bundle (NSDockTilePlugIn {report['dock_tile_plugin']}, PlugIns {report['plugins']})")
report["registered_before"] = registered()
if report["registered_before"] is None:
    sys.exit("inconclusive: usernoted's database is not readable here")
if report["registered_before"]:
    sys.exit(f"inconclusive: usernoted already knows {report['registered_before']}; use a new tag")

with open(CONFIG, "w") as f:
    f.write("{}\n")
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
teardown = TagTeardown(APP)
teardown.install()
app = None
try:
    with open(os.path.join(opts.out, "app.log"), "w") as app_log:
        app = subprocess.Popen([BINARY], env={**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
                                              "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG},
                               stdout=app_log, stderr=subprocess.STDOUT)
    print(f"app pid {app.pid}, bundle {BUNDLE_ID}, out {opts.out}", flush=True)
    up = wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 120)
    if check(bool(up), "the app socket answers"):
        wait_for(daemon_socket, 60)
        title = f"automation quiet {uuid.uuid4().hex[:10]}"

        def banner():
            return [b for b in (rpc("debug.notifications").get("banners") or [])
                    if isinstance(b, dict) and (b.get("subtitle") or "").split(" · ")[0] == title]

        # The app may not follow the daemon's notifications yet right after launch: post again
        # (same title) until a banner arrives, at most 4 times.
        report["notify"] = []
        for _ in range(4):
            posted = cli("notify", "--title", title, "--body", "cx-zkxzp automation launch proof", daemon=True)
            report["notify"].append({"exit": posted.returncode, "err": posted.stderr[-400:]})
            if posted.returncode == 0 and wait_for(banner, 15):
                break
        last = report["notify"][-1]
        if check(last["exit"] == 0, f"cmux notify posted (exit {last['exit']} {last['err'].strip()[:200]})"):
            check(bool(banner()), "the app decided to post the banner (debug.notifications banners)")
            # A registration follows the authorization request within about a second; watch a bounded window.
            late = wait_for(registered, opts.settle)
            state = rpc("debug.notifications")
            report["authorization"] = state.get("authorization")
            report["log_tail"] = (state.get("log") or [])[-6:]
            check(report["authorization"] == "automation",
                  f"the app never asked for authorization (authorization {report['authorization']!r})")
            report["registered_after"] = late or registered()
            check(report["registered_after"] == [],
                  f"usernoted registered nothing for {BUNDLE_ID} or its helpers ({report['registered_after']})")
finally:
    rpc("action.run", {"action": "quitEndSessions"})
    if app is not None:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            app.kill()
    teardown.end()
    report["registered_final"] = registered()
    with open(os.path.join(opts.out, "report.json"), "w") as f:
        json.dump(report, f, indent=1, default=str)

print(f"{len(failures)} failure(s); report {os.path.join(opts.out, 'report.json')}: "
      f"registered_final {report.get('registered_final')}")
sys.exit(1 if failures else 0)
