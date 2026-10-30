#!/usr/bin/env python3
"""Each Home window follows ITS OWN key state (cx-95476, MessagesLab 806ef0c inactive-per-view).

MessagesLab keeps the inactive-window state per window view (MessagesWindowView.inactive): each Home pane sets it from
its own window only (didBecomeKey -> active, didResignKey -> inactive, `!window.isKeyWindow` when it joins a window).
Before cx-95476 one app-wide state (HomeKeyState over `Fixture.inactive`, cx-4o3vq) drew every Home window with the key
palette while any Home window was key, and dimmed every bubble when none was. The rule now, as Messages on macOS 27: a
non-key Home window is inactive while another Home window is key (its typing indicator takes the inactive colours, its
rows are drawn with its own state); the bubbles are the same in both states (Home draws them with the theme's key
palette); a display move does not change the state.

Two windows, each with a Home fixture tab, on the tagged app TAG (classic Home). The app takes the key window, so run
it in `nx-remote --needs input` (the GUI session alone). Reads each window's own state (`debug.home.drive geometry` with
`window`: viewInactive, cellsOffInactive = visible rows drawn with another state than their view's, windowKey,
appActive) and the incoming balloon fill in each window's snapshot:
  1. window A (Home) key: A active; A shows the key fill.
  2. window B key, B without a Home pane: A inactive; A's fill does not change.
  3. B gets a Home tab, B key: B active, A inactive (before cx-95476 A stayed on the key palette); same fills.
  4. A key again: A active, B inactive (before cx-95476 B stayed on the key palette); same fills.
  5. the app inactive (Finder takes the activation): A and B inactive; the fills do not change (before: dimmed).
  6. A key, then A moved to a 1x virtual display and back: A's state and fill do not change.
  7. a send in A; while its Chief types: A key, then B key: A's typing fill follows A's own state (exact compare).

The app runs with `--follow-key-state` (MessagesLab's parity behavior). Without it Home keeps the key look in every
window (trunk 283047940d8, Lawrence 2026-10-18; HomeUnfocusedAppearanceTests), so these steps test the parity switch.

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


def state(window):
    """The inactive-window state of the Home view in `window` (its own; a build before cx-95476 has only the app-wide
    `fixtureInactive`, which is what that view drew with), the rows it drew with another state, its window's key state
    and the app's activity."""
    g = (rpc("debug.home.drive", {"action": "geometry", "window": window}) or {}).get("geometry") or {}
    out = {k: g.get(k) for k in ("viewInactive", "cellsOffInactive", "typingOffInactive", "appActive", "windowKey")}
    if out["viewInactive"] is None:
        out["viewInactive"], out["legacy"] = g.get("fixtureInactive"), True
    return out


def own(s, inactive):
    """The view's own state is `inactive` and every visible row drew with it, a typing row's fill exactly (a build before
    cx-95476 has no row read)."""
    return s.get("viewInactive") == inactive and (s.get("legacy") or (s.get("cellsOffInactive") == 0 and s.get("typingOffInactive") == 0))


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


def typing_fill(window, name):
    """The typing bubble's fill in `window`'s snapshot, exactly: the most common colour of the band above its dots
    (its box from debug.home.drive typing, window points, bottom-left origin)."""
    box = rpc("debug.home.drive", {"action": "typing", "window": window}) or {}
    path = os.path.join(opts.out, f"{name}.png")
    rpc("debug.window_snapshot", {"path": path, "window": window})
    if not box.get("ok") or not os.path.exists(path):
        return None, box
    return path, box


def band_colour(path, box):
    w, h, (rows, bpp) = read_png(path)
    s = w / box["windowWidth"]
    x0, x1 = (box["x"] + box["width"] * 0.25) * s, (box["x"] + box["width"] * 0.75) * s
    top = (box["windowHeight"] - box["y"] - box["height"]) * s
    y0, y1 = top + box["height"] * 0.10 * s, top + box["height"] * 0.24 * s
    counts = Counter(tuple(rows[y][x * bpp:x * bpp + 3]) for y in range(int(y0), int(y1) + 1) for x in range(int(x0), int(x1) + 1))
    return counts.most_common(1)[0][0] if counts else None


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
process = subprocess.Popen(["/usr/bin/open", "-n", "-W", "-a", app] + [a for k, v in env.items() for a in ("--env", f"{k}={v}")]
                           + ["--args", "--follow-key-state"],
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
    s1, fa1 = state(a), fill(a, "1-a-key")
    print(f"     1 A key: A {s1} A fill {fa1}", flush=True)
    check("1: the app is active and A is key", s1.get("appActive") == 1 and s1.get("windowKey") == 1, s1)
    check("1: A key: A active", own(s1, 0), s1)
    key_fill = fa1
    check("1: A shows a fill", key_fill is not None, key_fill)

    rpc("action.run", {"action": "newWindow", "origin": "script"})
    b = poll(lambda: next((i for i in window_ids() if i != a), None), timeout=20)
    if not check("window B opens", bool(b), window_ids()):
        sys.exit(1)
    rpc("debug.window.focus", {"window": b})
    wait_settled()
    s2, fa2 = state(a), fill(a, "2-a-behind-b")
    print(f"     2 B key, no Home: A {s2} A fill {fa2}", flush=True)
    check("2: B key without a Home pane: A inactive", own(s2, 1), s2)
    check("2: A's bubbles do not change (the same in both states)", same(fa2, key_fill), {"a": fa2, "key": key_fill})

    check("window B: a Home fixture tab shows its transcript", open_fixture(), rpc("debug.home.drive", {"action": "texts"}))
    rpc("debug.window.focus", {"window": b})
    wait_settled()
    s3a, s3b, fa3, fb3 = state(a), state(b), fill(a, "3-a"), fill(b, "3-b")
    print(f"     3 B key with Home: A {s3a} B {s3b} A fill {fa3} B fill {fb3}", flush=True)
    check("3: B key (hosts Home): B active", own(s3b, 0), s3b)
    check("3: B key: A inactive (its own window is not key)", own(s3a, 1), s3a)
    check("3: A and B show the key fill", same(fa3, fb3, key_fill), {"a": fa3, "b": fb3, "key": key_fill})

    rpc("debug.window.focus", {"window": a})
    wait_settled()
    s4a, s4b, fa4, fb4 = state(a), state(b), fill(a, "4-a"), fill(b, "4-b")
    print(f"     4 A key again: A {s4a} B {s4b} A fill {fa4} B fill {fb4}", flush=True)
    check("4: A key again: A active", own(s4a, 0), s4a)
    check("4: A key: B inactive (its own window is not key)", own(s4b, 1), s4b)
    check("4: A and B show the key fill", same(fa4, fb4, key_fill), {"a": fa4, "b": fb4, "key": key_fill})

    # Another app takes the activation (Finder; the input lock holds the GUI session).
    subprocess.run(["/usr/bin/open", "-b", "com.apple.finder"], capture_output=True)
    check("the app is no longer active (Finder is)", bool(poll(lambda: state(a).get("appActive") == 0, timeout=10)), state(a))
    wait_settled()
    s5a, s5b, fa5, fb5 = state(a), state(b), fill(a, "5-a"), fill(b, "5-b")
    print(f"     5 app inactive: A {s5a} B {s5b} A fill {fa5} B fill {fb5}", flush=True)
    check("5: the app inactive: A and B inactive", own(s5a, 1) and own(s5b, 1), [s5a, s5b])
    check("5: the bubbles do not change (no dimmed palette)", same(fa5, fb5, key_fill), {"a": fa5, "b": fb5, "key": key_fill})

    # 6: A key, then a display move and back: no state change (the display change never sets the key state).
    rpc("debug.window.focus", {"window": a})
    subprocess.run(["/usr/bin/open", "-a", app], capture_output=True)  # the app active again (the input lock is held)
    check("the app is active again", bool(poll(lambda: state(a).get("appActive") == 1, timeout=10)), state(a))
    rpc("debug.window.focus", {"window": a})
    wait_settled()
    s6, fa6 = state(a), fill(a, "6-a-before")
    print(f"     6 A key before the move: A {s6} A fill {fa6}", flush=True)
    check("6: before the move A is key: A active and the key fill",
          s6.get("appActive") == 1 and s6.get("windowKey") == 1 and own(s6, 0) and same(fa6, key_fill), [s6, fa6, key_fill])
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
        check("6: the move does not change A's state", own(s7, 0), [s6, s7])
        subprocess.run(["kill", str(vd)], capture_output=True)  # the virtual display this script started (its pid=)
        gone = poll(lambda: subprocess.run(["kill", "-0", str(vd)], capture_output=True).returncode != 0, timeout=15)
        vd = None if gone else vd
        time.sleep(1.0)  # test harness: the window is back on the 2x display
        rpc("debug.window.focus", {"window": a})
        wait_settled()
        s8, fa8 = state(a), fill(a, "6-a-after")
        print(f"     6 A back on the 2x display: {s8} A fill {fa8}", flush=True)
        check("6: after the move back: the same state and the same fill",
              own(s8, 0) and same(fa8, fa6, key_fill), {"before": [s6, fa6], "after": [s8, fa8]})

    # 7: the typing indicator per window state, exactly (key and non-key fills differ by one level: no tolerance).
    # The mock Chief of A's fixture types from 1.5 s to 3.0 s after a send; both snapshots fall inside that window.
    rpc("debug.window.focus", {"window": a})
    wait_settled()
    rpc("debug.home.drive", {"action": "focus", "window": a})
    rpc("debug.home.drive", {"action": "type", "text": "Key state typing check", "window": a})
    sent = rpc("debug.home.drive", {"action": "send", "window": a}) or {}
    check("7: a send in A", bool(sent.get("ok")), sent)
    time.sleep(1.7)  # test harness: inside the mock Chief's typing window
    t_key, box_key = typing_fill(a, "7-a-typing-key")
    s7k = state(a)
    rpc("debug.window.focus", {"window": b})
    time.sleep(0.3)  # test harness: the key change's redraw lands
    t_off, box_off = typing_fill(a, "7-a-typing-behind-b")
    s7o = state(a)
    check("7: A shows a typing row in both states", bool(t_key and t_off), [box_key, box_off])
    check("7: A key: A active, its typing row drawn with it", own(s7k, 0), s7k)
    check("7: B key: A inactive, its typing row drawn with it", own(s7o, 1), s7o)
    if t_key and t_off:
        ck, co = band_colour(t_key, box_key), band_colour(t_off, box_off)
        print(f"     7 A typing fill key {ck} behind B {co}", flush=True)
        check("7: the typing fill differs between the states (exact compare)", ck is not None and co is not None and ck != co,
              {"key": ck, "inactive": co})
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
