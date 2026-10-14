#!/usr/bin/env python3
"""Live check: a chat's subagents open beside it, as tabs or tiled (cx-1ndnn, Lawrence's zellij ask).

A card row's click opens that subagent as a tab in the pane right of the chat (open beside, as the
chat's links do): the first click makes that pane, the next adds a tab to it, a click on an open one
selects its tab; each tab is named for the subagent's task. Tile Subagents
(`agentChat.tileSubagents`) opens every running subagent in a pane of its own stacked right of the
chat, the panes equal in height, and again equal after one closes; an ended subagent opens none.

The chat: the app must run without --showcase (showcase swaps acpmux for a mock host). As
open-beside-realchat-e2e.py, the script adds harness `fake` (acpmux's tests/fake_agent.py,
`--fake-agent`) to this build's acpmux config.json (restored at the end), makes a session per
workspace on it, shows it in a chat tab (`debug.agent_pane select_session`) and seeds the
`subagents` fixture into it (webviews subagentsTurn.ts: three running subagents, one ended).

Usage: tile-subagents-e2e.py --socket SOCK [--out DIR] [--tag TAG] [--home DIR] [--record]
Exit status 0 when every check passes.
"""
import argparse, glob, json, os, re, socket, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", default="/tmp/tile-subagents", help="snapshots and frames go here")
parser.add_argument("--tag", default="", help="the build's tag (its acpmux home is .acpmux/builds/<key>, the key ending in the tag)")
parser.add_argument("--home", action="append", default=[], help="a HOME the app may run with")
HERE = os.path.dirname(os.path.abspath(__file__))
FAKE_AGENT = next((p for p in (os.path.join(HERE, "fake_agent.py"),
                               os.path.join(HERE, "..", "..", "cmux-tui", "crates", "acpmux", "tests", "fake_agent.py"))
                   if os.path.exists(p)), os.path.join(HERE, "fake_agent.py"))
parser.add_argument("--fake-agent", default=FAKE_AGENT, help="acpmux's tests/fake_agent.py (next to this script on a slot)")
parser.add_argument("--record", action="store_true")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
# A capture slot's root is the parent of --out; its HOME is <root>/home.
if not opts.home:
    opts.home = [os.path.join(os.path.dirname(os.path.abspath(opts.out)), "home"), os.path.expanduser("~")]
ROWS = []
CREATED = []
RESTORE = []
CAPTION = ["start"]
RECORDING = threading.Event()
# webviews subagentsTurn.ts: the tasks, oldest first; the last one has ended.
TASKS = ["Explore auth flow", "Audit retry policy", "Write timeout tests", "Read the docs"]
RUNNING = TASKS[:3]
CWD = "/tmp/cmux-tile-subagents"


def rpc(method, params=None, timeout=30):
    """One request on the app's control socket (line JSON)."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


# ---- acpmux (as chat-transfer-live.py) -------------------------------------------------------

class Acpmux:
    def __init__(self, path):
        self.conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.conn.connect(path)
        self.next, self.answers, self.lock = 0, {}, threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()
        self.request("initialize", {"protocolVersion": 1, "clientInfo": {"name": "tile-subagents-e2e"}})

    def _read(self):
        buf = b""
        while True:
            try:
                chunk = self.conn.recv(1 << 20)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if "id" in message and ("result" in message or "error" in message):
                    with self.lock:
                        self.answers[message["id"]] = message
                        self.lock.notify_all()

    def request(self, method, params, timeout=30):
        with self.lock:
            self.next += 1
            rid = self.next
        self.conn.sendall((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
        with self.lock:
            self.lock.wait_for(lambda: rid in self.answers, timeout)
            return self.answers.pop(rid, {"error": {"message": "no answer"}})


def socket_of(home):
    preferred = os.path.join(home, "acpmux.sock")
    if len(preferred.encode()) < 96:
        return preferred
    h = 0xcbf29ce484222325
    for byte in home.encode():
        h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"/tmp/acpmux-{os.getuid()}/{h:016x}.sock"


def live(path):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(2)
        conn.connect(path)
        conn.close()
        return True
    except OSError:
        return False


def slug(tag):
    return re.sub(r"[^a-z0-9]+", "-", tag.lower()).strip("-")


def acpmux_homes():
    """Build homes with a live daemon: any under the slot HOME (only this app runs there), and
    under the account home only those naming --tag as a word. A build's home is
    ~/.acpmux/builds/<key> (cx-is1kf.3, the key ends in the tag); older builds used ~/.acpmux/tags/<slug>."""
    found = {}
    for index, user_home in enumerate(opts.home):
        for home in glob.glob(os.path.join(user_home, ".acpmux", "builds", "*")) + \
                glob.glob(os.path.join(user_home, ".acpmux", "tags", "*")):
            named = f"-{slug(os.path.basename(home))}-"
            if index > 0 and not (opts.tag and f"-{slug(opts.tag)}-" in named):
                continue
            if live(socket_of(home)):
                found[home] = socket_of(home)
    return found


def write_config(path, text):
    temp = path + ".tile-subagents-e2e"
    with open(temp, "w") as f:
        f.write(text)
    os.replace(temp, path)


def restore_configs():
    for path, original, sock in RESTORE:
        try:
            if original is None:
                os.remove(path)
            else:
                write_config(path, original)
            Acpmux(sock).request("_acpmux/reload_config", {}, timeout=10)
            print("restored", path, flush=True)
        except OSError as error:
            print("could not restore", path, error, flush=True)


def configure_fake(home, sock):
    """Adds harness `fake` to the acpmux home's config.json once; restore_configs() undoes it."""
    path = os.path.join(home, "config.json")
    if any(entry[0] == path for entry in RESTORE):
        return Acpmux(sock)
    try:
        with open(path) as f:
            original = f.read()
    except FileNotFoundError:
        original = None
    config = json.loads(original) if original is not None else {}
    config.setdefault("harnesses", {})["fake"] = {"argv": ["/usr/bin/python3", opts.fake_agent]}
    write_config(path, json.dumps(config, indent=2))
    RESTORE.append((path, original, sock))
    client = Acpmux(sock)
    print("reload", home, json.dumps(client.request("_acpmux/reload_config", {}))[:200], flush=True)
    return client


# ---- the app's panes ---------------------------------------------------------------------------

def topology():
    snap = rpc("snapshot.get") or {}
    return (snap.get("topology") or snap) if isinstance(snap, dict) else {}


def panes_of(workspace):
    """[(pane id, [tab dicts])] of the workspace's first screen, in the snapshot's order."""
    for ws in topology().get("workspaces", []):
        if ws.get("id") == workspace:
            return [(p.get("id"), p.get("tabs") or []) for s in (ws.get("screens") or [])[:1] for p in s.get("panes") or []]
    return []


def brief(workspace):
    def tab(t):
        label = t.get("kind") or "?"
        if t.get("agent_session"):
            label += "@" + str(t["agent_session"])[-8:]
        if t.get("url"):
            label += ":" + t["url"].rsplit(":", 1)[-1]
        return label
    return [(pane[-6:], [tab(t) for t in tabs]) for pane, tabs in panes_of(workspace)]


def pane_rpc(pane, action, **params):
    return rpc("debug.agent_pane", {"action": action, "pane": pane, **params}, timeout=60)


def session_tabs(workspace, sid):
    """[(pane, tab)] of every tab bound to session `sid`, in snapshot order."""
    return [(pane, t) for pane, tabs in panes_of(workspace) for t in tabs if t.get("agent_session") == sid]


def chat_pane(workspace, sid):
    """The pane of the chat: the session's first tab (subagent tabs come after it)."""
    return next((pane for pane, t in session_tabs(workspace, sid) if t.get("id") == CHAT[sid]), None)


def subagent_tabs(workspace, sid):
    """[(pane, tab)] of the session's tabs other than the chat's: its subagents'."""
    return [(pane, t) for pane, t in session_tabs(workspace, sid) if t.get("id") != CHAT[sid]]


def named(tab, task):
    return task in json.dumps(tab)


def cells():
    """{pane id: [x, y, w, h]} of every shown pane (debug.pane_chrome)."""
    chrome = rpc("debug.pane_chrome") or {}
    out = {}
    for window in chrome.get("windows") or []:
        for entry in window.get("panes") or []:
            cell = entry.get("cell")
            if isinstance(cell, dict):
                cell = [cell.get("x"), cell.get("y"), cell.get("width"), cell.get("height")]
            out[entry.get("pane")] = cell
    return out


def equal_heights(panes):
    shown = [cells().get(p) for p in panes]
    heights = [c[3] for c in shown if c]
    return len(heights) == len(panes) and max(heights) - min(heights) <= 3, heights


CHAT = {}


def new_workspace():
    before = {ws.get("id") for ws in topology().get("workspaces", [])}
    rpc("action.run", {"action": "newTab", "args": {}, "focus": True})
    made = wait(lambda: [ws.get("id") for ws in topology().get("workspaces", []) if ws.get("id") not in before], 15)
    if not made:
        sys.exit("no workspace opened")
    CREATED.append(made[0])
    pane = wait(lambda: (panes_of(made[0]) or [(None,)])[0][0], 10)
    return made[0], pane


def recorder():
    """~4 fps window frames with the caption of the moment."""
    meta, start, index = [], time.time(), 0
    while RECORDING.is_set():
        began = time.time()
        name = f"{index:04d}.png"
        reply = rpc("debug.window_snapshot", {"path": os.path.join(opts.out, name)}, timeout=10)
        if isinstance(reply, dict) and "error" not in reply:
            meta.append({"file": name, "t": round(began - start, 2), "caption": CAPTION[0]})
            index += 1
        time.sleep(max(0.0, 0.25 - (time.time() - began)))
    with open(os.path.join(opts.out, "meta.json"), "w") as f:
        json.dump(meta, f, indent=1)
    print("recorded", len(meta), "frames", flush=True)


def caption(text):
    CAPTION[0] = text
    print("caption:", text, flush=True)


def pace():
    if opts.record:
        time.sleep(2.5)  # recording: one step every 2.5 s, so each shows


def open_real_chat(workspace, pane):
    """A lone chat tab in `pane` bound to a new fake-harness acpmux session, seeded with the
    subagents fixture; returns the session id."""
    before = {t.get("id") for _, tabs in panes_of(workspace) for t in tabs}
    print("newAgentChat:", json.dumps(rpc("action.run", {"action": "palette.newAgentChat", "target": f"pane:{pane}", "focus": True}))[:300], flush=True)
    found = wait(lambda: acpmux_homes() or None, 60, 0.5)
    if not found:
        sys.exit("no acpmux daemon came up (is the app running without --showcase?)")
    home, sock = max(found.items(), key=lambda item: os.path.getmtime(item[0]))
    client = configure_fake(home, sock)
    os.makedirs(CWD, exist_ok=True)
    created = client.request("session/new", {"cwd": CWD, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}})
    sid = (created.get("result") or {}).get("sessionId")
    if not sid:
        sys.exit("acpmux made no fake session: " + json.dumps(created)[:300])
    client.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "hi"}],
                                      "_meta": {"acpmux": {"promptId": "p-hi"}}}, timeout=60)
    time.sleep(1)  # test harness: the new chat tab draws its page
    new = [p for p, tabs in panes_of(workspace) for t in tabs if t.get("id") not in before]
    target = new[0] if new else pane
    for _ in range(3):
        print("select_session:", json.dumps(pane_rpc(target, "select_session", session=sid))[:300], flush=True)
        if wait(lambda: session_tabs(workspace, sid), 20, 0.5):
            break
    if not session_tabs(workspace, sid):
        sys.exit("the chat tab never bound to the session")
    CHAT[sid] = session_tabs(workspace, sid)[0][1].get("id")
    for _, tabs in panes_of(workspace):
        for t in tabs:
            if t.get("agent_session") != sid:
                rpc("action.run", {"action": "closeTab", "target": f"tab:{t.get('id')}"})
    wait(lambda: len(panes_of(workspace)) == 1 and len(panes_of(workspace)[0][1]) == 1, 10)
    print("seed:", json.dumps(pane_rpc(chat_pane(workspace, sid), "seed_rows", fixture="subagents"))[:200], flush=True)
    time.sleep(2)  # test harness: the card draws its Subagents list
    print("chat:", brief(workspace), flush=True)
    return sid


def click_row(workspace, sid, task):
    reply = pane_rpc(chat_pane(workspace, sid), "click", selector=f'.acpmux-summary-agent[title="{task}"]')
    print("click", task, json.dumps(reply)[:200], flush=True)


def tabs_part(workspace, sid):
    """The row clicks (cx-1ndnn): tabs in the pane right of the chat."""
    caption("Click a subagent in the Subagents card: it opens as a tab right of the chat")
    click_row(workspace, sid, RUNNING[0])
    first = wait(lambda: subagent_tabs(workspace, sid) or None, 15)
    holder = first[0][0] if first else None
    row("a subagent row opens a tab beside the chat, named for its task",
        f"one subagent tab outside the chat's pane named {RUNNING[0]!r}", f"panes {brief(workspace)}",
        bool(first) and holder != chat_pane(workspace, sid) and named(first[0][1], RUNNING[0]))
    panes_after_first = len(panes_of(workspace))
    pace()

    caption("Click another subagent: a second tab in that same pane, no new split")
    click_row(workspace, sid, RUNNING[1])
    second = wait(lambda: len(subagent_tabs(workspace, sid)) == 2 or None, 15)
    pair = subagent_tabs(workspace, sid)
    row("a second subagent adds a tab to the same pane", f"{panes_after_first} panes; both tabs in one pane",
        f"panes {brief(workspace)}", bool(second) and len(panes_of(workspace)) == panes_after_first
        and len({p for p, _ in pair}) == 1 and any(named(t, RUNNING[1]) for _, t in pair))
    pace()

    caption("Click the first subagent again: its tab is selected, no new tab")
    click_row(workspace, sid, RUNNING[0])
    time.sleep(1.5)  # test harness: a wrong open would land by now
    first_id = next((t.get("id") for _, t in subagent_tabs(workspace, sid) if named(t, RUNNING[0])), None)
    selected = wait(lambda: next((p.get("selected_tab") for ws in topology().get("workspaces", []) if ws.get("id") == workspace
                                  for p in (ws.get("screens") or [{}])[0].get("panes") or [] if p.get("id") == holder), None) == first_id, 5)
    row("an open subagent's row selects its tab, no other tab", "still 2 subagent tabs, the first selected",
        f"panes {brief(workspace)}", bool(selected) and len(subagent_tabs(workspace, sid)) == 2)
    pace()


def tile_part(workspace, sid):
    """Tile Subagents: a stack of equal panes right of the chat."""
    caption("Tile Subagents: each running subagent in a pane of its own, stacked right of the chat")
    chat = chat_pane(workspace, sid)
    print("tile:", json.dumps(rpc("action.run", {"action": "agentChat.tileSubagents", "target": f"pane:{chat}", "focus": True}))[:200], flush=True)
    tiled = wait(lambda: len({p for p, _ in subagent_tabs(workspace, sid)}) == len(RUNNING) or None, 30)
    tabs = subagent_tabs(workspace, sid)
    panes = [p for p, _ in tabs]
    row("Tile Subagents opens each running subagent in a pane of its own, named for its task",
        f"{len(RUNNING)} subagent panes, one tab each, named {RUNNING}; none for {TASKS[3]!r}", f"panes {brief(workspace)}",
        bool(tiled) and len(tabs) == len(RUNNING) and len(set(panes)) == len(RUNNING) and chat not in panes
        and all(any(named(t, task) for _, t in tabs) for task in RUNNING) and not any(named(t, TASKS[3]) for _, t in tabs))
    time.sleep(1)  # test harness: the stack's springs settle
    ok, heights = equal_heights(panes) if panes else (False, [])
    row("the tiled panes are equal in height", "heights within 3 pt", heights, ok)
    pace()

    caption("Close one tiled subagent: the others share the height again")
    if tabs:
        rpc("action.run", {"action": "closeTab", "target": f"tab:{tabs[1][1].get('id')}"})
    left = wait(lambda: len(subagent_tabs(workspace, sid)) == len(RUNNING) - 1 or None, 10)
    time.sleep(1.5)  # test harness: the rebalance's springs settle
    rest = [p for p, _ in subagent_tabs(workspace, sid)]
    ok, heights = equal_heights(rest) if rest else (False, [])
    row("after one closes the rest are equal again", "heights within 3 pt", heights, bool(left) and ok)
    pace()


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    if opts.record:
        print("window_frame:", json.dumps(rpc("debug.window_frame", {"frame": [20, 60, 1500, 900]}))[:200], flush=True)
    recording = None
    if opts.record:
        RECORDING.set()
        recording = threading.Thread(target=recorder, daemon=True)
        recording.start()
    workspace, pane = new_workspace()
    tabs_part(workspace, open_real_chat(workspace, pane))
    # Tiling in a workspace of its own, on another session: the tracker is per session.
    workspace, pane = new_workspace()
    tile_part(workspace, open_real_chat(workspace, pane))
    caption("Done")
    time.sleep(2.5 if opts.record else 0.5)  # recording: the end frame
    if recording:
        RECORDING.clear()
        recording.join(30)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "tile-subagents.png")})
    for ws in CREATED:
        rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}, "target": f"workspace:{ws}"})


try:
    main()
finally:
    RECORDING.clear()
    restore_configs()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
