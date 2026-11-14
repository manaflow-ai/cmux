#!/usr/bin/env python3
"""The session service line ("Session service isn't responding") on a fleet build: shown only for a real
outage, and gone by itself once the service answers.

Downloads the build of `--job`, starts it with a fresh tag state (its first `server ensure` starts and restores a
new owner, as after an update), then:

  launch    connected; 150 s later (past the model's 120 s no-progress bound) no part is shown, the
            session service is not listed at all (not even slow), and nothing holds a replace
  outage    `debug.health.inject {sessionDaemon, hang}` stops the owner (SIGSTOP): within 60 s a part is
            not healthy and the sidebar line shows
  recovery  `debug.health.inject {sessionDaemon, resume}`: within 60 s every part is healthy again with no
            click, and 150 s later still is (no stale restore left behind by the outage or a replace)

Reads `debug.health` (the app health snapshot plus `holds_replace`; `timer_armed` is not checked, since
visible pages' heartbeats arm the model's one timer) and saves window
snapshots (`launch.png`, `outage.png`, `recovered.png`). Writes report.json. Exit 1 on any failed step.
Every process of this job's own app copy is ended on exit (tag_teardown.py, exact PIDs).
Run under nx-remote on cmux-lawrence-2:
  nx-remote --host cmux-lawrence-2 --class light --needs gui -- python3 scripts/cmux-next/session-service-health-live.py --job <id> --tag <tag>
"""
import argparse, glob, json, os, plistlib, shutil, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--job", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--quiet-seconds", type=int, default=150, help="how long a healthy state must hold")
opts = parser.parse_args()

OUT = os.path.realpath(os.environ.get("NX_ARTIFACTS") or "/tmp/session-service-health-live")
os.makedirs(OUT, exist_ok=True)
LOG = open(os.path.join(OUT, "live.log"), "a")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(line + "\n")
    LOG.flush()


zip_path = os.path.join(OUT, "app.zip")
if not os.path.exists(zip_path):
    subprocess.run([os.path.expanduser("~/.local/bin/cmux-ci"), "artifact", opts.job, zip_path], check=True,
                   env=dict(os.environ, CMUX_CI_CONTROLLER="http://100.89.225.106:18765"))
app_dir = os.path.join(OUT, "app")
if not os.path.isdir(app_dir):
    subprocess.run(["ditto", "-x", "-k", zip_path, app_dir], check=True)
APP = next(iter(glob.glob(os.path.join(app_dir, "*.app"))), None)
if not APP:
    sys.exit("no .app in the artifact")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
TAG = opts.tag
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
say("app", APP, "bundle", INFO.get("CFBundleIdentifier"))


def rpc(method, params=None, timeout=60):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(SOCKET)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # harness wait, not app code
    return None


def health():
    value = rpc("debug.health")
    return value if isinstance(value, dict) and "error" not in value else {}


def shown(snapshot):
    """The parts the sidebar line can name: worse than slow (AppHealth.headline)."""
    return [p for p in snapshot.get("parts", []) if p.get("state") not in (None, "healthy", "slow")]


def brief(snapshot):
    return {"parts": [{k: p.get(k) for k in ("id", "state", "detail")} for p in snapshot.get("parts", [])],
            "timer_armed": snapshot.get("timer_armed"), "holds_replace": snapshot.get("holds_replace")}


def daemon_listed(snapshot):
    return [p for p in snapshot.get("parts", []) if p.get("id") == "sessionDaemon"]


def snapshot(name):
    path = os.path.join(OUT, f"{name}.png")
    rpc("debug.window_snapshot", {"kind": "main", "path": path}, timeout=60)
    return path if os.path.exists(path) else None


def quiet(seconds):
    """Every part stays healthy (or only slow) for `seconds`; the first snapshot that is not, else None."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        snap = health()
        if shown(snap):
            return snap
        time.sleep(2)  # harness wait, not app code
    return None


steps = []


def step(name, ok, **detail):
    steps.append({"step": name, "ok": bool(ok), **detail})
    say("PASS" if ok else "FAIL", name, json.dumps(detail)[:800])


TagTeardown(APP).install()
teardown = TagTeardown(APP, log=say)
app = None
try:
    for tag_state in (os.path.expanduser(f"~/Library/Application Support/cmux-next/tags/{TAG}"),
                      os.path.expanduser(f"~/Library/Application Support/cmux/tags/{TAG}")):
        if os.path.isdir(tag_state) and not os.path.islink(tag_state):
            os.rename(tag_state, f"{tag_state}.old-{int(time.time())}")
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = dict(os.environ)
    env.update({"CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_NO_ACTIVATE": "1",
                "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,820"})
    app_log = open(os.path.join(OUT, "app.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=app_log, stderr=app_log, stdin=subprocess.DEVNULL)
    say("started app pid", app.pid)
    if not wait(lambda: os.path.exists(SOCKET) and health().get("model_linked") is not None, 180):
        raise SystemExit("the app did not come up")
    linked = health().get("model_linked")
    step("model linked", linked, model_linked=linked)

    # launch: the first connection, then the quiet period past the 120 s bound.
    connected = wait(lambda: not any(p.get("id") == "acpmux" and p.get("state") != "healthy"
                                     for p in health().get("parts", [])) and rpc("debug.surfaces").get("windows"), 180)
    started = time.time()
    noisy = quiet(opts.quiet_seconds)
    snap = health()
    step("launch: no line for a serving owner", connected and noisy is None and not daemon_listed(snap)
         and not snap.get("holds_replace"), waited_s=round(time.time() - started), seen=brief(noisy or snap))
    snapshot("launch")

    # outage: the owner stops answering.
    hung = rpc("debug.health.inject", {"id": "sessionDaemon", "fault": "hang"})
    bad = wait(lambda: shown(health()) and health(), 60, 1)
    step("outage: the line shows", hung.get("ok") and bad, inject=hung, seen=brief(bad or health()))
    snapshot("outage")

    # recovery: the owner answers again; the line leaves with no click and stays away.
    resumed = rpc("debug.health.inject", {"id": "sessionDaemon", "fault": "resume"})
    t0 = time.time()
    clear = wait(lambda: not shown(health()) and health(), 90, 1)
    step("recovery: the line leaves by itself", clear, resume=resumed, after_s=round(time.time() - t0),
         seen=brief(clear or health()))
    noisy = quiet(opts.quiet_seconds)
    snap = health()
    step("recovery: nothing stale comes back", noisy is None and not daemon_listed(snap) and not snap.get("holds_replace"),
         seen=brief(noisy or snap))
    snapshot("recovered")
finally:
    if app and app.poll() is None:
        app.terminate()
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            app.kill()
    teardown.end()
    with open(os.path.join(OUT, "report.json"), "w") as f:
        json.dump({"job": opts.job, "tag": TAG, "steps": steps}, f, indent=1)
failed = [s["step"] for s in steps if not s["ok"]]
say("FAILED" if failed else "EVERY STEP PASSED", failed)
shutil.rmtree(app_dir, ignore_errors=True)
sys.exit(1 if failed or not steps else 0)
