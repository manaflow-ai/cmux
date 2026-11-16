#!/usr/bin/env python3
"""Tab switch harness: every switch judged from the frames the screen showed, idle and under load (tab-switch/v1).

Leo, 2026-11-15 (softened): have we ever had benchmarks on any of this? Why is it so slow? It should be instant even
under load, and a tab or its animation not knowing where it should go is silly; we should have had CI for this a long
time ago. His NIGHTLY recording shows blank panes on return, an empty centered composer flashing before the
transcript, content and composer jumping as rows arrive, and a new tab not knowing where it goes.

Runs on a Mac with a console session (scripts/measure/tab-switch.sh build=nightly|SHA, through `cmux-ci run
--display`), against a shipped NIGHTLY (no debug.* commands: only the public control socket's snapshot.get and
action.run) or a built app. The frames come from outside the app (scripts/measure/tab-switch-frames/recorder.swift:
ScreenCaptureKit on the window's region at display rate), so the same harness measures both.

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
Kills only what it started: the app copy it launched (its bundle's processes), its spinners and its recorder.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import select
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
import bench_memory as bm  # noqa: E402
import idle_cost_load as icl  # noqa: E402
import tab_switch_judge as judge  # noqa: E402

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

    def action(self, name, focus=True, **args):
        params = {"action": name, "args": args, "wait": True, "origin": "script",
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
            bm.end_bundle(self.bundle)  # this run's copy: every process of it is this run's
        if self.aside is not None:
            self.aside.__exit__(None, None, None)


# ---------------------------------------------------------------------------------------------------------------
# The recorder.

class Recorder:
    def __init__(self, binary, pid, width):
        self.process = subprocess.Popen([binary, str(pid), str(width)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, bufsize=1, start_new_session=True)
        self.ready = self.reply(30)
        if not self.ready or not self.ready.get("ready"):
            err = self.process.stderr.read(2000) if self.process.poll() is not None else ""
            raise Unmeasurable(f"recorder: {self.ready or 'no answer'} {err}".strip())
        if not self.ready.get("first_frame"):
            raise Unmeasurable(f"recorder: no frame came in 5 s (Screen Recording grant? {self.ready})")
        self.w, self.h = self.ready["w"], self.ready["h"]
        self.scale = self.ready["px_per_point"]
        self.hz = self.ready["display_hz"]
        self.frame_ms = 1000.0 / self.hz

    def reply(self, timeout):
        ready, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not ready:
            return None
        line = self.process.stdout.readline()
        try:
            return json.loads(line)
        except ValueError:
            return {"error": line.strip()[:300]}

    def send(self, line):
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()

    def begin(self, path):
        self.send(f"begin {path}")
        answer = self.reply(10)
        if not answer or not answer.get("begun"):
            raise Unmeasurable(f"recorder begin: {answer}")

    def mark(self, name):
        self.send(f"mark {name}")

    def end(self):
        self.send("end")
        answer = self.reply(30) or {}
        return {name: t for name, t in answer.get("marks") or []}

    def quit(self):
        if self.process.poll() is None:
            try:
                self.send("quit")
                self.process.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                os.killpg(self.process.pid, signal.SIGKILL)  # this run's own recorder, by its own process group


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


class Agents:
    """Chats on the app's own acpmux (the test agents registered as harnesses of the app)."""

    def __init__(self, app, bundle):
        self.app, self.bundle = app, bundle
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

    def new(self, agent_id, text):
        made = subprocess.run([self.cli, "acp", "new", "--json", "-d", "-m", agent_id, text], capture_output=True,
                              text=True, timeout=180, env=self.env)
        try:
            return json.loads(made.stdout)["sessionId"]
        except (ValueError, KeyError):
            raise Unmeasurable(f"acp new {agent_id}: {(made.stdout + made.stderr).strip()[-600:]}")

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
            icl.stream([self.cli], self.env, session, seconds, rate)
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
        self.seq = 0

    def segment(self):
        self.seq += 1
        return os.path.join(self.root, f"seg-{self.seq:04d}.bin")

    def select(self, name):
        return self.c.action("selectSurfaceByNumber", index=self.index[name])

    def grab(self):
        """The picture on screen now (full gray frame)."""
        path = self.segment()
        self.rec.begin(path)
        time.sleep(0.12)  # test script: the recorder writes the frame on screen at begin
        self.rec.end()
        frames = judge.read_segment(path, self.rec.w, self.rec.h)
        os.remove(path)
        if not frames:
            raise Unmeasurable("the recorder wrote no frame")
        return frames[-1][1]

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
        reply = self.c.action("agent.openSessionTab", session=chat_session)
        if reply.get("error"):
            raise Unmeasurable(f"agent.openSessionTab: {reply['error']}")
        self.wait_tabs(2)
        time.sleep(4)  # test script: the long transcript loads
        page = os.path.join(self.root, "page.html")
        with open(page, "w") as handle:
            handle.write(page_html())
        reply = self.c.action("openBrowser.chromium", url="file://" + page)
        if reply.get("error"):
            raise Unmeasurable(f"openBrowser.chromium: {reply['error']}")
        tabs = self.wait_tabs(3)
        self.tabs_at_build = tabs
        if len(tabs) != 3:
            raise Unmeasurable(f"the workspace's pane has {len(tabs)} tabs, want 3 (terminal, chat, page): {json.dumps(tabs)[:600]}")
        self.index = {"terminal": 1, "chat": 2, "chromium": 3}
        time.sleep(2)  # test script: the page loads
        # The content area: pane_chrome on a build with debug commands, else the pixels of two tabs.
        self.select("terminal")
        time.sleep(1)
        terminal = self.grab()
        self.select("chromium")
        time.sleep(1)
        page_frame = self.grab()
        self.select("chat")
        time.sleep(1.5)
        chat = self.grab()
        self.content = self.chrome_rect() or judge.content_rect(terminal, page_frame, self.rec.w, self.rec.h)
        if self.content is None:
            raise Unmeasurable("the capture shows no difference between a terminal and a Chromium page (no page pixels: "
                               "Screen Recording grant?)")
        self.strip = judge.strip_rect(self.content, self.rec.scale, self.rec.h)
        cterm, cchat = (judge.crop(f, self.rec.w, self.content) for f in (terminal, chat))
        if judge.diff_share(cterm, cchat) <= judge.TOLERANCE:
            raise Unmeasurable("the chat tab shows the same pixels as the terminal (its page not in the capture?)")
        self.refs = {"terminal": terminal, "chromium": page_frame, "chat": chat}

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
                                  strip=strip, px_per_point=self.rec.scale)

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

    def returning(self, shown, via, label):
        self.select(shown)
        time.sleep(self.args.settle)
        path = self.segment()
        self.rec.begin(path)
        time.sleep(0.25)
        self.rec.mark("leave")
        self.select(via)
        time.sleep(self.args.away)
        self.rec.mark("return")
        self.select(shown)
        time.sleep(self.args.record)
        marks = self.rec.end()
        frames = judge.read_segment(path, self.rec.w, self.rec.h)
        os.remove(path)
        leave, back = marks.get("leave"), marks.get("return")
        if leave is None or back is None:
            return {"error": "the recorder lost a mark"}
        last = [f for f in frames if f[0] <= leave]
        reference = last[-1][1] if last else self.refs.get(shown)
        self.refs[shown] = reference
        tail = [f for f in frames if f[0] > leave]
        switch = self.judge(tail, back, reference=reference)
        self.keep_sheet(switch, tail, back, label, reference)
        return switch

    def new_and_close(self, label_new, label_close):
        self.select("terminal")
        time.sleep(self.args.settle)
        out = []
        path = self.segment()
        self.rec.begin(path)
        time.sleep(0.25)
        self.rec.mark("new")
        reply = self.c.action("newSurface")
        time.sleep(self.args.record + 0.3)
        marks = self.rec.end()
        frames = judge.read_segment(path, self.rec.w, self.rec.h)
        os.remove(path)
        if reply.get("error"):
            return [{"error": f"newSurface: {reply['error']}"}], None
        switch = self.judge(frames, marks.get("new", 0), strip=self.strip)
        self.keep_sheet(switch, frames, marks.get("new", 0), label_new)
        out.append(switch)
        time.sleep(0.5)
        path = self.segment()
        self.rec.begin(path)
        time.sleep(0.25)
        self.rec.mark("close")
        reply = self.c.action("closeTab")
        time.sleep(self.args.record + 0.3)
        marks = self.rec.end()
        frames = judge.read_segment(path, self.rec.w, self.rec.h)
        os.remove(path)
        if reply.get("error"):
            return out, {"error": f"closeTab: {reply['error']}"}
        tabs, pane = self.c.focused_tabs()
        selected = next((i + 1 for i, t in enumerate(tabs) if t.get("selected") or (pane and t.get("id") == pane.get("selected_tab"))), None)
        neighbor = {1: "terminal", 2: "chat", 3: "chromium"}.get(selected)
        reference = self.refs.get(neighbor) if neighbor else None
        if len(tabs) != 3:
            close = {"error": f"the pane has {len(tabs)} tabs after the close, want 3"}
        else:
            close = self.judge(frames, marks.get("close", 0), reference=reference, strip=self.strip)
            close["neighbor"] = neighbor
            self.keep_sheet(close, frames, marks.get("close", 0), label_close, reference)
        return out, close

    def run(self, loads, rounds, scenarios, agents, sessions):
        rows = {}
        for load in loads:
            say(f"load {load}")
            if load == "cpu":
                agents_cpu = CpuLoad(self.root)
                agents_cpu.start()
            elif load == "agents":
                agents.start(sessions, seconds=rounds * 40 + 120, rate=self.args.stream_rate)
            time.sleep(self.args.load_settle if load != "idle" else 0)
            try:
                for r in range(1, rounds + 1):
                    for name, (shown, via) in (("chat-long-return", ("chat", "terminal")),
                                               ("terminal-return", ("terminal", "chromium")),
                                               ("chromium-return", ("chromium", "terminal"))):
                        if name in scenarios:
                            rows.setdefault((name, load), []).append(self.returning(shown, via, f"{name}/{load} round {r}"))
                    if "new-tab" in scenarios or "close-tab" in scenarios:
                        news, close = self.new_and_close(f"new-tab/{load} round {r}", f"close-tab/{load} round {r}")
                        if "new-tab" in scenarios:
                            rows.setdefault(("new-tab", load), []).extend(news)
                        if "close-tab" in scenarios and close is not None:
                            rows.setdefault(("close-tab", load), []).append(close)
                    say(f"  round {r} done")
            finally:
                if load == "cpu":
                    agents_cpu.stop()
                elif load == "agents":
                    agents.stop()
        return [judge.scenario_row(name, load, switches) for (name, load), switches in rows.items()]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", help="an app bundle to launch (a copy of it is not made)")
    parser.add_argument("--dmg", help="a DMG whose app is copied out and launched (a NIGHTLY)")
    parser.add_argument("--build", default="unknown", help="the report's build: a version or a commit")
    parser.add_argument("--recorder", required=True, help="the compiled recorder.swift")
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
        agents = Agents(app, bundle)
        session, seed_s = agents.long_chat(args.chat_turns)
        say(f"long chat {session}: {args.chat_turns} turns in {seed_s} s")
        extra["seed_s"] = seed_s
        sessions = agents.stream_chats(args.agents) if "agents" in loads else []
        recorder = Recorder(args.recorder, app.process.pid, args.width)
        hz = recorder.hz
        extra["capture"] = recorder.ready
        say(f"capture {json.dumps(recorder.ready)}")
        harness = Harness(args, app, recorder, root)
        harness.build(session)
        extra["content_rect_px"], extra["strip_rect_px"] = harness.content, harness.strip
        extra["tabs_at_build"] = harness.tabs_at_build
        rows = harness.run(loads, args.rounds, scenarios, agents, sessions)
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
            recorder.quit()
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
