#!/usr/bin/env python3
"""Launch to first interaction (startup-tti): how long after its process starts cmux NEXT takes a typed key, with a
realistic session list, cold and warm.

Leo, 2026-11-19: "startup times and time to first interaction".

    launch_tti_check.py (--app APP | --dmg DMG) [--workspaces 120] [--chats 6] [--plan KIND:FRONT,...]
                        [--load none|busy] [--launch open|exec] [--out DIR]

On a fresh home (fresh_home_launch_smoke.py launches it, as the nightly gate does) it seeds the session list: the
relaunch-restore pair (relaunch_restore_check.seed: `l5-a` with a terminal under 2,000 lines of scrollback, `l5-b`
with an agent chat on the acpmux test agent, one turn answered), then workspaces `tti-NNN` up to --workspaces in all,
--chats - 1 more of them with a chat of their own and every tenth with 500 lines in its terminal. Then each round of
--plan (KIND:FRONT, in order):

  FRONT    what the front window shows at the quit and so after the relaunch: `chat` (l5-b's chat tab, typed into
           its composer) or `terminal` (l5-a's terminal, typed into its shell's tty, which echoes).
  KIND     `cold_install`: the copy is deleted and copied again (ditto) from the one kept at the start, so the launch
           is the first exec of new files, as a fresh install; `cold_after_update`: a fresh copy after the updater's
           StagedUpdatePrewarm sequence, run in a staging folder that is then renamed into place (updated_copy, as
           nightly-fresh-launch.py's update arm): the launch after an update, of the same pre-warmed copy; `warm`:
           the same copy relaunched right after the quit (launch-ready.sh prerun=0); `warm60`: before it, one full run
           of the same copy that stays up 60 s after its window shows, then quits (launch-ready.sh prerun=60).

Each round is Quit and Keep Sessions, then the app started again with the run's environment, the typing probe on
(CMUX_NEXT_TYPING_PROBE, a release build's own key-to-echo timeline) and a fresh launch-marks pipe. From the start the
harness posts a key (`x`) to the process every KEY_EVERY_S (CGEventPostToPid) until the front accepts one (a
terminal key that reached the pty holds further keys for up to a second, so its echo closes the probe sample):

  chat       the app's launch mark `agent_pane.input_echoed`: the composer drew a key the person typed (the page's
             pane.inputEchoed). A build without that mark reads no chat number (`no_mark`: no page in its bundle posts
             pane.inputEchoed, decided once per run), never a harness time; the round fails nothing. A build that
             has the mark and does not post it within --settle fails the round.
  terminal   the typing probe's first complete row: a key that went through the app's terminal, reached the pty and
             whose echo the app presented (`contents_ms`); its `event_uptime_ns` and the process start in the same
             clock (CLOCK_UPTIME_RAW) put it on the launch marks' clock.

Every number is ms since the app's own process start (sysctl p_starttime), the clock of its launch marks:
first_frame_ms (`first_window_frame_committed`), main_ms (`main_start`), input_ms (the front took a key: the
interaction), split at `main` into premain_ms (the system's part: a new copy's policy check, dyld) and ours_ms (main
to the key taken), accepted_ms (terminal: the first key the app wrote toward the pty), and spawn_to_start_ms (the harness's
exec to the process start; a Dock click's own delta is not measured here). Keys are paced KEY_EVERY_S apart, so
a chat input_ms is late by at most that; the terminal's is the echo of the key that reached the pty, each key on its own clock. Each round also carries `stages`: the launch's startup stages from its marks
(premain, did_finish_launching, daemon_connected, first_window_shown, first_frame, webview_ready, first_chat_paint,
first_interaction; launch_stages.py), and the run's `stages` is each stage's median per front.
Each round prints `TTI-ROUND {json}`, the run prints `TTI {json}` with its verdict.
A round that leaves no app running (its launch failed, or the app exited) no longer ends the plan: the run ends any
instance of the copy still up, launches it once unmeasured until its socket answers (`TTI-RECOVER {json}`), and goes on
to the next round, at most MAX_RECOVERIES times. The failed round still fails the verdict.

Percentiles (startup-matrix, a fixed-slot harness like a device farm): a plan item KIND:FRONT*N runs N rounds of it
(`cold_install:terminal*20`). Before each launch the round waits up to --load-wait s for the Mac's 1-minute load per
core to fall to --max-load-per-core (LOAD_BOUND_PER_CORE) and records load_1m, cpus and load_per_core. The run prints
`TTI-PCT {json}`: per KIND_FRONT the nearest-rank p50 and p95 of input_ms over the rounds launched at or under the
bound, n, the rounds left out for load, and the load they ran at; a cell with under --min-quiet quiet measured rounds
reads `refused` with no p50/p95, so a loaded Mac never posts a number.
Exit 0 when every round measured its front.

Restart to first paint and to first input, three surfaces on one clock (Leo, 2026-11-22: "the speed i see on restarts
is terminal << chromium browser <<<<<<<< our [...] agent pane."). Every round reads first_paint_ms, its front's
PAINT_MARK (chat `agent_pane.painted`, terminal `first_terminal_frame`, browser `browser_pane.first_paint`), and the
terminal's content marks (first_terminal_content, first_terminal_content_applied, first_terminal_frame) whether or not
a key went in: a failed key probe fails the input number only. The `browser` front is a Chromium tab (workspace
`tti-browser`) on a static page this harness serves on 127.0.0.1; its input_ms is `browser_pane.input_ready` (the
page took keys) and no key is posted. A build without a front's marks reads `no_mark` for it (decided once per run
from the bundle), never a harness time, and fails nothing. The run then prints one `RESTART-FIRST-PAINT {json}` line
per front and kind (each number's median and every sample) and one `RESTART-FIRST-PAINT-RATIO {json}` per kind
(chat/terminal and browser/terminal, of the medians). --load busy runs one `yes > /dev/null` per core through each
measured launch (stopped when the round ends, and on any exit).

The measured launch goes through LaunchServices (`open -n`, activated, as a Dock click; the marks come through a
FIFO, CMUX_NEXT_LAUNCH_MARKS_PATH) so its window is key at its first frame: a plain exec from the harness left no
window key there on a fleet Mac (`terminal.probe_no_key_window`, both terminal rounds of cmux-ci step
37643b8028222260ca36ab63). --launch exec keeps the old exec; the row's `launch` says which ran.

--launch-delay-ms N is the bench's positive control (launch-tti.sh control=N): each measured launch gets
CMUX_NEXT_LAUNCH_TEST_DELAY_MS=N, so the app waits N ms before it makes any window; launch_tti_control.py compares
that run with a baseline one and fails the bench when its numbers did not move by about N.

A NIGHTLY is a Release build: only release control methods and the bundled CLI are used. Posting keys needs the
process to hold the PostEvent grant (CGPreflightPostEventAccess). A runner without it (`post_access: false`) types in
the app instead (`input: in_app`, every round row and the TTI line say which path ran, `posted` or `in_app`): the
launch has CMUX_NEXT_LAUNCH_TYPE_PROBE=1, so the app itself types one key into its key window at its first window
frame (LaunchTypeProbe, the probe scripts/measure/launch-ready.swift's `type` mode uses), and the terminal's
interaction is its launch marks `terminal_input_accepted` (accepted_ms) and `terminal_echo` (input_ms): the same
process start to the typed key taken. With no key window at that frame (a background runner's launch is never brought to the front) the
probe takes the front itself, as a Dock launch does, and the round's `probe_focus` says so (`app_inactive`,
`window_not_key`; `key` when a window was key). `terminal.probe_no_key_window` (no window could take keys) fails the
round's input number (its paint number stands). The app types that one key wherever its key window takes it, before a
chat page is up, so on the in_app path a chat round ends when the chat drew and fails nothing; the posted path's keys
time the chat, and a build whose chat pages do not post the composer's input mark reads `no_mark` for its input.

Every measured launch runs without CMUX_NEXT_NO_ACTIVATE (fresh_home_launch_smoke.fresh_env sets it for its own
launch): under it the app refuses every activation and no window ever takes key (WindowActivation orders them in
behind, NoActivateKeyboardGuard gives the front back), so no key, posted or the app's own, could reach a window.
"""
from __future__ import annotations

import csv
import ctypes
import datetime
import ctypes.util
import json
import math
import mmap
import os
import plistlib
import select
import shutil
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import relaunch_restore_check as rr  # noqa: E402  (its probe set, seed and launch, shared with L5)
import launch_stages  # noqa: E402  (the per-stage startup spans the app's launch-times.jsonl rows carry)

KEY_EVERY_S = 0.04
KEY_X = 7  # kVK_ANSI_X
KINDS = ("cold_install", "cold_after_update", "warm", "warm60")
FRONTS = ("chat", "terminal", "browser")
DEFAULT_FRONTS = ("chat", "terminal")  # the default plan's fronts; `browser` runs when a plan names it
DEFAULT_PLAN = ("cold_install:chat,cold_install:terminal,cold_after_update:chat,cold_after_update:terminal,"
                "warm:chat,warm:terminal,warm60:chat,warm60:terminal,"
                "cold_install:chat,cold_install:terminal,cold_after_update:chat,cold_after_update:terminal,"
                "warm:chat,warm:terminal,warm60:chat,warm60:terminal")
PRERUN_S = 60.0
# The load bound (startup-matrix, a fixed-slot harness): a round launches only once the Mac's 1-minute load per core is
# at most LOAD_BOUND_PER_CORE, waiting up to LOAD_WAIT_S for it; a round launched over it is kept but left out of the
# p50/p95, and a KIND_FRONT cell with fewer than MIN_QUIET_ROUNDS quiet rounds posts no number (`refused`).
LOAD_BOUND_PER_CORE = 0.5
LOAD_WAIT_S = 120.0
LOAD_POLL_S = 5.0
MIN_QUIET_ROUNDS = 5
INPUT_MARK_MESSAGE = b"pane.inputEchoed"  # what a page posts when its composer drew a typed key (the mark's source)
CHAT_MARK = "agent_pane.input_echoed"
TYPE_PROBE_VARIABLE = "CMUX_NEXT_LAUNCH_TYPE_PROBE"  # LaunchTypeProbe: the app types one key at its first window frame
LAUNCH_DELAY_VARIABLE = "CMUX_NEXT_LAUNCH_TEST_DELAY_MS"  # LaunchTestDelay: the app waits this long before any window
PROBE_TYPED, PROBE_NO_KEY_WINDOW = "terminal.probe_key_typed", "terminal.probe_no_key_window"
BROWSER_PAINT, BROWSER_INPUT = "browser_pane.first_paint", "browser_pane.input_ready"  # CEFLaunchMarks.swift
BROWSER_MARK_BYTES = BROWSER_PAINT.encode()  # a build whose executable names it has the browser marks
TERMINAL_PAINT_MARKS = ("first_terminal_content", "first_terminal_content_applied", "first_terminal_frame")
# Each front's restart-to-first-paint mark: the chat drew its kept session, the terminal presented its first frame,
# the browser tab presented its page's first frame.
PAINT_MARK = {"chat": "agent_pane.painted", "terminal": "first_terminal_frame", "browser": BROWSER_PAINT}
# LaunchTypeProbe found no key window at the first frame and took the front itself, as a Dock launch would: the app
# was not active (a background runner's launch), or it was and no window was key. The round's `probe_focus` names it.
PROBE_TOOK_FRONT = ("terminal.probe_app_inactive", "terminal.probe_window_not_key")
KEPT_MARKS = ("main_start", "first_window_frame_committed", "reveal.pane", "reveal.home", "agent_pane.painted",
              CHAT_MARK, "first_terminal_surface_created", *TERMINAL_PAINT_MARKS, "terminal_input_accepted",
              "terminal_echo", PROBE_TYPED, PROBE_NO_KEY_WINDOW, *PROBE_TOOK_FRONT, BROWSER_PAINT,
              BROWSER_INPUT,
              "agent_pane.launch_images_read", "agent_pane.launch_image_shown", "agent_pane.launch_image_missed",
              "agent_pane.launch_image_cleared", "launch_snapshot_shown", "window.restore_wait_end")
LOADS = ("none", "busy")
BROWSER_PAGE = (b"<!doctype html><html><head><meta charset=utf-8><title>tti page</title></head><body>"
                b"<h1>launch tti</h1><input id=q autofocus placeholder=type></body></html>")
# Every mark of the steps between the first frame and the chat drawn, kept too: Chromium's start (cef.*, its
# cef.step.* split), the page host (chromium_page.*), the page's own navigation and paint (first_page.*), the chat's
# handshake and paint (agent_pane.*) and Home (home.*). Without them a round says only that webview_ready or
# first_chat_paint was late, never which step (a warm-vs-update gap on 2026-11-23 could not be split from the logs).
# `terminal.first_key.<reading>`: what the app's terminal key hold read of the process's first key-down (hq#22681):
# `terminal_awaited` held it for the restored terminal; any other names why it did not.
# The daemon's own steps (daemon.prepare_start, daemon.spawned or daemon.reused, daemon.socket_connected): whether the
# launch kept the daemon that held the session or started a new one. hq run 45746889291's round 2 typed its key 1.2 s
# before daemon_connected and the key never reached the pty; these say which of the two that launch was.
FIRST_KEY_PREFIX = "terminal.first_key."
KEPT_MARK_PREFIXES = ("cef.", "chromium_page.", "first_page.", "agent_pane.", "home.", "reveal.", "after_open.",
                      "daemon.", FIRST_KEY_PREFIX)
KEPT_MARKS_MAX = 120  # a round's line stays small; the stage marks and KEPT_MARKS always fit first


def kept_marks(marks: dict) -> dict:
    """The marks a round's line carries: KEPT_MARKS and every stage mark, then each mark under KEPT_MARK_PREFIXES in
    launch order, at most KEPT_MARKS_MAX in all."""
    named = set(KEPT_MARKS) | set(launch_stages.MARKS)
    out = {k: marks[k] for k in marks if k in named}
    rest = sorted((k for k in marks if k not in named and k.startswith(KEPT_MARK_PREFIXES)),
                  key=lambda k: (_num(marks[k]) is None, _num(marks[k]) or 0.0, k))
    for k in rest[:max(0, KEPT_MARKS_MAX - len(out))]:
        out[k] = marks[k]
    return out


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


# ---- clocks ---------------------------------------------------------------------------------

def uptime_ns() -> int:
    return time.clock_gettime_ns(getattr(time, "CLOCK_UPTIME_RAW", time.CLOCK_MONOTONIC))


def process_start_uptime_ns(pid: int) -> int | None:
    """The process's start (sysctl KERN_PROC_PID p_starttime, the clock LaunchTimesRecorder.processStart reads) on
    CLOCK_UPTIME_RAW, the clock of NSEvent timestamps and the typing probe; None off macOS or on a failed read."""
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    mib = (ctypes.c_int * 4)(1, 14, 1, pid)  # CTL_KERN, KERN_PROC, KERN_PROC_PID
    buf = ctypes.create_string_buffer(1024)
    size = ctypes.c_size_t(len(buf))
    if libc.sysctl(mib, 4, buf, ctypes.byref(size), None, ctypes.c_size_t(0)) != 0 or size.value < 16:
        return None
    sec = int.from_bytes(buf.raw[0:8], "little", signed=True)
    usec = int.from_bytes(buf.raw[8:12], "little", signed=True)
    if sec <= 0:
        return None
    wall_ns = sec * 1_000_000_000 + usec * 1000
    return wall_ns - (time.time_ns() - uptime_ns())


# ---- keys -----------------------------------------------------------------------------------

class Keys:
    """CGEventPostToPid of one key (down and up) through CoreGraphics; `access` is CGPreflightPostEventAccess."""

    def __init__(self):
        self.cg = None
        self.access = False
        try:
            cg = ctypes.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
            cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
            cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
            cg.CGEventPostToPid.argtypes = [ctypes.c_int, ctypes.c_void_p]
            cg.CFRelease.argtypes = [ctypes.c_void_p]
            cg.CGPreflightPostEventAccess.restype = ctypes.c_bool
            self.cg = cg
            self.access = bool(cg.CGPreflightPostEventAccess())
        except (OSError, AttributeError) as error:
            log(f"CoreGraphics not loaded: {error}")

    def post(self, pid: int, code: int = KEY_X) -> None:
        for down in (True, False):
            event = self.cg.CGEventCreateKeyboardEvent(None, code, down)
            if event:
                self.cg.CGEventPostToPid(pid, event)
                self.cg.CFRelease(event)


NO_ACTIVATE_VARIABLE = "CMUX_NEXT_NO_ACTIVATE"


def interactive_env(env: dict) -> dict:
    """The run's environment without CMUX_NEXT_NO_ACTIVATE, for every launch it times: a person's launch activates
    the app and its window takes key; under the variable none ever does, so a key could reach no window."""
    return {k: v for k, v in env.items() if k != NO_ACTIVATE_VARIABLE}


def activate(pid: int) -> None:
    """Bring the app to the front without waiting (a posted key goes to its key window)."""
    script = (f"ObjC.import('AppKit'); var a = $.NSRunningApplication.runningApplicationWithProcessIdentifier({pid}); "
              "if (a) { a.activateWithOptions(3) }")
    try:
        subprocess.Popen(["/usr/bin/osascript", "-l", "JavaScript", "-e", script],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


class Load:
    """--load busy: one `yes > /dev/null` per core while a measured launch runs; stop() ends them (also at exit)."""

    def __init__(self, kind: str, cores: int | None = None):
        self.kind, self.cores = kind, cores or os.cpu_count() or 1
        self.procs: list[subprocess.Popen] = []
        import atexit
        atexit.register(self.stop)

    def start(self) -> None:
        if self.kind != "busy" or self.procs:
            return
        for _ in range(self.cores):
            self.procs.append(subprocess.Popen(["yes"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))

    def stop(self) -> None:
        procs, self.procs = self.procs, []
        for proc in procs:
            proc.kill()
        for proc in procs:
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass


class Launched:
    """A process LaunchServices started (not this one's child): the part of Popen a round uses."""

    def __init__(self, pid: int):
        self.pid = pid

    def poll(self):
        try:
            os.kill(self.pid, 0)
            return None
        except ProcessLookupError:
            return "ended"
        except PermissionError:
            return None

    def wait(self, timeout: float | None = None):
        end = time.monotonic() + (timeout if timeout is not None else 1e9)
        while self.poll() is None:
            if time.monotonic() > end:
                raise subprocess.TimeoutExpired(f"pid {self.pid}", timeout)
            time.sleep(0.05)
        return self.poll()

    def kill(self) -> None:
        try:
            os.kill(self.pid, 9)
        except OSError:
            pass


def executable_paths(executable: Path) -> set[str]:
    """The paths ps may name EXECUTABLE by: as given and resolved. LaunchServices starts a bundle at its resolved path,
    so an app copied under /tmp runs as /private/tmp/... (pure but for the resolve)."""
    return {str(executable), os.path.realpath(executable)}


def pids_running(ps_out: str, paths: set[str]) -> set[int]:
    """Pids in `ps -axo pid=,comm=` output PS_OUT whose executable is one of PATHS (pure)."""
    pids = set()
    for line in ps_out.splitlines():
        pid, _, comm = line.strip().partition(" ")
        if comm.strip() in paths and pid.isdigit():
            pids.add(int(pid))
    return pids


def running_pids(executable: Path) -> set[int]:
    """Pids whose executable is EXECUTABLE (ps comm is the full path on macOS), under either of its paths."""
    try:
        out = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return set()
    return pids_running(out, executable_paths(executable))


def open_args(app: Path, env: dict, fifo: Path, log_path: Path) -> list[str]:
    """`open` for a new, activated instance of APP with ENV (each variable as --env) and the marks FIFO (pure)."""
    full = {**env, "CMUX_NEXT_LAUNCH_MARKS_PATH": str(fifo)}
    full.pop("CMUX_NEXT_LAUNCH_MARKS_FD", None)
    argv = ["/usr/bin/open", "-n", "-a", str(app)]
    for key in sorted(full):
        argv += ["--env", f"{key}={full[key]}"]
    return argv + ["--stdout", str(log_path), "--stderr", str(log_path), "--args", "-ApplePersistenceIgnoreState", "YES"]


def ls_launch(app: Path, env: dict, out_log: Path) -> tuple[Launched, int]:
    """APP started through LaunchServices, activated as a Dock click starts it, its marks through a FIFO: (process,
    the FIFO's read end). Raises RuntimeError when `open` fails or no new process shows within 15 s."""
    import fresh_home_launch_smoke as smoke
    _, name = smoke.bundle_info(app)
    executable = app / "Contents" / "MacOS" / name
    fifo = out_log.parent / "tti-marks.fifo"
    fifo.unlink(missing_ok=True)
    os.mkfifo(fifo, 0o600)
    fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)  # a reader first, so the app's nonblocking open finds one
    before = running_pids(executable)
    done = subprocess.run(open_args(app, env, fifo, out_log), capture_output=True, text=True, timeout=30)
    if done.returncode != 0:
        os.close(fd)
        raise RuntimeError(f"open: {(done.stdout + done.stderr).strip()[-300:] or done.returncode}")
    pid = None
    end = time.monotonic() + 15
    while pid is None and time.monotonic() < end:
        new = running_pids(executable) - before
        pid = min(new) if new else None
        if pid is None:
            time.sleep(0.01)
    if pid is None:
        os.close(fd)
        raise RuntimeError(f"open returned but no new process of the app showed within 15 s (looked for {sorted(executable_paths(executable))})")
    return Launched(pid), fd


def serve_page() -> str:
    """A static page on 127.0.0.1 (a thread of this process, for the run): its URL."""
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class Page(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(BROWSER_PAGE)))
            self.end_headers()
            self.wfile.write(BROWSER_PAGE)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/tti"


def seed_browser(inst: rr.Instance, made: dict, url: str) -> None:
    """Workspace `tti-browser` with a Chromium tab on URL; records browser_workspace and browser_tab in MADE."""
    ws = rr.unwrap(inst.cmux("workspace", "create", "--name", "tti-browser", timeout=30))
    if not isinstance(ws, dict) or not ws.get("workspace_id"):
        raise RuntimeError(f"workspace create tti-browser: {json.dumps(ws)[:300]}")
    args = ["tab", "create", "browser", "--url", url, "--workspace", ws["workspace_id"]]
    tab = rr.unwrap(inst.cmux(*args, *(["--pane", ws["pane_id"]] if ws.get("pane_id") else []), timeout=30))
    if not isinstance(tab, dict) or not tab.get("tab_id"):
        raise RuntimeError(f"tab create browser: {json.dumps(tab)[:300]}")
    made.update(browser_workspace=ws["workspace_id"], browser_tab=tab["tab_id"])


def browser_fronted(shown: list[dict]) -> bool:
    """`shown` (rr.front()) has tti-browser on its browser tab in a visible window (pure)."""
    return any(window.get("workspace") == "tti-browser"
               and any("browser" in str(t.get("kind") or "") for t in window.get("selected") or [])
               for window in shown)


def put_front(inst: rr.Instance, which: str, made: dict) -> str | None:
    """The round's front in the front window before the quit; None, or why it failed."""
    if which != "browser":
        return rr.put_front(inst, which, made)
    ws, tab = made.get("browser_workspace"), made.get("browser_tab")
    if not (ws and tab):
        return "no browser tab recorded at seed"
    for step in (("workspace", ws, "focus"), ("tab", tab, "focus")):
        answer = inst.cmux(*step)
        if isinstance(answer, dict) and answer.get("error"):
            return f"putting browser in front failed: {answer['error']}"
    if not rr.wait(lambda: browser_fronted(rr.front(inst.topology())), 10, 0.1):
        return f"browser never showed in the front window: {json.dumps(rr.front(inst.topology()))[:300]}"
    return None


def bundle_has_browser_mark(app: Path) -> bool:
    """Whether the app's executables name the browser pane's launch marks (read once per run)."""
    macos = app / "Contents" / "MacOS"
    for path in (macos.iterdir() if macos.is_dir() else ()):
        try:
            with open(path, "rb") as handle, mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
                if mapped.find(BROWSER_MARK_BYTES) >= 0:
                    return True
        except (OSError, ValueError):
            continue
    return False


# ---- the typing probe -----------------------------------------------------------------------

def load_1m() -> float | None:
    try:
        return round(os.getloadavg()[0], 2)
    except OSError:
        return None


def per_core(load: float | None, cpus: int | None = None) -> float | None:
    """The 1-minute load over this Mac's CPU count: the one load figure that compares across Macs of 8 to 14 cores."""
    cpus = cpus if cpus is not None else os.cpu_count()
    return round(load / cpus, 3) if load is not None and cpus else None


def wait_for_quiet(bound: float, wait_s: float) -> tuple[float | None, float]:
    """A fixed slot, as a device farm takes one: before a launch, wait up to wait_s for the load per core to fall to
    bound (checked every LOAD_POLL_S). Returns the load per core at the launch and the seconds waited."""
    started = time.monotonic()
    while True:
        load = per_core(load_1m())
        if load is None or load <= bound or time.monotonic() - started >= wait_s:
            return load, round(time.monotonic() - started, 1)
        time.sleep(LOAD_POLL_S)


def nearest_rank(values: list[float], pct: float) -> float | None:
    """The pct percentile by nearest rank (no interpolation): with N=20, p50 is the 10th value and p95 the 19th."""
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, min(len(ordered) - 1, math.ceil(pct / 100 * len(ordered)) - 1))]


def percentiles(rounds: list[dict], bound: float, min_quiet: int) -> dict:
    """Per KIND_FRONT: p50 and p95 of input_ms over the rounds launched at or under `bound` load per core, with n, the
    rounds left out for load (over_load) and the load they ran at. A cell with fewer than min_quiet quiet measured
    rounds is `refused` (its p50/p95 None): a number from a loaded Mac is not posted."""
    out: dict = {}
    for kind in KINDS:
        for which in FRONTS:
            mine = [r for r in rounds if r.get("kind") == kind and r.get("front") == which]
            if not mine:
                continue
            # A --load busy round ran under load by design (restart-first-paint's busy column), never a quiet one.
            over = [r for r in mine if r.get("load") == "busy"
                    or ((lpc := _num(r.get("load_per_core"))) is not None and lpc > bound)]
            quiet = [r for r in mine if r not in over]
            times = [float(r["input_ms"]) for r in quiet if isinstance(r.get("input_ms"), (int, float))]
            loads = [float(r["load_1m"]) for r in quiet if isinstance(r.get("load_1m"), (int, float))]
            lpcs = [float(r["load_per_core"]) for r in quiet if isinstance(r.get("load_per_core"), (int, float))]
            refused = len(times) < min_quiet
            out[f"{kind}_{which}"] = {
                "n": len(times), "rounds": len(mine), "over_load": len(over), "unmeasured": len(quiet) - len(times),
                "p50_ms": None if refused else nearest_rank(times, 50),
                "p95_ms": None if refused else nearest_rank(times, 95),
                "load_1m_p50": nearest_rank(loads, 50), "load_1m_max": max(loads) if loads else None,
                "load_per_core_max": max(lpcs) if lpcs else None, "cpus": os.cpu_count(),
                "load_bound_per_core": bound, "min_quiet": min_quiet,
                **({"refused": f"{len(times)} quiet measured rounds of {len(mine)}, under {min_quiet}"}
                   if refused else {})}
    return out


def _num(value) -> float | None:
    try:
        return float(value) if value not in (None, "") else None
    except ValueError:
        return None


def probe_rows(path: Path) -> list[dict]:
    try:
        with open(path, newline="") as handle:
            return list(csv.DictReader(handle))
    except OSError:
        return []


def terminal_reading(rows: list[dict], start_ns: int | None) -> dict:
    """{accepted_ms, input_ms} on the launch clock from the typing probe's rows: accepted, the first key the app wrote
    toward the pty (socket_submit_ms or io_write_ms); input, the first complete row's echo frame (contents_ms)."""
    out = {"accepted_ms": None, "input_ms": None}
    if start_ns is None:
        return out
    for row in rows:
        event = _num(row.get("event_uptime_ns"))
        if event is None:
            continue
        at = (event - start_ns) / 1e6
        sent = _num(row.get("socket_submit_ms")) or _num(row.get("io_write_ms"))
        if out["accepted_ms"] is None and sent is not None:
            out["accepted_ms"] = round(at + sent, 1)
        shown = _num(row.get("contents_ms"))
        if str(row.get("complete")).lower() in ("1", "true", "yes") and shown is not None:
            out["input_ms"] = round(at + shown, 1)
            break
    return out


def input_path(post_access: bool, chosen: str = "auto") -> str:
    """`posted` when this process may post keys (the harness types), else `in_app` (the app's LaunchTypeProbe types);
    --input posted or in_app picks one whatever the grant (posted without it fails every round, as before)."""
    if chosen in ("posted", "in_app"):
        return chosen
    return "posted" if post_access else "in_app"


def launch_env(env: dict, probe: Path, path: str, delay_ms: int = 0) -> dict:
    """The measured launch's environment: the typing probe always, the app's own first-frame key on the in_app path,
    and with `delay_ms` the positive control's known wait before the first window (LaunchTestDelay)."""
    out = {**env, "CMUX_NEXT_TYPING_PROBE": str(probe)}
    if path == "in_app":
        out[TYPE_PROBE_VARIABLE] = "1"
    if delay_ms > 0:
        out[LAUNCH_DELAY_VARIABLE] = str(delay_ms)
    return out


def in_app_terminal_reading(marks: dict) -> dict:
    """{accepted_ms, input_ms} from the launch marks on the in_app path: the key LaunchTypeProbe typed left the app for
    the restored terminal's pty (terminal_input_accepted) and its echo came back (terminal_echo); ms since process
    start, as launch-ready.swift's type mode reads them."""
    return {"accepted_ms": marks.get("terminal_input_accepted"), "input_ms": marks.get("terminal_echo")}


def probe_focus(marks: dict) -> str | None:
    """How the in-app key found its window (pure): `key` (a window was key at the first frame), `app_inactive` or
    `window_not_key` (the probe took the front, PROBE_TOOK_FRONT), `none` (no window could take keys); None when the
    probe did not run."""
    took = next((m for m in PROBE_TOOK_FRONT if m in marks), None)
    if took:
        return took.removeprefix("terminal.probe_")
    if PROBE_NO_KEY_WINDOW in marks:
        return "none"
    return "key" if PROBE_TYPED in marks else None


def round_failures(which: str, path: str, row: dict, marks: dict, settle: float) -> list[str]:
    """What a round that ran its launch failed on, from its reading (pure). The posted path without the grant has no
    way to type; the in_app path with no window key at its first frame typed nowhere. The in_app path's one key is typed
    before a chat page is up, so its chat round measures nothing and fails nothing."""
    out = []
    if path == "posted" and not row.get("post_access", True):
        out.append("this process may not post keys (CGPreflightPostEventAccess false)")
    if row.get("input_ms") is None and not row.get("no_mark") and not (path == "in_app" and which == "chat"):
        if which == "browser":
            out.append(f"the browser page took no keys within {settle:.0f} s ({BROWSER_INPUT})")
        elif path == "in_app" and which == "terminal" and PROBE_NO_KEY_WINDOW in marks:
            out.append("the app typed no key: no window could take keys at its first frame (terminal.probe_no_key_window)")
        else:
            first = next((k.removeprefix(FIRST_KEY_PREFIX) for k in marks if k.startswith(FIRST_KEY_PREFIX)), None)
            out.append(f"the {which} took no key within {settle:.0f} s ({path})" + (f"; its key hold read {first}" if first else ""))
    return out


def bundle_has_input_mark(app: Path) -> bool:
    """Whether any page script the app ships posts the composer's input mark (INPUT_MARK_MESSAGE): read once per run,
    so a chat round on a build without it is `no_mark` and a slow composer on a build with it is a failure."""
    resources = app / "Contents" / "Resources"
    for path in resources.rglob("*.js"):
        try:
            if INPUT_MARK_MESSAGE in path.read_bytes():
                return True
        except OSError:
            continue
    return False


def split(input_ms, main_ms) -> dict:
    """The interaction split at `main`: premain_ms, the system's part before it (the policy check of a new copy,
    dyld), and ours_ms, main to the key taken. None for both when either end is unknown."""
    if not isinstance(input_ms, (int, float)) or not isinstance(main_ms, (int, float)):
        return {"premain_ms": None, "ours_ms": None}
    return {"premain_ms": round(float(main_ms), 1), "ours_ms": round(float(input_ms) - float(main_ms), 1)}


# ---- seed -----------------------------------------------------------------------------------

def seed_list(inst: rr.Instance, made: dict, workspaces: int, chats: int, work: str) -> dict:
    """Workspaces tti-NNN up to `workspaces` in all (the l5 pair counts), chats - 1 more chats, every tenth terminal
    with 500 lines; returns what it made. Raises RuntimeError naming the step that failed."""
    have = len([w for w in (inst.topology() or {}).get("workspaces") or [] if isinstance(w, dict)])
    n, extra_chats, filled = 0, 0, 0
    while have < workspaces:
        made_ws = rr.unwrap(inst.cmux("workspace", "create", "--name", f"tti-{n:03d}", timeout=30))
        if not isinstance(made_ws, dict) or not made_ws.get("workspace_id"):
            raise RuntimeError(f"workspace create tti-{n:03d}: {json.dumps(made_ws)[:300]}")
        term = made_ws.get("terminal_id")
        if term and n % 10 == 0:
            inst.cmux("terminal", term, "write", "--text", "seq 1 500\n")
            filled += 1
        if extra_chats < chats - 1 and n % 20 == 5:
            chat = rr.unwrap(inst.cmux("agents", "chat", "new", "--workspace", made_ws["workspace_id"], "--harness",
                                       rr.HARNESS, "--cwd", work, "--name", f"tti-chat-{n:03d}", "--",
                                       f"{rr.PROMPT} {n}", timeout=90))
            if isinstance(chat, dict) and chat.get("chat"):
                extra_chats += 1
        have += 1
        n += 1
    return {"workspaces": have, "chats": 1 + extra_chats, "filled_terminals": 1 + filled}


# ---- one round ------------------------------------------------------------------------------

def quit_app(inst: rr.Instance, process, timing: dict | None = None) -> str | None:
    """Quit and Keep Sessions, then wait for the process to end. `timing`, when given, gets `quit_ms`: the ask to the
    old process's end (or to its kill), so a round can tell a slow relaunch from a slow quit before it."""
    asked = time.monotonic()
    reply = rr.call(inst.sock, "action.run", {"action": "quitKeepSessions"}, timeout=10)
    try:
        process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)
        if timing is not None:
            timing["quit_ms"], timing["quit_killed"] = round((time.monotonic() - asked) * 1000, 1), True
        return f"the app did not end within 20 s of Quit and Keep Sessions ({reply.get('error') or 'ok'})"
    if timing is not None:
        timing["quit_ms"] = round((time.monotonic() - asked) * 1000, 1)
    if os.path.exists(inst.sock):
        try:
            os.remove(inst.sock)
        except OSError:
            pass
    return None


def fresh_copy(app: Path, pristine: Path, n: int | str) -> Path:
    """A new copy of PRISTINE for round N's cold launch, in a folder of its own beside APP's (under the smoke's root,
    which its cleanup removes), and the copy APP was is removed, best effort. Never into APP's own path: a bundle
    path a process has launched from refuses new files there on a fleet Mac ("ditto: ...: Operation not permitted",
    every file, cmuxterm-hq run 44723138688, 2026-11-20), so a re-copy in place failed every cold round."""
    new = app.parent.parent / f"app-cold-{n}" / app.name
    new.parent.mkdir(parents=True, exist_ok=False)
    subprocess.run(["ditto", str(pristine), str(new)], check=True, timeout=600)
    shutil.rmtree(app, ignore_errors=True)
    return new


def updated_copy(app: Path, pristine: Path, n: int, env: dict) -> tuple[Path, dict]:
    """Round N's cold_after_update copy, made the way scripts/measure/nightly-fresh-launch.py's update arm
    (prewarm-update-moved, NOW's app_update_launch_ms) makes it: a new copy in a staging folder, the updater's pre-warm
    run there (staged_update_prewarm), then the folder renamed into place, as an installed update is moved; the launch
    is that same pre-warmed copy. Returns the placed app and the pre-warm's record."""
    staged = fresh_copy(app, pristine, f"stage-{n}")
    prewarm = staged_update_prewarm(staged, env)
    placed = staged.parent.parent / f"app-cold-{n}"
    os.rename(staged.parent, placed)
    return placed / staged.name, prewarm


def staged_prewarm_plan(app: Path) -> list[tuple[Path, list[str]]]:
    """The ordered process part of ``StagedUpdatePrewarm.runs(bundle:)`` for APP."""
    with open(app / "Contents" / "Info.plist", "rb") as handle:
        executable_name = plistlib.load(handle)["CFBundleExecutable"]
    main = app / "Contents" / "MacOS" / executable_name
    runs: list[tuple[Path, list[str]]] = []
    if main.is_file() and os.access(main, os.X_OK):
        runs.append((main, ["--cmux-prewarm-launch"]))
    for name in ("cmux", "cmux-tui"):
        binary = app / "Contents" / "Resources" / "bin" / name
        if binary.is_file() and os.access(binary, os.X_OK):
            runs.append((binary, ["--version"]))
    frameworks = app / "Contents" / "Frameworks"
    helpers = sorted((p for p in frameworks.iterdir() if p.is_dir() and p.suffix == ".app" and " Helper" in p.name),
                     key=lambda p: p.name) if frameworks.is_dir() else []
    for helper in helpers:
        binary = helper / "Contents" / "MacOS" / helper.stem
        if binary.is_file() and os.access(binary, os.X_OK):
            runs.append((binary, ["--version"]))
    if main.is_file() and os.access(main, os.X_OK):
        runs.append((main, ["--cmux-prewarm-chromium"]))
    return runs


def staged_update_prewarm(app: Path, env: dict) -> dict:
    """Mirror the updater's best-effort process and Frameworks-page pre-warm on a fresh copy."""
    result: dict = {"runs": []}
    for executable, arguments in staged_prewarm_plan(app):
        started = time.monotonic()
        status: int | str
        try:
            completed = subprocess.run([str(executable), *arguments], cwd=env.get("HOME"), env=env,
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       timeout=20)
            status = completed.returncode
        except (OSError, subprocess.SubprocessError) as error:
            status = f"error: {error}"
        result["runs"].append({"executable": executable.name, "arguments": arguments, "status": status,
                               "ms": round((time.monotonic() - started) * 1000, 1)})
    files = pages = 0
    frameworks = app / "Contents" / "Frameworks"
    paths = sorted(frameworks.rglob("*")) if frameworks.is_dir() else ()
    for path in paths:
        if path.is_symlink() or not path.is_file():
            continue
        try:
            size = path.stat().st_size
            if size == 0:
                continue
            with open(path, "rb") as handle, mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
                for offset in range(0, size, mmap.PAGESIZE):
                    mapped[offset]
            files += 1
            pages += (size + mmap.PAGESIZE - 1) // mmap.PAGESIZE
        except OSError:
            continue
    result["frameworks"] = {"files": files, "pages": pages}
    return result


def read_marks(fd: int, buf: bytearray, marks: dict) -> None:
    try:
        while chunk := os.read(fd, 1 << 16):
            buf.extend(chunk)
    except (BlockingIOError, OSError):
        pass
    whole, sep, rest = bytes(buf).rpartition(b"\n")
    if not sep:
        return
    buf[:] = rest
    for line in whole.decode(errors="replace").splitlines():
        name, _, ms = line.rpartition(" ")
        try:
            marks.setdefault(name, round(float(ms), 1))
        except ValueError:
            pass


def prerun(inst: rr.Instance, app: Path, env: dict, out: Path, seconds: float) -> tuple[object, str | None]:
    """One full run of the copy that stays up `seconds` after its window shows, then quits (launch-ready prerun=S)."""
    process, fd, _ = rr.launch(app, env, out / "app-prerun.log")
    marks: dict = {}
    buf = bytearray()
    shown = rr.wait(lambda: (read_marks(fd, buf, marks), "first_window_frame_committed" in marks)[1], 30, 0.1)
    os.close(fd)
    if not shown:
        quit_app(inst, process)
        return None, "the prerun's window never showed"
    time.sleep(seconds)  # sleep-ok: the prerun stays up `seconds` after its window shows, on purpose
    rr.wait(lambda: rr.call(inst.sock, "system.ping", timeout=2).get("error") is None, 10, 0.25)
    return None, quit_app(inst, process)


MAX_RECOVERIES = 3  # a run whose launches keep failing stops after this many, as it stopped at the first before
RECOVER_READY_S = 30.0


def app_answers(inst: rr.Instance) -> bool:
    return rr.call(inst.sock, "system.ping", timeout=2).get("error") is None


def recover_app(inst: rr.Instance, app: Path, env: dict, out: Path):
    """After a round left no app this run tracks (its launch failed, or the app exited): end any instance of APP still
    up, then one unmeasured launch of APP, ready when its socket answers. Returns (the process, None) or (None, why).
    Before 2026-11-26 the plan stopped at such a round: one failed launch (round 1 of 51, cmuxterm-hq job
    140156243595) left every NOW app_*_launch_to_interaction_ms row null for the night (goals/startup-matrix.md)."""
    import fresh_home_launch_smoke as smoke
    _, name = smoke.bundle_info(app)
    executable = app / "Contents" / "MacOS" / name
    if app_answers(inst):  # an instance this run started but could not track (cmux#59530's missed pid)
        rr.call(inst.sock, "action.run", {"action": "quitKeepSessions"}, timeout=10)
        rr.wait(lambda: not running_pids(executable), 20, 0.25)
    for pid in running_pids(executable):  # only this run's own copy of the app: its path is under the smoke's root
        try:
            os.kill(pid, 9)
        except OSError:
            pass
    if os.path.exists(inst.sock):
        try:
            os.remove(inst.sock)
        except OSError:
            pass
    try:
        process, fd, _ = rr.launch(app, env, out / "app-recover.log")
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        return None, f"the recovery launch failed: {error}"
    marks: dict = {}
    buf = bytearray()
    ready = rr.wait(lambda: (read_marks(fd, buf, marks), app_answers(inst))[1], RECOVER_READY_S, 0.25)
    os.close(fd)
    if not ready or process.poll() is not None:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        return None, f"the recovery launch never answered within {RECOVER_READY_S:.0f} s (status {process.poll()})"
    return process, None


def round_has_marks(which: str, args) -> dict:
    """{paint, input}: whether this run's build has the front's paint and input marks (decided once per run; a
    missing one reads `no_mark`, never a harness time). The terminal's marks are in every build."""
    if which == "chat":
        return {"paint": True, "input": bool(getattr(args, "has_input_mark", False))}
    if which == "browser":
        has = bool(getattr(args, "has_browser_mark", False))
        return {"paint": has, "input": has}
    return {"paint": True, "input": True}


def round_once(n: int, kind: str, which: str, process, inst: rr.Instance, app: Path, pristine: Path, env: dict,
               made: dict, keys: Keys, args, out: Path):
    """One quit and measured launch; returns (row, the new process, the app it ran: a cold round's is a new copy)."""
    path = input_path(keys.access, args.input)
    row: dict = {"round": n, "kind": kind, "front": which, "workspaces": made.get("list", {}).get("workspaces"),
                 "post_access": keys.access, "input": path, "load": args.load, "launch": args.launch}
    failures = row.setdefault("failures", [])
    put = put_front(inst, which, made)
    if put:
        failures.append(put)
        rr.safe_print("TTI-ROUND " + json.dumps(row, default=str), flush=True)
        return row, process, app
    why = quit_app(inst, process, row)
    quit_end = time.monotonic()
    if why:
        failures.append(why)
    if kind in ("cold_install", "cold_after_update"):
        try:
            if kind == "cold_after_update":
                app, row["prewarm"] = updated_copy(app, pristine, n, env)
            else:
                app = fresh_copy(app, pristine, n)
        except (OSError, subprocess.SubprocessError) as error:
            failures.append(f"the fresh copy failed: {error}")
            rr.safe_print("TTI-ROUND " + json.dumps(row, default=str), flush=True)
            return row, process, app
        # The seeded session's CLI is the running copy's (Instance.cli): follow the app to its new path.
        inst.app, inst.cli = str(app), os.path.join(str(app), "Contents", "Resources", "bin", "cmux")
    elif kind == "warm60":
        _, why = prerun(inst, app, env, out, PRERUN_S)
        if why:
            failures.append(why)
    probe = out / f"typing-round{n}.csv"
    probe.unlink(missing_ok=True)
    # The old process's end to this launch (a cold round's copy and prewarm sit in it, a warm round's is ~0), and the
    # Mac's 1-minute load at the launch: a stage median mixes rounds, and both decide whether rounds compare.
    row["quit_to_launch_ms"] = round((time.monotonic() - quit_end) * 1000, 1)
    row["load_per_core"], row["load_wait_s"] = wait_for_quiet(args.max_load_per_core, args.load_wait)
    row["load_1m"], row["cpus"] = load_1m(), os.cpu_count()
    # --load busy starts after the quiet wait: started before it, the round would wait out --load-wait on its own load.
    args.load_runner.start()
    spawned = uptime_ns()
    launched_wall = time.time()
    try:
        if args.launch == "open":
            process, fd = ls_launch(app, launch_env(env, probe, path, args.launch_delay_ms), out / "app-tti.log")
        else:
            process, fd, _ = rr.launch(app, launch_env(env, probe, path, args.launch_delay_ms), out / "app-tti.log")
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        args.load_runner.stop()
        failures.append(f"the launch failed: {error}")
        rr.safe_print("TTI-ROUND " + json.dumps(row, default=str), flush=True)
        return row, process, app
    start_ns = process_start_uptime_ns(process.pid)
    activate(process.pid)  # the front from the start: a key, the app's own or ours, goes to its key window
    activated = time.monotonic()
    row["pid"] = process.pid
    row["spawn_to_start_ms"] = round((start_ns - spawned) / 1e6, 1) if start_ns else None
    marks: dict = {}
    buf = bytearray()
    posted, last_post = 0, 0.0
    term: dict = {"accepted_ms": None, "input_ms": None}
    has_marks = round_has_marks(which, args)
    framed_at = None
    end = time.monotonic() + args.settle
    while time.monotonic() < end and process.poll() is None:
        read_marks(fd, buf, marks)
        # The paint number: the front's PAINT_MARK, or (a build without it, `no_mark`) nothing to wait for.
        painted = PAINT_MARK[which] in marks or not has_marks["paint"]
        if which == "chat":
            # A build whose pages never post the composer's input mark (bundle_has_input_mark, decided once per run),
            # or the in_app path (its one key is typed before a chat page is up): the round ends when the chat drew
            # and types nothing into its draft; `no_mark` or nothing measured, not a failure of the app.
            took = CHAT_MARK in marks or ((not has_marks["input"] or path == "in_app") and "agent_pane.painted" in marks)
        elif which == "browser":
            took = BROWSER_INPUT in marks or not has_marks["input"]
            # A build without the browser marks: the round ends 2 s after its first frame (nothing to read).
            if "first_window_frame_committed" in marks and framed_at is None:
                framed_at = time.monotonic()
            if not has_marks["paint"] and (framed_at is None or time.monotonic() - framed_at < 2.0):
                took = False
        elif path == "in_app":
            term = in_app_terminal_reading(marks)
            took = term["input_ms"] is not None or PROBE_NO_KEY_WINDOW in marks  # a failed probe ends the input only
        else:
            term = terminal_reading(probe_rows(probe), start_ns)
            took = term["input_ms"] is not None
        if took and painted:
            break
        if time.monotonic() - activated > 2.0 and not took:
            activate(process.pid)
            activated = time.monotonic()
        # A terminal key that reached the pty: stop typing so its echo closes the sample (a later key would close it
        # unfinished), and post again only if no echo comes within a second.
        holding = which == "terminal" and term["accepted_ms"] is not None and time.monotonic() - last_post < 1.0
        if path == "posted" and keys.cg is not None and not holding and not took and which != "browser":
            keys.post(process.pid)
            posted += 1
            last_post = time.monotonic()
        time.sleep(KEY_EVERY_S)
    # Marks written as the loop ended: read until the pipe stays quiet for 0.2 s (or ends), at most 2 s.
    drain_end = time.monotonic() + 2.0
    while time.monotonic() < drain_end:
        try:
            ready, _, _ = select.select([fd], [], [], 0.2)
        except (OSError, ValueError):
            break
        if not ready:
            break
        before = (len(buf), len(marks))
        read_marks(fd, buf, marks)
        if (len(buf), len(marks)) == before:
            break  # readable with nothing new: the writer closed the pipe
    read_marks(fd, buf, marks)
    os.close(fd)
    args.load_runner.stop()
    if which == "terminal":
        term = in_app_terminal_reading(marks) if path == "in_app" else terminal_reading(probe_rows(probe), start_ns)
    row["keys_posted"] = posted
    row["main_ms"] = marks.get("main_start")
    row["first_frame_ms"] = marks.get("first_window_frame_committed")
    row.update({k: marks.get(k) for k in TERMINAL_PAINT_MARKS})  # every round, typed or not
    row["first_paint_ms"] = marks.get(PAINT_MARK[which]) if has_marks["paint"] else "no_mark"
    if which == "chat":
        row["input_ms"] = marks.get(CHAT_MARK)
        if not has_marks["input"]:
            row["no_mark"] = True  # this build's pages never post the composer's input mark
        elif path == "in_app" and row["input_ms"] is None and PAINT_MARK["chat"] in marks:
            # The app typed its one key before this chat page was up: the round measured no chat key by design (the
            # posted path times the chat). It drew, so it counts toward the verdict, named, never as a number.
            row["unmeasured"] = "in_app: the app types its one key before a chat page is up"
    elif which == "browser":
        row["input_ms"] = marks.get(BROWSER_INPUT)
        if not has_marks["input"]:
            row["no_mark"] = True  # this build has no browser pane marks
    else:
        row.update(term)
    if row.get("first_paint_ms") is None:
        failures.append(f"the {which} never painted within {args.settle:.0f} s ({PAINT_MARK[which]})")
    row.update(split(row.get("input_ms"), row["main_ms"]))
    if path == "in_app":
        row["probe_focus"] = probe_focus(marks)
    row["marks"] = kept_marks(marks)
    row["stages"] = launch_stages.spans(marks)
    row["binders"] = launch_row_binders(env["HOME"], app, launched_wall)
    if process.poll() is not None:
        failures.append(f"the app exited (status {process.poll()})")
    failures += round_failures(which, path, row, marks, args.settle)
    rr.safe_print("TTI-ROUND " + json.dumps(row, default=str), flush=True)
    return row, process, app


def launch_row_binders(home: str, app: Path, since: float, wait: float = 3.0) -> dict | None:
    """This launch's ``binders`` from the app's launch-times.jsonl (cmux#57799: each `AppActions.bind` binder's
    main-thread ms, the slowest LaunchTimesRecord.binderCount). The row has no pid: it is the newest one started at or
    after SINCE (wall seconds, less 1 s for the row's whole-second started_at). None when no such row arrives in WAIT
    seconds or the build writes no binders: the round reads nothing, never fails."""
    import fresh_home_launch_smoke as smoke
    try:
        bundle_id, _ = smoke.bundle_info(app)
    except (OSError, KeyError, ValueError):
        return None
    path = Path(home) / "Library" / "Application Support" / bundle_id / "launch-times.jsonl"
    deadline = time.monotonic() + max(0.0, wait)
    while True:
        try:
            lines = path.read_text(errors="replace").splitlines()
        except OSError:
            lines = []
        for line in reversed(lines):
            try:
                record = json.loads(line)
                started = datetime.datetime.fromisoformat(str(record.get("started_at", "")).replace("Z", "+00:00"))
            except (TypeError, ValueError, AttributeError):
                continue
            if started.timestamp() < since - 1.0:
                break
            binders = record.get("binders")
            return binders if isinstance(binders, dict) else None
        if time.monotonic() >= deadline:
            return None
        time.sleep(0.1)


def binder_medians(rows: list) -> dict:
    """Each binder's median ms over ROWS' ``binders``, slowest first (the pre-frame cut's list)."""
    got: dict = {}
    for row in rows:
        for name, ms in (row.get("binders") or {}).items() if isinstance(row.get("binders"), dict) else ():
            if isinstance(ms, (int, float)) and not isinstance(ms, bool):
                got.setdefault(name, []).append(ms)
    medians = {name: round(statistics.median(v), 2) for name, v in got.items()}
    return dict(sorted(medians.items(), key=lambda kv: -kv[1]))


# ---- restart to first paint ----------------------------------------------------------------

def _median(values: list[float]) -> float | None:
    values = sorted(values)
    if not values:
        return None
    mid = len(values) // 2
    return round(values[mid] if len(values) % 2 else (values[mid - 1] + values[mid]) / 2, 1)


def _number(rows: list[dict], key: str) -> dict:
    """{median, samples}: a number's median over ROWS and every sample (`no_mark` when the build has no mark)."""
    samples = [("no_mark" if (key == "input_ms" and r.get("no_mark")) else r.get(key)) for r in rows]
    if samples and all(v == "no_mark" for v in samples):
        return {"median": "no_mark", "samples": samples}
    return {"median": _median([v for v in samples if isinstance(v, (int, float))]), "samples": samples}


def restart_first_paint(rounds: list[dict], load: str) -> tuple[list[dict], list[dict]]:
    """(one RESTART-FIRST-PAINT row per front and kind in round order, one RESTART-FIRST-PAINT-RATIO row per kind):
    first_paint_ms and input_ms as {median, samples}, and chat/terminal and browser/terminal of the medians (pure)."""
    lines, groups = [], {}
    for r in rounds:
        if r.get("front") in FRONTS and r.get("kind") in KINDS:
            groups.setdefault((r["kind"], r["front"]), []).append(r)
    for (kind, front), rows in groups.items():
        lines.append({"front": front, "kind": kind, "first_paint_ms": _number(rows, "first_paint_ms"),
                      "input_ms": _number(rows, "input_ms"), "rounds": [r.get("round") for r in rows], "load": load})
    ratios = []
    for kind in dict.fromkeys(k for k, _ in groups):
        by = {line["front"]: line for line in lines if line["kind"] == kind}
        row = {"kind": kind, "load": load}
        for num in ("first_paint_ms", "input_ms"):
            base = (by.get("terminal") or {}).get(num, {}).get("median")
            for other in ("chat", "browser"):
                top = (by.get(other) or {}).get(num, {}).get("median")
                ok = isinstance(top, (int, float)) and isinstance(base, (int, float)) and base > 0
                row[f"{other}_over_terminal_{num[:-3]}"] = round(top / base, 2) if ok else None
        ratios.append(row)
    return lines, ratios


# ---- the check ------------------------------------------------------------------------------

def check(args) -> int:
    import fresh_home_launch_smoke as smoke
    result: dict = {"rounds": [], "recoveries": []}
    keys = Keys()

    def journey(process, socket_path, env, app, out, report):
        out = Path(args.out or Path(env["HOME"]).parent)
        app = Path(app)
        inst = rr.Instance(str(socket_path), str(app), env["HOME"])
        work = os.path.join(env["HOME"], "l5-work")
        env = interactive_env(env)  # every launch from here takes the front, as a person's does
        started = time.monotonic()
        try:
            made = rr.seed(inst, args.fake_agent, work, front_terminal=False)
            made["list"] = seed_list(inst, made, args.workspaces, args.chats, work)
        except RuntimeError as error:
            result["seed_error"] = str(error)
            return [f"seed: {error}"]
        result["seed"] = {**made["list"], "seed_s": round(time.monotonic() - started, 1)}
        args.has_input_mark = bundle_has_input_mark(app)
        result["has_input_mark"] = args.has_input_mark
        args.has_browser_mark = bundle_has_browser_mark(app)
        result["has_browser_mark"] = args.has_browser_mark
        if any(which == "browser" for _, which in args.plan):
            try:
                seed_browser(inst, made, serve_page())
            except RuntimeError as error:
                result["seed_error"] = f"browser: {error}"
                return [f"seed: browser: {error}"]
        # Under the smoke's own root, never the evidence folder: the smoke's cleanup removes it whatever happens.
        pristine = Path(env["HOME"]).parent / "pristine.noindex" / app.name
        pristine.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["ditto", str(app), str(pristine)], check=True, timeout=600)
        failures = []
        for n, (kind, which) in enumerate(args.plan, 1):
            row, process, app = round_once(n, kind, which, process, inst, app, pristine, env, made, keys, args, out)
            result["rounds"].append(row)
            failures += [f"round {n}: {f}" for f in row["failures"]]
            if process.poll() is not None:
                # No app left to quit into the next round: bring one up unmeasured and go on, so one failed launch
                # costs its own round, not the rest of the plan (the 20 cold_install:terminal p50/p95 rounds).
                if len(result["recoveries"]) >= MAX_RECOVERIES or n == len(args.plan):
                    break
                recovered, why = recover_app(inst, app, launch_env(env, out / "typing-recover.csv", "posted"), out)
                result["recoveries"].append({"after_round": n, "error": why})
                rr.safe_print("TTI-RECOVER " + json.dumps(result["recoveries"][-1]), flush=True)
                if recovered is None:
                    failures.append(f"after round {n}: {why}")
                    break
                process = recovered
        rr.call(inst.sock, "action.run", {"action": "quitEndEverything"}, timeout=10)
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
        try:
            os.kill(made["terminal_pid"], 15)
        except OSError:
            pass
        shutil.rmtree(pristine.parent, ignore_errors=True)
        return failures

    smoke.AFTER_RENDER = journey

    def prepare(env):
        smoke.login_keychain(env)
        rr.write_harness(env["HOME"], args.fake_agent)

    smoke.PREPARE_HOME = prepare
    argv = ["--seconds", "1", *(["--dmg", args.dmg] if args.dmg else ["--app", args.app]),
            *(["--out", args.out] if args.out else [])]
    try:
        status = smoke.main(argv)
    finally:
        args.load_runner.stop()
    fronts = [f for f in FRONTS if f in DEFAULT_FRONTS or any(w == f for _, w in args.plan)]
    summary = {}
    for kind in KINDS:
        for which in fronts:
            got = [r["input_ms"] for r in result["rounds"] if r.get("kind") == kind and r.get("front") == which
                   and isinstance(r.get("input_ms"), (int, float))]
            summary[f"{kind}_{which}_ms"] = max(got) if got else None
    # Each stage's median per front over the rounds (ms from process start; launch_stages.TABLE names the marks).
    result["stages"] = {which: launch_stages.medians([r.get("stages") for r in result["rounds"] if r.get("front") == which])
                        for which in fronts}
    # Each launch binder's median per front (startup-under-100ms: which binders the pre-frame cut defers).
    result["binders"] = {which: binder_medians([r for r in result["rounds"] if r.get("front") == which]) for which in fronts}
    rr.safe_print("TTI-BINDERS " + json.dumps(result["binders"]), flush=True)
    # The percentile rows (startup-matrix): p50/p95 per KIND_FRONT over the rounds launched under the load bound.
    result["percentiles"] = percentiles(result["rounds"], args.max_load_per_core, args.min_quiet)
    rr.safe_print("TTI-PCT " + json.dumps(result["percentiles"]), flush=True)
    # A chat round on a build without the input mark measured nothing about the app and fails nothing (`no_mark`).
    # So does an in_app chat round that drew (`unmeasured`): the app's one key went in before the page was up.
    measured = [r for r in result["rounds"] if isinstance(r.get("input_ms"), (int, float)) or r.get("no_mark")
                or r.get("unmeasured")]
    passed = status == 0 and len(result["rounds"]) == len(args.plan) and len(measured) == len(args.plan)
    result.update(summary, verdict="pass" if passed else "fail", post_access=keys.access, launch_delay_ms=args.launch_delay_ms,
                  input=input_path(keys.access, args.input))
    if args.out:
        with open(Path(args.out) / "tti.json", "w") as handle:
            json.dump(result, handle, indent=2, default=str)
    lines, ratios = restart_first_paint(result["rounds"], args.load)
    result.update(restart_first_paint=lines, restart_first_paint_ratio=ratios)
    for line in lines:
        print("RESTART-FIRST-PAINT " + json.dumps(line), flush=True)
    for line in ratios:
        print("RESTART-FIRST-PAINT-RATIO " + json.dumps(line), flush=True)
    shown = ("verdict", "post_access", "input", "launch_delay_ms", "seed", "seed_error", "stages", "binders", "percentiles",
             "recoveries", *summary)
    print("TTI " + json.dumps({k: result.get(k) for k in shown}),
          flush=True)
    return 0 if passed else (status if status not in (0, None) else 1)


def parse_plan(text: str) -> list[tuple[str, str]]:
    plan = []
    for item in (p.strip() for p in text.split(",") if p.strip()):
        # KIND:FRONT*N repeats a round N times in a row (cold_install:terminal*20: twenty cold launches)
        head, star, count = item.partition("*")
        kind, _, which = head.partition(":")
        if kind not in KINDS or which not in FRONTS:
            raise ValueError(f"{item!r}: KIND is one of {', '.join(KINDS)}, FRONT one of {', '.join(FRONTS)}")
        if star and not (count.isdigit() and 1 <= int(count) <= 100):
            raise ValueError(f"{item!r}: *N takes 1-100 rounds")
        plan += [(kind, which)] * (int(count) if star else 1)
    if not plan:
        raise ValueError("an empty plan")
    return plan


def main(argv: list[str] | None = None) -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--app")
    source.add_argument("--dmg")
    parser.add_argument("--workspaces", type=int, default=120)
    parser.add_argument("--chats", type=int, default=6)
    parser.add_argument("--plan", default=DEFAULT_PLAN, help="KIND:FRONT rounds in order; KIND cold_install, "
                                                             "cold_after_update, warm or warm60, FRONT chat, terminal "
                                                             "or browser")
    parser.add_argument("--settle", type=float, default=30.0, help="seconds a launch may take to take a key")
    parser.add_argument("--input", choices=("auto", "posted", "in_app"), default="auto",
                        help="who types: posted (CGEventPostToPid, needs the PostEvent grant), in_app (the app's "
                             "LaunchTypeProbe at its first frame), auto (posted when the grant is held)")
    parser.add_argument("--load", choices=LOADS, default="none",
                        help="busy: one `yes > /dev/null` per core through each measured launch")
    parser.add_argument("--launch", choices=("open", "exec"), default="open",
                        help="open: LaunchServices (activated, as a Dock click); exec: the harness execs the app")
    parser.add_argument("--launch-delay-ms", type=int, default=0,
                        help="the positive control: each measured launch waits this long before its first window "
                             "(CMUX_NEXT_LAUNCH_TEST_DELAY_MS; the app clamps it to 5000)")
    parser.add_argument("--max-load-per-core", type=float, default=LOAD_BOUND_PER_CORE,
                        help="the load bound: a round waits (up to --load-wait s) for the 1-minute load per core to "
                             "fall to this, and a round launched over it is left out of the p50/p95")
    parser.add_argument("--load-wait", type=float, default=LOAD_WAIT_S)
    parser.add_argument("--min-quiet", type=int, default=MIN_QUIET_ROUNDS,
                        help="a KIND_FRONT cell with fewer quiet measured rounds posts no p50/p95 (refused)")
    parser.add_argument("--fake-agent", default=str(rr.DEFAULT_FAKE_AGENT))
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    try:
        args.plan = parse_plan(args.plan)
    except ValueError as error:
        parser.error(str(error))
    if args.workspaces < 2:
        parser.error("--workspaces must be at least 2 (the l5 pair)")
    args.load_runner = Load(args.load)
    return check(args)


if __name__ == "__main__":
    sys.exit(main())
