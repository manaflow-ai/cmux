#!/usr/bin/env python3
"""Click to first content for every right-side open of a cmux NEXT chat, light, under STRESS and right after a restart.

Leo, 2026-11-05: "I need those all to always open up really fast. ... the browser itself can also be helped
probably. And then I also think the diff viewer, there's a decent amount of work, but I feel there's more that we
can do. And probably also actually terminal would probably open up okay, but the other ones, there's stuff opening
up subagents or opening up other sessions. Those need to be fast. There's no reason for them to have a delay, even
under load."

One chat (a seeded acpmux chat with subagents, its folder a git repository with uncommitted changes, so Changes
shows) in a workspace of its own. Each surface is one real click on the chat's page (`debug.new_tab frame_strip`
with gesture `agent_click`: the element is found before the recording starts, and the click's instant is when its
press goes in), and the window is read as the window server composited it, frame after frame, until the rightmost
pane (`content: "rightmost"`, where every right-side open lands) stops changing:

  terminal     the header's Terminal: a terminal split on the chat's right
  browser      the header's Browser: a browser split on the chat's right
  changes      the header's Changes: the diff viewer of the chat's folder beside the chat
  files        the header's Files: the folder tree beside the chat (shown through agent-pane/layout.json)
  new_tab      the header's [+] New tab: a New Tab page in a column right of the chat (layout.json too)
  subagent     a click on a subagent's line in the transcript: the subagent's chat on the right
  side_chat    the "..." menu's New side chat: another session's chat on the right (the menu opens first, untimed)

Per open, from the frames (chat_open_frames.final_frame) and frame_strip's own report:

  commit_ms         the first frame whose rightmost pane differs from before the click (the open's first visible
                    change: the split or tab shows)
  first_content_ms  the first such frame that is not blank (the pane is not one flat color)
  final_ms          the first frame of the settled run (every frame after it equals the last): the surface's final
                    content. An open that never settles inside the strip (--strip-ms) has none and counts as missed.

Each as p50 / p95 / max over the opens of a surface. Three conditions (--conditions):

  light    a fresh app: one window, the chat's workspace
  stress   the STRESS session (perf-stress-session.py: 59 other workspaces, 10 with Chromium pages, the 14-pane
           grid of 6 tabs each, 10 busy terminals elsewhere), then the chat's workspace shown on top; and while
           measuring, CPU spinners on every core, disk writers and readers (chat-open-bench's load) and
           --storm workers looping the app's own CLI against its daemon (a busy daemon)
  restart  the app quit as a person quits (state kept) and launched again on the light state: each relaunch's
           first open of every surface (--restarts relaunches)

The budget (CLAUDE.md, perf-lead.md): every action < 10 ms to its committed frame, the content in that frame. A
frame strip sees a change only in a display frame, so a surface is OVER when its p95 commit_ms is past one display
frame plus 10 ms, or its p95 final_ms past its p95 commit_ms by more than a frame (content after the first frame).

Usage: right-pane-open-bench.py --app APP [--runs 6] [--conditions light,stress,restart] [--surfaces ...]
                                [--restarts 2] [--json FILE] [--md FILE]
Fleet: cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/right-pane-open.sh
       --ref SHA --artifact artifacts/right-pane-open.json [--arg=--runs=6]
The table is printed between RIGHT-PANE-OPEN-TABLE-BEGIN and -END, and the JSON has every open's frames.
Kills only the processes it started (the app it launched, the seeding daemon, the load's own process groups).
"""
import argparse
import importlib.util
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_memory as bm  # noqa: E402
import chat_open_frames as cof  # noqa: E402
import idle_cost_load as icl  # noqa: E402
from bench_power import wipe_state  # noqa: E402

SURFACES = ("terminal", "browser", "changes", "files", "new_tab", "subagent", "side_chat")
# The header's quick actions by id (webviews acpmux header/quickActions.ts, ChatHeaderTools `data-quick-action`).
QUICK = {"terminal": "terminal", "browser": "browser", "changes": "changes", "files": "files", "new_tab": "newTab"}
# A subagent's line in the transcript (chat-open-bench.py's SUBAGENT_LINES): by its name or task first.
SUBAGENT_LINES = ("button.cv-subagent-done:not([disabled])", "button.acpmux-agent-line__button:not([disabled])")
NO_MATCH = "no visible element matches"

parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
parser.add_argument("--app", required=True)
parser.add_argument("--runs", type=int, default=6, help="opens of each surface per condition (restart: one per relaunch)")
parser.add_argument("--restarts", type=int, default=2, help="relaunches in the restart condition")
parser.add_argument("--conditions", default="light,stress,restart")
parser.add_argument("--surfaces", default=",".join(SURFACES))
parser.add_argument("--storm", type=int, default=6, help="stress: workers looping the app's CLI against its daemon")
parser.add_argument("--strip-ms", type=float, default=2500, help="how long each frame strip records after the click")
parser.add_argument("--strip-tolerance", type=float, default=0.001)
parser.add_argument("--settle-frames", type=int, default=10)
parser.add_argument("--settle", type=float, default=6, help="stress: seconds the load runs before the first open")
parser.add_argument("--tag", default="rpopen")
parser.add_argument("--json")
parser.add_argument("--md")
opts = parser.parse_args()
APP = os.path.realpath(opts.app.rstrip("/"))
CONDITIONS = [c.strip() for c in opts.conditions.split(",") if c.strip()]
WANTED = [s.strip() for s in opts.surfaces.split(",") if s.strip()]
unknown = [s for s in WANTED if s not in SURFACES]
if unknown:
    raise SystemExit(f"right-pane-open: unknown surfaces {unknown}; use {','.join(SURFACES)}")
SUBAGENTS = opts.runs + opts.restarts + 2
AGENT = os.path.join(HERE, "chat_open_agent.py")
NCPU = os.cpu_count() or 8
CONFIG = {"workspaces": {"newPlacement": "bottom"}}
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")


def say(*parts):
    print(" ".join(str(p) for p in parts), flush=True)


def load_stress():
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


STRESS = load_stress()

# ---------------------------------------------------------------------------------------------
# The load: chat-open-bench's (the QoS lane's probe shape), plus the app's CLI against its daemon.

SPIN_C = r"""#include <pthread.h>
static void*t(void*a){volatile unsigned long x=0;for(;;)x++;return 0;}
int main(){pthread_t th;for(int i=0;i<3;i++)pthread_create(&th,0,t,0);t(0);return 0;}
"""


class Load:
    def __init__(self, root):
        self.root = os.path.join(root, "load")
        os.makedirs(os.path.join(self.root, "tree"), exist_ok=True)
        source = os.path.join(self.root, "spin.c")
        with open(source, "w") as handle:
            handle.write(SPIN_C)
        self.spin = os.path.join(self.root, "spin")
        subprocess.run(["cc", "-O2", "-o", self.spin, source], check=True)
        for i in range(400):
            with open(os.path.join(self.root, "tree", f"f{i}"), "wb") as handle:
                handle.write(os.urandom(65536))
        self.groups = []

    def start(self, app_socket):
        work = [[self.spin]] * (NCPU // 4 + 1)
        work += [["/bin/sh", "-c", f"while :; do dd if=/dev/zero of={self.root}/w$$ bs=1m count=256 2>/dev/null; "
                  f"rm -f {self.root}/w$$; done"]] * 2
        work += [["/bin/sh", "-c", "while :; do find /System/Library /usr -type f -size +1k >/dev/null 2>&1; done"]] * 2
        work += [["/bin/sh", "-c", f"while :; do cat {self.root}/tree/f* | shasum >/dev/null; done"]] * 2
        storm = f'while :; do "{CLI}" --app-socket "{app_socket}" workspace list >/dev/null 2>&1; ' \
                f'"{CLI}" --app-socket "{app_socket}" tree >/dev/null 2>&1; done'
        work += [["/bin/sh", "-c", storm]] * opts.storm
        for argv in work:
            # Each in a process group of its own, so stop() ends exactly what this started.
            self.groups.append(subprocess.Popen(argv, start_new_session=True, stdout=subprocess.DEVNULL,
                                                stderr=subprocess.DEVNULL))

    def stop(self):
        for child in self.groups:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for child in self.groups:
            child.wait()
        self.groups = []
        for name in os.listdir(self.root):
            if name.startswith("w"):
                os.remove(os.path.join(self.root, name))


def load_average():
    return subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip()


# ---------------------------------------------------------------------------------------------
# The chat and its folder.

def make_repo(root):
    """A git repository with uncommitted changes in three files, so the chat's header shows Changes."""
    repo = os.path.join(root, "project")
    os.makedirs(os.path.join(repo, "src"), exist_ok=True)
    git = lambda *a: subprocess.run(["git", "-C", repo, *a], check=True, capture_output=True)  # noqa: E731
    git("init", "-q")
    git("config", "user.email", "bench@example.invalid")
    git("config", "user.name", "bench")
    for i in range(3):
        with open(os.path.join(repo, "src", f"file{i}.py"), "w") as handle:
            handle.write("".join(f"def f{i}_{k}():\n    return {k}\n\n" for k in range(200)))
    git("add", ".")
    git("commit", "-q", "-m", "base")
    for i in range(3):
        with open(os.path.join(repo, "src", f"file{i}.py"), "a") as handle:
            handle.write("".join(f"def g{i}_{k}():\n    return {k} * 2\n\n" for k in range(40)))
    return repo


def seed(root, repo):
    """A chat with SUBAGENTS subagents, written by acpmux on a seeding daemon, then one copy per condition
    (fresh ids, the repo as its folder) in the app's store."""
    peer = icl.PeerDaemon(APP, root, AGENT)
    peer.start()
    try:
        session = peer.new_chat("turn: 0")
        if not session:
            raise SystemExit("right-pane-open: the seeding daemon made no chat")
        for text in ("turn: 1", f"subagents: {SUBAGENTS}"):
            sent = peer.acpmux("send", session, text, timeout=180)
            if sent.returncode != 0:
                raise SystemExit(f"right-pane-open: send {text!r}: {(sent.stdout + sent.stderr).strip()[-2000:]}")
        template = icl.read_chat(peer.home, session)
    finally:
        peer.stop()
    home = os.path.join(root, "acpmux")
    icl.private_dir(home)
    icl.private_dir(os.path.join(home, "sessions"))
    chats = {}
    for condition in CONDITIONS:
        chat = str(uuid.uuid4())
        swap = lambda data: data.replace(template["id"].encode(), chat.encode())  # noqa: E731
        meta = json.loads(swap(template["meta"]))
        meta.update({"id": chat, "name": f"Right pane {condition}", "title": f"Right pane {condition}",
                     "updatedAt": int(time.time() * 1000), "status": "idle", "cwd": repo})
        folder = os.path.join(home, "sessions", chat)
        icl.private_dir(folder)
        icl.private_dir(os.path.join(folder, "events"))
        icl.private_write(os.path.join(folder, "session.json"), json.dumps(meta, indent=2).encode())
        for name, data in template["events"].items():
            icl.private_write(os.path.join(folder, "events", name), swap(data))
        chats[condition] = chat
    return home, chats, sorted(json.loads(template["meta"]).keys())


# ---------------------------------------------------------------------------------------------
# The app.

class Run:
    """One launched app on a state that outlives its launches (HOME, config, acpmux store)."""

    def __init__(self, acpmux_home):
        self.env = {"ACPMUX_HOME": acpmux_home}
        self.pid = self.sock = self.scratch = None

    def launch(self):
        if self.scratch is None:
            self.pid, self.sock, self.scratch = bm.launch(APP, CONFIG, dict(self.env))
            self.env.update({"HOME": os.path.join(self.scratch, "home"), "TMPDIR": os.path.join(self.scratch, "tmp") + "/",
                             "CMUX_NEXT_CONFIG_FILE": os.path.join(self.scratch, "cmux.json")})
            self.write_layout()
        else:
            # Into this run's scratch (its HOME, config and saved state), with bench_memory's whole environment
            # (the scratch Downloads folder too), as a relaunch after a quit.
            self.pid, self.sock, _ = bm.launch(APP, CONFIG, dict(self.env), scratch=self.scratch)
        self.app = bm.App(APP, self.sock)
        deadline = time.monotonic() + 60
        while not self.app.ping() and time.monotonic() < deadline:
            time.sleep(0.5)  # test script: the app's socket answers once it runs

    def write_layout(self):
        """Every quick action the bench clicks shows in the header (Files and New tab are off by default):
        agent-pane/layout.json next to cmux.json, which the app watches."""
        folder = os.path.join(os.path.dirname(self.env["CMUX_NEXT_CONFIG_FILE"]), "agent-pane")
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, "layout.json"), "w") as handle:
            json.dump({"quickActions": ["changes", "terminal", "browser", "files", "newTab"]}, handle)

    def rpc(self, method, params=None, timeout=40):
        try:
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
            answer = json.loads(buf or b"{}")
        except (OSError, ValueError) as error:
            return {"error": f"{method}: {error}"}
        return {"error": answer["error"]} if answer.get("error") else answer.get("result")

    def quit(self):
        """Quits as a person does (state saved), then makes sure every process of the bundle ended."""
        self.rpc("action.run", {"action": "quitKeepSessions", "origin": "script"})
        if self.pid and not bm.wait_gone(self.pid, 30):
            bm.end_bundle(APP)
        bm.end_bundle(APP)

    def end(self):
        bm.end_bundle(APP)
        if self.scratch:
            shutil.rmtree(self.scratch, ignore_errors=True)


class Chat:
    """The chat's workspace in `run`: shows it, finds its pane, lists and closes what an open added."""

    def __init__(self, run):
        self.run = run
        self.stress = STRESS.Stress(lambda m, p=None, timeout=60: run.rpc(m, p, timeout), log=say)
        self.workspace = self.pane = None

    def open(self, session):
        key = str(uuid.uuid4())
        opened = self.run.app.action("agent.openSessionWorkspace", focus=True, wait=False, session=session, key=key)
        if opened.get("error"):
            raise SystemExit(f"right-pane-open: open the chat: {opened}")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            reply = self.run.app.action("goToWorkspace", focus=True, workspace=key)
            if not reply.get("error"):
                break
            time.sleep(0.05)  # test script: the workspace is not listed yet
        self.find()

    def find(self):
        """The shown workspace and the pane that shows the chat (an agent tab), once the chat's page has content."""
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            ready = self.run.rpc("debug.agent_pane", {"action": "readiness"}) or {}
            if (ready.get("body_text_length") or 0) > 0 and ready.get("pane"):
                self.pane = ready["pane"]
                break
            time.sleep(0.3)  # test script: waiting for the chat to show
        self.workspace = self.stress.focused_workspace()
        if not self.pane:
            panes = self.stress.panes(self.stress.workspace(self.workspace))
            self.pane = panes[0]["id"] if panes else None
        time.sleep(1.5)  # test script: the page's own reads after its first content end before the first click

    def show(self):
        self.stress.show(self.workspace)
        self.stress.focus_pane(self.pane)
        time.sleep(0.5)  # test script: the switch settles

    def tabs(self):
        return {t.get("id") for p in self.stress.panes(self.stress.workspace(self.workspace)) for t in p.get("tabs") or [] if t.get("id")}

    def close_new(self, before):
        """Closes every tab an open added (the chat alone again), and waits for the layout to be back."""
        for tab in self.tabs() - before:
            self.stress.action("closeTab", target=f"tab:{tab}", focus=False)
        STRESS.wait(lambda: not (self.tabs() - before), 10, step=0.1)
        STRESS.wait(lambda: len(self.stress.panes(self.stress.workspace(self.workspace))) <= 1, 10, step=0.1)
        self.stress.focus_pane(self.pane)
        time.sleep(0.6)  # test script: the close's own motion ends before the next click


# ---------------------------------------------------------------------------------------------
# One open.

def strip(run, chat, click, label):
    folder = os.path.join(tempfile.gettempdir(), f"right-pane-open-{os.getpid()}", label)
    params = {"action": "frame_strip", "gesture": "agent_click", "click": {**click, "pane": chat.pane}, "above": True,
              "content": "rightmost", "duration_ms": opts.strip_ms, "dir": folder, "tolerance": opts.strip_tolerance}
    reply = run.rpc("debug.new_tab", params, timeout=opts.strip_ms / 1000 + 90) or {}
    shutil.rmtree(folder, ignore_errors=True)
    return reply


def clicks(surface, round_index):
    """The click targets to try for `surface`, in order: the first one the page shows is clicked."""
    if surface in QUICK:
        return [{"selector": f'[data-quick-action="{QUICK[surface]}"]'}]
    if surface == "subagent":
        order = [round_index % SUBAGENTS] + [k for k in range(SUBAGENTS - 1, -1, -1) if k != round_index % SUBAGENTS]
        texts = [t for k in order for t in (f"Auditor {k}", f"Audit area {k}: crashes, edge cases, slow paths")]
        return [{"text": t} for t in texts] + [{"selector": s} for s in SUBAGENT_LINES]
    if surface == "side_chat":
        return [{"text": "New side chat"}]
    raise ValueError(surface)


def measure(run, chat, surface, label, round_index):
    before = chat.tabs()
    if surface == "side_chat":
        # The "..." menu first (not timed): New side chat is its row.
        opened = run.rpc("debug.agent_pane", {"action": "click", "selector": ".acpmux-header-more", "pane": chat.pane}) or {}
        if opened.get("error"):
            return {"error": f"open the chat menu: {opened['error']}"}
        time.sleep(0.4)  # test script: the menu's own motion ends
    reply, target = {}, None
    for target in clicks(surface, round_index):
        reply = strip(run, chat, target, label)
        if NO_MATCH not in str(reply.get("error") or ""):
            break
    if reply.get("error"):
        chat.close_new(before)
        return {"error": str(reply["error"])[:400], "click": target}
    # A click that failed in the app comes back in `key` (the gesture's own reply), not as the strip's error.
    clicked = reply.get("key") if isinstance(reply.get("key"), dict) else {}
    if clicked.get("error") or clicked.get("clicked") is False:
        chat.close_new(before)
        return {"error": f"click: {clicked.get('error') or 'not clicked'}", "click": target, "key": clicked}
    record = cof.final_frame(reply.get("frames"), settle_frames=opts.settle_frames, tolerance=opts.strip_tolerance)
    record.update({"click": target, "commit_ms": reply.get("first_change_ms"), "final_ms": record.get("final_frame_ms"),
                   "strip_settled_ms": reply.get("settled_ms"), "frame_count": reply.get("frame_count"),
                   "mean_interval_ms": reply.get("mean_interval_ms"), "capture": reply.get("capture"),
                   "key": reply.get("key"), "spans": reply.get("spans"), "opened_tabs": len(chat.tabs() - before),
                   "frames": [[f.get("ms"), round(f.get("content_vs_before") or 0, 4), round(f.get("content_vs_final") or 0, 4),
                               round(f.get("flatness") or 0, 4), bool(f.get("blank"))] for f in reply.get("frames") or []],
                   "frames_columns": ["ms", "content_vs_before", "content_vs_final", "flatness", "blank"]})
    if not record["opened_tabs"]:
        record["error"] = "the click opened no tab"
    chat.close_new(before)
    return record


# ---------------------------------------------------------------------------------------------
# Summary.

def pct(values, q):
    values = sorted(v for v in values if isinstance(v, (int, float)) and not isinstance(v, bool))
    if not values:
        return None
    return round(values[min(len(values) - 1, int(round((len(values) - 1) * q)))], 1)


def summarize(records):
    good = [r for r in records if not r.get("error") and isinstance(r.get("final_ms"), (int, float))]
    out = {"n": len(records), "ok": len(good), "errors": [r.get("error") for r in records if r.get("error")][:4],
           "missed": len(records) - len(good)}
    for key in ("commit_ms", "first_content_ms", "final_ms"):
        values = [r.get(key) for r in good]
        out[key] = {"p50": pct(values, 0.5), "p95": pct(values, 0.95), "max": pct(values, 1.0)}
    frames = [r.get("mean_interval_ms") for r in good if isinstance(r.get("mean_interval_ms"), (int, float))]
    out["frame_ms"] = round(sum(frames) / len(frames), 1) if frames else None
    out["over"] = over_budget(out)
    return out


def over_budget(s):
    """Over the < 10 ms committed-frame budget with content in that frame (the module doc), or a missed open."""
    if s["missed"] or not s["ok"]:
        return "missed"
    frame = s.get("frame_ms") or 16.7
    commit, final = s["commit_ms"]["p95"], s["final_ms"]["p95"]
    reasons = []
    if commit is not None and commit > frame + 10:
        reasons.append("commit")
    if final is not None and commit is not None and final - commit > frame:
        reasons.append("content")
    return ",".join(reasons) or None


def triple(s, key):
    v = s.get(key) or {}
    return "/".join("–" if v.get(q) is None else f"{v[q]:g}" for q in ("p50", "p95", "max"))


def markdown(results):
    lines = [f"right-pane-open-bench on {results['host']} ({results['model']}, {results['ncpu']} CPUs), app {results.get('app_version')}; "
             f"ms from the click to the frame, p50/p95/max over the opens (n ok/n); commit: the rightmost pane first changes; "
             f"content: its first non-blank frame; final: the first frame of its settled run. OVER: p95 commit past a frame "
             f"plus 10 ms (commit), or the final frame more than a frame after the commit (content); missed: an open that "
             f"errored or never settled in {opts.strip_ms:g} ms",
             "", "| surface | condition | n | commit | content | final | over |", "|---|---|---|---|---|---|---|"]
    for surface in WANTED:
        for condition in CONDITIONS:
            s = results["surfaces"].get(surface, {}).get(condition)
            if not s:
                continue
            lines.append(f"| {surface} | {condition} | {s['ok']}/{s['n']} | {triple(s, 'commit_ms')} | {triple(s, 'first_content_ms')} | "
                         f"{triple(s, 'final_ms')} | {s['over'] or 'ok'} |")
    lines += ["", "load average per condition: " + ", ".join(f"{c} {v}" for c, v in results.get("load_avg", {}).items())]
    return "\n".join(lines)


def write_results(results):
    table = markdown(results)
    print("RIGHT-PANE-OPEN-TABLE-BEGIN\n" + table + "\nRIGHT-PANE-OPEN-TABLE-END", flush=True)
    results["table"] = table
    if opts.json:
        os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
        with open(opts.json, "w") as handle:
            json.dump(results, handle, indent=1)
    if opts.md:
        with open(opts.md, "w") as handle:
            handle.write(table + "\n")
    return table


# ---------------------------------------------------------------------------------------------

def run_surfaces(run, chat, condition, results, rounds):
    for surface in WANTED:
        records = results["raw"].setdefault(surface, {}).setdefault(condition, [])
        for index in range(rounds):
            record = measure(run, chat, surface, f"{condition}-{surface}-{len(records)}", len(records))
            records.append(record)
            say(f"right-pane-open: {condition} {surface} {len(records) - 1}: commit_ms={record.get('commit_ms')} "
                f"first_content_ms={record.get('first_content_ms')} final_ms={record.get('final_ms')} "
                f"blank={record.get('blank_frames')} between={record.get('between_frames')}"
                + (f" error={record['error']}" if record.get("error") else ""))


def main():
    root = tempfile.mkdtemp(prefix="right-pane-open-")
    results = {"host": socket.gethostname(), "ncpu": NCPU, "app": APP,
               "model": subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip(),
               "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "surfaces": {}, "raw": {}, "conditions": {}}
    signal.signal(signal.SIGTERM, bm.interrupted)
    load = Load(root)
    run = None
    try:
        repo = make_repo(root)
        say("right-pane-open: seeding")
        home, chats, meta_keys = seed(root, repo)
        results["seed"] = {"subagents": SUBAGENTS, "meta_keys": meta_keys}
        for condition in CONDITIONS:
            if run:
                run.end()
            wipe_state(APP)
            run = Run(home)
            run.launch()
            if not results.get("app_version"):
                results["app_version"] = (run.app.identify() or {}).get("version")
            time.sleep(5)  # test script: let launch work end before the chat opens
            chat = Chat(run)
            chat.open(chats[condition])
            info = {}
            if condition == "stress":
                stress = chat.stress
                stress.busy_where = "elsewhere"
                started = time.monotonic()
                stress.build_background()
                stress.build_measured()
                info["stress_build_s"] = round(time.monotonic() - started, 1)
                info["busy_terminals"] = len(getattr(stress, "busy", []))
                chat.show()
                load.start(run.sock)
                time.sleep(opts.settle)  # test script: the load reaches steady state
            if condition == "restart":
                for restart in range(opts.restarts):
                    run.quit()
                    run.launch()
                    chat = Chat(run)
                    chat.find()
                    info.setdefault("restored_panes", []).append(chat.pane)
                    run_surfaces(run, chat, condition, results, 1)
            else:
                run_surfaces(run, chat, condition, results, opts.runs)
            results["load_avg"] = {**results.get("load_avg", {}), condition: load_average()}
            results["conditions"][condition] = info
            load.stop()
            for surface in WANTED:
                results["surfaces"].setdefault(surface, {})[condition] = summarize(results["raw"].get(surface, {}).get(condition, []))
            time.sleep(3)  # test script: the machine settles between conditions
    finally:
        load.stop()
        try:
            write_results(results)  # before teardown: a teardown that stalls never loses the run
        except Exception as error:  # noqa: BLE001 - a report that fails must not hide the run's own error
            say(f"right-pane-open: writing the results failed: {error!r}")
        if run:
            run.end()
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
