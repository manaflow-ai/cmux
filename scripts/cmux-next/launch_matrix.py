"""The launch correctness matrix (p08-startup done check 13, task p08-startup-071).

Each case ends a tagged app one way, changes what the next launch finds, relaunches it and checks the launch: the
first frame is never blank and never layout-wrong (no closed workspace, no wrong pane tree), and content may be stale
until live for at most 2 s. relaunch-e2e.py `--matrix` runs every case on a fresh tag state each; restore-trace.py
`--case NAME` traces one case's restore read by read. Each case gives PASS, FAIL or SKIP (the host cannot make the
case: one display, F2 off) with the screenshot path of its first frame.

Per case (``run_case``): a fresh launch, the case's layout (two workspaces, the first one split in three), then
``relaunch_case``: the window placed with `debug.window_frame` (no launch sets the CMUX_NEXT_TEST_WINDOW_* knobs: the
picture path never runs under a test placement, LaunchSnapshotWindow.open), and when the case does not end with a quit,
a quit and a relaunch first, so the last quit's saved window picture is on disk; the case's ``before`` on the running
app, its ``end``, its ``between`` (what changes while the app is closed) and the relaunch. ``first_look`` takes each
main window's still and the topology as soon as the relaunch answers; ``verdict`` then checks:

  - every still is not blank: at most 99.7 % of its pixels within a small distance of one color (window material
    alone, the traffic lights aside, is blank);
  - the first frame's layout: the topology as the relaunch first answers (the launch snapshot's provisional model the
    first window draws) lists no workspace closed while the app was closed, and each workspace it already shows has
    its saved pane tree;
  - the restored topology: the same workspaces with the same pane tree (tab counts per pane, per screen), without the
    workspaces closed while the app was closed;
  - the saved picture (`savedWindowPicture` on, the default here): shown, refused or not shown, as the case expects
    (``picture_problems``: the app records a refusal as `launch_picture_mismatch` when a meta field differs,
    LaunchSnapshotWindow.show, or as `launch_picture_refused.<reason>`); when it showed, the regions it cut out
    because their layout changed (`launch_picture_stale.<region>`) are the case's, none in an unchanged one, and it
    left within 2 s
    (`launch_picture_shown` .. `launch_picture_removed`, LaunchPicturePhase.bound). A picture that shows matched the
    opening window's meta, its layout too, so it shows what the first frame's layout check checked;
  - a second still 2.5 s after the first is not blank either, and the app still runs.

Chrome restores the same way: the session's tabs come back in their windows whatever ended the last run
(chrome/browser/sessions/session_restore.cc) and a startup capture is never shown after an unclean exit or once it no
longer matches (chrome/android/java/src/org/chromium/chrome/browser/paint_preview/StartupPaintPreviewHelper.java).
"""
from __future__ import annotations

import collections
import copy
import dataclasses
import glob
import json
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_launch  # noqa: E402
import home_pixels  # noqa: E402
import launch_journey_report as journey  # noqa: E402

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"
PICTURE_FEATURE = "savedWindowPicture"
SHOWN_MARK, REMOVED_MARK, REFUSED_PREFIX = "launch_picture_shown", "launch_picture_removed", "launch_picture_refused."
# LaunchSnapshotWindow.show: the saved picture's meta differs from the opening window's (any WindowPictureMeta field).
MISMATCH_MARK = "launch_picture_mismatch"
# LaunchSnapshotWindow.show: a region whose layout changed since the quit, cut out of the picture shown
# (WindowPictureMeta.staleAreas): `sidebar` or `pane`.
STALE_PREFIX = "launch_picture_stale."
# WindowPictureStore+LaunchRead.swift: the launch read found and decoded the front window's picture.
DECODED_MARK = "launch_picture_decoded"
# The refusals a meta mismatch proves (WindowPictureMeta.Field); the others (crashRecovery, incognitoLeftovers) only
# their own `launch_picture_refused.<reason>` mark proves.
META_REASONS = frozenset(("format", "window", "profile", "frame", "screen", "scale", "appearance", "theme",
                          "sidebarWidth", "build", "sidebarLayout", "contentLayout"))
PICTURES_FOLDER = "window-pictures"  # WindowPictureStore.directoryName, in the tag's state folder
TEST_PLACEMENT_PREFIX = "CMUX_NEXT_TEST_WINDOW_"
# LaunchPicturePhase.bound: the picture over the live window at most this long; the slack is one late main turn.
STALE_LIMIT_MS, STALE_SLACK_MS = 2000, 100
LIVE_LOOK_S = 2.5  # the second still: after the picture's bound
BLANK_FRACTION, BLANK_TOLERANCE = 0.997, 12  # one color within 12 per channel over 99.7 % of the pixels is blank
SAMPLE_EDGE = 512  # stills are scaled to this many pixels on their long edge before the read (sips)
LAUNCH_TIMEOUT, EXIT_TIMEOUT, LOADED_TIMEOUT = 120.0, 45.0, 30.0
BASE_CONFIG = {"appearance": {"backgroundOpacity": 1}}
SECOND_WORKSPACE = "matrix-2"
URL = "https://example.com/?cmux-launch-matrix"
PAGE_URL = "data:text/html,<title>launch-matrix</title><h1>launch matrix</h1>"


class Skip(Exception):
    """The host cannot make the case (one display, F2 off): SKIP with the reason, never PASS."""


# ---------------------------------------------------------------- pure checks (tests feed them)

def layout_of(topology):
    """The parts of `snapshot.get`'s topology a launch must restore: whether it loaded, the daemon state, the window
    count, the tab count, and per workspace (name, per screen the tab count of each pane), sorted."""
    workspaces, tabs = [], 0
    for workspace in topology.get("workspaces") or []:
        shape = []
        for screen in workspace.get("screens") or []:
            panes = [len(pane.get("tabs") or []) for pane in screen.get("panes") or [] if not pane.get("dock")]
            tabs += sum(panes)
            shape.append(tuple(panes))
        workspaces.append((workspace.get("name") or "", tuple(shape)))
    return {"loaded": bool(topology.get("loaded")), "daemon_state": topology.get("daemon_state"),
            "windows": len(topology.get("windows") or []), "tabs": tabs, "workspaces": sorted(workspaces)}


def layout_problems(expected, got, mode="same", closed=()):
    """What `got` (``layout_of`` after the relaunch) restored wrong against `expected` (before the app ended).
    `mode`: `same` (every workspace with its pane tree, the window count), `contains` (every expected workspace by
    name, at least as many windows: the case adds some), or `skip`. Workspaces named in `closed` were closed while the
    app was closed: they are left out of `expected` and must not come back."""
    if mode == "skip":
        return []
    if not got.get("loaded"):
        return ["the topology never loaded"]
    want = [w for w in expected["workspaces"] if w[0] not in closed]
    problems = [f"closed workspace {name!r} came back" for name in sorted(closed)
                if any(w[0] == name for w in got["workspaces"])]
    if mode == "same":
        missing = collections.Counter(want) - collections.Counter(got["workspaces"])
        extra = collections.Counter(got["workspaces"]) - collections.Counter(want)
        if missing or extra:
            problems.append(f"workspaces or pane trees differ: missing {describe(missing)}, extra {describe(extra)}")
        if got["windows"] != expected["windows"]:
            problems.append(f"{got['windows']} windows restored, {expected['windows']} expected")
    elif mode == "contains":
        missing = collections.Counter(w[0] for w in want) - collections.Counter(w[0] for w in got["workspaces"])
        if missing:
            problems.append(f"workspaces missing: {describe(missing)}")
        if got["windows"] < expected["windows"]:
            problems.append(f"{got['windows']} windows restored, at least {expected['windows']} expected")
    else:
        raise ValueError(f"layout mode {mode!r}")
    return problems


def first_frame_problems(expected, first, mode="same", closed=()):
    """What the first frame's model (``layout_of`` as the relaunch first answers, loaded or not) shows wrong: a
    workspace closed while the app was closed, and with `mode` `same` a workspace that was not open or one whose pane
    tree differs from the saved one. A workspace it does not show yet (no screens) is not checked."""
    if mode == "skip" or first is None:
        return []
    problems = [f"the first frame lists closed workspace {name!r}" for name in sorted(closed)
                if any(w[0] == name for w in first["workspaces"])]
    if mode == "same":
        saved = collections.defaultdict(list)
        for name, shape in expected["workspaces"]:
            saved[name].append(shape)
        for name, shape in first["workspaces"]:
            if name in closed:
                continue
            if name not in saved:
                problems.append(f"the first frame shows workspace {name!r}, which was not open")
            elif shape and shape not in saved[name]:
                problems.append(f"the first frame shows {name!r} with pane tree {shape}, saved {saved[name]}")
    return problems


def describe(counter):
    return ", ".join(f"{key!r}" + (f" x{n}" if n > 1 else "") for key, n in sorted(counter.items())) or "none"


def picture_problems(marks, expect, reasons=(), stale=()):
    """The saved picture against the case's `expect`: `shown` (with the regions `stale` cut out and no other),
    `refused` (for one of `reasons`, any when empty), `not-shown` or `any`. `marks` is `debug.timings`'
    launch_ms_since_process_start.

    `refused` needs a picture that was read (DECODED_MARK; else the case refused nothing, a harness defect) and not
    shown. A meta reason is proven by MISMATCH_MARK or its own refusal mark; crashRecovery and incognitoLeftovers by
    their own mark only, and no launch path records those yet, so for them a picture read and not shown is enough. A
    refusal recorded for another reason fails."""
    shown = SHOWN_MARK in marks
    refused = sorted(name[len(REFUSED_PREFIX):] for name in marks if name.startswith(REFUSED_PREFIX))
    mismatch = MISMATCH_MARK in marks
    if expect == "any":
        return []
    if expect == "shown":
        why = ", ".join(refused + (["mismatch"] if mismatch else [])) or "none"
        if not shown:
            return [f"the saved picture did not show (refused: {why})"]
        cut = sorted(name[len(STALE_PREFIX):] for name in marks if name.startswith(STALE_PREFIX))
        if cut != sorted(stale):
            return [f"the picture cut out {', '.join(cut) or 'no region'}; expected {', '.join(sorted(stale)) or 'none'}"]
        return []
    if shown:
        return [f"the saved picture showed; expected {expect}" + (f" ({', '.join(reasons)})" if reasons else "")]
    if expect == "not-shown":
        return []
    if expect != "refused":
        raise ValueError(f"picture expectation {expect!r}")
    if DECODED_MARK not in marks:
        return [f"harness: no saved picture was read ({DECODED_MARK} missing), so none could be refused"]
    wanted = set(reasons)
    if refused and wanted and not set(refused) & wanted:
        return [f"the picture was refused for {', '.join(refused)}, expected {' or '.join(reasons)}"]
    if mismatch and wanted and not wanted & META_REASONS:
        return [f"the picture was refused for a meta mismatch ({MISMATCH_MARK}), expected {' or '.join(reasons)}"]
    if not refused and not mismatch and wanted <= META_REASONS:
        return [f"the picture did not show but no refusal was recorded ({MISMATCH_MARK} missing; expected "
                f"{' or '.join(reasons) or 'any'})"]
    return []


def stale_problems(marks):
    """Content may be stale until live, at most 2 s: the saved picture leaves within LaunchPicturePhase.bound."""
    if SHOWN_MARK not in marks:
        return []
    if REMOVED_MARK not in marks:
        return [f"the saved picture never left ({REMOVED_MARK} missing)"]
    held = marks[REMOVED_MARK] - marks[SHOWN_MARK]
    if held > STALE_LIMIT_MS + STALE_SLACK_MS:
        return [f"the saved picture stayed {held:.0f} ms over the live window (limit {STALE_LIMIT_MS} ms)"]
    return []


def blank_problem(path, read=None):
    """None when the still at `path` shows something, else why it is blank (or unreadable)."""
    try:
        width, height, (rows, bpp) = (read or small_png)(path)
    except (OSError, ValueError, KeyError, struct.error, zlib.error) as error:
        return f"{path}: unreadable still ({error})"
    pixels = [tuple(row[x * bpp:x * bpp + bpp]) for row in rows[:height] for x in range(width)]
    if not pixels:
        return f"{path}: empty still"
    if bpp == 4 and not any(p[3] for p in pixels):
        return f"{path}: fully transparent"
    mode = collections.Counter(tuple(c >> 3 for c in p[:3]) for p in pixels).most_common(1)[0][0]
    centre = tuple((c << 3) + 4 for c in mode)
    near = sum(1 for p in pixels if all(abs(p[k] - centre[k]) <= BLANK_TOLERANCE for k in range(3)))
    fraction = near / len(pixels)
    if fraction >= BLANK_FRACTION:
        return f"{path}: blank ({fraction:.1%} of it is #{centre[0]:02x}{centre[1]:02x}{centre[2]:02x})"
    return None


def small_png(path):
    """``home_pixels.read_png`` of `path` scaled to SAMPLE_EDGE on its long edge by sips (macOS); the full still
    where sips is missing or fails."""
    sips = shutil.which("sips")
    if sips:
        handle, small = tempfile.mkstemp(suffix=".png")
        os.close(handle)
        try:
            done = subprocess.run([sips, "-Z", str(SAMPLE_EDGE), path, "--out", small], capture_output=True, timeout=60)
            if done.returncode == 0:
                return home_pixels.read_png(small)
        except (OSError, subprocess.TimeoutExpired, ValueError):
            pass
        finally:
            os.unlink(small)
    return home_pixels.read_png(path)


def test_placement_keys(env):
    """The CMUX_NEXT_TEST_WINDOW_* variables of a launch env: a matrix launch sets none, or no picture can show."""
    return sorted(key for key in env if key.startswith(TEST_PLACEMENT_PREFIX))


def result_of(problems, skipped=None):
    return SKIP if skipped else (FAIL if problems else PASS)


def line(row):
    """One printed line per case: the result, the case, its first frame's still (or why there is none)."""
    shot = row.get("screenshot") or "(no still: " + (row.get("skip") or "no window") + ")"
    text = f"{row['result']:<4} {row['case']:<28} {shot}"
    for problem in row.get("problems") or []:
        text += f"\n       {problem}"
    if row.get("skip"):
        text += f"\n       skipped: {row['skip']}"
    return text


# ---------------------------------------------------------------- the run of one case on a tagged app

class Run:
    """One case's tag: its BenchApp, what the launch must restore (``expected``), the workspaces closed while the app
    was closed, and the problems found on the way (the case's own ends add them). `now` and `sleep` are seams."""

    def __init__(self, bench, out, picture=True, f2=False, log=print, now=time.monotonic, sleep=time.sleep):
        self.bench, self.out, self.picture, self.f2, self.log = bench, out, picture, f2, log
        self.now, self.sleep = now, sleep
        self.expected = None
        self.closed = set()
        self.problems = []
        self.notes = []
        self.frames_before = None
        self.tabs_before = None
        self.pictures_aside = None  # scale-change: the copy of the pictures the quit on the first screen saved
        self.host_killed = None  # cef-host-kill: the Chromium Host pid killed during the relaunch
        self.watchers = []  # threads a relaunch's on_start started (URL open, host kill)
        os.makedirs(out, exist_ok=True)

    # -- the socket
    def rpc(self, method, params=None, timeout=60):
        return self.bench.rpc(method, params, timeout)

    def action(self, name, args=None, target=None):
        params = {"action": name, "args": args or {}, "focus": True, "confirm": True, "origin": "script"}
        if target:
            params["target"] = target
        reply = self.rpc("action.run", params, timeout=120)
        if isinstance(reply, dict) and reply.get("error"):
            self.log(f"  action {name} -> {reply['error']}")
        return reply if isinstance(reply, dict) else {}

    def cli(self, *args, timeout=60):
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        return subprocess.run([self.bench.cli, "--socket", self.bench.socket, *args], capture_output=True, text=True,
                              timeout=timeout, env=env, stdin=subprocess.DEVNULL)

    def wait(self, predicate, seconds, step=0.25):
        deadline = self.now() + seconds
        while True:
            value = predicate()
            if value or self.now() >= deadline:
                return value
            self.sleep(step)  # test harness: the gap between two reads of the app

    def topology(self):
        snap = self.rpc("snapshot.get")
        return (snap.get("topology") or {}) if isinstance(snap, dict) else {}

    def layout(self):
        return layout_of(self.topology())

    def windows(self):
        """`debug.window_list`'s visible main windows."""
        reply = self.rpc("debug.window_list")
        listed = reply.get("windows") if isinstance(reply, dict) else None
        return [w for w in listed or [] if w.get("kind") == "main" and w.get("visible")]

    def marks(self):
        reply = self.rpc("debug.timings")
        return (reply.get("launch_ms_since_process_start") or {}) if isinstance(reply, dict) else {}

    def alive(self):
        return self.bench.process is not None and self.bench.process.poll() is None

    # -- launches and ends
    def launch(self, **launch_args):
        """The case's first launch: a fresh state on the tag."""
        self.bench.launch(timeout=LAUNCH_TIMEOUT, **launch_args)
        journey.remember(self.bench)

    def relaunch(self, **launch_args):
        """Starts the app again on the tag's saved state; the daemon the last run left is adopted."""
        journey.relaunch(self.bench, timeout=LAUNCH_TIMEOUT, validate_host=False, **launch_args)

    def wait_exit(self, seconds=EXIT_TIMEOUT):
        try:
            self.bench.process.wait(seconds)
            return True
        except subprocess.TimeoutExpired:
            return False

    def quit(self):
        """Quit, keeping the sessions (the daemon keeps every terminal); the quit saves each window's picture."""
        self.action("quitKeepSessions")
        if not self.wait_exit():
            self.problems.append(f"the app did not quit within {EXIT_TIMEOUT:.0f} s of quitKeepSessions")
            self.bench.process.terminate()  # the PID this run started: SIGTERM is a quit too
            self.wait_exit(15)

    def kill(self):
        self.bench.process.kill()  # SIGKILL of the PID this run started: no handler runs
        self.wait_exit(20)

    def crash(self):
        self.rpc("debug.crash.app", {"kind": "segv"}, timeout=10)
        if not self.wait_exit(30):
            self.problems.append("debug.crash.app did not end the app")
            self.kill()

    # -- the daemon (cmux-tui), while the app is closed
    def tui(self, *args):
        """The bundled cmux-tui on the tag's daemon session (launch-connect-journey.py's Tag.tui_json)."""
        temp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
        env = dict(os.environ, CMUX_TUI_STATE_DIR=os.path.join(self.bench.state_root(), "tui"), TMPDIR=temp or "/tmp")
        env.pop("XDG_RUNTIME_DIR", None)
        binary = os.path.join(self.bench.app, "Contents/Resources/bin/cmux-tui")
        return subprocess.run([binary, "--session", f"cmux-app-{self.bench.tag}", "--json", *args], env=env,
                              capture_output=True, text=True, timeout=60)

    def daemon_socket(self):
        temp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
        for base in dict.fromkeys(p for p in (os.environ.get("TMPDIR"), temp, "/tmp") if p):
            found = sorted(glob.glob(os.path.join(base, "cmux-tui-*", f"cmux-app-{self.bench.tag}.sock")))
            if found:
                return found[0]
        return None

    def daemon(self, cmd, **fields):
        """One request on the tag's daemon socket (the CLI's path while the app is closed)."""
        path = self.daemon_socket()
        if not path:
            return {"error": "no daemon socket"}
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(30)
            sock.connect(path)
            stream = sock.makefile("rwb")
            stream.write((json.dumps({"id": 1, "cmd": cmd, **fields}) + "\n").encode())
            stream.flush()
            for raw in stream:
                reply = json.loads(raw)
                if reply.get("id") == 1:
                    return reply
        return {"error": "the daemon closed the connection"}

    # -- stills
    def stills(self, label, webviews):
        """Each visible main window's still into the case folder: [(path or None, problem or None)]."""
        out = []
        for index, window in enumerate(self.windows()):
            path = os.path.join(self.out, f"{label}-{index + 1}.png")
            reply = self.rpc("debug.window_snapshot", {"window": window.get("id"), "path": path, "webviews": webviews},
                             timeout=60)
            if not isinstance(reply, dict) or reply.get("error") or not os.path.exists(path):
                out.append((None, f"window {window.get('id')}: no still ({(reply or {}).get('error')})"))
            else:
                out.append((path, None))
        return out


def build_layout(run):
    """Two workspaces: the first split in three (right, then down), the second (SECOND_WORKSPACE) with one pane;
    the first one shown."""
    first = (run.wait(lambda: run.topology().get("workspaces"), 30) or [{}])[0]
    first_id = first.get("id")
    panes = [p for s in first.get("screens") or [] for p in s.get("panes") or []]
    if not first_id or not panes:
        raise RuntimeError("the first launch shows no workspace with a pane")
    run.action("splitRight", target=f"pane:{panes[0]['id']}")
    run.action("splitDown", target=f"pane:{panes[0]['id']}")

    def built():
        shown = next((w for w in run.topology().get("workspaces") or [] if w.get("id") == first_id), {})
        return sum(len(s.get("panes") or []) for s in shown.get("screens") or []) >= 3

    if not run.wait(built, 30):
        raise RuntimeError(f"the first workspace did not split in three: {run.layout()}")
    add_second_workspace(run)
    run.action("goToWorkspace", {"workspace": first_id})
    run.sleep(1.0)  # test harness: the shells draw their prompts before the app ends


def add_second_workspace(run):
    """SECOND_WORKSPACE, one pane, not shown: the workspace workspace-closed-while-closed closes."""
    run.cli("new-workspace", "--name", SECOND_WORKSPACE, "--focus", "false")
    if not run.wait(lambda: any(w[0] == SECOND_WORKSPACE for w in run.layout()["workspaces"]), 30):
        raise RuntimeError(f"new-workspace made no {SECOND_WORKSPACE!r}: {run.layout()}")


def place_window(run):
    """The first window centered on the last screen (debug.window_frame), where the test placement put it: no launch
    sets CMUX_NEXT_TEST_WINDOW_*, so the quit saves this frame and the relaunch opens there."""
    placed = run.rpc("debug.window_frame", {"screen": "last"})
    if not isinstance(placed, dict) or placed.get("error"):
        run.notes.append(f"debug.window_frame did not place the window ({placed})")
        return
    run.sleep(0.5)  # test harness: the window server places the window before the quit


# ---------------------------------------------------------------- the cases' steps

def end_quit(run):
    run.quit()


def end_kill(run):
    run.kill()


def end_crash(run):
    run.crash()


def end_crash_streak(run):
    """Three crashes in a row, each soon after its launch answered (FeatureSafeMode's crash streak)."""
    run.crash()
    for _ in range(2):
        run.relaunch()
        run.crash()


def end_quit_during_launch(run):
    """A quit, then a launch that gets SIGTERM 100 ms after its spawn (a requested quit, QuitSignal): it must end
    cleanly; the case's relaunch after it is the one checked."""
    run.quit()
    term = []

    def quit_soon(process):
        timer = threading.Timer(0.1, lambda: process.poll() is None and process.send_signal(signal.SIGTERM))
        timer.start()
        term.append(timer)

    try:
        run.relaunch(on_start=quit_soon)
    except bench_launch.LaunchError as error:
        run.notes.append(f"quit during launch: the launch ended before answering ({error.reason})")
    finally:
        for timer in term:
            timer.join()
    if run.bench.process.poll() is None and not run.wait_exit(20):
        run.problems.append("a quit 100 ms after launch did not end the app within 20 s")
        run.kill()
    code = run.bench.process.returncode
    if code not in (0, -signal.SIGTERM):
        run.problems.append(f"the app quit during launch ended with {code} (a crash?)")


def flip_appearance(run):
    """The app's own appearance set opposite to the system's (debug.appearance) for the quit's picture; the relaunch
    has no override, so it opens in the other appearance."""
    effective = (run.rpc("debug.appearance", {}) or {}).get("effective")
    if effective not in ("light", "dark"):
        raise RuntimeError(f"debug.appearance gave no effective appearance ({effective!r})")
    run.rpc("debug.appearance", {"mode": "light" if effective == "dark" else "dark"})
    run.sleep(1.0)  # test harness: the theme applies before the quit


def change_theme(run):
    """Another terminal background in the launch's Ghostty config (BenchApp's scratch file)."""
    with open(os.path.join(run.bench.scratch, "ghostty"), "w") as handle:
        handle.write("background = #1e3a5f\nforeground = #f2f2f2\n")


def open_incognito(run):
    """What must come back is the layout before the incognito window: the kill leaves it as a leftover."""
    run.expected = run.layout()
    windows = run.expected["windows"]
    run.action("newIncognitoWindow")
    if not run.wait(lambda: run.layout()["windows"] > windows, 20):
        raise RuntimeError("newIncognitoWindow opened no window")


def width_of(rect):
    """The width of a `debug.window_frame` rect ([x, y, w, h], DebugLayers.rect), else None."""
    return rect[2] if isinstance(rect, list) and len(rect) == 4 else None


def height_of(rect):
    return rect[3] if isinstance(rect, list) and len(rect) == 4 else None


def screens(run):
    """[(NSScreen index, backing scale, screen frame)] read by moving the window to each screen (debug.window_frame)
    and taking its still (pixels over points); the window ends on the last screen read."""
    found = []
    for index in range(8):
        moved = run.rpc("debug.window_frame", {"screen": index})
        if not isinstance(moved, dict) or moved.get("error"):
            break
        path = os.path.join(run.out, f"screen-{index}.png")
        shot = run.rpc("debug.window_snapshot", {"path": path, "webviews": False})
        width = width_of(moved.get("frame"))
        scale = round(shot.get("width", 0) / width, 2) if isinstance(shot, dict) and width else None
        found.append((index, scale, moved.get("screen_frame")))
    return found


def pictures_folder(run):
    return os.path.join(run.bench.state_root(), PICTURES_FOLDER)


def other_scale_screen(run):
    """The saved picture from a screen of one backing scale, the relaunch's window on a screen of another: a quit on
    the first screen, its pictures kept aside, a relaunch that moves the window to the other screen; the case's quit
    then saves that frame, and ``restore_first_pictures`` puts the first screen's pictures back while the app is
    closed."""
    found = screens(run)
    if not found:
        raise RuntimeError("debug.window_frame moved the window to no screen")
    first = found[0]
    other = next((s for s in found if s[1] and first[1] and s[1] != first[1]), None)
    if not other:
        raise Skip(f"no display of another scale ({', '.join(f'screen {i}: {s}x' for i, s, _ in found)})")
    run.rpc("debug.window_frame", {"screen": first[0]})
    run.sleep(0.5)  # test harness: the window server places the window before the quit
    run.quit()
    folder = pictures_folder(run)
    if not os.path.isdir(folder):
        raise RuntimeError(f"the quit on screen {first[0]} saved no pictures ({folder} missing)")
    run.pictures_aside = os.path.join(run.out, "pictures-first-screen")
    shutil.rmtree(run.pictures_aside, ignore_errors=True)
    shutil.copytree(folder, run.pictures_aside)
    run.relaunch()
    moved = run.rpc("debug.window_frame", {"screen": other[0]})
    if not isinstance(moved, dict) or moved.get("error"):
        raise RuntimeError(f"debug.window_frame could not move the window to screen {other[0]} ({moved})")
    run.sleep(0.5)  # test harness: the window server places the window before the quit
    run.notes.append(f"the picture saved on screen {first[0]} ({first[1]}x); "
                     f"relaunch on screen {other[0]} ({other[1]}x)")


def restore_first_pictures(run):
    """While the app is closed: the first screen's pictures replace those the quit on the other screen saved."""
    folder = pictures_folder(run)
    shutil.rmtree(folder, ignore_errors=True)
    shutil.copytree(run.pictures_aside, folder)


def three_windows_two_displays(run):
    """Three windows, the third on the second display; their frames must come back."""
    if len(screens(run)) < 2:
        raise Skip("one display")
    run.rpc("debug.window_frame", {"screen": 0})
    for _ in range(2):
        before = run.layout()["windows"]
        run.action("newWindow")
        if not run.wait(lambda: run.layout()["windows"] > before, 20):
            raise RuntimeError("newWindow opened no window")
    third = (run.topology().get("windows") or [{}])[-1].get("key")
    moved = run.rpc("debug.window_frame", {"window": third, "screen": 1})
    if not isinstance(moved, dict) or moved.get("error"):
        raise RuntimeError(f"debug.window_frame could not move a window to the second display ({moved})")
    run.sleep(1.0)  # test harness: the window server places the window
    run.frames_before = window_frames(run)


def window_frames(run):
    return sorted((round(f["x"]), round(f["y"]), round(f["width"]), round(f["height"]))
                  for f in (w.get("frame") for w in run.windows()) if f)


def frames_kept(run):
    after = window_frames(run)
    if len(after) != len(run.frames_before) or any(
            max(abs(a - b) for a, b in zip(x, y)) > 4 for x, y in zip(sorted(after), sorted(run.frames_before))):
        return [f"window frames {after}, saved {run.frames_before}"]
    return []


def full_screen(run):
    run.action("toggleFullScreen")
    run.sleep(2.0)  # test harness: the full-screen transition ends before the check
    current = run.rpc("debug.window_frame", {})
    current = current if isinstance(current, dict) else {}
    frame, whole = current.get("frame"), current.get("screen_frame")
    size, screen = (width_of(frame), height_of(frame)), (width_of(whole), height_of(whole))
    if None in size + screen or [round(v) for v in size] != [round(v) for v in screen]:
        raise Skip(f"the window did not enter full screen (frame {frame}, screen {whole})")


def close_second_workspace(run):
    """SECOND_WORKSPACE closed through the daemon while the app is closed."""
    listed = run.daemon("list-workspaces")
    workspaces = ((listed.get("data") or {}).get("workspaces")) or []
    target = next((w for w in workspaces if (w.get("name") or w.get("title")) == SECOND_WORKSPACE), None)
    if not target:
        raise RuntimeError(f"the daemon lists no workspace {SECOND_WORKSPACE!r} ({listed.get('error') or 'none'})")
    fields = {"key": target["key"]} if target.get("key") else {"workspace": target.get("id")}
    closed = run.daemon("close-workspace", end_terminals=True, **fields)
    if closed.get("error") or closed.get("ok") is False:
        raise RuntimeError(f"close-workspace: {closed}")
    run.closed.add(SECOND_WORKSPACE)


def stop_daemon(run):
    done = run.tui("server", "stop")
    if not run.wait(lambda: run.daemon_socket() is None or not bench_launch.socket_in_use(run.daemon_socket()), 15):
        raise RuntimeError(f"cmux-tui server stop left the daemon running (exit {done.returncode}: "
                           f"{(done.stdout + done.stderr).strip()[-300:]})")


def daemon_unavailable(run):
    """The daemon stopped and a daemon binary that exits at once (CMUX_NEXT_TUI_BIN, DaemonLauncher.resolveBinary)."""
    stop_daemon(run)
    stub = os.path.join(run.bench.scratch, "no-daemon")
    with open(stub, "w") as handle:
        handle.write("#!/bin/sh\nexit 1\n")
    os.chmod(stub, 0o755)
    run.bench.extra_env["CMUX_NEXT_TUI_BIN"] = stub


def daemon_stayed_away(run):
    state = run.topology().get("daemon_state")
    return [f"the daemon connected ({state}): the stand-in binary was not used"] if state == "connected" else []


def close_all_windows(run):
    for _ in range(6):
        count = len(run.windows())
        if not count:
            return
        run.action("closeWindow")
        run.wait(lambda: len(run.windows()) < count, 10)
    raise RuntimeError(f"closeWindow left {len(run.windows())} windows")


def startup_completed(run):
    if not run.wait(lambda: "startup_complete" in run.marks(), 15):
        return ["startup never completed (no startup_complete mark)"]
    return []


def open_url_on_start(run):
    """Right after the spawn, once LaunchServices knows the process: `open -g -a <app> URL` (a URL open)."""
    run.tabs_before = run.expected["tabs"]

    def opener(process):
        def go():
            lsappinfo = shutil.which("lsappinfo")
            for _ in range(100):
                if not lsappinfo or subprocess.run([lsappinfo, "find", f"pid={process.pid}"], capture_output=True,
                                                   text=True).stdout.strip():
                    break
                time.sleep(0.1)  # test harness: LaunchServices registers the process
            done = subprocess.run(["open", "-g", "-a", run.bench.app, URL], capture_output=True, text=True)
            run.notes.append(f"open -g -a ... {URL}: exit {done.returncode} {done.stderr.strip()[-200:]}")
        thread = threading.Thread(target=go, daemon=True)
        thread.start()
        run.watchers.append(thread)
    return opener


def url_opened(run):
    if not run.wait(lambda: run.layout()["tabs"] > run.tabs_before, 20):
        return [f"the opened URL made no tab ({run.layout()['tabs']} tabs, {run.tabs_before} before)"]
    return []


def host_env(run):
    """The F2 Debug toggle on through the launch's own tunables file (child-crash-e2e.py's host arm)."""
    crash_e2e = chromium_crash_module()
    path = os.path.join(run.bench.scratch, "tunables.json")
    with open(path, "w") as handle:
        json.dump({"version": 1, "values": {crash_e2e.HOST_TOGGLE: True}}, handle)
    run.bench.extra_env[crash_e2e.TUNABLES_FILE] = path


def chromium_crash_module():
    return bench_launch.load_by_path("child_crash_e2e", os.path.join(HERE, "child-crash-e2e.py"))


def open_chromium_page(run):
    """A Chromium page in the shown workspace (the restored visible page), with F2's host on."""
    crash_e2e = chromium_crash_module()
    if crash_e2e.settle_host_state(run.bench, "on") != "on":
        raise Skip(f"{crash_e2e.HOST_FEATURE} is not on in this build")
    opened = run.action("openBrowser", {"url": PAGE_URL, "engine": "chromium"})
    if not opened.get("created"):
        raise RuntimeError(f"openBrowser opened no Chromium tab ({opened})")
    run.sleep(2.0)  # test harness: the page loads before the quit
    run.expected = run.layout()


def kill_host_on_start(run):
    """During the relaunch: SIGKILL of the Chromium Host process (F2's browser process) once it runs."""
    crash_e2e = chromium_crash_module()
    def watcher(process):
        def go():
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and process.poll() is None:
                hosts = [p for p in crash_e2e.descendants(crash_e2e.read_ps(), process.pid).values()
                         if " Chromium Host" in p.command and crash_e2e.switch_value(p.command, "type") is None]
                if hosts:
                    os.kill(hosts[0].pid, signal.SIGKILL)
                    run.host_killed = hosts[0].pid
                    return
                time.sleep(0.02)  # test harness: the host spawns during launch
        thread = threading.Thread(target=go, daemon=True)
        thread.start()
        run.watchers.append(thread)
    return watcher


def host_kill_survived(run):
    for thread in run.watchers:
        thread.join(25)
    if run.host_killed is None:
        raise Skip("no Chromium Host process ran during the launch")
    if not run.alive():
        return [f"cmux ended after its Chromium Host ({run.host_killed}) was killed during launch"]
    reply = run.rpc("debug.key", {"key": "a"}, timeout=10)
    if not isinstance(reply, dict) or reply.get("error"):
        return [f"cmux does not answer debug.key after the host kill ({reply})"]
    return []


def safe_mode_note(run):
    run.notes.append(f"safe mode after the streak: {(run.bench.features or (None, None, None))[2]}")
    return []


# ---------------------------------------------------------------- the matrix

@dataclasses.dataclass(frozen=True)
class Case:
    name: str
    summary: str
    end: object = end_quit  # None: the fresh launch is the one checked
    picture: str = "any"  # shown | refused | not-shown | any (with the picture feature on)
    reasons: tuple = ()
    stale: tuple = ()  # with picture `shown`: the regions cut out of it (launch_picture_stale.<region>)
    layout: str = "same"
    before: object = None  # on the running app, before it ends
    between: object = None  # while the app is closed, before the relaunch
    on_start: object = None  # (run) -> a BenchApp on_start for the relaunch
    after: object = None  # (run) -> problems, once the relaunch answered
    config: dict = dataclasses.field(default_factory=dict)
    env: object = None  # (run) -> None: the launch env (BenchApp.extra_env) before the first launch
    ready: str = "debug.windows"
    needs_f2: bool = False


CASES = (
    Case("first-launch", "a new tag: no daemon, no saved state, no picture", end=None, picture="not-shown", layout="skip"),
    Case("warm", "quit keeping the sessions, relaunch: the control (the picture shows)", picture="shown"),
    Case("scale-change", "the relaunch opens on a display of another scale", picture="refused",
         reasons=("frame", "screen", "scale"), before=other_scale_screen, between=restore_first_pictures),
    Case("appearance-flip", "light and dark swapped since the quit", picture="refused", reasons=("appearance", "theme"),
         before=flip_appearance),
    Case("theme-change", "the terminal theme changed since the quit", picture="refused", reasons=("theme",),
         between=change_theme),
    Case("crash-recovery", "the last run crashed", end=end_crash, picture="refused", reasons=("crashRecovery",)),
    Case("crash-streak", "three crashes in a row (safe mode may turn the picture off: never shown)",
         end=end_crash_streak, picture="not-shown", after=safe_mode_note),
    Case("incognito-leftovers", "the last run was killed with an incognito window open", end=end_kill,
         picture="refused", reasons=("incognitoLeftovers",), before=open_incognito),
    Case("three-windows-two-displays", "three windows, one on the second display",
         before=three_windows_two_displays, after=frames_kept),
    Case("full-screen", "the window was full screen at the quit", picture="not-shown", before=full_screen),
    Case("translucent", "a translucent window (backgroundOpacity 0.6): the picture shows whole over the live material",
         config={"appearance": {"backgroundOpacity": 0.6}}, picture="shown"),
    Case("workspace-closed-while-closed", f"{SECOND_WORKSPACE} closed through the daemon while the app was closed "
         "(its saved picture lists it: the sidebar is cut out, the content shows)", picture="shown", stale=("sidebar",),
         between=close_second_workspace),
    Case("daemon-cold", "the daemon stopped too: the app starts it on the saved registry", between=stop_daemon),
    Case("daemon-unavailable", "no daemon can start", layout="skip", between=daemon_unavailable,
         after=daemon_stayed_away),
    Case("no-window", "every window closed before the quit", picture="not-shown", layout="skip",
         before=close_all_windows, after=startup_completed, ready="debug.window_list"),
    Case("url-open", "a URL opened at the app while it launches", layout="contains", on_start=open_url_on_start,
         after=url_opened),
    Case("quit-during-launch", "a quit 100 ms into a launch, then a launch", end=end_quit_during_launch),
    Case("cef-host-kill", "F2: the Chromium Host killed during the launch of a restored Chromium page",
         before=open_chromium_page, on_start=kill_host_on_start, after=host_kill_survived, env=host_env,
         needs_f2=True),
)
CASE = {case.name: case for case in CASES}
RELAUNCH_CASES = tuple(case.name for case in CASES if case.end is not None)


def select(names):
    """The cases `names` (a comma list, or `all`) in matrix order; ValueError names an unknown one."""
    if names in (None, "", "all"):
        return list(CASES)
    wanted = [n.strip() for n in names.split(",") if n.strip()]
    unknown = [n for n in wanted if n not in CASE]
    if unknown:
        raise ValueError(f"unknown matrix case {', '.join(unknown)}; cases: {', '.join(CASE)}")
    return [case for case in CASES if case.name in wanted]


def expected_picture(case, picture_on):
    """The case's expectation with the picture feature on; with it off no launch shows a picture."""
    return case.picture if picture_on else "not-shown"


def prepare_bench(bench, case, picture=True):
    """The case's launch settings on `bench` before its first launch: the picture feature, the cmux.json additions,
    and no test placement (CMUX_NEXT_TEST_WINDOW_*: LaunchSnapshotWindow.open shows no picture under one;
    ``place_window`` places the window instead)."""
    bench.local_features = {**(bench.local_features or {}), PICTURE_FEATURE: bool(picture)}
    config = copy.deepcopy(bench.config if bench.config else BASE_CONFIG)
    for key, value in case.config.items():
        config[key] = {**(config.get(key) or {}), **value}
    bench.config = config
    bench.window = bench.screen = None


def relaunch_case(run, case):
    """From a running app holding the layout: the case's before, end, between and relaunch. A case that does not end
    with a quit gets a quit and a relaunch first: the saved picture its relaunch refuses is on disk."""
    place_window(run)
    if case.end is not end_quit and case.end is not end_quit_during_launch:
        run.quit()
        run.relaunch()
    if case.before:
        case.before(run)
    if run.expected is None:
        run.expected = run.layout()
    case.end(run)
    if case.between:
        case.between(run)
    launch_args = {"ready": case.ready}
    if case.on_start:
        launch_args["on_start"] = case.on_start(run)
    run.relaunch(**launch_args)


def loaded_layout(run):
    layout = run.layout()
    return layout if layout["loaded"] else None


def first_look(run):
    """The windows as the relaunch first answers: (monotonic time, [(still path, problem)], ``layout_of`` the
    topology then: the model the first frame draws)."""
    return run.now(), run.stills("first", webviews=False), run.layout()


def verdict(run, case, first, skip=None):
    """The case's row: PASS when nothing went wrong, FAIL with the problems, SKIP with `skip` (or a Skip an after
    check raises)."""
    at, shots, first_layout = first
    problems = list(run.problems)
    if case.ready == "debug.windows" and not shots:
        problems.append("the relaunch showed no window")
    problems += [problem for _, problem in shots if problem]
    problems += [p for p in (blank_problem(path) for path, _ in shots if path) if p]
    problems += first_frame_problems(run.expected, first_layout, case.layout, run.closed)
    if case.layout != "skip":
        got = run.wait(lambda: loaded_layout(run), LOADED_TIMEOUT) or run.layout()
        problems += layout_problems(run.expected, got, case.layout, run.closed)
    left = LIVE_LOOK_S - (run.now() - at)
    if left > 0:
        run.sleep(left)  # test harness: the second still comes after the picture's bound
    live = run.stills("live", webviews=True)
    problems += [problem for _, problem in live if problem]
    problems += [f"2.5 s after the first frame: {p}" for p in (blank_problem(path) for path, _ in live if path) if p]
    marks = run.marks()
    problems += picture_problems(marks, expected_picture(case, run.picture), case.reasons, case.stale)
    problems += stale_problems(marks)
    if case.after:
        try:
            problems += case.after(run)
        except Skip as reason:
            skip = str(reason)
    if not run.alive():
        problems.append(f"the app ended (exit {run.bench.process.returncode if run.bench.process else None})")
    return {"case": case.name, "summary": case.summary, "result": result_of(problems, skip),
            "screenshot": next((path for path, _ in shots if path), None),
            "screenshots": [path for path, _ in shots + live if path], "problems": problems, "skip": skip,
            "first_frame_layout": first_layout,
            "picture": {"expected": expected_picture(case, run.picture), "reasons": list(case.reasons),
                        "stale": list(case.stale),
                        "marks": {k: v for k, v in marks.items() if k.startswith("launch_picture")}},
            "notes": run.notes}


def run_case(run, case):
    """One case on `run`'s tag (a fresh state): its row. The tag's app and daemons are ended either way."""
    def row(result, problems=(), skip=None):
        return {"case": case.name, "summary": case.summary, "result": result, "screenshot": None, "screenshots": [],
                "problems": list(problems), "skip": skip, "picture": None, "notes": run.notes}

    if case.needs_f2 and not run.f2:
        return row(SKIP, skip="F2 off: pass --f2 for the Chromium Host case")
    try:
        if case.env:
            case.env(run)
        run.launch()
        if case.end is None:
            run.expected = run.layout()
            return verdict(run, case, first_look(run))
        build_layout(run)
        relaunch_case(run, case)
        return verdict(run, case, first_look(run))
    except Skip as reason:
        return row(SKIP, skip=str(reason))
    except CASE_ERRORS as error:  # any error is this case's FAIL row, and the matrix goes on
        return row(FAIL, run.problems + [harness_problem(error)])
    finally:
        run.bench.stop()


# What a case may raise: any Exception, and LaunchError, a SystemExit (bench_launch.py).
CASE_ERRORS = (Exception, bench_launch.LaunchError)


def harness_problem(error):
    """The FAIL row's problem for an error a case raised: a launch that did not come up, else a harness defect."""
    if isinstance(error, bench_launch.LaunchError):
        return f"a launch did not come up: {error.reason}: {(error.report or {}).get('detail', '')}"
    if isinstance(error, (RuntimeError, OSError, subprocess.SubprocessError, ValueError)):
        return f"harness: {error}"
    return f"harness: {type(error).__name__}: {error}"


def error_row(case, run, error):
    """A FAIL row for `error` raised outside ``run_case`` (restore-trace.py's --case path)."""
    return {"case": case.name, "summary": case.summary, "result": FAIL, "screenshot": None, "screenshots": [],
            "problems": list(run.problems) + [harness_problem(error)], "skip": None, "picture": None,
            "notes": run.notes}


def write_report(out, app, picture, f2, rows):
    report = os.path.join(out, "launch-matrix.json")
    with open(report, "w") as handle:
        json.dump({"app": app, "picture": picture, "f2": f2, "cases": rows}, handle, indent=1)
    return report


def run_matrix(app, names, out, picture=True, f2=False, session="light", bench_app=bench_launch.BenchApp, log=print):
    """Every selected case on its own fresh state of `app`'s tag; writes `<out>/launch-matrix.json` and returns the
    rows."""
    rows = []
    for case in select(names):
        folder = os.path.join(out, case.name)
        bench = bench_app(app, out=folder, config={}, window=None, screen=None, log_name="app.log",
                          perf_session=session)
        prepare_bench(bench, case, picture)
        log(f"launch matrix: {case.name}: {case.summary}")
        rows.append(run_case(Run(bench, folder, picture=picture, f2=f2, log=log), case))
        log(line(rows[-1]))
        write_report(out, app, picture, f2, rows)  # after each case: a run stopped later keeps these rows
    report = write_report(out, app, picture, f2, rows)
    counts = collections.Counter(row["result"] for row in rows)
    log(f"launch matrix: {counts[PASS]} PASS, {counts[FAIL]} FAIL, {counts[SKIP]} SKIP; {report}")
    return rows
