#!/usr/bin/env python3
"""A heavy user's load for bench_power.py's `loaded` scenario (the shared idle-cost bench).

On Leo's Mac with Leo idle (2026-10-28) the app took 65-75% of a core: the agent page's renderer
about 650 MB and 23-50% CPU, the Chromium GPU process 820 MB and 15-20%, two hidden cmux pages up
to 10%, the acpmux daemon 700 MB with thousands of chats listed. Every fix for that needs its
before and after from one load, so this builds that load in a fresh home:

  seed_store   before launch: `sessions` chats in the app's acpmux store (ACPMUX_HOME), a
               `closed` share of them closed and the rest idle (no agent process; a prompt
               respawns it), each with one answered turn on disk.
  PeerDaemon   after launch: a second acpmux daemon from the same bundle on its own home, its
               chats on the test agent, mirrored by the app's daemon as the peer `bench-remote`
               over loopback WebSocket. It stands in for an ssh host; its processes are the
               remote machine's and are left out of the numbers.
  open_load    `remote` chats on that peer and `local` chats on the app's own daemon, each in its
               own workspace; `streaming` of them get a reply that keeps streaming through the
               measured window; `tabs` Chromium tabs of local sites, each shown once; Home and
               New Tab in a workspace of their own; then the first idle local chat is shown.

Every count reached goes into the report, so a short load shows, never passes silently.
macOS only, on a fleet mini (bench_power.py launches the app).
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory as bm  # noqa: E402  (App, FakeChats, FAKE_AGENT_ID, process_table)

PEER = "bench-remote"
REPLY = "I read the build scripts, moved the shared steps into one helper and ran the suite again. " * 12


def private_dir(path: str):
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)  # acpmux refuses a state folder another user can write


def private_write(path: str, text: str):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(text)


def seed_store(home: str, count: int, closed_share: float, harness: str, cwd: str) -> dict:
    """`count` chats in the store of the acpmux home `home`, as a long-used daemon lists them.

    A closed chat with no log reads as purged and is skipped, so each gets its turn's records."""
    root = os.path.join(home, "sessions")
    private_dir(home)
    private_dir(root)
    closed = int(round(count * closed_share))
    now = int(time.time() * 1000)
    for i in range(count):
        session = f"01a1dc00-0000-7000-8000-{i:012x}"
        status = "closed" if i < closed else "idle"
        at = now - (count - i) * 60_000  # one a minute, oldest first
        prompt = f"idle-cost chat {i}: tidy the build scripts"
        agent = f"fake-seed-{i}"
        records = [
            {"seq": 1, "at": at, "dir": "out", "kind": "session/prompt",
             "msg": {"jsonrpc": "2.0", "id": 1, "method": "session/prompt",
                     "params": {"sessionId": agent, "prompt": [{"type": "text", "text": prompt}]}}},
            {"seq": 2, "at": at + 1, "dir": "in", "kind": "agent_message_chunk",
             "msg": {"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": agent, "update": {
                 "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": REPLY}}}}},
            {"seq": 3, "at": at + 2, "dir": "in", "kind": "session/prompt",
             "msg": {"jsonrpc": "2.0", "id": 1, "result": {"stopReason": "end_turn"}}},
        ]
        if status == "closed":
            records.append({"seq": 4, "at": at + 3, "dir": "mux", "kind": "status", "msg": {"status": "closed"}})
        meta = {"schema": "acpmux.session.v1", "id": session, "name": f"idle-cost-{i}", "harness": harness,
                "cwd": cwd, "status": status, "createdAt": at, "updatedAt": at + len(records),
                "lastSeq": len(records), "eventCount": len(records), "turnCount": 1,
                "title": f"Idle-cost chat {i}", "lastPrompt": prompt, "preview": REPLY[:120]}
        folder = os.path.join(root, session)
        private_dir(folder)
        private_dir(os.path.join(folder, "events"))
        private_write(os.path.join(folder, "session.json"), json.dumps(meta))
        private_write(os.path.join(folder, "events", "000000.ndjson"), "".join(json.dumps(r) + "\n" for r in records))
    return {"sessions": count, "closed": closed, "idle": count - closed}


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
                        raise RuntimeError(f"{method}: {json.dumps(message['error'])[:300]}")
                    return message.get("result")


def bundled_acpmux(bundle: str) -> str:
    for relative in ("Contents/Resources/bin/acpmux", "Contents/MacOS/acpmux", "Contents/Helpers/acpmux"):
        path = os.path.join(bundle, relative)
        if os.access(path, os.X_OK):
            return path
    raise SystemExit(f"idle-cost: no acpmux in {bundle}")


class PeerDaemon:
    """The load's remote machine: an acpmux daemon from the bundle on a home of its own."""

    def __init__(self, bundle: str, root: str, fake_agent: str):
        self.binary = bundled_acpmux(bundle)
        self.home = os.path.join(root, "peer-acpmux")
        private_dir(self.home)
        self.socket_dir = tempfile.mkdtemp(prefix="icp", dir="/tmp")  # a socket path must stay short
        self.socket = os.path.join(self.socket_dir, "s.sock")
        person = os.path.join(root, "peer-home")
        os.makedirs(person, exist_ok=True)
        self.env = {"HOME": person, "USER": os.environ.get("USER", ""), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "TMPDIR": self.socket_dir + "/", "ACPMUX_HOME": self.home, "ACPMUX_SOCKET": self.socket,
                    "ACPMUX_LOGIN_ENV": "0"}
        self.fake_agent = os.path.abspath(fake_agent)
        self.process: subprocess.Popen | None = None

    def start(self) -> dict:
        """Starts the daemon and registers the test agent; returns the peer entry for `_acpmux/peer_add`."""
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
                                                  "command": sys.executable, "args": [self.fake_agent],
                                                  "protocol": "acp", "replace": True})
        return {"name": PEER, "url": f"ws://{listen}", "token": token, "peerToken": peer_token, "wait": True}

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
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
        shutil.rmtree(self.socket_dir, ignore_errors=True)


def new_session(cli: str, env: dict, text: str) -> str | None:
    """A chat on the test agent with its first turn answered; its session id."""
    made = subprocess.run([cli, "acp", "new", "--json", "-d", "-m", bm.FAKE_AGENT_ID, text],
                          capture_output=True, text=True, timeout=120, env=env)
    try:
        return json.loads(made.stdout)["sessionId"]
    except (ValueError, KeyError):
        print(f"   acp new: {(made.stdout + made.stderr).strip()[:300]}", file=sys.stderr)
        return None


def stream(cli: str, env: dict, session: str, seconds: float, rate: float) -> bool:
    """Starts a reply that streams for `seconds` (the test agent's `stream:`), without waiting for it."""
    sent = subprocess.run([cli, "acp", "send", "--no-wait", session, f"stream: {int(seconds)} {rate}"],
                          capture_output=True, text=True, timeout=60, env=env)
    if sent.returncode != 0:
        print(f"   acp send {session}: {(sent.stdout + sent.stderr).strip()[:300]}", file=sys.stderr)
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


def remote_rows(app_socket: str, want: int, seconds: float = 90) -> list[str]:
    """The ids the app's daemon lists for the peer's chats, once it lists `want` of them."""
    deadline, ids = time.monotonic() + seconds, []
    while time.monotonic() < deadline:
        try:
            rows = (rpc(app_socket, "_acpmux/sessions", {"peer": PEER, "limit": 1000}) or {}).get("sessions") or []
        except (OSError, RuntimeError) as error:
            print(f"   _acpmux/sessions: {error}", file=sys.stderr)
            rows = []
        ids = [row.get("sessionId") or row.get("id") for row in rows
               if row.get("peer") == PEER or str(row.get("sessionId") or row.get("id") or "").startswith(PEER + "/")]
        ids = [value for value in ids if value]
        if len(ids) >= want:
            break
        time.sleep(2)  # test script: waiting for the peer's chats to reach the app's daemon
    return ids


def open_load(app: bm.App, bundle: str, fake_agent: str, root: str, page_url, counts: dict, stream_s: float) -> tuple[dict, PeerDaemon]:
    """Opens the load in the launched app (see the module); returns what it reached and the peer."""
    reached = {"remote_chats": 0, "local_chats": 0, "streaming": 0, "browser_tabs": 0, "home": False, "new_tab": False,
               "peer": False}
    chats = bm.FakeChats(app, bundle, fake_agent)  # the test agent on the app's daemon, and its socket
    app_socket = chats.env["ACPMUX_SOCKET"]
    peer = PeerDaemon(bundle, root, fake_agent)
    peer_env = dict(os.environ, ACPMUX_HOME=peer.home, ACPMUX_SOCKET=peer.socket)
    streaming_left = counts["streaming"]
    try:
        entry = peer.start()
        made = [s for s in (new_session(app.cli_path, peer_env, f"remote chat {i}") for i in range(counts["remote"])) if s]
        rpc(app_socket, "_acpmux/peer_add", entry, timeout=120)
        reached["peer"] = True
        listed = remote_rows(app_socket, len(made))
        for index, session in enumerate(listed[:counts["remote"]]):
            if open_workspace(app, session) or open_workspace(app, f"{PEER}/{session}"):
                reached["remote_chats"] += 1
        # One remote chat streams (on its own machine; the app mirrors it), the rest stream locally.
        if streaming_left and made and stream(app.cli_path, peer_env, made[0], stream_s, counts["rate"]):
            reached["streaming"] += 1
            streaming_left -= 1
    except (OSError, RuntimeError, subprocess.SubprocessError, SystemExit) as error:
        # The local load still runs; the report shows how many remote chats opened.
        print(f"   remote load: {error}", file=sys.stderr)
    first_idle = None
    for i in range(counts["local"]):
        session = new_session(app.cli_path, chats.env, f"local chat {i}")
        workspace = open_workspace(app, session) if session else None
        if not workspace:
            continue
        reached["local_chats"] += 1
        if streaming_left and stream(app.cli_path, chats.env, session, stream_s, counts["rate"]):
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
    # Home and New Tab, in their own workspace.
    app.run("workspace.newAtBottom")
    app.run("workspace.selectLast")
    reached["home"] = not (app.run("home.tab").get("error"))
    reached["new_tab"] = not (app.run("newTab").get("error"))
    if first_idle:
        app.action("goToWorkspace", workspace=first_idle)
    return reached, peer
