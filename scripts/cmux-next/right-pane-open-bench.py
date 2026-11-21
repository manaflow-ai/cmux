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
  reopen_right Reopen Closed (Cmd-Shift-T) of a subagent's chat that was open on the chat's right: the subagent's
               chat opens on the right and closes again (both untimed), then the key is timed. Leo, 2026-11-07: "it
               should just reopen on the right straight up and just play that rightmost opening animation. And also
               it should load a lot faster." `multi_phase` counts opens whose window motion ran in two phases or
               more (`motion.phases`): the old two-step (a tab opened in the main pane, then the split on the right)
               shows as one, and so does content that pops in after the split landed.

Three more, run only when named in --surfaces (e.g. `--surfaces sender_local,sender_peer,sender_unreached
--conditions light`): a click on the sender's name at the start of another agent's message in the chat's
transcript (SenderName in webviews acpmux conversation/IncomingMessageCard.tsx, `.cv-received__from--open`). Leo,
2026-11-07: "It feels just super duper unresponsive to be clicking into one of these agents ... I expect to see,
okay, my right pane is going to either gain a new tab or, like, split into having a new tab". Each message is put in
after the chat opens, through the app's own acpmux daemon (the bundle's acpmux CLI on the run's ACPMUX_HOME and
socket), the way such a message really arrives, so the line draws as the app draws a real one:

  sender_local      from another chat on the app's daemon: that chat's agent's own `acpmux send` (its caller
                    token proves the session, so acpmux records sender.session). The sender's chat opens on the right.
  sender_peer       from a chat on a second acpmux daemon (idle_cost_load.PeerDaemon, a few dozen turns in its
                    transcript) that the app's daemon has as the peer `bench-remote`; the peer has the app's daemon as
                    a peer too, so the chat's `acpmux send` crosses the peer link as a remote session's does. The
                    remote chat opens on the right.
  sender_unreached  from a self-declared name no daemon here has (`acpmux send --from some-vm/some-chat`, as the lane-gh
                    broker relays a lane VM's message): acpmux shows it as "(self-declared, unauthenticated)". A click
                    should open a tab on the right that says the chat cannot be found or reached; one that opens no new
                    pane (a toast only) is a miss (`opened_pane` false), never the run's end.

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

The whole run is on a 1920 x 1200 virtual main display (--vdisplay, perf-stress-session's helper): STRESS's
1600 x 1000 pt window does not fit a 1920 x 1080 display under the menu bar and Dock. A condition that fails
is that condition's record (`conditions.<name>.error`), and the next condition still runs; the run then exits
non-zero. The chat is followed by its tab, not its pane: closing what an open added can fold the chat's pane
into another one.

The budget (CLAUDE.md, perf-lead.md): every action < 10 ms to its committed frame, the content in that frame. A
frame strip sees a change only in a display frame, so a surface is OVER when its p95 commit_ms is past one display
frame plus 10 ms, or its p95 final_ms past its p95 commit_ms by more than a frame (content after the first frame).

Usage: right-pane-open-bench.py --app APP [--runs 6] [--conditions light,stress,restart] [--surfaces ...]
                                [--restarts 2] [--json FILE] [--md FILE]
Fleet: cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/right-pane-open.sh
       --ref SHA --artifact artifacts/right-pane-open.json [--arg=--runs=6]
The table is printed between RIGHT-PANE-OPEN-TABLE-BEGIN and -END, and the JSON has every open's frames.
Kills only the processes it started (the app it launched, the seeding daemon, sender_peer's daemon, the load's own
process groups).
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_memory as bm  # noqa: E402
import chat_open_frames as cof  # noqa: E402
import idle_cost_load as icl  # noqa: E402
from bench_power import wipe_state  # noqa: E402

SURFACES = ("terminal", "browser", "changes", "files", "new_tab", "subagent", "side_chat", "reopen_right")
# A click on another agent's message's sender (the module doc): only when --surfaces names them.
SENDER_SURFACES = ("sender_local", "sender_peer", "sender_unreached")
# SenderName's name control, the one that opens the sender's chat. Its aria-label says "Open NAME", so each case
# clicks its own sender's line when the transcript holds several.
SENDER_CHIP = ".cv-received__from--open"
# A folded inbox notice's head (InboxNoticeCard.tsx, MessageGroupHead.tsx): its senders' chips show once it is open.
INBOX_FOLDED = '.cv-inbox--group .cv-inbox__head[aria-expanded="false"]'
# A name no daemon here has, as a lane VM's message relayed by the lane-gh broker names its sender.
UNREACHED_SENDER = "some-vm/some-chat"
# The peer daemon's sender chat, its transcript's turns (so its first rows are measurable), and the name the peer
# gives the app's daemon. The app's daemon calls the peer idle_cost_load.PEER (`bench-remote`).
PEER_SENDER = "rpopen-peer-sender"
PEER_TURNS = 30
APP_ON_PEER = "bench-mac"
# The header's quick actions by id (webviews acpmux header/quickActions.ts, ChatHeaderTools `data-quick-action`).
QUICK = {"terminal": "terminal", "browser": "browser", "changes": "changes", "files": "files", "new_tab": "newTab"}
# A subagent's line in the transcript (chat-open-bench.py's SUBAGENT_LINES): by its name or task first.
SUBAGENT_LINES = (".cv-subagent-done button.cv-agent-tag.is-open", "button.acpmux-agent-line__button:not([disabled])")
NO_MATCH = "no visible element matches"

parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
parser.add_argument("--app", required=True)
parser.add_argument("--runs", type=int, default=6, help="opens of each surface per condition (restart: one per relaunch)")
parser.add_argument("--restarts", type=int, default=2, help="relaunches in the restart condition")
parser.add_argument("--conditions", default="light,stress,restart")
parser.add_argument("--surfaces", default=",".join(SURFACES),
                    help=f"of {','.join(SURFACES + SENDER_SURFACES)} (the default is all but the sender_* ones)")
parser.add_argument("--storm", type=int, default=6, help="stress: workers looping the app's CLI against its daemon")
parser.add_argument("--strip-ms", type=float, default=2500, help="how long each frame strip records after the click")
parser.add_argument("--strip-tolerance", type=float, default=0.001)
parser.add_argument("--settle-frames", type=int, default=10)
parser.add_argument("--settle", type=float, default=6, help="stress: seconds the load runs before the first open")
parser.add_argument("--motion", action="store_true",
                    help="also time the transition itself, open and (for a header toggle) close: composited stalls and main-thread misses")
parser.add_argument("--tunable", action="append", default=[], metavar="KEY=VALUE",
                    help="a debug tunable set after every launch (debug.tunables), e.g. motion.pane.variant=crisp")
parser.add_argument("--strips", help="keep each open's frame strip (strip.png) here, packed as STRIPS.tgz at the end")
parser.add_argument("--vdisplay", type=float, default=120,
                    help="a 1920 x 1200 virtual main display at this rate for the whole run (perf-stress-session's), so "
                         "STRESS's 1600 x 1000 pt window fits under the menu bar and Dock; 0 measures on the host's display")
parser.add_argument("--tag", default="rpopen")
parser.add_argument("--json")
parser.add_argument("--md")
opts = parser.parse_args()
APP = os.path.realpath(opts.app.rstrip("/"))
CONDITIONS = [c.strip() for c in opts.conditions.split(",") if c.strip()]
WANTED = [s.strip() for s in opts.surfaces.split(",") if s.strip()]
unknown = [s for s in WANTED if s not in SURFACES + SENDER_SURFACES]
if unknown:
    raise SystemExit(f"right-pane-open: unknown surfaces {unknown}; use {','.join(SURFACES + SENDER_SURFACES)}")
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
        # The edit last: Changes shows only for a chat whose transcript has an edit turn (App.tsx lastEditTurn).
        for text in ("turn: 1", f"subagents: {SUBAGENTS}", f"edit: {repo}"):
            sent = peer.acpmux("send", session, text, timeout=180)
            if sent.returncode != 0:
                raise SystemExit(f"right-pane-open: send {text!r}: {(sent.stdout + sent.stderr).strip()[-2000:]}")
    finally:
        peer.stop()
    template = icl.read_chat(peer.home, session)  # after the stop: its shutdown checkpoint writes session.json
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
# The sender_* surfaces' messages, put into the chat through the app's own acpmux daemon after it launched.

# Each sender surface's state in the condition that runs now: the name its chip says (`name`), or why its message
# never reached the chat (`error`).
SENDERS = {}
TOKEN = re.compile(r"^[0-9a-f]{64}$")


class SenderError(Exception):
    """A sender's message that did not reach the chat: that surface's rows are misses, the rest still run."""


def cli_env(**extra):
    """This shell's environment without any acpmux session of its own (a fleet step may run inside one), plus
    `extra`: a send from here is the person's, a --from sender's or the session `extra` proves, nothing else."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("ACPMUX_")}
    env.update(extra)
    return env


def run_cli(binary, env, *words, timeout=180):
    done = subprocess.run([binary, *words], capture_output=True, text=True, timeout=timeout, env=env)
    if done.returncode != 0:
        raise SenderError(f"acpmux {' '.join(words[:2])}: {(done.stdout + done.stderr).strip()[-600:]}")
    return done


def chat_log(home, session):
    """The chat's event log as its daemon wrote it, all segments."""
    data = b""
    folder = os.path.join(home, "sessions", session, "events")
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if name.endswith(".ndjson"):
            with open(os.path.join(folder, name), "rb") as handle:
                data += handle.read()
    return data


def logged_agent_env(home, session):
    """The agent's answer to `envs: ...` (fake_agent.py: a JSON object of the names asked), from its chat's log."""
    found = {}

    def walk(value):
        if isinstance(value, dict):
            for item in value.values():
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)
        elif isinstance(value, str) and value.lstrip().startswith("{") and "ACPMUX_SESSION_TOKEN" in value:
            try:
                answer = json.loads(value)
            except ValueError:
                return
            if isinstance(answer, dict) and TOKEN.match(str(answer.get("ACPMUX_SESSION_TOKEN") or "")):
                found.update(answer)

    for line in chat_log(home, session).splitlines():
        try:
            walk(json.loads(line))
        except ValueError:
            continue
    return found


def caller_env(binary, env, home, session):
    """The env an `acpmux send` run by `session`'s own agent has: its session id, the caller token acpmux gave the
    agent and the socket of the daemon that issued it (hub/start_gate.rs `caller_env`), so the daemon proves the
    send is that session's (requests.rs: `session_message`, sender.session set). The test agent says its own env
    (fake_agent.py `envs:`, as acpmux's own tests read the token: tests/person_auto_start.rs)."""
    run_cli(binary, env, "send", session, "envs: ACPMUX_SESSION_TOKEN,ACPMUX_SESSION_TOKEN_SOCKET")
    deadline = time.monotonic() + 30
    found = {}
    while time.monotonic() < deadline:
        found = logged_agent_env(home, session)
        if found:
            break
        time.sleep(0.3)  # test script: the daemon writes the answer to its log
    if not found:
        raise SenderError(f"the agent of {session} never said its caller token")
    # The CLI sends the token only to the socket that issued it, compared as a path: the same string both places.
    issuer = found.get("ACPMUX_SESSION_TOKEN_SOCKET") or env["ACPMUX_SOCKET"]
    return {"ACPMUX_SESSION_ID": session, "ACPMUX_SESSION_TOKEN": found["ACPMUX_SESSION_TOKEN"],
            "ACPMUX_SESSION_TOKEN_SOCKET": issuer, "ACPMUX_SOCKET": issuer}


def new_chat(binary, env, name, text):
    """A chat on the test agent named `name`, its first turn `text` answered; its id."""
    made = run_cli(binary, env, "new", "--json", "-d", "-m", bm.FAKE_AGENT_ID, "--name", name, text)
    try:
        session = json.loads(made.stdout)["sessionId"]
    except (ValueError, KeyError):
        raise SenderError(f"acpmux new {name}: {made.stdout.strip()[-400:]}") from None
    subprocess.run([binary, "wait", session, "--timeout", "60"], capture_output=True, timeout=90, env=env)
    return session


def wait_delivered(binary, env, home, chat, marker):
    """Until the chat's log holds the message (an inbox record and its notice turn, or a queued turn from a peer),
    then its turn's end, and the page's own draw of it."""
    deadline = time.monotonic() + 90
    while marker.encode() not in chat_log(home, chat):
        if time.monotonic() > deadline:
            raise SenderError(f"the message {marker} never reached the chat's log in 90 s")
        time.sleep(0.5)  # test script: the outbox delivers it in the background
    subprocess.run([binary, "wait", chat, "--timeout", "60"], capture_output=True, timeout=90, env=env)
    time.sleep(2)  # test script: the page draws the new line


class PeerSender:
    """sender_peer's remote machine: a second acpmux daemon (idle_cost_load.PeerDaemon) with one chat of PEER_TURNS
    answered turns, started once for the run and linked to each launch's app daemon in both directions."""

    def __init__(self, root):
        self.peer = icl.PeerDaemon(APP, os.path.join(root, "sender-peer"), AGENT)
        self.chat = None

    def start(self):
        self.peer.start()
        env = dict(self.peer.env)
        self.chat = new_chat(self.peer.binary, env, PEER_SENDER, "turn: 0")
        for turn in range(1, PEER_TURNS):
            run_cli(self.peer.binary, env, "send", self.chat, f"turn: {turn}")
        self.caller = caller_env(self.peer.binary, env, self.peer.home, self.chat)

    def link(self, app_socket, home):
        """The app's daemon has the peer as `bench-remote` (as idle_cost_load does), and the peer has the app's
        daemon as APP_ON_PEER: its listener and token from `_acpmux/status`, its peer token from run/peer.token, so
        the app's daemon serves the peer as a peer, not as Web (server/peer_auth.rs). Both are add-or-replace, so
        every launch links again (the app's listener may move)."""
        icl.rpc(app_socket, "_acpmux/peer_add", self.peer.entry, timeout=120)
        status = icl.rpc(app_socket, "_acpmux/status", {}) or {}
        listen = status.get("listen")
        token = (parse_qs(urlparse(status.get("webUrl") or "").fragment).get("token") or [None])[0]
        if not token:
            with open(os.path.join(home, "config.json")) as handle:
                token = (json.load(handle).get("websocket") or {}).get("token")
        with open(os.path.join(home, "run", "peer.token")) as handle:
            peer_token = handle.read().strip()
        if not listen or not token:
            raise SenderError(f"the app's acpmux listens on {listen!r} with token {bool(token)}")
        icl.rpc(self.peer.socket, "_acpmux/peer_add", {"name": APP_ON_PEER, "url": f"ws://{listen}", "token": token,
                                                        "peerToken": peer_token, "wait": True}, timeout=120)

    def mirrored(self, own, seconds=90):
        """The id the peer lists the app's chat `own` under (a remote session, as remote_rows reads one)."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            rows = (icl.rpc(self.peer.socket, "_acpmux/sessions", {"peer": APP_ON_PEER, "limit": 1000}) or {}).get("sessions") or []
            for row in rows:
                ids = (row.get("sessionId"), str(row.get("qualifiedSessionId") or "").split("/")[-1])
                if row.get("peer") == APP_ON_PEER and row.get("sessionId") and own in ids:
                    return row["sessionId"]
            time.sleep(2)  # test script: the app's chats reach the peer's list
        raise SenderError(f"the peer never listed the app's chat {own}")

    def send(self, target, text):
        """The peer chat's own `acpmux send` to the app's chat: the peer forwards it with the session it proved
        (peer_forward.rs `name_sender`), as a lane on another machine sends."""
        run_cli(self.peer.binary, dict(self.peer.env, **self.caller), "send", target, text)

    def stop(self):
        self.peer.stop()


def seed_senders(home, chat, condition, peer):
    """Each wanted sender_* surface's message in `chat` (the condition's chat, open in the launched app), through
    the app's own acpmux daemon. Fills SENDERS; returns what each reached, for the condition's record."""
    SENDERS.clear()
    wanted = [s for s in WANTED if s in SENDER_SURFACES]
    if not wanted:
        return {}
    binary = icl.bundled_acpmux(APP)
    app_socket = bm.FakeChats.acpmux_socket(APP)
    env = cli_env(ACPMUX_HOME=home, ACPMUX_SOCKET=app_socket)
    try:
        # The test agent on the app's daemon: the local sender runs on it, and the chat's own notice turn spawns it.
        icl.rpc(app_socket, "_acpmux/harness/add", {"id": bm.FAKE_AGENT_ID, "displayName": "Right pane bench",
                                                     "command": sys.executable, "args": [AGENT], "protocol": "acp",
                                                     "replace": True})
    except (OSError, RuntimeError) as error:
        for surface in wanted:
            SENDERS[surface] = {"error": f"harness/add: {str(error)[:500]}"}
        return {surface: dict(state) for surface, state in SENDERS.items()}
    for surface in wanted:
        marker = f"rpopen-{surface}-{condition}"
        text = f"{marker}: the parser change is ready for review; the tests pass."
        try:
            if surface == "sender_local":
                # Another chat here, whose agent's own `acpmux send` names it (an agent's send is queued: the outbox
                # delivers it as that session, server/outbox.rs). The chat holds it in its inbox and shows it.
                name = f"rpopen-local-{condition}"
                sender = new_chat(binary, env, name, "turn: 0")
                run_cli(binary, dict(env, **caller_env(binary, env, home, sender)), "send", chat, text)
                SENDERS[surface] = {"name": name, "session": sender}
            elif surface == "sender_peer":
                if peer is None or not peer.chat:
                    raise SenderError("the peer daemon did not start")
                peer.link(app_socket, home)
                # The app lists the peer's chat (a click opens its mirror), and the peer lists the app's chat.
                if not icl.remote_rows(app_socket, {peer.chat}):
                    raise SenderError("the app's daemon never listed the peer's chat")
                peer.send(peer.mirrored(chat), text)
                SENDERS[surface] = {"name": PEER_SENDER, "session": peer.chat}
            else:
                # A sender that only names itself, from no session (the lane-gh broker's `acpmux send --from VM/LANE`):
                # acpmux records a declared, unauthenticated label (prompt_provenance.rs `sender_record_with_auth`)
                # and the inbox shows it as "some-vm/some-chat (self-declared, unauthenticated)" (inbox.rs
                # `display_sender`).
                run_cli(binary, env, "send", "--from", UNREACHED_SENDER, chat, text)
                SENDERS[surface] = {"name": UNREACHED_SENDER}
            wait_delivered(binary, env, home, chat, marker)
        except (SenderError, OSError, RuntimeError, subprocess.SubprocessError) as error:
            SENDERS[surface] = {**SENDERS.get(surface, {}), "error": f"{type(error).__name__}: {str(error)[:500]}"}
            say(f"right-pane-open: {condition} {surface}: no message: {SENDERS[surface]['error']}")
    return {surface: dict(state) for surface, state in SENDERS.items()}


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
        self.workspace = self.pane = self.tab = None

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
        panes = self.stress.panes(self.stress.workspace(self.workspace))
        if not self.pane:
            self.pane = panes[0]["id"] if panes else None
        mine = next((p for p in panes if p.get("id") == self.pane), {})
        tabs = mine.get("tabs") or []
        self.tab = next((t.get("id") for t in tabs if t.get("kind") == "conversation"), tabs[0].get("id") if tabs else None)
        time.sleep(1.5)  # test script: the page's own reads after its first content end before the first click

    def repane(self):
        """The pane that holds the chat's tab now: closing what an open added can fold the chat's pane into a new one
        (light run at 05efe285: after Changes closed, the chat's tab was in another pane and every later open
        clicked into the old pane id, "shows no agent tab")."""
        if not self.tab:
            return
        panes = self.stress.panes(self.stress.workspace(self.workspace))
        found = next((p.get("id") for p in panes if any(t.get("id") == self.tab for t in p.get("tabs") or [])), None)
        if found and found != self.pane:
            say(f"right-pane-open: the chat's tab moved from pane {self.pane} to {found}")
            self.pane = found

    def show(self):
        self.repane()
        self.stress.show(self.workspace)
        self.stress.focus_pane(self.pane)
        time.sleep(0.5)  # test script: the switch settles

    def tabs(self):
        return {t.get("id") for p in self.stress.panes(self.stress.workspace(self.workspace)) for t in p.get("tabs") or [] if t.get("id")}

    def close_new(self, before):
        """Closes every tab an open added (the chat alone again), and waits for the layout to be back. Returns
        None, or what was left when the chat's pane never took focus back (the topology, for the record)."""
        for tab in self.tabs() - before:
            self.stress.action("closeTab", target=f"tab:{tab}", focus=False)
        STRESS.wait(lambda: not (self.tabs() - before), 10, step=0.1)
        STRESS.wait(lambda: len(self.stress.panes(self.stress.workspace(self.workspace))) <= 1, 10, step=0.1)
        left = sorted(self.tabs() - before)
        problem = None
        for _ in range(3):
            try:
                self.repane()
                self.stress.show(self.workspace)
                self.stress.focus_pane(self.pane)
                problem = None
                break
            except STRESS.StressShapeError as error:
                problem = str(error)[:600]
                time.sleep(0.5)  # test script: an open's own focus move ends before the retry
        time.sleep(0.6)  # test script: the close's own motion ends before the next click
        panes = self.stress.panes(self.stress.workspace(self.workspace))
        if problem or left or len(panes) > 1:
            return {"focus": problem, "left_tabs": left, "panes": [{"id": p.get("id"), "tabs": [(t.get("id"), t.get("kind"), t.get("page"))
                                                 for t in p.get("tabs") or []]} for p in panes]}
        return None


# ---------------------------------------------------------------------------------------------
# One open.

# Reopen Closed: the key the strip sends through the real key path instead of a click (`reopen_right`).
REOPEN_KEY = {"key": "t", "modifiers": ["command", "shift"]}


def strip(run, chat, click, label, content="rightmost"):
    folder = os.path.join(tempfile.gettempdir(), f"right-pane-open-{os.getpid()}", label)
    gesture = dict(REOPEN_KEY) if click is REOPEN_KEY else {"gesture": "agent_click", "click": {**click, "pane": chat.pane}}
    params = {"action": "frame_strip", **gesture, "above": True,
              "content": content, "duration_ms": opts.strip_ms, "dir": folder, "tolerance": opts.strip_tolerance}
    cef = {}
    if opts.motion:
        # Whether Chromium had a spare window and page ready for this click (debug.cef), and every main-thread stall
        # over the watchdog's threshold during it with its stack (debug.hangs), for the longest frame's cause.
        cef = run.rpc("debug.cef") or {}
        run.rpc("debug.hangs", {"clear": True})
        run.rpc("debug.frames", {"action": "start"})
    reply = run.rpc("debug.new_tab", params, timeout=opts.strip_ms / 1000 + 90) or {}
    if opts.strips and os.path.exists(os.path.join(folder, "strip.png")):
        os.makedirs(opts.strips, exist_ok=True)
        shutil.copy(os.path.join(folder, "strip.png"), os.path.join(opts.strips, f"{label}.png"))
    if opts.motion:
        frames = run.rpc("debug.frames", {"action": "stop"}) or {}
        reply["main_frames"] = {k: frames.get(k) for k in ("missed", "max_ms", "p99_ms", "refresh_ms", "expected_ms") if k in frames}
        reply["cef_before"] = {k: cef.get(k) for k in ("spare_window", "spare_page", "spare_pages_taken") if k in cef}
        reply["hangs"] = [{"ms": round(h.get("duration_ms") or 0, 1), "kind": h.get("kind"),
                           "frames": [str(f)[:90] for f in (h.get("frames") or [])[:30]]}
                          for h in (run.rpc("debug.hangs") or {}).get("records") or []]
        for hang in sorted(reply["hangs"], key=lambda h: -h["ms"])[:2]:
            say(f"right-pane-open: {label}: main-thread stall {hang['ms']} ms ({hang['kind']}; cef {reply['cef_before']}): "
                + " < ".join(hang["frames"][:24]))
    shutil.rmtree(folder, ignore_errors=True)
    return reply


# The header buttons whose second click closes the split the first opened (AgentChatSplitToggles.panels), timed for
# --motion: Browser (a Chromium page). Changes' second click left the chat's pane without its chat on the fleet
# (2026-11-06), so the rows after it measured nothing.
TOGGLES = ("browser",)
# A run of unchanged composited frames this long inside a transition splits it into two motions (about 33 ms at 120 Hz).
PHASE_GAP_FRAMES = 4


def motion_stats(frames):
    """How the window moved between the click's first visible change and its last one, from the composited frames.

    A frame is its pixel shares against the picture before the click and the settled one (inside the measured pane and
    outside it); an idle refresh repeats the last picture, so an unchanged frame inside the transition is one the
    window server showed while the motion stood still. `stall_frames`: such frames; `longest_stall_ms`: the longest
    standing run; `phases`: moving runs split by a stand of PHASE_GAP_FRAMES or more (1 is one continuous motion, 2 is a
    move and then a second step, such as content that pops in after the panes landed); `motion_ms`: first change to
    last change."""
    rows = [f for f in frames or [] if isinstance(f.get("ms"), (int, float))]
    keys = [(round(f.get("outside_vs_before") or 0, 4), round(f.get("outside_vs_final") or 0, 4),
             round(f.get("content_vs_before") or 0, 4), round(f.get("content_vs_final") or 0, 4)) for f in rows]
    changed = [i for i in range(1, len(rows)) if keys[i] != keys[i - 1] and rows[i]["ms"] >= 0]
    if not changed:
        return {"motion_ms": 0, "stall_frames": 0, "longest_stall_ms": 0, "phases": 0, "frames": 0}
    first, last = changed[0], changed[-1]
    stall, longest, phases, still = 0, 0.0, 1, 0
    for i in range(first + 1, last + 1):
        if keys[i] == keys[i - 1]:
            stall += 1
            still += 1
            longest = max(longest, rows[i]["ms"] - rows[i - still]["ms"])
        else:
            if still >= PHASE_GAP_FRAMES:
                phases += 1
            still = 0
    return {"motion_ms": round(rows[last]["ms"] - rows[first]["ms"], 1), "stall_frames": stall,
            "longest_stall_ms": round(longest, 1), "phases": phases, "frames": last - first + 1}


def measure_close(run, chat, click, label):
    """The same header button again (it toggles): the split closes; its whole-window motion and main-thread misses."""
    reply = strip(run, chat, click, label + "-close", content="none")
    if reply.get("error"):
        return {"error": str(reply["error"])[:400]}
    return {"motion": motion_stats(reply.get("frames")), "main_frames": reply.get("main_frames"),
            "commit_ms": next((f.get("ms") for f in reply.get("frames") or []
                               if (f.get("ms") or 0) > 0 and (f.get("outside_vs_before") or 0) > opts.strip_tolerance), None)}


def clicks(surface, round_index):
    """The click targets to try for `surface`, in order: the first one the page shows is clicked."""
    if surface in QUICK:
        return [{"selector": f'[data-quick-action="{QUICK[surface]}"]'}]
    if surface == "reopen_right":
        return [REOPEN_KEY]
    if surface == "subagent":
        order = [round_index % SUBAGENTS] + [k for k in range(SUBAGENTS - 1, -1, -1) if k != round_index % SUBAGENTS]
        texts = [t for k in order for t in (f"Auditor {k}", f"Audit area {k}: crashes, edge cases, slow paths")]
        return [{"text": t} for t in texts] + [{"selector": s} for s in SUBAGENT_LINES]
    if surface == "side_chat":
        return [{"text": "New side chat"}]
    if surface in SENDER_SURFACES:
        # The sender's own chip by its aria-label ("Open NAME", the name as the line shows it), else the name's text.
        name = (SENDERS.get(surface) or {}).get("name") or ""
        return [{"selector": f'{SENDER_CHIP}[aria-label*="{name}"]'}, {"text": name}]
    raise ValueError(surface)


def open_and_close_right(run, chat, round_index, before):
    """`reopen_right`'s untimed setup: a subagent's chat opened on the chat's right, shown, then closed (its pane goes
    with it), so the next Reopen Closed is that chat. Returns None, or what went wrong."""
    opened = {}
    for target in clicks("subagent", round_index):
        opened = run.rpc("debug.agent_pane", {"action": "click", **target, "pane": chat.pane}) or {}
        if NO_MATCH not in str(opened.get("error") or ""):
            break
    if opened.get("error"):
        return f"open the subagent: {str(opened['error'])[:300]}"
    if not STRESS.wait(lambda: chat.tabs() - before, 15, step=0.1):
        return "the subagent's chat never opened"
    time.sleep(2.5)  # test script: the subagent's chat draws its transcript before it closes, as a person reads it
    for tab in chat.tabs() - before:
        closed = chat.stress.action("closeTab", target=f"tab:{tab}", focus=False) or {}
        if closed.get("error"):
            return f"close the subagent's chat: {str(closed['error'])[:300]}"
    # A close that did not land would leave Cmd-Shift-T reopening an older entry, timed as this one.
    if not STRESS.wait(lambda: not (chat.tabs() - before), 10, step=0.1):
        return "the subagent's chat never closed"
    if not STRESS.wait(lambda: len(chat.stress.panes(chat.stress.workspace(chat.workspace))) <= 1, 10, step=0.1):
        return "the subagent's pane never closed"
    chat.show()
    time.sleep(0.6)  # test script: the close's own motion ends before the timed key
    return None


def pane_count(chat):
    return len(chat.stress.panes(chat.stress.workspace(chat.workspace)))


def measure(run, chat, surface, label, round_index):
    chat.repane()
    before = chat.tabs()
    sender = surface in SENDER_SURFACES
    if sender:
        if (SENDERS.get(surface) or {}).get("error") or not (SENDERS.get(surface) or {}).get("name"):
            return {"error": f"no message: {(SENDERS.get(surface) or {}).get('error') or 'not seeded'}", "opened_pane": False}
        panes_before = pane_count(chat)
        # Not timed: senders held in the chat's inbox (sender_local's and sender_unreached's both) fold into one
        # notice whose head lists them (InboxNoticeCard.tsx, two threads or more), and each sender's own chip shows
        # only once it is open, as a person opens it before clicking a name.
        expanded = run.rpc("debug.agent_pane", {"action": "click", "selector": INBOX_FOLDED, "pane": chat.pane}) or {}
        if not expanded.get("error"):
            time.sleep(0.4)  # test script: the notice's own motion ends
    if surface == "reopen_right":
        problem = open_and_close_right(run, chat, round_index, before)
        if problem:
            return {"error": problem, "close": chat.close_new(before)}
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
        return {"error": str(reply["error"])[:400], "click": target, "close": chat.close_new(before),
                **({"opened_pane": False} if sender else {})}
    # A click that failed in the app comes back in `key` (the gesture's own reply), not as the strip's error.
    clicked = reply.get("key") if isinstance(reply.get("key"), dict) else {}
    if clicked.get("error") or clicked.get("clicked") is False:
        return {"error": f"click: {clicked.get('error') or 'not clicked'}", "click": target, "key": clicked,
                "close": chat.close_new(before), **({"opened_pane": False} if sender else {})}
    record = cof.final_frame(reply.get("frames"), settle_frames=opts.settle_frames, tolerance=opts.strip_tolerance)
    record.update({"click": target, "commit_ms": reply.get("first_change_ms"), "final_ms": record.get("final_frame_ms"),
                   "strip_settled_ms": reply.get("settled_ms"), "frame_count": reply.get("frame_count"),
                   "mean_interval_ms": reply.get("mean_interval_ms"), "capture": reply.get("capture"),
                   "key": reply.get("key"), "spans": reply.get("spans"), "opened_tabs": len(chat.tabs() - before),
                   "frames": [[f.get("ms"), round(f.get("content_vs_before") or 0, 4), round(f.get("content_vs_final") or 0, 4),
                               round(f.get("flatness") or 0, 4), bool(f.get("blank"))] for f in reply.get("frames") or []],
                   "main_frames": reply.get("main_frames"), "motion": motion_stats(reply.get("frames")),
                   "cef_before": reply.get("cef_before"), "hangs": reply.get("hangs"),
                   "frames_columns": ["ms", "content_vs_before", "content_vs_final", "flatness", "blank"]})
    if not record["opened_tabs"]:
        record["error"] = "the click opened no tab"
    if sender:
        # Whether the click opened a pane on the chat's right at all: before the fix an unreached sender's click shows
        # a toast and opens nothing, which is that open's miss.
        record["opened_pane"] = pane_count(chat) > panes_before
        if surface == "sender_unreached" and not record["opened_pane"]:
            record["error"] = "the click opened no pane" + ("" if record["opened_tabs"] else " (no tab either)")
    if opts.motion and surface in TOGGLES and record["opened_tabs"]:
        record["close_motion"] = measure_close(run, chat, target, label)
    record["close"] = chat.close_new(before)
    if record["close"]:
        say(f"right-pane-open: {label}: the close left the layout changed (the next open runs in it): {json.dumps(record['close'])[:800]}")
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
    # The instant-splits four numbers (FOUR-NUMBERS table): blank frames, and dropped frames (the main thread's
    # missed refreshes with --motion, else frames standing still inside the transition).
    for key, pick in (("blank_frames", lambda r: r.get("blank_frames")),
                      ("dropped_frames", lambda r: (r.get("main_frames") or {}).get("missed")
                       if isinstance((r.get("main_frames") or {}).get("missed"), (int, float))
                       else (r.get("motion") or {}).get("stall_frames"))):
        values = [pick(r) for r in good]
        out[key] = {"p50": pct(values, 0.5), "p95": pct(values, 0.95), "max": pct(values, 1.0)}
    out["over"] = over_budget(out)
    # Opens whose window motion ran in two phases or more (motion_stats): a placement in two steps, or late content.
    out["multi_phase"] = sum(1 for r in good if ((r.get("motion") or {}).get("phases") or 0) >= 2)
    if opts.motion:
        out["motion"] = motion_summary([r.get("motion") for r in good], [r.get("main_frames") for r in good])
        closes = [r.get("close_motion") for r in good if isinstance(r.get("close_motion"), dict) and not r["close_motion"].get("error")]
        if closes:
            out["close_motion"] = motion_summary([c.get("motion") for c in closes], [c.get("main_frames") for c in closes])
    return out


def motion_summary(motions, mains):
    motions = [m for m in motions if isinstance(m, dict)]
    mains = [m for m in mains if isinstance(m, dict)]
    out = {"n": len(motions)}
    for key in ("motion_ms", "stall_frames", "longest_stall_ms", "phases"):
        values = [m.get(key) for m in motions]
        out[key] = {"p50": pct(values, 0.5), "p95": pct(values, 0.95), "max": pct(values, 1.0)}
    for key in ("missed", "max_ms"):
        values = [m.get(key) for m in mains]
        out["main_" + key] = {"p50": pct(values, 0.5), "p95": pct(values, 0.95), "max": pct(values, 1.0)}
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
             "", "| surface | condition | n | commit | content | final | multi-phase | over |", "|---|---|---|---|---|---|---|---|"]
    for surface in WANTED:
        for condition in CONDITIONS:
            s = results["surfaces"].get(surface, {}).get(condition)
            if not s:
                continue
            lines.append(f"| {surface} | {condition} | {s['ok']}/{s['n']} | {triple(s, 'commit_ms')} | {triple(s, 'first_content_ms')} | "
                         f"{triple(s, 'final_ms')} | {s.get('multi_phase', 0)} | {s['over'] or 'ok'} |")
    if opts.motion:
        lines += ["", "Transition (--motion): composited frames from the first change to the last, p50/p95/max. stalls: unchanged "
                  "frames inside it; longest stall ms; phases: moving runs split by a stand of "
                  f"{PHASE_GAP_FRAMES}+ frames (1 = one motion); main missed / longest main-thread frame ms (debug.frames).",
                  "", "| surface | condition | step | n | motion ms | stalls | longest stall | phases | main missed | main longest |",
                  "|---|---|---|---|---|---|---|---|---|---|"]
        for surface in WANTED:
            for condition in CONDITIONS:
                s = results["surfaces"].get(surface, {}).get(condition) or {}
                for step in ("motion", "close_motion"):
                    m = s.get(step)
                    if m:
                        lines.append(f"| {surface} | {condition} | {'open' if step == 'motion' else 'close'} | {m['n']} | {triple(m, 'motion_ms')} | "
                                     f"{triple(m, 'stall_frames')} | {triple(m, 'longest_stall_ms')} | {triple(m, 'phases')} | "
                                     f"{triple(m, 'main_missed')} | {triple(m, 'main_max_ms')} |")
    lines += ["", "FOUR-NUMBERS (instant-splits, goals/instant-splits.md in cmuxterm-hq): ms from the click, p50/p95/max. "
              "first change = commit; settled = final; blank = frames whose pane was flat and unlike before and after; "
              "dropped = main-thread missed refreshes (--motion), else frames standing still inside the transition.",
              "", "| surface | condition | first change | settled | blank frames | dropped frames |", "|---|---|---|---|---|---|"]
    for surface in WANTED:
        for condition in CONDITIONS:
            s = results["surfaces"].get(surface, {}).get(condition)
            if s and s.get("ok"):
                lines.append(f"| {surface} | {condition} | {triple(s, 'commit_ms')} | {triple(s, 'final_ms')} | "
                             f"{triple(s, 'blank_frames')} | {triple(s, 'dropped_frames')} |")
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

def set_tunables(run):
    if not opts.tunable:
        return
    run.rpc("debug.tunables", {"action": "activate"})  # a bench build's tunable store is off until asked (debug-settings.md)
    for item in opts.tunable:
        key, _, value = item.partition("=")
        row = run.rpc("debug.tunables", {"action": "set", "key": key, "value": value}) or {}
        say(f"right-pane-open: tunable {key}={value}: {json.dumps(row)[:200]}")


def run_surfaces(run, chat, condition, results, rounds):
    for surface in WANTED:
        records = results["raw"].setdefault(surface, {}).setdefault(condition, [])
        for index in range(rounds):
            try:
                record = measure(run, chat, surface, f"{condition}-{surface}-{len(records)}", len(records))
            except STRESS.StressShapeError as error:  # one open's broken layout is its row's miss, not the run's end
                record = {"error": f"layout: {str(error)[:400]}"}
            records.append(record)
            say(f"right-pane-open: {condition} {surface} {len(records) - 1}: commit_ms={record.get('commit_ms')} "
                f"first_content_ms={record.get('first_content_ms')} final_ms={record.get('final_ms')} "
                f"blank={record.get('blank_frames')} between={record.get('between_frames')}"
                + (f" error={record['error']}" if record.get("error") else ""))


def main():
    root = tempfile.mkdtemp(prefix="right-pane-open-")
    results = {"tunables": opts.tunable, "host": socket.gethostname(), "ncpu": NCPU, "app": APP,
               "model": subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip(),
               "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "surfaces": {}, "raw": {}, "conditions": {}}
    signal.signal(signal.SIGTERM, bm.interrupted)
    load = Load(root)
    runs, display, peer = {}, None, None
    try:
        if opts.vdisplay:
            try:
                display = STRESS.start_vdisplay(opts.vdisplay, root, hold=6 * 3600)
                results["display"] = {"vdisplay_hz": opts.vdisplay, "size": STRESS.VDISPLAY_SIZE}
            except STRESS.StressShapeError as error:
                # Measured on the host's display; STRESS then says why its window does not fit.
                results["display"] = {"vdisplay_hz": opts.vdisplay, "error": str(error)[:400]}
                say(f"right-pane-open: VDISPLAY-FALLBACK {error}")
            time.sleep(2)  # test script: WindowServer settles the new main display before the app opens on it
        repo = make_repo(root)
        say("right-pane-open: seeding")
        home, chats, meta_keys = seed(root, repo)
        results["seed"] = {"subagents": SUBAGENTS, "meta_keys": meta_keys}
        if "sender_peer" in WANTED:
            # sender_peer's remote machine, for the whole run: a failed start is that surface's misses only.
            peer = PeerSender(root)
            try:
                peer.start()
                results["seed"]["peer_sender"] = {"session": peer.chat, "turns": PEER_TURNS}
            except (SenderError, SystemExit, OSError, RuntimeError, subprocess.SubprocessError) as error:
                results["seed"]["peer_sender"] = {"error": f"{type(error).__name__}: {str(error)[:500]}"}
                say(f"right-pane-open: the peer sender did not start: {results['seed']['peer_sender']['error']}")
                peer.chat = None
        for condition in CONDITIONS:
            info = {}
            try:
                run_condition(condition, runs, home, chats, load, results, info, peer)
            except (Exception, SystemExit) as error:  # noqa: BLE001 - one condition's failure is its record; the next still runs
                info["error"] = f"{type(error).__name__}: {str(error)[:600]}"
                say(f"right-pane-open: {condition} did not finish: {info['error']}")
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
        if runs.get("run"):
            runs["run"].end()
        if peer:
            peer.stop()  # the daemon this script started, and the agent hosts under it
        if display:
            display.terminate()  # the helper this script started, by its process
            display.wait()
        if opts.strips and os.path.isdir(opts.strips):
            subprocess.run(["tar", "-czf", opts.strips.rstrip("/") + ".tgz", "-C", opts.strips, "."], check=False)
        shutil.rmtree(root, ignore_errors=True)
    failed = [c for c in CONDITIONS if results["conditions"].get(c, {}).get("error")]
    if failed:
        raise SystemExit(f"right-pane-open: {', '.join(failed)} did not finish (the table has every condition that did)")


def run_condition(condition, runs, home, chats, load, results, info, peer=None):
    """One condition on a fresh app. `runs` holds the app now launched (["run"]), so an error part way through
    still ends it before the next condition. `peer`: sender_peer's daemon (PeerSender), when that surface runs."""
    if runs.get("run"):
        runs["run"].end()
    wipe_state(APP)
    run = runs["run"] = Run(home)
    run.launch()
    set_tunables(run)
    if not results.get("app_version"):
        results["app_version"] = (run.app.identify() or {}).get("version")
    time.sleep(5)  # test script: let launch work end before the chat opens
    chat = Chat(run)
    chat.open(chats[condition])
    if any(s in SENDER_SURFACES for s in WANTED):
        # The sender_* messages, through the app's own daemon now that it runs (untimed); the chat shown again after.
        info["senders"] = seed_senders(home, chats[condition], condition, peer)
        chat.show()
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
        for _ in range(opts.restarts):
            run.quit()
            run.launch()
            set_tunables(run)
            chat = Chat(run)
            chat.find()
            info.setdefault("restored_panes", []).append(chat.pane)
            run_surfaces(run, chat, condition, results, 1)
    else:
        run_surfaces(run, chat, condition, results, opts.runs)

if __name__ == "__main__":
    main()
