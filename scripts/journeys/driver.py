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
import json
import os
import random
import re
import shutil
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
        # App life (journeys/p0/app-life-*.json): layout, working directories, restore and settings.
        "daemon_cwd": "daemon", "daemon_grid": "daemon", "daemon_pane_ready": "daemon",
        "app_cwd": "app", "app_layout": "app", "app_tab_pane": "app", "app_tab_gone": "app", "app_rpc": "app",
        "app_grid": "app"}
# Seconds a quit (Cmd-Q or a crash) may take to end the app's process, and a relaunch to answer.
QUIT_SECONDS = 60
RELAUNCH_SECONDS = 90
# A capture slot's window is never the key window (the app runs with CMUX_NEXT_NO_ACTIVATE). Keys typed while
# the app holds them for a terminal still being made (CreationInputCoordinator: after Cmd-D, Ctrl-` or a restore,
# at most its holdLimit of 2 s) are replayed through NSApp.sendEvent, which only reaches the key window, so in a
# slot they are lost (a person's window is key). Steps that make a terminal wait this long before the next key.
CREATION_HOLD_SECONDS = 2.5
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

    def roots(self, table, host_pid):
        """The terminal's host when the app named it, else every process run from the app's bundle."""
        if host_pid and host_pid in table:
            return {host_pid}
        return {pid for pid, row in table.items() if row["command"].startswith(self.bundle + "/")}

    def snapshot(self, path):
        path = Path(path)
        if path.exists():
            path.unlink()
        self.rpc("debug.window_snapshot", {"kind": "main", "path": str(path)}, timeout=SNAPSHOT_TIMEOUT)
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
        self.term = self.pane = self.host_pid = None
        self.steps, self.evidence, self.checks = [], [], 0
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
        before = {p.get("terminal_id") for p in self.app.panes() if p.get("terminal_id")}
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
        self.app.cmux("terminal", self.need_term(), "write", "--text", NEUTRAL_PROMPT)
        end = now() + float(step.get("timeout", 15))
        while now() < end:
            if last_line(self.app.screen(self.term)["text"]) == PROMPT.rstrip():
                return {"prompt": PROMPT}
            time.sleep(0.1)
        raise StepError(f"the neutral prompt never showed; screen ends {last_line(self.app.screen(self.term)['text'])!r}")

    def step_type(self, step):
        # The mark is the moment the command is entered (Return), else the first key.
        text = self.sub(step["text"])
        held = self.before_keys()
        replies = []
        if step.get("mark") and not step.get("enter"):
            self.marks[step["mark"]] = now()
        for char in text:
            replies.append(self.key(char, []))
            time.sleep(0.01)
        if step.get("enter"):
            if step.get("mark"):
                self.marks[step["mark"]] = now()
            replies.append(self.key("return", []))
        routes = sorted({str(r.get("handled_by")) for r in replies if isinstance(r, dict)})
        # One full reply per route (its trace says who took the key): evidence when typing went astray.
        samples = {}
        for char, reply in zip(text + ("\r" if step.get("enter") else ""), replies):
            if isinstance(reply, dict) and str(reply.get("handled_by")) not in samples:
                samples[str(reply.get("handled_by"))] = {"char": char, "reply": reply}
        return {"typed": text, "keys": len(replies), "handled_by": routes, "samples": samples, "waited_out_hold_s": held}

    def step_key(self, step):
        held = self.before_keys()
        if step.get("mark"):
            self.marks[step["mark"]] = now()
        # `repeat`: the same key N times, `gap` seconds apart (a person pressing it again and again).
        repeat, replies, took = int(step.get("repeat", 1)), [], []
        for index in range(repeat):
            if index:
                time.sleep(float(step.get("gap", 0.1)))
            t = now()
            replies.append(self.key(step["key"], step.get("modifiers", [])))
            took.append(round((now() - t) * 1000, 1))
        if repeat == 1:
            return {"key": step["key"], "modifiers": step.get("modifiers", []), "reply": replies[0], "waited_out_hold_s": held}
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

    def key(self, key, modifiers):
        self.last_key_at = now()
        return self.app.rpc("debug.key", {"key": key, "modifiers": modifiers})

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

    def step_remember(self, step):
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
            raise StepError(f"remember: unknown source {source!r}")
        if value is None:
            raise StepError(f"remember {source}: no value")
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
        else:
            raise StepError(f"relaunch: how is quit or crash, not {how!r}")
        while now() < end and app.alive(old):
            time.sleep(0.25)
        if app.alive(old):
            raise StepError(f"relaunch ({how}): app pid {old} still runs {QUIT_SECONDS} s later: {json.dumps(record)[:300]}")
        record["ended_after_s"] = round(now() - started, 2)
        if step.get("mark"):
            self.marks[step["mark"]] = now()
        argv = ["/usr/bin/open", "-g", "-n", "-a", app.bundle]
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
        live = [s for s in state if s["name"] != "frame_text"]
        frames = [s for s in state if s["name"] == "frame_text"]
        ticks = 0
        while True:
            ticks += 1
            cache = {}
            for s in live:
                if not s["ok"]:
                    ok, detail = self.evaluate(s["name"], s["cond"][s["name"]], cache)
                    s["detail"] = detail
                    if ok:
                        s["ok"], s["at"] = True, now()
            if all(s["ok"] for s in live) or now() >= timeout_at:
                break
            time.sleep(POLL_SECONDS)
        # A frame is read after the state it should show holds: the window draws it on its next frame,
        # so it gets FRAME_GRACE more seconds of fresh snapshots (text recognition time not counted
        # against the step's timeout), and at least two tries.
        frame_until = max(timeout_at, now() + FRAME_GRACE)
        for s in frames:
            tries = 0
            while not s["ok"]:
                time.sleep(0.25)
                tries += 1
                ok, detail = self.evaluate("frame_text", s["cond"]["frame_text"], {})
                s["detail"] = dict(detail, tries=tries) if isinstance(detail, dict) else detail
                if ok:
                    s["ok"], s["at"] = True, now()
                elif now() >= frame_until and tries >= 2:
                    break
        failed = []
        for s in state:
            elapsed = None if s["at"] is None else round((s["at"] - t0) * 1000)
            limit = None if within is None or s["name"] == "frame_text" else round(float(within) * 1000)
            passed = s["ok"] and (limit is None or elapsed <= limit)
            row = {"kind": KIND.get(s["name"], "other"), "check": s["name"], "want": s["cond"][s["name"]],
                   "pass": passed, "elapsed_ms": elapsed, "within_ms": limit, "detail": s["detail"],
                   "step": step.get("title", "")}
            self.evidence.append(row)
            if not passed:
                failed.append(f"{s['name']} {json.dumps(s['cond'][s['name']])}"
                              + (f" took {elapsed} ms > {limit} ms" if s["ok"] else " never held"))
        result = {"polls": ticks, "since": since, "conditions": len(state)}
        if failed:
            raise StepError("; ".join(failed))
        return result

    def evaluate(self, name, want, cache):
        """(holds, detail) of one condition; `cache` keeps one read of each source per poll."""
        try:
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
                    if want.get("foreground"):
                        # A controlling tty, and the process in its foreground group (ps `+`): Ctrl+C can reach it.
                        good = [h for h in hits if h["tty"] not in ("??", "-", "") and "+" in h["stat"]]
                    else:
                        good = hits
                    if good and want.get("bind"):
                        self.binds[want["bind"]] = good[0]
                    return bool(good), {"matches": hits[:3], "scope_root": self.host_pid or "bundle"}
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
            """`rules`: {"equals"|"contains"|"gte"|"lte"|"gt"|"lt"|"len"|"len_gte": value}; all must hold."""
            for rule, value in rules.items():
                if rule == "equals" and got != value:
                    # A remembered ${number} arrives as text: numbers compare as numbers.
                    try:
                        if isinstance(got, bool) or float(got) != float(value):
                            return False
                    except (TypeError, ValueError):
                        return False
                if rule == "contains" and (got is None or str(value) not in (got if isinstance(got, (list, str)) else json.dumps(got))):
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
            return all(got.get(k) == v for k, v in want.items()), got
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
            rules = {k: v for k, v in want.items() if k not in ("method", "params", "path")}
            return compare(got, rules), {"got": got if len(json.dumps(got, default=str)) < 600 else json.dumps(got, default=str)[:600]}
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
            frames.stopped.set()
            frames.join(timeout=SNAPSHOT_TIMEOUT)
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
    a = ap.parse_args(argv)
    deadline = now() + a.deadline_seconds
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    app = App(a.socket, a.app, a.home, a.ocr)
    host = {"host": socket.gethostname().split(".")[0], "macos": subprocess.run(["sw_vers", "-productVersion"],
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
