#!/usr/bin/env python3
"""Live check: what a click in a chat opens goes to one pane right of the chat (open beside).

Leo 2026-10-14: a link, a PR link or a file ref clicked in a chat opens in a pane right of the
chat, the in-app way: the first click with no pane there makes one; each later click adds a tab
to that same pane, never another split; a click on what a tab there already shows selects that
tab. Before, a link opened in the default browser and a file ref in a new tab of the chat's own
pane.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket. It serves two pages on 127.0.0.1:47811 and writes
/tmp/cmux-open-beside/notes.md, opens a workspace with an agent page, seeds the reply of
`debug.agent_pane seed_rows fixture: "links"` (two links and that path), and clicks the links
and the path chip with `debug.agent_pane click` (a native click the pane takes as the user's),
reading the workspace's panes (`snapshot.get`) after each. It closes its workspace and never
launches or quits the app.

Usage: open-beside-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock
Exit status 0 when every check passes.
"""
import argparse, http.server, json, os, socket, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", default="/tmp", help="where the end state's window snapshot goes")
opts = parser.parse_args()
ROWS = []
CREATED = []
PORT = 47811  # webviews linksTurn.ts
NOTES = "/tmp/cmux-open-beside/notes.md"


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
        time.sleep(step)  # test harness polling a live app
    return None


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


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
    """The URL of the tab `pane` selects ('' for none or a tab without one)."""
    for ws in topology().get("workspaces", []):
        if ws.get("id") != workspace:
            continue
        for p in (ws.get("screens") or [{}])[0].get("panes") or []:
            if p.get("id") == pane:
                return next((t.get("url") or "" for t in p.get("tabs") or [] if t.get("id") == p.get("selected_tab")), "")
    return ""


def brief(workspace):
    return [(pane[-6:], [t.get("kind") + (":" + t["url"].rsplit(":", 1)[-1] if t.get("url") else "") for t in tabs])
            for pane, tabs in panes_of(workspace)]


def pane_rpc(pane, action, **params):
    return rpc("debug.agent_pane", {"action": action, "pane": pane, **params}, timeout=60)


def serve():
    """The two PR pages the links open."""
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
    """A new focused workspace; returns its id and its one pane."""
    before = {ws.get("id") for ws in topology().get("workspaces", [])}
    rpc("action.run", {"action": "newTab", "args": {}, "focus": True})
    made = wait(lambda: [ws.get("id") for ws in topology().get("workspaces", []) if ws.get("id") not in before], 15)
    if not made:
        sys.exit("no workspace opened")
    CREATED.append(made[0])
    pane = wait(lambda: (panes_of(made[0]) or [(None,)])[0][0], 10)
    return made[0], pane


def chat_pane(workspace):
    """The workspace's pane whose agent page answers."""
    for pane, _ in panes_of(workspace):
        state = pane_rpc(pane, "chat_state")
        if isinstance(state, dict) and "error" not in state:
            return pane
    return None


def beside(workspace, chat):
    """The panes other than the chat's (the chat's pane is the one holding its agent tab)."""
    return [(pane, tabs) for pane, tabs in panes_of(workspace) if pane != chat]


def browsers(workspace, chat):
    return [t.get("url", "") for _, tabs in beside(workspace, chat) for t in tabs if t.get("kind") == "browser"]


def click(chat, selector):
    reply = pane_rpc(chat, "click", selector=selector)
    print("click", selector, json.dumps(reply)[:200], flush=True)
    return reply


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    server = serve()
    os.makedirs(os.path.dirname(NOTES), exist_ok=True)
    with open(NOTES, "w") as f:
        f.write("# Notes\n\nOpened beside the chat.\n")
    workspace, pane = new_workspace()
    rpc("action.run", {"action": "newTab.page", "target": f"pane:{pane}", "focus": True})
    chat = wait(lambda: chat_pane(workspace), 60, 1)
    if not chat:
        sys.exit("no agent page answered")
    print("seed:", json.dumps(pane_rpc(chat, "seed_rows", fixture="links"))[:200], flush=True)
    time.sleep(2)  # test harness: the reply draws and its path chip asks the host about its path
    print("start:", brief(workspace), flush=True)

    # 1. The first link: a pane right of the chat with the page, in the in-app browser.
    click(chat, f'a[href="http://127.0.0.1:{PORT}/pr/1"]')
    first = wait(lambda: any(u.endswith("/pr/1") for u in browsers(workspace, chat)), 10)
    row("a link opens in the in-app browser beside the chat", "a browser tab on /pr/1 outside the chat's pane",
        f"panes {brief(workspace)}", bool(first))
    panes_after_first = len(panes_of(workspace))

    # 2. The second link: a tab in that same pane, no new split.
    click(chat, f'a[href="http://127.0.0.1:{PORT}/pr/2"]')
    second = wait(lambda: any(u.endswith("/pr/2") for u in browsers(workspace, chat)), 10)
    side = beside(workspace, chat)
    holder = [p for p, tabs in side if any(t.get("url", "").endswith("/pr/2") for t in tabs)]
    same = bool(second) and len(panes_of(workspace)) == panes_after_first and len(holder) == 1 and \
        any(t.get("url", "").endswith("/pr/1") for p, tabs in side if p == holder[0] for t in tabs)
    row("a second link adds a tab to the same pane", f"{panes_after_first} panes; /pr/1 and /pr/2 in one pane",
        f"panes {brief(workspace)}", same)

    # 3. The first link again: its tab is selected, no third tab.
    tabs_before = len(browsers(workspace, chat))
    click(chat, f'a[href="http://127.0.0.1:{PORT}/pr/1"]')
    time.sleep(1.5)  # test harness: a wrong open would land by now
    shown = wait(lambda: selected_url(workspace, holder[0]).endswith("/pr/1") if holder else False, 5)
    again = tabs_before == 2 and len(browsers(workspace, chat)) == tabs_before and len(panes_of(workspace)) == panes_after_first
    row("a link already open beside the chat selects its tab there, no other tab",
        f"still 2 browser tabs, {panes_after_first} panes, /pr/1 selected",
        f"panes {brief(workspace)} selected {selected_url(workspace, holder[0]) if holder else None!r}", again and bool(shown))

    # 4. The file ref: its page in that same pane, even when the chat's own pane shows the file
    # already (a Command-click opens it there): a page elsewhere never turns the click into a no-op.
    chat_tab = next((t.get("id") for p, tabs in panes_of(workspace) if p == chat for t in tabs
                     if t.get("kind") == "conversation"), None)
    rpc("action.run", {"action": "file.open", "args": {"path": NOTES}, "target": f"pane:{chat}", "wait": True})
    wait(lambda: sum(1 for p, tabs in panes_of(workspace) if p == chat for t in tabs if t.get("kind") == "page") > 0, 10)
    rpc("action.run", {"action": "tab.focus", "target": f"tab:{chat_tab}", "focus": True})
    time.sleep(1)  # test harness: the chat shows again before its click
    pages_before = sum(1 for _, tabs in beside(workspace, chat) for t in tabs if t.get("kind") != "browser")
    click(chat, f'[data-path="{NOTES}"]')
    page = wait(lambda: sum(1 for _, tabs in beside(workspace, chat) for t in tabs if t.get("kind") != "browser") > pages_before, 10)
    row("a file ref opens its page beside the chat, also when the chat's pane shows it",
        "one more page tab outside the chat's pane, no new pane",
        f"panes {brief(workspace)}", bool(page) and len(panes_of(workspace)) == panes_after_first)

    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "open-beside.png")})
    for ws in CREATED:
        rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}, "target": f"workspace:{ws}"})
    server.shutdown()


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
