#!/usr/bin/env python3
"""Live check: a workspace switch creates no divider catcher windows (perf100 browser lane).

  scripts/cmux-next/divider-catchers-switch-live.py --app PATH [--switches 40] [--out DIR]

While a Chromium page shows, each divider hit area is covered by a small transparent panel (a
child window, `DividerMouseCatchers`). The GUI fuzzer found 2-3.5 s main-thread stalls on
workspace switches inside that code: each switch to a workspace with a page made new panel
windows (WindowServer window creation) and each switch away ordered them out, and AppKit's child
window ordering walks the parent's whole window group per operation.

Workspace 1 has a Chromium page and two splits (dividers); workspace 2 has only a terminal. The
script switches between them --switches times (`goToWorkspace`, the same show path as Cmd-number)
and reads `debug.layers` after each switch to workspace 1. Checks:

  1. the catchers cover the dividers while the page shows (the feature still works);
  2. the DividerMousePanel windows ever seen stay at the most shown at once (no new window per
     switch). Before the fix every switch made new ones.

Prints the switch round-trip times (p50, max). Quits the app, ends the tag's daemons.
"""
import argparse, json, os, plistlib, statistics, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--switches", type=int, default=40)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="divider-catchers-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = os.path.realpath(opts.app)
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
TAG = INFO["CFBundleIdentifier"].rsplit(".", 1)[-1]
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
SCRATCH = tempfile.mkdtemp(prefix="divider-catchers-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
EMPTY_GHOSTTY = os.path.join(SCRATCH, "ghostty-config")
PAGE = os.path.join(SCRATCH, "page.html")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def rpc(method, params=None, timeout=60):
    try:
        r = subprocess.run([CLI, "--app-socket", SOCKET, "--json", "app", "call", method, json.dumps(params or {})],
                           capture_output=True, text=True, timeout=timeout, env=CLI_ENV)
    except subprocess.TimeoutExpired:
        return {"error": f"{method} timed out"}
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def action(name, args=None):
    return rpc("action.run", {"action": name, "args": args or {}, "focus": True})


def wait_for(predicate, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    return None


def windows(node):
    """Every window object of debug.layers (the dicts that carry child_windows)."""
    if isinstance(node, dict):
        if "child_windows" in node:
            yield node
        for value in node.values():
            yield from windows(value)
    elif isinstance(node, list):
        for value in node:
            yield from windows(value)


def catchers():
    """(catcher window numbers now, divider areas now, catcher rects now, reorders) over all windows."""
    layers = rpc("debug.layers")
    numbers, areas, covered, reorders = set(), 0, 0, 0
    for window in windows(layers):
        numbers |= {int(c["window_number"]) for c in window["child_windows"] if c.get("class") == "DividerMousePanel"}
        areas += len(window.get("divider_areas_in_window") or [])
        covered += len(window.get("divider_catchers_in_window") or [])
        reorders += int(window.get("reorders") or 0)
    return numbers, areas, covered, reorders


for path, text in ((CONFIG, "{}\n"), (EMPTY_GHOSTTY, ""), (PAGE, "<title>page</title><body>page")):
    with open(path, "w") as f:
        f.write(text)
teardown = TagTeardown(APP)
teardown.install()
app = None
times = []
try:
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    app = subprocess.Popen([BINARY], env={**BASE_ENV, "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
                                          "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": EMPTY_GHOSTTY},
                           stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT)
    print(f"app pid {app.pid}, out {opts.out}", flush=True)
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 120)
    def new_workspace():
        made = action("workspace.newAtBottom")
        created = [item for item in made.get("created", []) if str(item).startswith("ws_")]
        check(bool(created), f"a workspace opens ({str(made)[:200]})")
        action("workspace.selectLast")
        return created[0] if created else None

    spaces = {1: new_workspace()}
    action("splitRight")
    action("splitRight")
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": "file://" + PAGE}, "focus": True}, timeout=90)
    check(bool(opened.get("created")), f"a Chromium tab opens ({str(opened)[:200]})")
    shown = wait_for(lambda: (lambda c: c[2] > 0 and c[2] == c[1] and c)(catchers()), 30)
    time.sleep(1)  # test script: a split's animation can show a transient extra divider area
    shown = catchers() if shown else None
    check(bool(shown), f"catchers cover the dividers while the page shows ({catchers()})")
    baseline = set(shown[0]) if shown else set()
    spaces[2] = new_workspace()
    seen, reorders, misses = set(), [], 0
    for i in range(opts.switches):
        for index in (1, 2):
            before = catchers()[3]
            t0 = time.monotonic()
            reply = action("goToWorkspace", {"workspace": spaces[index]})
            times.append((time.monotonic() - t0) * 1000)
            if "error" in reply:
                check(False, f"switch {i} to {index}: {reply}")
            # The switch happened: catchers cover every divider on 1, none on 2 (no page there).
            if index == 1:
                now = wait_for(lambda: (lambda c: c[2] == c[1] and c[2] > 0 and c)(catchers()), 10)
            else:
                now = wait_for(lambda: (lambda c: c[2] == 0 and c)(catchers()), 10)
            if not now:
                misses += 1
                now = catchers()
            seen |= now[0]
            if index == 1:
                reorders.append(now[3] - before)
    check(misses == 0, f"every switch reached its workspace ({misses} of {2 * opts.switches} did not)")
    check(bool(baseline), f"catcher windows on the first show: {sorted(baseline)}")
    check(seen <= baseline, f"{len(seen)} catcher windows over {opts.switches} switches, {len(baseline)} at the first show "
                            f"(new: {sorted(seen - baseline)[:10]})")
    pool = [w.get("divider_catcher_pool") for w in windows(rpc("debug.layers")) if "divider_catcher_pool" in w]
    print(f"divider_catcher_pool: {pool}; child reorders per switch in: max {max(reorders or [0])}, total {sum(reorders)}", flush=True)
    p50 = statistics.median(times) if times else 0
    print(f"switch round trip: p50 {p50:.0f} ms, max {max(times or [0]):.0f} ms over {len(times)} switches", flush=True)
finally:
    with open(os.path.join(opts.out, "divider-catchers-switch.json"), "w") as f:
        json.dump({"switch_ms": times, "failures": failures}, f)
    if app and app.poll() is None:
        rpc("action.run", {"action": "quitEndSessions"})
        try:
            app.wait(timeout=30)
        except subprocess.TimeoutExpired:
            app.kill()  # the PID launched above, never a pattern
            app.wait()
    teardown.end()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
