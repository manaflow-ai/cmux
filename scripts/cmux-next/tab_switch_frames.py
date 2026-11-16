#!/usr/bin/env python3
"""Tab switch harness: every switch judged from the frames the screen showed, idle and under load (tab-switch/v1).

Leo, 2026-11-15 (softened): have we ever had benchmarks on any of this? Why is it so slow? It should be instant even
under load, and a tab or its animation not knowing where it should go is silly; we should have had CI for this a long
time ago. His NIGHTLY recording shows blank panes on return, an empty centered composer flashing before the
transcript, content and composer jumping as rows arrive, and a new tab not knowing where it goes.

Runs on a Mac with a console session (scripts/measure/tab-switch.sh build=nightly|SHA, through `cmux-ci run
--display`), against a shipped NIGHTLY (no debug.* commands: only the public control socket's snapshot.get and
action.run) or a built app. The frames come from outside the app, so the same harness measures both: CuaDriver records
the display under the fleet's Screen Recording grant, a marker window flipped before each action syncs the video to
the actions, and the video is decoded into frames (tab_switch_capture.py, scripts/measure/tab-switch-frames/tools.swift).
A mark is the display frame that showed the marker's flip, so a time counts from there, not from the input itself.

Workload, in one pane of a fresh workspace: a terminal, a long chat (a session on the app's own acpmux written by
chat_open_agent.py, --chat-turns answered turns with thoughts, tool calls and Markdown), and a Chromium page.

Scenarios (--scenarios), each --rounds times under each load (--loads):
  chat-long-return   the chat shown, switch to the terminal, back to the chat: judged against the chat's last frame
  terminal-return    the terminal shown, switch to the Chromium page and back
  chromium-return    the Chromium page shown, switch to the terminal and back
  new-tab            a new terminal tab from the terminal (newSurface): the settled frame, the strip's insert and end
  close-tab          close that new tab (closeTab): judged against the neighbor's last frame, the strip too
Loads:
  idle     nothing else runs
  cpu      spinners on every core (as chat-open-bench.py's load)
  agents   --agents chats on the app's acpmux, each streaming a word --stream-rate times a second, open in a
           background workspace
Per switch (tab_switch_judge.py): to_content_ms, blank_frames, wrong_frames, shift_px, insert_ok, anim_end_ok.
Budgets: content within one display frame, 0 blank, 0 wrong, 0 px shift, insert and animation end right.

Writes OUT/report.json (schema tab-switch/v1) and, for every failing switch, a contact sheet OUT/sheets/*.png (the
frame before the switch, the frames after it, the expected end frame last). Exit 0 when every budget holds, 1 when
one fails (0 with --no-gate), 3 when it could not measure (no capture, no window, no workload).
Kills only what it started: the app copy it launched (its bundle's processes), its spinners, its marker window and
its CuaDriver session.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import tab_switch_capture as capture  # noqa: E402
import tab_switch_judge as judge  # noqa: E402


def mac_helpers():
    """bench_memory and idle_cost_load, imported on use: bench_memory loads macOS's libproc at import, and this module
    imports on any host (its tests run on Linux)."""
    import bench_memory
    import idle_cost_load
    return bench_memory, idle_cost_load


TURNS_AGENT = ("tab-switch-turns", os.path.join(HERE, "chat_open_agent.py"))
STREAM_AGENT = ("tab-switch-stream", os.path.join(HERE, "idle_cost_agent.py"))
SPIN_C = r"""#include <pthread.h>
static void*t(void*a){volatile unsigned long x=0;for(;;)x++;return 0;}
int main(){pthread_t th;for(int i=0;i<3;i++)pthread_create(&th,0,t,0);t(0);return 0;}
"""
WINDOW_FRAME = "40,40,1400,900"


def say(*parts):
    print("tab-switch:", *parts, flush=True)


class Unmeasurable(Exception):
    """The harness could not measure (exit 3)."""


def load_smoke():
    path = os.path.join(ROOT, "scripts/ci/fresh_home_launch_smoke.py")
    spec = importlib.util.spec_from_file_location("fresh_home_launch_smoke", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------------------------------------------------------
# The app.

class Control:
    def __init__(self, path):
        self.path = path

    def call(self, method, params=None, timeout=30):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                conn.settimeout(timeout)
                conn.connect(self.path)
                conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
                buf = b""
                while not buf.endswith(b"\n"):
                    chunk = conn.recv(1 << 20)
                    if not chunk:
                        break
                    buf += chunk
            answer = json.loads(buf or b"{}")
        except (OSError, ValueError) as error:
            return {"error": f"{method}: {error}"}
        if answer.get("error"):
            return {"error": answer["error"]}
        return answer.get("result") if answer.get("result") is not None else {}

    def action(self, action_id, /, focus=True, **args):
        """`action.run` of `action_id` with `args` (positional-only, so an action's own `name` or `action` argument
        is one of its args, as agent.harness.add's `name`)."""
        params = {"action": action_id, "args": args, "wait": True, "origin": "script",
                  "idempotency_key": f"mutation_{uuid.uuid4().hex}"}
        if focus:
            params["focus"] = True
        return self.call("action.run", params, timeout=60)

    def topology(self):
        snap = self.call("snapshot.get", timeout=15)
        return (snap or {}).get("topology") or {} if isinstance(snap, dict) else {}

    def focused_tabs(self):
        topology = self.topology()
        pane_id = (topology.get("focus") or {}).get("pane")
        for workspace in topology.get("workspaces") or []:
            for screen in workspace.get("screens") or []:
                for pane in screen.get("panes") or []:
                    if pane.get("id") == pane_id:
                        return pane.get("tabs") or [], pane
        return [], None


class App:
    """One launch of the app under test: a fresh home, onboarding skipped, its defaults set aside and put back."""

    def __init__(self, bundle, root, smoke):
        self.bundle, self.root, self.smoke = bundle, root, smoke
        self.bundle_id, self.executable = smoke.bundle_info(__import__("pathlib").Path(bundle))
        self.aside = None
        self.process = None

    def launch(self):
        from pathlib import Path
        self.aside = self.smoke.DefaultsAside(self.bundle_id, Path(self.root))
        self.aside.__enter__()
        subprocess.run(["defaults", "write", self.bundle_id, "home.firstRun.historyImportShown", "-bool", "YES"],
                       capture_output=True, timeout=30)
        self.socket_path = os.path.join(self.root, "c.sock")
        env = self.smoke.fresh_env(Path(self.root), Path(self.socket_path), 2)
        env.pop("CMUX_NEXT_LAUNCH_MARKS_FD", None)
        env.pop("CMUX_NEXT_NO_ACTIVATE", None)  # the window is in front on the worker's display: the capture reads it
        env.update({"CMUX_NEXT_SKIP_ONBOARDING": "1", "CMUX_NEXT_TEST_WINDOW_FRAME": WINDOW_FRAME,
                    "CMUX_NEXT_DOWNLOADS_DIR": os.path.join(self.root, "downloads")})
        os.makedirs(env["CMUX_NEXT_DOWNLOADS_DIR"], exist_ok=True)
        binary = os.path.join(self.bundle, "Contents/MacOS", self.executable)
        self.log = open(os.path.join(self.root, "app.log"), "a")
        self.process = subprocess.Popen([binary, "-ApplePersistenceIgnoreState", "YES"], env=env, stdout=self.log,
                                        stderr=self.log, stdin=subprocess.DEVNULL, start_new_session=True)
        say(f"app pid {self.process.pid}")
        self.control = Control(self.socket_path)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise Unmeasurable(f"the app exited ({self.process.returncode}) before its window showed")
            if os.path.exists(self.socket_path) and self.control.topology().get("workspaces"):
                return
            time.sleep(0.5)  # test script: waiting for the app's socket and first window
        raise Unmeasurable("the app showed no window in 120 s")

    def end(self):
        if self.process is not None:
            self.control.action("quitEndSessions", focus=False)
            try:
                self.process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                pass
            mac_helpers()[0].end_bundle(self.bundle)  # this run's copy: every process of it is this run's
        if self.aside is not None:
            self.aside.__exit__(None, None, None)


# ---------------------------------------------------------------------------------------------------------------
# Loads.

class CpuLoad:
    def __init__(self, root):
        source = os.path.join(root, "spin.c")
        with open(source, "w") as handle:
            handle.write(SPIN_C)
        self.binary = os.path.join(root, "spin")
        subprocess.run(["cc", "-O2", "-o", self.binary, source], check=True, timeout=120)
        self.children = []

    def start(self):
        for _ in range((os.cpu_count() or 8) // 4 + 1):  # four threads each: every core
            self.children.append(subprocess.Popen([self.binary], start_new_session=True,
                                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))

    def stop(self):
        for child in self.children:
            if child.pid > 1:
                try:
                    os.killpg(child.pid, signal.SIGKILL)  # the spinner's own group (start_new_session)
                except ProcessLookupError:
                    pass
            child.wait()
        self.children = []


def new_session_argvs(help_text):
    """The acpmux argv prefixes that create a session, best first, from `acpmux --help`: `new` (feat-cmux-next since
    acpmux dropped `acp new`; the NIGHTLY of 2026-11-16 answered "unrecognized subcommand 'acp'"), then `acp new` for an
    older build. Each with --json before the subcommand (a top-level flag)."""
    commands = set(re.findall(r"^\s{2,}([a-z][a-z0-9-]*)\b", help_text or "", re.M))
    out = []
    if "new" in commands or not commands:
        out.append(["--json", "new"])
    if "acp" in commands or not commands:
        out.append(["--json", "acp", "new"])
    return out or [["--json", "new"], ["--json", "acp", "new"]]


def session_id(stdout):
    """The new session's id from a creation command's output: a JSON object's sessionId (or id / session), searched at
    any depth, else the first UUID in the text; None when there is none."""
    text = (stdout or "").strip()
    for line in [text] + text.splitlines()[::-1]:
        try:
            value = json.loads(line)
        except ValueError:
            continue
        stack = [value]
        while stack:
            node = stack.pop()
            if isinstance(node, dict):
                for key in ("sessionId", "session_id", "id", "session"):
                    if isinstance(node.get(key), str) and node[key]:
                        return node[key]
                stack.extend(node.values())
            elif isinstance(node, list):
                stack.extend(node)
    found = re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", text)
    return found.group(0) if found else None


class Agents:
    """Chats on the app's own acpmux (the test agents registered as harnesses of the app)."""

    def __init__(self, app, bundle):
        self.app, self.bundle = app, bundle
        bm, icl = mac_helpers()
        self.cli = icl.bundled_acpmux(bundle)
        for agent_id, script in (TURNS_AGENT, STREAM_AGENT):
            for _ in range(6):
                added = app.control.action("agent.harness.add", focus=False, id=agent_id, name=agent_id,
                                           command=sys.executable, args=shlex.quote(script), protocol="acp",
                                           replace="true")
                if "timeout" not in json.dumps(added):
                    break
                time.sleep(5)  # test script: the app is still starting; the add goes on, try again
        self.env = dict(os.environ, ACPMUX_SOCKET=bm.FakeChats.acpmux_socket(bundle))
        self.streaming = []
        self.new_argvs = new_session_argvs(self.help_text())

    def help_text(self):
        try:
            shown = subprocess.run([self.cli, "--help"], capture_output=True, text=True, timeout=60, env=self.env)
        except (OSError, subprocess.TimeoutExpired):
            return ""  # no help: every creation command is tried in turn
        return shown.stdout + shown.stderr

    def new(self, agent_id, text):
        """A detached session on `agent_id` with `text` as its first prompt, by whichever creation command this build's
        acpmux has (new_session_argvs), each tried in turn."""
        tried = []
        for argv in self.new_argvs:
            made = subprocess.run([self.cli, *argv, "-d", "-m", agent_id, text], capture_output=True, text=True,
                                  timeout=180, env=self.env)
            session = session_id(made.stdout)
            if made.returncode == 0 and session:
                return session
            tried.append(f"`acpmux {' '.join(argv)}`: {(made.stdout + made.stderr).strip()[-300:]}")
        raise Unmeasurable(f"new session on {agent_id}: " + " | ".join(tried))

    def long_chat(self, turns):
        started = time.monotonic()
        session = self.new(TURNS_AGENT[0], "turn: 0")
        for i in range(1, turns):
            sent = subprocess.run([self.cli, "send", session, f"turn: {i}"], capture_output=True, text=True,
                                  timeout=180, env=self.env)
            if sent.returncode != 0:
                raise Unmeasurable(f"send turn {i}: {(sent.stdout + sent.stderr).strip()[-600:]}")
        return session, round(time.monotonic() - started, 1)

    def stream_chats(self, count):
        sessions = [self.new(STREAM_AGENT[0], f"hello {i}") for i in range(count)]
        for session in sessions:
            self.app.control.action("agent.openSessionWorkspace", focus=False, session=session)
        return sessions

    def start(self, sessions, seconds, rate):
        for session in sessions:
            mac_helpers()[1].stream([self.cli], self.env, session, seconds, rate)
        self.streaming = sessions

    def stop(self):
        for session in self.streaming:
            subprocess.run([self.cli, "cancel", session], capture_output=True, timeout=30, env=self.env)
        self.streaming = []


# ---------------------------------------------------------------------------------------------------------------
# The harness.

def page_html():
    return ("<!doctype html><title>tab switch page</title><body style='margin:0;background:#2a6fdb;color:#fff;"
            "font:48px -apple-system'><p style='padding:40px'>tab switch page</p></body>")


class Harness:
    def __init__(self, args, app, recorder, root):
        self.args, self.app, self.rec, self.root = args, app, recorder, root
        self.c = app.control
        self.refs = {}
        self.index = {}
        self.chat_note = None  # why the chat scenario is unmeasured, when it is


    def select(self, name):
        return self.c.action("selectSurfaceByNumber", index=self.index[name])

    @staticmethod
    def at(frames, t):
        """The frame on screen at time t (the last one presented at or before it)."""
        shown = [f for f in frames if f[0] <= t]
        return (shown or frames[:1])[-1][1]

    @staticmethod
    def between(frames, t0, t1):
        """The frame on screen at t0, then every frame presented after t0 up to t1."""
        before = [f for f in frames if f[0] <= t0][-1:]
        return before + [f for f in frames if t0 < f[0] <= t1]

    def wait_tabs(self, count, limit=60):
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            tabs, _ = self.c.focused_tabs()
            if len(tabs) >= count:
                return tabs
            time.sleep(0.2)  # test script: waiting for the tab
        raise Unmeasurable(f"the pane never had {count} tabs")

    def build(self, chat_session):
        reply = self.c.action("workspace new")
        if reply.get("error"):
            raise Unmeasurable(f"workspace new: {reply['error']}")
        self.wait_tabs(1)
        time.sleep(1.5)  # test script: the terminal attaches
        # The chat is optional: without it the terminal and page scenarios still run, the chat's reported unmeasured.
        order = ["terminal"]
        if chat_session:
            reply = self.c.action("agent.openSessionTab", session=chat_session)
            if reply.get("error"):
                self.chat_note = f"agent.openSessionTab: {reply['error']}"
            else:
                self.wait_tabs(2)
                order.append("chat")
                time.sleep(4)  # test script: the long transcript loads
        page = os.path.join(self.root, "page.html")
        with open(page, "w") as handle:
            handle.write(page_html())
        reply = self.c.action("openBrowser.chromium", url="file://" + page)
        if reply.get("error"):
            raise Unmeasurable(f"openBrowser.chromium: {reply['error']}")
        order.append("chromium")
        tabs = self.wait_tabs(len(order))
        self.tabs_at_build = tabs
        if len(tabs) != len(order):
            raise Unmeasurable(f"the workspace's pane has {len(tabs)} tabs, want {len(order)} ({', '.join(order)}): {json.dumps(tabs)[:600]}")
        self.index = {name: i + 1 for i, name in enumerate(order)}
        time.sleep(2)  # test script: the page loads
        # Each tab's picture, from one recorded block: a flip once the tab settled marks the frame that shows it.
        self.rec.begin()
        for name in self.index:
            self.select(name)
            time.sleep(1.5)  # test script: the tab settles
            self.rec.flip(f"ref-{name}")
        time.sleep(0.3)
        frames, flips = self.rec.end()
        shown = {name: self.at(frames, flips[f"ref-{name}"]) for name in self.index}
        terminal, page_frame = shown["terminal"], shown["chromium"]
        # The content area: pane_chrome on a build with debug commands, else the pixels of two tabs.
        self.content = self.chrome_rect() or judge.content_rect(terminal, page_frame, self.rec.w, self.rec.h)
        if self.content is None:
            raise Unmeasurable("the capture shows no difference between a terminal and a Chromium page (no page pixels: "
                               "Screen Recording grant?)")
        self.strip = judge.strip_rect(self.content, self.rec.scale, self.rec.h)
        self.refs = {"terminal": terminal, "chromium": page_frame}
        if "chat" in self.index:
            chat = shown["chat"]
            cterm, cchat = (judge.crop(f, self.rec.w, self.content) for f in (terminal, chat))
            if judge.diff_share(cterm, cchat) <= self.args.tolerance:
                # Its tab stays in the pane (the indexes hold); its scenario is reported unmeasured.
                self.chat_note = "the chat tab shows the same pixels as the terminal (its page not in the capture?)"
            else:
                self.refs["chat"] = chat

    def chrome_rect(self):
        chrome = self.c.call("debug.pane_chrome", timeout=10)
        if not isinstance(chrome, dict) or chrome.get("error"):
            return None
        for window in chrome.get("windows") or []:
            for pane in window.get("panes") or []:
                border = pane.get("border")
                if isinstance(border, dict) and border.get("width"):
                    s = self.rec.scale
                    x0, y0 = int(border["x"] * s), int(border["y"] * s)
                    return (x0, y0, min(self.rec.w, int((border["x"] + border["width"]) * s)),
                            min(self.rec.h, int((border["y"] + border["height"]) * s)))
        return None

    # -- scenarios ---------------------------------------------------------------------------------------------

    def judge(self, frames, mark, reference=None, strip=None):
        return judge.judge_switch(frames, mark, self.rec.w, self.content, self.rec.frame_ms, reference=reference,
                                  strip=strip, px_per_point=self.rec.scale, tolerance=self.args.tolerance)

    def keep_sheet(self, switch, frames, mark, label, reference=None):
        if not judge.budget_fails(switch, label):
            return
        png, tiles = judge.contact_sheet(frames, mark, self.rec.w, self.rec.h, reference=reference)
        if png:
            folder = os.path.join(self.args.out, "sheets")
            os.makedirs(folder, exist_ok=True)
            path = os.path.join(folder, label.replace("/", "-").replace(" ", "-") + ".png")
            with open(path, "wb") as handle:
                handle.write(png)
            switch["sheet"] = os.path.relpath(path, self.args.out)
            switch["sheet_tiles_ms"] = tiles

    # Drive, then judge: a scenario only selects tabs and flips the marker (`<label>:leave`, `:mark`, `:end`), and returns
    # what to judge; settle_block judges every pending switch once the block's recording is decoded.

    def returning(self, shown, via, label):
        self.select(shown)
        time.sleep(self.args.settle)
        self.rec.flip(f"{label}:leave")
        self.select(via)
        time.sleep(self.args.away)
        self.rec.flip(f"{label}:mark")
        self.select(shown)
        time.sleep(self.args.record)
        self.rec.flip(f"{label}:end")
        return {"label": label, "kind": "return", "shown": shown}

    def new_and_close(self, label_new, label_close):
        self.select("terminal")
        time.sleep(self.args.settle)
        self.rec.flip(f"{label_new}:leave")
        self.rec.flip(f"{label_new}:mark")
        reply = self.c.action("newSurface")
        time.sleep(self.args.record + 0.3)
        self.rec.flip(f"{label_new}:end")
        new = {"label": label_new, "kind": "new", "error": f"newSurface: {reply['error']}" if reply.get("error") else None}
        if new["error"]:
            return new, None
        time.sleep(0.5)
        self.rec.flip(f"{label_close}:leave")
        self.rec.flip(f"{label_close}:mark")
        reply = self.c.action("closeTab")
        time.sleep(self.args.record + 0.3)
        self.rec.flip(f"{label_close}:end")
        close = {"label": label_close, "kind": "close", "error": f"closeTab: {reply['error']}" if reply.get("error") else None}
        tabs, pane = self.c.focused_tabs()
        selected = next((i + 1 for i, t in enumerate(tabs) if t.get("selected") or (pane and t.get("id") == pane.get("selected_tab"))), None)
        close["neighbor"] = {i: name for name, i in self.index.items()}.get(selected)
        if not close["error"] and len(tabs) != len(self.index):
            close["error"] = f"the pane has {len(tabs)} tabs after the close, want {len(self.index)}"
        return new, close

    def settle_block(self, pending, frames, flips):
        """Each pending switch of a block, judged on the block's frames: the window from its leave flip to its end flip,
        the switch's mark at its mark flip. A return is judged against the shown tab's frame at its leave flip (its last
        frame before it was left); a close against the neighbor's newest such frame; a new tab against its settled one."""
        judged = []
        for item in pending:
            label = item["label"]
            if item.get("error"):
                judged.append((item, {"error": item["error"]}))
                continue
            leave, mark, end = (flips[f"{label}:{k}"] for k in ("leave", "mark", "end"))
            window = self.between(frames, leave, end)
            if item["kind"] == "return":
                reference = self.at(frames, leave)
                self.refs[item["shown"]] = reference
                switch = self.judge(window, mark, reference=reference)
            elif item["kind"] == "new":
                reference = None
                switch = self.judge(window, mark, strip=self.strip)
            else:
                reference = self.refs.get(item.get("neighbor"))
                switch = self.judge(window, mark, reference=reference, strip=self.strip)
                switch["neighbor"] = item.get("neighbor")
            self.keep_sheet(switch, window, mark, label, reference)
            judged.append((item, switch))
        return judged

    def run(self, loads, rounds, scenarios, agents, sessions, load_notes=None):
        """The scenario rows. A load in `load_notes` (its setup failed) and the chat scenario without a measurable chat
        are rows with no switch and the reason, so the rest still measures."""
        rows, notes = {}, {}
        load_notes = load_notes or {}
        if "chat-long-return" in scenarios and "chat" not in self.refs:
            scenarios = [s for s in scenarios if s != "chat-long-return"]
            for load in loads:
                notes[("chat-long-return", load)] = self.chat_note or "no chat"
        for load in [x for x in loads if x in load_notes]:
            for name in scenarios:
                notes[(name, load)] = load_notes[load]
        for load in [x for x in loads if x not in load_notes]:
            say(f"load {load}")
            if load == "cpu":
                agents_cpu = CpuLoad(self.root)
                agents_cpu.start()
            elif load == "agents":
                agents.start(sessions, seconds=rounds * 40 + 120, rate=self.args.stream_rate)
            time.sleep(self.args.load_settle if load != "idle" else 0)
            pending = []  # (scenario name, what to judge), in the order driven
            try:
                self.rec.begin()
                for r in range(1, rounds + 1):
                    for name, (shown, via) in (("chat-long-return", ("chat", "terminal")),
                                               ("terminal-return", ("terminal", "chromium")),
                                               ("chromium-return", ("chromium", "terminal"))):
                        if name in scenarios:
                            pending.append((name, self.returning(shown, via, f"{name}/{load} round {r}")))
                    if "new-tab" in scenarios or "close-tab" in scenarios:
                        new, close = self.new_and_close(f"new-tab/{load} round {r}", f"close-tab/{load} round {r}")
                        pending.append(("new-tab", new))
                        if close is not None:
                            pending.append(("close-tab", close))
                    say(f"  round {r} driven")
            finally:
                if load == "cpu":
                    agents_cpu.stop()
                elif load == "agents":
                    agents.stop()
            try:
                frames, flips = self.rec.end()
            except Exception as error:  # noqa: BLE001 - this load's rows say why; the next load still records
                for name, _item in pending:
                    notes.setdefault((name, load), f"recording: {type(error).__name__}: {error}"[:600])
                continue
            for (name, _), (_item, switch) in zip(pending, self.settle_block([p for _, p in pending], frames, flips)):
                if name in scenarios:
                    rows.setdefault((name, load), []).append(switch)
            say(f"load {load}: {len(pending)} switches judged on {len(frames)} frames")
        out = [judge.scenario_row(name, load, switches) for (name, load), switches in rows.items()]
        return out + [judge.scenario_row(name, load, [], notes=note) for (name, load), note in notes.items()]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", help="an app bundle to launch (a copy of it is not made)")
    parser.add_argument("--dmg", help="a DMG whose app is copied out and launched (a NIGHTLY)")
    parser.add_argument("--build", default="unknown", help="the report's build: a version or a commit")
    parser.add_argument("--tools", required=True, help="the compiled scripts/measure/tab-switch-frames/tools.swift")
    parser.add_argument("--tolerance", type=float, default=0.01,
                        help="share of the content area that may differ for two decoded video frames to be one picture")
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--loads", default="idle,cpu,agents")
    parser.add_argument("--scenarios", default=",".join(judge.SCENARIOS))
    parser.add_argument("--chat-turns", type=int, default=200)
    parser.add_argument("--agents", type=int, default=4)
    parser.add_argument("--stream-rate", type=float, default=30)
    parser.add_argument("--width", type=int, default=480, help="recorded frame width in pixels")
    parser.add_argument("--settle", type=float, default=1.0)
    parser.add_argument("--away", type=float, default=0.8)
    parser.add_argument("--record", type=float, default=1.2)
    parser.add_argument("--load-settle", type=float, default=5.0)
    parser.add_argument("--out", default=os.path.join(os.getcwd(), ".build/tab-switch"))
    parser.add_argument("--no-gate", action="store_true", help="exit 0 when the report is written, budgets or not")
    args = parser.parse_args(argv)
    # Decoded h264 frames of one picture differ in the low bits: 16 gray levels, not 32, so noise is not a change.
    judge.QUANT = bytes(v >> 4 for v in range(256))
    loads = [x for x in args.loads.split(",") if x]
    scenarios = [x for x in args.scenarios.split(",") if x]
    bad = [x for x in loads if x not in judge.LOADS] + [x for x in scenarios if x not in judge.SCENARIOS]
    if bad or not (args.app or args.dmg):
        parser.error(f"unknown load or scenario {bad}" if bad else "--app or --dmg")
    os.makedirs(args.out, exist_ok=True)
    smoke = load_smoke()
    root = tempfile.mkdtemp(prefix="tab-switch-")
    extra = {"host": {"chip": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip(),
                      "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip(),
                      "cores": os.cpu_count()},
             "rounds": args.rounds, "chat_turns": args.chat_turns, "agents": args.agents}
    app = recorder = None
    status, rows, hz = 3, [], None
    try:
        from pathlib import Path
        bundle = str(smoke.copy_app_from_dmg(Path(args.dmg), Path(root))) if args.dmg else os.path.realpath(args.app)
        extra["bundle_version"] = subprocess.run(["defaults", "read", os.path.join(bundle, "Contents/Info"), "CFBundleVersion"],
                                                 capture_output=True, text=True).stdout.strip()
        app = App(bundle, root, smoke)
        app.launch()
        # The chat and the agents load are optional: a setup fault in either leaves the terminal and page scenarios,
        # idle and under CPU load, measured, and names the fault on the rows it cost.
        agents, session, sessions, setup = None, None, [], {}
        try:
            agents = Agents(app, bundle)
            session, seed_s = agents.long_chat(args.chat_turns)
            say(f"long chat {session}: {args.chat_turns} turns in {seed_s} s")
            extra["seed_s"] = seed_s
        except Exception as error:  # noqa: BLE001 - reported on the chat's rows
            setup["chat"] = f"chat setup: {type(error).__name__}: {error}"[:600]
            say(setup["chat"])
        load_notes = {}
        if "agents" in loads:
            try:
                if agents is None:
                    raise Unmeasurable("no agent harness")
                sessions = agents.stream_chats(args.agents)
            except Exception as error:  # noqa: BLE001 - reported on the agents load's rows
                load_notes["agents"] = f"agents setup: {type(error).__name__}: {error}"[:600]
                say(load_notes["agents"])
        extra["setup_errors"] = {**setup, **load_notes}
        recorder = capture.Capture(args.tools, app.process.pid, args.width, os.path.join(root, "capture"))
        hz = recorder.hz
        extra["capture"] = {"window": recorder.window, "display": recorder.display, "display_hz": recorder.hz,
                            "permissions": recorder.permissions, "recorder": "CuaDriver"}
        say(f"capture {json.dumps(extra['capture'])}")
        harness = Harness(args, app, recorder, root)
        harness.chat_note = setup.get("chat")
        harness.build(session)
        extra["content_rect_px"], extra["strip_rect_px"] = harness.content, harness.strip
        extra["tabs_at_build"] = harness.tabs_at_build
        rows = harness.run(loads, args.rounds, scenarios, agents, sessions, load_notes)
        status = 0
    except Unmeasurable as error:
        say(f"cannot measure: {error}")
        extra["error"] = str(error)
    except Exception as error:  # noqa: BLE001 - any harness fault still writes the report, as a run that could not measure
        import traceback
        traceback.print_exc()
        extra["error"] = f"{type(error).__name__}: {error}"
    finally:
        if recorder is not None:
            recorder.close()
        if app is not None:
            app.end()
        shutil.rmtree(root, ignore_errors=True)
    out = judge.report(args.build, hz, rows, extra)
    if status == 3:
        out["pass"] = False
    with open(os.path.join(args.out, "report.json"), "w") as handle:
        json.dump(out, handle, indent=1)
    for row in rows:
        print("TSW", json.dumps(judge.summary(row)), flush=True)
        for fail in row["budget_fail"][:6]:
            print("TSW-FAIL", fail, flush=True)
    say(f"pass={out['pass']} report {os.path.join(args.out, 'report.json')}")
    if status == 3:
        return 3
    return 0 if out["pass"] or args.no_gate else 1


if __name__ == "__main__":
    sys.exit(main())
