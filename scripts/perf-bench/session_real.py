#!/usr/bin/env python3
"""session_real.py: ONE shared bench session of the size of the person who uses the app.

His session, read from his one session daemon on 2026-11-10: 826 workspaces, 858 panes, 1600 tabs,
798 terminals, 170 agents, 13 clients. Every bench owner uses this script (or the HOME it saved)
for the `real` session arm; nobody writes a second "800" maker.

The mix rule is the one of the test fixture `SessionFixtureSize.real`
(Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/SessionFixtureSize.swift, #40488), so a count test and a
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

Commands (make, counts, agents, clients, measure and map take `--socket <daemon socket>` or
`--app-socket <app debug socket>`, and refuse a daemon whose session is not `cmux-app-<tag>` of a
tagged DEV build; build and launch take `--app <bundle>`; save, install and uninstall take `--tag`):
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
           (exit 1 when the model did not load, a step failed or the clients step ended early)
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
import select
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

    def __init__(self, path, timeout=120, busy_wait=20.0):
        # The daemon serves 64 connections (MAX_SERVER_CONNECTIONS); above that it answers `server.busy` and
        # closes. 170 agents that report at one time fill it for some seconds: try again for `busy_wait`.
        give_up = time.monotonic() + busy_wait
        while True:
            self.sock = socket.socket(socket.AF_UNIX)
            self.sock.settimeout(timeout)
            self.sock.connect(path)
            self.buf = b""
            self.next_id = 1
            try:
                # With `conversation-tabs-v1` the tree names a chat tab `conversation`; without it a chat reads as `browser`.
                self.call("set-client-info", name="session-real", kind="bench", capabilities=["conversation-tabs-v1", "agent-session-tabs-v1"])
                return
            except ConnectionError:
                self.close()
                if time.monotonic() >= give_up:
                    raise ConnectionError(f"the daemon refused the connection for {busy_wait} s (its limit is 64 connections)") from None
                time.sleep(0.25)

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


CHANNELS = ("nightly", "rc", "staging")


def bench_tag(session):
    """The tag of a tagged DEV build's session (`cmux-app-<tag>`), else None. Not a bench's: the release
    session `cmux-app`, a channel build's (`cmux-app-nightly`, `-rc`, `-staging`), an untagged build's
    (`cmux-app--<hash>`) and every other session (a person's `cmux-next` or `main`)."""
    found = re.fullmatch(r"cmux-app-([A-Za-z0-9][A-Za-z0-9_.-]*)", session or "")
    return found.group(1) if found and found.group(1) not in CHANNELS else None


def check_tag(tag):
    """Refuses a tag that is no single folder name of a tagged DEV build."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", tag or "") or tag in CHANNELS:
        raise SystemExit(f"session_real: {tag!r} is not the tag of a tagged DEV build")
    return tag


def refuse_other_session(daemon_socket):
    """This tool makes hundreds of workspaces and holds connections: only in a tagged DEV build's session."""
    conn = Conn(daemon_socket)
    try:
        session = conn.must("identify").get("session")
    finally:
        conn.close()
    if bench_tag(session) is None:
        raise SystemExit(f"session_real: refusing the daemon on {daemon_socket}: its session is {session!r}, "
                         "not `cmux-app-<tag>` of a tagged DEV build")


def sockets(args):
    """(daemon socket, app socket or None). Refuses an app or a daemon that is not a tagged DEV build's."""
    if args.app_socket:
        info = app_rpc(args.app_socket, "system.identify", timeout=10) or {}
        bundle = info.get("app_bundle_path") or ""
        if ".debug" not in (info.get("bundle_id") or "") or bundle.startswith("/Applications/"):
            raise SystemExit(f"session_real: refusing {bundle!r} ({info.get('bundle_id')}): not a tagged DEV build")
        daemon_socket = daemon_of_app(args.app_socket)[1]
    elif args.socket:
        daemon_socket = args.socket
    else:
        raise SystemExit("session_real: give --socket <daemon socket> or --app-socket <app debug socket>")
    refuse_other_session(daemon_socket)
    return daemon_socket, args.app_socket or None


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
        listed = clients.get("data") or []
        out["clients"] = len(listed)
        names = {}
        for client in listed if isinstance(listed, list) else []:
            # One line per kind of client: the app holds several connections, each hook call is one for a moment.
            name = re.sub(r"[-_ ]?\d+$", "", str(client.get("name") or client.get("kind") or "unnamed")) if isinstance(client, dict) else "?"
            names[name] = names.get(name, 0) + 1
        out["client_names"] = names
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
    # The daemon lists an agent again for a restarted kept tab from its stored record (measured: 113 listed after
    # a restore, with no program in their shells), so "runs" is read from the process list, by the program's name.
    running = set(re.findall(r"session_real_agent\.zsh \S+ (real-\d{4})",
                             subprocess.run(["ps", "axo", "args="], capture_output=True, text=True).stdout))
    started = restarted = skipped = 0
    waiting = []
    for rank, (number, tab) in enumerate(agent_tabs(tree, mix)):
        surface = tab["surface"]
        if f"real-{number:04d}" in running and not tab.get("dead") and not args.force:
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
    programs = subprocess.run(["ps", "axo", "args="], capture_output=True, text=True).stdout.count("session_real_agent.zsh")
    print("SESSION-REAL-AGENTS " + json.dumps({"started": started, "restarted_shells": restarted, "already_running": skipped,
                                                "not_started": len(waiting), "agent_programs_running": programs, "after": after}), flush=True)
    if waiting:
        raise SystemExit(f"session_real: {len(waiting)} agent terminals took no input")


def clients(args):
    """Holds `--count` more control connections open (each named and subscribed to tree deltas, as
    an app window or a phone is), and reads what the daemon sends them, until killed or `--seconds`."""
    daemon_socket, _ = sockets(args)
    held = []

    if args.total:
        probe = Conn(daemon_socket)
        reads = []
        for _ in range(6):  # each hook call of an agent is a client for a moment: the lowest read is the steady list
            reads.append(len(probe.must("list-clients")) - 1)  # without this probe itself
            time.sleep(0.5)
        args.count = max(0, args.total - min(reads))
        probe.close()
    for index in range(args.count):
        conn = Conn(daemon_socket)
        conn.call("set-client-info", name=f"session-real-client-{index + 1}")
        conn.must("subscribe", tree_events="deltas")
        conn.sock.setblocking(False)
        held.append(conn)
    # One read, then the event reads start at once: the daemon closes a subscriber that does not read its events
    # for some seconds while 170 agents start (measured 2026-11-10: 18 held connections that waited 15 s were closed).
    listed = Conn(daemon_socket)
    others = len(listed.must("list-clients")) - 1
    listed.close()
    print(f"SESSION-REAL-CLIENTS held {len(held)}, the daemon lists {others + 1} (with this one)", flush=True)
    if args.total and others != args.total:
        # Not an error: the list moves (a hook call is a client for a moment, the app's own connections come and go).
        print(f"SESSION-REAL-CLIENTS-DIFFER the daemon lists {others} clients, {args.total} were asked for", flush=True)
    deadline = time.time() + args.seconds if args.seconds else None
    received = 0
    began = time.time()
    by_socket = {conn.sock: index + 1 for index, conn in enumerate(held)}
    try:
        while deadline is None or time.time() < deadline:
            # Read as soon as the daemon sends, as an app window does: a client that reads late is not his client.
            ready = select.select(list(by_socket), [], [], 0.25)[0] if by_socket else time.sleep(0.25) or []
            for sock in ready:
                try:
                    while True:
                        chunk = sock.recv(1 << 20)
                        if not chunk:
                            raise SystemExit(f"session_real: the daemon closed client connection {by_socket[sock]} of {len(held)} "
                                             f"after {time.time() - began:.1f} s and {received} bytes of events; "
                                             "the session has fewer clients than asked from here")
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


def daemon_child_kind(command):
    """What a descendant of the daemon is, from its command line."""
    program = os.path.basename(command.split(" --")[0].split(" ")[0]) if not command.startswith("/Users/") else os.path.basename(command.split(" --")[0])
    if "session_real_agent.zsh" in command:
        return "agent_programs"
    if "cmux-tui-host" in command or "terminal-host" in command:
        return "terminal_hosts"
    if "cmux-holder" in command or "__holder" in command:
        return "terminal_holders"
    if program.lstrip("-") in ("zsh", "bash", "sh", "login"):
        return "shells"
    return "daemon_other"


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
        role.setdefault(pid, daemon_child_kind(table[pid][3]))
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

    sys.path.insert(0, HERE)
    import procs  # noqa: PLC0415  (xbench's per-process counters: proc_pid_rusage, no root)

    # Window 1, nothing of the bench runs in the app: main-thread wakes, CPU and wakeups of every process.
    wakes_before = soft("debug.hangs", {"clear": True}).get("main_wakes")
    before = {pid: procs.counters(pid) for pid in role}
    started = time.time()
    time.sleep(args.seconds)
    elapsed = time.time() - started
    hangs = soft("debug.hangs")
    after = {pid: procs.counters(pid) for pid in role}
    second = process_table()
    # Window 2 (5 s): the display link's frames at rest. The frame recorder itself wakes the main thread per
    # frame, so its wakes are not in window 1.
    soft("debug.frames", {"action": "start"})
    frame_started = time.time()
    time.sleep(min(5.0, args.seconds))
    frames = soft("debug.frames", {"action": "stop", "raw": True})
    frame_seconds = time.time() - frame_started
    intervals, busy = frames.get("intervals_ms") or [], frames.get("main_ms") or []
    wakes = {
        "main_wakes_per_s": round((hangs.get("main_wakes") - wakes_before) / elapsed, 1)
        if isinstance(wakes_before, int) and isinstance(hangs.get("main_wakes"), int) else None,
        "main_max_gap_ms": hangs.get("max_gap_ms"), "main_stalls": hangs.get("count"),
        "frames_over_8_3ms": hangs.get("frames_over_8_3ms"),
        "frame_clock": {"seconds": round(frame_seconds, 1), "frames": len(intervals), "refresh_ms": frames.get("refresh_ms"),
                        "interval_ms": spread(intervals), "main_ms_per_frame": spread(busy),
                        "frames_main_over_1ms": sum(1 for value in busy if value > 1.0)},
        "errors": [r["error"] for r in (frames, hangs) if r.get("error")],
    }
    out = {}
    for pid, name in role.items():
        if pid not in second or not after.get(pid):
            continue
        group = out.setdefault(name, {"processes": 0, "rss_mb": 0.0, "footprint_mb": 0.0, "cpu_percent": 0.0, "wakeups_per_s": 0.0})
        group["processes"] += 1
        group["rss_mb"] += second[pid][1] / 1024
        group["footprint_mb"] += after[pid][3] / procs.MB
        if before.get(pid):
            group["cpu_percent"] += 100 * (after[pid][1] - before[pid][1]) / 1e9 / elapsed
            group["wakeups_per_s"] += (after[pid][2] - before[pid][2]) / elapsed
    total = {"processes": 0, "rss_mb": 0.0, "footprint_mb": 0.0, "cpu_percent": 0.0, "wakeups_per_s": 0.0}
    for group in out.values():
        for key in total:
            total[key] += group[key]
            group[key] = round(group[key], 2 if key == "cpu_percent" else 1)
    out["ALL"] = {key: round(value, 2 if key == "cpu_percent" else 1) for key, value in total.items()}
    conn = Conn(daemon_socket)
    result = {
        "seconds": round(elapsed, 1), "groups": out,
        "processes_of_session": out["ALL"]["processes"],
        "processes_of_user": len(second), "kern.maxprocperuid": sysctl("kern.maxprocperuid"),
        "app_idle": wakes, "counts": counts(conn, app_socket), "host": host_facts(),
        "note": "per group over the window: footprint_mb = sum of phys_footprint (Activity Monitor's Memory), rss_mb = sum of resident "
                "sizes (shared pages counted in each process), cpu_percent and wakeups_per_s from proc_pid_rusage (procs.py)",
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
        self.untimed_errors = []  # failed set-up and clean-up actions (not in a row's times, but the next run starts wrong)

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

    def step(self, action, **args):
        """An untimed action of a row's set-up or clean-up; its failure is kept and printed with the map."""
        reply = self.act(action, **args)
        if reply.get("error"):
            self.untimed_errors.append({"action": action, "error": reply["error"]})
        return reply

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
        own = next((r for r in recent if r.get("id") == action), {})  # never another action's sample
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
        # The watchdog samples the main thread in a stall (over its threshold, 50 ms): keep the longest one's
        # frames and the scheduled tasks that ran past their budget, so the row names its own cause.
        stalls = [r for r in hangs.get("records") or [] if isinstance(r, dict)]
        if stalls:
            worst = max(stalls, key=lambda r: r.get("duration_ms") or 0)
            row["stall"] = {"ms": worst.get("duration_ms"), "frames": (worst.get("frames") or [])[:24],
                            **{k: v for k, v in worst.items() if k not in ("frames", "frame_details", "duration_ms", "start_uptime_ns", "sequence")}}
        if hangs.get("over_budget"):
            row["over_budget"] = [{k: v for k, v in r.items() if k not in ("frames", "frame_details")}
                                  for r in hangs["over_budget"][-4:] if isinstance(r, dict)]
        if reply_ms > 1000 or (row["main_max_gap_ms"] or 0) > 1000 or row["error"]:
            self.unusable.append({"action": action, **{k: row[k] for k in ("reply_ms", "main_max_gap_ms", "error")}})
        return row


def summarize(name, rows, note=""):
    out = {"row": name, "runs": len(rows), "errors": sum(1 for r in rows if r.get("error")), "note": note}
    measured = [r for r in rows if not r.get("error")]  # a failed run is counted in `errors`, not in the times
    for key in ("commit_ms", "timer_commit_ms", "reply_ms", "max_frame_ms", "max_main_ms", "main_max_gap_ms"):
        out[key] = spread([r.get(key) for r in measured])
    out["late_frames_total"] = sum(r.get("late_frames") or 0 for r in rows)
    out["refresh_ms"] = next((r.get("refresh_ms") for r in rows if r.get("refresh_ms")), None)
    out["first_error"] = next((r.get("error") for r in rows if r.get("error")), None)
    out["main_stalls_total"] = sum(r.get("main_stalls") or 0 for r in rows)
    stalls = [r["stall"] for r in rows if r.get("stall")]
    if stalls:
        out["longest_stall"] = max(stalls, key=lambda s: s.get("ms") or 0)
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
    sampled = set(args.sample_rows.split(",")) if args.sample_rows else set()
    stem = (args.out or args.sample or "/tmp/session-real-map").removesuffix(".json")
    deadline = time.time() + args.budget_seconds

    def row(name, note, make):
        if (wanted and name not in wanted) or time.time() > deadline:
            if time.time() > deadline:
                print(f"SESSION-REAL-ROW-SKIPPED {name}: the time budget of this run ended", flush=True)
            return
        sampler = None
        if name in sampled:
            # A `sample` of the app beside this row says what its main thread does; it also slows the row,
            # so a sampled row's times are not for a table.
            path = f"{stem}.{name}.sample.txt"
            sampler = subprocess.Popen(["sample", str(app.pid), str(args.sample_seconds), "-file", path],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            note += f" (SAMPLED for {args.sample_seconds} s: {path})"
        try:
            raw[name] = make()
        except (RuntimeError, OSError, ValueError, KeyError) as error:
            print(f"SESSION-REAL-ROW-FAILED {name}: {type(error).__name__}: {error}", flush=True)
            app.unusable.append({"action": name, "error": str(error)})
            return
        finally:
            if sampler:
                try:
                    sampler.wait(timeout=args.sample_seconds + 30)
                except subprocess.TimeoutExpired:
                    sampler.kill()  # the PID this script started
        rows.append(summarize(name, raw[name], note))

    ids = app.workspace_ids()
    real = sorted(name for name in ids if name and NAME.match(name))
    if len(real) < 44:
        raise SystemExit(f"session_real: the app shows {len(real)} workspaces of a `make` session; map needs it")
    made = app.act("workspace.newAtBottom")
    bench = next((i for i in made.get("created", []) if str(i).startswith("ws_")), None)
    if not bench:
        raise SystemExit(f"session_real: workspace.newAtBottom made no workspace: {str(made)[:300]}")
    app.step("goToWorkspace", workspace=bench)
    time.sleep(1.5)

    def switch_warm():
        other = ids[real[0]]
        app.step("goToWorkspace", workspace=other)
        time.sleep(1.0)
        app.step("goToWorkspace", workspace=bench)
        time.sleep(1.0)
        return [app.timed("goToWorkspace", timer="debug.workspace_switch", workspace=(other, bench)[i % 2]) for i in range(runs)]

    def switch_cold():
        step = max(1, (len(real) - 2) // runs)
        targets = [ids[real[1 + (i * step) % (len(real) - 1)]] for i in range(runs)]
        return [app.timed("goToWorkspace", timer="debug.workspace_switch", workspace=target) for target in targets]

    def tab_switch():
        app.step("goToWorkspace", workspace=bench)
        app.step("newSurface")
        time.sleep(1.5)
        return [app.timed("nextSurface", timer="debug.tab_switch") for _ in range(runs)]

    def new_tab():
        out = []
        for _ in range(runs):
            out.append(app.timed("newSurface", settle=0.8))
            app.step("closeTab")
            time.sleep(0.4)
        return out

    def split():
        out = []
        for _ in range(runs):
            out.append(app.timed("splitDown", settle=0.8))
            app.step("closePane")
            time.sleep(0.4)
        return out

    new_rows = []

    def close():
        out = []
        for _ in range(runs):
            new_rows.append(app.timed("workspace.newAtBottom", timer="debug.new_workspace", settle=0.8))
            out.append(app.timed("closeWorkspace", settle=0.8, confirm=True))
            app.step("goToWorkspace", workspace=bench)
            time.sleep(0.3)
        return out

    row("workspace_switch_warm", "between two workspaces that both showed before", switch_warm)
    row("tab_switch", "terminal tab to terminal tab in one pane (nextSurface)", tab_switch)
    row("new_tab", "newSurface: a new terminal tab; closed again untimed", new_tab)
    row("split", "splitDown: a new terminal pane; closed again untimed", split)
    row("workspace_close", "closeWorkspace of a workspace made right before (1 terminal)", close)
    if new_rows:
        rows.append(summarize("new_workspace", new_rows, "workspace.newAtBottom (the make step of workspace_close)"))
        raw["new_workspace"] = new_rows
    row("workspace_switch_cold", "first show of 20 other workspaces spread over the session (a parked terminal starts its shell)", switch_cold)
    app.step("goToWorkspace", workspace=bench)
    app.step("closeWorkspace", confirm=True)
    sample = None
    if app.unusable and args.sample:
        sample = args.sample
        subprocess.run(["sample", str(app.pid), "3", "-file", sample], capture_output=True)
    result = {"rows": rows, "unusable": app.unusable, "untimed_errors": app.untimed_errors, "sample": sample,
              "runs_per_row": runs, "host": host_facts(),
              "method": "app-clock: action.run (origin script) on the debug socket; commit_ms from debug.action_budget, "
                        "frames from debug.frames (display link), gaps from debug.hangs",
              "counts": counts(Conn(daemon_socket)), "raw": raw}
    print("SESSION-REAL-MAP " + json.dumps({k: v for k, v in result.items() if k != "raw"}), flush=True)
    if app.unusable:
        print(f"SESSION-REAL-UNUSABLE {len(app.unusable)} actions took over 1 s or failed: {json.dumps(app.unusable[:6])}", flush=True)
    if app.untimed_errors:
        print(f"SESSION-REAL-UNTIMED-ERRORS {len(app.untimed_errors)} set-up or clean-up actions failed: "
              f"{json.dumps(app.untimed_errors[:6])}", flush=True)
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
        if os.path.exists(target):
            shutil.rmtree(target)  # what the failed `cp` left; `target` was not there before this call
        shutil.copytree(source, target, symlinks=True)


def save(args):
    source = os.path.join(state_root(args.home), check_tag(args.tag))
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
    target = os.path.join(state_root(args.home), check_tag(args.tag))
    source = os.path.join(args.saved, "state")
    if meta.get("tag") != args.tag:
        # The registry names its session (`workspace registry belongs to session "cmux-app-A", not "cmux-app-B"`,
        # measured 2026-11-10), and so do its agent and notification rows: a rename is not a restore.
        raise SystemExit(f"session_real: {args.saved} is the session of tag {meta.get('tag')}; a saved session is tied to its tag. "
                         f"Make the one of {args.tag}: session_real.py build --app '<.../cmux DEV {args.tag}.app>' --to <new folder>")
    alive = running_with_tag(args.tag)
    if alive:
        raise SystemExit(f"session_real: the tag {args.tag} runs ({len(alive)} processes); stop it first")
    if not os.path.isdir(source):
        raise SystemExit(f"session_real: {args.saved} has no `state` folder; nothing changed")
    put_aside(target)
    try:
        copy_tree(source, target)
        with open(os.path.join(target, INSTALL_MARK), "w", encoding="utf-8") as handle:
            json.dump({"from": os.path.abspath(args.saved), "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, handle)
    except BaseException:
        # No half install: take away what this call copied and put the state from before back, as `uninstall` does.
        if os.path.exists(target):
            shutil.rmtree(target)
        kept = target + ".before-session-real"
        if os.path.exists(kept):
            os.rename(kept, target)
        print(f"session_real: the install failed; {target} is as it was before", flush=True)
        raise
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
    target = os.path.join(state_root(args.home), check_tag(args.tag))
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
    app = BenchApp(args.app, out=args.out, fresh_state=False, socket_only=args.socket_only)
    result = {"tag": tag, "want_workspaces": None, "host": host_facts(), "steps": {}, "socket_only": args.socket_only}
    held, installed = None, False
    failures = []  # each one makes this command end with exit 1, after the quit and the uninstall

    def sample(name):
        if app.process and app.process.poll() is None:
            path = os.path.join(args.out, name)
            subprocess.run(["sample", str(app.process.pid), "3", "-file", path], capture_output=True, timeout=60)
            return path
        return None

    ptys_before = ptys_in_use()
    try:
        if args.saved:
            install(argparse.Namespace(saved=args.saved, tag=tag, home=None))
            installed = True
        want = None
        mark_path = os.path.join(state_root(), tag, INSTALL_MARK)
        if os.path.exists(mark_path):
            with open(mark_path, encoding="utf-8") as handle:
                saved_from = json.load(handle).get("from") or ""
            with open(os.path.join(saved_from, "session-real.json"), encoding="utf-8") as handle:
                # A folder that `save` made has no `asked` (only `build` knows the counts): then "loaded" is enough.
                want = (json.load(handle).get("asked") or {}).get("workspaces")
        result["want_workspaces"] = want
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
        # The app restarts a shell in each kept agent terminal at its first connect (`relaunchKeptLayoutIfNeeded`):
        # the restore is done when no kept terminal that does not wait for its show is dead.
        if loaded_at is not None and want:
            try:
                daemon = Conn(daemon_of_app(app.socket)[1])
                last = None
                restore_began = time.monotonic()
                while time.monotonic() - restore_began < args.restore_timeout:
                    last = counts(daemon)
                    # A kept tab is "not dead" as soon as the daemon takes its restart; its shell has a PTY later.
                    if not last.get("terminals_dead_other") and last.get("ptys_in_use_machine", 0) - ptys_before >= last.get("terminals_live", 0):
                        result["kept_terminals_restarted_s"] = round(time.monotonic() - started, 2)
                        break
                    time.sleep(0.5)
                result["counts_after_restore"] = last
                if "kept_terminals_restarted_s" not in result and last:
                    # A product fault, not a bench fault: say it, the `agents` step restarts these.
                    result["kept_terminals_not_restarted"] = {"dead": last.get("terminals_dead_other"), "after_s": args.restore_timeout}
                daemon.close()
            except (RuntimeError, OSError, ValueError, SystemExit) as error:
                result["kept_terminals_error"] = str(error)
        try:
            marks = app_rpc(app.socket, "debug.timings", timeout=60) or {}
            result["launch_marks_ms"] = marks.get("launch_ms_since_process_start")
            result["launch_terminals_frame_shown_max_ms"] = marks.get("launch_terminals_frame_shown_max_ms")
        except (RuntimeError, OSError, ValueError) as error:
            result["launch_marks_ms"] = {"error": str(error)}
        if loaded_at is None:
            result["not_loaded_sample"] = sample("not-loaded.sample.txt")
            failures.append(f"the app's model did not load in {args.timeout} s: {json.dumps(seen)[:200]}")
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
                    failures.append(f"step {step}: {error}")
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
            if code:
                failures.append(f"step {step}: exit {code}")
    finally:
        if held:
            if held.poll() is not None:  # it holds its connections until this script ends it
                failures.append(f"the clients step ended before the launch did (exit {held.poll()})")
            held.terminate()  # the PID this script started
        began = time.monotonic()
        app.stop(quit_timeout=args.quit_timeout)
        result["quit_s"] = round(time.monotonic() - began, 1)
        result["failures"] = failures
        with open(os.path.join(args.out, "launch.json"), "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=1)
        print("SESSION-REAL-LAUNCH-END " + json.dumps({k: result.get(k) for k in ("window_and_socket_s", "model_loaded_s", "quit_s", "steps", "failures")}), flush=True)
        if installed and not args.keep_installed:
            uninstall(argparse.Namespace(tag=tag, home=None))
    if failures:
        raise SystemExit("session_real: the launch had failures: " + "; ".join(failures))


def tag_of_app(app):
    """The tag of a `cmux DEV <tag>.app` bundle, as bench_launch.tag_of reads it."""
    found = re.fullmatch(r"cmux DEV (.+)\.app", os.path.basename(os.path.realpath(app).rstrip("/")))
    if not found:
        raise SystemExit(f"session_real: expected a `cmux DEV <tag>.app` bundle, got {app}")
    return check_tag(re.sub(r"[^a-z0-9]+", "-", found.group(1).lower()).strip("-"))


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

    def print_counts(a):
        daemon_socket, app_socket = sockets(a)
        print("SESSION-REAL-COUNTS " + json.dumps(counts(Conn(daemon_socket), app_socket)), flush=True)

    p.set_defaults(run=print_counts)

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
    p.add_argument("--sample-rows", help="comma list of rows to run beside a `sample` of the app (<out>.<row>.sample.txt); "
                   "their times are then not for a table")
    p.add_argument("--sample-seconds", type=int, default=10)
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
    p.add_argument("--restore-timeout", type=float, default=45, help="how long to wait for the app's restart of the kept agent terminals")
    p.add_argument("--socket-only", action="store_true", help="a host with no GUI session: counts, memory and processes only, never a frame time")
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
