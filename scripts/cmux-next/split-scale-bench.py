#!/usr/bin/env python3
"""Split and pane transitions across a matrix of splits, pane content and workspaces (instant-splits goal).

Leo, 2026-11-08: "these NEED to be PERFECT NO MATTER HOW MANY SPLITS THERE ARE AND WHAT CONTENT IS IN PANES AND HOW
MANY WORKSPACES/PROCESSES THERE ARE." So the same gestures run in every cell of

  splits      --splits 1,4,9        panes in the measured workspace (1, a 2 x 2 grid, a 3 x 3 grid)
  content     --contents            what every measured pane shows:
                empty       a fresh terminal
                scrollback  a terminal with --scrollback lines that keeps streaming output (about 2,000 lines/s)
                browser     a Chromium page that holds still: 2,500 laid-out cards with tables and text (HeavyPages)
                chat        an agent chat with a --chat-turns turn transcript (seeded once, a copy per pane)
  workspaces  --workspaces 1,10,30  workspaces in the window, the measured one included (checked before each
                                    cell); every other one runs a terminal that prints a line every 20 ms

and in each cell every transition of --transitions, each sent through the real input path (keys through
`debug.new_tab frame_strip`'s key path, the divider drag as synthesized mouse events on the divider):

  split_right   Cmd-D on the top-left pane                 close_right   Cmd-W on the pane it made
  split_down    Cmd-Shift-D on the top-left pane           close_down    Cmd-W on the pane it made
  bottom_open   Cmd-Shift-D on the bottom-left pane: a pane grows up from the window's bottom edge
  bottom_close  Cmd-W on it: the pane above grows back down (Leo's 2026-11-08 recording: a page above a terminal)
  divider_drag  the first divider dragged 120 pt left (and back, untimed); cells with one pane have none
  side_open     Cmd-B: the sidebar opens                      side_close    Cmd-B again
                (Toggle Sidebar, the window's sidebar beside the panes; it needs no chat or tab. NEXT has no right
                sidebar any more, so Option-Cmd-B moved no pane in any cell. Which way the toggle went is read from
                the trace's pane widths: a press that went the other way is dropped and the key pressed once more,
                and a press that moved nothing fails the round)

Per transition, from two recordings of the same gesture (split_scale_metrics.py has the definitions):

  first_frame_ms, settled_ms      input to the first and the last display-link tick whose layout moved (the trace,
                                  lined up with the input by frame_strip's `sent_host_s`); for static content (empty,
                                  chat) settled is no earlier than the composited window's settled frame
  frame_p50/p95/max_ms, dropped   display-link frame intervals while anything moved (`debug.motion trace_*`)
  blank_frames, partial_frames    content one flat color neither before nor final; content still painting after
                                  the panes landed (judged for empty, browser and chat panes; a streaming terminal
                                  changes every frame, so its cells are timed by the layout and judged on blank only)
  retargets                       a mover that reversed or sped up again mid-flight

Each number is the median over --rounds (blank, partial, retargets and frame max: the worst round). Targets: first
frame <= 16 ms, settled <= 120 ms, p95 <= 8.3 ms at 120 Hz (16.7 ms otherwise), 0 blank frames, 0 retargets, and the
cost flat across the matrix: per transition the worst cell's settled time within 1.2x of the smallest cell's
(1 split, empty, 1 workspace). The JSON has every cell, every round and the `worst` headline the goal check reads; the
table is printed between SPLIT-SCALE-TABLE-BEGIN and -END. `pass` needs every asked cell and transition measured,
no failed round and no failed cell.

Usage:
  split-scale-bench.py --app APP [--splits 1,4,9] [--contents empty,scrollback,browser,chat] [--workspaces 1,10,30]
                       [--transitions ...] [--rounds 3] [--quick] [--json FILE] [--md FILE] [--vdisplay 120]
Fleet (a bench build of REF, on an owned Mac with a console, 120 Hz virtual display):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \\
    --ref REF --artifact artifacts/split-spring/report.json --arg=--suite=split-scale --arg=--config=bench \\
    --arg=--vdisplay=120

The move family (--moves, fleet: --arg=--suite=split-move): a pane or a tab going from one split to another, forth and
back, in a row of 2, 3 or 4 panes (--move-shapes half,third,quarter) of each --contents (also `newtab`, the New Tab
page), one workspace. Each move is one key through the same key path (the bench binds the Move Tab to Pane and Swap
Pane actions in its scratch config) or, for pane_drag, mouse events on the pane's tab bar:

  move_to_pane          the pane's shown tab to the pane on its right (Move Tab to Pane Right); _back: to the left again
  move_to_split_down    that tab to a new split below its pane (the same action with no pane that way); _back: up
                        again, which closes the pane it left
  move_to_split_right   that tab, in the last pane, to a new split on the window's right; _back: left again
  swap                  the first pane swapped with its right neighbour (Swap Pane Right); _back: Swap Pane Left
  pane_drag             the first pane dragged by its tab bar (Option-drag) to the right edge of the last pane; _back:
                        dragged to the left edge of the first

Each is judged by split_move_metrics.py: the frame that first shows the new layout must show all of it (no mover
that starts late, moves again or steps back, no content off its pane, no reversal, no blank or partial frame, no tab
made again). The table is printed between SPLIT-MOVE-TABLE-BEGIN and -END; --gate exits 1 when a move fails.

Needs a bench or DEBUG build (the debug.* control methods). Kills only what it started: the app it launched
(bench_memory.end_bundle of its bundle) and the seeding daemon.
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
import tarfile
import tempfile
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_memory as bm  # noqa: E402
import idle_cost_load as icl  # noqa: E402
import split_move_metrics as smm  # noqa: E402
import split_scale_metrics as ssm  # noqa: E402
from bench_power import wipe_state  # noqa: E402

TRANSITIONS = ("split_right", "close_right", "split_down", "close_down", "bottom_open", "bottom_close",
               "divider_drag", "side_open", "side_close")
CONTENTS = ("empty", "scrollback", "browser", "chat", "newtab")
MOVES = ("move_to_pane", "move_to_split_down", "move_to_split_right", "swap", "pane_drag")
MOVE_SHAPES = {"half": 2, "third": 3, "quarter": 4}
MOVE_CONTENTS = "newtab,chat,empty,browser"
# Content whose pixels hold still between inputs: its composited settle is judged too (split_scale_metrics.transition).
STATIC_CONTENTS = ("empty", "browser", "chat", "newtab")
CMD_D = {"key": "d", "modifiers": ["command"]}
CMD_SHIFT_D = {"key": "d", "modifiers": ["command", "shift"]}
CMD_W = {"key": "w", "modifiers": ["command"]}
CMD_B = {"key": "b", "modifiers": ["command"]}
# The move family's keys: actions with no default shortcut, bound in the bench's scratch config (CONFIG).
MOVE_MODS, SWAP_MODS = ["control", "option", "command"], ["control", "option", "shift"]
MOVE_KEYS = {"left": "h", "down": "j", "up": "k", "right": "l"}
MOVE_ACTIONS = {"left": "moveSurfaceToPaneLeft", "down": "moveSurfaceToPaneDown", "up": "moveSurfaceToPaneUp",
                "right": "moveSurfaceToPaneRight"}
SWAP_ACTIONS = {"left": "swapPaneLeft", "right": "swapPaneRight"}
# The scrollback terminal: --scrollback numbered lines, then about 2,000 lines a second until the cell ends.
SCROLL_COMMAND = ("seq -f 'scrollback %g lorem ipsum dolor sit amet consectetur adipiscing elit' 1 {n}; "
                  "while :; do seq -f \"stream %g $RANDOM $RANDOM $RANDOM output\" 1 20; sleep 0.01; done\r")

parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
parser.add_argument("--app", required=True)
parser.add_argument("--tag", default="split-scale", help="split-spring.sh passes its tag; unused otherwise")
parser.add_argument("--out", help="split-spring.sh's artifact folder (the JSON goes to --json)")
parser.add_argument("--splits", default="1,4,9")
parser.add_argument("--contents", default=",".join(CONTENTS))
parser.add_argument("--workspaces", default="1,10,30")
parser.add_argument("--transitions", default=",".join(TRANSITIONS))
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--quick", action="store_true", help="smoke: 1 and 4 splits, empty and browser, 1 workspace, 1 round")
parser.add_argument("--scrollback", type=int, default=20000)
parser.add_argument("--chat-turns", type=int, default=300)
parser.add_argument("--strip-ms", type=float, default=900, help="how long each frame strip records after the input")
parser.add_argument("--strip-tolerance", type=float, default=ssm.TOLERANCE)
parser.add_argument("--settle", type=float, default=0.8, help="seconds between transitions (the last one's motion ends)")
parser.add_argument("--vdisplay", type=float, default=0,
                    help="a 1920 x 1200 virtual main display at this rate (perf-stress-session's helper); "
                         "0 measures on the host's display (split-spring.sh --vdisplay makes its own)")
parser.add_argument("--keep-frames", default="",
                    help="comma-separated prefixes of round labels (CELL-TRANSITION-ROUND, such as "
                         "'s1-browser-w30-bottom_open' or 's9'; 's1,s4,s9' is every round): those rounds' frames, "
                         "frame times and trace go to --out/frames.tar.gz, with an mp4 at the frames' own times when "
                         "ffmpeg is on PATH (prefixes, not globs: a fleet step's args take no '*')")
parser.add_argument("--moves", default="",
                    help=f"the move family instead of the transitions: 'all' or a comma list of {','.join(MOVES)}")
parser.add_argument("--move-shapes", default=",".join(MOVE_SHAPES), help="rows of 2, 3 and 4 panes")
parser.add_argument("--gate", action="store_true", help="exit 1 when a move fails its verdict (--moves)")
parser.add_argument("--json")
parser.add_argument("--md")
opts, _unknown = parser.parse_known_args()
APP = os.path.realpath(opts.app.rstrip("/"))
if opts.quick:
    opts.splits, opts.contents, opts.workspaces, opts.rounds = "1,4", "empty,browser", "1", 1
SPLITS = [int(s) for s in opts.splits.split(",") if s.strip()]
WANTED_CONTENTS = [c.strip() for c in opts.contents.split(",") if c.strip()]
WORKSPACES = sorted(int(w) for w in opts.workspaces.split(",") if w.strip())
WANTED = [t.strip() for t in opts.transitions.split(",") if t.strip()]
WANTED_MOVES = list(MOVES) if opts.moves.strip() == "all" else [m.strip() for m in opts.moves.split(",") if m.strip()]
WANTED_SHAPES = [s.strip() for s in opts.move_shapes.split(",") if s.strip()]
if WANTED_MOVES and opts.contents == ",".join(CONTENTS):
    WANTED_CONTENTS = MOVE_CONTENTS.split(",")
elif not WANTED_MOVES and opts.contents == ",".join(CONTENTS):
    WANTED_CONTENTS = [c for c in CONTENTS if c != "newtab"]  # the transition matrix keeps its four contents
for name, given, known in (("content", WANTED_CONTENTS, CONTENTS), ("transition", WANTED, TRANSITIONS),
                           ("move", WANTED_MOVES, MOVES), ("move shape", WANTED_SHAPES, tuple(MOVE_SHAPES))):
    bad = [g for g in given if g not in known]
    if bad:
        raise SystemExit(f"split-scale: unknown {name} {bad}; use {','.join(known)}")
if any(s not in (1, 4, 9) for s in SPLITS):
    raise SystemExit("split-scale: --splits takes 1, 4 and 9 (a 1 x 1, 2 x 2 or 3 x 3 grid)")
CONFIG = {"workspaces": {"newPlacement": "bottom"}}
if WANTED_MOVES:
    CONFIG["shortcuts"] = {"bindings": {
        **{MOVE_ACTIONS[way]: "ctrl+opt+cmd+" + key for way, key in MOVE_KEYS.items()},
        **{SWAP_ACTIONS[way]: "ctrl+opt+shift+" + MOVE_KEYS[way] for way in SWAP_ACTIONS}}}


def say(*parts):
    print(" ".join(str(p) for p in parts), flush=True)


def load_stress():
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


STRESS = load_stress()


# ---------------------------------------------------------------------------------------------
# The chat content: one transcript written by acpmux on a seeding daemon, a copy per pane in the app's store.

def seed_chats(root, copies):
    """`copies` chat ids in a fresh acpmux home, each a copy of one --chat-turns turn chat. Returns (home, ids)."""
    agent = os.path.join(HERE, "chat_open_agent.py")
    peer = icl.PeerDaemon(APP, root, agent)
    peer.start()
    try:
        session = peer.new_chat("turn: 0")
        if not session:
            raise SystemExit("split-scale: the seeding daemon made no chat")
        for i in range(1, opts.chat_turns):
            sent = peer.acpmux("send", session, f"turn: {i}", timeout=180)
            if sent.returncode != 0:
                raise SystemExit(f"split-scale: seed turn {i}: {(sent.stdout + sent.stderr).strip()[-1000:]}")
    finally:
        peer.stop()
    template = icl.read_chat(peer.home, session)
    home = os.path.join(root, "acpmux")
    icl.private_dir(home)
    icl.private_dir(os.path.join(home, "sessions"))
    ids = []
    for index in range(copies):
        chat = str(uuid.uuid4())
        swap = lambda data, c=chat: data.replace(template["id"].encode(), c.encode())  # noqa: E731
        meta = json.loads(swap(template["meta"]))
        meta.update({"id": chat, "name": f"Split scale {index}", "title": f"Split scale {index}",
                     "updatedAt": int(time.time() * 1000), "status": "idle"})
        folder = os.path.join(home, "sessions", chat)
        icl.private_dir(folder)
        icl.private_dir(os.path.join(folder, "events"))
        icl.private_write(os.path.join(folder, "session.json"), json.dumps(meta, indent=2).encode())
        for name, data in template["events"].items():
            icl.private_write(os.path.join(folder, "events", name), swap(data))
        ids.append(chat)
    return home, ids


# ---------------------------------------------------------------------------------------------
# The browser content: a heavy page that holds still (thousands of laid-out cards, tables and long text, no animation),
# so a pane that grows into an area its page has not painted yet shows as partial frames, not as page motion.

class HeavyPages:
    """Local pages for the browser panes, served from 127.0.0.1 (no network); `url()` and `close()` as
    perf-stress-session's Pages, so Stress.add_tab opens them."""

    def __init__(self):
        cards = "".join(f"<div class='c'><b>Card {i}</b><p>{'lorem ipsum dolor sit amet ' * 6}</p>"
                        f"<table>{'<tr><td>a</td><td>b</td><td>c</td></tr>' * 3}</table></div>" for i in range(2500))
        self.body = ("<!doctype html><meta charset='utf-8'><title>split-scale heavy page</title>"
                     "<style>body{margin:0;font:14px -apple-system,sans-serif;background:#eef0f4}"
                     ".g{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:8px;padding:12px}"
                     ".c{border-radius:8px;padding:8px;background:linear-gradient(135deg,#c9d4e8,#e8d4c9);"
                     "box-shadow:0 1px 3px #0003}td{border:1px solid #9ab;padding:2px}</style>"
                     f"<div class='g'>{cards}</div>").encode()
        self.server = None
        self.next = 0

    def url(self):
        import http.server
        import threading
        if self.server is None:
            body = self.body

            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):  # noqa: N802
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

                def log_message(self, *args):
                    pass
            self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
        self.next += 1
        return f"http://127.0.0.1:{self.server.server_address[1]}/{self.next}"

    def close(self):
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
            self.server = None


# ---------------------------------------------------------------------------------------------
# The app.

class Run:
    def __init__(self, env):
        self.env = dict(env)
        self.pid = self.sock = self.scratch = None

    def launch(self):
        self.pid, self.sock, self.scratch = bm.launch(APP, CONFIG, dict(self.env))
        self.app = bm.App(APP, self.sock)
        deadline = time.monotonic() + 60
        while not self.app.ping() and time.monotonic() < deadline:
            time.sleep(0.5)  # test script: the app's socket answers once it runs
        self.stress = STRESS.Stress(lambda m, p=None, timeout=60: self.rpc(m, p, timeout), log=say, busy_where="elsewhere")
        self.stress.pages = HeavyPages()

    def rpc(self, method, params=None, timeout=40):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                conn.settimeout(timeout)
                conn.connect(self.sock)
                conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
                buf = b""
                while not buf.endswith(b"\n"):
                    chunk = conn.recv(1 << 22)
                    if not chunk:
                        break
                    buf += chunk
            answer = json.loads(buf or b"{}")
        except (OSError, ValueError) as error:
            return {"error": f"{method}: {error}"}
        return {"error": answer["error"]} if answer.get("error") else answer.get("result")

    def end(self):
        if getattr(self, "stress", None):
            self.stress.pages.close()
        bm.end_bundle(APP)
        if self.scratch:
            shutil.rmtree(self.scratch, ignore_errors=True)


# ---------------------------------------------------------------------------------------------
# The cell's workspace.

def grid(stress, workspace, count):
    """`count` panes (1, 2 x 2, 3 x 3) in `workspace`, split by id; returns them as rows of columns [[top, ...], ...]
    by column, top first."""
    first = STRESS.wait(lambda: (stress.panes(stress.workspace(workspace)) or [{}])[0].get("id"), 20)
    side = {1: 1, 4: 2, 9: 3}[count]
    columns = [[first]]
    for _ in range(side - 1):
        # Each new column from the widest one so far (the first), then equalizeSplits evens them.
        made = stress.split(workspace, columns[-1][0], "splitRight")
        if not made:
            raise RuntimeError(f"splitRight made no pane: {stress.refusals[-2:]}")
        columns.append([made])
    for column in columns:
        for _ in range(side - 1):
            made = stress.split(workspace, column[-1], "splitDown")
            if not made:
                raise RuntimeError(f"splitDown made no pane: {stress.refusals[-2:]}")
            column.append(made)
    stress.action("equalizeSplits", target=f"pane:{first}", focus=False)
    return columns


def show_tab(run, workspace, pane, kinds):
    """Selects `pane`'s newest tab of `kinds` (tab.focus) and waits until the pane shows it: a tab that exists but is
    not selected is not what the cell measures."""
    stress = run.stress
    tab = STRESS.wait(lambda: next((t.get("id") for t in reversed(stress.tabs(workspace, pane))
                                    if t.get("kind") in kinds and not STRESS.provisional(t)), None), 20, step=0.1)
    if not tab:
        raise RuntimeError(f"no {sorted(kinds)} tab in pane {pane}")
    # With focus: tab.focus reveals only under the run's view-change permission, which focus=False withholds
    # (TabHandlers.reveal); the measured workspace is the shown one, so focusing in it moves nothing else.
    stress.action("tab.focus", target=f"tab:{tab}")
    # The pane carries its shown tab as `selected_tab`; tabs have no selected flag (ControlTopology+JSON.swift).
    shown = lambda: next((p.get("selected_tab") for p in stress.panes(stress.workspace(workspace)) if p.get("id") == pane), None)
    if not STRESS.wait(lambda: shown() == tab, 10, step=0.05):
        raise RuntimeError(f"pane {pane} never showed its {sorted(kinds)} tab {tab}: {stress.refusals[-2:]}")


def fill(run, workspace, pane, content, chats):
    """Puts `content` in `pane`, shown (its selected tab); returns what it started (a busy terminal's tab id, the chat
    id)."""
    stress = run.stress
    if content == "empty":
        return None
    if content == "newtab":
        reply = stress.action("newTab.page", target=f"pane:{pane}", focus=False)
        if isinstance(reply, dict) and reply.get("error"):
            raise RuntimeError(f"newTab.page: {str(reply['error'])[:300]}")
        show_tab(run, workspace, pane, {"page", "conversation", "browser"})
        return None
    if content == "browser":
        stress.add_tab(workspace, pane, "chromium")
        show_tab(run, workspace, pane, STRESS.topology_kinds("chromium", False))
        return None
    if content == "scrollback":
        tab = next((t.get("id") for t in stress.settled_tabs(workspace, pane) if t.get("kind") == "terminal"), None)
        if not tab:
            raise RuntimeError(f"pane {pane} has no terminal for the scrollback")
        stress.send(tab, SCROLL_COMMAND.format(n=opts.scrollback))
        return tab
    chat = chats.pop() if chats else None
    if not chat:
        raise RuntimeError("no seeded chat left for a chat pane")
    reply = stress.action("agent.openSessionTab", {"session": chat}, target=f"pane:{pane}", focus=False)
    if isinstance(reply, dict) and reply.get("error"):
        raise RuntimeError(f"agent.openSessionTab: {str(reply['error'])[:300]}")
    show_tab(run, workspace, pane, {"conversation"})
    return chat


def background(run, count, measured):
    """Makes the window hold exactly `count` workspaces besides Home, `measured` among them: the others each run a
    terminal that prints a line every 20 ms; extra ones are closed, missing ones made. Checks the count before the
    cell is measured. Home can't be closed and the topology carries no home flag, so a workspace whose close is
    refused is remembered as Home and left out of the count (it stays idle, as a user's Home does)."""
    stress = run.stress
    busy = getattr(run, "busy_workspaces", set())
    home = getattr(run, "home_workspaces", set())
    run.home_workspaces = home
    # One pass closes, makes or finds Home once: a window restored with many workspaces needs one pass for each.
    for _ in range(len(stress.workspaces()) + count + 8):
        others = [w["id"] for w in stress.workspaces() if w["id"] != measured and w["id"] not in home]
        if len(others) > count - 1:
            extra = next((w for w in others if w not in busy), others[-1])
            reply = stress.action("closeWorkspace", {"confirm": True}, target=f"workspace:{extra}", focus=False)
            if not STRESS.wait(lambda: stress.workspace(extra) is None, 15, step=0.1):
                if isinstance(reply, dict) and reply.get("error") and extra not in home:
                    home.add(extra)  # refused: Home (the launch workspace)
                    busy.discard(extra)
                    continue
                raise RuntimeError(f"closeWorkspace left {extra}: {stress.refusals[-2:]}")
            busy.discard(extra)
        elif len(others) < count - 1:
            if not stress.new_workspace():
                raise RuntimeError(f"no background workspace {len(others) + 1}: {stress.refusals[-2:]}")
        else:
            break
    else:
        raise RuntimeError(f"the window never held {count} workspaces: {stress.refusals[-2:]}")
    for workspace in others:
        if workspace in busy:
            continue
        pane = STRESS.wait(lambda w=workspace: (stress.panes(stress.workspace(w)) or [{}])[0].get("id"), 20)
        tab = next((t.get("id") for t in stress.settled_tabs(workspace, pane) if t.get("kind") == "terminal"), None)
        if not tab:  # a workspace that opened on a page (the launch one can): give it the busy terminal
            stress.add_tab(workspace, pane, "terminal")
            tab = next((t.get("id") for t in stress.settled_tabs(workspace, pane) if t.get("kind") == "terminal"), None)
        if not tab:
            raise RuntimeError(f"background workspace {workspace} has no terminal to keep busy: {stress.refusals[-2:]}")
        stress.make_busy(tab)
        busy.add(workspace)
    run.busy_workspaces = busy
    have = len([w for w in stress.workspaces() if w["id"] not in home])
    if have != count:
        raise RuntimeError(f"the cell has {have} workspaces, not {count}")
    stress.show(measured)


# ---------------------------------------------------------------------------------------------
# One transition: a frame strip of the gesture with the motion trace around it.

def record(run, gesture, label, content="focused", static=True):
    strip, trace = record_raw(run, gesture, label, content)
    return ssm.transition(strip, trace, opts.strip_tolerance, static=static)


def record_raw(run, gesture, label, content="focused"):
    """(strip, trace) of one gesture: the frame strip's reply and the motion trace around it (either an error dict)."""
    folder = os.path.join(tempfile.gettempdir(), f"split-scale-{os.getpid()}", label)
    trace_path = os.path.join(folder, "trace.json")
    os.makedirs(folder, exist_ok=True)
    params = {"action": "frame_strip", **gesture, "above": True, "duration_ms": opts.strip_ms, "dir": folder,
              "tolerance": opts.strip_tolerance}
    if content == "none":
        params["content"] = "none"
    run.rpc("debug.motion", {"action": "trace_start"})
    strip = run.rpc("debug.new_tab", params, timeout=opts.strip_ms / 1000 + 90) or {}
    stopped = run.rpc("debug.motion", {"action": "trace_stop", "path": trace_path}) or {}
    trace = {"error": stopped.get("error")} if stopped.get("error") else {"error": "trace never written"}
    if STRESS.wait(lambda: os.path.exists(trace_path), 10, step=0.05):
        try:
            with open(trace_path) as handle:
                trace = json.load(handle)
        except (OSError, ValueError) as error:
            trace = {"error": f"trace: {error}"}
    keep(label, folder, strip)
    shutil.rmtree(folder, ignore_errors=True)
    key = strip.get("key") if isinstance(strip.get("key"), dict) else {}
    if key.get("error"):
        strip = {"error": f"input: {key['error']}"}
    return strip, trace


KEEP = [p.strip() for p in opts.keep_frames.split(",") if p.strip()]


def keep(label, folder, strip):
    """A --keep-frames round: its frames, the strip's per-frame times (strip.json) and the trace, kept under
    --out/frames/LABEL, with frames.mp4 showing each frame for as long as the screen held it."""
    if not opts.out or not any(label.startswith(p) for p in KEEP):
        return
    dest = os.path.join(opts.out, "frames", label)
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(folder, dest)
    with open(os.path.join(dest, "strip.json"), "w") as handle:
        json.dump(strip, handle, indent=1)
    frames = [f for f in strip.get("frames") or [] if isinstance(f, dict) and f.get("file")
              and isinstance(f.get("ms"), (int, float)) and os.path.exists(os.path.join(dest, f["file"]))]
    if not frames or not shutil.which("ffmpeg"):
        return
    # The concat demuxer's durations are the gaps between frames, so the clip plays at the screen's own pace.
    lines = []
    for here, after in zip(frames, frames[1:] + [None]):
        gap = ((after["ms"] - here["ms"]) if after else 100) / 1000
        lines += [f"file '{here['file']}'", f"duration {max(gap, 0.001):.4f}"]
    lines.append(f"file '{frames[-1]['file']}'")
    with open(os.path.join(dest, "frames.txt"), "w") as handle:
        handle.write("\n".join(lines) + "\n")
    try:
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", "frames.txt",
                        "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-fps_mode", "vfr", "-pix_fmt", "yuv420p",
                        "frames.mp4"], cwd=dest, capture_output=True, timeout=120, check=False)
    except subprocess.TimeoutExpired:
        say(f"split-scale: ffmpeg took over 120 s on {label}; its frames are kept without a clip")


def pack_frames():
    """--out/frames.tar.gz: every kept round and report.json, one file a step can return."""
    frames = os.path.join(opts.out or "", "frames")
    if not KEEP or not opts.out or not os.path.isdir(frames):
        return
    with tarfile.open(os.path.join(opts.out, "frames.tar.gz"), "w:gz") as tar:
        tar.add(frames, arcname="frames")
        if opts.json and os.path.exists(opts.json):
            tar.add(opts.json, arcname="report.json")


def side_toggle(run, label, want, static):
    """Cmd-B recorded as the sidebar's `want` ("opened" or "closed"). The key toggles, and the app keeps the
    sidebar's visibility across launches, so a sidebar left hidden by an earlier run or a key that missed would swap
    open and close for every later cell: the trace says which way the panes went (ssm.side_way), and a press that went
    the other way restored `want`'s starting state, so it is pressed again and that press is the record. A press that
    moved no pane is the round's error."""
    for attempt in range(2):
        row = record(run, CMD_B, label if not attempt else f"{label}-again", content="none", static=static)
        way = ssm.side_way(row)
        if way == want:
            if ssm.side_returned(row):
                problem = f"Cmd-B {way} the sidebar and the panes went back to their width"
                row["error"] = f"{row['error']}; {problem}" if row.get("error") else problem
            return row
        if way is None:
            problem = "Cmd-B moved no pane (the sidebar neither opened nor closed)"
            row["error"] = f"{row['error']}; {problem}" if row.get("error") else problem
            return row
        time.sleep(opts.settle)  # test script: the wrong-way toggle's motion ends before the press that is timed
    row["error"] = f"Cmd-B {way} the sidebar twice in a row, not {want}"
    return row


def pane_ids(run, workspace):
    return [p["id"] for p in run.stress.panes(run.stress.workspace(workspace))]


def new_pane(run, workspace, before):
    return STRESS.wait(lambda: next((p for p in pane_ids(run, workspace) if p not in before), None), 5, step=0.05)


def run_cell(run, workspace, columns, results, cell, content):
    """Every wanted transition in this cell, --rounds times. Each pair (split, close) restores the layout it found."""
    stress = run.stress
    top_left, bottom_left = columns[0][0], columns[0][-1]
    out = results["raw"].setdefault(cell, {})
    static = content in STATIC_CONTENTS

    def add(name, row):
        out.setdefault(name, []).append(row)

    def pair(open_name, close_name, pane, gesture, rnd):
        if open_name not in WANTED and close_name not in WANTED:
            return
        stress.focus_pane(pane)
        time.sleep(opts.settle)  # test script: the focus move's own motion ends before the timed key
        before = pane_ids(run, workspace)
        row = record(run, gesture, f"{cell}-{open_name}-{rnd}", static=static)
        made = new_pane(run, workspace, before)
        if not made:
            row["error"] = "the key made no pane"
        if open_name in WANTED:
            add(open_name, row)
        if not made:
            return
        time.sleep(opts.settle)  # test script: the open's motion ends before the close
        stress.focus_pane(made)
        time.sleep(opts.settle)  # test script: the last gesture's motion ends
        row = record(run, CMD_W, f"{cell}-{close_name}-{rnd}", static=static)
        gone = STRESS.wait(lambda: made not in pane_ids(run, workspace), 5, step=0.05)
        if not gone:
            row["error"] = "Cmd-W left the pane"
            stress.action("closePane", target=f"pane:{made}", focus=False)  # untimed: the next round's layout
            STRESS.wait(lambda: made not in pane_ids(run, workspace), 5, step=0.05)
        if close_name in WANTED:
            add(close_name, row)
        time.sleep(opts.settle)  # test script: the last gesture's motion ends

    for rnd in range(opts.rounds):
        pair("split_right", "close_right", top_left, CMD_D, rnd)
        pair("split_down", "close_down", top_left, CMD_SHIFT_D, rnd)
        pair("bottom_open", "bottom_close", bottom_left, CMD_SHIFT_D, rnd)
        if "divider_drag" in WANTED and len(pane_ids(run, workspace)) > 1:
            stress.focus_pane(top_left)
            time.sleep(opts.settle)  # test script: the last gesture's motion ends
            # Diagonal: "first" is the divider area lowest in the window, a column's row divider as often as a column
            # divider, and a drag along a divider moves nothing; this moves either kind.
            add("divider_drag", record(run, {"gesture": "mouse", "mouse": {"action": "drag", "divider": "first",
                                                                            "by_x": -120, "by_y": -60, "steps": 30}},
                                       f"{cell}-divider_drag-{rnd}", static=static))
            time.sleep(opts.settle)  # test script: the last gesture's motion ends
            run.rpc("debug.mouse", {"action": "drag", "divider": "first", "by_x": 120, "by_y": 60, "steps": 30})  # untimed: back
            time.sleep(opts.settle)  # test script: the last gesture's motion ends
        if "side_open" in WANTED or "side_close" in WANTED:
            stress.focus_pane(top_left)
            time.sleep(opts.settle)  # test script: the last gesture's motion ends
            opened = side_toggle(run, f"{cell}-side_open-{rnd}", "opened", static)
            if "side_open" in WANTED:
                add("side_open", opened)
            time.sleep(opts.settle)  # test script: the last gesture's motion ends
            closed = side_toggle(run, f"{cell}-side_close-{rnd}", "closed", static)
            if "side_close" in WANTED:
                add("side_close", closed)
            time.sleep(opts.settle)  # test script: the last gesture's motion ends


def build_cell(run, splits, content, chats):
    """The cell's measured workspace, shown, its panes filled. Returns (workspace, columns)."""
    stress = run.stress
    workspace = stress.new_workspace()
    if not workspace:
        raise RuntimeError(f"no measured workspace: {stress.refusals[-2:]}")
    stress.show(workspace)
    columns = grid(stress, workspace, splits)
    for column in columns:
        for pane in column:
            fill(run, workspace, pane, content, chats)
    stress.show(workspace)
    time.sleep(3 if content in ("browser", "chat") else 1.5)  # test script: pages and transcripts draw before timing
    return workspace, columns


def close_cell(run, workspace):
    """Closes the cell's workspace; returns why it stayed, or None. A workspace left behind is background load the
    next cells never asked for, so the caller records it as the cell's error (the run cannot pass)."""
    run.stress.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}", focus=False)
    left = None
    if not STRESS.wait(lambda: run.stress.workspace(workspace) is None, 15, step=0.1):
        left = f"closeWorkspace left {workspace}: {run.stress.refusals[-2:]}"
        say(f"split-scale: {left}")
    time.sleep(1)  # test script: the close's own work ends before the next cell builds
    return left


# ---------------------------------------------------------------------------------------------
# The move family: a tab or a pane from one split to another, forth and back.

def row_of(stress, workspace, count):
    """`count` panes side by side in `workspace`, equal widths, left to right."""
    first = STRESS.wait(lambda: (stress.panes(stress.workspace(workspace)) or [{}])[0].get("id"), 20)
    panes = [first]
    for _ in range(count - 1):
        made = stress.split(workspace, panes[-1], "splitRight")
        if not made:
            raise RuntimeError(f"splitRight made no pane: {stress.refusals[-2:]}")
        panes.append(made)
    stress.action("equalizeSplits", target=f"pane:{first}", focus=False)
    return panes


def workspace_tabs(run, workspace):
    """{tab id: pane id} of `workspace`."""
    return {t.get("id"): p.get("id") for p in run.stress.panes(run.stress.workspace(workspace)) for t in p.get("tabs") or []}


def pane_frames(run):
    """Each shown pane host's frame [x, y, width, height] (window points, top-left origin), left to right then top to
    bottom, read from a few ticks of the motion trace."""
    run.rpc("debug.motion", {"action": "trace_start", "targets": ["panes"]})
    time.sleep(0.1)  # test script: a few display frames
    trace = run.rpc("debug.motion", {"action": "trace_stop"}) or {}
    rows = next((s.get("panes") for s in reversed(trace.get("samples") or []) if s.get("panes")), None) or []
    frames = [[float(v) for v in row[7:11]] for row in rows if isinstance(row, list) and len(row) >= 11]
    return sorted(frames, key=lambda f: (round(f[0]), round(f[1])))


def move_row(run, workspace, gesture, label, static, expect=None, content="focused"):
    """One recorded move, judged (split_move_metrics.move). `expect`: a check that the move happened (returns a
    truthy value once it did); a move that did not happen is the round's error."""
    before = workspace_tabs(run, workspace)
    strip, trace = record_raw(run, gesture, label, content)
    done = STRESS.wait(expect, 5, step=0.05) if expect else True
    row = smm.move(strip, trace, static=static, tabs_before=list(before), tabs_after=list(workspace_tabs(run, workspace)))
    if not done:
        row["error"] = "; ".join(filter(None, [row.get("error"), "the gesture moved nothing"]))
    elif not row.get("error") and row.get("commit_ms") is None and not (row.get("pixel_after_commit") or row.get("pixel_first_ms")):
        row["error"] = "nothing moved after the input"
    return row


def run_move_cell(run, workspace, panes, results, cell, content):
    """Every wanted move in this cell, forth and back, --rounds times; each pair leaves the layout as it found it."""
    stress = run.stress
    out = results["raw"].setdefault(cell, {})
    static = content in STATIC_CONTENTS
    first, last = panes[0], panes[-1]
    if content in ("empty", "scrollback"):
        for pane in {first, last}:  # a tab moves out of a pane that keeps one
            stress.add_tab(workspace, pane, "terminal")
        time.sleep(opts.settle)  # test script: the new tabs draw
    # The tab that moves: the first pane's shown tab (the cell's content).
    moving = next((p.get("selected_tab") for p in stress.panes(stress.workspace(workspace)) if p.get("id") == first), None)
    if not moving:
        raise RuntimeError(f"pane {first} shows no tab to move")

    def add(name, row):
        out.setdefault(name, []).append(row)
        say(f"  {cell} {name}: " + json.dumps({k: row.get(k) for k in ("commit_ms", "rest_ms", "frames_to_rest",
            "moved_after_commit_frames", "content_off_pane", "reversals", "pixel_after_commit_ms", "blank_frames",
            "partial_frames", "reloads", "error")}))

    def where():
        return workspace_tabs(run, workspace).get(moving)

    def aim(pane=None):
        """The moving tab shown and focused (or `pane` focused), and the last motion over."""
        if pane:
            stress.focus_pane(pane)
        else:
            stress.action("tab.focus", target=f"tab:{moving}")
        time.sleep(opts.settle)  # test script: the focus move's own motion ends before the timed key

    def key(way, mods=MOVE_MODS):
        return {"key": MOVE_KEYS[way], "modifiers": mods}

    def hop(way, until):
        """Untimed: the moving tab one pane `way` (the action the key runs), until `until()`."""
        for _ in range(len(panes) + 1):
            if until():
                return True
            stress.action(MOVE_ACTIONS[way], target=f"tab:{moving}")
            time.sleep(opts.settle)  # test script: the move's motion ends
        return bool(until())

    def tab_pair(name, forth, back, start, rnd):
        """The moving tab from `start` by key `forth` and back by key `back`, both recorded."""
        if name not in WANTED_MOVES:
            return
        if not hop("left" if start == first else "right", lambda: where() == start):
            add(name, {"error": f"the tab never reached pane {start}: {stress.refusals[-2:]}"})
            return
        aim()
        add(name, move_row(run, workspace, key(forth), f"{cell}-{name}-{rnd}", static, lambda: where() not in (None, start)))
        aim()
        add(f"{name}_back", move_row(run, workspace, key(back), f"{cell}-{name}_back-{rnd}", static, lambda: where() == start))
        if where() != start:  # untimed: the next move starts from the cell's layout
            stress.action(MOVE_ACTIONS[back], target=f"tab:{moving}")
            time.sleep(opts.settle)  # test script: the move's motion ends

    def drag(source, target, edge, along=0.72):
        """Mouse events: the pane at `source` dragged by its tab bar's empty space to the `edge` of the one at
        `target` (Option-drag: a plain press in the window's top row moves the window)."""
        to_x = target[0] + 14 if edge == "left" else target[0] + target[2] - 14
        return {"gesture": "mouse", "mouse": {"action": "drag", "x": source[0] + source[2] * along, "y": source[1] + 16,
                                              "to_x": to_x, "to_y": target[1] + target[3] * 0.5, "steps": 30,
                                              "modifiers": ["option"]}}

    for rnd in range(opts.rounds):
        tab_pair("move_to_pane", "right", "left", first, rnd)
        tab_pair("move_to_split_down", "down", "up", first, rnd)
        tab_pair("move_to_split_right", "right", "left", last, rnd)
        hop("left", lambda: where() == first)
        if "swap" in WANTED_MOVES:
            for name, way in (("swap", "right"), ("swap_back", "left")):
                aim(first)
                add(name, move_row(run, workspace, key(way, SWAP_MODS), f"{cell}-{name}-{rnd}", static))
        if "pane_drag" in WANTED_MOVES:
            for name, edge in (("pane_drag", "right"), ("pane_drag_back", "left")):
                time.sleep(opts.settle)  # test script: the last move's motion ends before the frames are read
                frames = pane_frames(run)
                if len(frames) < 2:
                    add(name, {"error": f"the trace showed {len(frames)} panes"})
                    continue
                source, target = (frames[0], frames[-1]) if edge == "right" else (frames[-1], frames[0])
                row = {}
                for along in (0.72, 0.5):  # the tab bar's empty space: right of the tabs, left of the pane's buttons
                    row = move_row(run, workspace, drag(source, target, edge, along), f"{cell}-{name}-{rnd}", static)
                    if "nothing moved" not in str(row.get("error") or ""):
                        break
                    run.rpc("debug.mouse", {"action": "up", "x": 4, "y": 4})  # untimed: no press stays down
                    time.sleep(opts.settle)  # test script: a drag that took nothing ends
                add(name, row)


def finish_moves(results):
    cells = {cell: {name: smm.summarize(rows) for name, rows in per.items()} for cell, per in results["raw"].items()}
    results["cells"] = cells
    static = lambda cell: cell.split("-", 1)[1] in STATIC_CONTENTS  # noqa: E731
    results["verdicts"] = {cell: {name: smm.verdict(s, static(cell)) for name, s in per.items()} for cell, per in cells.items()}
    pairs = [v for per in results["verdicts"].values() for v in per.values()]
    results["measured"], results["passing"] = len(pairs), sum(1 for v in pairs if v["pass"])
    wanted = [n for m in WANTED_MOVES for n in (m, f"{m}_back")]
    results["missing"] = [f"{shape}-{content} {name}" for shape in WANTED_SHAPES for content in WANTED_CONTENTS
                          for name in wanted if name not in cells.get(f"{shape}-{content}", {})]
    results["pass"] = bool(pairs) and results["passing"] == len(pairs) and not results["missing"] and not results["errors"]
    text = smm.table(results)
    print("SPLIT-MOVE-TABLE-BEGIN\n" + text + "\nSPLIT-MOVE-TABLE-END", flush=True)
    say(f"split-move: {results['passing']} of {len(pairs)} moves pass; missing {len(results['missing'])}; "
        f"cells that did not finish {len(results['errors'])}")
    if opts.json:
        with open(opts.json + ".tmp", "w") as handle:
            json.dump(results, handle, indent=1)
        os.replace(opts.json + ".tmp", opts.json)
    if opts.md:
        with open(opts.md, "w") as handle:
            handle.write("```\n" + text + "\n```\n")
    pack_frames()


def run_moves(run, results, chats):
    for shape in WANTED_SHAPES:
        for content in WANTED_CONTENTS:
            cell = f"{shape}-{content}"
            say(f"split-move: cell {cell}")
            workspace = None
            try:
                workspace = run.stress.new_workspace()
                if not workspace:
                    raise RuntimeError(f"no measured workspace: {run.stress.refusals[-2:]}")
                run.stress.show(workspace)
                panes = row_of(run.stress, workspace, MOVE_SHAPES[shape])
                for pane in panes:
                    fill(run, workspace, pane, content, chats)
                run.stress.show(workspace)
                time.sleep(3 if content in ("browser", "chat", "newtab") else 1.5)  # test script: pages draw before timing
                run_move_cell(run, workspace, panes, results, cell, content)
            except (Exception, SystemExit) as error:  # noqa: BLE001 - a cell that fails is its record; the next runs
                results["errors"][cell] = f"{type(error).__name__}: {str(error)[:500]}"
                say(f"split-move: {cell} did not finish: {results['errors'][cell]}")
            if workspace:
                left = close_cell(run, workspace)
                if left:
                    results["errors"][cell] = results["errors"].get(cell) or f"cleanup: {left}"


# ---------------------------------------------------------------------------------------------
# The report.

def finish(results):
    cells = {cell: {name: ssm.summarize(rows) for name, rows in per.items()} for cell, per in results["raw"].items()}
    results["cells"] = cells
    refresh = next((s.get("refresh_ms") for per in cells.values() for s in per.values() if s.get("refresh_ms")), None)
    results["refresh_ms"] = refresh
    results["verdicts"] = {cell: {name: ssm.verdict(s, refresh) for name, s in per.items()} for cell, per in cells.items()}
    results["flatness"] = ssm.flatness(cells)
    results["worst"] = ssm.headline(cells, results["flatness"], unsettled_ms=opts.strip_ms)
    pairs = [v for per in results["verdicts"].values() for v in per.values()]
    results["measured"] = len(pairs)
    results["passing"] = sum(1 for v in pairs if v["pass"])
    # Every cell the matrix asked for, with every wanted transition (a 1-pane cell has no divider to drag).
    missing = []
    for count in WORKSPACES:
        for splits in SPLITS:
            for content in WANTED_CONTENTS:
                cell = f"s{splits}-{content}-w{count}"
                wanted = [t for t in WANTED if not (t == "divider_drag" and splits == 1)]
                missing += [f"{cell} {t}" for t in wanted if t not in cells.get(cell, {})]
    results["missing"] = missing
    if results["errors"] or missing:
        results["worst"] = {**results["worst"], "incomplete": len(missing), "failed_cells": sorted(results["errors"])}
    results["pass"] = (bool(pairs) and results["passing"] == len(pairs) and not missing and not results["errors"]
                       and all(f["pass"] for f in results["flatness"].values()))
    text = ssm.table(results)
    print("SPLIT-SCALE-TABLE-BEGIN\n" + text + "\nSPLIT-SCALE-TABLE-END", flush=True)
    if opts.json:
        with open(opts.json + ".tmp", "w") as handle:
            json.dump(results, handle, indent=1)
        os.replace(opts.json + ".tmp", opts.json)
    if opts.md:
        with open(opts.md, "w") as handle:
            handle.write("```\n" + text + "\n```\n")
    pack_frames()


def main():
    root = tempfile.mkdtemp(prefix="split-scale-")
    results = {"host": socket.gethostname(), "app": APP, "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "model": subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip(),
               "matrix": {"splits": SPLITS, "contents": WANTED_CONTENTS, "workspaces": WORKSPACES, "transitions": WANTED,
                          "rounds": opts.rounds, "scrollback": opts.scrollback, "chat_turns": opts.chat_turns},
               "raw": {}, "errors": {}}
    signal.signal(signal.SIGTERM, bm.interrupted)
    run, display = None, None
    try:
        if opts.vdisplay:
            try:
                display = STRESS.start_vdisplay(opts.vdisplay, root, hold=6 * 3600)
                results["display"] = {"vdisplay_hz": opts.vdisplay, "size": STRESS.VDISPLAY_SIZE}
            except STRESS.StressShapeError as error:
                results["display"] = {"vdisplay_hz": opts.vdisplay, "error": str(error)[:400]}
                say(f"split-scale: VDISPLAY-FALLBACK {error}")
            time.sleep(2)  # test script: WindowServer settles the new main display before the app opens on it
        env, chats = {}, []
        if "chat" in WANTED_CONTENTS:
            say(f"split-scale: seeding a {opts.chat_turns}-turn chat")
            copies = sum(SPLITS) * len(WORKSPACES) + 2  # every chat cell's panes, each a fresh copy
            if WANTED_MOVES:
                copies = sum(MOVE_SHAPES[shape] for shape in WANTED_SHAPES) + 2
            home, chats = seed_chats(root, copies)
            env["ACPMUX_HOME"] = home
        wipe_state(APP)
        run = Run(env)
        run.launch()
        results["app_version"] = (run.app.identify() or {}).get("version")
        _, problem = STRESS.place_window(run.rpc)
        if problem:  # a window off its screen or the wrong size measures nothing comparable; fail the run
            results["errors"]["placement"] = problem
            raise SystemExit(f"split-scale: {problem}: run with a 1920 x 1200 display (--vdisplay=120 makes one)")
        time.sleep(4)  # test script: launch work ends before the first cell
        if WANTED_MOVES:
            results["matrix"] = {"shapes": WANTED_SHAPES, "contents": WANTED_CONTENTS, "moves": WANTED_MOVES,
                                 "rounds": opts.rounds, "chat_turns": opts.chat_turns}
            run_moves(run, results, chats)
        for count in [] if WANTED_MOVES else WORKSPACES:
            for splits in SPLITS:
                for content in WANTED_CONTENTS:
                    cell = f"s{splits}-{content}-w{count}"
                    say(f"split-scale: cell {cell}")
                    workspace = None
                    try:
                        workspace, columns = build_cell(run, splits, content, chats)
                        background(run, count, workspace)
                        run_cell(run, workspace, columns, results, cell, content)
                    except (Exception, SystemExit) as error:  # noqa: BLE001 - a cell that fails is its record; the next runs
                        results["errors"][cell] = f"{type(error).__name__}: {str(error)[:500]}"
                        say(f"split-scale: {cell} did not finish: {results['errors'][cell]}")
                    if workspace:
                        left = close_cell(run, workspace)
                        if left:
                            results["errors"][cell] = results["errors"].get(cell) or f"cleanup: {left}"
    finally:
        try:
            (finish_moves if WANTED_MOVES else finish)(results)  # before teardown: a teardown that stalls never loses the run
        except Exception as error:  # noqa: BLE001 - a report that fails must not hide the run's own error
            say(f"split-scale: writing the results failed: {error!r}")
        if run:
            run.end()
        if display:
            display.terminate()  # the helper this script started, by its process
            display.wait()
        shutil.rmtree(root, ignore_errors=True)
    if results["errors"] and not results["raw"]:
        raise SystemExit("split-scale: no cell finished")
    if WANTED_MOVES and opts.gate and not results.get("pass"):
        raise SystemExit("split-move: a move fails its verdict (the table above)")


if __name__ == "__main__":
    main()
