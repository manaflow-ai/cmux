#!/usr/bin/env python3
"""Live check: classic cmux sessions come over to a cmux-next build (docs/cmux-next/classic-to-next.md).

  scripts/cmux-next/classic-to-next-live.py --app "cmux DEV <tag>.app" [--classic-app "cmux NIGHTLY.app"] [--out DIR]

1. Seeds classic data in a scratch directory (a session snapshot with a
   workspace of one terminal and one Claude Code chat, a workspace holding a
   Codex chat, and an agent journal naming a past Claude chat whose folder is
   only in its transcript, plus the real classic release session in
   tests/fixtures/classic-to-next with its folders moved into the scratch
   directory), launches the tagged cmux-next app with no activation, and runs
   scripts/cmux-next/classic-to-next.py --apply on it. Each row must open: the
   workspace in its folder, each agent chat as a workspace for its session
   id, and the split workspace in classic's panes.
2. With --classic-app, launches that classic build with the automation socket
   mode, creates a workspace in a scratch folder over its socket, and asks
   cmux-next for session.transfer.pull of that terminal: it must open in
   cmux-next in the same folder, and classic must have closed it.

Step 1 reads classic data only from the scratch directory. Step 2 launches
the classic app with the real HOME, so it loads and saves that host's classic
session, and it can attach to a classic already listening on /tmp/cmux.sock:
run it on a fleet mini, never on a person's Mac. GUI host only. Quits both apps by the PIDs
it started and stops the tag's daemons at the end.
"""
import argparse, json, os, plistlib, re, socket, sqlite3, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True, help="the cmux-next build under test")
parser.add_argument("--classic-app", help="a classic cmux build for the live pull (step 2)")
parser.add_argument("--capture", action="store_true",
                    help="save a still of the cmux-next window after the script runs (cua-driver on PATH, GUI host)")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="classic-to-next-live-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)
    return ok


def plist(app):
    with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
        return plistlib.load(f)


def slug(raw):
    return re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")


def socket_path(bundle):
    """The control socket a bundle id listens on (ControlSocketPath / classic SocketPathMarkerFiles)."""
    for channel in ("nightly", "rc", "staging"):
        base = f"com.cmuxterm.app.{channel}"
        if bundle == base:
            return f"/tmp/cmux-{channel}.sock"
        if bundle.startswith(base + "."):
            return f"/tmp/cmux-{channel}-{slug(bundle[len(base) + 1:])}.sock"
    if bundle.startswith("com.cmuxterm.app.debug."):
        return f"/tmp/cmux-debug-{slug(bundle[len('com.cmuxterm.app.debug.'):])}.sock"
    return os.path.expanduser("~/.local/state/cmux/cmux.sock")


def call(path, method, params=None, timeout=60):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            s.connect(path)
            s.sendall(json.dumps({"id": 1, "method": method, "params": params or {}}).encode() + b"\n")
            data = b""
            while b"\n" not in data:
                chunk = s.recv(1 << 16)
                if not chunk:
                    break
                data += chunk
    except OSError as error:
        return {"error": str(error)}
    line = data.split(b"\n", 1)[0].decode(errors="replace")
    try:
        reply = json.loads(line)
    except ValueError:
        return {"error": line or "no reply"}
    return {"result": reply.get("result")} if reply.get("ok") else {"error": reply.get("error")}


def wait_for(predicate, what, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.5)
    check(False, f"timed out: {what}")
    return None


def panes(next_socket, workspace):
    """[[(tab name, cwd), ...] per pane] of the named workspace's screens."""
    topology = ((call(next_socket, "snapshot.get").get("result") or {}).get("topology") or {})
    return [[(tab.get("name") or tab.get("title") or "", tab.get("cwd")) for tab in pane.get("tabs") or []]
            for ws in topology.get("workspaces") or [] if (ws.get("name") or ws.get("title")) == workspace
            for screen in ws.get("screens") or [] for pane in screen.get("panes") or []]


def tabs(next_socket):
    """(workspace name, tab) for every tab in cmux-next's published topology."""
    topology = ((call(next_socket, "snapshot.get").get("result") or {}).get("topology") or {})
    return [(ws.get("name") or ws.get("title") or "", tab)
            for ws in topology.get("workspaces") or []
            for screen in ws.get("screens") or []
            for pane in screen.get("panes") or []
            for tab in pane.get("tabs") or []]


def same_dir(a, b):
    return bool(a) and bool(b) and os.path.realpath(a) == os.path.realpath(b)


def capture(name):
    """A still of each cmux-next window through cua-driver (it holds the Screen Recording grant)."""
    time.sleep(2)  # let the sidebar settle before the still (screenshot only)
    def cua(tool, args):
        r = subprocess.run(["cua-driver", "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=60)
        try:
            return json.loads(r.stdout)
        except ValueError:
            return {}
    listed = cua("list_windows", {"pid": next_app.pid})
    windows = listed.get("windows") or (listed.get("structuredContent") or {}).get("windows") or []
    for w in [w for w in windows if (w.get("bounds") or {}).get("width", 0) > 200][:2]:
        path = os.path.join(opts.out, f"{name}-{w['window_id']}.png")
        cua("get_window_state", {"pid": next_app.pid, "window_id": w["window_id"], "include_accessibility_tree": False,
                                 "screenshot_out_file": path})
        check(os.path.exists(path), f"capture {path}")


# -- seeded classic data --------------------------------------------------------
SCRATCH = os.path.realpath(tempfile.mkdtemp(prefix="classic-to-next-"))
CLASSIC = os.path.join(SCRATCH, "classic")
PROJ, OLD, BOX, LIVE = (os.path.join(SCRATCH, d) for d in ("proj", "old-proj", "box", "live"))
for d in (os.path.join(CLASSIC, "session-history"), PROJ, OLD, BOX, LIVE,
          os.path.join(SCRATCH, "claude/projects/old"), os.path.join(SCRATCH, "hooks"), os.path.join(SCRATCH, "codex")):
    os.makedirs(d, exist_ok=True)
CLAUDE_LIVE, CODEX, CLAUDE_PAST = "1f6c3c51-7c2e-4f4e-9a52-6f1b8f0e0a11", "019a1c2b-3d4e-7f60-8a9b-0c1d2e3f4a5b", "7e0b2a44-91d3-4c55-b1e2-5d0a9c8f7e66"


def terminal(pid, title, cwd, **term):
    return {"id": pid, "type": "terminal", "title": title, "isPinned": False, "isManuallyUnread": False,
            "listeningPorts": [], "terminal": {"workingDirectory": cwd, **term}}


snapshot = {"version": 1, "createdAt": time.time() - 978307200, "windows": [{"tabManager": {"workspaces": [
    {"stableId": "ws-api", "processTitle": "zsh", "customTitle": "api server", "isPinned": False, "currentDirectory": PROJ,
     "layout": {"type": "split", "split": {"orientation": "horizontal", "dividerPosition": 0.5,
                                           "first": {"type": "pane", "pane": {"panelIds": ["p1"]}},
                                           "second": {"type": "pane", "pane": {"panelIds": ["p2"]}}}},
     "panels": [terminal("p1", "dev", PROJ), terminal("p0", "logs", OLD),
                terminal("p2", "claude chat", PROJ, agent={"kind": "claude", "sessionId": CLAUDE_LIVE, "workingDirectory": PROJ})],
     "statusEntries": [], "logEntries": []},
    {"stableId": "ws-box", "processTitle": "codex", "isPinned": False, "currentDirectory": BOX,
     "layout": {"type": "pane", "pane": {"panelIds": ["p3"]}},
     "panels": [terminal("p3", "codex chat", BOX, resumeBinding={"kind": "codex", "command": f"codex resume {CODEX}", "cwd": BOX})],
     "statusEntries": [], "logEntries": []}]}}]}
with open(os.path.join(CLASSIC, "session-com.cmuxterm.app.nightly.json"), "w") as f:
    json.dump(snapshot, f)
db = sqlite3.connect(os.path.join(CLASSIC, "agent-journal-com.cmuxterm.app.nightly.sqlite3"))
db.execute("CREATE TABLE agent_journal(sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT UNIQUE, schema_version INTEGER, "
           "kind TEXT, occurred_at_ms INTEGER, committed_at_ms INTEGER, source TEXT, agent_key TEXT, session_id TEXT, "
           "workspace_id TEXT, surface_id TEXT, unattributed_reason TEXT, is_subagent INTEGER, pending_work INTEGER, "
           "native_event TEXT, declared_phase TEXT, detail TEXT)")
db.execute("INSERT INTO agent_journal(event_id, kind, occurred_at_ms, agent_key, session_id, workspace_id, is_subagent) "
           "VALUES ('e1', 'prompt', ?, 'claude', ?, 'ws-gone', 0)", (int(time.time() * 1000) - 3_600_000, CLAUDE_PAST))
db.commit()
db.close()
with open(os.path.join(SCRATCH, "claude/projects/old", f"{CLAUDE_PAST}.jsonl"), "w") as f:
    f.write(json.dumps({"type": "user", "cwd": OLD}) + "\n")
# The real classic release session (tests/fixtures/classic-to-next): "split api"
# holds api and logs as tabs on the left and web over db on the right.
SPLIT = os.path.join(SCRATCH, "split")
REAL = os.path.join(HERE, "..", "..", "tests", "fixtures", "classic-to-next", "session-com.cmuxterm.app.json")
with open(REAL) as f:
    real = f.read().replace("/Users/cmux/p4rt-classic/proj", SPLIT).replace("/Users/cmux", SCRATCH)
with open(os.path.join(CLASSIC, "session-com.cmuxterm.app.json"), "w") as f:
    f.write(real)
for d in ("api/logs", "web", "db"):
    os.makedirs(os.path.join(SPLIT, d), exist_ok=True)
seeded = sorted(os.listdir(CLASSIC))

# -- cmux-next ------------------------------------------------------------------
APP = os.path.realpath(opts.app)
NEXT_SOCKET = socket_path(plist(APP)["CFBundleIdentifier"])
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
teardown = TagTeardown(APP)
teardown.install()
next_app = subprocess.Popen([os.path.join(APP, "Contents/MacOS", plist(APP)["CFBundleExecutable"])],
                            env={**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
                                 "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG},
                            stdout=open(os.path.join(opts.out, "next.log"), "w"), stderr=subprocess.STDOUT)
classic_app = None
print(f"next pid {next_app.pid} socket {NEXT_SOCKET}, scratch {SCRATCH}, out {opts.out}", flush=True)
try:
    wait_for(lambda: "result" in call(NEXT_SOCKET, "snapshot.get", timeout=5), "cmux-next socket", 120)
    before = {tab.get("surface") for _, tab in tabs(NEXT_SOCKET)}

    # 1. The playbook script on seeded classic files.
    listing = subprocess.run([sys.executable, os.path.join(HERE, "classic-to-next.py"), "--classic-dir", CLASSIC,
                              "--hook-dir", os.path.join(SCRATCH, "hooks"), "--claude-dir", os.path.join(SCRATCH, "claude"),
                              "--codex-dir", os.path.join(SCRATCH, "codex"), "--json"], capture_output=True, text=True, timeout=60)
    inventory = json.loads(listing.stdout or "{}")
    agents = {a["session"]: a for a in inventory.get("agents", [])}
    check(set(agents) == {CLAUDE_LIVE, CODEX, CLAUDE_PAST}, f"lists the three agent chats: {sorted(agents)}")
    check(same_dir((agents.get(CLAUDE_PAST) or {}).get("cwd"), OLD), "finds a past chat's folder in its transcript")
    check([w["title"] for w in inventory.get("workspaces", [])][:1] == ["api server"] or
          "api server" in [w["title"] for w in inventory.get("workspaces", [])], "lists the classic workspace")
    applied = subprocess.run([sys.executable, os.path.join(HERE, "classic-to-next.py"), "--classic-dir", CLASSIC,
                              "--hook-dir", os.path.join(SCRATCH, "hooks"), "--claude-dir", os.path.join(SCRATCH, "claude"),
                              "--codex-dir", os.path.join(SCRATCH, "codex"), "--apply", "--select", "all",
                              "--socket", NEXT_SOCKET], capture_output=True, text=True, timeout=600)
    print(applied.stdout + applied.stderr, flush=True)
    check(applied.returncode == 0, f"classic-to-next.py --apply exits 0 (got {applied.returncode})")

    def opened():
        new = [(name, tab) for name, tab in tabs(NEXT_SOCKET) if tab.get("surface") not in before]
        names = {name for name, _ in new}
        return new if {"api server", "claude chat", "codex chat"} <= names and len(names) >= 4 else None
    new = wait_for(opened, "the selected rows open in cmux-next", 60) or []
    for name, tab in new:
        print(f"     opened: {name!r} kind={tab.get('kind')} cwd={tab.get('cwd')} agent={tab.get('agent')} session={tab.get('agent_session')}")
    check(any(name == "api server" and same_dir(tab.get("cwd"), PROJ) for name, tab in new),
          "the workspace opens in its folder")
    check(any(name == "api server" and same_dir(tab.get("cwd"), OLD) for name, tab in new),
          "each classic terminal opens as a tab in its own folder")
    for session, name in ((CLAUDE_LIVE, "claude chat"), (CODEX, "codex chat")):
        check(any(n == name for n, _ in new), f"agent chat {name} opens as its own workspace")
        # An adopted chat is a conversation tab; its topology agent_session is the
        # acpmux session, not the harness id, and `agent` fills in once acpmux attaches.
        kinds = [tab.get("kind") for n, tab in new if n == name]
        check("conversation" in kinds, f"{name} opens an agent chat tab for {session} (tab kinds: {kinds})")
    split = wait_for(lambda: (lambda p: p if sum(map(len, p)) >= 4 else None)(panes(NEXT_SOCKET, "split api")),
                     "the split workspace opens its four terminals", 60) or []
    print(f"     split api panes: {split}")
    shape = sorted([[(name, os.path.relpath(os.path.realpath(cwd or "/"), os.path.realpath(SPLIT))) for name, cwd in pane]
                    for pane in split])
    check(shape == [[("api", "api"), ("logs", "api/logs")], [("db", "db")], [("web", "web")]],
          f"the split workspace keeps classic's panes (api and logs as tabs, web and db split): {shape}")
    check(sorted(os.listdir(CLASSIC)) == seeded, "classic's files are unchanged (read only)")
    if opts.capture:
        capture("after-apply")

    # 2. A live classic build hands a terminal to cmux-next.
    if opts.classic_app:
        CLASSIC_APP = os.path.realpath(opts.classic_app)
        info = plist(CLASSIC_APP)
        bundle = info["CFBundleIdentifier"]
        classic_app = subprocess.Popen([os.path.join(CLASSIC_APP, "Contents/MacOS", info["CFBundleExecutable"])],
                                       env={**BASE_ENV, "CMUX_SOCKET_ENABLE": "1", "CMUX_SOCKET_MODE": "automation"},
                                       stdout=open(os.path.join(opts.out, "classic.log"), "w"), stderr=subprocess.STDOUT)
        def classic_socket():
            # The channel path, or the legacy /tmp/cmux.sock some classic builds still use.
            for path in (socket_path(bundle), "/tmp/cmux.sock", os.path.expanduser("~/.local/state/cmux/cmux.sock")):
                identity = call(path, "system.identify", timeout=5).get("result") or {}
                ours = identity.get("bundle_identifier") == bundle or \
                    os.path.realpath(identity.get("app_bundle_path") or "/nonexistent") == CLASSIC_APP or \
                    (path == "/tmp/cmux.sock" and identity and "pid" not in identity and not identity.get("bundle_identifier"))
                if os.path.exists(path) and ours:
                    print(f"     classic identify keys: {sorted(identity)} app={identity.get('app')} build={identity.get('build')}")
                    return path
            return None
        CLASSIC_SOCKET = wait_for(classic_socket, f"classic {bundle} socket", 120)
        if not CLASSIC_SOCKET:
            for path in (socket_path(bundle), "/tmp/cmux.sock"):
                print(f"     {path}: exists={os.path.exists(path)} identify={json.dumps(call(path, 'system.identify', timeout=5))[:400]}")
            CLASSIC_SOCKET = socket_path(bundle)
        print(f"classic pid {classic_app.pid} socket {CLASSIC_SOCKET}", flush=True)
        created = call(CLASSIC_SOCKET, "workspace.create", {"cwd": LIVE, "focus": False})
        workspace = (created.get("result") or {}).get("workspace_id")
        check(bool(workspace), f"classic creates a workspace in {LIVE}: {created}")
        surfaces = wait_for(lambda: ((call(CLASSIC_SOCKET, "surface.list", {"workspace_id": workspace}).get("result") or {})
                                     .get("surfaces")), "classic lists the new terminal", 30) or []
        surface = next((s.get("id") for s in surfaces if s.get("type") == "terminal"), None)
        peers = call(NEXT_SOCKET, "session.transfer.peers")
        listed = [s for p in (peers.get("result") or {}).get("peers", []) for s in p.get("sessions", [])
                  if s.get("surface") == surface]
        check(bool(listed), f"session.transfer.peers lists the classic terminal {surface}")
        before = {tab.get("surface") for _, tab in tabs(NEXT_SOCKET)}
        pulled = call(NEXT_SOCKET, "session.transfer.pull", {"source": CLASSIC_SOCKET, "ids": [surface]}, timeout=300)
        result = pulled.get("result") or {}
        check(len(result.get("moved") or []) == 1 and not result.get("failed"), f"session.transfer.pull moves it: {pulled}")
        check(bool(wait_for(lambda: [t for _, t in tabs(NEXT_SOCKET) if t.get("surface") not in before
                                     and same_dir(t.get("cwd"), LIVE)], "the terminal opens in cmux-next in its folder", 30)),
              "the moved terminal keeps its folder")
        remaining = call(CLASSIC_SOCKET, "surface.list", {"workspace_id": workspace})
        still = [s for s in (remaining.get("result") or {}).get("surfaces") or [] if s.get("id") == surface]
        check(not still, f"classic closed the moved terminal ({remaining.get('error') or 'gone'})")
finally:
    if classic_app and classic_app.poll() is None:
        classic_app.terminate()  # the exact PID this script started
        try:
            classic_app.wait(20)
        except subprocess.TimeoutExpired:
            classic_app.kill()
    if next_app.poll() is None:
        call(NEXT_SOCKET, "action.run", {"id": "quit"}, timeout=10)
        try:
            next_app.wait(30)
        except subprocess.TimeoutExpired:
            next_app.terminate()
    teardown.end()

print(f"\n{len(failures)} failure(s)" + "".join(f"\n  - {f}" for f in failures))
sys.exit(1 if failures else 0)
