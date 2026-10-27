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
        # Negative reads, scrollback rows and the clipboard ("Scroll, paste, select" below).
        "daemon_lacks": "daemon", "daemon_history": "daemon", "app_text_lacks": "app", "app_rows": "app",
        "frame_screen": "frame", "clipboard": "clipboard"}


def now():
    return time.monotonic()


class StepError(Exception):
    pass


class Deadline(Exception):
    pass


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
OCR_FOLD = str.maketrans({"O": "0", "o": "0", "D": "0", "I": "1", "l": "1", "|": "1", "i": "1", "S": "5", "s": "5",
                          "B": "8", "Z": "2", "z": "2", "—": "-", "–": "-", "_": "-"})


def ocr_contains(lines, wanted):
    """Whether OCR'd `lines` show `wanted` (spaces dropped, look-alike letters folded)."""
    fold = lambda s: re.sub(r"\s+", "", s).translate(OCR_FOLD).lower()
    target = fold(wanted)
    return any(target in fold(line) for line in lines) or target in fold("".join(lines))


def negative(name, want):
    """Whether a condition claims something is NOT there: read again every poll, never latched."""
    if name in ("daemon_lacks", "app_text_lacks"):
        return True
    # daemon_history with `lacks`; app_rows with `hold` (the view must stay as it is, e.g. while output arrives).
    return isinstance(want, dict) and ((name == "daemon_history" and "lacks" in want)
                                       or (name == "app_rows" and bool(want.get("hold"))))


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
        self.files = []

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
        return {"typed": text, "keys": len(replies), "handled_by": routes}

    def step_key(self, step):
        if step.get("mark"):
            self.marks[step["mark"]] = now()
        reply = self.key(step["key"], step.get("modifiers", []))
        return {"key": step["key"], "modifiers": step.get("modifiers", []), "reply": reply}

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

    def key(self, key, modifiers):
        return self.app.rpc("debug.key", {"key": key, "modifiers": modifiers})

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

    def cond_clipboard(self, want, cache):
        """The Mac's general pasteboard (what Cmd+V pastes, `pbpaste`) is exactly `want`."""
        env = {"LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "PATH": "/usr/bin:/bin"}
        got = subprocess.run(["/usr/bin/pbpaste"], env=env, capture_output=True, timeout=30).stdout.decode(errors="replace")
        return got == want, {"got": got[:200], "bytes": len(got.encode())}

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
            special = getattr(self, "cond_" + name, None)
            if special is not None:
                return special(want, cache)
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
                t = now()
                try:
                    record["result"] = handler(step)
                    record["ok"] = True
                except StepError as error:
                    record["ok"], record["error"] = False, str(error)[-600:]
                    raise
                finally:
                    record["seconds"] = round(now() - t, 3)
                    self.steps.append(record)
        except Deadline as error:
            status, reason = "not run", str(error)
        except (StepError, OSError, ValueError, subprocess.TimeoutExpired) as error:
            status, reason = "fail", f"step {len(self.steps)} ({self.steps[-1]['do'] if self.steps else '?'}): {error}"
        finally:
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
        results.append(result)
        print(f"journey {result['id']}: {result['status']} {result['reason']}", flush=True)
    (out / "summary.json").write_text(json.dumps([{k: r.get(k) for k in ("id", "status", "reason")} for r in results],
                                                 indent=1) + "\n")
    return 0 if all(r["status"] == "pass" for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
