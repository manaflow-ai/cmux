#!/usr/bin/env python3
"""Instant new tab on a running no-activate tagged build (plans/cmux-next/new-tab.md 2.3).

Opens the new tab page and types in the same main-actor turn (`debug.new_tab`
open_and_type), then checks the field holds every key and has focus, closes the
tab, waits for the next spare, and repeats. Budget: a spare adoption under 16 ms
of main-thread time at p95, no lost key. Prints the cold opening and each spare's
WebContent footprint. Run on cmux-lawrence-2 or the fleet, never the laptop.

Launches the tagged app itself (no-activate, automation socket, scratch cmux.json
and an empty Ghostty config) and kills it at the end.

Usage: new-tab-e2e.py --tag <tag> [--runs 20] [--budget-ms 16]
"""
import argparse, glob, json, os, signal, statistics, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--runs", type=int, default=20)
parser.add_argument("--budget-ms", type=float, default=16)
parser.add_argument("--text", default="hello")
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
APP = next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SCRATCH = tempfile.mkdtemp(prefix=f"newtab-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
open(GHOSTTY, "w").write("")
open(CONFIG, "w").write("{}")
ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}


def rpc(method, params=None):
    out = subprocess.run([CLI, "--socket", SOCKET, "rpc", method, json.dumps(params or {})],
                         capture_output=True, text=True, timeout=30, env=ENV).stdout
    return json.loads(out) if out.strip() else None


def wait(label, predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)  # test harness wait, not app code
    sys.exit(f"FAIL {label} (timed out after {timeout:.0f} s)\n{json.dumps(rpc('debug.new_tab', {'action': 'state'}), indent=1)}")


def state():
    return rpc("debug.new_tab", {"action": "state"}) or {}


def open_and_check(expect_spare, snapshot=None):
    opening = (rpc("debug.new_tab", {"action": "open_and_type", "text": opts.text}) or {}).get("opening") or {}
    if opening.get("spare") != expect_spare:
        sys.exit(f"FAIL expected spare={expect_spare}, got {opening}")
    field = wait("the field holds every key", lambda: (f := rpc("debug.new_tab", {"action": "field"}) or {})
                 and f.get("text") == opts.text and f, 5)
    if not field.get("focused"):
        sys.exit(f"FAIL the field does not have focus: {field}")
    if snapshot:
        print(f"snapshot: {rpc('debug.window_snapshot', {'path': snapshot})}")
    rpc("debug.key", {"key": "w", "modifiers": ["command"]})
    return opening["ms"]


app = None
try:
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720"}
    app = subprocess.Popen([BINARY], env=env, stdout=open(os.path.join(SCRATCH, "app.log"), "a"),
                           stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    print(f"launched pid {app.pid}", flush=True)
    wait("the tagged app comes up", lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 90)
    time.sleep(2)  # test harness: let the first workspace settle
    cold = open_and_check(False)
    print(f"cold opening: {cold:.2f} ms main thread")
    spare_ms, footprints = [], []
    for run in range(opts.runs):
        spares = wait("a spare is parked", lambda: state().get("spares"), 20)
        footprints += [s["footprint_mb"] for s in spares if s.get("footprint_mb") is not None]
        shot = os.path.join(os.environ.get("NX_ARTIFACTS", SCRATCH), "new-tab-spare.png") if run == 0 else None
    spare_ms.append(open_and_check(True, shot))
    p95 = sorted(spare_ms)[max(0, int(round(0.95 * len(spare_ms))) - 1)]
    print(f"spare openings: n={len(spare_ms)} p50={statistics.median(spare_ms):.2f} ms p95={p95:.2f} ms max={max(spare_ms):.2f} ms")
    if footprints:
        print(f"spare WebContent footprint: median={statistics.median(footprints):.1f} MB max={max(footprints):.1f} MB")
    if p95 > opts.budget_ms:
        sys.exit(f"FAIL p95 {p95:.2f} ms is over the {opts.budget_ms} ms budget")
    print("ok: no lost key in any run; p95 within budget")
finally:
    if app and app.poll() is None:
        app.send_signal(signal.SIGKILL)
        print(f"killed {app.pid}", flush=True)
