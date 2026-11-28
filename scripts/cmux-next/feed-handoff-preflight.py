#!/usr/bin/env python3
"""Live proof of the feed 9.1 handoff (plans/cmux-next/feed.md 9.1): a local
notification leaves the Mac for FeedDO.

  scripts/cmux-next/feed-handoff-preflight.py --tag <tag> (--app PATH | --job ID) [--out DIR]

Launches the tagged app (no activation, automation socket, scratch cmux.json),
waits until it is signed in (the tagged build signs in the host's dogfood
account by itself, CloudAuth/DogfoodCredentials; set CMUX_AUTH_CREDENTIALS_FILE
for a host without those files), then posts one agent notice
through the bundled CLI (`cmux notify`; agent notices are mirrored by default,
terminal ones are not). The handoff driver must log `moved <item>`
(`debug.notifications` feed_log: the daemon froze the item as handing_off,
FeedDO adopted it, the daemon marked it moved), and the owner's feed stream must
then hold an item with that title (`debug.feed {match}`), so the item is on
FeedDO (staging for a development build). GUI host only. Writes report.json and
app.log to DIR. Quits the app by PID and stops the tag's daemons at the end.
"""
import argparse, glob, json, os, plistlib, subprocess, sys, tempfile, time, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--job", help="cmux-ci build job id: download and use its artifact")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="feed-handoff-preflight-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = opts.app
if opts.job and not APP:
    zip_path = os.path.join(opts.out, "app.zip")
    if not os.path.exists(zip_path):
        subprocess.run([os.path.expanduser("~/.local/bin/cmux-ci"), "artifact", opts.job, zip_path], check=True,
                       env=dict(os.environ, CMUX_CI_CONTROLLER="http://100.89.225.106:18765"))
    app_dir = os.path.join(opts.out, "app")
    if not os.path.isdir(app_dir):
        subprocess.run(["ditto", "-x", "-k", zip_path, app_dir], check=True)
    APP = next(iter(glob.glob(os.path.join(app_dir, "*.app"))), None)
APP = APP or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"feed-handoff-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
# A host without the dogfood files signs in from an explicit 0600 credentials
# file (the agent profile); the path passes through, never the values.
AUTH_ENV = {key: os.environ[key] for key in ("CMUX_AUTH_CREDENTIALS_FILE", "CMUX_DEV_AUTH_PROFILE") if os.environ.get(key)}
report = {"app": APP, "tag": opts.tag, "auth_env": sorted(AUTH_ENV)}
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)
    return ok


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


def feed_log():
    return (rpc("debug.notifications") or {}).get("feed_log") or []


with open(CONFIG, "w") as f:
    f.write("{}\n")
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
teardown = TagTeardown(APP)
teardown.install()
app = subprocess.Popen([BINARY], env={**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
                                      "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, **AUTH_ENV},
                       stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT)
print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)
try:
    up = wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 120)
    if check(bool(up), "the app socket answers"):
        signed = wait_for(lambda: (rpc("debug.feed") or {}).get("signed_in") is True and rpc("debug.feed"), 120)
        report["feed_before"] = signed or rpc("debug.feed")
        report["auth"] = rpc("auth.status")
        if check(bool(signed), f"signed in (debug.feed api {report['feed_before'].get('api') if isinstance(report['feed_before'], dict) else '?'})"):
            title = f"feed handoff preflight {uuid.uuid4().hex[:10]}"
            report["title"] = title
            posted = cli("notify", "--title", title, "--body", "the feed 9.1 handoff preflight", daemon=True)
            report["daemon_socket"] = daemon_socket()
            report["notify"] = {"exit": posted.returncode, "out": posted.stdout[-800:], "err": posted.stderr[-800:]}
            if check(posted.returncode == 0, f"cmux notify posted (exit {posted.returncode} {posted.stderr.strip()[:200]})"):
                moved = wait_for(lambda: [line for line in feed_log() if line.startswith("moved ")], 120)
                report["feed_log"] = feed_log()
                print("feed_log:", json.dumps(report["feed_log"])[:1500], flush=True)
                if check(bool(moved), "the driver handed the item off: handing_off then moved"):
                    report["moved"] = moved
                    found = wait_for(lambda: (rpc("debug.feed", {"match": title}) or {}).get("matches"), 60)
                    report["feed_after"] = rpc("debug.feed", {"match": title})
                    check(bool(found), f"the item is on FeedDO: {json.dumps(found)[:600]}")
finally:
    rpc("action.run", {"action": "quitEndSessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()
    teardown.end()
    with open(os.path.join(opts.out, "report.json"), "w") as f:
        json.dump(report, f, indent=1, default=str)

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
