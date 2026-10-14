#!/usr/bin/env python3
"""Live check: what a click in a REAL agent chat opens goes to one pane right of the chat.

Same four checks as scripts/cmux-next/open-beside-e2e.py, but in a
chat tab bound to an acpmux session (snapshot.get topology tab `agent_session`), so the lone chat
docks left on the first click (ChatColumnPlacement.dockChat) and the pane right of it stays in
view. A fifth check reads that: after the first click the chat is in a shown left dock column and
the pane holding the page is on screen in the strip (debug.dock, debug.pane_chrome).

The chat: the app must run without --showcase (showcase swaps acpmux for a mock host). The script
opens a chat (palette.newAgentChat), finds this build's acpmux home (`<home>/.acpmux/builds/<key>`
under the slot HOME or the account home), adds harness `fake` (acpmux's tests/fake_agent.py,
`--fake-agent`: next to this script, else the repo's copy) to its config.json, makes a session on it
(session/new, as chat-transfer-live.py does), shows it in the tab (`debug.agent_pane
select_session`) and seeds the links fixture into it. config.json is restored at the end.

--record: frames of the window (debug.window_snapshot, ~4 fps) into --out as NNNN.png with
meta.json [{file, t, caption}]; the window is set to 1500x900 and clicks are 2.5 s apart.

Usage: open-beside-realchat.py --socket SOCK [--out DIR] [--tag TAG] [--home DIR] [--record]
Exit status 0 when every check passes.
"""
import argparse, glob, http.server, json, os, re, socket, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", default="/tmp/open-beside-realchat", help="snapshots and frames go here")
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
PORT = 47811  # webviews linksTurn.ts
NOTES = "/tmp/cmux-open-beside/notes.md"
CAPTION = ["start"]
RECORDING = threading.Event()


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
        self.request("initialize", {"protocolVersion": 1, "clientInfo": {"name": "open-beside-realchat"}})

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
    temp = path + ".open-beside-realchat"
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
    path = os.path.join(home, "config.json")
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


def selected_url(workspace, pane):
    for ws in topology().get("workspaces", []):
        if ws.get("id") != workspace:
            continue
        for p in (ws.get("screens") or [{}])[0].get("panes") or []:
            if p.get("id") == pane:
                return next((t.get("url") or "" for t in p.get("tabs") or [] if t.get("id") == p.get("selected_tab")), "")
    return ""


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


SID = [None]


def chat_pane(workspace):
    """The pane holding the tab bound to our session (it moves into a dock on the first click)."""
    for pane, tabs in panes_of(workspace):
        if any(t.get("agent_session") == SID[0] for t in tabs):
            return pane
    return None


def chat_tab(workspace):
    for _, tabs in panes_of(workspace):
        for t in tabs:
            if t.get("agent_session") == SID[0]:
                return t.get("id")
    return None


def beside(workspace, chat):
    return [(pane, tabs) for pane, tabs in panes_of(workspace) if pane != chat]


def browsers(workspace, chat):
    return [t.get("url", "") for _, tabs in beside(workspace, chat) for t in tabs if t.get("kind") == "browser"]


def visibility(workspace, holder_url_suffix):
    """(ok, detail): the chat's pane is in a shown left dock, and the pane holding the URL is a
    strip pane at least 200 pt wide inside the strip's uncovered area."""
    chat = chat_pane(workspace)
    holder = next((p for p, tabs in beside(workspace, chat) for t in tabs
                   if (t.get("url") or "").endswith(holder_url_suffix)), None)
    dock = rpc("debug.dock") or {}
    chrome = rpc("debug.pane_chrome") or {}
    chat_dock = next((d for w in dock.get("windows", []) for d in ((w.get("screen") or {}).get("dock") or [])
                      if chat in (d.get("panes") or [])), None)
    strip = next(((w.get("screen") or {}).get("strip") for w in dock.get("windows", []) if (w.get("screen") or {}).get("strip")), None)
    def norm(r):
        if isinstance(r, list) and len(r) == 4:
            return {"x": r[0], "y": r[1], "width": r[2], "height": r[3]}
        return r if isinstance(r, dict) else None
    cells = {p.get("pane"): norm(p.get("cell")) for w in (chrome.get("windows") or []) for p in w.get("panes") or []}
    if strip:
        strip = dict(strip, uncovered_in_window=norm(strip.get("uncovered_in_window")))
    def shown_width(cell):
        if not cell or not strip:
            return 0
        area = strip.get("uncovered_in_window") or {}
        left = max(cell["x"], area.get("x", 0))
        right = min(cell["x"] + cell["width"], area.get("x", 0) + area.get("width", 0))
        return max(0, right - left)
    chat_cell = cells.get(chat)
    holder_shown = shown_width(cells.get(holder))
    ok = bool(chat_dock and chat_dock.get("shown") and chat_dock.get("edge") == "left"
              and chat_cell and chat_cell["width"] > 100 and chat_cell["x"] >= 0 and holder_shown >= 200)
    detail = (f"chat {str(chat)[-6:]} dock={chat_dock and {k: chat_dock.get(k) for k in ('edge', 'mode', 'shown')}} "
              f"cell={chat_cell}; holder {str(holder)[-6:]} cell={cells.get(holder)} shown_w={holder_shown:.0f}; "
              f"strip={strip and strip.get('uncovered_in_window')}")
    return ok, detail


def serve():
    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = f"<title>{self.path}</title><h1>{self.path}</h1>".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


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


def click(workspace, selector):
    chat = wait(lambda: chat_pane(workspace), 10)
    reply = pane_rpc(chat, "click", selector=selector)
    print("click", str(chat)[-6:], selector, json.dumps(reply)[:200], flush=True)
    return reply


def open_real_chat(workspace, pane):
    """A chat tab in `pane` bound to a fake-harness acpmux session; returns its session id."""
    before = {t.get("id") for _, tabs in panes_of(workspace) for t in tabs}
    print("before chat:", brief(workspace), flush=True)
    print("newAgentChat:", json.dumps(rpc("action.run", {"action": "palette.newAgentChat", "target": f"pane:{pane}", "focus": True}))[:300], flush=True)
    found = wait(lambda: acpmux_homes() or None, 60, 0.5)
    print("acpmux homes:", found, "searched", opts.home, flush=True)
    if not found:
        sys.exit("no acpmux daemon came up (is the app running without --showcase?)")
    home, sock = max(found.items(), key=lambda item: os.path.getmtime(item[0]))
    client = configure_fake(home, sock)
    os.makedirs(os.path.dirname(NOTES), exist_ok=True)
    created = client.request("session/new", {"cwd": os.path.dirname(NOTES), "mcpServers": [],
                                             "_meta": {"acpmux": {"harness": "fake"}}})
    sid = (created.get("result") or {}).get("sessionId")
    print("session/new:", json.dumps(created)[:300], flush=True)
    if not sid:
        sys.exit("acpmux made no fake session")
    client.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "hi"}],
                                      "_meta": {"acpmux": {"promptId": "p-hi"}}}, timeout=60)
    SID[0] = sid
    time.sleep(1)  # test harness: the new chat tab draws its page
    print("after newAgentChat:", brief(workspace), flush=True)
    new = [p for p, tabs in panes_of(workspace) for t in tabs if t.get("id") not in before]
    target = new[0] if new else pane
    for attempt in range(3):
        print("select_session:", json.dumps(pane_rpc(target, "select_session", session=sid))[:300], flush=True)
        if wait(lambda: chat_pane(workspace), 20, 0.5):
            break
        print("not bound yet:", brief(workspace), flush=True)
    if not chat_pane(workspace):
        sys.exit("the chat tab never bound to the session")
    # A lone chat: the only tab of its pane.
    chat = chat_pane(workspace)
    for p, tabs in panes_of(workspace):
        for t in tabs:
            if t.get("agent_session") != sid:
                print("close", t.get("kind"), json.dumps(rpc("action.run", {"action": "closeTab", "target": f"tab:{t.get('id')}"}))[:200], flush=True)
    wait(lambda: len(panes_of(workspace)) == 1 and len(panes_of(workspace)[0][1]) == 1, 10)
    print("chat:", brief(workspace), flush=True)
    return sid


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    server = serve()
    os.makedirs(os.path.dirname(NOTES), exist_ok=True)
    with open(NOTES, "w") as f:
        f.write("# Notes\n\nOpened beside the chat.\n")
    if opts.record:
        print("window_frame:", json.dumps(rpc("debug.window_frame", {"frame": [20, 60, 1500, 900]}))[:200], flush=True)
    workspace, pane = new_workspace()
    open_real_chat(workspace, pane)
    chat = chat_pane(workspace)
    print("seed:", json.dumps(pane_rpc(chat, "seed_rows", fixture="links"))[:200], flush=True)
    time.sleep(2)  # test harness: the reply draws and its path chip asks the host about its path
    print("start:", brief(workspace), flush=True)
    recording = None
    if opts.record:
        RECORDING.set()
        recording = threading.Thread(target=recorder, daemon=True)
        recording.start()
        caption("A real agent chat (fake harness), alone in its workspace")
        time.sleep(2.5)  # recording: the start frame

    # 1. The first link.
    caption("Click link /pr/1: it opens in the in-app browser beside the chat")
    click(workspace, f'a[href="http://127.0.0.1:{PORT}/pr/1"]')
    first = wait(lambda: any(u.endswith("/pr/1") for u in browsers(workspace, chat_pane(workspace))), 10)
    row("a link opens in the in-app browser beside the chat", "a browser tab on /pr/1 outside the chat's pane",
        f"panes {brief(workspace)}", bool(first))
    panes_after_first = len(panes_of(workspace))
    time.sleep(1)  # test harness: the dock move settles
    shown, detail = wait(lambda: (lambda r: r if r[0] else None)(visibility(workspace, "/pr/1")), 8) or visibility(workspace, "/pr/1")
    row("the chat docks left and the pane beside it is in view", "chat in a shown left dock; /pr/1 pane >=200 pt in the strip",
        detail, shown)
    pace()

    # 2. The second link.
    caption("Click link /pr/2: a second tab in the same pane, no new split")
    click(workspace, f'a[href="http://127.0.0.1:{PORT}/pr/2"]')
    second = wait(lambda: any(u.endswith("/pr/2") for u in browsers(workspace, chat_pane(workspace))), 10)
    side = beside(workspace, chat_pane(workspace))
    holder = [p for p, tabs in side if any(t.get("url", "").endswith("/pr/2") for t in tabs)]
    same = bool(second) and len(panes_of(workspace)) == panes_after_first and len(holder) == 1 and \
        any(t.get("url", "").endswith("/pr/1") for p, tabs in side if p == holder[0] for t in tabs)
    row("a second link adds a tab to the same pane", f"{panes_after_first} panes; /pr/1 and /pr/2 in one pane",
        f"panes {brief(workspace)}", same)
    print("visible after 2:", visibility(workspace, "/pr/2"), flush=True)
    pace()

    # 3. The first link again.
    caption("Click link /pr/1 again: its tab is selected, no third tab")
    tabs_before = len(browsers(workspace, chat_pane(workspace)))
    click(workspace, f'a[href="http://127.0.0.1:{PORT}/pr/1"]')
    time.sleep(1.5)  # test harness: a wrong open would land by now
    shown3 = wait(lambda: selected_url(workspace, holder[0]).endswith("/pr/1") if holder else False, 5)
    again = tabs_before == 2 and len(browsers(workspace, chat_pane(workspace))) == tabs_before and len(panes_of(workspace)) == panes_after_first
    row("a link already open beside the chat selects its tab there, no other tab",
        f"still 2 browser tabs, {panes_after_first} panes, /pr/1 selected",
        f"panes {brief(workspace)} selected {selected_url(workspace, holder[0]) if holder else None!r}", again and bool(shown3))
    print("visible after 3:", visibility(workspace, "/pr/1"), flush=True)
    pace()

    # 4. The file ref, also when the chat's own pane shows the file.
    caption("Click the file ref: its page opens in the same pane beside the chat")
    chat = chat_pane(workspace)
    tab = chat_tab(workspace)
    rpc("action.run", {"action": "file.open", "args": {"path": NOTES}, "target": f"pane:{chat}", "wait": True})
    time.sleep(1)  # test harness: the file's tab lands
    print("after file.open:", brief(workspace), flush=True)
    rpc("action.run", {"action": "tab.focus", "target": f"tab:{tab}", "focus": True})
    time.sleep(1)  # test harness: the chat shows again before its click
    pages_before = sum(1 for _, tabs in beside(workspace, chat_pane(workspace)) for t in tabs if t.get("kind") != "browser")
    panes_before4 = len(panes_of(workspace))
    click(workspace, f'[data-path="{NOTES}"]')
    page = wait(lambda: sum(1 for _, tabs in beside(workspace, chat_pane(workspace)) for t in tabs if t.get("kind") != "browser") > pages_before, 10)
    row("a file ref opens its page beside the chat, also when the chat's pane shows it",
        "one more page tab outside the chat's pane, no new pane",
        f"panes {brief(workspace)}", bool(page) and len(panes_of(workspace)) == panes_before4)
    print("visible after 4:", visibility(workspace, "/pr/1"), flush=True)
    caption("Done")
    time.sleep(2.5 if opts.record else 0.5)  # recording: the end frame

    if recording:
        RECORDING.clear()
        recording.join(30)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "open-beside.png")})
    for ws in CREATED:
        rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}, "target": f"workspace:{ws}"})
    server.shutdown()


try:
    main()
finally:
    RECORDING.clear()
    restore_configs()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
