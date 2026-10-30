#!/usr/bin/env python3
"""Live proof that an app started by another cmux drops that cmux's state roots
(per-build isolation S4, cx-is1kf.5; cmux-lawrence-2 only, an --app-from-fleet
GUI job). LaunchIdentity.stripInheritedEnvironment.

The app starts as from a terminal of another cmux: that terminal's
CMUX_BUNDLE_ID, CMUX_TAG, CMUX_SOCKET_PATH and MUX_AGENT_TOKEN_FILE (the
markers), and the other build's state-root knobs CMUX_NEXT_SOCKET_PATH,
CMUX_NEXT_CHIEF_HOME, CMUX_NEXT_ACPMUX_ROOT, plus MUX_HOST_LOG and
OPTCHAT_HOME. All of them point into a temp folder. Expected:
  1. the app listens on its own control socket (/tmp/cmux-debug-<tag>.sock),
     never on the inherited CMUX_NEXT_SOCKET_PATH;
  2. after Home opens, nothing of this app is in the inherited Chief home or
     acpmux root (no host.lock, no acpmux socket);
  3. a launch by a harness (no markers) still honors CMUX_NEXT_SOCKET_PATH:
     the knobs are dropped only when another cmux started the app.

The app's own Chief is an isolated one (CMUX_NEXT_NO_ACTIVATE=1:
~/.cmux/chief/isolated/<tag>), stopped and removed at the end with the app.
Exit 0 when every step passed; the first failed step's number otherwise.
Usage: launch-env-fence-live.py --tag TAG --app APP [--out DIR]
"""
import argparse, json, os, shutil, socket, subprocess, sys, tempfile, time

ap = argparse.ArgumentParser()
ap.add_argument("--tag", required=True)
ap.add_argument("--app", required=True)
ap.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
opts = ap.parse_args()

TAG = opts.tag
SCRATCH = tempfile.mkdtemp(prefix="lef-", dir="/tmp")
OTHER = os.path.join(SCRATCH, "other")
OTHER_SOCKET = os.path.join(OTHER, "next.sock")
OTHER_CHIEF = os.path.join(OTHER, "chief")
OTHER_ACPMUX = os.path.join(OTHER, "acpmux")
HARNESS_SOCKET = os.path.join(SCRATCH, "harness.sock")
OWN_SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
ISOLATED_CHIEF = os.path.expanduser(f"~/.cmux/chief/isolated/{TAG}")
EXECUTABLE = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleExecutable",
                             os.path.join(opts.app, "Contents/Info.plist")], capture_output=True, text=True).stdout.strip()
BINARY = os.path.join(opts.app, "Contents/MacOS", EXECUTABLE or "cmux DEV")
CLI = os.path.join(opts.app, "Contents/Resources/bin/cmux")
os.makedirs(OTHER, exist_ok=True)
os.makedirs(opts.out, exist_ok=True)
REAL = ("/tmp/cmux-nightly", "/tmp/cmux.sock", "/tmp/cmux-debug.sock", "/tmp/cmux-rc.sock", "/tmp/cmux-staging.sock")
if TAG in ("nightly", "rc", "staging", "cmux-next") or OWN_SOCKET.startswith(REAL):
    sys.exit(f"refusing to run: {TAG} is a real build's tag")


def say(*parts):
    print(*parts, flush=True)


def rpc(path, method, params=None, timeout=10):
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
        return reply.get("result") if reply.get("ok") else None
    except (OSError, ValueError):
        return None


def answers(path):
    return os.path.exists(path) and isinstance(rpc(path, "debug.windows"), dict)


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def launch(extra, name):
    keep = ("HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR")
    env = {k: v for k, v in os.environ.items() if k in keep}
    env.update({"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
                "CMUX_NEXT_SOCKET_MODE": "automation"})
    env.update(extra)
    log = open(os.path.join(opts.out, f"app-{name}.log"), "a")
    return subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)


def quit_app(proc, path):
    """Quits the app this run started (`proc`), through `path` when that is its
    socket; a process that does not quit gets SIGTERM, then SIGKILL (its pid only)."""
    if proc.poll() is None and path and answers(path):
        rpc(path, "action.run", {"id": "quitEndSessions"})
    try:
        proc.wait(timeout=60)
    except subprocess.TimeoutExpired:
        say(f"app pid {proc.pid} did not quit within 60 s; ending it")
        proc.terminate()
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=20)


CLEAN_ENV = {k: v for k, v in os.environ.items() if not k.startswith(("ACPMUX_", "CMUX_", "MUX_", "OPTCHAT_"))}


def stop_chief(home):
    subprocess.run([CLI, "chief", "shutdown", "--chief-home", home], env=CLEAN_ENV, capture_output=True, timeout=90)


def stop_isolated_chief():
    stop_chief(ISOLATED_CHIEF)


def stop_inherited_roots():
    """What a build that kept the inherited roots started there (the red run):
    the Chief of the inherited home and every acpmux daemon under the inherited root."""
    if os.path.isdir(OTHER_CHIEF):
        stop_chief(OTHER_CHIEF)
    acpmux = os.path.join(opts.app, "Contents/Resources/bin/acpmux")
    homes = {OTHER_ACPMUX, os.path.join(OTHER_CHIEF, "acpmux")}
    for folder, _, files in os.walk(OTHER):
        if any(f.endswith(".sock") for f in files):
            homes.add(folder)
    for home in sorted(homes):
        if os.path.isdir(home):
            subprocess.run([acpmux, "daemon", "shutdown", "--end-agents"], env={**CLEAN_ENV, "ACPMUX_HOME": home},
                           capture_output=True, timeout=30)


def found_under(root):
    """Files the app made in an inherited root (locks and sockets), else []."""
    hits = []
    for folder, _, files in os.walk(root):
        hits += [os.path.join(folder, f) for f in files if f.endswith((".lock", ".sock"))]
    return sorted(hits)


failed = 0
proc = None
isolated_existed = os.path.exists(ISOLATED_CHIEF)
# Only an app this run starts may answer these names: else a pass could be another
# app's, and the quit at the end would stop it.
for name in (OWN_SOCKET, HARNESS_SOCKET):
    if answers(name):
        sys.exit(f"refusing to run: an app already answers {name}; pick a fresh tag")
if isolated_existed:
    sys.exit(f"refusing to run: {ISOLATED_CHIEF} exists (another run of tag {TAG}); pick a fresh tag")
try:
    # 1 and 2: started from another cmux's terminal
    open(os.path.join(OTHER, "token"), "w").write("not a token\n")
    proc = launch({
        "CMUX_BUNDLE_ID": "com.cmuxterm.app.debug.s4other", "CMUX_TAG": "s4other",
        "CMUX_SOCKET_PATH": os.path.join(OTHER, "app.sock"), "MUX_AGENT_TOKEN_FILE": os.path.join(OTHER, "token"),
        "CMUX_NEXT_SOCKET_PATH": OTHER_SOCKET, "CMUX_NEXT_CHIEF_HOME": OTHER_CHIEF,
        "CMUX_NEXT_ACPMUX_ROOT": OTHER_ACPMUX, "MUX_HOST_LOG": os.path.join(OTHER, "host.log"),
        "OPTCHAT_HOME": os.path.join(OTHER, "optchat"),
    }, "from-other-cmux")
    own = wait(lambda: answers(OWN_SOCKET), 300)
    other = answers(OTHER_SOCKET)
    say(f"step 1: started by another cmux: own socket {OWN_SOCKET} answers {bool(own)}; inherited {OTHER_SOCKET} answers {other}")
    if not own or other:
        failed = failed or 1
    path = OWN_SOCKET if own else OTHER_SOCKET
    rpc(path, "action.run", {"id": "home.show"})
    brain = wait(lambda: os.path.exists(os.path.join(ISOLATED_CHIEF, "state", "host.lock")), 180)
    leaked = found_under(OTHER)
    say(f"step 2: own isolated Chief {ISOLATED_CHIEF} has a brain lock: {bool(brain)}; files in the inherited roots: {leaked}")
    if leaked or not brain:
        failed = failed or 2
    quit_app(proc, path)
    proc = None
    stop_isolated_chief()
    stop_inherited_roots()
    # 3: a harness launch keeps the knob
    proc = launch({"CMUX_NEXT_SOCKET_PATH": HARNESS_SOCKET}, "harness")
    kept = wait(lambda: answers(HARNESS_SOCKET), 300)
    say(f"step 3: harness launch: CMUX_NEXT_SOCKET_PATH {HARNESS_SOCKET} answers {bool(kept)}")
    if not kept:
        failed = failed or 3
    quit_app(proc, HARNESS_SOCKET if kept else OWN_SOCKET)
    proc = None
except SystemExit:
    pass
except Exception as error:  # a crash of this script is a failure, never a pass
    say(f"error: {error!r}")
    failed = failed or 9
finally:
    if proc and proc.poll() is None:
        quit_app(proc, next((p for p in (OWN_SOCKET, OTHER_SOCKET, HARNESS_SOCKET) if answers(p)), None))
    stop_isolated_chief()
    stop_inherited_roots()
    if not isolated_existed:
        shutil.rmtree(ISOLATED_CHIEF, ignore_errors=True)
    shutil.rmtree(SCRATCH, ignore_errors=True)
    say("result", "PASS" if failed == 0 else f"FAIL {failed}")
sys.exit(failed)
