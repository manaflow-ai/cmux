#!/usr/bin/env python3
"""Home's key-window palette follows ONE app-wide state (cx-4o3vq).

MessagesLab draws Home's transcript with one process-wide palette state (`Fixture.inactive`). Before cx-4o3vq each Home
pane set it from its own window's key notifications and redrew only its own rows, so the palette followed whichever pane
fired last and the other Home windows kept rows of the other palette. The rule now: the palette is the key palette when
the app is active and its key window hosts a Home pane, else the inactive palette; every Home view draws again when it
changes; a display move does not change it.

Two windows, each with a Home fixture tab, on the tagged app TAG (classic Home). The app takes the key window, so run
it in `nx-remote --needs input` (the GUI session alone). Reads the palette state (`debug.home.drive geometry`:
fixtureInactive, appActive) and the incoming balloon fill in each window's snapshot:
  1. window A (Home) key: the key palette; A shows the key fill.
  2. window B key, B without a Home pane: the inactive palette; A shows the inactive fill.
  3. B gets a Home tab, B key: the key palette; A and B show the same fill.
  4. A key again: the key palette; A and B show the same fill (before cx-4o3vq B kept the inactive fill).
  5. the app inactive (Finder takes the activation): the inactive palette; A and B show the same fill, the inactive one.
  6. A key, then A moved to a 1x virtual display and back: the palette state and A's fill do not change.

Usage: home-key-palette.py --tag <tag> [--out DIR]
"""
import argparse, json, os, re, socket, subprocess, sys, time
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import home_classic  # noqa: E402
from home_pixels import read_png  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default="/tmp/home-key-palette")
opts = parser.parse_args()
home = os.environ["HOME"]
app = f"{home}/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"
sock = f"/tmp/cmux-debug-{opts.tag}.sock"
os.makedirs(opts.out, exist_ok=True)
failures = []


def rpc(method, params=None, timeout=35):
    try:
        c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(sock)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close()
        reply = json.loads(buf)
        return reply.get("result", reply)
    except Exception as error:
        return {"ok": False, "error": f"socket: {error}"}


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  {json.dumps(detail)[:500]}"), flush=True)
    if not ok:
        failures.append(name)
    return ok


def poll(predicate, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)  # test harness wait, not app code
    return None


def state(window=None):
    """The app-wide palette state and the app's activity, read through the Home view in `window` (default: the active
    window's); windowKey is that window's."""
    g = (rpc("debug.home.drive", {"action": "geometry", **({"window": window} if window else {})}) or {}).get("geometry") or {}
    return {k: g.get(k) for k in ("fixtureInactive", "appActive", "windowKey")}


def window_ids():
    report = rpc("debug.windows") or {}
    return [w.get("id") for w in report.get("windows") or [] if w.get("id")]


def fill(window, name):
    """The incoming balloon fill in `window`'s snapshot: the most common colour of the transcript's left part that is
    not the background (the colour at the transcript's top left)."""
    path = os.path.join(opts.out, f"{name}.png")
    rpc("debug.window_snapshot", {"path": path, "window": window})
    if not os.path.exists(path):
        return None
    w, h, (rows, bpp) = read_png(path)
    s = w / 1200

    def px(x, y):
        return tuple(rows[int(y * s)][int(x * s) * bpp:int(x * s) * bpp + 3])
    bg = px(255, 60)
    counts = Counter()
    for y in range(120, 700, 2):
        for x in range(280, 420, 2):
            c = px(x, y)
            if sum(abs(c[i] - bg[i]) for i in range(3)) / 3 > 6 and max(c) - min(c) < 24:
                counts[c] += 1
    return counts.most_common(1)[0][0] if counts else None


def same(*fills):
    """Equal fills, within 2 levels per channel (the outgoing gradient's dither moves a sampled grey by 1)."""
    return all(f is not None for f in fills) and all(max(abs(a[i] - b[i]) for i in range(3)) <= 2 for a in fills for b in fills)


def wait_settled():
    time.sleep(0.6)  # test harness: the palette change's redraw lands (off-main row bitmaps)


def open_fixture():
    def texts():
        return (rpc("debug.home.drive", {"action": "texts"}) or {}).get("texts")
    for _ in range(3):
        rpc("debug.home_native_fixture.open", {"new": True})
        if poll(texts, timeout=30):
            return True
    return False


if os.path.exists(sock):
    os.unlink(sock)
env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SHELL": "/bin/zsh",
       "PATH": f"{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
       "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_DEV_BACKEND_MODE": "local", "ACPMUX_AGENT_LAUNCH": "deny",
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800", **home_classic.ENV}
# Launched like a person's launch (no CMUX_NEXT_NO_ACTIVATE): the app activates and takes the key window.
process = subprocess.Popen(["/usr/bin/open", "-n", "-W", "-a", app] + [a for k, v in env.items() for a in ("--env", f"{k}={v}")],
                           cwd=opts.out, stdin=subprocess.DEVNULL, stdout=open(os.path.join(opts.out, "open.log"), "a"),
                           stderr=subprocess.STDOUT, start_new_session=True)
vd = None
try:
    if not home_classic.require(rpc):
        sys.exit(2)
    check("window A: a Home fixture tab shows its transcript", open_fixture(), rpc("debug.home.drive", {"action": "texts"}))
    ids = window_ids()
    if not check("one window to start", len(ids) == 1, ids):
        sys.exit(1)
    a = ids[0]
    rpc("debug.window.focus", {"window": a})
    check("the app is active", bool(poll(lambda: state(a).get("appActive") == 1, timeout=10)), state(a))
    wait_settled()
    s1, fa1 = state(), fill(a, "1-a-key")
    print(f"     1 A key: {s1} A fill {fa1}", flush=True)
    check("1: the app is active and A is key", s1.get("appActive") == 1 and s1.get("windowKey") == 1, s1)
    check("1: A key (hosts Home): the key palette", s1.get("fixtureInactive") == 0, s1)
    key_fill = fa1

    rpc("action.run", {"action": "newWindow", "origin": "script"})
    b = poll(lambda: next((i for i in window_ids() if i != a), None), timeout=20)
    if not check("window B opens", bool(b), window_ids()):
        sys.exit(1)
    rpc("debug.window.focus", {"window": b})
    wait_settled()
    s2, fa2 = state(a), fill(a, "2-a-behind-b")
    print(f"     2 B key, no Home: {s2} A fill {fa2}", flush=True)
    check("2: B key without a Home pane: the inactive palette", s2.get("fixtureInactive") == 1, s2)
    check("2: A shows a fill other than the key fill", fa2 is not None and not same(fa2, key_fill), {"a": fa2, "key": key_fill})
    inactive_fill = fa2

    check("window B: a Home fixture tab shows its transcript", open_fixture(), rpc("debug.home.drive", {"action": "texts"}))
    rpc("debug.window.focus", {"window": b})
    wait_settled()
    s3, fa3, fb3 = state(), fill(a, "3-a"), fill(b, "3-b")
    print(f"     3 B key with Home: {s3} A fill {fa3} B fill {fb3}", flush=True)
    check("3: B key (hosts Home): the key palette", s3.get("fixtureInactive") == 0, s3)
    check("3: A and B show the same fill, the key fill", same(fa3, fb3, key_fill), {"a": fa3, "b": fb3, "key": key_fill})

    rpc("debug.window.focus", {"window": a})
    wait_settled()
    s4, fa4, fb4 = state(), fill(a, "4-a"), fill(b, "4-b")
    print(f"     4 A key again: {s4} A fill {fa4} B fill {fb4}", flush=True)
    check("4: A key (hosts Home): the key palette", s4.get("fixtureInactive") == 0, s4)
    check("4: A and B show the same fill, the key fill (one palette state, every Home view drawn with it)",
          same(fa4, fb4, key_fill), {"a": fa4, "b": fb4, "key": key_fill})

    # Another app takes the activation (Finder; the input lock holds the GUI session).
    subprocess.run(["/usr/bin/open", "-b", "com.apple.finder"], capture_output=True)
    check("the app is no longer active (Finder is)", bool(poll(lambda: state(a).get("appActive") == 0, timeout=10)), state(a))
    wait_settled()
    s5, fa5, fb5 = state(a), fill(a, "5-a"), fill(b, "5-b")
    print(f"     5 app inactive: {s5} A fill {fa5} B fill {fb5}", flush=True)
    check("5: the app inactive: the inactive palette", s5.get("appActive") == 0 and s5.get("fixtureInactive") == 1, s5)
    check("5: A and B show the same fill, the inactive fill", same(fa5, fb5, inactive_fill),
          {"a": fa5, "b": fb5, "inactive": inactive_fill})

    # 6: A key, then a display move and back: no palette change (the display change never sets the palette state).
    rpc("debug.window.focus", {"window": a})
    subprocess.run(["/usr/bin/open", "-a", app], capture_output=True)  # the app active again (the input lock is held)
    check("the app is active again", bool(poll(lambda: state(a).get("appActive") == 1, timeout=10)), state(a))
    rpc("debug.window.focus", {"window": a})
    wait_settled()
    s6, fa6 = state(a), fill(a, "6-a-before")
    print(f"     6 A key before the move: {s6} A fill {fa6}", flush=True)
    check("6: before the move A is key: the key palette and the key fill",
          s6.get("appActive") == 1 and s6.get("windowKey") == 1 and s6.get("fixtureInactive") == 0 and same(fa6, key_fill),
          [s6, fa6, key_fill])
    vdbin = os.path.expanduser("~/messageslab-rig/bin/vdisplay")
    run = subprocess.run([vdbin, "1600", "1000", "60", "240", "0", "--detach", "--owner", str(os.getpid()), "--log",
                          os.path.join(opts.out, "vdisplay.log")], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
    line = (run.stdout.strip().splitlines() or [""])[-1]
    fields = dict(f.split("=", 1) for f in line.split()[1:] if "=" in f) if line.startswith("ready") else {}
    vd = int(fields["pid"]) if fields.get("pid", "").isdigit() else None
    if check("a 1x virtual display exists", vd is not None, line or (run.stderr or "")[-300:]):
        moved = rpc("debug.window_frame", {"window": a, "screen": "last"}) or {}
        check("A moves onto the virtual display", moved.get("screen") == "MessagesLab Rig", moved)
        wait_settled()
        s7 = state(a)
        print(f"     6 A on the 1x display: {s7}", flush=True)
        check("6: the move does not change the palette state", s7.get("fixtureInactive") == 0, [s6, s7])
        subprocess.run(["kill", str(vd)], capture_output=True)  # the virtual display this script started (its pid=)
        gone = poll(lambda: subprocess.run(["kill", "-0", str(vd)], capture_output=True).returncode != 0, timeout=15)
        vd = None if gone else vd
        time.sleep(1.0)  # test harness: the window is back on the 2x display
        rpc("debug.window.focus", {"window": a})
        wait_settled()
        s8, fa8 = state(a), fill(a, "6-a-after")
        print(f"     6 A back on the 2x display: {s8} A fill {fa8}", flush=True)
        check("6: after the move back: the same palette state and the same fill",
              s8.get("fixtureInactive") == 0 and same(fa8, fa6, key_fill), {"before": [s6, fa6], "after": [s8, fa8]})
finally:
    reply = rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
    if not (isinstance(reply, dict) and reply.get("quitting") == "end-sessions"):
        rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    rpc("action.run", {"id": "endAgents"}, timeout=5)
    try:
        process.wait(timeout=30)  # `open -W` returns when the app it launched exits
    except subprocess.TimeoutExpired:
        print("     the app did not quit in 30 s (run under nx-remote: its app stop ends the app)", flush=True)
        process.kill()  # the `open -W` this script started
    acp = "%s/.acpmux/builds/com.cmuxterm.app.debug.%s" % (home, re.sub(r"[^a-z0-9]+", ".", opts.tag.lower()).strip("."))
    subprocess.run([f"{app}/Contents/Resources/bin/acpmux", "daemon", "shutdown", "--end-agents"], capture_output=True,
                   env=dict(os.environ, ACPMUX_HOME=acp, ACPMUX_SOCKET=f"{acp}/acpmux.sock"))
    if vd is not None:
        subprocess.run(["kill", str(vd)], capture_output=True)  # the virtual display this script started (its pid=)

print(f"{len(failures)} failed: {failures}" if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
