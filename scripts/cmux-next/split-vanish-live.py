#!/usr/bin/env python3
"""New splits and browser splits never vanish under rapid creation (#26695), on a tagged cmux DEV.

Launches the tagged app (no activation, bounded window, isolated config), then, in a fresh
workspace per phase, fires a burst of split actions at once (`action.run` on parallel
connections, as a person pressing Cmd-D and Split Browser Right fast) and samples the panes the
window shows (`debug.tab_drag` strips) every 50 ms until they settle. A phase fails when:

- the shown pane count ever goes down (no action in the burst closes a pane);
- the workspace ever shows no pane at all;
- the settled count is not one pane plus the accepted splits;
- the workspace view's own pane counts (`debug.layout_counters` `pane_count_changes`) go down.

It takes a window snapshot mid-burst and after each phase into OUT_DIR.

Usage: split-vanish-live.py TAG APP OUT_DIR
Exit 0 = every phase clean. Writes OUT_DIR/split-vanish.json.
"""
import json, os, pwd, signal, socket, subprocess, sys, tempfile, threading, time

TAG, APP, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
SOCKET = "/tmp/cmux-debug-%s.sock" % TAG
ACCOUNT_HOME = pwd.getpwuid(os.getuid()).pw_dir
ACPMUX_HOME = os.path.join(ACCOUNT_HOME, ".cmux/chief/isolated", TAG, "acpmux")
ROUNDS = int(os.environ.get("SPLIT_VANISH_ROUNDS", "3"))
# Each phase: the actions fired at once in a fresh workspace.
PHASES = [
    ("terminal splits", ["splitRight", "splitDown", "splitRight", "splitDown"]),
    ("browser splits", ["splitBrowserRight", "splitBrowserDown", "splitBrowserRight"]),
    ("mixed", ["splitRight", "splitBrowserRight", "splitDown", "splitBrowserDown", "newColumn"]),
]
os.makedirs(OUT, exist_ok=True)


def rpc(method, params=None, timeout=30):
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(timeout)
        c.connect(SOCKET)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close()
        r = json.loads(buf)
        return r.get("result") if r.get("ok") else {"error": r.get("error")}
    except (OSError, ValueError) as e:
        return {"error": str(e)}


def shown_panes():
    """Panes the first window's selected workspace shows (its tab strips)."""
    windows = (rpc("debug.windows") or {}).get("windows") or []
    first = windows[0].get("id") if windows else None
    report = rpc("debug.tab_drag") or {}
    return len([s for s in report.get("strips") or [] if first is None or s.get("window") == first])


def burst(actions):
    """Fires every action at once; returns their replies in order."""
    replies = [None] * len(actions)

    def run(i, name):
        replies[i] = rpc("action.run", {"id": name})

    threads = [threading.Thread(target=run, args=(i, name)) for i, name in enumerate(actions)]
    for t in threads:
        t.start()
    return threads, replies


def accepted(reply):
    return not (isinstance(reply, dict) and reply.get("error"))


def phase(app, label, actions, round_index):
    failures = []
    name = "%s-%d" % (label.replace(" ", "-"), round_index)
    reply = rpc("action.run", {"action": "newTab", "args": {}, "focus": True})
    deadline = time.time() + 15
    while time.time() < deadline and shown_panes() != 1:
        time.sleep(0.1)  # test harness: the new workspace shows
    if shown_panes() != 1:
        return ["%s: no single-pane workspace (newTab %s)" % (name, json.dumps(reply)[:200])], []
    time.sleep(1)  # test harness: the workspace settles before the burst
    rpc("debug.layout_counters", {"reset": True})
    threads, replies = burst(actions)
    samples, snap_taken = [], False
    start = time.time()
    last_change = start
    while time.time() - start < 12:
        count = shown_panes()
        if samples and samples[-1][1] != count:
            last_change = time.time()
        samples.append((round(time.time() - start, 3), count))
        if not snap_taken and time.time() - start > 0.3:
            rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, name + "-mid.png")}, timeout=60)
            snap_taken = True
        done = all(not t.is_alive() for t in threads)
        if done and time.time() - last_change > 3:
            break
        if app.poll() is not None:
            return ["%s: app exited %s" % (name, app.returncode)], samples
        time.sleep(0.05)  # test harness sampling
    for t in threads:
        t.join(30)
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, name + "-after.png")}, timeout=60)
    counts = [c for _, c in samples]
    expected = 1 + sum(1 for r in replies if accepted(r))
    view_counts = (rpc("debug.layout_counters") or {}).get("pane_count_changes") or []
    drops = [(samples[i - 1], samples[i]) for i in range(1, len(samples)) if samples[i][1] < samples[i - 1][1]]
    if drops:
        failures.append("%s: shown panes went down %s" % (name, drops[:6]))
    if 0 in counts:
        failures.append("%s: the workspace showed no pane" % name)
    if counts and counts[-1] != expected:
        failures.append("%s: settled at %d panes, expected %d (replies %s)" % (
            name, counts[-1], expected, json.dumps(replies)[:400]))
    if any(b < a for a, b in zip(view_counts, view_counts[1:])):
        failures.append("%s: workspace view pane counts went down %s" % (name, view_counts))
    print("%s %s: counts %s view %s expected %d" % ("FAIL" if failures else "PASS", name,
          sorted(set(counts), key=counts.index), view_counts, expected), flush=True)
    return failures, samples


def quit_end_sessions():
    reply = rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
    if not (isinstance(reply, dict) and reply.get("quitting") == "end-sessions"):
        reply = rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    return reply


if os.path.exists(SOCKET):
    sys.exit("%s exists: pick a fresh tag" % SOCKET)
scratch = tempfile.mkdtemp(prefix="split-vanish-")
open(os.path.join(scratch, "cmux.json"), "w").write("{}")
open(os.path.join(scratch, "ghostty"), "w").write("")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"),
       "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(scratch, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1600,1000"}
log = open(os.path.join(OUT, "app-%s.log" % TAG), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
print("launched pid %d" % app.pid, flush=True)
failures, record = [], {}
try:
    deadline = time.time() + 180
    wins = None
    while time.time() < deadline and app.poll() is None:
        if os.path.exists(SOCKET):
            wins = (rpc("debug.windows") or {}).get("windows")
            if wins:
                break
        time.sleep(0.5)  # launch wait only (no runtime sync)
    if not wins:
        failures.append("no window within 180 s")
    else:
        for r in range(ROUNDS):
            for label, actions in PHASES:
                found, samples = phase(app, label, actions, r)
                failures += found
                record["%s-%d" % (label, r)] = samples
                if app.poll() is not None:
                    break
finally:
    print("quit:", json.dumps(quit_end_sessions())[:200], flush=True)
    try:
        app.wait(timeout=30)
    except subprocess.TimeoutExpired:
        os.kill(app.pid, signal.SIGKILL)
    subprocess.run([ACPMUX, "daemon", "shutdown", "--end-agents"], env={**os.environ, "ACPMUX_HOME": ACPMUX_HOME,
                   "ACPMUX_SOCKET": os.path.join(ACPMUX_HOME, "acpmux.sock")}, capture_output=True, timeout=30)
    subprocess.run([CLI, "server", "stop", "--session", "cmux-app-%s" % TAG, "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)

json.dump({"tag": TAG, "failures": failures, "samples": record}, open(os.path.join(OUT, "split-vanish.json"), "w"), indent=1)
for f in failures:
    print("FAIL", f, flush=True)
print("RESULT", "PASS" if not failures else "FAIL (%d)" % len(failures), flush=True)
sys.exit(0 if not failures else 1)
