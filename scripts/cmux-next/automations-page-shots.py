#!/usr/bin/env python3
"""Light and dark shots of the Automations page in a running tagged cmux-next app.

  scripts/cmux-next/automations-page-shots.py --app "<path>/cmux DEV <tag>.app" --tag <tag> --out <dir>

Seeds an isolated automation store (CMUX_AUTOMATIONS_DIR in a scratch folder: a failed nightly
command, a 30-minute prompt, a paused one) through the app's own `cmux automation`, launches the
app with the no-activate automation environment, opens the page with the `automations.show`
action (what Cmd+Shift+P "Automations" and the sidebar item run), checks the page is the window's
top page, and writes automations-light.png and automations-dark.png (`debug.window_snapshot`)
after setting `appearance.appTheme` to a light, then a dark Ghostty theme. Socket only.
"""
import argparse, json, os, subprocess, sys, tempfile, time

p = argparse.ArgumentParser()
p.add_argument("--app", required=True)
p.add_argument("--tag", required=True)
p.add_argument("--out", required=True)
o = p.parse_args()
BINARY = os.path.join(o.app, "Contents/MacOS", os.path.basename(o.app)[:-4])
CLI = os.path.join(o.app, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{o.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"automations-shots-{o.tag}-")
STORE = os.path.join(SCRATCH, "automations")
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
BASE = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_AUTOMATIONS_DIR": STORE}
os.makedirs(o.out, exist_ok=True)
failures = []


def check(label, ok, detail=""):
    print(f"{'ok  ' if ok else 'FAIL'} {label} {detail}", flush=True)
    if not ok:
        failures.append(label)


def cli(*args):
    return subprocess.run([CLI, *args], capture_output=True, text=True, timeout=60, env=BASE)


def rpc(method, params=None):
    r = subprocess.run([CLI, "--socket", SOCKET, "rpc", method, json.dumps(params or {})], capture_output=True, text=True,
                       timeout=30, env={**BASE, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"})
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:  # harness wait on the app's socket, not app code
        v = predicate()
        if v:
            return v
        time.sleep(step)
    return None


# A store that shows each section: Needs you (failed), Today, Paused.
made = cli("automation", "create", "Nightly deps PR", "--command", "exit 1", "--daily", "02:00")
check("seed: create a command automation", made.returncode == 0, made.stderr.strip())
check("seed: its run fails", cli("automation", "run", "Nightly deps PR", "--wait", "--key", "seed").returncode == 1)
check("seed: an every-30-minutes prompt", cli("automation", "create", "Unblock agents", "--prompt", "Check my stuck agents and unblock them.",
                                              "--every", "30m").returncode == 0)
check("seed: a paused hourly cleanup", cli("automation", "create", "Clean DerivedData", "--command", "true", "--hourly", "--paused").returncode == 0)

if os.path.exists(SOCKET):
    os.unlink(SOCKET)
env = {**BASE, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
       "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1280,800"}
log = open(os.path.join(SCRATCH, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
print(f"launched pid {app.pid} (log {SCRATCH}/app.log)", flush=True)
try:
    if not wait(lambda: os.path.exists(SOCKET) and rpc("debug.surfaces").get("windows"), 120):
        sys.exit("tagged app did not come up")
    time.sleep(2)  # first frame and restore settle before the action (harness, not app code)
    ran = rpc("action.run", {"id": "automations.show"})
    check("automations.show runs", "error" not in ran or not ran.get("error"), json.dumps(ran)[:200])
    shown = wait(lambda: "automations" in json.dumps(rpc("debug.focus")), 15)
    check("the Automations page is the window's top page", bool(shown))
    for name, theme in [("light", "GitHub Light Default"), ("dark", "GitHub Dark Default")]:
        set_theme = rpc("settings.set", {"path": "appearance.appTheme", "value": theme})
        check(f"{name}: app theme {theme}", "error" not in set_theme or not set_theme.get("error"), json.dumps(set_theme)[:200])
        rpc("action.run", {"id": "automations.show"})
        time.sleep(2)  # the page reloads its sources and redraws in the new theme (harness, not app code)
        shot = rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(o.out, f"automations-{name}.png")})
        check(f"{name}: snapshot", "path" in shot, json.dumps(shot)[:200])
finally:
    app.terminate()
    try:
        app.wait(15)
    except subprocess.TimeoutExpired:
        app.kill()
print("FAILED: " + ", ".join(failures) if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
