#!/usr/bin/env python3
"""Quit gamut (CMUX-630): every way cmux NEXT ends, crossed with what its agents are doing, on a published build.

Leo, 2026-11-16: "What about this? Have we ran the gamut? Tested settled ui fast?" and "Agents stay alive if they
need to. Idle ones can obviously die". One fresh home per run (fresh_home_launch_smoke.py's environment); each
round sets up one STATE, ends the app by one PATH, opens it again into the same HOME and reads three things:

  survives   an agent with work in flight (a turn, a queued message, a running tool) keeps its process (the same
             pid, read from the agent's own answer to `whoami`) and loses no output: after the reopen the turn's
             gate is released through its FIFO and the chat must then hold the turn's text before and after the
             gate, the queued message's answer, the tool's completion. An idle chat must come back bound to its tab
             with its messages and answer a new turn; its agent process may have ended.
  first      ms from the relaunched process's start to its first window frame (`first_window_frame_committed`).
  settled    ms from the process's start to the last launch region shown (`reveal.sidebar`, `reveal.tabs`,
             `reveal.pane` or `reveal.home`, and `agent_pane.painted` when a chat is in front). A region shown by its
             deadline instead of its data (`reveal.<region>.by_deadline`) is pop-in: the round says so.
  prior chat live   Leo, 21:24Z: "when i restart/re-launch... im expecting my prior workspace and the probable agent
             chat session that i had running. so THAT's the importtnt one". ms from the process's start until the
             front window shows the workspace and chat that were in front at the quit (snapshot.get, polled), its
             page is drawn (`agent_pane.painted`) and its stream transport is open (`agent_pane.transport_open`);
             `stream` also checks the reply goes on growing. Beside it, `warm switch`: the median of three switches
             back to that workspace in the running app before the quit, timed the same way (request to shown).

PATHs (only release control methods and the OS, so a NIGHTLY runs it):
  dock       the quit Apple event NSRunningApplication.terminate sends, as the Dock's Quit and Cmd-Q reach
             QuitCoordinator (origin .interactive)
  cmdq       Cmd-Q pressed in the app's key window (a CGEvent, needs this process to hold Accessibility); when it
             cannot be posted the round says so and fails (no measurement)
  scripted   `action.run quit`, the CLI's `cmux app quit` (origin scripted)
  update     Quit and Keep Sessions (the updater's .explicit(.keep)), the bundle swapped in place for --update-dmg's
             app while it is gone, as Sparkle's installer does, then the new app opened: a version handoff
  sparkle-update  the update as a person gets it (CMUX-119): the round starts on --update-dmg's older build with
             automatic downloads and install on quit on (the home's cmux-next.json), asks for an update
             (palette.checkForUpdates) until Sparkle has staged one (updates.status phase "installing") and the
             staged update's launch pre-warm has run, makes the round's STATE, then Quit and Keep Sessions: Sparkle's
             installer replaces the bundle after the app ends, and the newer build Sparkle installed (the feed's
             newest) is opened by the harness, never by Sparkle. The round keeps the updater log's "launch pre-warm"
             lines (prewarm_log). A second round of the same STATE then quits and reopens that build the same way
             with no update (launch "second"), and the first round's first_over_second holds first/second for
             first_window_ms, settled_ms, prior_chat_front_ms and prior_chat_live_ms
  kill       SIGKILL of the app (a crash)
  term       SIGTERM (origin .signal)
Startup paths (startup_paths.py; Leo, 2026-11-17: "i mean across all startups we shoudl be fast ofc"):
  fresh-install  a new user's first launch: a quarantined copy of the DMG, the app copied out and `open`ed with a new
                 HOME, the first-launch prompt answered; --fresh-rounds rows (state first-run), before the gamut boots
  cold-cache     the scripted quit, the disk cache purged (`sudo -n purge`, else a fresh bundle copy), the reopen:
                 a reboot's cold start, approximated (a fleet step cannot reboot)
  loaded         the scripted quit, then the reopen under a fixed synthetic CPU and IO load (the row's `load`)
  after-run      the app left running AFTER_RUN_S (60 s) from its start, the scripted quit, the reopen: a launch after
                 a full run, whose executable pages may have been dropped (back-to-back launches hide this)
STATEs:
  stream     a chat whose reply streams a word 8 times a second through the quit and after it, in front
  idle       a chat with one answered turn, in front
  midturn    a chat whose turn streams "before-gate" and waits on a FIFO, in front
  queued     midturn plus a second message sent while the turn runs (queued in acpmux)
  tool       a turn with a plan step and a tool call in progress, waiting on a FIFO
  long       a chat of --long-turns answered turns of about 4 KB each, in front
  many       --many workspaces with a terminal each (made once), a midturn chat in another workspace, the newest
             terminal in front

  quit_gamut_check.py --dmg DMG [--update-dmg DMG] [--paths dock,scripted,kill,term,update] [--states ...]
      [--out DIR] [--video STATE,...]
Prints one GAMUT-ROUND {json} per round (and GAMUT-RATIO {json} per sparkle-update state) and GAMUT {json} at
the end; writes gamut.json and gamut.md to --out. sparkle-update is not in the default paths (each round downloads
and stages a real update): ask for it with --paths sparkle-update.
--video records the screen (screencapture -v) from the quit to 8 s after the reopen for the named states.
A round with no first window, settled or prior-chat number and no failure fails as "no measurement: <why>" (a
round that did not run included): a run that judged nothing is never green. A fresh-install round whose prompt
nothing could press carries harness_failure (GAMUT's harness_failed), apart from the app's failures.
Exit 0 when every round passed, 1 when one failed, 3 when the run could not start.
"""
from __future__ import annotations

import argparse
import errno
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fresh_home_launch_smoke as smoke  # noqa: E402
import relaunch_restore_check as l5  # noqa: E402
import stable_next_ui_journey as ui  # noqa: E402
import startup_paths as startup  # noqa: E402

PATHS = ("dock", "cmdq", "scripted", "update", "sparkle-update", "kill", "term",
         "fresh-install", "cold-cache", "loaded", "after-run")
REOPEN_PATHS = ("cold-cache", "loaded", "after-run")  # a scripted quit, then a reopen changed by the path
AFTER_RUN_S = 60.0
KEEP_SESSIONS = ("update", "sparkle-update")
# What a person who keeps automatic updates has in their own file (downloadAutomatically is user-only over the
# socket): post-update-hitches.py's settings.
SPARKLE_SETTINGS = {"app": {"quitBehavior": "keep"}, "updates": {"installOnQuit": True, "downloadAutomatically": True}}
STAGE_S = 900.0
PREWARM_S = 120.0
INSTALL_S = 300.0
RATIO_KEYS = ("first_window_ms", "settled_ms", "prior_chat_front_ms", "prior_chat_live_ms")
STATES = ("stream", "idle", "midturn", "queued", "tool", "long", "many")
IN_FLIGHT = ("stream", "midturn", "queued", "tool", "many")
GATED = ("midturn", "queued", "tool", "many")
STREAM_PROMPT = "stream: 900 8"  # idle_cost_agent.py: a word 8 times a second for 15 min, until cancelled
HARNESS = "gamutfake"
REOPEN_S = 45.0


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


# ---- the app ---------------------------------------------------------------------------------

class App:
    """The app this run launches: its process, control socket, launch marks and CLI (l5.Instance)."""

    def __init__(self, bundle: Path, env: dict, root: Path):
        self.bundle, self.env, self.root = bundle, env, root
        self.sock = env["CMUX_NEXT_SOCKET_PATH"]
        self.inst = l5.Instance(self.sock, str(bundle), env["HOME"])
        self.process: subprocess.Popen | None = None
        self.marks: dict[str, float] = {}
        self._marks_fd = -1
        self._partial = b""
        self.started_at = 0.0

    def start(self) -> float:
        if os.path.exists(self.sock):
            os.remove(self.sock)
        self.marks, self._partial = {}, b""
        self.process, self._marks_fd, _ = l5.launch(self.bundle, self.env, self.root / "app.log")
        self.started_at = time.monotonic()
        return time.monotonic()

    def drain(self) -> dict[str, float]:
        try:
            while chunk := os.read(self._marks_fd, 1 << 16):
                self._partial += chunk
        except (BlockingIOError, OSError):
            pass
        whole, _, self._partial = self._partial.rpartition(b"\n")
        for line in whole.decode(errors="replace").splitlines():
            name, _, ms = line.rpartition(" ")
            try:
                self.marks.setdefault(name, round(float(ms)))
            except ValueError:
                pass
        return self.marks

    def close_marks(self) -> None:
        if self._marks_fd >= 0:
            os.close(self._marks_fd)
            self._marks_fd = -1

    def answers(self) -> bool:
        return bool(self.inst.topology())

    def cli(self, *argv: str, timeout: float = 30.0):
        return l5.unwrap(self.inst.cmux(*argv, timeout=timeout))


def quit_app(app: App, path: str) -> tuple[str | None, int | None]:
    """(why it could not be asked, ms from asking to the process gone)."""
    process = app.process
    asked = time.monotonic()
    path = "scripted" if path in REOPEN_PATHS else path
    if path == "dock":
        # NSRunningApplication.terminate sends the quit Apple event the Dock sends; it needs no Automation consent.
        # (JXA calls an ObjC method with no arguments on property access, as in `$.NSString.alloc`; the round
        # still fails below when the app does not end, so an event that was never sent cannot pass.)
        script = (f'ObjC.import("AppKit"); var a = $.NSRunningApplication.runningApplicationWithProcessIdentifier({process.pid}); '
                  'if (a.isNil()) { "gone" } else { var sent = a.terminate; sent ? "sent" : "refused" }')
        done = subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True, timeout=20)
        if "sent" not in done.stdout:
            return f"the quit Apple event was not sent: {(done.stdout + done.stderr).strip()[:200]}", None
    elif path == "cmdq":
        why = press_cmd_q(app)
        if why:
            return why, None
    elif path == "scripted" or path in KEEP_SESSIONS:
        action = "quit" if path == "scripted" else "quitKeepSessions"
        reply = l5.call(app.sock, "action.run", {"action": action}, timeout=10)
        # A quit may end the app before its answer (the update run: "did not finish within 1999 ms", not_run), so
        # an error counts only when the app is still running 20 s later. Then the quit was asked and the app did
        # not end: a failed quit, never a round that did not run (a timed-out action.run quit that never started
        # left three startup rows "not run", with no number and no failure).
        if reply.get("error"):
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
                app.close_marks()
                raise QuitFailed(f"the app did not end within 20 s of the {path} quit "
                                 f"(action.run {action}: {reply['error']})") from None
            app.close_marks()
            return None, round((time.monotonic() - asked) * 1000)
    elif path == "kill":
        os.kill(process.pid, signal.SIGKILL)
    elif path == "term":
        os.kill(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        # Asked and not ended is a failed quit, never a round that did not run.
        process.kill()
        process.wait(timeout=10)
        app.close_marks()
        raise QuitFailed(f"the app did not end within 20 s of the {path} quit")
    app.close_marks()
    return None, round((time.monotonic() - asked) * 1000)


class QuitFailed(Exception):
    pass


def press_cmd_q(app: App) -> str | None:
    """Cmd-Q to the app, activated first: a CGEvent posted to its pid. None when posted."""
    pid = app.process.pid
    script = (
        'ObjC.import("AppKit"); ObjC.import("CoreGraphics"); ObjC.import("ApplicationServices");'
        f'var app = $.NSRunningApplication.runningApplicationWithProcessIdentifier({pid});'
        # 2 is NSApplicationActivateIgnoringOtherApps, 1 kCGEventSourceStateHIDSystemState, 12 the Q key,
        # 1048576 kCGEventFlagMaskCommand.
        'if (app.isNil()) { "gone" } else if (!$.AXIsProcessTrusted()) { "untrusted" } else {'
        ' app.activateWithOptions(2); delay(0.6);'
        ' var src = $.CGEventSourceCreate(1);'
        ' var down = $.CGEventCreateKeyboardEvent(src, 12, true); $.CGEventSetFlags(down, 1048576);'
        ' var up = $.CGEventCreateKeyboardEvent(src, 12, false); $.CGEventSetFlags(up, 1048576);'
        f' $.CGEventPostToPid({pid}, down); $.CGEventPostToPid({pid}, up); "posted" }}')
    done = subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True, timeout=20)
    if "posted" in done.stdout:
        return None
    return f"Cmd-Q could not be pressed: {(done.stdout + done.stderr).strip()[:200]} (this process lacks Accessibility)"


# ---- chats -----------------------------------------------------------------------------------

def chat_items(app: App, chat: str) -> list[dict]:
    """Every transcript item, paged by item id (`chat read --after ID`)."""
    items, after = [], 0
    for _ in range(50):
        read = app.cli("agents", "chat", "read", chat, "--limit", "200", "--after", str(after))
        page = read.get("items") if isinstance(read, dict) else None
        if not isinstance(page, list) or not page:
            break
        items += page
        last = page[-1].get("id")
        if len(page) < 200 or not isinstance(last, int) or last <= after:
            break
        after = last
    return items


def assistant_text(app: App, chat: str) -> str:
    return "\n".join(str(i.get("text") or "") for i in chat_items(app, chat) if i.get("role") == "assistant")


def chat_state(app: App, chat: str) -> dict:
    state = app.cli("agents", "chat", "state", chat, timeout=15)
    return state if isinstance(state, dict) else {}


def new_chat(app: App, workspace: str, name: str, work: str) -> tuple[str, int | None]:
    """A chat on the test agent in WORKSPACE; its first turn is `whoami`, so its answer names the agent's pid."""
    made = app.cli("agents", "chat", "new", "--workspace", workspace, "--harness", HARNESS, "--cwd", work,
                   "--name", name, "--", "whoami", timeout=90)
    chat = made.get("chat") if isinstance(made, dict) else None
    if not chat:
        raise RuntimeError(f"chat new made no chat: {json.dumps(made)[:300]}")
    chat = str(chat)
    pid = None
    for _ in range(120):
        text = assistant_text(app, chat)
        if "pid=" in text:
            pid = int(text.split("pid=", 1)[1].split()[0].strip(".,"))
            break
        time.sleep(0.25)
    return chat, pid


def tool_status(app: App, chat: str) -> str | None:
    """The newest tool item's status (a read's tool items carry kind and status, never the title)."""
    tools = [i for i in chat_items(app, chat) if i.get("role") == "tool"]
    return ((tools[-1].get("tool") or {}).get("status") or tools[-1].get("status")) if tools else None


def count(value) -> int:
    """A queued field as a number: acpmux info gives a count or a list."""
    if isinstance(value, list):
        return len(value)
    return value if isinstance(value, int) else 0


def send(app: App, chat: str, text: str) -> str | None:
    """None, or why the send failed. The mailbox limits every sender, the person too (agent_message_policy.rs: 5
    sends in 10 s, 20 a minute to one chat): a rate-limited send waits and goes again, for at most 75 s."""
    deadline = time.monotonic() + 75
    while True:
        sent = app.inst.cmux("agents", "chat", "send", chat, "--", text, timeout=30)
        error = sent.get("error") if isinstance(sent, dict) and sent.get("error") else None
        reason = ((error or {}).get("details") or {}).get("reason") if isinstance(error, dict) else None
        if reason != "rate_limited" and "rate_limited" not in str(error or ""):
            return error
        if time.monotonic() > deadline:
            return error
        time.sleep(2)


def release(fifo: str) -> str | None:
    """Writes to the FIFO a turn waits on; None, or why not (ENXIO: no process holds it open, the turn is gone)."""
    try:
        fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as error:
        return "no reader: the waiting turn's process is gone" if error.errno == errno.ENXIO else str(error)
    try:
        os.write(fd, b"go\n")
    finally:
        os.close(fd)
    return None


def alive(pid: int | None) -> bool:
    return bool(pid) and smoke.alive(pid)


def wait_for(probe, seconds: float, every: float = 0.2):
    return l5.wait(probe, seconds, every)


# ---- one run ---------------------------------------------------------------------------------

class Gamut:
    def __init__(self, args, root: Path, out: Path):
        self.args, self.root, self.out = args, root, out
        self.work = root / "h" / "gamut-work"
        self.work.mkdir(parents=True, exist_ok=True)
        # The agent is idle_cost_agent.py (fake_agent.py plus "stream:"), copied under ROOT in the repository's own
        # layout (it loads fake_agent.py from ../../cmux-tui/...), so own_pids finds every agent this run started.
        agents = root / "a"
        (agents / "scripts" / "cmux-next").mkdir(parents=True)
        (agents / "cmux-tui" / "crates" / "acpmux" / "tests").mkdir(parents=True)
        shutil.copyfile(args.fake_agent, agents / "cmux-tui" / "crates" / "acpmux" / "tests" / "fake_agent.py")
        shutil.copyfile(HERE.parent / "cmux-next" / "idle_cost_agent.py",
                        agents / "scripts" / "cmux-next" / "idle_cost_agent.py")
        # quit_gamut_agent.py wraps it: it finds the fixture command in a delivery the mailbox framed.
        self.fake = agents / "scripts" / "cmux-next" / "quit_gamut_agent.py"
        shutil.copyfile(HERE / "quit_gamut_agent.py", self.fake)
        self.app: App | None = None
        self.many_made = False
        self.rounds: list[dict] = []
        self.serial = 0
        self.pristine: Path | None = None  # cold-cache's unread copy of the bundle
        self.sparkle: SparkleUpdate | None = None

    def boot(self, bundle: Path, env: dict) -> None:
        self.app = App(bundle, env, self.root)
        self.app.start()
        if not wait_for(self.app.answers, 60, 0.25):
            raise smoke.CannotRun("the app's control socket never answered snapshot.get")
        l5.call(self.app.sock, "system.ping")

    def put_front(self, workspace: str, tab: str | None) -> None:
        self.app.cli("workspace", workspace, "focus")
        if tab:
            self.app.cli("tab", tab, "focus")

    def setup(self, state: str) -> dict:
        """Makes STATE; returns what the checks need."""
        app, n = self.app, self.serial
        made = app.cli("workspace", "create", "--name", f"g{n}-{state}")
        ws = made.get("workspace_id") if isinstance(made, dict) else None
        if not ws:
            raise RuntimeError(f"workspace create: {json.dumps(made)[:300]}")
        case = {"workspace": ws}
        if state == "many" and not self.many_made:
            for i in range(self.args.many):
                app.cli("workspace", "create", "--name", f"many-{i:02d}")
            self.many_made = True
        chat, pid = new_chat(app, ws, f"g{n}-{state}", str(self.work))
        case.update(chat=chat, agent_pid=pid)
        if state == "long":
            filler = "x" * 4000
            def quiet():
                st = chat_state(app, chat)
                return not st.get("running") and not count(st.get("queued"))
            for t in range(self.args.long_turns):
                why = send(app, chat, f"long turn {t} {filler}")
                if why:
                    raise RuntimeError(f"long chat turn {t}: {why}")
                wait_for(quiet, 30, 0.05)
            if not wait_for(lambda: assistant_text(app, chat).count("long turn") >= self.args.long_turns, 60, 0.5):
                raise RuntimeError(f"the long chat has {assistant_text(app, chat).count('long turn')} of "
                                   f"{self.args.long_turns} answers")
            case["long_messages"] = len(chat_items(app, chat))
        if state == "stream":
            why = send(app, chat, STREAM_PROMPT)
            if why:
                raise RuntimeError(f"send: {why}")
            if not wait_for(lambda: assistant_text(app, chat).count("word") >= 8, 30, 0.25):
                raise RuntimeError(f"the stream never started: {json.dumps(chat_state(app, chat))[:300]}")
        if state in GATED:
            fifo = str(self.work / f"g{n}.fifo")
            if os.path.exists(fifo):
                os.remove(fifo)
            os.mkfifo(fifo)
            case["fifo"] = fifo
            prompt = f"work-gate: {fifo} | Run cargo test" if state == "tool" else f"gate: {fifo}"
            why = send(app, chat, prompt)
            if why:
                raise RuntimeError(f"send: {why}")
            # A read hides a running turn's unfinished words (visible_text) and never shows a tool's title, so the
            # turn has started when the chat says it runs (and, for `tool`, has a tool item in progress).
            def started():
                if not chat_state(app, chat).get("running"):
                    return False
                return state != "tool" or tool_status(app, chat) in ("pending", "in_progress")
            if not wait_for(started, 30):
                raise RuntimeError(f"the {state} turn never started: {json.dumps(chat_state(app, chat))[:300]}")
            if state == "queued":
                why = send(app, chat, "queued-echo-7")
                if why or not wait_for(lambda: count(chat_state(app, chat).get("queued")) >= 1, 10):
                    case["queued_note"] = (f"the second message was not seen queued: {why or ''} "
                                           f"{json.dumps(chat_state(app, chat))[:200]}")
        case["state_before"] = chat_state(app, chat)
        topo = app.inst.topology()
        case["chat_tab"] = l5.chat_tab_id(topo, chat)
        if state == "many":
            term_ws = l5.workspace_named(topo, f"many-{self.args.many - 1:02d}")
            self.put_front(term_ws["id"] if term_ws else ws, None)
        else:
            self.put_front(ws, case["chat_tab"])
            # The baseline Leo's target is set against: a warm switch back to this workspace, from another, in the
            # running app, timed the same way the reopen's front is (until the snapshot shows it in front).
            case["warm_switch_ms"] = self.warm_switch(ws, case["chat_tab"], chat)
        case["workspaces"] = len((topo or {}).get("workspaces") or [])
        return case

    def shows(self, chat: str, topo: dict | None = None) -> bool:
        """The front window shows CHAT's workspace with the chat's tab selected."""
        topo = topo if topo is not None else self.app.inst.topology()
        return any(t.get("agent_session") == chat for w in l5.front(topo) for t in w.get("selected") or [])

    def warm_switch(self, ws: str, tab: str | None, chat: str) -> float | None:
        """Median ms of three switches to WS (its chat tab in front) from another workspace, request to shown."""
        other = next((w.get("id") for w in (self.app.inst.topology() or {}).get("workspaces") or []
                      if w.get("id") != ws and w.get("kind") != "home"), None)
        if not other:
            return None
        samples = []
        for _ in range(3):
            self.app.cli("workspace", other, "focus")
            wait_for(lambda: not self.shows(chat), 5, 0.02)
            asked = time.monotonic()
            self.put_front(ws, tab)
            if wait_for(lambda: self.shows(chat), 5, 0.01):
                samples.append((time.monotonic() - asked) * 1000)
        return round(sorted(samples)[len(samples) // 2]) if samples else None

    def check(self, state: str, case: dict, row: dict) -> list[str]:
        """After the reopen: the chat back, in-flight work finished with nothing lost."""
        app, chat, failures = self.app, case["chat"], []
        if not wait_for(lambda: l5.chat_tab(app.inst.topology(), chat), 20):
            failures.append("the chat's tab is not back")
        # The history before the quit is all there: the first turn's `whoami` answer (its pid) in every chat, and
        # every answer in the long one, in order.
        text = assistant_text(app, chat)
        if case.get("agent_pid") and f"pid={case['agent_pid']}" not in text:
            failures.append("the chat's history before the quit is gone (its first answer is missing)")
        before_items = case.get("long_messages")
        if before_items is not None:
            now = len(chat_items(app, chat))
            row["long_messages_after"] = now
            answers = [int(line.split()[2]) for line in text.splitlines() if line.startswith("long turn ")]
            if now < before_items or answers[:self.args.long_turns] != list(range(self.args.long_turns)):
                failures.append(f"the long chat lost history: {now} items (had {before_items}), "
                                f"{len(answers)} of {self.args.long_turns} answers in order")
        in_flight = state in IN_FLIGHT
        row["agent_pid_before"] = case.get("agent_pid")
        row["agent_alive_after"] = alive(case.get("agent_pid"))
        if in_flight and not row["agent_alive_after"]:
            failures.append(f"the agent with work in flight (pid {case.get('agent_pid')}) ended")
        if state == "stream":
            # Still streaming: the reply grows over the next 2 s, then the turn is cancelled.
            before = assistant_text(app, chat).count("word")
            time.sleep(2)
            after = assistant_text(app, chat).count("word")
            row["stream_words_in_2s"] = after - before
            if after <= before:
                failures.append(f"the reply stopped streaming after the reopen ({before} words, then {after})")
            app.cli("agents", "chat", "interrupt", chat)
        elif in_flight:
            row["state_after_reopen"] = chat_state(app, chat)
            why = release(case["fifo"])
            if why:
                failures.append(f"releasing the turn: {why}")
            want = ["worked"] if state == "tool" else ["before-gate", "after-gate"]
            if state == "queued":
                want.append("queued-echo-7")
            def finished():
                text = assistant_text(app, chat)
                st = chat_state(app, chat)
                return all(w in text for w in want) and not st.get("running") and not count(st.get("queued"))
            if not wait_for(finished, 30, 0.25):
                text = assistant_text(app, chat)
                failures.append(f"output lost: missing {[w for w in want if w not in text]} "
                                f"(state {json.dumps(chat_state(app, chat))[:200]})")
            if state == "tool":
                row["tool_status"] = tool_status(app, chat)
                if row["tool_status"] != "completed":
                    failures.append(f"the running tool ended {row['tool_status']}, not completed")
        else:
            started = time.monotonic()
            send(app, chat, "after-reopen-echo")
            if wait_for(lambda: "after-reopen-echo" in assistant_text(app, chat), 30, 0.1):
                row["idle_answer_ms"] = round((time.monotonic() - started) * 1000)
            else:
                failures.append("the idle chat did not answer a new turn within 30 s")
        return failures

    def record_start(self, name: str) -> subprocess.Popen | None:
        if not self.args.video or not any(name.endswith(s) for s in self.args.video):
            return None
        movie = self.out / f"{name}.mov"
        try:
            return subprocess.Popen(["screencapture", "-x", "-v", "-V", "22", str(movie)],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        except OSError as error:
            log(f"video: {error}")
            return None

    def round(self, path: str, state: str, update_bundle: Path | None, staged: dict | None = None) -> dict:
        self.serial += 1
        second = path == "sparkle-update" and staged is None
        name = f"{path}-{state}" + ("-second" if second else "")
        row: dict = {"round": self.serial, "path": path, "state": state}
        if path == "sparkle-update":
            row["launch"] = "second" if second else "first"
            row.update(staged or {})
        failures: list[str] = row.setdefault("failures", [])
        try:
            case = self.setup(state)
        except RuntimeError as error:
            row["setup_error"] = str(error)
            failures.append(f"setup: {error}")
            return row
        row["workspaces"] = case["workspaces"]
        row["state_before"] = case.get("state_before")
        if case.get("queued_note"):
            row["queued_note"] = case["queued_note"]
        if path == "after-run":
            # The condition is the app's age itself: it has run AFTER_RUN_S before it is quit.
            row["ran_s"] = round(max(AFTER_RUN_S, time.monotonic() - self.app.started_at), 1)
            time.sleep(max(0.0, AFTER_RUN_S - (time.monotonic() - self.app.started_at)))
        processes_before = set(smoke.own_pids(self.root))
        recorder = self.record_start(name)
        time.sleep(0.5 if recorder else 0)
        try:
            why, quit_ms = quit_app(self.app, path)
        except QuitFailed as error:
            why, quit_ms = None, None
            failures.append(str(error))
        row["quit_ms"] = quit_ms
        if why:
            row["not_run"] = why
            if self.app.process.poll() is None:
                return row
        row["agent_alive_while_quit"] = alive(case.get("agent_pid"))
        gone = smoke.own_pids(self.root)
        row["processes_ended_with_app"] = len(processes_before - set(gone) - {self.app.process.pid})
        if path == "update" and update_bundle is not None:
            swap_bundle(self.app.bundle, update_bundle)
        if staged is not None:
            # Sparkle's installer replaces the bundle once the app has ended (install on quit); the harness opens it.
            why = self.sparkle.installed(row)
            if why:
                failures.append(why)
                return row
        load = None
        if path == "cold-cache":
            row["cold"] = startup.make_cold(self.app.bundle, self.pristine, swap_bundle)
        elif path == "loaded":
            load = startup.SyntheticLoad(self.root)
            row["load"] = load.start()
        started = self.app.start()
        row["timeline"] = []
        settled_at = front_ms = None
        chat_front = state != "many"
        while time.monotonic() - started < REOPEN_S and self.app.process.poll() is None:
            marks = self.app.drain()
            # Leo's number (2026-11-16 21:24Z): the prior workspace selected with its chat in front. The snapshot
            # answers once the control socket is up; the first poll that shows the chat in front is its time.
            if chat_front and front_ms is None and self.shows(case["chat"]):
                front_ms = round((time.monotonic() - started) * 1000)
            # Settled: the window, the sidebar, the tab strips and what the front pane shows (the chat drawn, or the
            # terminal's first frame) are all in. Each mark is ms since the process started.
            content = marks.get("agent_pane.painted") if chat_front else marks.get("reveal.pane")
            needed = [marks.get("first_window_frame_committed"), marks.get("reveal.sidebar"), marks.get("reveal.tabs"), content]
            if all(v is not None for v in needed) and (front_ms is not None or not chat_front):
                settled_at = max(needed)
                break
            time.sleep(0.05)
        if load is not None:
            row["load"].update(load.stop())  # the load lasts until the reopen settled (or REOPEN_S)
        marks = self.app.drain()
        # The chat draws from the launch snapshot before its stream connects (first fleet runs: painted at 1664 ms,
        # no transport_open_start yet), so live waits on past settled, for the transport mark.
        while (chat_front and "agent_pane.transport_open" not in marks and time.monotonic() - started < REOPEN_S
               and self.app.process.poll() is None):
            time.sleep(0.05)
            marks = self.app.drain()
        if chat_front:
            # The chat back and live: in front, its page drawn and its stream transport open (agent_pane marks).
            parts = [front_ms, marks.get("agent_pane.painted"), marks.get("agent_pane.transport_open")]
            row["prior_chat_front_ms"] = front_ms
            row["prior_chat_live_ms"] = max(parts) if all(p is not None for p in parts) else None
            row["warm_switch_ms"] = case.get("warm_switch_ms")
            if row["prior_chat_live_ms"] and row["warm_switch_ms"]:
                row["live_over_warm_switch"] = round(row["prior_chat_live_ms"] / max(row["warm_switch_ms"], 1), 1)
        if recorder:
            time.sleep(8)
            recorder.terminate()
            try:
                _, err = recorder.communicate(timeout=10)
                row["video"] = f"{name}.mov" if (self.out / f"{name}.mov").exists() else f"none: {err.decode(errors='replace')[:200]}"
            except subprocess.TimeoutExpired:
                recorder.kill()
        row["first_window_ms"] = marks.get("first_window_frame_committed")
        row["settled_ms"] = settled_at
        row["pop_in"] = sorted(k[:-len(".by_deadline")] for k in marks if k.endswith(".by_deadline"))
        row["marks"] = {k: v for k, v in marks.items() if k.startswith(("first_", "reveal.", "agent_pane.", "daemon.",
                                                                       "launch_", "main_start", "connecting_"))}
        if self.app.process.poll() is not None:
            failures.append(f"the reopened app exited (status {self.app.process.poll()})")
            return row
        if not wait_for(self.app.answers, 20, 0.1):
            failures.append("the reopened app's control socket never answered")
            return row
        if row["first_window_ms"] is None:
            failures.append("no first window frame")
        if settled_at is None:
            failures.append(f"not settled within {REOPEN_S:.0f} s (marks {sorted(marks)[:40]})")
        if row["pop_in"]:
            failures.append(f"pop-in: {', '.join(row['pop_in'])} shown by its deadline, not its data")
        failures += self.check(state, case, row)
        return row

    def run(self, bundle: Path, env: dict, update_bundle: Path | None, previous: Path | None) -> None:
        def emit(row: dict) -> None:
            self.rounds.append(judge_measured(row))
            print("GAMUT-ROUND " + json.dumps(row, default=str), flush=True)

        def restart() -> None:
            if self.app.process.poll() is not None:
                self.app.start()
                wait_for(self.app.answers, 60, 0.25)

        for path in self.args.paths:
            for state in self.args.states:
                staged = None
                if path in KEEP_SESSIONS:
                    if previous is None:
                        emit({"path": path, "state": state, "not_run": "no older nightly to update from (--update-dmg)"})
                        continue
                    # The round starts on the older build, so the reopen is a real version handoff.
                    if self.app.process.poll() is None:
                        try:
                            quit_app(self.app, "scripted")
                        except QuitFailed as error:
                            log(f"before the update round: {error}")
                    swap_bundle(self.app.bundle, previous)
                    if path == "sparkle-update":
                        self.sparkle = self.sparkle or SparkleUpdate(Path(env["HOME"]), self.app.bundle)
                        self.sparkle.prepare()
                    self.app.start()
                    if not wait_for(self.app.answers, 60, 0.25):
                        emit({"path": path, "state": state, "failures": ["the older build never answered"]})
                        if self.sparkle:
                            self.sparkle.restore()
                        continue
                    if path == "sparkle-update":
                        staged = self.sparkle.stage(self.app)
                        if staged.get("failures"):
                            emit({"path": path, "state": state, "launch": "first", **staged})
                            self.sparkle.restore()
                            restart()
                            continue
                row = self.round(path, state, update_bundle, staged)
                emit(row)
                restart()
                if staged is not None and not row.get("installed_build"):
                    self.sparkle.restore()  # the round stopped before the install: no second launch to compare
                elif staged is not None:
                    # The second launch of the build Sparkle installed: the same quit and reopen, no update.
                    second = self.round(path, state, None)
                    emit(second)
                    row["first_over_second"] = {k: round(row[k] / second[k], 2) for k in RATIO_KEYS
                                                if row.get(k) and second.get(k)}
                    print("GAMUT-RATIO " + json.dumps({"state": state, "build": row.get("installed_build"),
                                                       **row["first_over_second"]}), flush=True)
                    restart()


def bundle_build(bundle: Path) -> str | None:
    try:
        with open(bundle / "Contents" / "Info.plist", "rb") as handle:
            return str(plistlib.load(handle).get("CFBundleVersion"))
    except (OSError, plistlib.InvalidFileException):
        return None


class SparkleUpdate:
    """The `sparkle-update` path's update: staged by the older build's own Sparkle, installed by Sparkle on quit."""

    def __init__(self, home: Path, bundle: Path):
        self.home, self.bundle = home, bundle
        self.bundle_id, _ = smoke.bundle_info(bundle)
        self.settings = home / ".config" / "cmux" / "cmux-next.json"
        self.saved: str | None = None
        self.from_build: str | None = None
        # UpdateLogFile: Library/Logs/cmux-next/<bundle id>-updater.log, in the private home (CFFIXED_USER_HOME);
        # the account's own is read too, in case the log follows the account's home as Sparkle's installer does.
        name = f"{self.bundle_id}-updater.log"
        self.logs = [home / "Library/Logs/cmux-next" / name, Path(os.path.expanduser("~")) / "Library/Logs/cmux-next" / name]
        self.offsets: dict[Path, int] = {}

    def prepare(self) -> None:
        """Before the older build starts: the home's update settings and Sparkle's staging folder."""
        self.from_build = bundle_build(self.bundle)
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        if self.saved is None:
            self.saved = self.settings.read_text() if self.settings.exists() else ""
        current = json.loads(self.saved) if self.saved.strip() else {}
        for group, values in SPARKLE_SETTINGS.items():
            current.setdefault(group, {}).update(values)
        self.settings.write_text(json.dumps(current, indent=1))
        # The one-time "forget stored defaults" pass drops installOnQuit (true was a former default) from a file
        # with no record of it, and quit then cancels the staged update (post-update-hitches.py, cmux9s 2026-11-16).
        record = self.settings.with_name("cmux-next.json.defaults-forgotten.json")
        if not record.exists():
            record.write_text(json.dumps({"note": "quit gamut: this home's settings are a person's picks",
                                          "dropped": {}, "kept": {}}, indent=1))
        # Sparkle's installer runs from launchd with the account's home and stages under its Library/Caches; the app
        # looks under the private home. The private folder points at the account's, so both see the staged bundle
        # and the app's pre-warm finds it, as a person's app does (post-update-hitches.py, #44632).
        sparkle = Path("Library/Caches") / self.bundle_id / "org.sparkle-project.Sparkle"
        account = Path(os.path.expanduser("~")) / sparkle
        account.mkdir(parents=True, exist_ok=True)
        (self.home / sparkle).parent.mkdir(parents=True, exist_ok=True)
        if not (self.home / sparkle).exists():
            (self.home / sparkle).symlink_to(account, target_is_directory=True)
        self.offsets = {log_path: log_path.stat().st_size if log_path.exists() else 0 for log_path in self.logs}

    def restore(self) -> None:
        """The home's settings as they were: no later round installs or downloads an update."""
        if self.saved is not None:
            self.settings.write_text(self.saved) if self.saved else self.settings.unlink(missing_ok=True)
            self.saved = None

    def prewarm_lines(self) -> list[str]:
        lines = []
        for log_path, start in self.offsets.items():
            try:
                with open(log_path, "rb") as handle:
                    handle.seek(start)
                    lines += [line for line in handle.read().decode(errors="replace").splitlines() if "launch pre-warm" in line]
            except OSError:
                pass
        return lines

    def stage(self, app: App) -> dict:
        """Asks the running older build for an update until Sparkle has staged one and its pre-warm has ended."""
        result: dict = {"from_build": self.from_build}
        asked = time.monotonic()
        reply = l5.call(app.sock, "action.run", {"action": "palette.checkForUpdates"}, timeout=30)
        if reply.get("error"):
            result["failures"] = [f"action.run palette.checkForUpdates: {reply['error']}"]
            return result
        status: dict = {}
        def installing() -> bool:
            nonlocal status
            status = l5.call(app.sock, "updates.status", timeout=10)
            return status.get("phase") == "installing"
        if not wait_for(installing, STAGE_S, 2.0):
            result["failures"] = [f"no update staged in {STAGE_S:.0f} s: {json.dumps(status)[:300]}"]
            return result
        result["stage_s"] = round(time.monotonic() - asked, 1)
        result["staged_version"] = status.get("detected_version")
        # The pre-warm's last line: "... ms in all", "nothing to run" or "no staged bundle" (StagedUpdatePrewarm).
        done = wait_for(lambda: any(("in all" in line or "nothing to run" in line or "no staged bundle" in line)
                                    for line in self.prewarm_lines()), PREWARM_S, 1.0)
        result["prewarm_log"] = self.prewarm_lines()
        result["prewarm_done"] = bool(done)
        return result

    def installed(self, row: dict) -> str | None:
        """After the quit: waits for Sparkle's installer to replace the bundle; None, or why the round fails."""
        try:
            started = time.monotonic()
            if not wait_for(lambda: bundle_build(self.bundle) not in (None, self.from_build), INSTALL_S, 1.0):
                return f"install on quit left build {bundle_build(self.bundle)} (from {self.from_build}) after {INSTALL_S:.0f} s"
            row["installed_build"] = bundle_build(self.bundle)
            row["install_s"] = round(time.monotonic() - started, 1)
            row["prewarm_log"] = self.prewarm_lines()
            time.sleep(3)  # harness: a relaunch by Sparkle would show by now
            executable = str(self.bundle / "Contents" / "MacOS") + "/"
            ps = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True, timeout=20).stdout
            relaunched = [line.split()[0] for line in ps.splitlines() if line.strip().split(None, 1)[-1].startswith(executable)]
            if relaunched:
                return f"something relaunched the app (pid {', '.join(relaunched)}): the reopen would lose its environment"
            return None
        finally:
            self.restore()


def swap_bundle(bundle: Path, source: Path) -> None:
    """Replaces BUNDLE with a copy of SOURCE at the same path while the app is gone: copied beside it, then renamed
    over it, as Sparkle's installer does."""
    staged = bundle.with_name(bundle.name + ".staged")
    if staged.exists():
        shutil.rmtree(staged)
    subprocess.run(["ditto", str(source), str(staged)], check=True, timeout=600)
    old = bundle.with_name(bundle.name + ".old")
    if old.exists():
        shutil.rmtree(old)
    os.rename(bundle, old)
    os.rename(staged, bundle)
    shutil.rmtree(old)


MEASURES = ("first_window_ms", "settled_ms", "prior_chat_front_ms", "prior_chat_live_ms")


def judge_measured(row: dict) -> dict:
    """A row that measured nothing (no first window, settled or prior-chat number) and failed nothing fails with
    why: a round that judged nothing is never green."""
    if not row.get("failures") and all(row.get(k) is None for k in MEASURES):
        why = row.get("not_run") or row.get("setup_error") or "the round recorded no number"
        row.setdefault("failures", []).append(f"no measurement: {why}")
    return row


def table(rows: list[dict]) -> str:
    lines = ["| quit | state | survives | first window (ms) | settled (ms) | prior chat live (ms) | warm switch (ms) | "
             "quit (ms) | notes |", "|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        if r.get("not_run"):
            notes = "; ".join(r.get("failures") or []) or r["not_run"]
            lines.append(f"| {r['path']} | {r['state']} | {'NO, ' if r.get('failures') else ''}not run | | | | | | {notes} |")
            continue
        ok = "yes" if not r.get("failures") else "NO (harness)" if r.get("harness_failure") else "NO"
        notes = "; ".join(r.get("failures") or [])
        if r.get("state") in IN_FLIGHT and not r.get("failures"):
            notes = f"agent pid {r.get('agent_pid_before')} kept"
        if r.get("path") == "fresh-install":
            gate = r.get("gate") or {}
            notes = (f"from open: spawn {r.get('open_to_spawn_ms')}, first window {r.get('open_to_first_window_ms')}, "
                     f"settled {r.get('open_to_settled_ms')}; prompt by {r.get('prompt_route')}, shown "
                     f"{r.get('prompt_shown_ms')}, wait {r.get('prompt_wait_ms')}; syspolicyd "
                     f"{gate.get('syspolicyd_span_ms')}, XProtect {gate.get('xprotect_span_ms')} ms; {notes}")
        elif r.get("cold") or r.get("load"):
            notes = f"{json.dumps(r.get('cold') or r.get('load'))}; {notes}"
        if r.get("launch"):
            ratio = r.get("first_over_second")
            notes = (f"{r['launch']} launch of {r.get('installed_build') or 'this build'}"
                     + (f", first/second {json.dumps(ratio)}" if ratio else "") + (f"; {notes}" if notes else ""))
        lines.append(f"| {r['path']} | {r['state']} | {ok} | {r.get('first_window_ms')} | {r.get('settled_ms')} | "
                     f"{r.get('prior_chat_live_ms')} | {r.get('warm_switch_ms')} | {r.get('quit_ms')} | {notes[:300]} |")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dmg", required=True)
    parser.add_argument("--update-dmg", help="the older build the update rounds start on (the newer one is --dmg)")
    parser.add_argument("--paths", default="dock,cmdq,scripted,kill,term,update")
    parser.add_argument("--states", default=",".join(STATES))
    parser.add_argument("--many", type=int, default=32)
    parser.add_argument("--long-turns", type=int, default=40)  # the mailbox takes 20 a minute to one chat
    parser.add_argument("--video", default="")
    parser.add_argument("--fake-agent", default=str(l5.DEFAULT_FAKE_AGENT))
    parser.add_argument("--fresh-rounds", type=int, default=3, help="fresh-install: installs and first launches")
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    args.paths = [p for p in args.paths.split(",") if p]
    args.states = [s for s in args.states.split(",") if s]
    args.video = [s for s in args.video.split(",") if s]
    bad = [p for p in args.paths if p not in PATHS] + [s for s in args.states if s not in STATES]
    if bad:
        parser.error(f"unknown: {bad}")
    os.umask(0o022)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="cmux-gq-", dir="/tmp"))
    signal.signal(signal.SIGTERM, lambda s, _f: (_ for _ in ()).throw(SystemExit(128 + s)))
    gamut = Gamut(args, root, out)
    status = 3
    try:
        problem = smoke.gui_session_problem()
        if problem:
            raise smoke.CannotRun(problem)
        if "fresh-install" in args.paths:
            # Before the gamut's own home exists: each round is its own install, home and defaults set-aside.
            for index in range(1, args.fresh_rounds + 1):
                row = judge_measured(startup.fresh_install_round(smoke, Path(args.dmg), index, prepare_env=ui.login_keychain))
                gamut.rounds.append(row)
                print("GAMUT-ROUND " + json.dumps(row, default=str), flush=True)
            args.paths = [p for p in args.paths if p != "fresh-install"]
        bundle = smoke.copy_app_from_dmg(Path(args.dmg), root)
        newer = previous = None
        if args.update_dmg:
            side = root / "older"
            side.mkdir()
            previous = smoke.copy_app_from_dmg(Path(args.update_dmg), side)
            newer = root / "newer.app"
            subprocess.run(["ditto", str(bundle), str(newer)], check=True, timeout=600)
        if "cold-cache" in args.paths:
            # Without passwordless sudo, cold-cache swaps in a copy no process has read (startup.make_cold).
            (root / "pristine").mkdir()
            gamut.pristine = root / "pristine" / bundle.name
            subprocess.run(["ditto", str(bundle), str(gamut.pristine)], check=True, timeout=600)
        if args.paths:
            bundle_id, _ = smoke.bundle_info(bundle)
            with smoke.DefaultsAside(bundle_id, root):
                env = smoke.fresh_env(root, root / "s.sock", -1)
                env.pop("CMUX_NEXT_LAUNCH_MARKS_FD", None)
                ui.login_keychain(env)
                folder = Path(env["HOME"]) / ".config" / "cmux" / "harnesses"
                folder.mkdir(parents=True, exist_ok=True)
                (folder / f"{HARNESS}.toml").write_text(
                    f'schema = 1\nid = "{HARNESS}"\nname = "Gamut test agent"\nprotocol = "acp"\n'
                    f'command = "/usr/bin/python3"\nargs = [{json.dumps(str(gamut.fake))}]\n')
                gamut.boot(bundle, env)
                gamut.app.cli("setup", "trust", str(gamut.work))
                gamut.run(bundle, env, newer, previous)
                if gamut.app.process and gamut.app.process.poll() is None:
                    l5.call(gamut.app.sock, "action.run", {"action": "quitEndEverything"}, timeout=10)
                    try:
                        gamut.app.process.wait(timeout=20)
                    except subprocess.TimeoutExpired:
                        pass
                smoke.stop_child(gamut.app.process)
                smoke.stop(smoke.own_pids(root))
        rounds = [judge_measured(r) for r in gamut.rounds]
        status = 0 if rounds and all(not r.get("failures") for r in rounds) else 1
    except (smoke.CannotRun, OSError, subprocess.SubprocessError) as error:
        log(f"CANNOT RUN: {error}")
    finally:
        startup.SyntheticLoad.stop_all()  # a `loaded` round that raised mid-reopen
        if gamut.app and gamut.app.process and gamut.app.process.poll() is None:
            smoke.stop_child(gamut.app.process)
        smoke.stop(smoke.own_pids(root))
        (out / "gamut.json").write_text(json.dumps({"rounds": gamut.rounds, "status": status}, indent=2, default=str))
        (out / "gamut.md").write_text(table(gamut.rounds))
        shutil.copyfile(root / "app.log", out / "app.log") if (root / "app.log").exists() else None
        shutil.rmtree(root, ignore_errors=True)
    print("GAMUT " + json.dumps({"status": status, "rounds": len(gamut.rounds),
                                 "failed": [f"{r['path']}-{r['state']}" for r in gamut.rounds if r.get("failures")],
                                 "harness_failed": [f"{r['path']}-{r['state']}" for r in gamut.rounds
                                                    if r.get("harness_failure")]}), flush=True)
    print(table(gamut.rounds), flush=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
