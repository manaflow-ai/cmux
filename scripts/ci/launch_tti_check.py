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
  KIND     `cold`: the copy is deleted and copied again (ditto) from the one kept at the start, so the launch is the
           first exec of new files, as after an update in place (launch-ready.sh copy=fresh); `warm`: the same copy
           relaunched right after the quit (launch-ready.sh prerun=0); `warm60`: before it, one full run of the same
           copy that stays up 60 s after its window shows, then quits (launch-ready.sh prerun=60).

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
a chat input_ms is late by at most that; the terminal's is the echo of the key that reached the pty, each key on its own clock. Each round prints `TTI-ROUND {json}`, the run prints `TTI {json}` with its verdict.
Exit 0 when every round measured its front.

A NIGHTLY is a Release build: only release control methods and the bundled CLI are used. Posting keys needs the
process to hold the PostEvent grant; a run without it says `post_access: false` and measures no input.
"""
from __future__ import annotations

import csv
import ctypes
import ctypes.util
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import relaunch_restore_check as rr  # noqa: E402  (its probe set, seed and launch, shared with L5)

KEY_EVERY_S = 0.04
KEY_X = 7  # kVK_ANSI_X
KINDS = ("cold", "warm", "warm60")
FRONTS = ("chat", "terminal")
DEFAULT_PLAN = ("cold:chat,cold:terminal,warm:chat,warm:terminal,warm60:chat,warm60:terminal,"
                "cold:chat,cold:terminal,warm:chat,warm:terminal")
PRERUN_S = 60.0
INPUT_MARK_MESSAGE = b"pane.inputEchoed"  # what a page posts when its composer drew a typed key (the mark's source)
CHAT_MARK = "agent_pane.input_echoed"
KEPT_MARKS = ("main_start", "first_window_frame_committed", "reveal.pane", "reveal.home", "agent_pane.painted",
              CHAT_MARK, "first_terminal_surface_created", "terminal_input_accepted", "terminal_echo")


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


def fresh_copy(app: Path, pristine: Path) -> None:
    shutil.rmtree(app)
    subprocess.run(["ditto", str(pristine), str(app)], check=True, timeout=600)


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
    time.sleep(seconds)
    rr.wait(lambda: rr.call(inst.sock, "system.ping", timeout=2).get("error") is None, 10, 0.25)
    return None, quit_app(inst, process)


def round_once(n: int, kind: str, which: str, process, inst: rr.Instance, app: Path, pristine: Path, env: dict,
               made: dict, keys: Keys, args, out: Path):
    """One quit and measured launch; returns (row, the new process)."""
    row: dict = {"round": n, "kind": kind, "front": which, "workspaces": made.get("list", {}).get("workspaces"),
                 "post_access": keys.access}
    failures = row.setdefault("failures", [])
    put = rr.put_front(inst, which, made)
    if put:
        failures.append(put)
        rr.safe_print("TTI-ROUND " + json.dumps(row, default=str), flush=True)
        return row, process
    why = quit_app(inst, process)
    if why:
        failures.append(why)
    if kind == "cold":
        try:
            fresh_copy(app, pristine)
        except (OSError, subprocess.SubprocessError) as error:
            failures.append(f"the fresh copy failed: {error}")
            rr.safe_print("TTI-ROUND " + json.dumps(row, default=str), flush=True)
            return row, process
    elif kind == "warm60":
        _, why = prerun(inst, app, env, out, PRERUN_S)
        if why:
            failures.append(why)
    probe = out / f"typing-round{n}.csv"
    probe.unlink(missing_ok=True)
    spawned = uptime_ns()
    process, fd, _ = rr.launch(app, {**env, "CMUX_NEXT_TYPING_PROBE": str(probe)}, out / "app-tti.log")
    start_ns = process_start_uptime_ns(process.pid)
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
        if which == "terminal":
            term = terminal_reading(probe_rows(probe), start_ns)
            if term["input_ms"] is not None:
                break
        if "first_window_frame_committed" in marks and time.monotonic() - activated > 2.0:
            activate(process.pid)
            activated = time.monotonic()
        # A terminal key that reached the pty: stop typing so its echo closes the sample (a later key would close it
        # unfinished), and post again only if no echo comes within a second.
        holding = which == "terminal" and term["accepted_ms"] is not None and time.monotonic() - last_post < 1.0
        if keys.cg is not None and not holding:
            keys.post(process.pid)
            posted += 1
            last_post = time.monotonic()
        time.sleep(KEY_EVERY_S)
    time.sleep(0.2)
    read_marks(fd, buf, marks)
    os.close(fd)
    if which == "terminal":
        term = terminal_reading(probe_rows(probe), start_ns)
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
    if process.poll() is not None:
        failures.append(f"the app exited (status {process.poll()})")
    if not keys.access:
        failures.append("this process may not post keys (CGPreflightPostEventAccess false)")
    if row.get("input_ms") is None and not row.get("no_mark"):
        failures.append(f"the {which} took no key within {args.settle:.0f} s")
    rr.safe_print("TTI-ROUND " + json.dumps(row, default=str), flush=True)
    return row, process


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
            row, process = round_once(n, kind, which, process, inst, app, pristine, env, made, keys, args, out)
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
    # A chat round on a build without the input mark measured nothing about the app and fails nothing (`no_mark`).
    measured = [r for r in result["rounds"] if isinstance(r.get("input_ms"), (int, float)) or r.get("no_mark")]
    passed = status == 0 and len(result["rounds"]) == len(args.plan) and len(measured) == len(args.plan)
    result.update(summary, verdict="pass" if passed else "fail", post_access=keys.access)
    if args.out:
        with open(Path(args.out) / "tti.json", "w") as handle:
            json.dump(result, handle, indent=2, default=str)
    print("TTI " + json.dumps({k: result.get(k) for k in ("verdict", "post_access", "seed", "seed_error", *summary)}),
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
    parser.add_argument("--plan", default=DEFAULT_PLAN, help="KIND:FRONT rounds in order; KIND cold, warm or warm60, "
                                                             "FRONT chat or terminal")
    parser.add_argument("--settle", type=float, default=30.0, help="seconds a launch may take to take a key")
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
