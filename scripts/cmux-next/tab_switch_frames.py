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
With --scenarios all, also (Leo, 2026-11-16: "opening closing tabs and workspaces idk why we didn't measure settled
states before but like / testing it under actual extreme load is the point and seeing what oddities arise is
meaningful"):
  webkit-return      a WebKit page shown, switch to the terminal and back
  new-workspace      `workspace new` from the measured workspace: the settled frame, the sidebar's insert and end
  switch-workspace   back to the measured workspace (against its last frame), then to the new one again
  close-workspace    close the new workspace: against the measured workspace's last frame when it is the one shown
  rapid-open-5       five new tabs as fast as the socket takes them (animations retarget mid-flight)
  rapid-close-3      three of them closed as fast
  open-while-close   a close, then a new tab while the close still animates
Loads (--loads; parse_load, LOAD_PRESETS): idle and cpu and agents as before, and the instant-at-any-load modes:
  L0 idle; L1 the focused chat streams 60 chunks/s and a 2,000 lines/s tool output; L2 10 other chats streaming at
  30 chunks/s (3 as tabs of a pane split beside the measured one, the rest in background workspaces); L3 the focused
  chat is a 100k-row chat, streaming; L4 every core pinned; L5 all of them plus STRESS (perf-stress-session.py: 60
  workspaces, 20 printing terminals). Also cpu-max, agents-N, chat-100k, tabs-N, joined with + to combine.
Per switch (tab_switch_judge.py): to_content_ms, blank_frames, wrong_frames, shift_px, insert_ok, anim_end_ok; and
(tab_switch_settle.py) first_change_ms, settled_ms (the window still for 300 ms), changed_after_first and the
oddity log (placement, retarget, flicker, blank, layout-after-content, shift, late-change, never-settled), each oddity
with its frame and a contact-sheet crop, printed as TSW-ODD lines; the summary table as TSW-TABLE lines and table.md.
Budgets: content within one display frame, 0 blank, 0 wrong, 0 px shift, insert and animation end right. Settled
time and oddities are reported, never gated.

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
import pwd
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
import tab_switch_foreign as foreign  # noqa: E402
import tab_switch_judge as judge  # noqa: E402
import tab_switch_matrix as matrix  # noqa: E402
import tab_switch_settle as settle  # noqa: E402


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

    def action(self, action_id, /, focus=True, target=None, **args):
        """`action.run` of `action_id` with `args` (positional-only, so an action's own `name` or `action` argument
        is one of its args, as agent.harness.add's `name`), aimed at `target` ("tab:ID", "pane:ID", "workspace:ID")
        when given. A destructive action the app refuses with confirmation_required runs once more with confirm."""
        params = {"action": action_id, "args": args, "wait": True, "origin": "script",
                  "idempotency_key": f"mutation_{uuid.uuid4().hex}"}
        if focus:
            params["focus"] = True
        if target:
            params["target"] = target
        reply = self.call("action.run", params, timeout=60)
        if not isinstance(reply, dict):
            reply = {"result": reply}
        if "confirmation_required" in json.dumps(reply.get("error") or "") and not args.get("confirm"):
            params = dict(params, args=dict(args, confirm=True), idempotency_key=f"mutation_{uuid.uuid4().hex}")
            reply = self.call("action.run", params, timeout=60)
        return reply

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


RUN_SETTINGS = {"notifications": {"desktop": "never"}, "diagnostics": {"hangReports": False}}


def write_run_settings(home):
    """The run's own cmux-next.json in its private HOME: no macOS notification banners (a banner is another process's
    window over the app) and no hang-report invitation. Written before the first launch, so nothing is merged."""
    path = home / ".config" / "cmux" / "cmux-next.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(RUN_SETTINGS, indent=2) + "\n")
    return path


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
        # The one-time "Help Make cmux Faster?" card (sidebar notice, over the app's pixels) is answered for this run's
        # defaults: the same key the card sets when asked. This run's own domain only; the product default is unchanged.
        for key in ("home.firstRun.historyImportShown", "cmux.next.hangReports.asked"):
            subprocess.run(["defaults", "write", self.bundle_id, key, "-bool", "YES"], capture_output=True, timeout=30)
        self.spawn()

    def spawn(self, before=None):
        """The app's process in this run's home, waited for until its socket lists a workspace. `before`, when given,
        runs just before the exec (the settle matrix's relaunch flips its marker there)."""
        from pathlib import Path
        self.socket_path = os.path.join(self.root, "c.sock")
        env = self.smoke.fresh_env(Path(self.root), Path(self.socket_path), 2)
        write_run_settings(Path(env["HOME"]))
        self.smoke.login_keychain(env)  # a person's home has one: no Safe Storage Keychain dialog (cmuxterm-hq#11994)
        env.pop("CMUX_NEXT_LAUNCH_MARKS_FD", None)
        env.pop("CMUX_NEXT_NO_ACTIVATE", None)  # the window is in front on the worker's display: the capture reads it
        env.update({"CMUX_NEXT_SKIP_ONBOARDING": "1", "CMUX_NEXT_TEST_WINDOW_FRAME": WINDOW_FRAME,
                    "CMUX_NEXT_DOWNLOADS_DIR": os.path.join(self.root, "downloads")})
        os.makedirs(env["CMUX_NEXT_DOWNLOADS_DIR"], exist_ok=True)
        binary = os.path.join(self.bundle, "Contents/MacOS", self.executable)
        self.log = open(os.path.join(self.root, "app.log"), "a")
        if before is not None:
            before()
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


# The load modes fable-instant-at-any-load set for every "instant at any load" bench (the typing-under-load bench uses
# the same names), and the older names. Each is a spec of parts; parse_load joins names with "+".
#   live        the focused chat streams (chunks a second, tool-output lines a second)
#   bg_chats    other chats streaming at bg_rate (True: --agents of them at --stream-rate), `split` of them as tabs of a
#               pane split right of the measured one (one shown, the rest hidden), the rest in background workspaces
#   chat100k    the focused chat is a 100k-row chat (chat-100k-flat.bench.ts's size, seeded through acpmux)
#   cpu         every core pinned by busy processes outside the app
#   tabs        the measured pane holds this many tabs
#   stress      the STRESS background (perf-stress-session.py): 60 workspaces, 20 printing terminals
LOAD_PRESETS = {
    "L0": {}, "idle": {},
    "L1": {"live": (60, 2000)},
    "L2": {"bg_chats": 10, "bg_rate": 30, "split": 3},
    "L3": {"chat100k": True, "live": (60, 0)},
    "L4": {"cpu": True}, "cpu": {"cpu": True}, "cpu-max": {"cpu": True},
    "L5": {"live": (60, 2000), "bg_chats": 10, "bg_rate": 30, "split": 3, "chat100k": True, "cpu": True,
           "stress": True},
    "agents": {"bg_chats": True}, "chat-100k": {"chat100k": True},
}


def parse_load(name):
    """The spec of a load name: a preset, agents-N, tabs-N, or several joined with "+" (L4+tabs-40). Raises
    ValueError on an unknown name."""
    spec = {}
    for part in name.split("+"):
        if part in LOAD_PRESETS:
            add = dict(LOAD_PRESETS[part])
        elif re.fullmatch(r"agents-([1-9][0-9]?)", part):
            add = {"bg_chats": int(part[7:])}
        elif re.fullmatch(r"tabs-([1-9][0-9]{0,2})", part):
            add = {"tabs": int(part[5:])}
        else:
            raise ValueError(f"unknown load {part!r} (L0..L5, idle, cpu, cpu-max, agents, agents-N, chat-100k, tabs-N)")
        for key, value in add.items():
            if key == "live" and "live" in spec:
                spec["live"] = tuple(max(a, b) for a, b in zip(spec["live"], value))
            elif key in ("bg_chats", "tabs", "split", "bg_rate") and key in spec and spec[key] is not True and value is not True:
                spec[key] = max(spec[key], value)
            else:
                spec[key] = value
    return spec


def order_loads(loads):
    """`loads` in the order asked, those that build STRESS last (it is never taken down)."""
    return [x for x in loads if not parse_load(x).get("stress")] + [x for x in loads if parse_load(x).get("stress")]


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
        self.ensure_background(count)
        return self.background[:count]

    def make_stream_sessions(self, count):
        return [self.new(STREAM_AGENT[0], f"hello {i}") for i in range(count)]

    def ensure_background(self, count):
        """At least `count` stream chats, each open in a background workspace."""
        self.background = getattr(self, "background", [])
        for session in self.make_stream_sessions(max(0, count - len(self.background))):
            self.app.control.action("agent.openSessionWorkspace", focus=False, session=session)
            self.background.append(session)

    def hundred_k_chat(self, rows):
        """A chat of `rows` transcript rows (chat_open_agent.py `rows:`, 10,000 a turn), made once."""
        if getattr(self, "big", None):
            return self.big
        started = time.monotonic()
        per = 10000
        session = self.new(TURNS_AGENT[0], f"rows: {min(per, rows)}")
        for _ in range(max(0, (rows - 1) // per)):
            sent = subprocess.run([self.cli, "send", session, f"rows: {per}"], capture_output=True, text=True,
                                  timeout=600, env=self.env)
            if sent.returncode != 0:
                raise Unmeasurable(f"send rows: {(sent.stdout + sent.stderr).strip()[-600:]}")
        say(f"100k-row chat {session}: {rows} rows in {round(time.monotonic() - started, 1)} s")
        self.big = session
        return session

    def start(self, sessions, seconds, rate):
        for session in sessions:
            mac_helpers()[1].stream([self.cli], self.env, session, seconds, rate)
        self.streaming = list(getattr(self, "streaming", [])) + list(sessions)

    def live(self, session, seconds, chunks, lines):
        """The focused chat streaming (chat_open_agent.py `live:`), without waiting for it."""
        sent = subprocess.run([self.cli, "send", "--no-wait", session, f"live: {int(seconds)} {chunks} {lines}"],
                              capture_output=True, text=True, timeout=60, env=self.env)
        if sent.returncode != 0:
            say(f"live {session}: {(sent.stdout + sent.stderr).strip()[:400]}")
        self.streaming = list(getattr(self, "streaming", [])) + [session]

    def stop(self):
        for session in getattr(self, "streaming", []):
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
        self.ids = {}  # tab name -> its tab id (tab.focus by id: a pane with more than nine tabs, the tabs-N load)
        self.chat_note = None  # why the chat scenario is unmeasured, when it is
        self.sidebar = None
        self.watch = None  # the foreign-window watch (tab_switch_foreign.Watch), once the capture is up
        self.workspace_id = self.pane_id = None
        self.load_tabs = []  # tabs a load added to the measured pane (closed when the load ends)
        self.split_pane = None

    def opt(self, name, default):
        return getattr(self.args, name, default)

    def select(self, name):
        tab = self.ids.get(name)
        if tab:
            reply = self.c.action("tab.focus", target=f"tab:{tab}")
            if not reply.get("error"):
                return reply
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
            tabs, _ = self.pane_tabs()
            if len(tabs) >= count and not any(str(t.get("id", "")).startswith("pending_tab_") for t in tabs):
                return tabs
            time.sleep(0.2)  # test script: waiting for the tab
        raise Unmeasurable(f"the pane never had {count} tabs")

    def pane_tabs(self):
        """The measured pane's tabs and the pane (the focused pane's until the pane is known)."""
        if not self.pane_id:
            return self.c.focused_tabs()
        for workspace in self.c.topology().get("workspaces") or []:
            for screen in workspace.get("screens") or []:
                for pane in screen.get("panes") or []:
                    if pane.get("id") == self.pane_id:
                        return pane.get("tabs") or [], pane
        return [], None

    def workspace_ids(self):
        return [w.get("id") for w in self.c.topology().get("workspaces") or [] if w.get("id")]

    def focused_workspace(self):
        topology = self.c.topology()
        focus = topology.get("focus") or {}
        if focus.get("workspace"):
            return focus["workspace"]
        pane_id = focus.get("pane")
        for workspace in topology.get("workspaces") or []:
            for screen in workspace.get("screens") or []:
                if any(p.get("id") == pane_id for p in screen.get("panes") or []):
                    return workspace.get("id")
        return None

    def build(self, chat_session):
        before = set(self.workspace_ids())
        reply = self.c.action("workspace new")
        if reply.get("error"):
            raise Unmeasurable(f"workspace new: {reply['error']}")
        self.wait_tabs(1)
        time.sleep(1.5)  # test script: the terminal attaches
        made = [w for w in self.workspace_ids() if w not in before]
        self.workspace_id = made[0] if made else self.focused_workspace()
        _tabs, pane = self.c.focused_tabs()
        self.pane_id = (pane or {}).get("id")
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
        self.wait_tabs(len(order))
        if self.opt("webkit", False):
            reply = self.c.action("openBrowser.webkit", url="file://" + page)
            if not reply.get("error"):
                order.append("webkit")
                self.wait_tabs(len(order))
            else:
                self.webkit_note = f"openBrowser.webkit: {reply['error']}"
        tabs = self.wait_tabs(len(order))
        self.tabs_at_build = tabs
        if len(tabs) != len(order):
            raise Unmeasurable(f"the workspace's pane has {len(tabs)} tabs, want {len(order)} ({', '.join(order)}): {json.dumps(tabs)[:600]}")
        self.index = {name: i + 1 for i, name in enumerate(order)}
        self.ids = {name: tabs[i].get("id") for i, name in enumerate(order)}
        time.sleep(2)  # test script: the page loads
        self.calibrate()

    def calibrate(self):
        """Each tab's picture, from one recorded block (a flip once the tab settled marks the frame that shows it), and
        from them the content, strip and sidebar rects. Again after a load changes the measured pane's size."""
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
        self.sidebar = judge.sidebar_rect(self.content, self.rec.scale, self.rec.h)
        self.refs = {"terminal": terminal, "chromium": page_frame}
        if "webkit" in shown:
            self.refs["webkit"] = shown["webkit"]
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
                if self.pane_id and pane.get("id") not in (None, self.pane_id):
                    continue
                border = pane.get("border")
                if isinstance(border, dict) and border.get("width"):
                    s = self.rec.scale
                    x0, y0 = int(border["x"] * s), int(border["y"] * s)
                    return (x0, y0, min(self.rec.w, int((border["x"] + border["width"]) * s)),
                            min(self.rec.h, int((border["y"] + border["height"]) * s)))
        return None

    # -- loads -------------------------------------------------------------------------------------------------

    def enter_load(self, spec, agents, cpu):
        """Starts what `spec` (parse_load) asks; returns notes on the parts that could not start (the rest runs)."""
        notes = []
        seconds = self.load_seconds
        if spec.get("stress") and not getattr(self, "stress_built", False):
            try:
                self.stress_built = True
                build_stress(self.c, self.workspace_id, self.opt("stress_workspaces", 60),
                             self.opt("stress_terminals", 20))
            except Exception as error:  # noqa: BLE001 - the load runs with what was built
                notes.append(f"stress: {type(error).__name__}: {error}"[:300])
            self.c.action("goToWorkspace", workspace=self.workspace_id)
            time.sleep(2)  # test script: the measured workspace shows again
        if spec.get("chat100k"):
            try:
                session = agents.hundred_k_chat(self.opt("chat_rows", 100000))
                reply = self.c.action("agent.openSessionTab", session=session, target=f"pane:{self.pane_id}")
                if reply.get("error"):
                    raise Unmeasurable(f"agent.openSessionTab: {reply['error']}")
                tabs = self.wait_tabs(len(self.index) + len(self.load_tabs) + 1)
                known = set(self.ids.values()) | set(self.load_tabs)
                new = [t.get("id") for t in tabs if t.get("id") not in known]
                if not new:
                    raise Unmeasurable("the 100k-row chat's tab never showed in the measured pane")
                self.load_tabs.append(new[0])
                self.saved_chat = (self.ids.get("chat"), self.refs.get("chat"))
                self.ids["chat"] = new[0]
                self.index.setdefault("chat", len(self.index) + 1)
                self.chat_session = session
                self.select("chat")
                time.sleep(6)  # test script: the 100k-row transcript opens
                self.rec.begin()
                self.rec.flip("ref-chat100k")
                time.sleep(0.3)
                frames, flips = self.rec.end()
                self.refs["chat"] = self.at(frames, flips["ref-chat100k"])
            except Exception as error:  # noqa: BLE001
                notes.append(f"chat-100k: {type(error).__name__}: {error}"[:300])
        if spec.get("live"):
            chunks, lines = spec["live"]
            session = getattr(self, "chat_session", None) or getattr(self, "long_session", None)
            if session and agents:
                agents.live(session, seconds, chunks, lines)
            else:
                notes.append("live: no focused chat to stream")
        if spec.get("bg_chats"):
            count = spec["bg_chats"] if spec["bg_chats"] is not True else self.opt("agents", 4)
            try:
                split = spec.get("split", 0)
                if split:
                    self.open_split_chats(agents, split)
                agents.ensure_background(count - split if split else count)
                agents.start(agents.background[:count - (split or 0)] + (self.split_sessions if split else []),
                             seconds=seconds, rate=spec.get("bg_rate") or self.opt("stream_rate", 30))
            except Exception as error:  # noqa: BLE001
                notes.append(f"background chats: {type(error).__name__}: {error}"[:300])
        if spec.get("tabs"):
            try:
                self.fill_tabs(spec["tabs"])
            except Exception as error:  # noqa: BLE001
                notes.append(f"tabs: {type(error).__name__}: {error}"[:300])
        if spec.get("cpu"):
            cpu.start()
        self.select("terminal")
        time.sleep(self.opt("load_settle", 5.0))
        return notes

    def exit_load(self, spec, agents, cpu):
        if spec.get("cpu"):
            cpu.stop()
        if agents is not None:
            agents.stop()
        for tab in reversed(self.load_tabs):
            self.c.action("closeTab", focus=False, target=f"tab:{tab}")
        self.load_tabs = []
        if getattr(self, "saved_chat", None):
            chat_id, chat_ref = self.saved_chat
            if chat_id:
                self.ids["chat"] = chat_id
                if chat_ref is not None:
                    self.refs["chat"] = chat_ref
            else:
                self.ids.pop("chat", None)
                self.index.pop("chat", None)
                self.refs.pop("chat", None)
            self.saved_chat = None
            self.chat_session = None
        if self.split_pane:
            for tab in getattr(self, "split_tabs", []):
                self.c.action("closeTab", focus=False, target=f"tab:{tab}")
            self.split_pane, self.split_tabs = None, []
            time.sleep(1)  # test script: the pane closes
            self.select("terminal")
            self.calibrate()
        time.sleep(1)  # test script: the load's tabs close

    def open_split_chats(self, agents, count):
        """`count` streaming chats as tabs of a new pane right of the measured one (one shown, the rest hidden tabs);
        the content rect is measured again."""
        sessions = agents.make_stream_sessions(count)
        before = {p for p in self.all_panes()}
        reply = self.c.action("splitRight", target=f"pane:{self.pane_id}")
        if reply.get("error"):
            raise Unmeasurable(f"splitRight: {reply['error']}")
        deadline = time.monotonic() + 15
        made = None
        while time.monotonic() < deadline and not made:
            made = next((p for p in self.all_panes() if p not in before), None)
            time.sleep(0.2)  # test script: waiting for the pane
        if not made:
            raise Unmeasurable("splitRight made no pane")
        self.split_pane, self.split_tabs, self.split_sessions = made, [], sessions
        for session in sessions:
            self.c.action("agent.openSessionTab", focus=False, session=session, target=f"pane:{made}")
        time.sleep(2)  # test script: the chats open
        for workspace in self.c.topology().get("workspaces") or []:
            for screen in workspace.get("screens") or []:
                for pane in screen.get("panes") or []:
                    if pane.get("id") == made:
                        self.split_tabs = [t.get("id") for t in pane.get("tabs") or [] if t.get("id")]
        self.select("terminal")
        self.calibrate()

    def all_panes(self):
        return [p.get("id") for w in self.c.topology().get("workspaces") or [] for s in w.get("screens") or []
                for p in s.get("panes") or []]

    def fill_tabs(self, count):
        """Terminal tabs added to the measured pane until it has `count` (closed when the load ends)."""
        tabs, _ = self.pane_tabs()
        anchor = self.ids.get("chromium")
        for _ in range(max(0, count - len(tabs))):
            known = {t.get("id") for t in tabs}
            self.c.action("newSurface", focus=False, target=f"tab:{anchor}")
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                tabs, _ = self.pane_tabs()
                new = [t.get("id") for t in tabs if t.get("id") not in known and not str(t.get("id")).startswith("pending_tab_")]
                if new:
                    self.load_tabs.append(new[0])
                    break
                time.sleep(0.1)  # test script: waiting for the tab
        self.select("terminal")

    # -- scenarios ---------------------------------------------------------------------------------------------

    def judge(self, frames, mark, reference=None, strip=None):
        return judge.judge_switch(frames, mark, self.rec.w, self.content, self.rec.frame_ms, reference=reference,
                                  strip=strip, px_per_point=self.rec.scale, tolerance=self.args.tolerance)

    def write_png(self, png, label):
        folder = os.path.join(self.args.out, "sheets")
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, re.sub(r"[^A-Za-z0-9._-]+", "-", label) + ".png")
        with open(path, "wb") as handle:
            handle.write(png)
        return os.path.relpath(path, self.args.out)

    def keep_sheet(self, switch, frames, mark, label, reference=None):
        if not judge.budget_fails(switch, label):
            return
        png, tiles = judge.contact_sheet(frames, mark, self.rec.w, self.rec.h, reference=reference)
        if png:
            switch["sheet"] = self.write_png(png, label)
            switch["sheet_tiles_ms"] = tiles

    # Drive, then judge: a scenario only selects tabs and flips the marker (`<label>:leave`, `:mark`, `:end`), and returns
    # what to judge; settle_block judges every pending switch once the block's recording is decoded.

    def flip3(self, label):
        """The leave and mark flips of an action that starts at once (no switch away first)."""
        self.rec.flip(f"{label}:leave")
        self.rec.flip(f"{label}:mark")

    def new_tabs(self, before, want, limit=5.0):
        """The measured pane's tabs not in `before`, once `want` of them have daemon ids (a provisional
        `pending_tab_` id names no tab), or as they are after `limit` seconds."""
        deadline = time.monotonic() + limit
        while True:
            made = [t.get("id") for t in self.pane_tabs()[0] if t.get("id") not in before]
            if (len(made) >= want and not any(str(m).startswith("pending_tab_") for m in made)) or time.monotonic() > deadline:
                return [m for m in made if not str(m).startswith("pending_tab_")]
            time.sleep(0.1)  # test script: waiting for the daemon's tab ids

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
        tabs0 = {t.get("id") for t in self.pane_tabs()[0]}
        self.flip3(label_new)
        reply = self.c.action("newSurface")
        time.sleep(self.args.record + 0.3)
        self.rec.flip(f"{label_new}:end")
        new = {"label": label_new, "kind": "new", "error": f"newSurface: {reply['error']}" if reply.get("error") else None}
        if new["error"]:
            return new, None
        made = self.new_tabs(tabs0, 1)
        time.sleep(0.5)
        self.flip3(label_close)
        reply = self.c.action("closeTab", target=f"tab:{made[0]}") if made else self.c.action("closeTab")
        time.sleep(self.args.record + 0.3)
        self.rec.flip(f"{label_close}:end")
        close = {"label": label_close, "kind": "close", "error": f"closeTab: {reply['error']}" if reply.get("error") else None}
        tabs, pane = self.pane_tabs()
        selected = next((t.get("id") for t in tabs if t.get("selected") or (pane and t.get("id") == pane.get("selected_tab"))), None)
        close["neighbor"] = {i: name for name, i in self.ids.items()}.get(selected)
        if not close["error"] and len(tabs) != len(tabs0):
            close["error"] = f"the pane has {len(tabs)} tabs after the close, want {len(tabs0)}"
        return new, close

    def workspace_round(self, load, r):
        """new-workspace, switch-workspace (back, then to it again) and close-workspace; the items to judge, by name."""
        out = []
        self.select("terminal")
        time.sleep(self.args.settle)
        before = set(self.workspace_ids())
        ws0 = self.workspace_id
        label = f"new-workspace/{load} round {r}"
        self.flip3(label)
        reply = self.c.action("workspace new")
        time.sleep(self.args.record + 0.3)
        self.rec.flip(f"{label}:end")
        new_ws = next((w for w in self.workspace_ids() if w not in before), None)
        error = f"workspace new: {reply['error']}" if reply.get("error") else (None if new_ws else "no new workspace")
        out.append(("new-workspace", {"label": label, "kind": "settled", "strip": "sidebar", "error": error}))
        if not new_ws:
            self.c.action("goToWorkspace", workspace=ws0)
            return out
        new_label = label
        time.sleep(0.3)
        back = f"switch-workspace/{load} round {r} back"
        self.flip3(back)
        reply = self.c.action("goToWorkspace", workspace=ws0)
        time.sleep(self.args.record)
        self.rec.flip(f"{back}:end")
        out.append(("switch-workspace", {"label": back, "kind": "at", "ref_flip": f"{new_label}:leave", "strip": "sidebar",
                                         "error": f"goToWorkspace: {reply['error']}" if reply.get("error") else None}))
        time.sleep(0.3)
        there = f"switch-workspace/{load} round {r} there"
        self.flip3(there)
        reply = self.c.action("goToWorkspace", workspace=new_ws)
        time.sleep(self.args.record)
        self.rec.flip(f"{there}:end")
        out.append(("switch-workspace", {"label": there, "kind": "at", "ref_flip": f"{back}:leave", "strip": "sidebar",
                                         "error": f"goToWorkspace: {reply['error']}" if reply.get("error") else None}))
        time.sleep(0.3)
        close = f"close-workspace/{load} round {r}"
        self.flip3(close)
        reply = self.c.action("closeWorkspace", confirm=True, target=f"workspace:{new_ws}")
        time.sleep(self.args.record + 0.3)
        self.rec.flip(f"{close}:end")
        shown = self.focused_workspace()
        item = {"label": close, "kind": "at" if shown == ws0 else "settled", "ref_flip": f"{there}:leave",
                "strip": "sidebar", "error": f"closeWorkspace: {reply['error']}" if reply.get("error") else None,
                "neighbor": "measured" if shown == ws0 else shown}
        if new_ws in self.workspace_ids() and not item["error"]:
            item["error"] = "the workspace is still there after closeWorkspace"
        out.append(("close-workspace", item))
        if shown != ws0:
            self.c.action("goToWorkspace", workspace=ws0)
            time.sleep(0.5)
        return out

    def rapid_round(self, load, r):
        """rapid-open-5, rapid-close-3 and open-while-close in the measured pane; restores its tabs after."""
        out = []
        self.select("terminal")
        time.sleep(self.args.settle)
        tabs0 = [t.get("id") for t in self.pane_tabs()[0]]
        label = f"rapid-open-5/{load} round {r}"
        self.flip3(label)
        errors = [self.c.action("newSurface").get("error") for _ in range(5)]
        time.sleep(self.args.record + 0.5)
        self.rec.flip(f"{label}:end")
        made = self.new_tabs(tabs0, 5)
        error = next((f"newSurface: {e}" for e in errors if e), None) or (
            None if len(made) == 5 else f"{len(made)} new tabs, want 5")
        out.append(("rapid-open-5", {"label": label, "kind": "settled", "strip": "tab", "error": error}))
        if len(made) >= 4:
            time.sleep(0.3)
            label = f"rapid-close-3/{load} round {r}"
            self.flip3(label)
            closing = made[-3:][::-1]
            errors = [self.c.action("closeTab", target=f"tab:{tab}").get("error") for tab in closing]
            time.sleep(self.args.record + 0.5)
            self.rec.flip(f"{label}:end")
            out.append(("rapid-close-3", {"label": label, "kind": "settled", "strip": "tab",
                                          "error": next((f"closeTab: {e}" for e in errors if e), None)}))
            left = [t for t in made if t not in closing]
            time.sleep(0.3)
            label = f"open-while-close/{load} round {r}"
            self.flip3(label)
            e1 = self.c.action("closeTab", target=f"tab:{left[-1]}").get("error")
            e2 = self.c.action("newSurface").get("error")
            time.sleep(self.args.record + 0.5)
            self.rec.flip(f"{label}:end")
            out.append(("open-while-close", {"label": label, "kind": "settled", "strip": "tab",
                                             "error": (f"closeTab: {e1}" if e1 else None) or (f"newSurface: {e2}" if e2 else None)}))
        for tab in [t.get("id") for t in self.pane_tabs()[0] if t.get("id") not in tabs0]:
            self.c.action("closeTab", focus=False, target=f"tab:{tab}")
        time.sleep(0.8)  # test script: the extra tabs close
        return out

    def foreign_over(self, label):
        """The foreign windows that were over the content or sidebar rect at any time from the ambient span before the
        round's leave flip to just after its end flip ([] when no watch runs or the round has no wall times)."""
        walls = getattr(self.rec, "walls", None) or {}
        if getattr(self, "watch", None) is None or f"{label}:leave" not in walls or f"{label}:end" not in walls:
            return []
        t0 = walls[f"{label}:leave"] - settle.AMBIENT_S - 0.05
        t1 = walls[f"{label}:end"] + 0.2
        return self.watch.log.between(t0, t1, [self.content, self.sidebar])

    def settle_block(self, pending, frames, flips):
        """Each pending switch of a block, judged on the block's frames: the window from its leave flip to its end flip,
        the switch's mark at its mark flip. A return is judged against the shown tab's frame at its leave flip (its last
        frame before it was left); a close against the neighbor's newest such frame; a new tab against its settled one;
        "at" items against the frame at their ref_flip. Then its settled time and oddities (tab_switch_settle.py)."""
        judged = []
        for item in pending:
            label = item["label"]
            if item.get("error"):
                judged.append((item, {"error": item["error"]}))
                continue
            leave, mark, end = (flips[f"{label}:{k}"] for k in ("leave", "mark", "end"))
            covered = self.foreign_over(label)
            if covered and item.get("foreign_ok"):
                # A relaunch leaves the desktop in view by design between the quit and the new window.
                item["behind"] = "+".join(foreign.owners(covered))
                covered = []
            if covered:
                # Another process's window was over the content or sidebar: these pixels measure it, not the app.
                judged.append((item, {"label": label, "foreign_window": "+".join(foreign.owners(covered)),
                                      "windows": covered}))
                say(f"  {label}: excluded, a window of {'+'.join(foreign.owners(covered))} covers the app")
                continue
            window = self.between(frames, leave, end)
            kind = item["kind"]
            strip = self.strip if kind in ("new", "close") or item.get("strip") == "tab" else None
            if kind == "return":
                reference = self.at(frames, leave)
                self.refs[item["shown"]] = reference
            elif kind == "new" or kind == "settled":
                reference = None
            elif kind == "at":
                reference = self.at(frames, flips[item["ref_flip"]]) if item.get("ref_flip") in flips else None
            else:
                reference = self.refs.get(item.get("neighbor"))
            switch = self.judge(window, mark, reference=reference, strip=strip)
            if kind == "close":
                switch["neighbor"] = item.get("neighbor")
            if item.get("strip") == "sidebar" and getattr(self, "sidebar", None):
                side = judge.judge_strip(window, mark, self.rec.w, self.sidebar, self.rec.frame_ms, self.rec.scale,
                                         self.args.tolerance, tab_points=40, axis="y")
                switch.update({"sidebar_" + k: v for k, v in side.items()})
            self.add_settle(switch, frames, window, leave, mark, end, reference, label)
            self.keep_sheet(switch, window, mark, label, reference)
            judged.append((item, switch))
        return judged

    def add_settle(self, switch, frames, window, leave, mark, end, reference, label):
        """settled_ms and the oddity list of one action, each oddity with its contact-sheet crop."""
        w, h, fm = self.rec.w, self.rec.h, self.rec.frame_ms
        a = settle.AMBIENT_S
        pre = self.between(frames, min(leave, mark) - a - 0.05, end)
        amb = settle.ambient(pre, w, h, [(leave - a, leave), (mark - a, mark)])
        st = settle.settle(window, mark, w, h, fm, end=end, ambient_tiles=amb)
        flicker = settle.flicker_frame(window, mark, w, self.content, self.args.tolerance)
        odd = settle.oddities(switch, st, flicker, fm)
        after = [f for f in window if f[0] > mark]
        for o in odd:
            if o.get("frame") is not None and 0 <= o["frame"] < len(after):
                o["ms"] = round((after[o["frame"]][0] - mark) * 1000, 1)
            png, tiles = settle.oddity_sheet(window, mark, w, h, o.get("frame"), reference)
            if png:
                o["sheet"] = self.write_png(png, f"odd {label} {o['kind']}")
                o["sheet_tiles_ms"] = tiles
        switch.update({k: v for k, v in st.items() if k != "change_frames"})
        switch["change_frames"] = st.get("change_frames", [])[:20]
        switch["oddities"] = odd
        matrix.add_region_settle(self, switch, frames, window, leave, mark, end)

    def run(self, loads, rounds, scenarios, agents, sessions, load_notes=None):
        """The scenario rows. A load in `load_notes` (its setup failed) and the chat scenario without a measurable chat
        are rows with no switch and the reason, so the rest still measures."""
        rows, notes = {}, {}
        load_notes = load_notes or {}
        if "chat-long-return" in scenarios and "chat" not in self.refs:
            scenarios = [s for s in scenarios if s != "chat-long-return"]
            for load in loads:
                notes[("chat-long-return", load)] = self.chat_note or "no chat"
        if "webkit-return" in scenarios and "webkit" not in self.refs:
            scenarios = [s for s in scenarios if s != "webkit-return"]
            for load in loads:
                notes[("webkit-return", load)] = getattr(self, "webkit_note", None) or "no WebKit page"
        for load in [x for x in loads if x in load_notes]:
            for name in scenarios:
                notes[(name, load)] = load_notes[load]
        self.load_seconds = rounds * 90 + 180
        cpu = None
        for load in [x for x in loads if x not in load_notes]:
            say(f"load {load}")
            spec = parse_load(load)
            if spec.get("cpu") and cpu is None:
                cpu = CpuLoad(self.root)
            pending = []  # (scenario name, what to judge), in the order driven
            blocks = []  # (that block's pending, frames, flips)
            # The matrix records a block per round: CuaDriver ends a session with no tool call for a while, and one
            # block of five rounds at Leo's scale (about 20 minutes) lost every row on a CI mini (2026-11-18).
            per_round = any(s in scenarios for s in matrix.MATRIX_SCENARIOS)
            setup = []
            try:
                setup = self.enter_load(spec, agents, cpu)
                for note in setup:
                    say(f"  {load}: {note}")
                self.rec.begin()
                for r in range(1, rounds + 1):
                    for name, (shown, via) in (("chat-long-return", ("chat", "terminal")),
                                               ("terminal-return", ("terminal", "chromium")),
                                               ("chromium-return", ("chromium", "terminal")),
                                               ("webkit-return", ("webkit", "terminal"))):
                        if name in scenarios:
                            pending.append((name, self.returning(shown, via, f"{name}/{load} round {r}")))
                    if "new-tab" in scenarios or "close-tab" in scenarios:
                        new, close = self.new_and_close(f"new-tab/{load} round {r}", f"close-tab/{load} round {r}")
                        pending.append(("new-tab", new))
                        if close is not None:
                            pending.append(("close-tab", close))
                    if any(s in scenarios for s in ("new-workspace", "switch-workspace", "close-workspace")):
                        pending += self.workspace_round(load, r)
                    if any(s in scenarios for s in ("rapid-open-5", "rapid-close-3", "open-while-close")):
                        pending += self.rapid_round(load, r)
                    if any(s in scenarios for s in matrix.MATRIX_SCENARIOS if s not in ("new-workspace", "launch-restore")):
                        pending += matrix.matrix_round(self, load, r, scenarios, agents)
                    say(f"  round {r} driven")
                    if per_round:
                        done = sum(len(b[0]) for b in blocks)
                        frames, flips = self.rec.end()
                        blocks.append((pending[done:], frames, flips))
                        if r < rounds:
                            self.rec.begin()
                if not per_round:
                    frames, flips = self.rec.end()
                    blocks.append((pending, frames, flips))
            except Exception as error:  # noqa: BLE001 - this load's rows say why; the next load still records
                judged = sum(len(b[0]) for b in blocks)
                for name, _item in pending[judged:] or [(s, None) for s in scenarios]:
                    notes.setdefault((name, load), f"{type(error).__name__}: {error}"[:600])
                try:
                    self.rec.end()  # a block a driving fault left open
                except Exception:  # noqa: BLE001 - it was already closed
                    pass
            finally:
                # After the block's recording: ending a load can recalibrate, which records a block of its own.
                self.exit_load(spec, agents, cpu)
            if not blocks:
                continue
            for block, frames, flips in blocks:
                for (name, _), (_item, switch) in zip(block, self.settle_block([p for _, p in block], frames, flips)):
                    if name in scenarios:
                        if _item.get("chat_perf") is not None:
                            switch["chat_perf"] = _item["chat_perf"]
                        if setup:
                            switch["load_setup"] = setup
                        rows.setdefault((name, load), []).append(switch)
            say(f"load {load}: {sum(len(b[0]) for b in blocks)} switches judged on "
                f"{sum(len(b[1]) for b in blocks)} frames in {len(blocks)} blocks")
        for key, note in (getattr(self, "matrix_notes", None) or {}).items():
            if key not in rows:
                notes.setdefault(key, note)
        if "switch-workspace-cold" in scenarios and getattr(self, "cold_note", None):
            for load in loads:
                notes.setdefault(("switch-workspace-cold", load), self.cold_note)
        if "launch-restore" in scenarios:
            # Last: each relaunch restores what the loads left. Its own block, judged as the loads' are.
            try:
                pending, frames, flips = matrix.launch_block(self, rounds, self.opt("launch_record", 8.0), say)
                for (name, _), (_item, switch) in zip(pending, self.settle_block([p for _, p in pending], frames, flips)):
                    rows.setdefault((name, "scale"), []).append(switch)
            except Exception as error:  # noqa: BLE001 - the row says why
                notes[("launch-restore", "scale")] = f"{type(error).__name__}: {error}"[:600]
        out = [judge.scenario_row(name, load, switches) for (name, load), switches in rows.items()]
        return out + [judge.scenario_row(name, load, [], notes=note) for (name, load), note in notes.items()]


def build_stress(control, measured, workspaces, terminals):
    """The STRESS background of L5 through the shared builder (scripts/cmux-next/perf-stress-session.py, as
    typing-frame-bench.py --stress): `workspaces` - 1 more workspaces (the first ten with Chromium pages) and
    `terminals` of them printing output. The measured workspace stays as built."""
    path = os.path.join(HERE, "perf-stress-session.py")
    spec = importlib.util.spec_from_file_location("perf_stress_session", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    stress = module.Stress(control.call, log=say)
    made = stress.build_background(count=max(0, workspaces - 1))
    busy = 0
    for workspace in made:
        if busy >= terminals:
            break
        tab = stress.first_terminal(workspace)
        if tab:
            stress.make_busy(tab)
            busy += 1
    say(f"stress: {len(made)} more workspaces, {busy} printing terminals")
    return made


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", help="an app bundle to launch (a copy of it is not made)")
    parser.add_argument("--dmg", help="a DMG whose app is copied out and launched (a NIGHTLY)")
    parser.add_argument("--build", default="unknown", help="the report's build: a version or a commit")
    parser.add_argument("--tools", required=True, help="the compiled scripts/measure/tab-switch-frames/tools.swift")
    parser.add_argument("--tolerance", type=float, default=0.01,
                        help="share of the content area that may differ for two decoded video frames to be one picture")
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--loads", default="idle,cpu,agents",
                        help="comma list of load names (parse_load): L0..L5, idle, cpu, cpu-max, agents, agents-N, "
                             "chat-100k, tabs-N, joined with + to combine")
    parser.add_argument("--scenarios", default=",".join(judge.SCENARIOS), help="comma list, or all")
    parser.add_argument("--chat-turns", type=int, default=200)
    parser.add_argument("--chat-rows", type=int, default=100000, help="rows of the chat-100k / L3 / L5 chat")
    parser.add_argument("--agents", type=int, default=4)
    parser.add_argument("--stream-rate", type=float, default=30)
    parser.add_argument("--stress-workspaces", type=int, default=60)
    parser.add_argument("--stress-terminals", type=int, default=20)
    parser.add_argument("--width", type=int, default=480, help="recorded frame width in pixels")
    parser.add_argument("--settle", type=float, default=1.0)
    parser.add_argument("--away", type=float, default=0.8)
    parser.add_argument("--record", type=float, default=1.2,
                        help="seconds recorded after each action: the settled time's cap is this less 300 ms")
    parser.add_argument("--load-settle", type=float, default=5.0)
    parser.add_argument("--out", default=os.path.join(os.getcwd(), ".build/tab-switch"))
    parser.add_argument("--no-gate", action="store_true", help="exit 0 when the report is written, budgets or not")
    parser.add_argument("--scale", default="none",
                        help="the settle matrix's scale (tab_switch_matrix.py): leo (10,789 sessions, 206 workspaces), "
                             "SESSIONSxWORKSPACES, or none")
    parser.add_argument("--seeder", help="the built cmux-tui acpmux example scale_home (needed with --scale)")
    parser.add_argument("--launch-record", type=float, default=8.0, help="seconds recorded after each relaunch")
    parser.add_argument("--chat-perf", action="store_true",
                        help="the settle matrix also runs the measured chat page's own capture (agent.chat.perf) over "
                             "each step: its long tasks and layout shift say whether the page did work")
    args = parser.parse_args(argv)
    # Decoded h264 frames of one picture differ in the low bits: 16 gray levels, not 32, so noise is not a change.
    judge.QUANT = bytes(v >> 4 for v in range(256))
    loads = [x for x in args.loads.split(",") if x]
    known = judge.ALL_SCENARIOS + tuple(s for s in matrix.MATRIX_SCENARIOS if s not in judge.ALL_SCENARIOS)
    scenarios = (list(judge.ALL_SCENARIOS) if args.scenarios == "all" else list(matrix.MATRIX_SCENARIOS)
                 if args.scenarios == "matrix" else [x for x in args.scenarios.split(",") if x])
    bad = [x for x in scenarios if x not in known]
    try:
        scale = matrix.parse_scale(args.scale)
    except ValueError as error:
        parser.error(str(error))
    if scale and not args.seeder:
        parser.error("--scale needs --seeder (cargo build --release -p acpmux --example scale_home)")
    for load in loads:
        try:
            parse_load(load)
        except ValueError:
            bad.append(load)
    if bad or not (args.app or args.dmg):
        parser.error(f"unknown load or scenario {bad}" if bad else "--app or --dmg")
    loads = order_loads(loads)
    args.webkit = "webkit-return" in scenarios
    os.makedirs(args.out, exist_ok=True)
    smoke = load_smoke()
    root = tempfile.mkdtemp(prefix="tab-switch-")
    extra = {"host": {"chip": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip(),
                      "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip(),
                      "cores": os.cpu_count()},
             "rounds": args.rounds, "chat_turns": args.chat_turns, "agents": args.agents,
             "loads": {load: parse_load(load) for load in loads}, "record_s": args.record,
             "settle_quiet_ms": settle.QUIET_MS}
    app = recorder = watch = None
    started = time.time()
    dialog = foreign.CrashDialogOff()
    dialog.__enter__()  # no crash dialog over the app for this run; put back in the finally below
    status, rows, hz = 3, [], None
    try:
        from pathlib import Path
        bundle = str(smoke.copy_app_from_dmg(Path(args.dmg), Path(root))) if args.dmg else os.path.realpath(args.app)
        extra["bundle_version"] = subprocess.run(["defaults", "read", os.path.join(bundle, "Contents/Info"), "CFBundleVersion"],
                                                 capture_output=True, text=True).stdout.strip()
        app = App(bundle, root, smoke)
        scale_ids = []
        if scale:
            # The NIGHTLY's daemon home is ~/.acpmux of the app's HOME (fresh_env: ROOT/h), written before its first exec.
            scale_ids = matrix.seed_home(args.seeder, os.path.join(root, "h", ".acpmux"), scale[0], say)
            extra["scale"] = {"sessions": len(scale_ids), "workspaces": scale[1]}
        app.launch()
        # The chat and the chat loads are optional: a setup fault in either leaves the terminal and page scenarios
        # measured, and names the fault on the rows it cost.
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
        for load in loads:
            spec = parse_load(load)
            if agents is None and (spec.get("bg_chats") or spec.get("chat100k") or spec.get("live")):
                load_notes[load] = "agents setup: no agent harness" + (f" ({setup['chat']})" if setup.get("chat") else "")
        extra["setup_errors"] = {**setup, **load_notes}
        recorder = capture.Capture(args.tools, app.process.pid, args.width, os.path.join(root, "capture"))
        hz = recorder.hz
        extra["capture"] = {"window": recorder.window, "display": recorder.display, "display_hz": recorder.hz,
                            "permissions": recorder.permissions, "recorder": "CuaDriver"}
        say(f"capture {json.dumps(extra['capture'])}")
        harness = Harness(args, app, recorder, root)
        watch = foreign.Watch(args.tools, {app.process.pid, recorder.marker.process.pid}, recorder.window, recorder.scale)
        if not watch.ready():
            raise Unmeasurable("the window list (tab-switch-tools windows) gave no sample: foreign windows cannot be ruled out")
        harness.watch = watch
        harness.chat_note = setup.get("chat")
        harness.long_session = session
        harness.build(session)
        if scale:
            made = matrix.open_scale_workspaces(harness, scale_ids, scale[1], say)
            extra["scale"]["workspaces_shown"] = len(harness.workspace_ids())
            extra["scale"]["opened"] = len(made)
        if agents is not None and any(s in scenarios for s in ("chat-10k-open", "chat-10k-return")):
            try:
                matrix.prepare_10k(harness, agents, say)
            except Exception as error:  # noqa: BLE001 - the chat-10k rows say why
                harness.chat_10k_note = f"10k-row chat: {type(error).__name__}: {error}"[:300]
                say(harness.chat_10k_note)
        extra["content_rect_px"], extra["strip_rect_px"] = harness.content, harness.strip
        extra["sidebar_rect_px"] = harness.sidebar
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
        if watch is not None:
            watch.close()
        if recorder is not None:
            recorder.close()
        if app is not None:
            app.end()
        dialog.__exit__(None, None, None)
        shutil.rmtree(root, ignore_errors=True)
    # Which process crashed during the run, if one did (the dialog is off, the report is on disk).
    reports = foreign.crash_reports(os.path.join(pwd.getpwuid(os.getuid()).pw_dir, "Library/Logs/DiagnosticReports"), started)
    extra["crash_reports"] = reports
    for report in reports:
        say(f"crash report during the run: {json.dumps(report)}")
    lost, total, share = foreign.excluded_share(rows)
    extra["foreign_windows"] = {"excluded": lost, "rounds": total, "share": round(share, 3), "by_owner": foreign.by_owner(rows),
                                "limit": foreign.MAX_EXCLUDED_SHARE}
    lines = settle.table(rows, baseline=next((x for x in ("L0", "idle") if x in loads), loads[0] if loads else "L0"))
    extra["table"] = lines
    extra["oddity_count"] = sum(len(s.get("oddities") or []) for r in rows for s in r["switches"])
    out = judge.report(args.build, hz, rows, extra)
    if status == 3:
        out["pass"] = False
    if foreign.too_many(rows):
        # Not a budget miss: the screen was not the app's, so there is nothing to judge (exit 3, as an unmeasurable run).
        print(f"TSW-FAIL foreign windows covered the app in {lost} of {total} rounds ({share:.0%}, limit "
              f"{foreign.MAX_EXCLUDED_SHARE:.0%}): {json.dumps(foreign.by_owner(rows))}", flush=True)
        out["pass"] = False
        status = 3
    with open(os.path.join(args.out, "report.json"), "w") as handle:
        json.dump(out, handle, indent=1)
    with open(os.path.join(args.out, "table.md"), "w") as handle:
        handle.write(settle.table_markdown(lines))
    for row in rows:
        print("TSW", json.dumps(judge.summary(row)), flush=True)
        for fail in row["budget_fail"][:6]:
            print("TSW-FAIL", fail, flush=True)
        for index, switch in enumerate(row["switches"]):
            for odd in switch.get("oddities") or []:
                print("TSW-ODD", json.dumps({"scenario": row["name"], "load": row["load"], "action": index + 1,
                                             **{k: odd.get(k) for k in ("kind", "frame", "ms", "detail", "sheet")}}),
                      flush=True)
    for line in lines:
        print("TSW-TABLE", json.dumps(line), flush=True)
    print(settle.table_markdown(lines), flush=True)
    if any(s in matrix.MATRIX_SCENARIOS for s in scenarios):
        # The settle matrix: trigger to truly settled over the window, the page side and the sidebar (SETTLE lines).
        settled = matrix.table([r for r in rows if r["name"] in matrix.MATRIX_SCENARIOS])
        out["matrix"] = settled
        with open(os.path.join(args.out, "report.json"), "w") as handle:
            json.dump(out, handle, indent=1)
        with open(os.path.join(args.out, "matrix.md"), "w") as handle:
            handle.write(matrix.table_markdown(settled))
        for line in settled:
            print("SETTLE", json.dumps(line), flush=True)
        print(matrix.table_markdown(settled), flush=True)
    say(f"pass={out['pass']} report {os.path.join(args.out, 'report.json')}")
    if status == 3:
        return 3
    return 0 if out["pass"] or args.no_gate else 1


if __name__ == "__main__":
    sys.exit(main())
