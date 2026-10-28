#!/usr/bin/env python3
"""New splits and browser splits never vanish under rapid creation (#26695), on a tagged cmux DEV.

Attaches to a running tagged app (a capture slot's `capture-host launch`) through its control
socket and never launches or quits it. In a fresh workspace per phase, it sends a burst of
creates back to back: real Cmd-D presses (`debug.key`, which, unlike `action.run`, never waits for
the daemon, so a second press lands on the pane the first still shows provisionally) and split
actions at once (`action.run` on parallel connections). It samples the panes the
window shows (`debug.tab_drag` strips) every 50 ms until they settle. A phase fails when:

- the shown pane count ever goes down (no action in the burst closes a pane);
- the workspace ever shows no pane at all;
- the settled count is not one pane plus the accepted splits;
- the workspace view's own pane counts (`debug.layout_counters` `pane_count_changes`) go down.

It takes a window snapshot mid-burst and after each phase into OUT_DIR.

Usage: split-vanish-live.py SOCKET OUT_DIR [PID]
Exit 0 = every phase clean. Writes OUT_DIR/split-vanish.json.
"""
import json, os, socket, sys, threading, time

SOCKET, OUT = sys.argv[1], sys.argv[2]
PID = int(sys.argv[3]) if len(sys.argv) > 3 else None
ROUNDS = int(os.environ.get("SPLIT_VANISH_ROUNDS", "3"))
# Each phase: the steps sent back to back in a fresh workspace. `key:` presses a key as a person
# does (`debug.key`, no read-your-writes wait), so a second Cmd-D lands on the pane the first one
# still shows provisionally (the #26695 race: its client-only handle was refused and the split
# vanished); a bare name is `action.run` on its own connection, all at once.
PHASES = [
    ("cmd-d presses", ["key:d", "key:d", "key:d", "key:d"]),
    ("cmd-d then browser split", ["key:d", "splitBrowserRight", "key:d"]),
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
    """Sends every step back to back (key presses in order, actions at once); returns their replies."""
    replies = [None] * len(actions)

    def run(i, name):
        replies[i] = rpc("action.run", {"id": name})

    threads = []
    for i, name in enumerate(actions):
        if name.startswith("key:"):
            replies[i] = rpc("debug.key", {"key": name[4:], "modifiers": ["command"]})
            continue
        thread = threading.Thread(target=run, args=(i, name))
        thread.start()
        threads.append(thread)
    return threads, replies


def accepted(reply):
    return not (isinstance(reply, dict) and reply.get("error"))


class App:
    """The attached app: `poll()` is its exit (None while it runs), as a Popen's."""
    returncode = None

    def poll(self):
        if PID is None:
            return None
        try:
            os.kill(PID, 0)
            return None
        except OSError:
            self.returncode = "gone"
            return self.returncode


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
    # The phase's workspace and its terminals go, so later phases have PTYs to start.
    closed = rpc("action.run", {"id": "closeWorkspace", "args": {"confirm": True}})
    if isinstance(closed, dict) and closed.get("error"):
        print("close %s: %s" % (name, json.dumps(closed)[:200]), flush=True)
    return failures, samples


app, failures, record = App(), [], {}
deadline = time.time() + 120
while time.time() < deadline and not (rpc("debug.windows") or {}).get("windows"):
    time.sleep(0.5)  # attach wait only (no runtime sync)
if not (rpc("debug.windows") or {}).get("windows"):
    failures.append("the app does not answer on %s" % SOCKET)
else:
    for r in range(ROUNDS):
        for label, actions in PHASES:
            found, samples = phase(app, label, actions, r)
            failures += found
            record["%s-%d" % (label, r)] = samples

json.dump({"socket": SOCKET, "failures": failures, "samples": record}, open(os.path.join(OUT, "split-vanish.json"), "w"), indent=1)
for f in failures:
    print("FAIL", f, flush=True)
print("RESULT", "PASS" if not failures else "FAIL (%d)" % len(failures), flush=True)
sys.exit(0 if not failures else 1)
