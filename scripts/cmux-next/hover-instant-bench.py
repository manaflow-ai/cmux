#!/usr/bin/env python3
"""Sidebar row hover card: how long from the pointer's arrival on a row to the card (goal sidebar-hover-instant,
Leo 2026-11-01: "i need these hover previews to appear a hell of a lot faster than they do now").

  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \\
    --ref <sha> --artifact artifacts/split-spring/report.json --arg=--config=bench --arg=--suite=hover-instant

Launches the tagged app (a bench build: `debug.hover_cards` is registered only with CMUX_BENCH_HOOKS or in Debug),
fills the sidebar to each --workspaces count, and for --samples rows per count moves the real pointer onto the row
and reads `debug.hover_cards` until the row's card shows. The real pointer moves by the first route that works: a bench pointer app built once
from PointerGlide.swift (`--pointer-glide`, its own lasting Accessibility grant, given once), then
mouse moves this step posts itself (pointer-probe.swift; needs an Accessibility grant for this process, which a
binary compiled per run never has), then CuaDriver's `move_cursor` (desktop scope, foreground delivery) through its
daemon, which holds the host's Accessibility grant. Each route is checked by reading the pointer back. Only when
neither moves it does the bench say why for each and move a synthetic pointer through the windows' tracking areas
instead (`debug.pointer_hover`); the report's `input` and `pointer_route` say which ran. Per sample: the last move
to pending and to shown (ms); on a miss (no card in 2 s) the coordinator's whole report. Writes --json.
"""
import argparse, json, os, plistlib, queue, socket, statistics, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import LaunchError, launch_app  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402
from safe_log import safe_print  # noqa: E402  (a line in a cleanup path never skips the kill)

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", default=None)
parser.add_argument("--json", default=None)
parser.add_argument("--workspaces", default="10,200")
parser.add_argument("--samples", type=int, default=10)
parser.add_argument("--input", choices=("real", "synthetic"), default="real")
opts, _ = parser.parse_known_args()
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = opts.out or tempfile.mkdtemp(prefix="hover-instant-")
os.makedirs(OUT, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
REPORT = {"suite": "hover-instant", "cells": [], "input": opts.input, "notes": []}


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(check, seconds, step=0.05):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait on the app's state
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def cards():
    reply = rpc("debug.hover_cards", timeout=5)
    return reply if isinstance(reply, dict) else {}


def main_window():
    for entry in (rpc("debug.window_list") or {}).get("windows") or []:
        if entry.get("kind") == "main" and entry.get("visible"):
            return entry
    return None


def off_card(point, frame):
    """A window point away from the row and from its card, at the row's height: near the window's right edge. The card
    opens beside the sidebar and lingers while the pointer is on it, so a point just right of the sidebar can sit on
    the card and keep it open: step 8003f043 (cmux20-bench, 2026-11-16, real glides) parked 260 px right of the
    sidebar and every sample after the first read "not cold" with the first card still shown."""
    width = ((main_window() or {}).get("frame") or {}).get("width") or 0
    return [max(frame[0] + frame[2] + 260, width - 40), point[1]]


def workspace_count():
    snap = rpc("snapshot.get", timeout=60)
    return len(((snap.get("topology") or {}) if isinstance(snap, dict) else {}).get("workspaces") or [])


def rows():
    """The visible workspace rows: (key, window point at the row's middle, window frame)."""
    found = []
    for row in ((rpc("debug.sidebar_rows") or {}).get("windows") or [{}])[0].get("rows") or []:
        if not str(row.get("key", "")).startswith("workspace") or not row.get("in_list"):
            continue
        f = row["window_frame"]
        f = [f["x"], f["y"], f["width"], f["height"]] if isinstance(f, dict) else list(f)
        found.append((row["key"], [f[0] + f[2] / 2, f[1] + f[3] / 2], f))
    return found


# --- pointer ------------------------------------------------------------------------------------
PROBE = os.path.join(tempfile.mkdtemp(prefix="pointer-probe-"), "pointer-probe")
SCREEN_H = 0.0


def probe(*args, timeout=20):
    return subprocess.run([PROBE, *map(str, args)], capture_output=True, text=True, timeout=timeout).stdout.strip()


def to_screen(point):
    """A window point from the top left to a screen point from the top left."""
    f = (main_window() or {}).get("frame") or {}
    return (f.get("x", 0) + point[0], SCREEN_H - (f.get("y", 0) + f.get("height", 0)) + point[1])


def where():
    try:
        return tuple(map(float, probe("where").split()))
    except ValueError:
        return None


LAST_POINT = {}
DELAY_MS = 0.0  # the coordinator's show delay (`debug.hover_cards` delay_ms), read once the app answers
ROUTE = None  # the real pointer route: "helper" (cmux Computer Use), "posted" (pointer-probe) or "cua" (CuaDriver)
CUA_CANDIDATES = (os.path.expanduser("~/.local/bin/cua-driver"),
                  "/Applications/CuaDriver.app/Contents/MacOS/cua-driver")
CUA_PATH = next((p for p in CUA_CANDIDATES if os.access(p, os.X_OK)), None)


class Cua:
    """One `cua-driver mcp` stdio session to the CuaDriver daemon, which holds the host's Accessibility grant: a
    move is one JSON line each way, not a process per move (gui-session-sweep.py's route)."""

    def __init__(self, path):
        self.p = subprocess.Popen([path, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True)
        self.lines = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()
        self.n = 0
        try:
            self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "hover-instant-bench", "version": "1"}})
            self.rpc("notifications/initialized", notify=True)
        except (OSError, RuntimeError):
            self.close()
            raise

    def read(self):
        for line in self.p.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def rpc(self, method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            self.n += 1
            msg["id"] = self.n
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()
        if notify:
            return None
        while True:  # bounded: 60 s per answer, and an ended driver closes stdout
            try:
                line = self.lines.get(timeout=60)
            except queue.Empty:
                raise RuntimeError(f"cua-driver mcp: no answer to {method} in 60 s") from None
            if not line:
                raise RuntimeError("cua-driver mcp ended")
            try:
                reply = json.loads(line)
            except ValueError:
                continue
            if reply.get("id") == self.n:
                return reply

    def call(self, tool, args):
        """The tool's answer (structuredContent when there is one); RuntimeError when it failed or refused."""
        reply = self.rpc("tools/call", {"name": tool, "arguments": args})
        result = reply.get("result") or {}
        inner = result.get("structuredContent") if isinstance(result.get("structuredContent"), dict) else {}
        if (reply.get("error") or not result or result.get("isError")
                or "refused" in (inner.get("status"), inner.get("effect"))):
            text = " ".join(c.get("text", "") for c in result.get("content") or [] if isinstance(c, dict))
            raise RuntimeError(f"cua-driver {tool}: {(reply.get('error') or text or result)!s}"[-300:])
        return inner or result

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            self.p.kill()  # the exact PID this script started
            self.p.wait()


CUA = None
CUA_SCALE = 1.0

# Real moves need a process with its own lasting Accessibility grant: one this step compiles or starts directly never
# holds one (cmux20-bench, 2026-11-15: AXIsProcessTrusted and CGPreflightPostEventAccess false for the step's
# processes), and no shipped app answers `--pointer-glide`. So the bench builds PointerGlide.swift into a small app
# once, at a stable path the step's next runs find again, and never rebuilds it: an ad-hoc grant is tied to the binary,
# so one grant at the host's console lasts. Launched through LaunchServices, it is its own responsible process. The
# directory is this user's alone (0700). A changed PointerGlide.swift is picked up only after the app is deleted by
# hand and granted again. CMUX_BENCH_POINTER_APP names another app with the same `--pointer-glide` answer.
HELPER_CACHE = f"/Users/Shared/cmux-bench-pointer-{os.getuid()}"
HELPER_ID = "com.cmuxterm.bench-pointer"
HELPER_APP = os.environ.get("CMUX_BENCH_POINTER_APP", os.path.join(HELPER_CACHE, "v2", "cmux Bench Pointer.app"))
POINTER_GLIDE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench-pointer", "PointerGlide.swift")


def own_cache():
    """HELPER_CACHE, made 0700 for this user; RuntimeError when it is someone else's, a link, or open to others."""
    import stat
    try:
        os.mkdir(HELPER_CACHE, 0o700)
    except FileExistsError:
        pass
    info = os.lstat(HELPER_CACHE)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError(f"{HELPER_CACHE} is not a directory only uid {os.getuid()} may use "
                           f"(owner {info.st_uid}, mode {oct(info.st_mode & 0o7777)})")


def install_pointer_app():
    """HELPER_APP, built from PointerGlide.swift on the first run and left alone after (a rebuild would lose its
    grant); RuntimeError naming why not. Returns whether this run built it."""
    import plistlib, shutil
    own_cache()
    if os.path.isdir(HELPER_APP):
        return False
    with tempfile.TemporaryDirectory(prefix="pointer-app-", dir=HELPER_CACHE) as tmp:
        main = os.path.join(tmp, "main.swift")
        with open(main, "w") as out:
            out.write("import Darwin\nexit(PointerGlide().main(arguments: CommandLine.arguments))\n")
        app = os.path.join(tmp, os.path.basename(HELPER_APP))
        macos = os.path.join(app, "Contents", "MacOS")
        os.makedirs(macos)
        # The deployment target and Info.plist name a whole app: v1 (Info.plist with no version or minimum system,
        # swiftc's default target) built but LaunchServices refused to open it (error -10825, step adc067cb).
        built = subprocess.run(["xcrun", "swiftc", "-O", "-target", f"{os.uname().machine}-apple-macos14",
                                "-module-name", "BenchPointer", POINTER_GLIDE, main, "-o",
                                os.path.join(macos, "bench-pointer")], capture_output=True, text=True, timeout=600)
        if built.returncode:
            raise RuntimeError(f"swiftc exit {built.returncode}: {built.stderr.strip()[-300:]}")
        with open(os.path.join(app, "Contents", "Info.plist"), "wb") as out:
            plistlib.dump({"CFBundleIdentifier": HELPER_ID, "CFBundleExecutable": "bench-pointer",
                           "CFBundleName": "cmux Bench Pointer", "CFBundlePackageType": "APPL",
                           "CFBundleInfoDictionaryVersion": "6.0", "CFBundleVersion": "2",
                           "CFBundleShortVersionString": "2.0", "LSMinimumSystemVersion": "14.0",
                           "LSUIElement": True}, out)
        signed = subprocess.run(["codesign", "--force", "-s", "-", "--identifier", HELPER_ID, app],
                                capture_output=True, text=True, timeout=120)
        if signed.returncode:
            raise RuntimeError(f"codesign exit {signed.returncode}: {signed.stderr.strip()[-300:]}")
        os.makedirs(os.path.dirname(HELPER_APP), exist_ok=True)
        shutil.move(app, HELPER_APP)
    return True


def helper_glide(x0, y0, x1, y1, steps):
    """Posts `steps` real mouse moves from (x0, y0) to (x1, y1) (screen points, top left) through the helper app and
    returns the monotonic time of its last post (time.monotonic and the helper's CLOCK_UPTIME_RAW are one clock on
    macOS). RuntimeError with the helper's answer when it posted nothing."""
    with tempfile.TemporaryDirectory(prefix="hover-glide-") as tmp:
        out, err = os.path.join(tmp, "out"), os.path.join(tmp, "err")
        opened = subprocess.run(["open", "-g", "-n", "-W", "--stdout", out, "--stderr", err, HELPER_APP, "--args",
                                 "--pointer-glide", *[f"{v:.1f}" for v in (x0, y0, x1, y1)], str(steps)],
                                capture_output=True, text=True, timeout=30)
        text = open(out, errors="replace").read().strip() if os.path.exists(out) else ""
        try:
            answer = json.loads(text.splitlines()[-1]) if text else {}
        except ValueError:
            answer = {}
        if not isinstance(answer, dict):
            answer = {}
        posted = answer.get("last_post_uptime_ns")
        # A partial glide still landed its last post then: time from it, never from now (later, so too fast).
        if isinstance(posted, int) and posted > 0 and answer.get("posted"):
            return posted / 1e9
        stderr = open(err, errors="replace").read().strip()[-200:] if os.path.exists(err) else ""
        raise RuntimeError(f"helper --pointer-glide: {text[-300:] or 'no answer'} {stderr} "
                           f"(open exit {opened.returncode}: {opened.stderr.strip()[-200:]})".strip())


def cua_move(x, y):
    """The real pointer to screen point (x, y) (top left) through CuaDriver: desktop scope takes the main display's
    screenshot pixels; foreground delivery because the bench app is never in front on a fleet step and nobody
    uses a bench host's screen."""
    CUA.call("move_cursor", {"scope": "desktop", "delivery_mode": "foreground",
                             "x": round(x * CUA_SCALE), "y": round(y * CUA_SCALE)})


def move_path(start, end, steps):
    """Moves from `start` to `end` (window points), `steps` moves about 120 Hz apart; returns the monotonic time
    the last move landed."""
    if opts.input == "synthetic":
        height = ((main_window() or {}).get("frame") or {}).get("height", 0)
        for i in range(1, steps + 1):
            x = start[0] + (end[0] - start[0]) * i / steps
            y = start[1] + (end[1] - start[1]) * i / steps
            LAST_POINT.update(window_top_left=[x, y], sent=[x, height - y], height=height,
                              reply=rpc("debug.pointer_hover", {"point": [x, height - y]}))
        return time.monotonic()
    (x0, y0), (x1, y1) = to_screen(start), to_screen(end)
    if ROUTE == "helper":
        try:
            return helper_glide(x0, y0, x1, y1, steps)
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:  # the sample shows a miss
            if len(REPORT["notes"]) < 20:
                REPORT["notes"].append(f"glide failed: {error}")
            return time.monotonic()
    if ROUTE == "cua":
        for i in range(1, steps + 1):
            if i > 1:
                time.sleep(0.008)  # test harness: a mouse reports about every 8 ms
            try:
                cua_move(x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps)
            except (OSError, RuntimeError) as error:  # one refused move ends no run; the sample shows a miss
                if len(REPORT["notes"]) < 20:
                    REPORT["notes"].append(f"move failed: {error}")
        return time.monotonic()
    probe("path", x0, y0, x1, y1, steps)
    return time.monotonic()


def landed(target):
    at = where()
    return at, bool(at and abs(at[0] - target[0]) < 2 and abs(at[1] - target[1]) < 2)


def app_saw(move, route):
    """Whether the app got the moves `move` (screen point -> None) makes onto a sidebar row: the list hovers the row,
    or the hover coordinator counts an event or names a hit. A pointer that lands without one was warped
    (CuaDriver's move_cursor sends no mouse-moved event: on cmux20-bench, 2026-11-15, step b13acff317b8d8977670a944,
    the pointer sat on each row and `events` never changed), and a bench on it measures nothing. None when no row is
    there to tell. Each check's readings go to the report's `route_checks`."""
    found = wait(lambda: rows() or None, 5)
    if not found:
        return None
    key, point, frame = found[0]
    before = cards()
    move(to_screen(off_card(point, frame)))
    move(to_screen(point))
    seen = wait(lambda: (lambda c: c.get("events") != before.get("events") or c.get("last_hit", "-") != "-"
                         or c.get("pending_target", "-") != "-")(cards()), 1.5)
    hovered = row_hovered(key)
    after = cards()
    REPORT.setdefault("route_checks", []).append({
        "route": route, "row": key, "row_hovered": hovered, "pointer": where(),
        "events": [before.get("events"), after.get("events")], "last_hit": after.get("last_hit"),
        "app_active": (rpc("debug.focus") or {}).get("app_active")})
    move(to_screen(off_card(point, frame)))  # off the row again: the first sample starts cold
    return bool(seen) or bool(hovered)


def unseen(landed_ok, saw):
    """Why a route that moved the pointer did not count: the app saw no move (False), or no row was there to check."""
    if not landed_ok:
        return ""
    return ", the app saw no move" if saw is False else ", no sidebar row to check that the app saw it"


def real_input_works():
    """Picks the first real pointer route that moves the pointer (read back with pointer-probe where, which needs
    no grant) and whose moves the app sees, and returns None; else why each route failed."""
    global ROUTE, CUA, CUA_SCALE
    f = (main_window() or {}).get("frame") or {}
    target = to_screen([f.get("width", 800) * 0.6, f.get("height", 600) * 0.5])
    why = []
    # Every route counts only with proof the app got its moves (`app_saw` True). An unproven one (None: no row to
    # tell) measured nothing: step adc067cb took posted moves on None and missed all 20 cards (no row hovered, no
    # event), which reads 2000 ms on the board. Synthetic input measures the goal's after-delay cost the same.
    if os.path.isdir(HELPER_APP):
        try:
            helper_glide(target[0] - 40, target[1], target[0], target[1], 2)
            at, ok = landed(target)
            saw = app_saw(lambda p: helper_glide(p[0] - 1, p[1], p[0], p[1], 2), "helper") if ok else None
            if saw is True:
                ROUTE = "helper"
                return None
            why.append(f"helper glide to {target[0]:.0f} {target[1]:.0f}: pointer after {at}" + unseen(ok, saw))
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            why.append(str(error)[-300:])
    else:
        why.append(f"no helper app at {HELPER_APP}")
    run = subprocess.run([PROBE, "move", str(target[0]), str(target[1])], capture_output=True, text=True, timeout=20)
    at, ok = landed(target)
    saw = app_saw(lambda p: probe("move", p[0], p[1]), "posted") if ok else None
    if saw is True:
        ROUTE = "posted"
        REPORT["route_failures"] = why  # why each earlier route was passed over, also when a later one works
        return None
    why += [f"pointer-probe move {target[0]:.0f} {target[1]:.0f}: exit {run.returncode}, "
           f"stderr {run.stderr.strip()[-300:]!r}, pointer after {at}" + unseen(ok, saw)]
    if not CUA_PATH:
        return "; ".join(why + [f"no cua-driver at {' or '.join(CUA_CANDIDATES)}"])
    try:
        CUA = CUA or Cua(CUA_PATH)
        CUA_SCALE = float(CUA.call("get_screen_size", {}).get("scale_factor") or 1.0)
        # Off the target first, so a pointer already there does not pass the check.
        cua_move(target[0] - 40, target[1])
        cua_move(target[0], target[1])
        at, ok = landed(target)
        # Only when the app is seen getting its moves: move_cursor warps (no mouse-moved event), so an unproven
        # check (None: no row to tell) must not pick it (step 87a83e6c took it on None and measured nothing).
        saw = app_saw(lambda p: cua_move(*p), "cua") if ok else None
        if saw is True:
            ROUTE = "cua"
            REPORT["route_failures"] = why
            return None
        why.append(f"cua-driver move_cursor {target[0]:.0f} {target[1]:.0f} (scale {CUA_SCALE:g}): pointer after {at}"
                   + unseen(ok, saw) + (" (a warp sends no mouse-moved event)" if saw is False else ""))
    except (OSError, RuntimeError, ValueError) as error:
        why.append(f"cua-driver at {CUA_PATH}: {error}")
    REPORT["route_failures"] = why
    return "; ".join(why)


def activate():
    global CUA
    if (rpc("debug.focus") or {}).get("app_active"):
        return True
    try:
        # Through a `cua-driver mcp` session, which starts its daemon when none answers: `cua-driver call` looks for
        # the daemon's socket under HOME, and a fleet step's own HOME has none ("Cua Driver daemon is not running",
        # step b13acff317b8d8977670a944).
        if CUA is None and CUA_PATH:
            CUA = CUA or Cua(CUA_PATH)
        if CUA is not None:
            try:
                CUA.call("bring_to_front", {"pid": APP_PID})
            except RuntimeError as error:
                # "pid N owns more than one eligible top-level window; provide window_id" (step ccc304db, cmux20,
                # 2026-11-17): the main window's id, its on-screen window of the main window's size.
                f = (main_window() or {}).get("frame") or {}
                ids = [int(w[0]) for w in (line.split() for line in probe("windows", APP_PID).splitlines())
                       if len(w) == 5 and abs(float(w[3]) - f.get("width", -9)) < 2
                       and abs(float(w[4]) - f.get("height", -9)) < 2]
                if "window_id" not in str(error) or not ids:
                    raise
                CUA.call("bring_to_front", {"pid": APP_PID, "window_id": ids[0]})
    except (OSError, RuntimeError, ValueError) as error:
        REPORT.setdefault("activate_error", str(error)[-300:])
    return bool(wait(lambda: (rpc("debug.focus") or {}).get("app_active"), 3))


def pct(values, q):
    values = sorted(values)
    return round(values[min(len(values) - 1, int(round(q * (len(values) - 1))))], 1) if values else None


# --- one sample -----------------------------------------------------------------------------------
def front_owner(point):
    """(pid, app) of the frontmost normal window at a window point, or None: what a real move there reaches."""
    at = to_screen(point)
    words = probe("front", f"{at[0]:.1f}", f"{at[1]:.1f}").split(None, 1)
    return (int(words[0]), words[1] if len(words) > 1 else "?") if words and words[0].isdigit() else None


def reachable(visible):
    """The rows a real move reaches: another app's window in front of the inactive bench app takes every move under
    it. Step ccc304db (cmux20-bench, 2026-11-17): the installed cmux NEXT, opened at login, had a window from screen
    y 273 down in front of the bench app, and the 13 samples on rows below it read no event and no card (2000 ms
    each on the board) while the rows above read 3 to 36 ms past the delay. A covered row is not the app's cost, so
    it is left out and named in the cell's `occluded`: the samples take turns on the rows left, and a cell with none
    left has no samples, which reads unknown, never unmet."""
    if opts.input != "real":
        return visible, None
    covered = lambda: [(r, o) for r in visible if (o := front_owner(r[1])) is not None and o[0] != APP_PID]
    if covered():
        activate()
    hidden = covered()
    if not hidden:
        return visible, None
    keys = {r[0] for r, _ in hidden}
    return [r for r in visible if r[0] not in keys], {"rows": len(hidden), "by": sorted({o[1] for _, o in hidden})}


def row_hovered(key):
    """The sidebar's own hover state of row `key` (debug.sidebar_rows "hovered"): whether the list's tracking area
    got the pointer, apart from the hover card coordinator. None when the row is not listed."""
    for row in ((rpc("debug.sidebar_rows") or {}).get("windows") or [{}])[0].get("rows") or []:
        if row.get("key") == key:
            return row.get("hovered")
    return None


def row_target(key):
    """The card target id of row `key`: "workspace(ID)" is shown as "ws:ID"."""
    return "ws:" + key[key.find("(") + 1:-1] if key.startswith("workspace(") else key


def sample(count, index, key, point, frame):
    off = off_card(point, frame)  # in the content, clear of the card, at the row's height
    move_path(point, off, 3)
    # Cold start: no card open and the coordinator idle, or the sample is not counted (a card already open would
    # read as shown in a few ms with no pending phase, as the 200 workspace cell did in step b13acff317b8d8977670a944).
    cold = wait(lambda: (lambda c: c.get("phase") == "idle" and c.get("card_showing") != "true")(cards()), 3)
    # sleep-ok: outlasts the app's quick-reshow timer (HoverCardTiming.reshowWindow, 300 ms from the card hiding),
    # which debug.hover_cards does not report (the phase is idle through it), so the card opens cold.
    time.sleep(0.45)
    activate()
    start = [frame[0] + frame[2] + 40, point[1]]
    move_path(off, start, 3)
    before = cards()
    cold = bool(cold) and before.get("card_showing") != "true"
    # The glide onto the row from its right edge, as a hand comes off the content. It runs beside the reads: the
    # helper route returns only after its process ends (tens of ms past its last post), and a card that shows in
    # that gap must still be timed from the post, not from the first read after the exit.
    glide = {}
    mover = threading.Thread(target=lambda: glide.setdefault("last", move_path(start, point, 6)), daemon=True)
    mover.start()
    pending_at = shown_at = None
    report = {}
    target = row_target(key)
    began = time.monotonic()
    while cold:  # bounded: 2 s past the last move, and 32 s for a glide that never returns (its timeout is 30 s)
        report = cards()
        now = time.monotonic()
        if pending_at is None and report.get("pending_target", "-") == target:
            pending_at = now
        if report.get("card_showing") == "true" and report.get("shown_target") == target:
            shown_at = now  # only this row's card, opened after the sample began cold
        if not mover.is_alive() and (shown_at is not None or now > glide.get("last", began) + 2.0):
            break
        if now - began > 32:
            break
        time.sleep(0.005)  # test harness: about one read per frame
    mover.join(timeout=1)
    last = glide.get("last", time.monotonic())
    # A card seen before the last post landed counts as 0 ms: it showed while the hand was still arriving.
    pending = None if pending_at is None else max(0.0, (pending_at - last) * 1000)
    shown = None if shown_at is None or shown_at - last > 2.0 else max(0.0, (shown_at - last) * 1000)
    # The card's own cost past its wait: the coordinator arms the show delay when it turns pending, so pending to
    # shown, less that delay, is the timer's overshoot plus building and showing the card, whatever the delay is.
    after_delay = None if shown is None or pending_at is None else (shown_at - pending_at) * 1000 - DELAY_MS
    focus = rpc("debug.focus") or {}
    run = {"workspaces": count, "round": index, "row": key, "pending_ms": pending and round(pending, 1),
           "shown_ms": shown and round(shown, 1),
           "after_delay_ms": None if after_delay is None else round(after_delay, 1),
           "target": report.get("shown_target"),
           # Where moves stop on a miss: a hovered row with no coordinator hit is the coordinator; a row the list
           # never hovered is delivery (the window server sent the app no move).
           "row_hovered": row_hovered(key), "events_delta": None if not report else
           (int(report.get("events") or 0) - int(before.get("events") or 0)),
           "active": focus.get("app_active"), "key_window": focus.get("key_window")}
    if not cold:
        run["not_cold"] = {k: before.get(k) for k in ("phase", "card_showing", "shown_target")}
    if shown is None and cold:
        run["miss"] = {k: v for k, v in report.items() if k != "card_text"}
        run["pointer"] = where() if opts.input == "real" else None
        if report.get("last_hit", "-") == "-":
            # A coordinate mismatch or a source refusing the hit: the row's frame against the point the move used,
            # and every visible row's frame now.
            run["row_frame"] = frame
            run["point"] = dict(LAST_POINT) if opts.input == "synthetic" else to_screen(point)
            run["rows_now"] = [(k, f) for k, _, f in rows()][:12]
    print(f"   {count}w #{index} {key}: active {run['active']} hovered {run['row_hovered']} events "
          f"+{run['events_delta']} pending {run['pending_ms']} shown {run['shown_ms']}"
          + (f" NOT COLD {run['not_cold']}" if not cold else "")
          + (f" MISS {json.dumps(run.get('miss'))[:600]}" if "miss" in run else "")
          + (f" ROW {run['row_frame']} POINT {json.dumps(run['point'])[:400]} ROWS {json.dumps(run['rows_now'][:4])}"
             if "row_frame" in run else ""), flush=True)
    return run


def fill(count):
    for _ in range(count * 2):  # bounded: a create that never lands must not hang the step
        have = workspace_count()
        if have >= count:
            return True
        rpc("action.run", {"action": "workspace.newAtBottom", "args": {}, "focus": False, "origin": "script"}, timeout=60)
        if not wait(lambda: workspace_count() > have, 10, step=0.1):
            return False
    return workspace_count() >= count


# --- run ----------------------------------------------------------------------------------------
APP = opts.app.rstrip("/")
SCRATCH = tempfile.mkdtemp(prefix=f"hover-instant-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
teardown = TagTeardown(APP)
teardown.install()
app = None
APP_PID = None
status = 1
try:
    subprocess.run(["xcrun", "swiftc", "-O", os.path.join(HERE, "pointer-probe.swift"), "-o", PROBE], check=True)
    SCREEN_H = float(probe("screen") or 0)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_CHIEF_ISOLATED": "1",
           "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720",
           # A fleet step cannot activate the app (no LaunchServices session): WindowPlacement.noActivate counts it as
           # active and the coordinator hit-tests against its own windows.
           "CMUX_NEXT_NO_ACTIVATE": "1"}
    try:
        app, SOCKET = launch_app(APP, env, os.path.join(OUT, f"app-{opts.tag}.log"), timeout=180,
                                 on_start=lambda p: globals().__setitem__("APP_PID", p.pid))
    except LaunchError as error:
        REPORT["notes"].append(f"launch failed: {error}")
        raise SystemExit(1)
    APP_PID = app.pid
    REPORT["macos"] = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    REPORT["host"] = subprocess.run(["hostname", "-s"], capture_output=True, text=True).stdout.strip()
    REPORT["active_at_start"] = activate()
    if opts.input == "real" and "CMUX_BENCH_POINTER_APP" not in os.environ:
        try:
            # A just-built app has no grant yet: its glide answers "no post-event access" until one is given.
            REPORT["pointer_helper"] = {"app": HELPER_APP, "built_now": install_pointer_app()}
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            REPORT["pointer_helper"] = {"app": HELPER_APP, "error": str(error)[-300:]}
            REPORT["notes"].append(f"bench pointer app unavailable: {str(error)[-300:]}")
    # The route check hovers a sidebar row, and a just-launched app may list none yet: step 2af64408 (cmux20-bench,
    # 2026-11-16) ran it right after launch, found no row (no route_checks) and fell back to synthetic though the
    # granted glide moved the pointer.
    if opts.input == "real":
        fill(2)
    why = real_input_works() if opts.input == "real" else None
    if why:
        REPORT["notes"].append(f"real input fell back to synthetic: {why}")
        safe_print(f"real input fell back to synthetic: {why}", flush=True)
        opts.input = REPORT["input"] = "synthetic"
    REPORT["pointer_route"] = {"helper": "bench pointer app --pointer-glide", "posted": "pointer-probe posted moves", "cua": "cua-driver move_cursor"}.get(ROUTE) \
        if opts.input == "real" else "debug.pointer_hover"
    report = cards()
    REPORT["defaults"] = {k: report.get(k) for k in ("enabled", "delay_ms", "sources", "monitor", "suppressions", "quiet")}
    try:
        DELAY_MS = float(report.get("delay_ms") or 0)
    except (TypeError, ValueError):
        DELAY_MS = 0.0
    safe_print(f"app pid {APP_PID}, input {opts.input} ({REPORT['pointer_route']}), "
               f"active {REPORT['active_at_start']}, window "
               f"{(main_window() or {}).get('frame')}, cards {REPORT['defaults']}", flush=True)
    for count in [int(c) for c in opts.workspaces.split(",") if c]:
        if not fill(count):
            REPORT["notes"].append(f"the app stopped making workspaces before {count}")
            break
        visible, occluded = reachable(wait(lambda: rows() if len(rows()) >= 2 else None, 10) or [])
        if occluded:
            REPORT["notes"].append(f"{count} workspaces: {occluded['rows']} rows under {', '.join(occluded['by'])}")
        runs = [sample(count, i, *visible[i % len(visible)]) for i in range(opts.samples)] if visible else []
        shown = [r["shown_ms"] for r in runs if r["shown_ms"] is not None]
        pending = [r["pending_ms"] for r in runs if r["pending_ms"] is not None]
        after = [r["after_delay_ms"] for r in runs if r["after_delay_ms"] is not None]
        cell = {"workspaces": count, "rows_visible": len(visible), "occluded": occluded, "samples": len(runs),
                "shown": len(shown),
                "shown_p50": pct(shown, 0.5), "shown_p95": pct(shown, 0.95),
                "pending_p50": pct(pending, 0.5), "pending_p95": pct(pending, 0.95),
                "delay_ms": DELAY_MS, "after_delay_p50": pct(after, 0.5), "after_delay_p95": pct(after, 0.95),
                "median": statistics.median(shown) if shown else None, "runs": runs}
        REPORT["cells"].append(cell)
        safe_print(f"{count} workspaces: {len(shown)}/{len(runs)} shown, last move to shown p50 {cell['shown_p50']} "
                   f"p95 {cell['shown_p95']} ms, to pending p50 {cell['pending_p50']} ms, past the {DELAY_MS:g} ms "
                   f"delay p50 {cell['after_delay_p50']} p95 {cell['after_delay_p95']} ms", flush=True)
    # A cell every row of which is covered has no samples: unknown, which fails nothing (review F1 on #45318).
    status = 0 if REPORT["cells"] and all(c["shown"] or not c["samples"] for c in REPORT["cells"]) else 1
finally:
    if CUA is not None:
        CUA.close()
    if app is not None:
        rpc("action.run", {"action": "quitEndSessions", "origin": "script"}, timeout=10)
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            app.kill()  # the exact PID this script started
            app.wait()
    teardown.end()
    if opts.json:
        with open(opts.json, "w") as f:
            json.dump(REPORT, f, indent=1)
sys.exit(status)
