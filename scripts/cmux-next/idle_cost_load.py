#!/usr/bin/env python3
"""A heavy user's load for bench_power.py's `loaded` scenario (the shared idle-cost bench).

On Leo's Mac with Leo idle (2026-10-28) the app took 65-75% of a core: the agent page's renderer
about 650 MB and 23-50% CPU, the Chromium GPU process 820 MB and 15-20%, two hidden cmux pages up
to 10%, the acpmux daemon 700 MB with thousands of chats listed. Every fix for that needs its
before and after from one load, so this builds that load in a fresh home:

  PeerDaemon   before launch: a second acpmux daemon (a copy of the bundle's binary, so the bench's
               launch and teardown never take it for the app's) on its own home, with the test
               agent. It stands in for an ssh host: the app's daemon mirrors it as the peer
               `bench-remote` over loopback WebSocket, and its processes are left out of the numbers.
  templates    on that daemon: one chat with an answered turn and one closed after its turn. Their
               session.json and event logs are what the daemon itself wrote.
  seed_store   before launch: `sessions` copies of them in the app's acpmux store (ACPMUX_HOME),
               each under its own id, a `closed` share closed and the rest idle (no agent process;
               a prompt respawns it).
  open_load    after launch: `remote` chats on the peer and `local` chats on the app's own daemon,
               each in its own workspace, shown once; `streaming` of them get a reply that keeps
               streaming through the measured window; `tabs` Chromium tabs of local sites, each
               shown once; Home and the New Tab page in a workspace of their own; then the first
               idle local chat is shown.

A remote chat opens the way `acpmux new --host H --group G` opens one (cli/run/launch.rs
show_in_group): its mirrored id, without a host; this Mac's acpmux forwards it to the peer.
Every count reached goes into the report, so a short load shows, never passes silently.
macOS only, on a fleet mini (bench_power.py launches the app).
"""
from __future__ import annotations

import glob
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory as bm  # noqa: E402  (App, FakeChats, FAKE_AGENT_ID, process_table)

PEER = "bench-remote"


def private_dir(path: str):
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)  # acpmux refuses a state folder another user can write


def private_write(path: str, data: bytes):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)


def read_chat(home: str, session: str) -> dict:
    """A chat as its daemon stored it: session.json and its event log segments."""
    folder = os.path.join(home, "sessions", session)
    with open(os.path.join(folder, "session.json"), "rb") as handle:
        meta = handle.read()
    events = {}
    for path in sorted(glob.glob(os.path.join(folder, "events", "*.ndjson"))):
        with open(path, "rb") as handle:
            events[os.path.basename(path)] = handle.read()
    if not events:
        raise RuntimeError(f"chat {session} has no event log in {folder}")
    return {"id": session, "meta": meta, "events": events}


def seed_store(home: str, count: int, closed_share: float, answered: dict, closed: dict) -> dict:
    """`count` chats in the store of the acpmux home `home`, as a long-used daemon lists them:
    copies of the `answered` and `closed` template chats (read_chat), each under its own id."""
    root = os.path.join(home, "sessions")
    private_dir(home)
    private_dir(root)
    closed_count = int(round(count * closed_share))
    now = int(time.time() * 1000)
    for i in range(count):
        template = closed if i < closed_count else answered
        session = str(uuid.UUID(int=(0x01A1DC00 << 96) | (0x7000 << 64) | (0x8 << 60) | i))
        swap = lambda data: data.replace(template["id"].encode(), session.encode())  # noqa: E731
        meta = json.loads(swap(template["meta"]))
        at = now - (count - i) * 60_000  # one a minute, oldest first
        meta.update({"id": session, "name": f"idle-cost-{i}", "title": f"Idle-cost chat {i}", "createdAt": at,
                     "updatedAt": at + 1000, "status": "closed" if template is closed else "idle"})
        folder = os.path.join(root, session)
        private_dir(folder)
        private_dir(os.path.join(folder, "events"))
        private_write(os.path.join(folder, "session.json"), json.dumps(meta, indent=2).encode())
        for name, data in template["events"].items():
            private_write(os.path.join(folder, "events", name), swap(data))
    return {"sessions": count, "closed": closed_count, "idle": count - closed_count}


def rpc(path: str, method: str, params: dict, timeout: float = 60):
    """One JSON-RPC call on an acpmux socket; its result. Raises on an error answer."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(timeout)
        stream.connect(path)
        stream.sendall((json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}) + "\n").encode())
        pending = b""
        while True:
            chunk = stream.recv(65536)
            if not chunk:
                raise OSError(f"{method}: the daemon closed the connection")
            pending += chunk
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if message.get("id") == 1:
                    if message.get("error"):
                        raise RuntimeError(f"{method}: {json.dumps(message['error'])[:2000]}")
                    return message.get("result")


def bundled_acpmux(bundle: str) -> str:
    for relative in ("Contents/Resources/bin/acpmux", "Contents/MacOS/acpmux", "Contents/Helpers/acpmux"):
        path = os.path.join(bundle, relative)
        if os.access(path, os.X_OK):
            return path
    raise SystemExit(f"idle-cost: no acpmux in {bundle}")


class PeerDaemon:
    """The load's remote machine: the bundle's acpmux, copied out, on a home of its own."""

    def __init__(self, bundle: str, root: str, agent: str):
        bin_dir = os.path.join(root, "peer-bin")
        os.makedirs(bin_dir, exist_ok=True)
        self.binary = os.path.join(bin_dir, "acpmux")
        shutil.copy2(bundled_acpmux(bundle), self.binary)
        self.home = os.path.join(root, "peer-acpmux")
        private_dir(self.home)
        self.socket_dir = tempfile.mkdtemp(prefix="icp", dir="/tmp")  # a socket path must stay short
        self.socket = os.path.join(self.socket_dir, "s.sock")
        person = os.path.join(root, "peer-home")
        os.makedirs(person, exist_ok=True)
        self.env = {"HOME": person, "USER": os.environ.get("USER", ""), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "TMPDIR": self.socket_dir + "/", "ACPMUX_HOME": self.home, "ACPMUX_SOCKET": self.socket,
                    "ACPMUX_LOGIN_ENV": "0"}
        self.agent = os.path.abspath(agent)
        self.process: subprocess.Popen | None = None
        self.entry: dict = {}

    def start(self):
        """Starts the daemon and registers the test agent; `entry` is its `_acpmux/peer_add` params."""
        log = open(os.path.join(self.home, "daemon.log"), "a")
        self.process = subprocess.Popen([self.binary, "daemon", "run", "--ready-fd", "1", "--log", "warn"],
                                        env=self.env, stdout=subprocess.PIPE, stderr=log, stdin=subprocess.DEVNULL,
                                        start_new_session=True, text=True)
        ready: dict = {}
        seen = threading.Event()

        def read():  # drains stdout for the daemon's whole life, so it never blocks on a full pipe
            for line in self.process.stdout:
                if not seen.is_set():
                    try:
                        value = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(value, dict) and value.get("ready"):
                        ready.update(value)
                        seen.set()

        threading.Thread(target=read, daemon=True).start()
        if not seen.wait(90):
            raise SystemExit(f"idle-cost: the peer acpmux gave no ready line in 90 s (log {log.name})")
        listen = ready.get("listen")
        token = (parse_qs(urlparse(ready.get("webUrl") or "").query).get("token") or [None])[0]
        if not token:
            with open(os.path.join(self.home, "config.json")) as handle:
                token = (json.load(handle).get("websocket") or {}).get("token")
        with open(os.path.join(self.home, "run", "peer.token")) as handle:
            peer_token = handle.read().strip()
        if not listen or not token:
            raise SystemExit(f"idle-cost: the peer acpmux listens on {listen!r} with token {bool(token)}")
        rpc(self.socket, "_acpmux/harness/add", {"id": bm.FAKE_AGENT_ID, "displayName": "Idle-cost bench",
                                                  "command": sys.executable, "args": [self.agent],
                                                  "protocol": "acp", "replace": True})
        self.entry = {"name": PEER, "url": f"ws://{listen}", "token": token, "peerToken": peer_token, "wait": True}

    def acpmux(self, *words: str, timeout: float = 120) -> subprocess.CompletedProcess:
        return subprocess.run([self.binary, *words], capture_output=True, text=True, timeout=timeout, env=self.env)

    def new_chat(self, text: str) -> str | None:
        """A chat on the test agent whose first turn has ended; its session id."""
        made = self.acpmux("new", "--json", "-d", "-m", bm.FAKE_AGENT_ID, text)
        try:
            session = json.loads(made.stdout)["sessionId"]
        except (ValueError, KeyError):
            print(f"   peer acpmux new: {(made.stdout + made.stderr).strip()[:2000]}", file=sys.stderr)
            return None
        self.acpmux("wait", session, "--timeout", "60", timeout=90)
        return session

    def templates(self) -> tuple[dict, dict]:
        """One answered chat and one closed chat, as this daemon stored them (seed_store's templates)."""
        answered = self.new_chat("idle-cost template: tidy the build scripts")
        closed = self.new_chat("idle-cost template: tidy the build scripts")
        if not answered or not closed:
            raise SystemExit("idle-cost: the peer acpmux made no template chats")
        killed = self.acpmux("kill", closed)
        if killed.returncode != 0:
            raise SystemExit(f"idle-cost: acpmux kill: {(killed.stdout + killed.stderr).strip()[:2000]}")
        return read_chat(self.home, answered), read_chat(self.home, closed)

    def pids(self) -> set[int]:
        """The daemon and every process under it: the remote machine's, never the app's."""
        if self.process is None:
            return set()
        children: dict[int, list[int]] = {}
        for pid, ppid, _cmd in bm.process_table():
            children.setdefault(ppid, []).append(pid)
        found, todo = set(), [self.process.pid]
        while todo:
            pid = todo.pop()
            if pid not in found:
                found.add(pid)
                todo.extend(children.get(pid, []))
        return found

    def stop(self):
        """Ends the daemon and every agent host it started. A plain stop (SIGTERM) leaves hosted
        agents running for a next daemon (hub/shutdown.rs), and they run outside the app bundle,
        where bench_memory.end_bundle never looks: `daemon shutdown --end-agents` ends them, then
        sweeps any host still running. Whatever it left under the daemon is killed last."""
        if self.process and self.process.poll() is None:
            left = self.pids()
            try:
                done = self.acpmux("daemon", "shutdown", "--end-agents", timeout=60)
                if done.returncode != 0:
                    print(f"   peer acpmux shutdown: {(done.stdout + done.stderr).strip()[:2000]}", file=sys.stderr)
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
            for pid in left - {self.process.pid}:
                try:
                    os.kill(pid, signal.SIGKILL)  # this run's own peer processes only
                except ProcessLookupError:
                    pass
        shutil.rmtree(self.socket_dir, ignore_errors=True)


def new_session(cli: str, env: dict, text: str) -> str | None:
    """A chat on the test agent with its first turn answered; its session id."""
    made = subprocess.run([cli, "acp", "new", "--json", "-d", "-m", bm.FAKE_AGENT_ID, text],
                          capture_output=True, text=True, timeout=120, env=env)
    try:
        return json.loads(made.stdout)["sessionId"]
    except (ValueError, KeyError):
        print(f"   acp new: {(made.stdout + made.stderr).strip()[:2000]}", file=sys.stderr)
        return None


def stream(argv: list[str], env: dict, session: str, seconds: float, rate: float) -> bool:
    """Starts a reply that streams for `seconds` (idle_cost_agent.py's `stream:`), without waiting for it."""
    sent = subprocess.run(argv + ["send", "--no-wait", session, f"stream: {int(seconds)} {rate}"],
                          capture_output=True, text=True, timeout=60, env=env)
    if sent.returncode != 0:
        print(f"   send {session}: {(sent.stdout + sent.stderr).strip()[:2000]}", file=sys.stderr)
    return sent.returncode == 0


def open_workspace(app: bm.App, session: str) -> str | None:
    """A workspace on the chat, shown once (as a person who opened it read it), then left behind."""
    response = app.action("agent.openSessionWorkspace", session=session)
    created = [item for item in response.get("created", []) if str(item).startswith("ws_")]
    if not created:
        print(f"   agent.openSessionWorkspace {session}: {response.get('error') or response}", file=sys.stderr)
        return None
    app.action("goToWorkspace", workspace=created[0])
    time.sleep(1)  # test script: let the shown chat render
    return created[0]


def remote_rows(app_socket: str, want: set[str], seconds: float = 90) -> list[tuple[str, str]]:
    """(mirrored id, the peer's own id) for each of the peer's chats `want` the app's daemon
    lists, once it lists them all (or `seconds` pass: the report counts what opened)."""
    deadline, pairs = time.monotonic() + seconds, []
    while time.monotonic() < deadline:
        try:
            rows = (rpc(app_socket, "_acpmux/sessions", {"peer": PEER, "limit": 1000}) or {}).get("sessions") or []
        except (OSError, RuntimeError) as error:
            print(f"   _acpmux/sessions: {error}", file=sys.stderr)
            rows = []
        pairs = []
        for row in rows:
            mirrored = row.get("sessionId")
            own = next((value for value in (mirrored, str(row.get("qualifiedSessionId") or "").split("/")[-1]) if value in want), None)
            if row.get("peer") == PEER and mirrored and own:
                pairs.append((mirrored, own))
        if len(pairs) >= len(want):
            break
        time.sleep(2)  # test script: waiting for the peer's chats to reach the app's daemon
    return pairs


def open_load(app: bm.App, bundle: str, agent: str, peer: PeerDaemon, page_url, counts: dict,
              stream_s: float) -> dict:
    """Opens the load in the launched app (see the module); returns what it reached."""
    reached = {"remote_chats": 0, "local_chats": 0, "streaming": 0, "browser_tabs": 0, "home": False,
               "new_tab_page": False, "peer": False}
    chats = bm.FakeChats(app, bundle, agent)  # the test agent on the app's daemon, and its socket
    app_socket = chats.env["ACPMUX_SOCKET"]
    streaming_left = counts["streaming"]
    try:
        made = [s for s in (peer.new_chat(f"remote chat {i}") for i in range(counts["remote"])) if s]
        rpc(app_socket, "_acpmux/peer_add", peer.entry, timeout=120)
        reached["peer"] = True
        opened = []  # (the peer's own id, the mirrored id the app opened)
        for mirrored, own in remote_rows(app_socket, set(made)):
            if open_workspace(app, mirrored):
                opened.append((own, mirrored))
        reached["remote_chats"] = len(opened)
        # One opened remote chat streams on its own machine (the app mirrors it); the rest stream here.
        if streaming_left and opened and stream([peer.binary], peer.env, opened[0][0], stream_s, counts["rate"]):
            reached["streaming"] += 1
            streaming_left -= 1
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        # The local load still runs; the report shows how many remote chats opened.
        print(f"   remote load: {error}", file=sys.stderr)
    first_idle = None
    for i in range(counts["local"]):
        session = new_session(app.cli_path, chats.env, f"local chat {i}")
        workspace = open_workspace(app, session) if session else None
        if not workspace:
            continue
        reached["local_chats"] += 1
        if streaming_left and stream([app.cli_path, "acp"], chats.env, session, stream_s, counts["rate"]):
            reached["streaming"] += 1
            streaming_left -= 1
        elif first_idle is None:
            first_idle = workspace
    # Browser tabs in a workspace of their own, each shown once (a Chromium page loads when first shown).
    app.run("workspace.newAtBottom")
    app.run("workspace.selectLast")
    tabs = []
    for i in range(counts["tabs"]):
        response = app.run("openBrowser.chromium", url=page_url(i))
        if response.get("error") or response.get("code"):
            print(f"   browser tab {i}: {response.get('message') or response.get('error')}", file=sys.stderr)
            continue
        tabs.extend(item for item in response.get("created", []) if str(item).startswith("tab_"))
        reached["browser_tabs"] += 1
    for tab in tabs:
        app.run("tab.focus", target=tab)
        time.sleep(1)  # test script: let the shown page load
    # Home and the New Tab page, in their own workspace (`newTab` is New Workspace; `newTab.page` the page).
    app.run("workspace.newAtBottom")
    app.run("workspace.selectLast")
    for key, action in (("home", "home.tab"), ("new_tab_page", "newTab.page")):
        response = app.run(action)
        reached[key] = not (response.get("error") or response.get("code"))
    if first_idle:
        app.action("goToWorkspace", workspace=first_idle)
    return reached
