#!/usr/bin/env python3
"""Live check that a chat started in place on a New Tab page has a working header (cx-65br).

A New Tab page that starts a chat becomes that chat in its own tab. Its header must then act
as on any chat: Terminal and Browser each open a tab of their kind beside the chat, and [+] New
tab opens a New Tab page in a new column right of the chat (cx-qom0). A plain chat (New Agent
Chat) is checked first, as the control; then [+] on four New Tab Page chats (the page's move
into the column raced the store's tree), the first one's column page also starting a chat;
then Terminal and Browser on another New Tab Page chat, and that chat's [+] and Terminal with the
browser beside it (cx-p0fz: the address bar's restyle restarted its edit in a loop and the
main-thread watchdog stopped the app).

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket. The app needs an ACP harness with id `fake`
(cmux-tui/crates/acpmux/tests/fake_agent.py) in `harnesses/fake.toml` of the build's own acpmux
home (`$HOME/.acpmux/builds/<bundle id>/`; never `~/.config/cmux/harnesses`, which shipped builds
read), written before the launch. Each check opens a new workspace, starts a chat on the fake harness
and clicks a header button through `debug.agent_pane` (a native click on the page). It closes
the workspaces it made and never launches or quits the app.

Usage: newtab-chat-header-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--folder DIR]
`--folder`: the folder each chat starts in (named by the chat verb, so it gets the folder trust
question, never a refusal); a capture slot needs one below its HOME, as its home is no project.
Exit status 0 when every check passes.
"""
import argparse, json, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--folder", help="a folder each chat starts in, below the app's home (default: the page's start folder)")
opts = parser.parse_args()
ROWS = []
CREATED = []


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


def wait(check, seconds, step=0.5):
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


def topology():
    snap = rpc("snapshot.get") or {}
    return (snap.get("topology") or snap) if isinstance(snap, dict) else {}


def focus():
    return topology().get("focus") or {}


def panes_of(workspace):
    """{pane id: [tab kinds]} of the workspace."""
    found = {}
    for ws in topology().get("workspaces", []):
        if ws.get("id") != workspace:
            continue
        for screen in ws.get("screens", []):
            for pane in screen.get("panes", []):
                found[pane.get("id")] = [tab.get("kind") for tab in pane.get("tabs", [])]
    return found


def pane_rpc(pane, action, **params):
    return rpc("debug.agent_pane", {"action": action, "pane": pane, **params}, timeout=60)


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def new_workspace():
    """A new focused workspace; returns its id and its one pane."""
    before = {ws.get("id") for ws in topology().get("workspaces", [])}
    for _ in range(6):
        rpc("action.run", {"action": "newTab", "args": {}, "focus": True})
        made = wait(lambda: [ws.get("id") for ws in topology().get("workspaces", []) if ws.get("id") not in before], 15)
        if made:
            CREATED.append(made[0])
            wait(lambda: focus().get("workspace") == made[0], 10)
            pane = wait(lambda: next(iter(panes_of(made[0])), None), 10)
            return made[0], pane
        time.sleep(3)  # PTY capacity on shared minis is transient
    sys.exit("no workspace opened")


def chat_pane(workspace):
    """The workspace's pane whose agent page answers."""
    for pane, kinds in panes_of(workspace).items():
        state = pane_rpc(pane, "chat_state")
        if isinstance(state, dict) and "error" not in state:
            return pane
    return None


def start_fake_chat(pane):
    """Starts a chat on the fake harness on the page in `pane` (the session starts with the first
    prompt); returns the session."""
    picked = wait(lambda: (lambda r: r if isinstance(r, dict) and "error" not in r else None)(
        pane_rpc(pane, "new_chat", harness="fake", **({"cwd": opts.folder} if opts.folder else {}))), 60, 2)
    replies = []
    sent = wait(lambda: (lambda r: replies.append(r) or (r if isinstance(r, dict) and "error" not in r else None))(
        pane_rpc(pane, "send_prompt", text="hello")), 30, 2) or (replies[-1:] or [None])[0]
    session = wait(lambda: (pane_rpc(pane, "chat_state") or {}).get("sessionId"), 5)
    if not session:
        # A fresh folder asks for trust first; Trust sends the prompt the composer kept.
        print("trust:", json.dumps(pane_rpc(pane, "click", selector=".acpmux-trust-ask-action"))[:200], flush=True)
        session = wait(lambda: (pane_rpc(pane, "chat_state") or {}).get("sessionId"), 30)
    if not session:
        print("new_chat:", json.dumps(picked)[:300], "send_prompt:", json.dumps(sent)[:300], flush=True)
        print("chat_state:", json.dumps(pane_rpc(pane, "chat_state"))[:600], flush=True)
        return None
    time.sleep(1.5)  # test harness: the header draws for the chat
    return session


def click_header(pane, label):
    return pane_rpc(pane, "click", selector=f'.acpmux-header-tool[aria-label="{label}"]')


def kinds_beside(workspace, chat):
    """Every tab kind in the workspace's panes other than the chat's."""
    return sorted(k for p, kinds in panes_of(workspace).items() if p != chat for k in kinds)


def check_header(name, workspace, pane, label="Terminal", kind="terminal"):
    """The header button `label` opens a tab of `kind` beside the chat (a split, or the pane
    already beside it)."""
    before = kinds_beside(workspace, pane).count(kind)
    clicked = click_header(pane, label)
    grew = wait(lambda: kinds_beside(workspace, pane).count(kind) > before, 10)
    row(f"{name}: header {label} opens a {kind} beside the chat", f"one more {kind} tab outside the chat's pane",
        f"clicked {(clicked or {}).get('clicked')}; panes {panes_of(workspace)}", bool(grew))


def page_chat(name, workspace, page):
    """Starts a chat in place on the New Tab page in `page`; returns whether it started."""
    print(f"{name} page:", json.dumps(pane_rpc(page, "chat_state"))[:200], flush=True)
    session = start_fake_chat(page)
    row(f"{name}: the New Tab page starts a chat in place", "a session", f"session {session}", bool(session))
    return bool(session)


def page_workspace(name):
    """A new workspace whose only pane shows a New Tab page that started a chat in place; returns
    (workspace, pane) or None."""
    workspace, pane = new_workspace()
    rpc("action.run", {"action": "newTab.page", "target": f"pane:{pane}", "focus": True})
    page = wait(lambda: chat_pane(workspace), 60, 1)
    if not page:
        sys.exit("no New Tab page answered")
    return (workspace, page) if page_chat(name, workspace, page) else None


def plus_column(name, workspace, page):
    """The chat's header [+] New tab opens a New Tab page in a new pane (a column right of the
    chat, cx-qom0); returns that pane."""
    before = set(panes_of(workspace))
    clicked = click_header(page, "New tab")
    column = wait(lambda: next((p for p in panes_of(workspace) if p not in before and "conversation" in panes_of(workspace)[p]), None), 15)
    row(f"{name}: header [+] opens a New Tab page in a new column", "a new pane with an agent tab",
        f"clicked {(clicked or {}).get('clicked')}; panes {panes_of(workspace)}", bool(column))
    return column


def close_created():
    for workspace in CREATED:
        rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}, "target": f"workspace:{workspace}"})
    CREATED.clear()


def main():
    # Control: a plain chat.
    workspace, pane = new_workspace()
    rpc("action.run", {"action": "palette.newAgentChat", "target": f"pane:{pane}", "focus": True})
    chat = wait(lambda: chat_pane(workspace), 60, 1)
    if not (chat and start_fake_chat(chat)):
        sys.exit("the fake harness did not start a chat (is fake.toml in the build's acpmux home?)")
    check_header("New Agent Chat", workspace, chat)
    close_created()

    # [+] New tab on a New Tab page's chat, alone in its workspace (with a pane beside the chat it
    # reads Hide tabs). The page's move into the new column raced the store's tree (about half
    # the clicks left it in the chat's pane), so four rounds, each in a fresh workspace.
    for n in range(1, 5):
        made = page_workspace(f"New Tab Page {n}")
        if not made:
            continue
        workspace, page = made
        column = plus_column(f"New Tab Page chat {n}", workspace, page)
        if n == 1 and column and wait(lambda: "error" not in (pane_rpc(column, "chat_state") or {"error": 1}), 30, 1):
            if page_chat("[+] column", workspace, column):
                check_header("[+] column chat", workspace, column)
        close_created()

    # Terminal and Browser on a New Tab page's chat, then [+] (Hide tabs, with the browser beside
    # the chat) and Terminal again: with the browser's address bar editing, the next header click
    # hung the app (cx-p0fz).
    made = page_workspace("Last New Tab Page")
    if made:
        workspace, page = made
        check_header("New Tab Page chat", workspace, page)
        check_header("New Tab Page chat", workspace, page, "Browser", "browser")
        for label in ("Hide tabs", "Terminal"):
            clicked = click_header(page, label)
            time.sleep(2)  # test harness: the click lands
            answers = bool(wait(lambda: "error" not in (rpc("debug.windows", timeout=5) or {"error": 1}), 15))
            row(f"New Tab Page chat beside a browser: header {label} keeps the app answering", "the click lands; the app answers",
                f"clicked {(clicked or {}).get('clicked')}; panes {panes_of(workspace) if answers else 'no answer'}",
                answers and bool((clicked or {}).get("clicked")))
            if not answers:
                return


if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
    sys.exit("the app does not answer on " + opts.socket)
try:
    main()
finally:
    for workspace in CREATED:
        rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}, "target": f"workspace:{workspace}"})
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
