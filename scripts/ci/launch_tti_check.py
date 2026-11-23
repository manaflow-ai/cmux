#!/usr/bin/env python3
"""Launch to first interaction (startup-tti): how long after its process starts cmux NEXT takes a typed key, with a
realistic session list, cold and warm.

Leo, 2026-11-19: "startup times and time to first interaction".

    launch_tti_check.py (--app APP | --dmg DMG) [--workspaces 120] [--chats 6] [--plan KIND:FRONT,...] [--out DIR]

On a fresh home (fresh_home_launch_smoke.py launches it, as the nightly gate does) it seeds the session list: the
relaunch-restore pair (relaunch_restore_check.seed: `l5-a` with a terminal under 2,000 lines of scrollback, `l5-b`
with an agent chat on the acpmux test agent, one turn answered), then workspaces `tti-NNN` up to --workspaces in all,
--chats - 1 more of them with a chat of their own and every tenth with 500 lines in its terminal. Then each round of
--plan (KIND:FRONT, in order):

  FRONT    what the front window shows at the quit and so after the relaunch: `chat` (l5-b's chat tab, typed into
           its composer) or `terminal` (l5-a's terminal, typed into its shell's tty, which echoes).
  KIND     `cold_install`: the copy is deleted and copied again (ditto) from the one kept at the start, so the launch
           is the first exec of new files, as a fresh install; `cold_after_update`: the same fresh copy after the
           updater's StagedUpdatePrewarm sequence; `warm`: the same copy relaunched right after the quit
           (launch-ready.sh prerun=0); `warm60`: before it, one full run of the same copy that stays up 60 s after
           its window shows, then quits (launch-ready.sh prerun=60).

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
Exit 0 when every round measured its front.

A NIGHTLY is a Release build: only release control methods and the bundled CLI are used. Posting keys needs the
process to hold the PostEvent grant (CGPreflightPostEventAccess). A runner without it (`post_access: false`) types in
the app instead (`input: in_app`, every round row and the TTI line say which path ran, `posted` or `in_app`): the
launch has CMUX_NEXT_LAUNCH_TYPE_PROBE=1, so the app itself types one key into its key window at its first window
frame (LaunchTypeProbe, the probe scripts/measure/launch-ready.swift's `type` mode uses), and the terminal's
interaction is its launch marks `terminal_input_accepted` (accepted_ms) and `terminal_echo` (input_ms): the same
process start to the typed key taken. `terminal.probe_no_key_window` (no window was key at that frame) fails the
round. The chat composer posts no input mark in any build yet (`no_mark`), so on either path a chat round measures
nothing and the row is the terminal's.
"""
from __future__ import annotations

import csv
import ctypes
import ctypes.util
import json
import mmap
import os
import plistlib
import select
import shutil
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
FRONTS = ("chat", "terminal")
DEFAULT_PLAN = ("cold_install:chat,cold_install:terminal,cold_after_update:chat,cold_after_update:terminal,"
                "warm:chat,warm:terminal,warm60:chat,warm60:terminal,"
                "cold_install:chat,cold_install:terminal,cold_after_update:chat,cold_after_update:terminal,"
                "warm:chat,warm:terminal,warm60:chat,warm60:terminal")
PRERUN_S = 60.0
INPUT_MARK_MESSAGE = b"pane.inputEchoed"  # what a page posts when its composer drew a typed key (the mark's source)
CHAT_MARK = "agent_pane.input_echoed"
TYPE_PROBE_VARIABLE = "CMUX_NEXT_LAUNCH_TYPE_PROBE"  # LaunchTypeProbe: the app types one key at its first window frame
PROBE_TYPED, PROBE_NO_KEY_WINDOW = "terminal.probe_key_typed", "terminal.probe_no_key_window"
KEPT_MARKS = ("main_start", "first_window_frame_committed", "reveal.pane", "reveal.home", "agent_pane.painted",
              CHAT_MARK, "first_terminal_surface_created", "terminal_input_accepted", "terminal_echo", PROBE_TYPED,
              PROBE_NO_KEY_WINDOW)


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


def activate(pid: int) -> None:
    """Bring the app to the front without waiting (a posted key goes to its key window)."""
    script = (f"ObjC.import('AppKit'); var a = $.NSRunningApplication.runningApplicationWithProcessIdentifier({pid}); "
              "if (a) { a.activateWithOptions(3) }")
    try:
        subprocess.Popen(["/usr/bin/osascript", "-l", "JavaScript", "-e", script],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


# ---- the typing probe -----------------------------------------------------------------------

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


def launch_env(env: dict, probe: Path, path: str) -> dict:
    """The measured launch's environment: the typing probe always, the app's own first-frame key on the in_app path."""
    out = {**env, "CMUX_NEXT_TYPING_PROBE": str(probe)}
    if path == "in_app":
        out[TYPE_PROBE_VARIABLE] = "1"
    return out


def in_app_terminal_reading(marks: dict) -> dict:
    """{accepted_ms, input_ms} from the launch marks on the in_app path: the key LaunchTypeProbe typed left the app for
    the restored terminal's pty (terminal_input_accepted) and its echo came back (terminal_echo); ms since process
    start, as launch-ready.swift's type mode reads them."""
    return {"accepted_ms": marks.get("terminal_input_accepted"), "input_ms": marks.get("terminal_echo")}


def round_failures(which: str, path: str, row: dict, marks: dict, settle: float) -> list[str]:
    """What a round that ran its launch failed on, from its reading (pure). The posted path without the grant has no
    way to type; the in_app path with no key window at the first frame typed nowhere."""
    out = []
    if path == "posted" and not row.get("post_access", True):
        out.append("this process may not post keys (CGPreflightPostEventAccess false)")
    if row.get("input_ms") is None and not row.get("no_mark"):
        if path == "in_app" and which == "terminal" and PROBE_NO_KEY_WINDOW in marks:
            out.append("the app typed no key: no window was key at its first frame (terminal.probe_no_key_window)")
        else:
            out.append(f"the {which} took no key within {settle:.0f} s ({path})")
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

def quit_app(inst: rr.Instance, process) -> str | None:
    reply = rr.call(inst.sock, "action.run", {"action": "quitKeepSessions"}, timeout=10)
    try:
        process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)
        return f"the app did not end within 20 s of Quit and Keep Sessions ({reply.get('error') or 'ok'})"
    if os.path.exists(inst.sock):
        try:
            os.remove(inst.sock)
        except OSError:
            pass
    return None


def fresh_copy(app: Path, pristine: Path, n: int) -> Path:
    """A new copy of PRISTINE for round N's cold launch, in a folder of its own beside APP's (under the smoke's root,
    which its cleanup removes), and the copy APP was is removed, best effort. Never into APP's own path: a bundle
    path a process has launched from refuses new files there on a fleet Mac ("ditto: ...: Operation not permitted",
    every file, cmuxterm-hq run 44723138688, 2026-11-20), so a re-copy in place failed every cold round."""
    new = app.parent.parent / f"app-cold-{n}" / app.name
    new.parent.mkdir(parents=True, exist_ok=False)
    subprocess.run(["ditto", str(pristine), str(new)], check=True, timeout=600)
    shutil.rmtree(app, ignore_errors=True)
    return new


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


def round_once(n: int, kind: str, which: str, process, inst: rr.Instance, app: Path, pristine: Path, env: dict,
               made: dict, keys: Keys, args, out: Path):
    """One quit and measured launch; returns (row, the new process, the app it ran: a cold round's is a new copy)."""
    path = input_path(keys.access, args.input)
    row: dict = {"round": n, "kind": kind, "front": which, "workspaces": made.get("list", {}).get("workspaces"),
                 "post_access": keys.access, "input": path}
    failures = row.setdefault("failures", [])
    put = rr.put_front(inst, which, made)
    if put:
        failures.append(put)
        rr.safe_print("TTI-ROUND " + json.dumps(row, default=str), flush=True)
        return row, process, app
    why = quit_app(inst, process)
    if why:
        failures.append(why)
    if kind in ("cold_install", "cold_after_update"):
        try:
            app = fresh_copy(app, pristine, n)
        except (OSError, subprocess.SubprocessError) as error:
            failures.append(f"the fresh copy failed: {error}")
            rr.safe_print("TTI-ROUND " + json.dumps(row, default=str), flush=True)
            return row, process, app
        # The seeded session's CLI is the running copy's (Instance.cli): follow the app to its new path.
        inst.app, inst.cli = str(app), os.path.join(str(app), "Contents", "Resources", "bin", "cmux")
        if kind == "cold_after_update":
            row["prewarm"] = staged_update_prewarm(app, env)
    elif kind == "warm60":
        _, why = prerun(inst, app, env, out, PRERUN_S)
        if why:
            failures.append(why)
    probe = out / f"typing-round{n}.csv"
    probe.unlink(missing_ok=True)
    spawned = uptime_ns()
    process, fd, _ = rr.launch(app, launch_env(env, probe, path), out / "app-tti.log")
    start_ns = process_start_uptime_ns(process.pid)
    if path == "in_app":
        activate(process.pid)  # the app types into its key window at its first frame: ask for the front from the start
    row["pid"] = process.pid
    row["spawn_to_start_ms"] = round((start_ns - spawned) / 1e6, 1) if start_ns else None
    marks: dict = {}
    buf = bytearray()
    posted, activated, last_post = 0, 0.0, 0.0
    term: dict = {"accepted_ms": None, "input_ms": None}
    end = time.monotonic() + args.settle
    while time.monotonic() < end and process.poll() is None:
        read_marks(fd, buf, marks)
        if which == "chat" and CHAT_MARK in marks:
            break
        # A build whose pages never post the composer's input mark (bundle_has_input_mark, decided once per run): the
        # round ends when the chat drew and types nothing into its draft; it reads `no_mark`, not a failure of the app.
        if which == "chat" and not args.has_input_mark and "agent_pane.painted" in marks:
            break
        if which == "terminal" and path == "in_app":
            term = in_app_terminal_reading(marks)
            if term["input_ms"] is not None or PROBE_NO_KEY_WINDOW in marks:
                break
        elif which == "terminal":
            term = terminal_reading(probe_rows(probe), start_ns)
            if term["input_ms"] is not None:
                break
        if "first_window_frame_committed" in marks and time.monotonic() - activated > 2.0:
            activate(process.pid)
            activated = time.monotonic()
        # A terminal key that reached the pty: stop typing so its echo closes the sample (a later key would close it
        # unfinished), and post again only if no echo comes within a second.
        holding = which == "terminal" and term["accepted_ms"] is not None and time.monotonic() - last_post < 1.0
        if path == "posted" and keys.cg is not None and not holding:
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
    if which == "terminal":
        term = in_app_terminal_reading(marks) if path == "in_app" else terminal_reading(probe_rows(probe), start_ns)
    row["keys_posted"] = posted
    row["main_ms"] = marks.get("main_start")
    row["first_frame_ms"] = marks.get("first_window_frame_committed")
    if which == "chat":
        row["input_ms"] = marks.get(CHAT_MARK)
        if not args.has_input_mark:
            row["no_mark"] = True  # this build's pages never post the composer's input mark
    else:
        row.update(term)
    row.update(split(row.get("input_ms"), row["main_ms"]))
    row["marks"] = {k: marks[k] for k in KEPT_MARKS if k in marks}
    row["stages"] = launch_stages.spans(marks)
    if process.poll() is not None:
        failures.append(f"the app exited (status {process.poll()})")
    failures += round_failures(which, path, row, marks, args.settle)
    rr.safe_print("TTI-ROUND " + json.dumps(row, default=str), flush=True)
    return row, process, app


# ---- the check ------------------------------------------------------------------------------

def check(args) -> int:
    import fresh_home_launch_smoke as smoke
    result: dict = {"rounds": []}
    keys = Keys()

    def journey(process, socket_path, env, app, out, report):
        out = Path(args.out or Path(env["HOME"]).parent)
        app = Path(app)
        inst = rr.Instance(str(socket_path), str(app), env["HOME"])
        work = os.path.join(env["HOME"], "l5-work")
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
                break
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
    status = smoke.main(argv)
    summary = {}
    for kind in KINDS:
        for which in FRONTS:
            got = [r["input_ms"] for r in result["rounds"] if r.get("kind") == kind and r.get("front") == which
                   and isinstance(r.get("input_ms"), (int, float))]
            summary[f"{kind}_{which}_ms"] = max(got) if got else None
    # Each stage's median per front over the rounds (ms from process start; launch_stages.TABLE names the marks).
    result["stages"] = {which: launch_stages.medians([r.get("stages") for r in result["rounds"] if r.get("front") == which])
                        for which in FRONTS}
    # A chat round on a build without the input mark measured nothing about the app and fails nothing (`no_mark`).
    measured = [r for r in result["rounds"] if isinstance(r.get("input_ms"), (int, float)) or r.get("no_mark")]
    passed = status == 0 and len(result["rounds"]) == len(args.plan) and len(measured) == len(args.plan)
    result.update(summary, verdict="pass" if passed else "fail", post_access=keys.access,
                  input=input_path(keys.access, args.input))
    if args.out:
        with open(Path(args.out) / "tti.json", "w") as handle:
            json.dump(result, handle, indent=2, default=str)
    shown = ("verdict", "post_access", "input", "seed", "seed_error", "stages", *summary)
    print("TTI " + json.dumps({k: result.get(k) for k in shown}),
          flush=True)
    return 0 if passed else (status if status not in (0, None) else 1)


def parse_plan(text: str) -> list[tuple[str, str]]:
    plan = []
    for item in (p.strip() for p in text.split(",") if p.strip()):
        kind, _, which = item.partition(":")
        if kind not in KINDS or which not in FRONTS:
            raise ValueError(f"{item!r}: KIND is one of {', '.join(KINDS)}, FRONT one of {', '.join(FRONTS)}")
        plan.append((kind, which))
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
                                                             "cold_after_update, warm or warm60, FRONT chat or terminal")
    parser.add_argument("--settle", type=float, default=30.0, help="seconds a launch may take to take a key")
    parser.add_argument("--input", choices=("auto", "posted", "in_app"), default="auto",
                        help="who types: posted (CGEventPostToPid, needs the PostEvent grant), in_app (the app's "
                             "LaunchTypeProbe at its first frame), auto (posted when the grant is held)")
    parser.add_argument("--fake-agent", default=str(rr.DEFAULT_FAKE_AGENT))
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    try:
        args.plan = parse_plan(args.plan)
    except ValueError as error:
        parser.error(str(error))
    if args.workspaces < 2:
        parser.error("--workspaces must be at least 2 (the l5 pair)")
    return check(args)


if __name__ == "__main__":
    sys.exit(main())
