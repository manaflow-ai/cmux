#!/usr/bin/env python3
"""session_real.py: ONE shared bench session of the size of the person who uses the app.

His session, read from his one session daemon on 2026-11-10: 826 workspaces, 858 panes, 1600 tabs,
798 terminals, 170 agents, 13 clients. Every bench owner uses this script (or the HOME it saved)
for the `real` session arm; nobody writes a second "800" maker.

The mix rule is the one of the test fixture `SessionFixtureSize.real`
(Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/SessionFixtureSize.swift), so a count test and a
bench row talk about the same session. With pick(i, k, n) = "k of n, spread evenly":
  1. `--terminals` of the `--workspaces` start with a terminal; the others hold one agent chat.
  2. `--agents` of the terminals are agent terminals (see "What an agent is").
  3. The second tabs (`--tabs` minus one per workspace) go to terminal workspaces; `--browser-tabs`
     of them are pages (Chromium and WebKit in turn), the others are agent chats. (The fixture
     cycles chat, Chromium, WebKit; the sums are the same: 286 chats, 258 + 258 pages.)
  4. `--panes` minus `--workspaces` of the second tabs are in a second pane (a split to the right).

PTY limit. macOS has `kern.tty.ptmx_max` PTYs for the whole machine (511 on the bench minis and
on a default Mac), and the daemon keeps a reserve (PTY_RESERVE 64, pty_reclaim.rs). So 798 shells
never run at one time, in his session neither: the daemon parks idle ones (`park-tabs`; the tab
stays, its shell starts again when its workspace is shown). `make` does the same on purpose:
the agent terminals and `--live-shells` plain terminals keep a shell, the others are parked. It
prints the split and the limit; it never makes fewer terminals than asked without an error.

What an agent is. Not a model session (170 of them cost money and their load is not repeatable).
An agent terminal runs `session_real_agent.zsh`: a program that draws like an agent TUI (prompt
box; a spinner line and a title at 10 Hz and one output line a second while it works) and reports
its state through the product's own path, the hook helper every cmux-tui terminal exports
(`$CMUX_TUI_HOOK claude <event>`). So the daemon's agent roster, the sidebar's agent marks and the
restore rule ("a kept tab whose terminal ran an agent starts again at launch") all see an agent.
`--agents-working` of them work (the default 8 is a guess of his usual state, written in each
result); the others wait at their prompt and print nothing.

Commands (every one takes `--socket <daemon socket>` or `--app-socket <app debug socket>`):
  make     make the session in a running daemon, in batches; print the counts read back and the time
  counts   print the counts read back from the daemon (and from the app with --app-socket)
  agents   start the agent program in every agent terminal (after `make --no-agents`, or after a
           restore: a restored agent terminal has a new shell, its program is not run again)
  clients  hold N more control connections open, as his 13 clients do, until killed
  measure  memory of app + daemon + terminal hosts, process count, PTYs, idle CPU, main wakes/s
  map      the first map: 20 runs each of workspace switch, tab switch, new tab, split, workspace
           close on the app's own clocks (p50 / p95 / max)
  build    make the saved session of a bench app with no app and no GUI lock (its daemon, headless)
  launch   start the bench app on its saved session: restore time, then other commands, then quit
  save     copy the tag's state folder of a QUIT app to a folder (a saved session made live)
  install  put a saved session in place as the state of its tag (the app must not run)
  uninstall  remove that copy and put the tag's old state back

A saved session is the folder `~/Library/Application Support/cmux-next/tags/<tag>` of a bench app
whose daemon stopped with "End Sessions, Keep Layout" (`debug.quit {fixture_quit:"end-sessions"}`,
what `bench_launch.BenchApp.stop` sends). It is tied to the tag: the registry names its session
`cmux-app-<tag>` and the daemon refuses another one's. So each twin tag gets its own saved session
(`build`, about two minutes), and a clone of a twin that keeps the bundle name uses the same one.

Only on a fleet mini, never on a person's Mac: `make` starts hundreds of processes.
"""

import argparse
import json
import os
import pwd
import re
import shutil
import socket
import subprocess
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT_PROGRAM = os.path.join(HERE, "session_real_agent.zsh")
REAL = {"workspaces": 826, "panes": 858, "tabs": 1600, "terminals": 798, "agents": 170, "browser_tabs": 516, "clients": 13}
PTY_RESERVE = 64  # cmux-tui pty_reclaim.rs: the PTYs the daemon keeps free for new terminals
NAME = re.compile(r"^real-(\d{4})$")


# ---------------------------------------------------------------- the mix rule

def pick(i, k, n):
    """Picks exactly k of the positions 0..n-1, evenly. The picked position's rank (0..k-1), else None."""
    if k <= 0 or n <= 0:
        return None
    rank = i * k // n
    return rank if i == 0 or rank > (i - 1) * k // n else None


class Mix:
    """The shape of each workspace (1-based): a list of panes, each a list of tab kinds
    ("terminal", "agent", "chat", "chromium", "webkit")."""

    def __init__(self, workspaces, terminals, agents, tabs, panes, browser_tabs):
        self.workspaces, self.terminals, self.agents = workspaces, terminals, agents
        self.seconds = tabs - workspaces
        self.chats = self.seconds - browser_tabs
        self.splits = panes - workspaces
        faults = []
        if not 0 < terminals <= workspaces:
            faults.append(f"--terminals {terminals} must be 1..{workspaces} (one per workspace at most)")
        if not 0 <= agents <= terminals:
            faults.append(f"--agents {agents} must be 0..{terminals}")
        if not 0 <= self.seconds <= terminals:
            faults.append(f"--tabs {tabs} must be {workspaces}..{workspaces + terminals} (two tabs per workspace at most)")
        if not 0 <= browser_tabs <= max(self.seconds, 0):
            faults.append(f"--browser-tabs {browser_tabs} must be 0..{self.seconds}")
        if not 0 <= self.splits <= max(self.seconds, 0):
            faults.append(f"--panes {panes} must be {workspaces}..{workspaces + self.seconds}")
        if faults:
            raise SystemExit("session_real: " + "; ".join(faults))
        self._shapes = {}
        pages = 0
        for workspace in range(1, workspaces + 1):
            terminal = pick(workspace - 1, terminals, workspaces)
            if terminal is None:
                self._shapes[workspace] = [["chat"]]
                continue
            first = "terminal" if pick(terminal, agents, terminals) is None else "agent"
            second = pick(terminal, self.seconds, terminals)
            if second is None:
                self._shapes[workspace] = [[first]]
                continue
            if pick(second, self.chats, self.seconds) is not None:
                kind = "chat"
            else:
                kind = ("chromium", "webkit")[pages % 2]
                pages += 1
            split = pick(second, self.splits, self.seconds) is not None
            self._shapes[workspace] = [[first], [kind]] if split else [[first, kind]]

    def shape(self, workspace):
        return self._shapes[workspace]

    def count(self, *kinds):
        return sum(1 for shape in self._shapes.values() for pane in shape for tab in pane if not kinds or tab in kinds)

    def summary(self):
        return {
            "workspaces": self.workspaces,
            "panes": sum(len(shape) for shape in self._shapes.values()),
            "tabs": self.count(),
            "terminals": self.count("terminal", "agent"),
            "agent_terminals": self.count("agent"),
            "agent_chats": self.count("chat"),
            "chromium_pages": self.count("chromium"),
            "webkit_pages": self.count("webkit"),
        }


def mix_of(args):
    return Mix(args.workspaces, args.terminals, args.agents, args.tabs, args.panes, args.browser_tabs)


# ---------------------------------------------------------------- sockets

class Conn:
    """One connection of the daemon's raw control protocol (JSON lines, cmux-tui/spec/commands.md)."""

    def __init__(self, path, timeout=120):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buf = b""
        self.next_id = 1
        # With `conversation-tabs-v1` the tree names a chat tab `conversation`; without it a chat reads as `browser`.
        self.call("set-client-info", name="session-real", kind="bench", capabilities=["conversation-tabs-v1", "agent-session-tabs-v1"])

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def call(self, cmd, **params):
        rid = self.next_id
        self.next_id += 1
        self.sock.sendall((json.dumps({"id": rid, "cmd": cmd, **params}) + "\n").encode())
        while True:
            while b"\n" not in self.buf:
                chunk = self.sock.recv(1 << 20)
                if not chunk:
                    raise ConnectionError("control socket closed")
                self.buf += chunk
            line, self.buf = self.buf.split(b"\n", 1)
            msg = json.loads(line)
            if msg.get("id") == rid and "ok" in msg:
                return msg

    def must(self, cmd, **params):
        resp = self.call(cmd, **params)
        if not resp.get("ok"):
            raise RuntimeError(f"{cmd} failed: {resp.get('error')!r} {resp.get('error_code', '')}")
        data = resp.get("data")
        return {} if data is None else data


def app_rpc(sock, method, params=None, timeout=60):
    """One request on the app's debug socket; the result, or raises."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(timeout)
        conn.connect(sock)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    reply = json.loads(buf or b"{}")
    if not reply.get("ok", "result" in reply):
        raise RuntimeError(f"{method}: {reply.get('error') or 'no answer'}")
    return reply.get("result")


def daemon_of_app(app_socket):
    """(daemon pid, daemon socket) of the daemon the app says it is connected to (`debug.daemon`)."""
    state = app_rpc(app_socket, "debug.daemon", timeout=10) or {}
    pid = state.get("pid")
    if not pid:
        raise SystemExit(f"session_real: the app on {app_socket} names no daemon: {state!r}")
    line = subprocess.run(["ps", "-o", "args=", "-p", str(int(pid))], capture_output=True, text=True).stdout
    found = re.search(r"--socket[ =](\S+)", line)
    if not found:
        raise SystemExit(f"session_real: daemon {pid} has no --socket argument: {line.strip()!r}")
    return int(pid), found.group(1)


def sockets(args):
    """(daemon socket, app socket or None). Refuses an app that is not a tagged DEV build."""
    if args.app_socket:
        info = app_rpc(args.app_socket, "system.identify", timeout=10) or {}
        bundle = info.get("app_bundle_path") or ""
        if ".debug" not in (info.get("bundle_id") or "") or bundle.startswith("/Applications/"):
            raise SystemExit(f"session_real: refusing {bundle!r} ({info.get('bundle_id')}): not a tagged DEV build")
        return daemon_of_app(args.app_socket)[1], args.app_socket
    if not args.socket:
        raise SystemExit("session_real: give --socket <daemon socket> or --app-socket <app debug socket>")
    return args.socket, None


# ---------------------------------------------------------------- reading back

def sysctl(name):
    out = subprocess.run(["sysctl", "-n", name], capture_output=True, text=True).stdout.strip()
    return int(out) if out.isdigit() else None


def ptys_in_use():
    """PTYs in use on the machine by this user's processes: the distinct devices behind the open
    /dev/ptmx handles (a terminal's host and the daemon hold several handles of one PTY)."""
    out = subprocess.run(["lsof", "-n", "-w", "/dev/ptmx"], capture_output=True, text=True).stdout
    return len({fields[5] for fields in (line.split() for line in out.splitlines()[1:]) if len(fields) > 5})


def walk(tree):
    """(workspace, screen, pane, tab) of every tab of a `list-workspaces` tree."""
    for workspace in tree.get("workspaces", []):
        for screen in workspace.get("screens", []):
            for pane in screen.get("panes", []):
                for tab in pane.get("tabs", []):
                    yield workspace, screen, pane, tab


def is_terminal(tab):
    return tab.get("kind") == "pty"


def is_parked(tab):
    return bool(tab.get("dead")) and bool((tab.get("relaunch") or {}).get("on_show"))


def tab_kind(tab):
    """terminal, chat, chromium, webkit, or the raw kind."""
    if is_terminal(tab):
        return "terminal"
    if tab.get("kind") == "conversation" or tab.get("conversation"):
        return "chat"
    if tab.get("kind") == "browser":
        return {"cef": "chromium"}.get(tab.get("browser_engine"), tab.get("browser_engine") or "page")
    return str(tab.get("kind"))


def counts(conn, app_socket=None):
    """The counts read back from the daemon (and the app's own model with `app_socket`)."""
    tree = conn.must("list-workspaces")
    workspaces = tree.get("workspaces", [])
    tabs = list(walk(tree))
    terminals = [tab for _, _, _, tab in tabs if is_terminal(tab)]
    kinds = {}
    for _, _, _, tab in tabs:
        kinds[tab_kind(tab)] = kinds.get(tab_kind(tab), 0) + 1
    out = {
        "workspaces": len(workspaces),
        "screens": sum(len(w.get("screens", [])) for w in workspaces),
        "panes": sum(len(s.get("panes", [])) for w in workspaces for s in w.get("screens", [])),
        "tabs": len(tabs),
        "terminals": len(terminals),
        "terminals_live": sum(1 for tab in terminals if not tab.get("dead")),
        "terminals_parked": sum(1 for tab in terminals if is_parked(tab)),
        "terminals_dead_other": sum(1 for tab in terminals if tab.get("dead") and not is_parked(tab)),
        "tab_kinds": kinds,
    }
    agents = conn.call("list-agents")
    if agents.get("ok"):
        states = {}
        for agent in (agents.get("data") or {}).get("agents", []):
            state = agent.get("status") or agent.get("state") or "?"
            states[state] = states.get(state, 0) + 1
        out["agents"] = sum(states.values())
        out["agent_states"] = states
    clients = conn.call("list-clients")
    if clients.get("ok"):
        out["clients"] = len(clients.get("data") or [])
    out["ptys_in_use_machine"] = ptys_in_use()
    out["kern.tty.ptmx_max"] = sysctl("kern.tty.ptmx_max")
    if app_socket:
        out["app"] = app_counts(app_socket)
    return out


def app_counts(app_socket):
    """What the app's own model holds (`snapshot.get`): the counts a person's window is built from."""
    try:
        snap = app_rpc(app_socket, "snapshot.get", timeout=120) or {}
    except (RuntimeError, OSError, ValueError) as error:
        return {"error": str(error)}
    topology = snap.get("topology") or snap
    workspaces = topology.get("workspaces") or []
    panes = tabs = terminals = 0
    for workspace in workspaces:
        for screen in workspace.get("screens") or [workspace]:
            for pane in screen.get("panes") or []:
                panes += 1
                for tab in pane.get("tabs") or []:
                    tabs += 1
                    terminals += 1 if tab.get("kind") in ("pty", "terminal") else 0
    return {"loaded": topology.get("loaded"), "daemon_state": topology.get("daemon_state"),
            "workspaces": len(workspaces), "panes": panes, "tabs": tabs, "terminals": terminals}


def agent_tabs(tree, mix):
    """(workspace number, tab) of each agent terminal of a session `make` made: the first terminal of
    a workspace named real-NNNN whose shape starts with an agent terminal."""
    found = []
    for workspace in tree.get("workspaces", []):
        named = NAME.match(workspace.get("name") or "")
        if not named or int(named.group(1)) > mix.workspaces:
            continue
        number = int(named.group(1))
        if mix.shape(number)[0][0] != "agent":
            continue
        for screen in workspace.get("screens", []):
            for pane in screen.get("panes", []):
                for tab in pane.get("tabs", []):
                    if is_terminal(tab):
                        found.append((number, tab))
                        break
                else:
                    continue
                break
            else:
                continue
            break
    return found


# ---------------------------------------------------------------- make

def pty_budget(mix, live_shells):
    """Refuses a live-terminal count the machine cannot hold; prints the limit with its number."""
    limit, used = sysctl("kern.tty.ptmx_max"), ptys_in_use()
    live = mix.count("agent") + live_shells
    line = (f"PTY limit: kern.tty.ptmx_max={limit} for the whole machine, {used} in use now, daemon reserve {PTY_RESERVE}. "
            f"Terminals {mix.count('terminal', 'agent')} = {live} with a shell ({mix.count('agent')} agent + {live_shells} plain) "
            f"+ {mix.count('terminal', 'agent') - live} parked (shell starts when the workspace is shown).")
    print(line, flush=True)
    if limit is not None and used + live + PTY_RESERVE > limit:
        raise SystemExit(f"session_real: LIMIT kern.tty.ptmx_max={limit}: {used} in use + {live} live + reserve {PTY_RESERVE} "
                         f"= {used + live + PTY_RESERVE}. Give a smaller --live-shells, or free PTYs; the size is not lowered for you.")
    return line


def agent_command(number, state):
    """The shell line that starts the agent program in an agent terminal (a leading space keeps it out of history)."""
    return f" exec /bin/zsh -f {shell_quote(AGENT_PROGRAM)} {state} real-{number:04d}\n"


def shell_quote(text):
    return "'" + text.replace("'", "'\\''") + "'"


def agent_state(rank, args):
    if rank < args.agents_working:
        return "working"
    if rank < args.agents_working + args.agents_blocked:
        return "blocked"
    return "idle"


def make(args):
    mix = mix_of(args)
    daemon_socket, app_socket = sockets(args)
    live_plain = min(args.live_shells, mix.count("terminal"))
    limit_line = pty_budget(mix, live_plain)
    conn = Conn(daemon_socket)
    before = counts(conn)
    print(f"before: {json.dumps(before)}", flush=True)
    started = time.time()
    plain_seen = agents_seen = made = 0
    to_park, agent_surfaces, step_times = [], [], []
    batch_started = time.time()
    for number in range(1, mix.workspaces + 1):
        shape = mix.shape(number)
        workspace = conn.must("create-workspace", name=f"real-{number:04d}")["workspace"]
        first = shape[0][0]
        pane = None
        chat = {"host": "install:session-real", "session": f"real-{number:04d}", "harness": "claude"}
        if first == "chat":
            conn.must("new-conversation-tab", workspace=workspace, agent_session=chat)
        else:
            terminal = conn.must("create-terminal", workspace=workspace, cwd=args.cwd)
            pane = terminal.get("pane")
            if first == "agent":
                agent_surfaces.append((number, terminal["surface"], agent_state(agents_seen, args)))
                agents_seen += 1
            else:
                if pick(plain_seen, live_plain, mix.count("terminal")) is None:
                    to_park.append(terminal["surface"])
                plain_seen += 1
        for index, kind in enumerate(tab for pane_tabs in shape for tab in pane_tabs):
            if index == 0:
                continue
            split = {"split": {"direction": "right"}} if len(shape) > 1 else {}
            if kind == "chat":
                conn.must("new-conversation-tab", pane=pane, agent_session=chat, **split)
            else:
                conn.must("new-frontend-browser-tab", pane=pane, url=args.browser_url, title=f"Page {number}",
                          engine="cef" if kind == "chromium" else "webkit", activate=False, **split)
        made += 1
        if made % args.batch == 0 or number == mix.workspaces:
            if to_park:
                parked = conn.must("park-tabs", surfaces=to_park).get("parked", [])
                if len(parked) != len(to_park):
                    print(f"park-tabs: asked {len(to_park)}, parked {len(parked)}", flush=True)
                to_park = []
            if not args.no_agents:
                for agent_number, surface, state in agent_surfaces:
                    conn.must("send", surface=surface, text=agent_command(agent_number, state))
                agent_surfaces = []
            step_times.append(round(time.time() - batch_started, 3))
            print(f"made {made}/{mix.workspaces} workspaces, batch {step_times[-1]} s, PTYs in use {ptys_in_use()}", flush=True)
            batch_started = time.time()
    seconds = time.time() - started
    settle_agents(conn, 0 if args.no_agents else mix.count("agent"), args.settle)
    after = counts(conn, app_socket)
    want = mix.summary()
    result = {
        "asked": want, "limit": limit_line, "make_seconds": round(seconds, 2), "batch_seconds": step_times,
        "batch": args.batch, "agents_working": args.agents_working, "agents_blocked": args.agents_blocked,
        "before": before, "after": after, "host": host_facts(),
    }
    print("SESSION-REAL " + json.dumps(result), flush=True)
    faults = []
    for key in ("workspaces", "panes", "tabs", "terminals"):
        if after[key] - before[key] != want[key]:
            faults.append(f"{key}: asked {want[key]}, read back {after[key] - before[key]} more than before")
    kinds = {"chat": want["agent_chats"], "chromium": want["chromium_pages"], "webkit": want["webkit_pages"]}
    for kind, asked in kinds.items():
        got = after["tab_kinds"].get(kind, 0) - before["tab_kinds"].get(kind, 0)
        if got != asked:
            faults.append(f"{kind} tabs: asked {asked}, read back {got} more than before")
    if not args.no_agents and after.get("agents", 0) - before.get("agents", 0) != want["agent_terminals"]:
        faults.append(f"agents: asked {want['agent_terminals']}, the daemon lists {after.get('agents', 0) - before.get('agents', 0)} more than before")
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=1)
    if faults:
        raise SystemExit("session_real: READ-BACK DIFFERS: " + "; ".join(faults))
    print(f"OK: made and read back {want} in {seconds:.1f} s", flush=True)


def settle_agents(conn, want, seconds):
    """Waits until the daemon lists `want` agents (each reports through its hook helper), at most `seconds`."""
    deadline = time.time() + seconds
    while want and time.time() < deadline:
        agents = conn.call("list-agents")
        if agents.get("ok") and len((agents.get("data") or {}).get("agents", [])) >= want:
            return
        time.sleep(0.5)


def host_facts():
    def run(*cmd):
        return subprocess.run(list(cmd), capture_output=True, text=True).stdout.strip()
    return {"host": socket.gethostname(), "macos": run("sw_vers", "-productVersion"), "load": run("sysctl", "-n", "vm.loadavg"),
            "kern.tty.ptmx_max": sysctl("kern.tty.ptmx_max"), "kern.maxprocperuid": sysctl("kern.maxprocperuid"),
            "kern.maxfilesperproc": sysctl("kern.maxfilesperproc")}


# ---------------------------------------------------------------- agents, clients

def agents(args):
    """Starts the agent program in every agent terminal that has a shell and no agent yet."""
    mix = mix_of(args)
    daemon_socket, _ = sockets(args)
    conn = Conn(daemon_socket)
    tree = conn.must("list-workspaces")
    listed = {agent.get("surface") for agent in (conn.must("list-agents") or {}).get("agents", [])}
    started = restarted = skipped = 0
    waiting = []
    for rank, (number, tab) in enumerate(agent_tabs(tree, mix)):
        surface = tab["surface"]
        if surface in listed and not tab.get("dead") and not args.force:
            skipped += 1
            continue
        if tab.get("dead"):
            reply = conn.call("restart-tab", surface=surface)
            if not reply.get("ok") and reply.get("error_code") != "tab-not-dead":
                print(f"restart-tab real-{number:04d}: {reply.get('error')!r}", flush=True)
                continue
            restarted += 1
        waiting.append((number, surface, agent_state(rank, args)))
    deadline = time.time() + args.settle
    while waiting and time.time() < deadline:
        still = []
        for number, surface, state in waiting:
            reply = conn.call("send", surface=surface, text=agent_command(number, state))
            if reply.get("ok"):
                started += 1
            else:
                still.append((number, surface, state))  # the new shell is not in the tab yet
        waiting = still
        if waiting:
            time.sleep(0.5)
    settle_agents(conn, len(agent_tabs(tree, mix)) - len(waiting), args.settle)
    after = counts(conn)
    print("SESSION-REAL-AGENTS " + json.dumps({"started": started, "restarted_shells": restarted, "already_running": skipped,
                                                "not_started": len(waiting), "after": after}), flush=True)
    if waiting:
        raise SystemExit(f"session_real: {len(waiting)} agent terminals took no input")


def clients(args):
    """Holds `--count` more control connections open (each named and subscribed to tree deltas, as
    an app window or a phone is), and reads what the daemon sends them, until killed or `--seconds`."""
    daemon_socket, _ = sockets(args)
    held = []
    if args.total:
        probe = Conn(daemon_socket)
        args.count = max(0, args.total - (len(probe.must("list-clients")) - 1))  # without this probe itself
        probe.close()
    for index in range(args.count):
        conn = Conn(daemon_socket)
        conn.call("set-client-info", name=f"session-real-client-{index + 1}")
        conn.must("subscribe", tree_events="deltas")
        conn.sock.setblocking(False)
        held.append(conn)
    listed = Conn(daemon_socket)
    print(f"SESSION-REAL-CLIENTS held {len(held)}, the daemon lists {len(listed.must('list-clients'))} (with this one)", flush=True)
    listed.close()
    deadline = time.time() + args.seconds if args.seconds else None
    received = 0
    try:
        while deadline is None or time.time() < deadline:
            time.sleep(0.25)
            for conn in held:
                try:
                    while True:
                        chunk = conn.sock.recv(1 << 20)
                        if not chunk:
                            raise SystemExit("session_real: the daemon closed a client connection")
                        received += len(chunk)
                except BlockingIOError:
                    pass
    except KeyboardInterrupt:
        pass
    print(f"SESSION-REAL-CLIENTS done, {received} bytes of events read", flush=True)


# ---------------------------------------------------------------- measure

def process_table():
    """pid -> (ppid, rss KiB, cpu seconds, command) of every process of this user."""
    out = subprocess.run(["ps", "-U", str(os.getuid()), "-o", "pid=,ppid=,rss=,time=,command="], capture_output=True, text=True).stdout
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        clock = [float(x) for x in parts[3].replace("-", ":").split(":")]
        cpu = sum(value * 60 ** power for power, value in enumerate(reversed(clock)))
        table[int(parts[0])] = (int(parts[1]), int(parts[2]), cpu, parts[4])
    return table


def footprint_mb(pid):
    """`footprint` physical footprint in MB (what Activity Monitor's Memory column shows), else None."""
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    found = re.search(r"phys_footprint:\s*([\d.]+)\s*(KB|MB|GB)", out) or re.search(r"Footprint:\s*([\d.]+)\s*(KB|MB|GB)", out)
    if not found:
        return None
    return round(float(found.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[found.group(2)], 1)


def groups(table, app_pid, daemon_pid, bundle):
    """The session's processes by role: app, app helpers (children of the app), daemon, terminal
    hosts and their shells and programs (the daemon's descendants and every `cmux-tui` host of this bundle)."""
    children = {}
    for pid, (ppid, _, _, _) in table.items():
        children.setdefault(ppid, []).append(pid)

    def below(root):
        found, stack = [], list(children.get(root, []))
        while stack:
            pid = stack.pop()
            found.append(pid)
            stack.extend(children.get(pid, []))
        return found

    role = {app_pid: "app", daemon_pid: "daemon"}
    for pid in below(app_pid):
        role.setdefault(pid, "app_helpers")
    for pid in below(daemon_pid):
        role.setdefault(pid, "daemon_children")
    for pid, (_, _, _, command) in table.items():
        if pid not in role and bundle and command.startswith(bundle + "/") and "cmux-tui" in command.split(" ")[0]:
            role[pid] = "terminal_hosts"
            for child in below(pid):
                role.setdefault(child, "terminal_programs")
    return role


def measure(args):
    daemon_socket, app_socket = sockets(args)
    if not app_socket:
        raise SystemExit("session_real: measure needs --app-socket")
    info = app_rpc(app_socket, "system.identify", timeout=10)
    app_pid, bundle = int(info["pid"]), info.get("app_bundle_path") or ""
    daemon_pid = daemon_of_app(app_socket)[0]
    first = process_table()
    role = groups(first, app_pid, daemon_pid, bundle)
    def soft(method, params=None):
        try:
            return app_rpc(app_socket, method, params, timeout=20) or {}
        except (RuntimeError, OSError, ValueError) as error:
            return {"error": str(error)}

    wakes_before = soft("debug.hangs", {"clear": True}).get("main_wakes")
    soft("debug.frames", {"action": "start"})
    started = time.time()
    time.sleep(args.seconds)
    elapsed = time.time() - started
    second = process_table()
    frames = soft("debug.frames", {"action": "stop", "raw": True})
    hangs = soft("debug.hangs")
    intervals, busy = frames.get("intervals_ms") or [], frames.get("main_ms") or []
    wakes = {
        "main_wakes_per_s": round((hangs.get("main_wakes") - wakes_before) / elapsed, 1)
        if isinstance(wakes_before, int) and isinstance(hangs.get("main_wakes"), int) else None,
        "main_max_gap_ms": hangs.get("max_gap_ms"), "main_stalls": hangs.get("count"),
        "idle_frames": len(intervals), "idle_frames_per_s": round(len(intervals) / elapsed, 1),
        "refresh_ms": frames.get("refresh_ms"), "frame_interval_ms": spread(intervals), "frame_main_ms": spread(busy),
        "errors": [r["error"] for r in (frames, hangs) if r.get("error")],
    }
    out = {}
    for pid, name in role.items():
        if pid not in second:
            continue
        group = out.setdefault(name, {"processes": 0, "rss_mb": 0.0, "cpu_percent": 0.0})
        group["processes"] += 1
        group["rss_mb"] += second[pid][1] / 1024
        group["cpu_percent"] += 100 * (second[pid][2] - first[pid][2]) / elapsed if pid in first else 0.0
    for group in out.values():
        group["rss_mb"], group["cpu_percent"] = round(group["rss_mb"], 1), round(group["cpu_percent"], 2)
    conn = Conn(daemon_socket)
    result = {
        "seconds": round(elapsed, 1), "groups": out,
        "footprint_mb": {"app": footprint_mb(app_pid), "daemon": footprint_mb(daemon_pid)},
        "processes_of_session": sum(group["processes"] for group in out.values()),
        "processes_of_user": len(second), "kern.maxprocperuid": sysctl("kern.maxprocperuid"),
        "app_idle": wakes, "counts": counts(conn, app_socket), "host": host_facts(),
        "note": "cpu_percent: ps cpu time over the window (1 s steps of ps, so +-1/seconds %); rss is resident size, footprint is phys_footprint",
    }
    print("SESSION-REAL-MEASURE " + json.dumps(result), flush=True)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=1)


# ---------------------------------------------------------------- map: the app's own clocks per action

def spread(values):
    """{n, p50, p95, max} of a list of numbers (nearest rank), None values dropped."""
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return {"n": 0}
    rank = lambda q: values[max(0, min(len(values) - 1, -(-len(values) * q // 100) - 1))]  # noqa: E731
    return {"n": len(values), "p50": round(rank(50), 2), "p95": round(rank(95), 2), "max": round(values[-1], 2)}


class AppDriver:
    """The bench app through its debug socket: actions as a script sends them (`action.run`, the same pipeline
    as a key press) and the app's own clocks: `debug.action_budget` (action start to its committed frame),
    `debug.frames` (the display link: frame intervals and main-thread time per frame), `debug.hangs` (main-thread
    gaps) and the switch timers."""

    def __init__(self, app_socket, daemon_socket):
        self.sock, self.daemon = app_socket, Conn(daemon_socket)
        self.pid = int(app_rpc(app_socket, "system.identify", timeout=10)["pid"])
        self.unusable = []

    def rpc(self, method, params=None, timeout=60):
        return app_rpc(self.sock, method, params, timeout) or {}

    def soft(self, method, params=None, timeout=60):
        try:
            return self.rpc(method, params, timeout)
        except (RuntimeError, OSError, ValueError) as error:
            return {"error": f"{type(error).__name__}: {error}"}

    def act(self, action, **args):
        return self.soft("action.run", {"action": action, "args": args, "wait": True, "origin": "script", "focus": True,
                                        "idempotency_key": f"mutation_{uuid.uuid4().hex}"}, timeout=120)

    def topology(self):
        return (self.rpc("snapshot.get", timeout=120) or {}).get("topology") or {}

    def workspace_ids(self):
        """name -> the app's workspace id, through the daemon's key of each name."""
        keys = {w.get("key"): w.get("name") for w in self.daemon.must("list-workspaces").get("workspaces", [])}
        return {keys.get(w.get("key")): w.get("id") for w in self.topology().get("workspaces") or [] if w.get("id")}

    def last_sequence(self):
        recent = self.soft("debug.action_budget", {"limit": 4}).get("recent") or []
        return max((r.get("sequence", 0) for r in recent), default=0)

    def timed(self, action, timer=None, settle=0.6, **args):
        """One action and what the app's clocks say of it."""
        before = self.last_sequence()
        self.soft("debug.hangs", {"clear": True})
        if timer:
            self.soft(timer, {"action": "start"})
        self.soft("debug.frames", {"action": "start"})
        time.sleep(0.1)  # a few frames at rest before the action
        started = time.monotonic()
        reply = self.act(action, **args)
        reply_ms = (time.monotonic() - started) * 1000
        time.sleep(settle)  # the action's frames land
        frames = self.soft("debug.frames", {"action": "stop", "raw": True})
        timed = self.soft(timer, {"action": "stop"}) if timer else {}
        hangs = self.soft("debug.hangs")
        recent = [r for r in self.soft("debug.action_budget", {"limit": 16}).get("recent") or [] if r.get("sequence", 0) > before]
        own = next((r for r in recent if r.get("id") == action), recent[0] if recent else {})
        samples = next((v for k, v in timed.items() if isinstance(v, list) and k != "confirms_ms" and v and isinstance(v[0], dict)), [])
        intervals, busy = frames.get("intervals_ms") or [], frames.get("main_ms") or []
        row = {
            "error": reply.get("error") or frames.get("error"), "reply_ms": round(reply_ms, 1),
            "commit_ms": own.get("commit_ms"), "budget_id": own.get("id"), "outcome": own.get("outcome"),
            "timer_commit_ms": samples[0].get("commit_ms") if samples else None,
            "timer_late_vsyncs": samples[0].get("late_vsyncs") if samples else None,
            "frames": len(intervals), "refresh_ms": frames.get("refresh_ms"),
            "max_frame_ms": max(intervals) if intervals else None, "max_main_ms": max(busy) if busy else None,
            "late_frames": sum(1 for i in intervals if frames.get("refresh_ms") and i > frames["refresh_ms"] * 1.5),
            "main_max_gap_ms": hangs.get("max_gap_ms"), "main_stalls": hangs.get("count"),
        }
        if reply_ms > 1000 or (row["main_max_gap_ms"] or 0) > 1000 or row["error"]:
            self.unusable.append({"action": action, **{k: row[k] for k in ("reply_ms", "main_max_gap_ms", "error")}})
        return row


def summarize(name, rows, note=""):
    out = {"row": name, "runs": len(rows), "errors": sum(1 for r in rows if r.get("error")), "note": note}
    for key in ("commit_ms", "timer_commit_ms", "reply_ms", "max_frame_ms", "max_main_ms", "main_max_gap_ms"):
        out[key] = spread([r.get(key) for r in rows])
    out["late_frames_total"] = sum(r.get("late_frames") or 0 for r in rows)
    out["refresh_ms"] = next((r.get("refresh_ms") for r in rows if r.get("refresh_ms")), None)
    out["first_error"] = next((r.get("error") for r in rows if r.get("error")), None)
    print("SESSION-REAL-ROW " + json.dumps(out), flush=True)
    return out


def map_rows(args):
    """The first map of the app at this session: 20 runs per action, the app's own clocks."""
    daemon_socket, app_socket = sockets(args)
    if not app_socket:
        raise SystemExit("session_real: map needs --app-socket")
    app = AppDriver(app_socket, daemon_socket)
    runs, rows, raw = args.runs, [], {}
    wanted = set(args.rows.split(",")) if args.rows else None
    deadline = time.time() + args.budget_seconds

    def row(name, note, make):
        if (wanted and name not in wanted) or time.time() > deadline:
            if time.time() > deadline:
                print(f"SESSION-REAL-ROW-SKIPPED {name}: the time budget of this run ended", flush=True)
            return
        try:
            raw[name] = make()
        except (RuntimeError, OSError, ValueError, KeyError) as error:
            print(f"SESSION-REAL-ROW-FAILED {name}: {type(error).__name__}: {error}", flush=True)
            app.unusable.append({"action": name, "error": str(error)})
            return
        rows.append(summarize(name, raw[name], note))

    ids = app.workspace_ids()
    real = sorted(name for name in ids if name and NAME.match(name))
    if len(real) < 44:
        raise SystemExit(f"session_real: the app shows {len(real)} workspaces of a `make` session; map needs it")
    made = app.act("workspace.newAtBottom")
    bench = next((i for i in made.get("created", []) if str(i).startswith("ws_")), None)
    if not bench:
        raise SystemExit(f"session_real: workspace.newAtBottom made no workspace: {str(made)[:300]}")
    app.act("goToWorkspace", workspace=bench)
    time.sleep(1.5)

    def switch_warm():
        other = ids[real[0]]
        app.act("goToWorkspace", workspace=other)
        time.sleep(1.0)
        app.act("goToWorkspace", workspace=bench)
        time.sleep(1.0)
        return [app.timed("goToWorkspace", timer="debug.workspace_switch", workspace=(other, bench)[i % 2]) for i in range(runs)]

    def switch_cold():
        step = max(1, (len(real) - 2) // runs)
        targets = [ids[real[1 + i * step]] for i in range(runs)]
        return [app.timed("goToWorkspace", timer="debug.workspace_switch", workspace=target) for target in targets]

    def tab_switch():
        app.act("goToWorkspace", workspace=bench)
        app.act("newSurface")
        time.sleep(1.5)
        return [app.timed("nextSurface", timer="debug.tab_switch") for _ in range(runs)]

    def new_tab():
        out = []
        for _ in range(runs):
            out.append(app.timed("newSurface", settle=0.8))
            app.act("closeTab")
            time.sleep(0.4)
        return out

    def split():
        out = []
        for _ in range(runs):
            out.append(app.timed("splitRight", settle=0.8))
            app.act("closePane")
            time.sleep(0.4)
        return out

    new_rows = []

    def close():
        out = []
        for _ in range(runs):
            new_rows.append(app.timed("workspace.newAtBottom", timer="debug.new_workspace", settle=0.8))
            out.append(app.timed("closeWorkspace", settle=0.8, confirm=True))
            app.act("goToWorkspace", workspace=bench)
            time.sleep(0.3)
        return out

    row("workspace_switch_warm", "between two workspaces that both showed before", switch_warm)
    row("tab_switch", "terminal tab to terminal tab in one pane (nextSurface)", tab_switch)
    row("new_tab", "newSurface: a new terminal tab; closed again untimed", new_tab)
    row("split", "splitRight: a new terminal pane; closed again untimed", split)
    row("workspace_close", "closeWorkspace of a workspace made right before (1 terminal)", close)
    if new_rows:
        rows.append(summarize("new_workspace", new_rows, "workspace.newAtBottom (the make step of workspace_close)"))
        raw["new_workspace"] = new_rows
    row("workspace_switch_cold", "first show of 20 other workspaces spread over the session (a parked terminal starts its shell)", switch_cold)
    app.act("goToWorkspace", workspace=bench)
    app.act("closeWorkspace", confirm=True)
    sample = None
    if app.unusable and args.sample:
        sample = args.sample
        subprocess.run(["sample", str(app.pid), "3", "-file", sample], capture_output=True)
    result = {"rows": rows, "unusable": app.unusable, "sample": sample, "runs_per_row": runs, "host": host_facts(),
              "method": "app-clock: action.run (origin script) on the debug socket; commit_ms from debug.action_budget, "
                        "frames from debug.frames (display link), gaps from debug.hangs",
              "counts": counts(Conn(daemon_socket)), "raw": raw}
    print("SESSION-REAL-MAP " + json.dumps({k: v for k, v in result.items() if k != "raw"}), flush=True)
    if app.unusable:
        print(f"SESSION-REAL-UNUSABLE {len(app.unusable)} actions took over 1 s or failed: {json.dumps(app.unusable[:6])}", flush=True)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=1)


# ---------------------------------------------------------------- save, install

def state_root(home=None):
    """The folder of every tag's state. The app finds it from the ACCOUNT's home, not from $HOME (a bench runs with
    its own HOME, FLEET.md f3), so the default here is the account's home too."""
    return os.path.join(home or pwd.getpwuid(os.getuid()).pw_dir, "Library/Application Support/cmux-next/tags")


def running_with_tag(tag):
    out = subprocess.run(["ps", "axo", "args="], capture_output=True, text=True).stdout
    return [line for line in out.splitlines() if f"cmux-app-{tag} " in line + " " or f"cmux DEV {tag}.app/Contents/MacOS/" in line]


def copy_tree(source, target):
    """An APFS clone copy where it can (`cp -Rc`), else a plain copy. `target` must not exist."""
    if os.path.exists(target):
        raise SystemExit(f"session_real: {target} exists; give a new folder (nothing is deleted for you)")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if subprocess.run(["cp", "-Rc", source, target], capture_output=True).returncode != 0:
        shutil.copytree(source, target, symlinks=True)


def save(args):
    source = os.path.join(state_root(args.home), args.tag)
    if not os.path.isdir(source):
        raise SystemExit(f"session_real: no state folder {source}")
    alive = running_with_tag(args.tag)
    if alive:
        raise SystemExit(f"session_real: the tag {args.tag} still runs ({len(alive)} processes); quit it with "
                         "debug.quit {fixture_quit: end-sessions} first: a copy of a live session is not a saved session")
    copy_tree(source, os.path.join(args.to, "state"))
    meta = {"tag": args.tag, "session": f"cmux-app-{args.tag}", "saved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "host": host_facts(), "note": args.note}
    with open(os.path.join(args.to, "session-real.json"), "w", encoding="utf-8") as handle:
        json.dump(meta, handle, indent=1)
    size = subprocess.run(["du", "-sk", args.to], capture_output=True, text=True).stdout.split()
    print(f"SESSION-REAL-SAVED {args.to} ({int(size[0]) // 1024 if size else '?'} MB) from tag {args.tag}", flush=True)


def install(args):
    with open(os.path.join(args.saved, "session-real.json"), encoding="utf-8") as handle:
        meta = json.load(handle)
    target = os.path.join(state_root(args.home), args.tag)
    if meta["tag"] != args.tag:
        # The registry names its session (`workspace registry belongs to session "cmux-app-A", not "cmux-app-B"`,
        # measured 2026-11-10), and so do its agent and notification rows: a rename is not a restore.
        raise SystemExit(f"session_real: {args.saved} is the session of tag {meta['tag']}; a saved session is tied to its tag. "
                         f"Make the one of {args.tag}: session_real.py build --app '<.../cmux DEV {args.tag}.app>' --to <new folder>")
    alive = running_with_tag(args.tag)
    if alive:
        raise SystemExit(f"session_real: the tag {args.tag} runs ({len(alive)} processes); stop it first")
    put_aside(target)
    copy_tree(os.path.join(args.saved, "state"), target)
    with open(os.path.join(target, INSTALL_MARK), "w", encoding="utf-8") as handle:
        json.dump({"from": os.path.abspath(args.saved), "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, handle)
    print(f"SESSION-REAL-INSTALLED {target} from {args.saved}. Launch the app with BENCH_LAUNCH_KEEP_STATE=1 "
          "(bench_launch moves a tag's state away at each launch without it); `uninstall` puts the old state back.", flush=True)


INSTALL_MARK = "session-real-installed.json"


def put_aside(target):
    """Makes room at `target`. An installed copy of a saved session (it has the mark) is removed: the saved
    folder is its source. Any other state moves to `<target>.before-session-real` (one kept), never deleted."""
    if not os.path.exists(target):
        return
    if os.path.exists(os.path.join(target, INSTALL_MARK)):
        shutil.rmtree(target)
        print(f"removed the installed copy at {target}", flush=True)
        return
    kept = target + ".before-session-real"
    if os.path.exists(kept):
        older = f"{kept}-{int(time.time())}"
        os.rename(kept, older)
        print(f"an older kept state moved to {older}", flush=True)
    os.rename(target, kept)
    print(f"moved the tag's old state to {kept} (not deleted)", flush=True)


def uninstall(args):
    """Removes the installed copy and puts the state from before `install` back (the next owner of the tag
    then finds what was there)."""
    target = os.path.join(state_root(args.home), args.tag)
    alive = running_with_tag(args.tag)
    if alive:
        raise SystemExit(f"session_real: the tag {args.tag} runs ({len(alive)} processes); stop it first")
    if not os.path.exists(os.path.join(target, INSTALL_MARK)):
        raise SystemExit(f"session_real: {target} is not an installed saved session (no {INSTALL_MARK}); nothing changed")
    shutil.rmtree(target)
    kept = target + ".before-session-real"
    if os.path.exists(kept):
        os.rename(kept, target)
    print(f"SESSION-REAL-UNINSTALLED {target} ({'old state back' if os.path.exists(target) else 'no old state'})", flush=True)


def launch(args):
    """Starts the bench app ON its saved session and says how long the restore takes, then runs the other
    commands against it and quits it as a bench does ("End Sessions, Keep Layout"). Needs the GUI session of a
    bench host (`bench_launch.BenchApp`); with `--saved` the session is installed first and taken away after."""
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, os.path.join(os.path.dirname(here), "cmux-next"))
    from bench_launch import BenchApp  # noqa: PLC0415  (only this command needs it)

    tag = tag_of_app(args.app)
    os.makedirs(args.out, exist_ok=True)
    if args.saved:
        install(argparse.Namespace(saved=args.saved, tag=tag, home=None))
    want = None
    meta_path = os.path.join(state_root(), tag, INSTALL_MARK)
    if os.path.exists(meta_path):
        with open(os.path.join(json.load(open(meta_path, encoding="utf-8"))["from"], "session-real.json"), encoding="utf-8") as handle:
            want = json.load(handle)["asked"]["workspaces"]
    app = BenchApp(args.app, out=args.out, fresh_state=False)
    result = {"tag": tag, "want_workspaces": want, "host": host_facts(), "steps": {}}
    held = None

    def sample(name):
        if app.process and app.process.poll() is None:
            path = os.path.join(args.out, name)
            subprocess.run(["sample", str(app.process.pid), "3", "-file", path], capture_output=True, timeout=60)
            return path
        return None

    try:
        started = time.monotonic()
        try:
            app.launch(timeout=args.timeout)
        except SystemExit:
            result["launch_failed_sample"] = sample("launch-failed.sample.txt")
            raise
        result["window_and_socket_s"] = app.ready_seconds
        seen, loaded_at = None, None
        while time.monotonic() - started < args.timeout:
            try:
                seen = app_counts(app.socket)
            except (RuntimeError, OSError, ValueError) as error:
                seen = {"error": str(error)}
            if seen.get("loaded") and (want is None or seen.get("workspaces", 0) >= want):
                loaded_at = round(time.monotonic() - started, 2)
                break
            time.sleep(0.25)
        result["model_loaded_s"], result["app_counts_at_load"] = loaded_at, seen
        try:
            marks = app_rpc(app.socket, "debug.timings", timeout=60) or {}
            result["launch_marks_ms"] = marks.get("launch") or marks.get("launch_marks") or {k: v for k, v in marks.items() if "launch" in k}
        except (RuntimeError, OSError, ValueError) as error:
            result["launch_marks_ms"] = {"error": str(error)}
        if loaded_at is None:
            result["not_loaded_sample"] = sample("not-loaded.sample.txt")
        print("SESSION-REAL-LAUNCH " + json.dumps(result), flush=True)
        me = [sys.executable, os.path.abspath(__file__)]
        for step in [part for part in (args.steps or "").split(",") if part]:
            name, _, extra = step.partition(":")
            base = me + [name, "--app-socket", app.socket]
            if name == "clients":
                held = subprocess.Popen(me + ["clients", "--app-socket", app.socket, "--total", extra or str(REAL["clients"])])
                time.sleep(2)
                continue
            if name == "still":
                path = os.path.join(args.out, f"window-{extra or 'still'}.png")
                try:
                    app_rpc(app.socket, "debug.window_snapshot", {"kind": "main", "path": path}, timeout=60)
                except (RuntimeError, OSError, ValueError) as error:
                    print(f"still failed: {error}", flush=True)
                continue
            if name == "wait":
                time.sleep(float(extra or 5))
                continue
            if name in ("measure", "map", "make"):
                base += ["--out", os.path.join(args.out, f"{name}.json")]
            if name == "map":
                base += ["--sample", os.path.join(args.out, "map.sample.txt")]
            base += extra.split() if extra else []
            began = time.monotonic()
            code = subprocess.run(base).returncode
            result["steps"][step] = {"exit": code, "seconds": round(time.monotonic() - began, 1)}
            print(f"SESSION-REAL-STEP {step}: exit {code} in {result['steps'][step]['seconds']} s", flush=True)
    finally:
        if held:
            held.terminate()  # the PID this script started
        began = time.monotonic()
        app.stop(quit_timeout=args.quit_timeout)
        result["quit_s"] = round(time.monotonic() - began, 1)
        if args.saved and not args.keep_installed:
            uninstall(argparse.Namespace(tag=tag, home=None))
        with open(os.path.join(args.out, "launch.json"), "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=1)
        print("SESSION-REAL-LAUNCH-END " + json.dumps({k: result.get(k) for k in ("window_and_socket_s", "model_loaded_s", "quit_s", "steps")}), flush=True)


def tag_of_app(app):
    """The tag of a `cmux DEV <tag>.app` bundle, as bench_launch.tag_of reads it."""
    found = re.fullmatch(r"cmux DEV (.+)\.app", os.path.basename(os.path.realpath(app).rstrip("/")))
    if not found:
        raise SystemExit(f"session_real: expected a `cmux DEV <tag>.app` bundle, got {app}")
    return re.sub(r"[^a-z0-9]+", "-", found.group(1).lower()).strip("-")


def build(args):
    """Makes the saved session of one bench app with NO app and no GUI lock: the bundle's own daemon runs
    headless as the app's session (`cmux-app-<tag>`) on a new state folder, `make` fills it, and the daemon stops
    as the app's "End Sessions, Keep Layout" stops it. About two minutes; then `install` on any host."""
    tag = tag_of_app(args.app)
    binary = os.path.join(os.path.realpath(args.app), "Contents/Resources/bin/cmux-tui")
    if os.path.exists(args.to):
        raise SystemExit(f"session_real: {args.to} exists; give a new folder")
    alive = running_with_tag(tag)
    if alive:
        raise SystemExit(f"session_real: the tag {tag} runs ({len(alive)} processes); stop it first")
    state = os.path.join(args.to, "state", "tui")
    home = os.path.join(args.to, "build-home")
    os.makedirs(state)
    os.makedirs(home)
    sock = f"/private/tmp/session-real-{os.getpid()}.sock"
    env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=home + "/.config", XDG_STATE_HOME=home + "/.local/state",
               XDG_DATA_HOME=home + "/.local/share", XDG_CACHE_HOME=home + "/.cache",
               CMUX_TUI_CONFIG=os.path.join(home, "config.json"), SHELL="/bin/zsh")
    log = open(os.path.join(args.to, "daemon.log"), "a")
    daemon = subprocess.Popen([binary, "--headless", "--session", f"cmux-app-{tag}", "--socket", sock, "--state", state],
                              stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
    conn = None
    try:
        deadline = time.time() + 60
        while conn is None:
            if daemon.poll() is not None or time.time() > deadline:
                raise SystemExit(f"session_real: the daemon did not start (exit {daemon.poll()}); see {log.name}")
            if os.path.exists(sock):
                try:
                    conn = Conn(sock)
                except OSError:
                    pass
            time.sleep(0.1)
        identity = conn.must("identify")
        args.socket, args.app_socket, args.out = sock, None, os.path.join(args.to, "make.json")
        make(args)
        started = time.time()
        ended = conn.must("shutdown-daemon", pid=identity["pid"], generation=identity["generation"], end_terminals=True, keep_layout=True)
        conn.close()
        daemon.wait(timeout=300)
        print(f"daemon stopped, keep layout: {ended.get('ended_terminals')} terminals ended in {time.time() - started:.1f} s", flush=True)
    finally:
        if daemon.poll() is None:
            daemon.terminate()  # the PID this script started
            try:
                daemon.wait(timeout=30)
            except subprocess.TimeoutExpired:
                daemon.kill()
    with open(os.path.join(args.to, "make.json"), encoding="utf-8") as handle:
        made = json.load(handle)
    meta = {"tag": tag, "session": f"cmux-app-{tag}", "saved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "host": host_facts(), "note": "built headless by session_real.py build", "asked": made["asked"],
            "daemon": open(os.path.join(os.path.dirname(binary), "cmux-tui.version"), encoding="utf-8").read().split()
            if os.path.exists(os.path.join(os.path.dirname(binary), "cmux-tui.version")) else None}
    with open(os.path.join(args.to, "session-real.json"), "w", encoding="utf-8") as handle:
        json.dump(meta, handle, indent=1)
    shutil.rmtree(home, ignore_errors=True)
    size = subprocess.run(["du", "-sk", os.path.join(args.to, "state")], capture_output=True, text=True).stdout.split()
    print(f"SESSION-REAL-BUILT {args.to} for tag {tag} ({int(size[0]) // 1024 if size else '?'} MB), PTYs in use now {ptys_in_use()}", flush=True)


# ---------------------------------------------------------------- main

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def target(p):
        p.add_argument("--socket", help="the daemon's control socket")
        p.add_argument("--app-socket", help="the bench app's debug socket (/tmp/cmux-debug-<tag>.sock); the daemon is found from it")

    def size(p):
        p.add_argument("--workspaces", type=int, default=REAL["workspaces"])
        p.add_argument("--terminals", type=int, default=REAL["terminals"])
        p.add_argument("--agents", type=int, default=REAL["agents"])
        p.add_argument("--tabs", type=int, default=REAL["tabs"])
        p.add_argument("--panes", type=int, default=REAL["panes"])
        p.add_argument("--browser-tabs", type=int, default=REAL["browser_tabs"], help="pages among the second tabs (Chromium and WebKit in turn)")
        p.add_argument("--agents-working", type=int, default=8, help="agent terminals that work (spinner at 10 Hz); the others wait")
        p.add_argument("--agents-blocked", type=int, default=0, help="agent terminals that wait for a permission")
        p.add_argument("--settle", type=float, default=60, help="seconds to wait for the agents' reports")

    p = sub.add_parser("make")
    target(p)
    size(p)
    p.add_argument("--live-shells", type=int, default=30, help="plain terminals that keep a shell; the others are parked")
    p.add_argument("--batch", type=int, default=32, help="workspaces per batch (park and agent start run per batch)")
    p.add_argument("--cwd", default="/private/tmp", help="the terminals' directory (one that is on every host, so a saved session restores anywhere)")
    p.add_argument("--browser-url", default="about:blank")
    p.add_argument("--no-agents", action="store_true", help="do not start the agent program (run `agents` later)")
    p.add_argument("--out", help="write the result JSON here")
    p.set_defaults(run=make)

    p = sub.add_parser("counts")
    target(p)
    p.set_defaults(run=lambda a: print("SESSION-REAL-COUNTS " + json.dumps(counts(Conn(sockets(a)[0]), sockets(a)[1])), flush=True))

    p = sub.add_parser("agents")
    target(p)
    size(p)
    p.add_argument("--force", action="store_true", help="send the start line also to a terminal the daemon lists an agent for")
    p.set_defaults(run=agents)

    p = sub.add_parser("clients")
    target(p)
    p.add_argument("--count", type=int, default=REAL["clients"] - 1, help="connections to hold (his 13 = the app + 12)")
    p.add_argument("--total", type=int, default=0, help="hold as many as make the daemon's client list this long (his is 13)")
    p.add_argument("--seconds", type=float, default=0, help="0 = until killed")
    p.set_defaults(run=clients)

    p = sub.add_parser("measure")
    target(p)
    p.add_argument("--seconds", type=float, default=60)
    p.add_argument("--out")
    p.set_defaults(run=measure)

    p = sub.add_parser("map")
    target(p)
    p.add_argument("--runs", type=int, default=20)
    p.add_argument("--rows", help="comma list: workspace_switch_warm,tab_switch,new_tab,split,workspace_close,workspace_switch_cold")
    p.add_argument("--budget-seconds", type=float, default=420, help="no new row starts after this (a GUI hold is short)")
    p.add_argument("--sample", help="write a `sample` of the app here when an action took over 1 s or failed")
    p.add_argument("--out")
    p.set_defaults(run=map_rows)

    p = sub.add_parser("save")
    p.add_argument("--tag", required=True)
    p.add_argument("--to", required=True, help="a new folder")
    p.add_argument("--home", help="the account home the app used (default: this user's)")
    p.add_argument("--note", default="")
    p.set_defaults(run=save)

    p = sub.add_parser("build")
    size(p)
    p.add_argument("--app", required=True, help="the bench app bundle (`.../cmux DEV <tag>.app`); its own daemon makes the session")
    p.add_argument("--to", required=True, help="a new folder for the saved session")
    p.add_argument("--live-shells", type=int, default=30)
    p.add_argument("--batch", type=int, default=32)
    p.add_argument("--cwd", default="/private/tmp")
    p.add_argument("--browser-url", default="about:blank")
    p.add_argument("--no-agents", action="store_true")
    p.set_defaults(run=build)

    p = sub.add_parser("install")
    p.add_argument("--saved", required=True, help="a folder `save` made")
    p.add_argument("--tag", required=True)
    p.add_argument("--home")
    p.set_defaults(run=install)

    p = sub.add_parser("launch")
    p.add_argument("--app", required=True, help="the bench app bundle (`.../cmux DEV <tag>.app`)")
    p.add_argument("--saved", help="install this saved session first and take it away after")
    p.add_argument("--keep-installed", action="store_true")
    p.add_argument("--out", required=True, help="a folder for the app log and the results")
    p.add_argument("--timeout", type=float, default=240)
    p.add_argument("--quit-timeout", type=float, default=60)
    p.add_argument("--steps", default="counts", help="comma list, each `command[:arguments]`: counts, agents, clients[:total], "
                   "measure[:--seconds N], map[:--runs N ...], make[:...], still[:name], wait[:seconds]")
    p.set_defaults(run=launch)

    p = sub.add_parser("uninstall")
    p.add_argument("--tag", required=True)
    p.add_argument("--home")
    p.set_defaults(run=uninstall)

    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("session_real: a fleet Mac only")
    args.run(args)


if __name__ == "__main__":
    main()
