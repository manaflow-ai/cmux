#!/usr/bin/env python3
"""Run user journeys against one launched cmux NEXT DEV app, on the Mac where it runs.

run.py sends this file to a leased capture slot (with build_names.py and the journey specs) and
starts it there with the stock /usr/bin/python3 (3.9: standard library only):

    driver.py --socket S --app APP --home HOME --journeys specs.json --out DIR --ocr OCR
              [--deadline-seconds N] [--frame-interval S]

Each journey is a list of steps (README.md, "Steps and conditions"). The driver plays them
through the same interfaces a person's input and the app's own state go through:

  - keys: `debug.key`, a key-down dispatched the way NSApplication.sendEvent does (the key
    router, window key equivalents, the menu, then the responder chain): the real key path;
  - app state: the control socket (`debug.surfaces` with the pane's viewport text);
  - daemon state: the bundled `cmux` CLI on the app's own daemon (`terminal ID screen read`);
  - processes: the Mac's process table (`ps`), scoped to the terminal's `__terminal-host`;
  - frames: the app's own drawing of its main window (`debug.window_snapshot`), read with
    macOS text recognition (OCR, scripts/ci/pr_media_ocr.swift compiled by run.py).

It writes DIR/<journey id>/result.json (status pass, fail or not run, every step and every
piece of evidence), DIR/<id>/frames/ (the window about every --frame-interval seconds, for the
clip) and DIR/<id>/check-NN.png (each frame a check read). A journey passes only when every
step ran, every condition held, and the passing evidence covers app state, the daemon screen
and a frame. Exit 0 when every journey passed, 1 otherwise.
"""
import argparse
import hashlib
import json
import os
import random
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # build_names.py beside it, also under -I
import build_names  # noqa: E402

PROMPT = "J> "
# The prompt every journey's shell gets (neutral: no host, user or path in any frame).
NEUTRAL_PROMPT = "PS1='J> '; PROMPT='J> '; RPROMPT=''; unset PROMPT_COMMAND; cd /tmp; printf '\\033[H\\033[2J\\033[3J'\r"
# Before it, the shell writes its tty to {tty_file} (its own short line, which the neutral prompt's clear then
# removes): one terminal host runs the shells of every terminal (one tty each), and process checks look only
# at this terminal's tty.
TTY_PROBE = "tty >| {tty_file}\r"
RPC_TIMEOUT = 30.0
SNAPSHOT_TIMEOUT = 30.0
POLL_SECONDS = 0.05
FRAME_INTERVAL = 1.0
MAX_FRAMES = 240
CLIP_WIDTH = 1280
# Seconds of fresh snapshots a frame check gets once the state it should show holds.
FRAME_GRACE = 10.0
# Evidence a passing journey must have: the user-visible result seen three independent ways.
REQUIRED_KINDS = ("app", "daemon", "frame")
KIND = {"daemon_line": "daemon", "daemon_contains": "daemon", "daemon_prompt": "daemon",
        "app_text_line": "app", "app_text_contains": "app", "app_prompt": "app", "app_pane": "app",
        "process_present": "process", "process_gone": "process", "frame_text": "frame",
        # Negative reads, scrollback rows and the clipboard ("Scroll, paste, select" below).
        "daemon_lacks": "daemon", "daemon_history": "daemon", "app_text_lacks": "app", "app_rows": "app",
        "frame_screen": "frame", "clipboard": "clipboard", "quit_leftovers": "process",
        # App life (journeys/p0/app-life-*.json): layout, working directories, restore and settings.
        "daemon_cwd": "daemon", "daemon_grid": "daemon", "daemon_pane_ready": "daemon",
        "app_cwd": "app", "app_layout": "app", "app_tab_pane": "app", "app_tab_gone": "app", "app_rpc": "app",
        "app_grid": "app"}
# Conditions an extension module adds (ext_*.py beside this file, load_extensions): name -> fn(journey, want, cache).
EXT_CONDITIONS = {}
# The extension conditions that are negative (an extension's NEGATIVE): read again every poll, never latched.
EXT_NEGATIVE = set()
# `relaunch` kinds that quit through the app's own quit actions, with no dialog (QuitOrigin.explicit).
QUIT_ACTIONS = {"quit-keep": "quitKeepSessions", "quit-end-sessions": "quitEndSessions",
                "quit-end-everything": "quitEndEverything"}
# Seconds a quit (Cmd-Q or a crash) may take to end the app's process, and a relaunch to answer.
QUIT_SECONDS = 60
RELAUNCH_SECONDS = 90
# A capture slot's window is never the key window (the app runs with CMUX_NEXT_NO_ACTIVATE). Keys typed while
# the app holds them for a terminal still being made (CreationInputCoordinator: after Cmd-D, Ctrl-` or a restore,
# at most its holdLimit of 2 s) are replayed through NSApp.sendEvent, which only reaches the key window, so in a
# slot they are lost (a person's window is key). Steps that make a terminal wait this long before the next key.
CREATION_HOLD_SECONDS = 2.5
# The app's New Terminal Tab key (newSurface, TabActionCatalog's default Ctrl-`): what a person presses for a
# new terminal. On Home it opens a workspace with a terminal; in a workspace, a terminal tab in the focused pane.
NEW_TERMINAL_KEY = {"key": "`", "modifiers": ["control"]}
# Launch variables a relaunch passes on (restore-journey.py's rule): what a capture slot sets.
LAUNCH_ENV = re.compile(r"^(CMUX_[A-Z0-9_]*|HOME|TMPDIR)$")


def now():
    return time.monotonic()


class StepError(Exception):
    pass


class Deadline(Exception):
    pass


class NotRun(Exception):
    """The journey cannot be played in this app (for example: it needs a fresh app and another journey ran first)."""


# Journeys already played in this app process (first launch needs none before it).
PLAYED = []


# ---- the app: control socket, daemon CLI, process table, frames -----------------------------

class App:
    def __init__(self, sock, bundle, home, ocr):
        self.sock, self.home, self.ocr = sock, home, ocr
        info = self.rpc("system.identify")
        if not isinstance(info, dict) or not info.get("pid"):
            raise SystemExit(f"driver: no app answers on {sock}: {info!r}")
        self.identity = info
        self.pid = int(info["pid"])
        self.bundle = info.get("app_bundle_path") or bundle
        self.cli = info.get("app_cli_path") or os.path.join(self.bundle, "Contents/Resources/bin/cmux")
        self.tag = info.get("tag")
        bundle_id = info.get("bundle_id") or ""
        if ".debug" not in bundle_id or self.bundle.startswith("/Applications/"):
            raise SystemExit(f"driver: refusing {self.bundle} ({bundle_id}): not a tagged DEV build")
        try:
            named = build_names.of_app(self.bundle).get("session")
        except (ValueError, OSError, KeyError):
            named = None
        self.sessions = [s for s in (named, f"cmux-app-{self.tag}" if self.tag else None) if s]

    def rpc(self, method, params=None, timeout=RPC_TIMEOUT):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(self.sock)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf or b"{}")
        if not reply.get("ok", "result" in reply):
            raise StepError(f"{method}: {reply.get('error') or 'no answer'}")
        result = reply.get("result")
        if isinstance(result, dict) and result.get("error"):
            raise StepError(f"{method}: {result['error']}")
        return result

    def reidentify(self, info):
        """After a relaunch: the new process of the same bundle (refused if it is another app)."""
        if not isinstance(info, dict) or not info.get("pid"):
            raise StepError(f"system.identify after relaunch: {info!r}")
        bundle = info.get("app_bundle_path") or self.bundle
        if bundle != self.bundle:
            raise StepError(f"the socket now answers for another app: {bundle}")
        self.identity, self.pid = info, int(info["pid"])
        self._daemon_sock = None

    def launch_env(self):
        """The app process's own launch variables (`ps eww`, same user): CMUX_*, HOME and TMPDIR."""
        out = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(self.pid)], capture_output=True, text=True).stdout
        env = {}
        for word in out.split():
            key, sep, value = word.partition("=")
            if sep and LAUNCH_ENV.match(key):
                env[key] = value
        return env

    @staticmethod
    def alive(pid):
        """Whether `pid` runs (a zombie counts as gone)."""
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        stat = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        return bool(stat) and not stat.startswith("Z")

    def daemon_pid(self):
        """The pid of the daemon the app says it is connected to (`debug.daemon`), or None."""
        try:
            state = self.rpc("debug.daemon", timeout=5) or {}
        except (StepError, OSError, ValueError):
            return None
        pid = state.get("pid") if isinstance(state, dict) else None
        return int(pid) if pid else None

    def daemon_socket(self):
        """The app daemon's socket, from its own `--socket` argument: the daemon the app says it is
        connected to (`debug.daemon` pid), else the `--headless` process of this bundle and session."""
        try:
            state = self.rpc("debug.daemon", timeout=5) or {}
        except (StepError, OSError, ValueError):
            state = {}
        self.daemon_state = state
        lines = []
        if state.get("pid"):
            lines = subprocess.run(["ps", "-o", "args=", "-p", str(int(state["pid"]))], capture_output=True, text=True).stdout.splitlines()
        if not any("--socket " in line for line in lines):
            lines = [line for line in subprocess.run(["ps", "axo", "args="], capture_output=True, text=True).stdout.splitlines()
                     if line.startswith(self.bundle + "/") and "--headless" in line
                     and any(f"--session {s} " in line + " " for s in self.sessions)]
        for line in lines:
            found = re.search(r"--socket[ =](\S+)", line)
            if found:
                return found.group(1)
        self.daemon_args = lines
        return None

    def cmux(self, *args, timeout=30):
        """The bundled `cmux` CLI on the app's daemon, `--json`: the parsed answer."""
        sock = self._daemon_sock if getattr(self, "_daemon_sock", None) and os.path.exists(self._daemon_sock) else None
        sock = sock or self.daemon_socket()
        self._daemon_sock = sock
        if not sock:
            raise StepError(f"no daemon socket: debug.daemon {json.dumps(getattr(self, 'daemon_state', None))[:300]}, "
                            f"daemon args {getattr(self, 'daemon_args', [])[:2]}")
        env = {"HOME": self.home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1"}
        done = subprocess.run([self.cli, "--socket", sock, "--json", *args], capture_output=True, text=True,
                              timeout=timeout, env=env)
        try:
            answer = json.loads(done.stdout)
        except ValueError:
            raise StepError(f"cmux {' '.join(args)[:80]}: exit {done.returncode}: {(done.stdout + done.stderr).strip()[-300:]}")
        if isinstance(answer, dict) and answer.get("error"):
            raise StepError(f"cmux {' '.join(args)[:80]}: {answer['error']}")
        return answer.get("value", answer) if isinstance(answer, dict) and "text" not in answer else answer

    def screen(self, term):
        answer = self.cmux("terminal", term, "screen", "read")
        for _ in range(3):  # the answer, or its value / result envelope
            if isinstance(answer, dict) and "text" not in answer:
                answer = next((answer[k] for k in ("value", "result", "data") if isinstance(answer.get(k), dict)), answer)
        if not isinstance(answer, dict) or "text" not in answer:
            raise StepError(f"terminal {term} screen read gave no text: {json.dumps(answer)[:200]}")
        return answer

    def panes(self):
        report = self.rpc("debug.surfaces", {"text": True}) or {}
        return [p for w in report.get("windows", []) for p in w.get("panes", []) if isinstance(p, dict)]

    @staticmethod
    def processes():
        """{pid: {ppid, pgid, tpgid, tty, stat, command}} of every process of this account."""
        out = subprocess.run(["ps", "-axo", "pid=,ppid=,pgid=,tpgid=,tty=,stat=,command="],
                             capture_output=True, text=True).stdout
        table = {}
        for line in out.splitlines():
            parts = line.split(None, 6)
            if len(parts) < 6:
                continue
            try:
                pid, ppid, pgid, tpgid = (int(p) for p in parts[:4])
            except ValueError:
                continue
            table[pid] = {"pid": pid, "ppid": ppid, "pgid": pgid, "tpgid": tpgid, "tty": parts[4], "stat": parts[5],
                          "command": parts[6] if len(parts) > 6 else ""}
        return table

    def bundle_processes(self, app_pid=None):
        """[{pid, ppid, rss_kb, command}] of every process this app's bundle started or owns: its command is
        in the bundle (helpers, daemons, Chromium) or names the bundle id as its `--owner` (terminal hosts)."""
        out = subprocess.run(["ps", "-axo", "pid=,ppid=,rss=,command="], capture_output=True, text=True).stdout
        bundle_id = str(self.identity.get("bundle_id") or "")
        rows = []
        for line in out.splitlines():
            parts = line.split(None, 3)
            if len(parts) < 4 or not parts[0].isdigit():
                continue
            command = parts[3]
            owned = bool(bundle_id) and re.search(r"--owner " + re.escape(bundle_id) + r"(?::|\s|$)", command)
            if (command.startswith(self.bundle + "/") or owned) and int(parts[0]) != app_pid:
                rows.append({"pid": int(parts[0]), "ppid": int(parts[1]), "rss_kb": int(parts[2]) if parts[2].isdigit() else None,
                             "command": command[:400]})
        return rows

    def roots(self, table, host_pid):
        """The terminal's host when the app named it, else every process run from the app's bundle."""
        if host_pid and host_pid in table:
            return {host_pid}
        return {pid for pid, row in table.items() if row["command"].startswith(self.bundle + "/")}

    def snapshot(self, path):
        path = Path(path)
        if path.exists():
            path.unlink()
        # The journey's window (a main window id) when a step chose one, else the main window.
        target = {"window": self.snapshot_window} if getattr(self, "snapshot_window", None) else {"kind": "main"}
        self.rpc("debug.window_snapshot", dict(target, path=str(path)), timeout=SNAPSHOT_TIMEOUT)
        if not path.is_file() or path.stat().st_size == 0:
            raise StepError("debug.window_snapshot wrote no image")
        return path

    def read_text(self, image):
        done = subprocess.run([self.ocr, str(image)], capture_output=True, text=True, timeout=120)
        if done.returncode != 0:
            raise StepError(f"text recognition failed on {Path(image).name}: {(done.stderr or done.stdout).strip()[-200:]}")
        return [line for line in done.stdout.splitlines() if line.strip()]


def descendants(table, roots):
    children = {}
    for row in table.values():
        children.setdefault(row["ppid"], []).append(row["pid"])
    seen, todo = set(), list(roots)
    while todo:
        pid = todo.pop()
        for child in children.get(pid, []):
            if child not in seen:
                seen.add(child)
                todo.append(child)
    return seen


class Frames(threading.Thread):
    """The main window every `interval` seconds while a journey runs: the clip."""

    def __init__(self, app, directory, interval):
        super().__init__(daemon=True)
        self.app, self.directory, self.interval = app, Path(directory), max(0.25, interval)
        self.count, self.stopped = 0, threading.Event()
        self.directory.mkdir(parents=True, exist_ok=True)

    def run(self):
        while not self.stopped.is_set() and self.count < MAX_FRAMES:
            try:
                self.app.snapshot(self.directory / f"frame-{self.count:05d}.png")
                self.count += 1
            except (OSError, ValueError, StepError):
                pass
            self.stopped.wait(self.interval)


# ---- text matching -------------------------------------------------------------------------

def lines_of(text):
    return [line.rstrip() for line in (text or "").split("\n")]


def last_line(text):
    filled = [line for line in lines_of(text) if line.strip()]
    return filled[-1] if filled else ""


# Letters text recognition confuses in a monospace terminal font, folded to one form.
OCR_FOLD = str.maketrans({"O": "0", "o": "0", "D": "0", "I": "1", "l": "1", "L": "1", "|": "1", "i": "1", "S": "5", "s": "5",
                          "B": "8", "Z": "2", "z": "2", "—": "-", "–": "-", "_": "-"})


def ocr_contains(lines, wanted):
    """Whether OCR'd `lines` show `wanted` (spaces dropped, look-alike letters folded)."""
    fold = lambda s: re.sub(r"\s+", "", s).translate(OCR_FOLD).lower()
    target = fold(wanted)
    return any(target in fold(line) for line in lines) or target in fold("".join(lines))


def negative(name, want):
    """Whether a condition claims something is NOT there: read again every poll, never latched."""
    if name in ("daemon_lacks", "app_text_lacks") or name in EXT_NEGATIVE:
        return True
    # daemon_history with `lacks`; app_rows with `hold` (the view must stay as it is, e.g. while output arrives).
    return isinstance(want, dict) and ((name == "daemon_history" and "lacks" in want)
                                       or (name == "app_rows" and bool(want.get("hold"))))
# The app-life conditions (Journey.evaluate_life).
LIFE_CONDITIONS = {"daemon_cwd", "daemon_grid", "daemon_pane_ready", "app_cwd", "app_layout", "app_tab_pane",
                   "app_tab_gone", "app_rpc", "app_grid"}


def same_dir(got, wanted):
    """Whether two directory paths are the same place: macOS shows /tmp and /var as /private/tmp and
    /private/var, and a shell may print either."""
    if not got or not wanted:
        return False
    norm = lambda p: re.sub(r"^/private(?=/)", "", str(p).rstrip("/") or "/")
    return norm(got) == norm(wanted)


def dig(value, path):
    """`value` at a dotted path ("result.launch.recovery"; list items by index)."""
    for part in [p for p in str(path).split(".") if p]:
        if isinstance(value, list) and part.isdigit():
            value = value[int(part)] if int(part) < len(value) else None
        elif isinstance(value, dict):
            value = value.get(part)
        else:
            return None
    return value


# ---- one journey ---------------------------------------------------------------------------

class Journey:
    def __init__(self, spec, app, out, deadline, frame_interval):
        self.spec, self.app, self.deadline = spec, app, deadline
        self.id = spec["id"]
        self.out = Path(out) / self.id
        if self.out.exists():
            shutil.rmtree(self.out)
        self.out.mkdir(parents=True)
        self.frame_interval = frame_interval
        # Digits a text reader cannot confuse with letters: the run's own text, never a fixture's.
        self.nonce = "".join(random.choice("23456789") for _ in range(6))
        self.vars = {"nonce": self.nonce, "prompt": PROMPT}
        self.marks, self.binds = {}, {}
        # {terminal id: its tty as ps names it (ttys004)}, written by the shell at neutral_prompt.
        self.ttys, self.tty_probes = {}, 0
        self.term = self.pane = self.host_pid = None
        self.steps, self.evidence, self.checks = [], [], 0
        # The window keys go to (a main window id; None: debug.key's default, the first window), and
        # the window frames are read from (None: the main window); each journey starts with both defaults.
        self.key_window = None
        app.snapshot_window = None
        self.files = []
        # Named terminals ({"term", "pane", "host_pid"}): `as` on the steps that adopt one, `use` switches.
        self.aliases = {}
        # The app's own terminal ids already on screen: `focused_terminal` waits for one not in it.
        self.known_views = set()

    def sub(self, value):
        if isinstance(value, str):
            return re.sub(r"\$\{(\w+)\}", lambda m: str(self.vars.get(m.group(1), m.group(0))), value)
        if isinstance(value, list):
            return [self.sub(v) for v in value]
        if isinstance(value, dict):
            return {k: self.sub(v) for k, v in value.items()}
        return value

    # -- steps --

    def step_new_terminal(self, step):
        """`via`: `key` (the person's New Terminal Tab key, NEW_TERMINAL_KEY, through debug.key: an action of
        origin user that claims the window's keyboard) or `socket` (default: a script's `action.run newTab`
        with focus, which since cp/fix-chief-composer-focus shows the workspace only when no text input has
        the person's keyboard). A journey that plays what a person does says `via: key`."""
        via = step.get("via", "socket")
        if via == "key":
            return self.new_terminal_by_key(step)
        if via != "socket":
            raise StepError(f"new_terminal: via is key or socket, not {via!r}")
        before = {p.get("terminal_id") for p in self.app.panes() if p.get("terminal_id")}
        # A second new_terminal in one journey (a second window) finds its own terminal, not the first's.
        self.term = self.pane = self.host_pid = None
        reply = self.app.rpc("action.run", {"action": "newTab", "args": {"name": self.sub(step.get("name", self.id)), "focus": True}})
        end = now() + float(step.get("timeout", 20))
        while now() < end:
            for pane in self.app.panes():
                if pane.get("focused") and pane.get("terminal_id") and pane["terminal_id"] not in before:
                    # The daemon's id of the terminal: the tab's `terminal` in the app's topology
                    # (debug.surfaces' terminal_id is the app's own id, not a daemon selector).
                    self.pane = pane.get("pane")
                    self.host_pid = int(pane["host_pid"]) if pane.get("host_pid") else None
                    # The shell drew its first prompt (any text) in the daemon's screen.
                    last = "empty screen"
                    while now() < end:
                        try:
                            if not self.term:
                                self.term = self.daemon_terminal(self.sub(step.get("name", self.id)), self.pane)
                            if self.app.screen(self.term)["text"].strip():
                                return {"pane": self.pane, "terminal": self.term, "host_pid": self.host_pid,
                                        "workspace": pane.get("workspace"), "daemon_socket": self.app._daemon_sock,
                                        "action_reply": reply}
                        except StepError as error:
                            last = str(error)
                        time.sleep(0.2)
                    raise StepError(f"terminal {self.term}: the daemon's screen never showed a prompt: {last[-400:]}")
            time.sleep(0.2)
        raise StepError(f"newTab showed no new focused terminal pane within {step.get('timeout', 20)} s: {json.dumps(reply)[:200]}")

    def new_terminal_by_key(self, step):
        """The person's new terminal: presses NEW_TERMINAL_KEY (the app's own binding, never changed here) and
        adopts the new focused terminal as `focused_terminal` does. Right after launch the window may not exist
        yet (debug.key answers "no window"); the key is pressed again until it does, as a person presses it once
        they see the window. Checks the key router ran newSurface for it (debug.key `last`)."""
        held = self.before_keys()
        end = now() + float(step.get("timeout", 20))
        press = {"key": step.get("key", NEW_TERMINAL_KEY["key"]), "modifiers": step.get("modifiers", NEW_TERMINAL_KEY["modifiers"])}
        tries = 0
        while True:
            tries += 1
            self.known_views |= {p.get("terminal_id") for p in self.app.panes() if p.get("terminal_id")}
            before = self.app.rpc("debug.key", {"last": True}) or {}
            reply = self.key(press["key"], press["modifiers"])
            if not (isinstance(reply, dict) and reply.get("error") == "no window") or now() > end:
                break
            time.sleep(0.1)
        if isinstance(reply, dict) and reply.get("error"):
            raise StepError(f"the new terminal key {press} was refused: {reply['error']}")
        last = self.app.rpc("debug.key", {"last": True}) or {}
        adopted = self.step_focused_terminal({"timeout": max(1.0, end - now())})
        return dict(adopted, via="key", key=press, presses=tries, waited_out_hold_s=held,
                    handled_by=reply.get("handled_by") if isinstance(reply, dict) else None,
                    router_last={"action": last.get("action"), "ran": last.get("ran"),
                                 "new": last.get("count") != before.get("count")})

    def step_script_new_terminal(self, step):
        """Automation on purpose: a script's `action.run newTab` (`name`, `focus`, default true) through the
        socket, as `cmux workspace new --focus` sends it. Does not wait for the workspace to show (a script's
        new workspace shows only when no text input has the person's keyboard): waits for the topology to list
        a workspace named `name` with a terminal, makes that terminal current (no pane: the app may not show
        it) and waits for its shell's first prompt in the daemon's screen."""
        name = self.sub(step.get("name", self.id))
        reply = self.app.rpc("action.run", {"action": "newTab", "args": {"name": name, "focus": bool(step.get("focus", True))}})
        end = now() + float(step.get("timeout", 20))
        last = "no reply"
        while now() < end:
            try:
                self.term, self.pane, self.host_pid = self.daemon_terminal(name, None), None, None
                if self.app.screen(self.term)["text"].strip():
                    return {"terminal": self.term, "workspace": name, "action_reply": reply}
            except StepError as error:
                last = str(error)
            time.sleep(0.2)
        raise StepError(f"the script's newTab {name!r} listed no terminal with a prompt within {step.get('timeout', 20)} s: {last[-300:]}")

    def daemon_terminal(self, workspace_name, pane_key):
        """The daemon terminal id of the selected tab in `pane_key` of the workspace named `workspace_name`."""
        snap = self.app.rpc("snapshot.get") or {}
        topo = snap.get("topology") if isinstance(snap, dict) else None
        found = []
        for ws in (topo or {}).get("workspaces", []):
            if ws.get("name") != workspace_name:
                continue
            for screen in ws.get("screens", []):
                for pane in screen.get("panes", []):
                    for tab in pane.get("tabs", []):
                        term = tab.get("terminal")
                        term = term.get("id") if isinstance(term, dict) else term
                        if term:
                            found.append((pane.get("id") == pane_key, bool(tab.get("selected")), str(term)))
        if not found:
            names = [w.get("name") for w in (topo or {}).get("workspaces", [])]
            sample = next((t for w in (topo or {}).get("workspaces", []) if w.get("name") == workspace_name
                           for s in w.get("screens", []) for p in s.get("panes", []) for t in p.get("tabs", [])), None)
            raise StepError(f"the topology has no terminal tab in a workspace named {workspace_name!r} "
                            f"(workspaces {names[:8]}, a tab {json.dumps(sample)[:300]})")
        return sorted(found, reverse=True)[0][2]

    def step_neutral_prompt(self, step):
        # Set-up, not under test: written into the PTY by the daemon, as a paste would be.
        term = self.need_term()
        # The tty first, on its own line; the neutral prompt is written only after the shell ran it.
        tty_file = self.tty_probe_path()
        if tty_file.exists():
            tty_file.unlink()
        self.app.cmux("terminal", term, "write", "--text", TTY_PROBE.format(tty_file=shlex.quote(str(tty_file))))
        tty = self.read_tty(tty_file, float(step.get("tty_timeout", 3)))
        self.app.cmux("terminal", term, "write", "--text", NEUTRAL_PROMPT)
        end = now() + float(step.get("timeout", 15))
        while now() < end:
            if last_line(self.app.screen(self.term)["text"]) == PROMPT.rstrip():
                # A slow shell ran the probe late: it is ahead of the neutral prompt line, so it ran by now.
                tty = tty or self.read_tty(tty_file, 0)
                if tty_file.exists():
                    tty_file.unlink()
                if tty:
                    self.ttys[term] = tty
                else:
                    self.ttys.pop(term, None)
                return {"prompt": PROMPT, "tty": tty}
            time.sleep(0.1)
        raise StepError(f"the neutral prompt never showed; screen ends {last_line(self.app.screen(self.term)['text'])!r}")

    def tty_probe_path(self):
        """The next probe file: in the driver's out dir (the capture slot's, removed with the slot; never /tmp),
        a name of fixed length (no journey id), so the probe line never wraps the 110-column terminal."""
        self.tty_probes += 1
        return self.out.parent / f".tty-{self.nonce}-{self.tty_probes}"

    @staticmethod
    def read_tty(path, timeout):
        """The tty the shell wrote (/dev/ttys004 -> ttys004, as ps names it), or None."""
        end = now() + timeout
        while True:
            try:
                text = path.read_text().strip()
            except OSError:
                text = ""
            if text.startswith("/dev/"):
                return text[len("/dev/"):]
            if now() >= end:
                return None
            time.sleep(0.05)

    def step_type(self, step):
        # The mark is the moment the command is entered (Return), else the first key.
        text = self.sub(step["text"])
        held = self.before_keys()
        window = self.window_for(step.get("window"))
        replies = []
        if step.get("mark") and not step.get("enter"):
            self.marks[step["mark"]] = now()
        for char in text:
            replies.append(self.key(char, [], window))
            time.sleep(0.01)
        if step.get("enter"):
            if step.get("mark"):
                self.marks[step["mark"]] = now()
            replies.append(self.key("return", [], window))
        routes = sorted({str(r.get("handled_by")) for r in replies if isinstance(r, dict)})
        # One full reply per route (its trace says who took the key): evidence when typing went astray.
        samples = {}
        for char, reply in zip(text + ("\r" if step.get("enter") else ""), replies):
            if isinstance(reply, dict) and str(reply.get("handled_by")) not in samples:
                samples[str(reply.get("handled_by"))] = {"char": char, "reply": reply}
        return {"typed": text, "keys": len(replies), "handled_by": routes, "samples": samples, "waited_out_hold_s": held}

    def step_key(self, step):
        held = self.before_keys()
        # `window`: the window the key is typed in (a name a step gave it, e.g. ext_multiwindow's
        # `name_window`, or a window id); else the journey's key window.
        window = self.window_for(step.get("window"))
        if step.get("mark"):
            self.marks[step["mark"]] = now()
        # `repeat`: the same key N times, `gap` seconds apart (a person pressing it again and again).
        repeat, replies, took = int(step.get("repeat", 1)), [], []
        for index in range(repeat):
            if index:
                time.sleep(float(step.get("gap", 0.1)))
            t = now()
            replies.append(self.key(step["key"], step.get("modifiers", []), window))
            took.append(round((now() - t) * 1000, 1))
        if repeat == 1:
            return {"key": step["key"], "modifiers": step.get("modifiers", []), "window": window or self.key_window,
                    "reply": replies[0], "waited_out_hold_s": held}
        return {"key": step["key"], "modifiers": step.get("modifiers", []), "presses": repeat,
                "reply_ms_max": max(took), "reply_ms": took, "handled_by": sorted({str(r.get("handled_by")) for r in replies if isinstance(r, dict)})}

    def step_outwait_hold(self, step):
        """After a key that can show a terminal whose view comes later (a tab switch onto an evicted terminal):
        the next key waits until CREATION_HOLD_SECONDS after the last key (see CREATION_HOLD_SECONDS)."""
        self.hold_from = getattr(self, "last_key_at", now())
        return {"next_key_waits_from": "the last key"}

    def step_wait(self, step):
        time.sleep(float(step.get("seconds", 1)))
        return {}

    def step_rpc(self, step):
        return {"reply": self.app.rpc(step["method"], self.sub(step.get("params") or {}))}

    # -- scroll, paste, select: the pointer, the clipboard, helper files --

    def step_mouse(self, step):
        """`debug.mouse` over the journey's pane (its center): `action` scroll (default; `dy` > 0 moves
        toward older rows, as a wheel turned up does), click, double_click; `count` times, `interval`
        seconds apart."""
        params = {k: self.sub(v) for k, v in step.items() if k in ("action", "dx", "dy", "phase", "modifiers", "button")}
        params.setdefault("action", "scroll")
        params["pane"] = self.need_pane()
        # `window`: the window that shows the pane (a named window or an id); debug.mouse's default is the first window.
        if step.get("window"):
            params["window"] = self.window_for(step["window"])
        if step.get("mark"):
            self.marks[step["mark"]] = now()
        replies = []
        for index in range(int(step.get("count", 1))):
            if index:
                time.sleep(float(step.get("interval", 0.05)))
            replies.append(self.app.rpc("debug.mouse", params))
        return {"params": params, "count": len(replies), "replies": replies[:2]}

    def step_select_text(self, step):
        """Selects TEXT where the pane shows it, as a person does with the pointer: `how` drag (press on
        its first cell, drag to its last, release) or double_click (on its middle: a word). The cells come
        from the pane's viewport text and grid (debug.surfaces); `occurrence` last (default) or first."""
        text = self.sub(step["text"])
        pane = self.pane_report()
        grid, viewport = pane.get("grid"), pane.get("text") or ""
        if not isinstance(grid, dict) or not grid.get("cell_width"):
            raise StepError(f"pane {self.pane} reports no grid: {json.dumps(grid)[:200]}")
        lines = viewport.split("\n")
        hits = [i for i, line in enumerate(lines) if text in line]
        if not hits:
            raise StepError(f"the pane does not show {text!r}; it ends {[l for l in lines if l.strip()][-4:]}")
        index = hits[-1] if step.get("occurrence", "last") == "last" else hits[0]
        # The viewport text is logical lines; the grid wraps each at its column count.
        cw, ch = float(grid["cell_width"]), float(grid["cell_height"])
        cols = max(1, int((grid["frame_width"] - 2 * (grid["origin_x"] - grid["frame_x"])) // cw))
        col = lines[index].index(text)
        row = sum(max(1, -(-len(line) // cols)) for line in lines[:index]) + col // cols
        col %= cols
        y = grid["origin_y"] + (row + 0.5) * ch
        first_x = grid["origin_x"] + (col + 0.25) * cw
        last_x = grid["origin_x"] + (col + len(text) - 0.25) * cw
        if step.get("mark"):
            self.marks[step["mark"]] = now()
        if step.get("how", "drag") == "double_click":
            params = {"window": grid["window"], "action": "double_click", "x": (first_x + last_x) / 2, "y": y}
        else:
            params = {"window": grid["window"], "action": "drag", "x": first_x, "y": y, "to_x": last_x, "to_y": y,
                      "steps": int(step.get("steps", 12))}
        return {"text": text, "row": row, "col": col, "cols": cols, "params": params, "reply": self.app.rpc("debug.mouse", params)}

    def step_clipboard_set(self, step):
        """Set-up: puts `text` (or `lines`: {"format": "L%05d-${nonce}", "count": N}, joined by LF) on the
        Mac's general pasteboard, the one Cmd+V reads, and reads it back; binds ${clip_sha} and ${clip_lines}."""
        if "lines" in step:
            spec = self.sub(step["lines"])
            fmt, start = spec["format"], int(spec.get("start", 1))
            text = "\n".join(fmt % n for n in range(start, start + int(spec["count"])))
        else:
            text = self.sub(step["text"])
        data = text.encode()
        env = {"LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "PATH": "/usr/bin:/bin"}
        subprocess.run(["/usr/bin/pbcopy"], input=data, env=env, check=True, timeout=30)
        back = subprocess.run(["/usr/bin/pbpaste"], env=env, capture_output=True, timeout=30).stdout
        if back != data:
            raise StepError(f"the pasteboard did not take the text ({len(data)} bytes set, {len(back)} read back)")
        self.vars["clip_sha"] = hashlib.sha256(data).hexdigest()
        self.vars["clip_lines"] = str(text.count("\n") + 1)
        return {"bytes": len(data), "lines": text.count("\n") + 1, "sha256": self.vars["clip_sha"], "head": text[:60]}

    def step_file(self, step):
        """Set-up: writes a helper file the journey runs (a program under test's stand-in), only at
        /tmp/jr-*; removed when the journey ends. `text`, or `lines` (joined by LF). The content is not
        substituted: a helper takes the run's values as arguments."""
        path = self.sub(step["path"])
        if not re.fullmatch(r"/tmp/jr-[A-Za-z0-9._-]+", path):
            raise StepError(f"a helper file goes to /tmp/jr-*, not {path!r}")
        text = "\n".join(step["lines"]) + "\n" if "lines" in step else step["text"]
        Path(path).write_text(text)
        self.files.append(path)
        return {"path": path, "bytes": len(text.encode())}

    def need_pane(self):
        if not self.pane:
            raise StepError("no pane: the journey needs a new_terminal step first")
        return self.pane

    def pane_report(self):
        pane = next((p for p in self.app.panes() if p.get("pane") == self.need_pane()), None)
        if pane is None:
            raise StepError(f"pane {self.pane} is not in debug.surfaces")
        return pane

    def key(self, key, modifiers, window=None):
        self.last_key_at = now()
        params = {"key": key, "modifiers": modifiers}
        if window or self.key_window:
            params["window"] = window or self.key_window
        return self.app.rpc("debug.key", params)

    def window_for(self, ref):
        """A step's `window`: a name a step gave a window (`named_windows`, ext_multiwindow's `name_window`),
        else a window id as is; None when the step names none."""
        if not ref:
            return None
        ref = self.sub(ref)
        return getattr(self, "named_windows", {}).get(ref, ref)

    def before_keys(self):
        """Before a step's first key: waits out a creation hold a step before may have opened; seconds waited."""
        since, self.hold_from = getattr(self, "hold_from", None), None
        return None if since is None else self.outwait_creation_hold(since)

    def outwait_creation_hold(self, since):
        """Sleeps until CREATION_HOLD_SECONDS after `since` (see CREATION_HOLD_SECONDS); returns the seconds slept."""
        left = since + CREATION_HOLD_SECONDS - now()
        if left > 0:
            time.sleep(left)
        return round(max(0.0, left), 2)

    def need_term(self):
        if not self.term:
            raise StepError("no terminal: the journey needs a new_terminal step first")
        return self.term

    # -- conditions for scroll, paste, select (README "Conditions") --

    def cached_pane(self, cache):
        if "pane" not in cache:
            cache["pane"] = next((p for p in self.app.panes() if p.get("pane") == self.pane), None)
        if cache["pane"] is None:
            raise StepError(f"pane {self.pane} is not in debug.surfaces")
        return cache["pane"]

    def history(self, which, count, cache):
        """The daemon's scrollback rows (`terminal ID history read`): the `count` oldest or newest, as
        text, and the number of rows it holds."""
        key = ("history", which, count)
        if key not in cache:
            args = ["terminal", self.need_term(), "history", "read", "--limit", str(count)]
            if which == "oldest":
                args += ["--before", str(count)]
            answer = self.app.cmux(*args)
            for _ in range(3):
                if isinstance(answer, dict) and "rows" not in answer:
                    answer = next((answer[k] for k in ("value", "result", "data") if isinstance(answer.get(k), dict)), answer)
            if not isinstance(answer, dict) or not isinstance(answer.get("rows"), list):
                raise StepError(f"terminal {self.term} history read gave no rows: {json.dumps(answer)[:200]}")
            texts = ["".join(str(run.get("text", "")) for run in row.get("runs", []) if isinstance(run, dict))
                     for row in answer["rows"] if isinstance(row, dict)]
            start = int(answer.get("start") or 0)
            total = start + len(texts) if which == "newest" else None
            cache[key] = (texts, total)
        return cache[key]

    @staticmethod
    def numbered(lines, pattern):
        """(number, line) of each line `pattern` (one group: the number) finds, in order."""
        found = []
        for line in lines:
            match = re.search(pattern, line)
            if match:
                found.append((int(match.group(1)), line.strip()))
        return found

    @staticmethod
    def gaps(numbers):
        """Where `numbers` is not each one after the last: [(index, previous, next)]."""
        return [(i, a, b) for i, (a, b) in enumerate(zip(numbers, numbers[1:]), 1) if b != a + 1][:5]

    def cond_app_rows(self, want, cache):
        """The numbered rows the pane's viewport shows (what the person sees, after any scroll):
        `pattern` (one group: the row's number), `min_rows` (default 3), `contiguous` (default true:
        each row the one after the last, nothing dropped, repeated or out of order), `top` / `last`:
        {eq|ne|gt|lt|ge|le: N, a NAME an earlier app_rows bound, or "daemon_oldest" (the first numbered
        row the daemon's scrollback still holds)}; `bind` NAME keeps the top and last numbers and sets
        ${NAME_top} and ${NAME_mid} to the top and middle rows' text."""
        pane = self.cached_pane(cache)
        lines = lines_of(pane.get("text") or "")
        rows = self.numbered(lines, want["pattern"])
        numbers = [n for n, _ in rows]
        detail = {"rows": len(rows), "top": numbers[0] if numbers else None, "last": numbers[-1] if numbers else None,
                  "viewport_lines": len(lines), "head": [l for l in lines if l.strip()][:2],
                  "tail": [l for l in lines if l.strip()][-2:]}
        if len(rows) < int(want.get("min_rows", 3)):
            return False, dict(detail, why="too few numbered rows in the viewport")
        if want.get("contiguous", True) and self.gaps(numbers):
            return False, dict(detail, why="rows out of order or missing", gaps=self.gaps(numbers))
        ops = {"eq": lambda a, b: a == b, "ne": lambda a, b: a != b, "gt": lambda a, b: a > b,
               "lt": lambda a, b: a < b, "ge": lambda a, b: a >= b, "le": lambda a, b: a <= b}
        for field in ("top", "last"):
            for op, ref in (want.get(field) or {}).items():
                if ref == "daemon_oldest":
                    oldest = self.numbered(self.history("oldest", 200, cache)[0], want["pattern"])
                    if not oldest:
                        return False, dict(detail, why="the daemon's oldest 200 scrollback rows hold no numbered row")
                    value = oldest[0][0]
                elif isinstance(ref, str):
                    if ref not in self.binds:
                        return False, dict(detail, why=f"no rows bound as {ref!r}")
                    value = self.binds[ref][field]
                else:
                    value = int(ref)
                detail[f"{field}_{op}"] = value
                if not ops[op](detail[field], value):
                    return False, dict(detail, why=f"{field} {detail[field]} is not {op} {value}")
        if want.get("bind"):
            self.binds[want["bind"]] = {"top": numbers[0], "last": numbers[-1]}
            self.vars[want["bind"] + "_top"] = rows[0][1]
            self.vars[want["bind"] + "_mid"] = rows[len(rows) // 2][1]
        return True, detail

    def cond_daemon_history(self, want, cache):
        """The daemon's scrollback (`history read`): `rows` oldest|newest, `count` (default 200, at most
        10000) rows; `contains` / `lacks` TEXT in any of them; `pattern` (one group: a row's number) with
        `contiguous` (default true) and `last` N (the last numbered row's number)."""
        which, count = want.get("rows", "newest"), int(want.get("count", 200))
        texts, total = self.history(which, count, cache)
        detail = {"rows_read": len(texts), "history_rows": total, "head": texts[:2], "tail": texts[-2:]}
        if "contains" in want and not any(want["contains"] in t for t in texts):
            return False, dict(detail, why=f"no row has {want['contains']!r}")
        if "lacks" in want:
            hits = [t for t in texts if want["lacks"] in t]
            if hits:
                return False, dict(detail, why=f"{len(hits)} rows have {want['lacks']!r}", hit=hits[0])
        if "pattern" in want:
            numbers = [n for n, _ in self.numbered(texts, want["pattern"])]
            detail.update(numbered=len(numbers), first=numbers[0] if numbers else None, last=numbers[-1] if numbers else None)
            if not numbers:
                return False, dict(detail, why="no numbered rows")
            if want.get("contiguous", True) and self.gaps(numbers):
                return False, dict(detail, why="rows out of order or missing", gaps=self.gaps(numbers))
            if "last" in want and numbers[-1] != int(want["last"]):
                return False, dict(detail, why=f"the last numbered row is {numbers[-1]}, not {want['last']}")
        return True, detail

    def cond_frame_screen(self, want, cache):
        """One fresh frame (the app's own drawing of the window) that shows every text of `shows` and
        none of `lacks` to text recognition: what is gone is checked on a frame that is not blank."""
        self.checks += 1
        image = self.app.snapshot(self.out / f"check-{self.checks:02d}.png")
        lines = self.app.read_text(image)
        missing = [t for t in want.get("shows", []) if not ocr_contains(lines, t)]
        present = [t for t in want.get("lacks", []) if ocr_contains(lines, t)]
        detail = {"image": image.name, "text": lines[-12:], "lines": len(lines), "missing": missing, "present": present}
        return bool(want.get("shows")) and not missing and not present, detail

    def cond_quit_leftovers(self, want, cache):
        """The processes a `relaunch` with `leftovers_after` found after the quit: each must match one of
        `allow` ({"match": RE on the command, "why": the reason it may stay}); the rest are offenders."""
        kept = getattr(self, "leftovers", None)
        if kept is None:
            return False, {"error": "no relaunch step with leftovers_after ran before this check"}
        allow = want.get("allow", [])
        offenders = [r for r in kept["rows"] if not any(re.search(a["match"], r["command"]) for a in allow)]
        allowed = [dict(r, why=next(a.get("why") for a in allow if re.search(a["match"], r["command"])))
                   for r in kept["rows"] if r not in offenders]
        rss = sum(r["rss_kb"] or 0 for r in offenders)
        return not offenders, {"after_s": kept["after_s"], "offenders": offenders, "offender_rss_mb": round(rss / 1024, 1),
                               "allowed": allowed[:6], "allowed_count": len(allowed)}

    def cond_clipboard(self, want, cache):
        """The Mac's general pasteboard (what Cmd+V pastes, `pbpaste`) is exactly `want`."""
        env = {"LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "PATH": "/usr/bin:/bin"}
        got = subprocess.run(["/usr/bin/pbpaste"], env=env, capture_output=True, timeout=30).stdout.decode(errors="replace")
        return got == want, {"got": got[:200], "bytes": len(got.encode())}
    # -- app life steps (journeys/p0/app-life-*.json) --

    def topology(self):
        snap = self.app.rpc("snapshot.get") or {}
        topo = snap.get("topology") if isinstance(snap, dict) else None
        if not isinstance(topo, dict):
            raise StepError(f"snapshot.get has no topology: {json.dumps(snap)[:200]}")
        return topo

    @staticmethod
    def places(topo):
        """(workspace, pane, tab, daemon terminal id) of every tab in the topology."""
        for ws in topo.get("workspaces", []):
            for screen in ws.get("screens", []):
                for pane in screen.get("panes", []):
                    for tab in pane.get("tabs", []):
                        term = tab.get("terminal")
                        term = term.get("id") if isinstance(term, dict) else term
                        yield ws, pane, tab, (str(term) if term else None)

    def place_of(self, term, topo=None):
        """(workspace, pane, tab) that holds daemon terminal `term`, or None."""
        for ws, pane, tab, t in self.places(topo or self.topology()):
            if t == term:
                return ws, pane, tab
        return None

    def view_of_pane(self, pane_id):
        return next((p for p in self.app.panes() if p.get("pane") == pane_id), None)

    def adopt(self, term, pane_id, host_pid=None):
        """Makes daemon terminal `term` in pane `pane_id` the journey's current terminal."""
        self.term, self.pane = term, pane_id
        view = self.view_of_pane(pane_id) if host_pid is None else None
        if view and view.get("host_pid"):
            host_pid = int(view["host_pid"])
        if host_pid:
            self.host_pid = host_pid
        return {"terminal": self.term, "pane": self.pane, "host_pid": self.host_pid}

    def wait_screen(self, end):
        """Until the daemon's screen of the current terminal shows any text (the shell's first prompt)."""
        last = "empty screen"
        while now() < end:
            try:
                if self.app.screen(self.term)["text"].strip():
                    return
            except StepError as error:
                last = str(error)
            time.sleep(0.2)
        raise StepError(f"terminal {self.term}: the daemon's screen never showed a prompt: {last[-300:]}")

    def step_focused_terminal(self, step):
        """After a key that makes a terminal (Ctrl-` New Terminal Tab, Cmd-D split, Home's Open a terminal):
        waits for a focused terminal pane showing a terminal the journey has not seen, adopts it (`as` names
        it) and waits for its shell's first prompt in the daemon's screen."""
        end = now() + float(step.get("timeout", 20))
        last = None
        while now() < end:
            for view in self.app.panes():
                if not (view.get("focused") and view.get("kind", "terminal") == "terminal" and view.get("terminal_id")):
                    continue
                if view["terminal_id"] in self.known_views:
                    last = f"the focused pane {view.get('pane')} still shows a terminal seen before"
                    continue
                place = None
                topo = self.topology()
                for ws, pane, tab, term in self.places(topo):
                    if pane.get("id") == view.get("pane") and tab.get("id") == pane.get("selected_tab") and term:
                        place = (ws, pane, term)
                if not place:
                    last = f"pane {view.get('pane')} has no selected terminal tab in the topology yet"
                    continue
                self.known_views.add(view["terminal_id"])
                adopted = self.adopt(place[2], view.get("pane"), int(view["host_pid"]) if view.get("host_pid") else None)
                self.wait_screen(end)
                # The next key waits out the creation hold (CREATION_HOLD_SECONDS); checks need not.
                self.hold_from = getattr(self, "last_key_at", now())
                return dict(adopted, workspace=place[0].get("name"))
            time.sleep(0.2)
        raise StepError(f"no new focused terminal pane within {step.get('timeout', 20)} s ({last or 'no focused terminal pane'})")

    def step_fresh_app(self, step):
        """First launch: the app must be the one capture-host launched from empty state, with no journey
        played in it before (run.py puts a `first_in_app` journey first in its lease)."""
        if PLAYED:
            raise NotRun(f"first launch needs a fresh app; this app already played {', '.join(PLAYED)}")
        return {"pid": self.app.pid, "played_before": []}

    def step_use(self, step):
        """Makes the terminal named `name` current again; its pane is read from the topology now (a moved
        tab or a relaunch can change it)."""
        name = step["name"]
        if name not in self.aliases:
            raise StepError(f"use: no terminal named {name!r} (name one with `as`)")
        term = self.aliases[name]["term"]
        place = self.place_of(term)
        if not place:
            raise StepError(f"use {name}: terminal {term} is in no tab of the topology")
        self.host_pid = self.aliases[name].get("host_pid")
        return self.adopt(term, place[1].get("id"))

    def step_remember_value(self, step):
        """Keeps a measured value as ${name} for later conditions: `daemon_cols`, `daemon_rows` (the
        current terminal's grid in the daemon) or `app_cell_height` (the pane's cell height in points)."""
        source = step["source"]
        if source in ("daemon_cols", "daemon_rows"):
            row = self.daemon_terminal_row(self.need_term())
            value = row.get("cols" if source == "daemon_cols" else "rows")
        elif source == "app_cell_height":
            view = self.view_of_pane(self.pane) or {}
            value = (view.get("grid") or {}).get("cell_height")
        else:
            raise StepError(f"remember_value: unknown source {source!r}")
        if value is None:
            raise StepError(f"remember_value {source}: no value")
        self.vars[step["name"]] = value
        return {step["name"]: value}

    def config_file(self):
        env = self.app.launch_env()
        return env.get("CMUX_NEXT_CONFIG_FILE") or os.path.join(self.app.home, ".config", "cmux", "cmux-next.json")

    def step_settings_file(self, step):
        """Edits the app's settings file (cmux-next.json, the slot's own) as a person does in an editor:
        `set` merges nested keys, `unset` removes dotted keys. Nothing else touches the app."""
        path = Path(self.config_file())
        try:
            data = json.loads(path.read_text()) if path.is_file() and path.read_text().strip() else {}
        except ValueError as error:
            raise StepError(f"settings file {path} is not JSON: {error}")

        def merge(into, more):
            for k, v in more.items():
                if isinstance(v, dict) and isinstance(into.get(k), dict):
                    merge(into[k], v)
                else:
                    into[k] = v
        merge(data, self.sub(step.get("set") or {}))
        for dotted in step.get("unset") or []:
            node, parts = data, dotted.split(".")
            for part in parts[:-1]:
                node = node.get(part) if isinstance(node, dict) else None
            if isinstance(node, dict):
                node.pop(parts[-1], None)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".journey")
        tmp.write_text(json.dumps(data, indent=2) + "\n")
        os.replace(tmp, path)
        if step.get("mark"):
            self.marks[step["mark"]] = now()
        return {"file": str(path), "now": data}

    def step_relaunch(self, step):
        """Ends the app and opens it again, as a person does: `how` "quit" presses Cmd-Q (answering a quit
        sheet with its default, as Return does) and "crash" crashes it (`debug.crash.app`, SIGSEGV in the
        app's own process, so none of its quit path runs). The same bundle opens again through LaunchServices
        with its launch variables (the slot's HOME, socket and settings file). Then every named terminal is
        found again in the restored topology; the journey's checks say what came back."""
        how = step.get("how", "quit")
        app, old = self.app, self.app.pid
        env = app.launch_env()
        record = {"how": how, "old_pid": old}
        started = now()
        if how == "quit":
            record["waited_out_hold_s"] = self.before_keys()
            try:
                record["key"] = self.key("q", ["cmd"])
            except (StepError, OSError, ValueError) as error:
                record["key_error"] = str(error)[-200:]
            end = now() + QUIT_SECONDS
            while now() < end and app.alive(old):
                try:
                    report = app.rpc("debug.quit", timeout=5) or {}
                except (StepError, OSError, ValueError):
                    report = {}
                if isinstance(report, dict) and report.get("asking"):
                    default = str((report.get("prompt") or {}).get("default"))
                    record["sheet"] = {"default": default, "lines": report.get("lines"),
                                       "buttons": [b.get("id") for b in report.get("buttons") or []]}
                    app.rpc("debug.quit", {"press": default}, timeout=10)
                time.sleep(0.25)
        elif how == "crash":
            try:
                record["reply"] = app.rpc("debug.crash.app", {"signal": "segv"}, timeout=5)
            except (StepError, OSError, ValueError) as error:
                record["reply"] = f"no answer (expected): {str(error)[-120:]}"
            end = now() + QUIT_SECONDS
        elif how in QUIT_ACTIONS:
            # A quit of one kind with no dialog (QuitOrigin.explicit): the File menu's own actions.
            try:
                record["reply"] = app.rpc("action.run", {"action": QUIT_ACTIONS[how], "args": {}}, timeout=10)
            except (StepError, OSError, ValueError) as error:
                record["reply"] = f"no answer: {str(error)[-120:]}"
            end = now() + QUIT_SECONDS
        elif how in ("kill-app", "kill-both"):
            # SIGKILL: none of the app's quit path runs (and with kill-both, none of its daemon's either).
            if how == "kill-both":
                record["daemon_pid"] = app.daemon_pid()
                if not record["daemon_pid"]:
                    raise StepError("relaunch (kill-both): debug.daemon names no daemon pid")
                os.kill(record["daemon_pid"], signal.SIGKILL)
            os.kill(old, signal.SIGKILL)
            end = now() + QUIT_SECONDS
        else:
            raise StepError(f"relaunch: how is quit, crash, kill-app, kill-both or one of {sorted(QUIT_ACTIONS)}, not {how!r}")
        while now() < end and app.alive(old):
            time.sleep(0.25)
        if app.alive(old):
            raise StepError(f"relaunch ({how}): app pid {old} still runs {QUIT_SECONDS} s later: {json.dumps(record)[:300]}")
        record["ended_after_s"] = round(now() - started, 2)
        if callable(step.get("after_end")):
            # A caller's read between the end and the reopen (the action fuzzer: what the daemon kept).
            try:
                record["after_end"] = step["after_end"]()
            except (StepError, OSError, ValueError) as error:
                record["after_end"] = {"error": str(error)[-200:]}  # still reopen: the caller judges the error
        if step.get("leftovers_after") is not None:
            # What a person's Mac still runs after the quit: every process run from this bundle (its
            # path) or owned by it (`--owner BUNDLE_ID`, the terminal hosts), `leftovers_after` seconds on.
            time.sleep(float(step["leftovers_after"]))
            self.leftovers = {"after_s": float(step["leftovers_after"]), "rows": app.bundle_processes(old)}
            record["leftovers"] = self.leftovers
        if step.get("mark"):
            self.marks[step["mark"]] = now()
        # In the background (-g), as capture-host's own launch, unless that launch was --activate (a whole-host
        # lease): then the reopened app comes to the front and becomes the active app again, as a person sees it.
        argv = ["/usr/bin/open", *([] if ACTIVATE else ["-g"]), "-n", "-a", app.bundle]
        for key, value in env.items():
            argv += ["--env", f"{key}={value}"]
        opened = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        if opened.returncode != 0:
            raise StepError(f"relaunch: open exited {opened.returncode}: {(opened.stderr or opened.stdout)[-300:]}")
        t, end = now(), now() + RELAUNCH_SECONDS
        while now() < end:
            try:
                info = app.rpc("system.identify", timeout=3)
                if isinstance(info, dict) and info.get("pid") and int(info["pid"]) != old:
                    break
            except (StepError, OSError, ValueError):
                pass
            time.sleep(0.25)
        else:
            raise StepError(f"relaunch: the app never answered on {app.sock} within {RELAUNCH_SECONDS} s")
        app.reidentify(info)
        record.update(new_pid=app.pid, answered_after_s=round(now() - t, 2))
        # Restore has loaded once the topology says so; then each named terminal is looked up again.
        loaded = False
        while now() < end and not loaded:
            try:
                loaded = bool(self.topology().get("loaded"))
            except (StepError, OSError, ValueError):
                pass
            if not loaded:
                time.sleep(0.25)
        record["topology_loaded"] = loaded
        topo = self.topology() if loaded else None
        found = {}
        for name, alias in self.aliases.items():
            place = self.place_of(alias["term"], topo) if topo else None
            found[name] = place[1].get("id") if place else None
            if place:
                alias["pane"] = place[1].get("id")
        record["named_terminals"] = found
        # Restore settles when every shown terminal view is attached live (restore-journey.py's rule); then the
        # creation hold a restored selection opens is waited out (CREATION_HOLD_SECONDS).
        settled = False
        while now() < end and not settled:
            try:
                shown = [p for p in app.panes() if p.get("kind") == "terminal" and p.get("presence") == "visible"]
                settled = bool(shown) and all(p.get("attach") == "live" for p in shown)
            except (StepError, OSError, ValueError):
                pass
            if not settled:
                time.sleep(0.25)
        record["settled_after_s"] = round(now() - t, 2) if settled else None
        self.hold_from = now()
        if self.term:
            place = self.place_of(self.term, topo) if topo else None
            if place:
                self.pane = place[1].get("id")
        self.known_views = {p.get("terminal_id") for p in app.panes() if p.get("terminal_id")}
        return record

    def daemon_terminal_row(self, term):
        """The daemon's record of terminal `term` (`cmux terminal list`: cols, rows, cwd, lifecycle)."""
        rows = self.app.cmux("terminal", "list")
        if isinstance(rows, dict):
            rows = next((rows[k] for k in ("terminals", "value", "result") if isinstance(rows.get(k), list)), [])
        row = next((r for r in rows or [] if isinstance(r, dict) and r.get("id") == term), None)
        if row is None:
            raise StepError(f"terminal {term} is not in the daemon's terminal list ({len(rows or [])} terminals)")
        return row

    # -- conditions --

    def step_expect(self, step):
        conds = [self.sub(c) for c in step["all"]]
        since = step.get("since")
        if since and since not in self.marks:
            raise StepError(f"expect since {since!r}: no step set that mark")
        t0 = self.marks[since] if since else now()
        within = step.get("within")
        timeout_at = t0 + float(step.get("timeout", 10))
        state = [{"cond": c, "name": next(iter(c)), "ok": False, "at": None, "detail": None} for c in conds]
        for s in state:
            s["negative"] = negative(s["name"], s["cond"][s["name"]])
        live = [s for s in state if KIND.get(s["name"]) != "frame"]
        frames = [s for s in state if KIND.get(s["name"]) == "frame"]
        ticks = 0
        while True:
            ticks += 1
            cache = {}
            for s in live:
                # A positive condition holds once it has held; a negative one (something must NOT
                # show) is read again every poll, so it holds only together with the positive ones.
                if not s["ok"] or s["negative"]:
                    ok, detail = self.evaluate(s["name"], s["cond"][s["name"]], cache)
                    s["detail"] = detail
                    if ok and not s["ok"]:
                        s["at"] = now()
                    s["ok"] = ok
            if all(s["ok"] for s in live) or now() >= timeout_at:
                break
            time.sleep(POLL_SECONDS)
        # `settle` (seconds): the negative conditions must keep holding that much longer, so what the
        # step must not cause cannot show up late (a scrolled view that jumps, a paste that runs).
        settle_until = now() + float(step.get("settle", 0)) if all(s["ok"] for s in live) else now()
        while now() < settle_until:
            time.sleep(POLL_SECONDS * 4)
            cache = {}
            for s in live:
                if s["negative"] and s["ok"]:
                    ok, detail = self.evaluate(s["name"], s["cond"][s["name"]], cache)
                    if not ok:
                        s["ok"] = False
                        s["detail"] = dict(detail, broke_during_settle=True) if isinstance(detail, dict) else detail
        # A frame is read after the state it should show holds: the window draws it on its next frame,
        # so it gets FRAME_GRACE more seconds of fresh snapshots (text recognition time not counted
        # against the step's timeout), and at least two tries.
        frame_until = max(timeout_at, now() + FRAME_GRACE)
        for s in frames:
            tries = 0
            while not s["ok"]:
                time.sleep(0.25)
                tries += 1
                ok, detail = self.evaluate(s["name"], s["cond"][s["name"]], {})
                s["detail"] = dict(detail, tries=tries) if isinstance(detail, dict) else detail
                if ok:
                    s["ok"], s["at"] = True, now()
                elif now() >= frame_until and tries >= 2:
                    break
        failed = []
        for s in state:
            elapsed = None if s["at"] is None else round((s["at"] - t0) * 1000)
            limit = None if within is None or KIND.get(s["name"]) == "frame" else round(float(within) * 1000)
            passed = s["ok"] and (limit is None or elapsed <= limit)
            row = {"kind": KIND.get(s["name"], "other"), "check": s["name"], "want": s["cond"][s["name"]],
                   "pass": passed, "elapsed_ms": elapsed, "within_ms": limit, "detail": s["detail"],
                   "step": step.get("title", "")}
            self.evidence.append(row)
            if not passed:
                failed.append(f"{s['name']} {json.dumps(s['cond'][s['name']])}"
                              + (f" took {elapsed} ms > {limit} ms" if s["ok"]
                                 else " did not hold at the end" if s["negative"] else " never held"))
        result = {"polls": ticks, "since": since, "conditions": len(state)}
        if failed:
            raise StepError("; ".join(failed))
        return result

    def evaluate(self, name, want, cache):
        """(holds, detail) of one condition; `cache` keeps one read of each source per poll."""
        try:
            if name in EXT_CONDITIONS:
                return EXT_CONDITIONS[name](self, want, cache)
            special = getattr(self, "cond_" + name, None)
            if special is not None:
                return special(want, cache)
            if name in LIFE_CONDITIONS:
                return self.evaluate_life(name, want, cache)
            if name.startswith("daemon_"):
                if "screen" not in cache:
                    cache["screen"] = self.app.screen(self.need_term())
                text = cache["screen"]["text"]
                tail = [l for l in lines_of(text) if l.strip()][-4:]
                if name == "daemon_line":
                    return any(l.strip() == want.strip() for l in lines_of(text)), {"tail": tail}
                if name == "daemon_contains":
                    return want in text, {"tail": tail}
                if name == "daemon_lacks":
                    return want not in text, {"tail": tail}
                if name == "daemon_prompt":
                    return last_line(text) == PROMPT.rstrip(), {"last_line": last_line(text)}
            if name.startswith("app_"):
                if "pane" not in cache:
                    cache["pane"] = next((p for p in self.app.panes() if p.get("pane") == self.pane), None)
                pane = cache["pane"]
                if pane is None:
                    return False, {"error": f"pane {self.pane} is not in debug.surfaces"}
                text = pane.get("text") or ""
                tail = [l for l in lines_of(text) if l.strip()][-4:]
                if name == "app_text_line":
                    return any(l.strip() == want.strip() for l in lines_of(text)), {"tail": tail, "link": pane.get("link")}
                if name == "app_text_contains":
                    return want in text, {"tail": tail}
                if name == "app_text_lacks":
                    return want not in text, {"tail": tail}
                if name == "app_prompt":
                    return last_line(text) == PROMPT.rstrip(), {"last_line": last_line(text), "link": pane.get("link")}
                if name == "app_pane":
                    got = {k: pane.get(k) for k in want}
                    return got == want, {"got": got}
            if name.startswith("process_"):
                if "ps" not in cache:
                    cache["ps"] = self.app.processes()
                table = cache["ps"]
                if name == "process_present":
                    scope = descendants(table, self.app.roots(table, self.host_pid))
                    hits = [table[p] for p in sorted(scope) if re.search(want["match"], table[p]["command"])]
                    tty = self.ttys.get(self.term) if self.term else None
                    detail = {"matches": hits[:3], "count": len(hits), "tty": tty, "scope_root": self.host_pid or "bundle"}
                    if want.get("foreground"):
                        # A controlling tty, and the process in its foreground group (ps `+`): Ctrl+C can reach it.
                        good = [h for h in hits if h["tty"] not in ("??", "-", "") and "+" in h["stat"]]
                        # This terminal's tty: the host also runs the other terminals' shells and jobs.
                        if tty:
                            good = [h for h in good if h["tty"] == tty]
                        elif want.get("bind") and len({h["tty"] for h in good}) > 1:
                            # Which one is this terminal's is unknown: a guess would bind another terminal's.
                            detail["error"] = f"matches on ttys {sorted({h['tty'] for h in good})}; this terminal's tty is unknown"
                            return False, detail
                    else:
                        good = hits
                    if good and want.get("bind"):
                        self.binds[want["bind"]] = good[0]
                        detail["bound"] = good[0]
                    return bool(good), detail
                if name == "process_gone":
                    bound = self.binds.get(want)
                    if not bound:
                        return False, {"error": f"no process bound as {want!r}"}
                    row = table.get(bound["pid"])
                    alive = row is not None and not row["stat"].startswith("Z") and row["command"] == bound["command"]
                    return not alive, {"pid": bound["pid"], "tty": bound["tty"], "now": row}
            if name == "frame_text":
                self.checks += 1
                image = self.app.snapshot(self.out / f"check-{self.checks:02d}.png")
                lines = self.app.read_text(image)
                return ocr_contains(lines, want), {"image": image.name, "text": lines[-12:], "lines": len(lines)}
        except (StepError, OSError, ValueError, subprocess.TimeoutExpired) as error:
            return False, {"error": str(error)[-300:]}
        return False, {"error": f"unknown condition {name}"}

    def evaluate_life(self, name, want, cache):
        """The app-life conditions: layout and working directories from the app's topology and the
        daemon's terminal list, app reports over the control socket, grids in both."""
        def topo():
            if "topology" not in cache:
                cache["topology"] = self.topology()
            return cache["topology"]

        def term_of(spec, key):
            """The terminal a condition names (`name`: an alias), else the current one; and its wanted value."""
            if isinstance(spec, dict):
                alias = spec.get("name")
                if alias and alias not in self.aliases:
                    raise StepError(f"no terminal named {alias!r}")
                return (self.aliases[alias]["term"] if alias else self.need_term()), spec.get(key)
            return self.need_term(), spec

        def compare(got, rules):
            """`rules`: {"equals"|"not_equals"|"in"|"not_in"|"contains"|"lacks"|"gte"|"lte"|"gt"|"lt"|"len"|"len_gte": value};
            all must hold. `not_equals`, `not_in`: a missing value (None) does not hold either, so a wrong
            path cannot pass a negative rule."""
            for rule, value in rules.items():
                if rule == "not_equals" and (got is None or got == value):
                    return False
                if rule == "in" and got not in value:
                    return False
                if rule == "not_in" and (got is None or got in value):
                    return False
                if rule == "equals" and got != value:
                    # A remembered ${number} arrives as text: numbers compare as numbers.
                    try:
                        if isinstance(got, bool) or float(got) != float(value):
                            return False
                    except (TypeError, ValueError):
                        return False
                if rule == "contains" and (got is None or str(value) not in (got if isinstance(got, (list, str)) else json.dumps(got))):
                    return False
                # `lacks`: the value (as JSON text when not a string) does not contain the text; a missing value fails.
                if rule == "lacks" and (got is None or str(value) in (got if isinstance(got, str) else json.dumps(got))):
                    return False
                if rule in ("gte", "lte", "gt", "lt"):
                    try:
                        g, v = float(got), float(value)
                    except (TypeError, ValueError):
                        return False
                    if not {"gte": g >= v, "lte": g <= v, "gt": g > v, "lt": g < v}[rule]:
                        return False
                if rule in ("len", "len_gte"):
                    if not isinstance(got, (list, dict, str)):
                        return False
                    if (rule == "len" and len(got) != int(value)) or (rule == "len_gte" and len(got) < int(value)):
                        return False
            return True

        if name == "daemon_cwd":
            term, path = term_of(want, "cwd")
            row = self.daemon_terminal_row(term)
            return same_dir(row.get("cwd"), path), {"cwd": row.get("cwd"), "terminal": term}
        if name == "daemon_grid":
            row = self.daemon_terminal_row(self.need_term())
            got = {"cols": row.get("cols"), "rows": row.get("rows")}
            ok = all(compare(got.get(rule.split("_")[0]), {rule.split("_", 1)[1] if "_" in rule else "equals": value})
                     for rule, value in want.items())
            return ok, got
        if name == "daemon_pane_ready":
            place = self.place_of(self.need_term(), topo())
            if not place:
                return False, {"error": f"terminal {self.term} is in no tab"}
            terms = [t for _, pane, _, t in self.places(topo()) if pane.get("id") == place[1].get("id") and t]
            empty = [t for t in terms if not self.app.screen(t)["text"].strip()]
            return len(terms) >= int(want.get("tabs", 1)) and not empty, {"terminals": len(terms), "empty": empty[:5]}
        if name == "app_cwd":
            term, path = term_of(want, "cwd")
            place = self.place_of(term, topo())
            got = place[2].get("cwd") if place else None
            return place is not None and same_dir(got, path), {"cwd": got, "terminal": term}
        if name == "app_layout":
            t = topo()
            place = self.place_of(self.need_term(), t)
            if not place:
                return False, {"error": f"terminal {self.term} is in no tab of the topology"}
            ws, pane, _ = place
            panes = [p for s in ws.get("screens", []) for p in s.get("panes", [])]
            got = {"windows": len(t.get("windows", [])), "workspace": ws.get("name"), "panes": len(panes),
                   "tabs": sum(len(p.get("tabs", [])) for p in panes), "pane_tabs": len(pane.get("tabs", [])),
                   "selected": pane.get("selected_tab") == place[2].get("id")}
            ok = all(got.get(k) == v for k, v in want.items() if k != "bind_workspace")
            if ok and want.get("bind_workspace"):
                # `bind_workspace`: the workspace's name as ${NAME} (an automatic name, checked after a quit).
                self.vars[want["bind_workspace"]] = got["workspace"]
            return ok, got
        if name == "app_tab_pane":
            place = self.place_of(self.need_term(), topo())
            other_name = want.get("same_as") or want.get("not_same_as")
            if other_name not in self.aliases:
                return False, {"error": f"no terminal named {other_name!r}"}
            other = self.place_of(self.aliases[other_name]["term"], topo())
            if not place or not other:
                return False, {"error": "a terminal is in no tab", "here": bool(place), "other": bool(other)}
            same = place[1].get("id") == other[1].get("id")
            return (same if want.get("same_as") else not same), {"pane": place[1].get("id"), "other_pane": other[1].get("id")}
        if name == "app_tab_gone":
            if want not in self.aliases:
                return False, {"error": f"no terminal named {want!r}"}
            place = self.place_of(self.aliases[want]["term"], topo())
            return place is None, {"tab": place[2].get("id") if place else None}
        if name == "app_rpc":
            reply = self.app.rpc(want["method"], want.get("params") or {})
            got = dig(reply, want.get("path", ""))
            rules = {k: v for k, v in want.items() if k not in ("method", "params", "path", "bind")}
            ok = compare(got, rules)
            if ok and want.get("bind"):
                # `bind`: the value as ${NAME} for later steps (a pane id read before a quit, checked after it).
                self.vars[want["bind"]] = got
            return ok, {"got": got if len(json.dumps(got, default=str)) < 600 else json.dumps(got, default=str)[:600]}
        if name == "app_grid":
            view = self.view_of_pane(self.pane) or {}
            grid = view.get("grid") or {}
            got = {"cell_height": grid.get("cell_height"), "cell_width": grid.get("cell_width"), "grid": (view.get("surface") or {}).get("grid")}
            ok = all(compare(got.get(rule.rsplit("_", 1)[0]), {rule.rsplit("_", 1)[1]: value}) for rule, value in want.items())
            return ok, got
        return False, {"error": f"unknown condition {name}"}

    # -- the run --

    def run(self):
        started, wall = now(), time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        frames = Frames(self.app, self.out / "frames", self.frame_interval)
        frames.start()
        status, reason = "pass", ""
        try:
            for index, step in enumerate(self.spec["steps"]):
                if now() > self.deadline:
                    raise Deadline(f"the lease deadline came before step {index + 1} ({step['do']})")
                record = {"index": index + 1, "do": step["do"], "title": step.get("title", "")}
                handler = getattr(self, "step_" + step["do"], None)
                if handler is None:
                    raise StepError(f"unknown step {step['do']!r}")
                if step["do"] in ("key", "type", "rpc", "new_terminal"):
                    # The terminals on screen before an input: `focused_terminal` waits for one not among them.
                    self.known_views |= {p.get("terminal_id") for p in self.app.panes() if p.get("terminal_id")}
                t = now()
                try:
                    record["result"] = handler(step)
                    record["ok"] = True
                    if step.get("as"):
                        # Names the current terminal for later `use` steps and conditions.
                        self.aliases[step["as"]] = {"term": self.need_term(), "pane": self.pane, "host_pid": self.host_pid}
                        view = self.view_of_pane(self.pane)
                        if view and view.get("terminal_id"):
                            self.known_views.add(view["terminal_id"])
                except StepError as error:
                    record["ok"], record["error"] = False, str(error)[-600:]
                    raise
                finally:
                    record["seconds"] = round(now() - t, 3)
                    self.steps.append(record)
        except (Deadline, NotRun) as error:
            status, reason = "not run", str(error)
        except (StepError, OSError, ValueError, subprocess.TimeoutExpired) as error:
            status, reason = "fail", f"step {len(self.steps)} ({self.steps[-1]['do'] if self.steps else '?'}): {error}"
        finally:
            # `finally` steps put the app back for the next journey (leave full screen, close a second
            # window), whatever happened; their errors are recorded and never change the status.
            for step in self.spec.get("finally") or []:
                record = {"do": step["do"], "title": step.get("title", ""), "finally": True}
                try:
                    record["result"] = getattr(self, "step_" + step["do"])(step)
                    record["ok"] = True
                except Exception as error:  # noqa: BLE001 (clean-up: record any error, keep going)
                    record["ok"], record["error"] = False, str(error)[-300:]
                self.steps.append(record)
            frames.stopped.set()
            frames.join(timeout=SNAPSHOT_TIMEOUT)
            for path in self.files:
                try:
                    os.unlink(path)
                except OSError:
                    pass
        if status == "pass":
            kinds = {e["kind"] for e in self.evidence if e["pass"]}
            missing = [k for k in REQUIRED_KINDS if k not in kinds]
            if missing:
                status, reason = "fail", "not enough evidence: no passing " + ", ".join(missing) + " check"
            elif not all(e["pass"] for e in self.evidence):
                status, reason = "fail", "a check failed"
        clip = self.clip_frames()
        result = {"id": self.id, "priority": self.spec.get("priority"), "title": self.spec.get("title"),
                  "status": status, "reason": reason, "started_at": wall, "seconds": round(now() - started, 2),
                  "nonce": self.nonce, "terminal": self.term, "pane": self.pane, "host_pid": self.host_pid,
                  # run.py's run (--run-id, --run-started-at): run.py takes no result.json without its own (STATUS 1362).
                  "run_id": RUN["run_id"], "run_started_at": RUN["run_started_at"],
                  "frames": frames.count, "clip_frames": clip, "steps": self.steps, "evidence": self.evidence}
        (self.out / "result.json").write_text(json.dumps(result, indent=1, default=str) + "\n")
        return result

    def clip_frames(self):
        """The frames scaled to CLIP_WIDTH (sips, stock macOS) in clip/: what run.py fetches for the clip."""
        frames = sorted((self.out / "frames").glob("frame-*.png"))
        if not frames:
            return 0
        clip = self.out / "clip"
        clip.mkdir(exist_ok=True)
        done = subprocess.run(["/usr/bin/sips", "--resampleWidth", str(CLIP_WIDTH), *map(str, frames), "--out", str(clip)],
                              capture_output=True, text=True, timeout=300)
        if done.returncode == 0:
            shutil.rmtree(self.out / "frames")
        return len(list(clip.glob("frame-*.png")))


def load_extensions(module):
    """Step and condition groups beside this file (`ext_*.py`): each has `install(driver)`, `STEPS`
    ({name: fn(journey, step)}, played as `do: name`) and `CONDITIONS` ({name: (evidence kind, fn(journey,
    want, cache) -> (holds, detail))}). They must not import this file (it runs as __main__ on the mini)."""
    import importlib
    for path in sorted(Path(os.path.dirname(os.path.abspath(__file__))).glob("ext_*.py")):
        ext = importlib.import_module(path.stem)
        ext.install(module)
        for name, fn in getattr(ext, "STEPS", {}).items():
            if hasattr(Journey, "step_" + name):
                raise SystemExit(f"driver: {path.name} redefines step {name!r}")
            setattr(Journey, "step_" + name, fn)
        for name, (kind, fn) in getattr(ext, "CONDITIONS", {}).items():
            if name in KIND:
                raise SystemExit(f"driver: {path.name} redefines condition {name!r}")
            KIND[name], EXT_CONDITIONS[name] = kind, fn
        # `NEGATIVE`: the group's conditions that claim something did NOT happen (read every poll and through `settle`).
        EXT_NEGATIVE.update(n for n in getattr(ext, "NEGATIVE", ()) if n in EXT_CONDITIONS)


load_extensions(sys.modules[__name__])


# Whether the app was launched active (capture-host launch --activate, a whole-host lease); main sets it.
ACTIVATE = False
# The run.py run these results belong to (--run-id, --run-started-at); main sets it.
RUN = {"run_id": None, "run_started_at": None}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--socket", required=True)
    ap.add_argument("--app", required=True, help="the slot's app bundle (capture-host launch's app=)")
    ap.add_argument("--home", required=True, help="the slot's HOME, for the bundled CLI")
    ap.add_argument("--journeys", required=True, help="a JSON list of journey specs")
    ap.add_argument("--out", required=True)
    ap.add_argument("--ocr", required=True, help="the compiled scripts/ci/pr_media_ocr.swift")
    ap.add_argument("--deadline-seconds", type=float, default=480)
    ap.add_argument("--frame-interval", type=float, default=FRAME_INTERVAL)
    ap.add_argument("--activate", action="store_true",
                    help="the app was launched active (capture-host launch --activate): a relaunch opens it in front")
    ap.add_argument("--run-id", help="run.py's run id, written into each result.json (run.py refuses any other)")
    ap.add_argument("--run-started-at", help="run.py's run start (UTC, %%Y-%%m-%%dT%%H:%%M:%%SZ), written beside the run id")
    a = ap.parse_args(argv)
    global ACTIVATE
    ACTIVATE = a.activate
    RUN.update(run_id=a.run_id, run_started_at=a.run_started_at)
    deadline = now() + a.deadline_seconds
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    app = App(a.socket, a.app, a.home, a.ocr)
    host = {"run_id": a.run_id, "host": socket.gethostname().split(".")[0], "macos": subprocess.run(["sw_vers", "-productVersion"],
            capture_output=True, text=True).stdout.strip(), "identify": app.identity, "sessions": app.sessions}
    (out / "host.json").write_text(json.dumps(host, indent=1, default=str) + "\n")
    # Text recognition loads its models on first use (tens of seconds on a cold mini): warm it up
    # before any journey, so no frame check pays for it.
    try:
        warm = app.snapshot(out / "warmup.png")
        t = now()
        app.read_text(warm)
        host["ocr_warmup_seconds"] = round(now() - t, 2)
        warm.unlink()
    except (StepError, OSError, subprocess.TimeoutExpired) as error:
        host["ocr_warmup_error"] = str(error)[-300:]
    (out / "host.json").write_text(json.dumps(host, indent=1, default=str) + "\n")
    results = []
    for spec in json.loads(Path(a.journeys).read_text()):
        if now() > deadline:
            results.append({"id": spec["id"], "status": "not run", "reason": "the lease deadline came first"})
            continue
        result = Journey(spec, app, out, deadline, a.frame_interval).run()
        PLAYED.append(result["id"])
        results.append(result)
        print(f"journey {result['id']}: {result['status']} {result['reason']}", flush=True)
    (out / "summary.json").write_text(json.dumps([{k: r.get(k) for k in ("id", "status", "reason")} for r in results],
                                                 indent=1) + "\n")
    return 0 if all(r["status"] == "pass" for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
