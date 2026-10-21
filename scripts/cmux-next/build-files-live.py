#!/usr/bin/env python3
"""Per-build isolation S5 (cx-is1kf.6), live on a GUI host: a build's small
App Support files (the sidebar snapshot, and agent drafts, diff recents beside
it) stay in its own folder, never in another build's tag folder.

App B is a copy of the tagged DEV app A (bundle com.cmuxterm.app.debug.<tag>)
whose bundle ships another tag (LSEnvironment CMUX_TAG=<tag>b). Its bundle id
names A's tag, but it is another build: its daemon and sockets are of its build
key (S3), so its files belong in cmux/builds/<key>/, not in A's cmux/tags/<tag>/.
A is never started. B runs once and quits (the quit writes the sidebar snapshot).

Checks: B's sidebar-snapshot-v1.json is in builds/<key>/ and A's tags/<tag>/
folder has none. Everything B makes (its daemon, state, Chief and acpmux roots
under a temp folder) is stopped and removed at the end; the test never resolves
a real build's names.

Exit 0 on PASS, 1 on FAIL, 2 when B wrote no snapshot anywhere (inconclusive).
Left on the host: B shares A's bundle id, so its preferences and caches are A's
(the tag's own, never a real build's).
Usage: build-files-live.py --tag TAG --app APP [--out DIR]
"""
import argparse, json, os, re, shutil, socket, subprocess, sys, tempfile, time

ap = argparse.ArgumentParser()
ap.add_argument("--tag", required=True)
ap.add_argument("--app", required=True)
ap.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
opts = ap.parse_args()
os.makedirs(opts.out, exist_ok=True)

TAG = opts.tag
if not re.fullmatch(r"[a-z0-9]+", TAG):
    # The bundle id suffix, the tag folder and the key take the tag as is only then.
    sys.exit(f"refusing to run: tag {TAG!r} is not [a-z0-9]+")
TAG_B = f"{TAG}b"
SUPPORT = os.path.expanduser("~/Library/Application Support/cmux")
SNAPSHOT = "sidebar-snapshot-v1.json"


def say(*parts):
    print(*parts, flush=True)


def fnv(text):
    h = 0x811C9DC5
    for byte in text.encode():
        h = ((h ^ byte) * 0x01000193) & 0xFFFFFFFF
    return f"{h:08x}"


def plist(path, command):
    return subprocess.run(["/usr/libexec/PlistBuddy", "-c", command, path], capture_output=True, text=True)


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def rpc(path, method, params=None, timeout=30):
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
    except (OSError, ValueError) as error:
        return {"error": str(error)}


info = os.path.join(opts.app, "Contents/Info.plist")
BUNDLE = plist(info, "Print :CFBundleIdentifier").stdout.strip()
if BUNDLE != f"com.cmuxterm.app.debug.{TAG}":
    sys.exit(f"refusing to run: A's bundle id is {BUNDLE!r}, want com.cmuxterm.app.debug.{TAG}")
# B's build key (BuildIdentity: the bundle id is its own component, plus the
# shipped tag that differs from the id's), its hash and names (S3).
KEY = f"{BUNDLE}--{TAG_B}"
KEY_HASH = fnv(KEY)
B_SESSION = f"cmux-app--{KEY_HASH}"
B_SOCKET = f"/tmp/cmux-debug--{KEY_HASH}.sock"
B_BUILD = os.path.join(SUPPORT, "builds", KEY)
A_TAG_DIR = os.path.join(SUPPORT, "tags", TAG)
for path in (B_BUILD, A_TAG_DIR):
    if os.path.exists(path):
        sys.exit(f"refusing to run: {path} exists before the run (another run of this tag?)")

SCRATCH = tempfile.mkdtemp(prefix="bfl-", dir="/tmp")
dst = os.path.join(SCRATCH, "B.app")
subprocess.run(["ditto", opts.app, dst], check=True)
b_info = os.path.join(dst, "Contents/Info.plist")
for key in ("CMUX_BUNDLE_ID", "CMUX_SOCKET_PATH"):
    plist(b_info, f"Delete :LSEnvironment:{key}")
if plist(b_info, f"Set :LSEnvironment:CMUX_TAG {TAG_B}").returncode != 0:
    plist(b_info, f"Add :LSEnvironment:CMUX_TAG string {TAG_B}")
signed = subprocess.run(["codesign", "--force", "--deep", "--sign", "-", dst], capture_output=True, text=True)
say("B signed:", signed.returncode, signed.stderr.strip()[-200:])
cli = os.path.join(dst, "Contents/Resources/bin/cmux")
acpmux = os.path.join(dst, "Contents/Resources/bin/acpmux")
clean_env = {k: v for k, v in os.environ.items() if not k.startswith(("ACPMUX_", "CMUX_", "XDG_RUNTIME"))}

failed = 0
proc = None
try:
    keep = ("HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG")
    env = {k: v for k, v in os.environ.items() if k in keep}
    config = os.path.join(SCRATCH, "cmux.json")
    open(config, "w").write("{}")
    env.update({"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
                "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": config,
                # Chief and acpmux roots of the run, never the host's.
                "CMUX_NEXT_CHIEF_ROOT": os.path.join(SCRATCH, "chief"),
                "CMUX_NEXT_ACPMUX_ROOT": os.path.join(SCRATCH, "acpmux")})
    log = open(os.path.join(opts.out, f"app-{TAG_B}.log"), "a")
    proc = subprocess.Popen([os.path.join(dst, "Contents/MacOS/cmux DEV")], env=env, stdout=log, stderr=log,
                            stdin=subprocess.DEVNULL)
    up = wait(lambda: (rpc(B_SOCKET, "debug.windows") or {}).get("windows"), 300)
    say(f"B ({TAG_B}) pid {proc.pid}: {'up' if up else 'NOT UP'} on {B_SOCKET}")
    if not up:
        failed = 1
        raise SystemExit
    # A sidebar change after launch records a snapshot (records during launch
    # are skipped); quit flushes it.
    made = rpc(B_SOCKET, "action.run", {"action": "workspace.newAtBottom", "args": {}, "focus": False, "origin": "script"})
    say("B new workspace:", json.dumps(made)[:200])
    wait(lambda: False, 2)
    rpc(B_SOCKET, "action.run", {"id": "quitEndSessions"}, timeout=10)
    try:
        proc.wait(timeout=60)
    except subprocess.TimeoutExpired:
        say(f"B pid {proc.pid} did not quit within 60 s")
    in_build = os.path.isfile(os.path.join(B_BUILD, SNAPSHOT))
    in_a = os.path.isfile(os.path.join(A_TAG_DIR, SNAPSHOT))
    listing = lambda d: sorted(os.listdir(d)) if os.path.isdir(d) else None
    say(f"B's {SNAPSHOT} in builds/{KEY}: {in_build} ({listing(B_BUILD)}); in A's tags/{TAG}: {in_a} ({listing(A_TAG_DIR)})")
    if in_a:
        failed = 1
    elif not in_build:
        failed = 2
except SystemExit:
    pass
finally:
    if proc and proc.poll() is None:
        rpc(B_SOCKET, "action.run", {"id": "quitEndSessions"}, timeout=10)
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            say(f"B pid {proc.pid} still runs after quit")
    subprocess.run([acpmux, "daemon", "shutdown", "--end-agents"], env={**clean_env, "ACPMUX_HOME": os.path.join(SCRATCH, "acpmux", "builds", KEY)},
                   capture_output=True, timeout=30)
    subprocess.run([cli, "daemon", "stop", "--session", B_SESSION, "--end-terminals"], env=clean_env,
                   capture_output=True, timeout=60)
    # Only what this run made: both folders were absent before it.
    for path in (B_SOCKET, os.path.expanduser(f"~/.local/state/cmux/{os.path.basename(B_SOCKET)}")):
        if os.path.islink(path) or (os.path.exists(path) and not os.path.isdir(path)):
            os.unlink(path)
    shutil.rmtree(B_BUILD, ignore_errors=True)
    shutil.rmtree(A_TAG_DIR, ignore_errors=True)
    shutil.rmtree(SCRATCH, ignore_errors=True)
    say("result", "PASS" if failed == 0 else f"FAIL {failed}")
sys.exit(failed)
