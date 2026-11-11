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
           restore: a restored agent terminal has a new shell, or the real CLI that the product's
           "Resume Agents After Restart" started; that CLI is ended by its exact PIDs first)
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

Exit codes, the same for every command:
  0  done, and the result is what was asked for
  1  refused or stopped (`session_real: <why>`); `launch`: it had failures (after the quit and the uninstall)
     128 + N: stopped by signal N (SIGTERM: 143), after each clean-up ran
  2  wrong arguments
  3  the command ran to its end and wrote its output, but the result has failures: a line
     `SESSION-REAL-FAULTS <command> [...]` names each one (map: a failed, empty, short or skipped row, a failed
     set-up action; agents: a failed restart, a terminal that took no input, a wrong count of programs;
     clients: the daemon's list is not the count asked for, or it closed a held connection)

What this tool removes: only a folder that it made itself in this run, never one found by a name. A work folder of
this run has the file `.session-real-made-by-this-run.json` with a token of this process and the folder's inode
(``OwnFolder``); the installed copy has `session-real-installed.json` with the same two. So `launch --saved` deletes
the copy that it installed; the `uninstall` command of a later run moves the installed copy to
`<tag>.session-real-removed-<time>-<id>` beside the tag's state and prints the path. `install` changes the tag's
state only at its end (two renames, no signal between them): a failed or killed copy leaves the tag as it was.

A saved session is the folder `~/Library/Application Support/cmux-next/tags/<tag>` of a bench app
whose daemon stopped with "End Sessions, Keep Layout" (`debug.quit {fixture_quit:"end-sessions"}`,
what `bench_launch.BenchApp.stop` sends). It is tied to the tag: the registry names its session
`cmux-app-<tag>` and the daemon refuses another one's. So each twin tag gets its own saved session
(`build`, about two minutes), and a clone of a twin that keeps the bundle name uses the same one.

Only on a fleet mini, never on a person's Mac: `make` starts hundreds of processes.
"""

import argparse
import tempfile
import json
import os
import pwd
import re
import select
import shutil
import signal
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
EXIT_FAULTS = 3  # the command ran to its end and wrote its output, but the result has failures


def end_with(command, faults):
    """Ends the command with exit 3 when its result has failures; each one is printed first."""
    if not faults:
        return
    print(f"SESSION-REAL-FAULTS {command} " + json.dumps(faults), flush=True)
    raise SystemExit(EXIT_FAULTS)


def stop_on_signals():
    """SIGTERM and SIGHUP raise SystemExit, so each `finally` and `except BaseException` of a command runs (a hold's
    watchdog and a `kill <pid>` end a command with SIGTERM)."""
    def stop(signum, _frame):
        raise SystemExit(128 + signum)
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, stop)


class SignalsHeld:
    """SIGTERM, SIGHUP and SIGINT wait while the block runs (two renames that must both happen, a clean-up that
    must end); a signal that came in the block is delivered after it."""

    SIGNALS = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)

    def __enter__(self):
        self.before = signal.pthread_sigmask(signal.SIG_BLOCK, self.SIGNALS)
        return self

    def __exit__(self, *_):
        signal.pthread_sigmask(signal.SIG_SETMASK, self.before)


# ---------------------------------------------------------------- the folders this tool may remove

OWN_MARK = ".session-real-made-by-this-run.json"


class OwnFolder:
    """A folder that THIS run made: an exclusive `mkdir` (a folder that is there is never taken over), then a mark
    file with a token only this process knows and the folder's inode. `remove` checks both first, so this tool
    removes only what it made itself in this run: never a folder another process made, never by a name pattern."""

    def __init__(self, path, what):
        self.path = os.path.abspath(path)
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        try:
            os.mkdir(self.path)
        except FileExistsError:
            raise SystemExit(f"session_real: {self.path} exists; give a new folder (nothing is deleted for you)") from None
        self.token = uuid.uuid4().hex
        with open(os.path.join(self.path, OWN_MARK), "x", encoding="utf-8") as handle:
            json.dump({"token": self.token, "pid": os.getpid(), "what": what, "inode": os.stat(self.path).st_ino,
                       "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, handle)

    def is_mine(self):
        try:
            with open(os.path.join(self.path, OWN_MARK), encoding="utf-8") as handle:
                mark = json.load(handle)
            return isinstance(mark, dict) and mark.get("token") == self.token and mark.get("inode") == os.stat(self.path).st_ino
        except (OSError, ValueError):
            return False

    def remove(self):
        """Removes the folder when it is still the one this run made; else prints why not and leaves it."""
        if not self.is_mine():
            print(f"session_real: NOT removed: {self.path} does not carry the mark of this run", flush=True)
            return False
        shutil.rmtree(self.path)
        return True

    def keep(self):
        """The folder is a result (a saved session): it stays, without the run's mark."""
        if self.is_mine():
            os.remove(os.path.join(self.path, OWN_MARK))


def left_by_earlier_runs(target):
    """The stage and trash folders beside `target` that an earlier run of this tool left (it was killed). They are
    printed, never removed: this run did not make them."""
    parent, name = os.path.dirname(target), os.path.basename(target)
    try:
        found = sorted(entry for entry in os.listdir(parent)
                       if entry.startswith(name + ".session-real-")
                       and any(os.path.exists(os.path.join(parent, entry, mark)) for mark in (OWN_MARK, INSTALL_MARK)))
    except OSError:
        return []
    for entry in found:
        print(f"session_real: NOTE: {os.path.join(parent, entry)} is from an earlier run of this tool; "
              "this run does not remove it (it did not make it)", flush=True)
    return found


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


# The tags of the shipped builds, which keep a person's session (`BuildIdentity` ownedTags in the app,
# `SHIPPED_STATE_TAGS` in scripts/cmux-next/bench_launch.py). Compared in lower case: the default disk is case-blind.
CHANNELS = ("nightly", "rc", "staging", "cmux-next")


def bench_tag(session):
    """The tag of a tagged DEV build's session (`cmux-app-<tag>`), else None. Not a bench's: the release
    session `cmux-app`, a shipped build's (`cmux-app-nightly`, `-rc`, `-staging`, `-cmux-next`), an untagged build's
    (`cmux-app--<hash>`) and every other session (a person's `cmux-next` or `main`)."""
    found = re.fullmatch(r"cmux-app-([A-Za-z0-9][A-Za-z0-9_.-]*)", session or "")
    return found.group(1) if found and found.group(1).lower() not in CHANNELS else None


def check_tag(tag):
    """Refuses a tag that is no single folder name of a tagged DEV build."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", tag or "") or tag.lower() in CHANNELS:
        raise SystemExit(f"session_real: {tag!r} is not the tag of a tagged DEV build")
    return tag


def tagged_dev_bundle(bundle_id):
    """Whether a bundle id is a TAGGED DEV build's: `...debug.<tag part>` (`scripts/reload.sh --tag`). The untagged
    DEV build `com.cmuxterm.app.debug` and every shipped build are not."""
    return bool(re.search(r"\.debug\.[A-Za-z0-9][A-Za-z0-9._-]*$", bundle_id or ""))


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
        if not tagged_dev_bundle(info.get("bundle_id")) or bundle.startswith("/Applications/"):
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
    """PTYs in use by THIS USER's processes: the distinct devices behind the open /dev/ptmx handles (a terminal's
    host and the daemon hold several handles of one PTY). `lsof` without root does not show another user's, so on a
    Mac with a second user who has terminals open this is a lower bound of the machine's count (the key
    `ptys_in_use_machine` keeps its name for the results that exist; `ptys_in_use_scope` says it)."""
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
    out["ptys_in_use_scope"] = "this user's processes (lsof without root)"
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
    line = (f"PTY limit: kern.tty.ptmx_max={limit} for the whole machine, {used} in use now by this user, daemon reserve {PTY_RESERVE}. "
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
    park_asked = park_done = 0
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
                park_asked, park_done = park_asked + len(to_park), park_done + len(parked)
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
    # A parked tab reads as parked when its host exited (tab_park.rs): give the last batch up to 15 s before the count is judged.
    deadline = time.time() + 15
    while after["terminals_parked"] - before["terminals_parked"] < min(park_done, mix.count("terminal") - live_plain) and time.time() < deadline:
        time.sleep(0.5)
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
    faults += park_faults(park_asked, park_done, mix.count("terminal") - live_plain,
                          after["terminals_parked"] - before["terminals_parked"])
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=1)
    if faults:
        print("session_real: READ-BACK DIFFERS: " + "; ".join(faults), flush=True)
    end_with("make", faults)
    print(f"OK: made and read back {want} in {seconds:.1f} s", flush=True)


def park_faults(asked, parked, want, read_back):
    """The faults of the parked terminals: what `park-tabs` answered against what was sent, and the parked count the
    daemon reads back against the mix (more shells than the split printed with the PTY limit is a wrong session)."""
    faults = []
    if parked != asked:
        faults.append(f"park-tabs: asked {asked}, the daemon parked {parked}")
    if read_back != want:
        faults.append(f"parked terminals: the mix has {want}, read back {read_back} more than before")
    return faults


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

AGENT_COMMAND = re.compile(r"session_real_agent\.zsh \S+ (real-\d{4})(?:\s|$)")


# The CLI that the product's "Resume Agents After Restart" starts in a restored agent terminal of this session: the
# stored record of the bench program is a Claude session `session-real-<name>`, so the product types
# `claude --resume session-real-<name>` and the real CLI runs (measured 2026-11-10, aws-m4pro-3: 157 of 170 terminals,
# 12.6 GB). The program path has no space and the session id is the one this tool gave that terminal's bench program.
RESUMED_CLI = re.compile(r"^(?:\S*/)?claude\s(?:.*\s)?--resume session-real-(real-\d{4})(?:\s|$)")
SHELLS = ("sh", "bash", "zsh", "dash", "ksh")


def is_shell(command):
    """True for `login` and for a shell that runs no script (`-zsh`, `/bin/zsh`, `-/bin/zsh -l`): a shell with a
    script or a command (`/bin/sh /path/claude ...`, `zsh -f program`) is a program, not a prompt."""
    words = command.split()
    if not words:
        return False
    name = os.path.basename(words[0].lstrip("-"))
    return name == "login" or (name in SHELLS and all(word.startswith("-") for word in words[1:]))


def children_of(rows):
    """{pid: [the pids whose parent it is]} of `rows` ({pid: (ppid, start, command)})."""
    children = {}
    for other, (parent, _, _) in rows.items():
        children.setdefault(parent, []).append(other)
    return children


def below(pid, rows, children=None):
    """The pids in `rows` ({pid: (ppid, start, command)}) that have `pid` as an ancestor (`children`: `children_of(rows)`,
    when the caller asks for many)."""
    children = children_of(rows) if children is None else children
    found, todo = set(), [pid]
    while todo:
        for other in children.get(todo.pop(), ()):
            if other not in found and other != pid:
                found.add(other)
                todo.append(other)
    return found


def started_seconds_ago(start, now):
    """How long ago a process started, from its `ps lstart` text (`Tue Nov 10 18:29:37 2026`); None when not readable."""
    try:
        return now - time.mktime(time.strptime(" ".join(start.split()), "%a %b %d %H:%M:%S %Y"))
    except (ValueError, OverflowError, AttributeError):
        return None


def agent_terminal_states(conn, tabs, rows=None, now=None):
    """{name: state} of each agent terminal, from the daemon's `terminal-resources` (its own terminals only) and the
    process table. A state is ("program", pid): the bench agent program with this terminal's name runs;
    ("resumed", {pid: start}): the real CLI that the product's resume started for this terminal's bench session runs,
    with the processes below it; ("shell", seconds): only shells, the newest one started `seconds` ago (None: not
    known); ("other", text): another program runs or what runs is not known, it is not this tool's; ("none", None):
    the daemon has no terminal for the tab (a dead tab). Only the terminal's own process (`pid`) and the processes
    below it in the process table count: a listed PID that is not there (a PID that another process took between the
    daemon's reply and the table) makes the terminal "other", so it gets no start line and no signal in this read.
    A reply that is not OK stops the command (exit 1)."""
    reply = conn.call("terminal-resources", surfaces=[tab["surface"] for _, tab in tabs])
    if not reply.get("ok"):
        raise SystemExit(f"session_real: the daemon did not answer terminal-resources: {reply.get('error')!r}; "
                         "the agent programs cannot be counted")
    rows = process_rows() if rows is None else rows
    children = children_of(rows)
    by_surface = {terminal.get("surface"): terminal for terminal in (reply.get("data") or {}).get("terminals") or []}
    states = {}
    for number, tab in tabs:
        name, terminal = f"real-{number:04d}", by_surface.get(tab["surface"])
        if terminal is None:
            states[name] = ("none", None)
            continue
        root = terminal.get("pid")
        if root not in rows:
            states[name] = ("other", "the daemon names no live process for this terminal: what runs in it is not known")
            continue
        tree = {root} | below(root, rows, children)
        listed = [pid for pid in dict.fromkeys([root] + [process.get("pid") for process in terminal.get("processes") or []])
                  if pid in rows]
        pids = [pid for pid in listed if pid in tree]
        if len(pids) < len(listed):
            outside = next(pid for pid in listed if pid not in tree)
            states[name] = ("other", f"pid {outside} of the daemon's list is not below this terminal's process: {rows[outside][2][:90]}")
            continue
        ages = [started_seconds_ago(rows[pid][1], time.time() if now is None else now) for pid in pids]
        state = ("shell", min(ages) if ages and None not in ages else None)
        for pid in pids:
            command = rows[pid][2]
            named = AGENT_COMMAND.search(command)
            if named and named.group(1) == name:
                state = ("program", pid)
                break
            resumed = RESUMED_CLI.search(command)
            if resumed and resumed.group(1) == name:
                # The CLI and what it started, in this terminal only: each pid with its start time.
                mine = {pid} | (below(pid, rows, children) & set(pids))
                state = ("resumed", {one: rows[one][1] for one in sorted(mine)})
            elif state[0] == "shell" and not is_shell(command):
                state = ("other", command[:120])
        if state[0] == "resumed":
            # Another program beside the resumed CLI and its own processes: not this tool's, nothing is ended.
            extra = [rows[pid][2][:120] for pid in pids if pid not in state[1] and not is_shell(rows[pid][2])]
            if extra:
                state = ("other", extra[0])
        if state[0] in ("shell", "resumed") and terminal.get("truncated"):
            state = ("other", "the daemon cut the process list of this terminal: what runs in it is not known")
        states[name] = state
    return states


def agent_programs(conn, tabs, rows=None):
    """{name: pid} of the agent programs that run in the agent terminals of THIS daemon, from the daemon's own record
    (`agent_terminal_states`). Never by the program's name alone over the host, so another tag's programs do not
    count. Only for a daemon that has the command (``has_terminal_resources``)."""
    return {name: state[1] for name, state in agent_terminal_states(conn, tabs, rows).items() if state[0] == "program"}


def end_resumed(resumed, sig=signal.SIGTERM, rows=None, kill=None):
    """Sends `sig` to each process of `resumed` ({pid: start}) that is still the same process (same start time):
    exact PIDs that the daemon listed in a terminal of its own, never a name. The pids it signalled."""
    rows = process_rows() if rows is None else rows
    done = []
    for pid, start in resumed.items():
        if pid in rows and rows[pid][1] == start:
            try:
                (kill or os.kill)(pid, sig)
                done.append(pid)
            except (ProcessLookupError, PermissionError):
                pass
    return done


RETYPE_SECONDS = 8   # a start line that did not start the program (typed at the moment the product typed its own) is typed again
# The product types its resume command into a new shell at the shell's prompt: it waits for the prompt for at most 10 s
# and then for a quiet prompt for at most 10 s more (terminal_respawn/prefill.rs, PROMPT_WAIT two times: 20 s at the
# worst; measured 5 to 10 s at load 12 to 27). A shell younger than that, plus 5 s for the shim to start the CLI and
# for the 1 s steps of the process table's start times, gets no start line yet, so the line does not go into a CLI
# that starts in that moment. (If one still starts later: nothing more is typed into it and the next round ends it.)
SHELL_SETTLE_SECONDS = 25
KILL_SECONDS = 5     # a resumed CLI that does not end on SIGTERM gets SIGKILL after this
OTHER_SECONDS = 10   # another program for this long is not a start-up step (the product's shim, the wrapper): it stays


def start_agents(tabs, states_now, send, restart, end, state_of, settle, clock=time.time, sleep=time.sleep):
    """Brings each agent terminal to the bench agent program, in rounds, until all run it or `settle` seconds passed.
    `states_now()` gives {name: (kind, detail)} (`agent_terminal_states`). Each round reads the states one time and
    sends its start lines FIRST, with nothing between the read and the lines (no process table, no signal, no
    restart), so a line goes only into what the read saw as a shell. Then, per terminal:
    - "program": the bench program runs: nothing, never a line;
    - "resumed": the real CLI that the product's "Resume Agents After Restart" started: `end(pids, SIGTERM)` one time,
      SIGKILL after KILL_SECONDS; nothing is typed into it, the start line is typed when a later read sees only the shell;
    - "none": the daemon has no terminal (a dead tab): `restart(tab)` one time; a later read sees its new shell;
    - "shell": `send(number, tab, state)` when its newest shell is SHELL_SETTLE_SECONDS old (the product's own
      resume command comes before that); again after RETYPE_SECONDS when the program did not start;
    - "other": another program, or not known: never typed into, never signalled; after OTHER_SECONDS it is not waited for;
    - "unknown" (a daemon without `terminal-resources`): `restart` for a dead tab, the start line one time, as the
      tool did before.
    Returns the counts, the last states, `not_typed` (no line went in) and `held_back` (of those: the shell was too
    young when the time ended)."""
    names = {f"real-{number:04d}": (rank, number, tab) for rank, (number, tab) in enumerate(tabs)}
    result = {"started": 0, "restarted_shells": 0, "already_running": 0, "restart_failed": [], "ended_resumed": {},
              "resumed_killed": [], "rounds": 0}
    typed, restarted, ended, failed, other_since, young, first = {}, set(), {}, set(), {}, set(), True
    deadline = clock() + settle
    while True:
        states = states_now()
        result["rounds"] += 1
        late, young = clock() >= deadline, set()
        for name, (rank, number, tab) in names.items():   # 1. the start lines, right after the read
            kind, detail = states.get(name, ("none", None))
            if name in failed or kind not in ("shell", "unknown"):
                continue
            if kind == "shell" and detail is not None and detail < SHELL_SETTLE_SECONDS:
                young.add(name)
                continue
            if late or (kind == "unknown" and (name in typed or (tab.get("dead") and name not in restarted))):
                continue
            if name in typed and clock() - typed[name] < RETYPE_SECONDS:
                continue
            if send(number, tab, state_of(rank)):
                result["started"] += 0 if name in typed else 1
                typed[name] = clock()
        pending = 0
        for name, (rank, number, tab) in names.items():   # 2. the signals and the restarts; the next read sees their result
            kind, detail = states.get(name, ("none", None))
            if kind == "program":
                result["already_running"] += 1 if first else 0
                continue
            if name in failed or (kind == "unknown" and name in typed):
                continue
            if kind == "other":
                pending += 1 if clock() - other_since.setdefault(name, clock()) < OTHER_SECONDS else 0
                continue
            other_since.pop(name, None)
            pending += 1
            if late:
                continue
            if kind == "resumed":
                if name not in ended:
                    if end(detail, signal.SIGTERM):
                        ended[name] = clock()
                        result["ended_resumed"][name] = sorted(detail)
                elif clock() - ended[name] >= KILL_SECONDS and name not in result["resumed_killed"]:
                    end(detail, signal.SIGKILL)
                    result["resumed_killed"].append(name)
            elif (kind == "none" or (kind == "unknown" and tab.get("dead"))) and name not in restarted:
                error = restart(tab)
                if error:
                    result["restart_failed"].append({"terminal": name, "error": error})
                    failed.add(name)
                else:
                    restarted.add(name)
                    result["restarted_shells"] += 1
        first = False
        if not pending or clock() >= deadline:
            break
        sleep(0.5)
    result["states"] = states
    result["not_typed"] = sorted(name for name, state in states.items()
                                 if state[0] in ("shell", "none", "unknown") and name not in typed and name not in failed)
    result["held_back"] = sorted(name for name in result["not_typed"] if name in young)
    return result


def has_terminal_resources(identity):
    """True when the daemon says that it has `terminal-resources` (its `identify` capabilities)."""
    return "terminal-resources-v1" in ((identity or {}).get("capabilities") or [])


def agent_programs_by_socket(daemon_socket, rows=None, read=None):
    """{name: pid} of the agent programs whose own environment names this daemon's socket (`CMUX_TUI_SOCKET`). For a
    daemon without `terminal-resources` only, and then a LOWER BOUND: a terminal that the app starts again from a
    saved session keeps the socket path of the daemon that made the session (measured 2026-11-10, aws-m4pro-3:
    29 of 170 after a restore), so this count is said and never judged."""
    teardown = teardown_module()
    rows = process_rows() if rows is None else rows
    read = read or teardown.procargs
    want = os.path.realpath(daemon_socket)
    found = {}
    for pid, (_, _, command) in rows.items():
        named = AGENT_COMMAND.search(command)
        if not named:
            continue
        got = read(pid)
        theirs = (got[1] if got else {}).get("CMUX_TUI_SOCKET")
        if theirs and os.path.realpath(theirs) == want:
            found[named.group(1)] = pid
    return found


def agents(args):
    """Starts the agent program in every agent terminal that has no agent program yet (`start_agents`)."""
    mix = mix_of(args)
    daemon_socket, _ = sockets(args)
    conn = Conn(daemon_socket)
    tree = conn.must("list-workspaces")
    made = sum(1 for workspace in tree.get("workspaces", []) if NAME.match(workspace.get("name") or ""))
    if made != mix.workspaces:
        # The mix rule finds the agent terminals by the workspace's number: with another session size it names others.
        raise SystemExit(f"session_real: the session has {made} workspaces of a `make` session (real-NNNN) and the counts given are "
                         f"for {mix.workspaces}: give `agents` the counts the session was made with (--workspaces --terminals "
                         "--agents --tabs --panes --browser-tabs); nothing was started")
    tabs = agent_tabs(tree, mix)
    # The daemon lists an agent again for a restarted kept tab from its stored record (measured: 113 listed after
    # a restore, with no program in their shells), so "runs" is read from the processes of this daemon's terminals.
    exact = has_terminal_resources(conn.must("identify"))

    def states_now():
        if exact:
            return agent_terminal_states(conn, tabs)
        running = agent_programs_by_socket(daemon_socket)
        return {f"real-{number:04d}": ("program", running[f"real-{number:04d}"]) if f"real-{number:04d}" in running
                else ("unknown", None) for number, _ in tabs}

    def send(number, tab, state):
        return bool(conn.call("send", surface=tab["surface"], text=agent_command(number, state)).get("ok"))  # not OK: the new shell is not in the tab yet

    def restart(tab):
        reply = conn.call("restart-tab", surface=tab["surface"])
        if reply.get("ok") or reply.get("error_code") == "tab-not-dead":
            return None
        print(f"restart-tab {tab['surface']}: {reply.get('error')!r}", flush=True)
        return str(reply.get("error"))[:200]

    table = {"at": 0.0, "rows": {}}

    def end(resumed, sig):
        # One process table for the signals of a round (it had one `ps` per terminal: 157 in a row at 826). A PID
        # gets the signal only when this table still has it with the start time that the state read saw.
        if time.time() - table["at"] > 1:
            table.update(rows=process_rows(), at=time.time())
        return end_resumed(resumed, sig, table["rows"])

    did = start_agents(tabs, states_now, send, restart, end, lambda rank: agent_state(rank, args), args.settle)
    states = did.pop("states")
    restart_failed, not_typed, held_back = did["restart_failed"], did.pop("not_typed"), did.pop("held_back")
    expected = len(tabs) - len(not_typed) - len(restart_failed) - sum(1 for state in states.values() if state[0] in ("other", "resumed"))
    settle_agents(conn, expected, args.settle)
    states = states_now()  # what runs now, after the wait for the reports: the count below is never an older read
    deadline = time.time() + min(args.settle, 15)
    while sum(1 for state in states.values() if state[0] == "program") < expected and time.time() < deadline:
        time.sleep(0.5)  # a shell takes a moment to `exec` the program
        states = states_now()
    programs = sum(1 for state in states.values() if state[0] == "program")
    other = {name: state[1] for name, state in states.items() if state[0] == "other"}
    resumed_left = sorted(name for name, state in states.items() if state[0] == "resumed")
    after = counts(conn)
    print("SESSION-REAL-AGENTS " + json.dumps({
        "started": did["started"], "restarted_shells": did["restarted_shells"], "already_running": did["already_running"],
        "not_started": len(not_typed), "held_back_young_shell": len(held_back), "restart_failed": len(restart_failed), "agent_terminals": len(tabs),
        "agent_programs_running": programs,
        "agent_programs_scope": "the agent terminals of this daemon (its terminal-resources)" if exact else
                                "a lower bound, not judged: programs whose CMUX_TUI_SOCKET is this daemon's (the daemon has no terminal-resources)",
        "resumed_cli_ended": len(did["ended_resumed"]), "resumed_cli_killed": len(did["resumed_killed"]),
        "resumed_cli_left": len(resumed_left), "other_programs": len(other), "rounds": did["rounds"],
        "after": after}), flush=True)
    end_with("agents", agents_faults(len(tabs), programs if exact else None, after.get("agents"), len(not_typed), restart_failed,
                                     other, resumed_left, len(held_back), args.settle))


def agents_faults(agent_terminals, programs, listed, not_started, restart_failed, other=None, resumed_left=(), held_back=0,
                  settle=None):
    """Why the `agents` result is not the session asked for (empty: it is)."""
    faults = []
    if other:
        first = sorted(other)[0]
        faults.append(f"{len(other)} agent terminals run another program; nothing was typed into them and nothing was ended: "
                      f"first {first}: {other[first]}")
    if resumed_left:
        faults.append(f"{len(resumed_left)} agent terminals still run the real CLI that the product's resume started "
                      f"(`claude --resume session-real-<name>`): first {resumed_left[0]}")
    if restart_failed:
        faults.append(f"restart-tab failed for {len(restart_failed)} agent terminals: first {json.dumps(restart_failed[0])}")
    if held_back:
        faults.append(f"{held_back} agent terminals got no start line: their shell was younger than {SHELL_SETTLE_SECONDS} s when "
                      f"--settle {settle:g} ended (the product types its resume command into a new shell in that time); "
                      "give a longer --settle")
    if not_started - held_back > 0:
        faults.append(f"{not_started - held_back} agent terminals took no input")
    if programs is not None and programs != agent_terminals:  # None: the daemon cannot say (no terminal-resources)
        faults.append(f"{programs} agent programs run in this daemon's terminals, the session has {agent_terminals} agent terminals")
    if listed is None or listed < agent_terminals:
        faults.append(f"the daemon lists {listed} agents, the session has {agent_terminals} agent terminals")
    return faults


STEADY_SECONDS = 10  # longer than the longest hook connection seen (9.07 s of 501, hold r3 2026-11-10)


def steady_clients(listed):
    """The clients of a `list-clients` reply that stay: not the asking connection, and either named (the app's
    connections and every bench client call `set-client-info`) or connected for STEADY_SECONDS or more. An agent's
    hook call is an unnamed connection for a moment (p50 0.3 s): it is in the daemon's list, and it is not one of
    the person's clients."""
    return [client for client in listed if isinstance(client, dict) and not client.get("self")
            and (client.get("name") or (client.get("connected_seconds") or 0) >= STEADY_SECONDS)]


def clients_faults(asked_total, steady, asked_count, held, closed):
    """Why the `clients` result is not what was asked for (empty: it is)."""
    faults = []
    if asked_total and steady != asked_total:
        faults.append(f"the daemon lists {steady} steady clients (named, or connected {STEADY_SECONDS} s or more), "
                      f"{asked_total} were asked for; {held} are held by this command")
    if not asked_total and held != asked_count:
        faults.append(f"{held} connections are held, {asked_count} were asked for")
    for index, seconds, received in closed:
        faults.append(f"the daemon closed held connection {index} after {seconds:.1f} s and {received} bytes of events")
    return faults


def clients(args):
    """Holds control connections open (each named and subscribed to tree deltas, as an app window or a phone is) and
    reads what the daemon sends them, until SIGTERM, SIGINT or `--seconds`. `--total N`: as many as make the
    daemon's list of steady clients (``steady_clients``) N long; the count is READ BACK, and a count that is not N
    is a failure (a line `SESSION-REAL-FAULTS clients`, and exit 3 at the end; the connections stay held until
    then, so the bench beside it does not lose its clients in the middle)."""
    daemon_socket, _ = sockets(args)
    held, closed, stop = {}, [], {"now": False, "received": 0}
    began = time.time()

    def on_signal(_signum, _frame):
        stop["now"] = True  # the hold ends, the count is said, the exit code is the result's

    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, on_signal)

    def drain(seconds):
        """Reads the held connections for `seconds`, as soon as the daemon sends: it closes a subscriber that does
        not read its events for some seconds while 170 agents start (measured 2026-11-10)."""
        until = time.time() + seconds
        while not stop["now"]:
            left = until - time.time()
            if left <= 0:
                break
            by_socket = {conn.sock: index for index, conn in held.items()}
            if not by_socket:
                time.sleep(min(0.25, left))
                continue
            for sock in select.select(list(by_socket), [], [], min(0.25, left))[0]:
                try:
                    while True:
                        chunk = sock.recv(1 << 20)
                        if not chunk:
                            raise ConnectionError("closed")
                        stop["received"] += len(chunk)
                except BlockingIOError:
                    pass
                except OSError:
                    index = by_socket[sock]
                    held.pop(index).close()
                    closed.append((index, time.time() - began, stop["received"]))
                    print("SESSION-REAL-FAULTS clients " + json.dumps(clients_faults(0, 0, 0, 0, closed[-1:])), flush=True)

    def read_list():
        """The daemon's client list. A full daemon (64 connections) refuses for some seconds: the held connections
        are read in that time too."""
        for _ in range(80):
            try:
                probe = Conn(daemon_socket, timeout=30, busy_wait=0)
            except ConnectionError:
                drain(0.5)
                continue
            try:
                return probe.must("list-clients") or []
            finally:
                probe.close()
        raise SystemExit("session_real: the daemon refused the list-clients connection for 40 s")

    def open_one():
        index = max(held, default=0) + 1 + len(closed)
        conn = Conn(daemon_socket)
        conn.call("set-client-info", name=f"session-real-client-{index}")
        conn.must("subscribe", tree_events="deltas")
        conn.sock.setblocking(False)
        held[index] = conn

    steady = None
    if args.total:
        # Make the count exact and read it back: add what is missing, take away what is too many, at most 4 times
        # (an unnamed connection of the app becomes steady, or goes, between two reads).
        # The count that is said and judged is always a read made AFTER the last change of this command.
        for attempt in range(6):
            listed = read_list()
            steady = len(steady_clients(listed))
            if steady == args.total or stop["now"] or attempt == 5:
                break
            for _ in range(max(0, args.total - steady)):
                open_one()
            for _ in range(min(len(held), max(0, steady - args.total))):
                held.pop(max(held)).close()
            drain(1.0)
    else:
        for _ in range(args.count):
            open_one()
        drain(0.5)
        listed = read_list()
    ready = {"held": len(held), "asked_total": args.total or None, "asked_count": None if args.total else args.count,
             "steady": len(steady_clients(listed)), "listed_with_short_ones": sum(1 for client in listed if not client.get("self")),
             "steady_rule": f"named, or connected {STEADY_SECONDS} s or more; not this command's own read"}
    ready["faults"] = clients_faults(args.total, ready["steady"], args.count, len(held), closed)
    print(f"SESSION-REAL-CLIENTS held {len(held)}, the daemon lists {ready['steady']} steady clients "
          f"({ready['listed_with_short_ones']} with the short ones) " + json.dumps(ready), flush=True)
    if ready["faults"]:
        print("SESSION-REAL-FAULTS clients " + json.dumps(ready["faults"]), flush=True)
    if args.ready_file:
        with open(args.ready_file + ".part", "w", encoding="utf-8") as handle:
            json.dump(ready, handle)
        os.replace(args.ready_file + ".part", args.ready_file)
    deadline = time.time() + args.seconds if args.seconds else None
    while not stop["now"] and (deadline is None or time.time() < deadline):
        drain(1.0 if deadline is None else max(0.0, min(1.0, deadline - time.time())))
    print(f"SESSION-REAL-CLIENTS done, {stop['received']} bytes of events read, {len(held)} held at the end", flush=True)
    for conn in held.values():
        conn.close()
    end_with("clients", clients_faults(args.total, ready["steady"], args.count, ready["held"], closed))


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


HOST_OWNER = re.compile(r"(?:^|\s)--owner \S+@(\d+)(?:\s|$)")


def groups(table, app_pid, daemon_pid, bundle, responsible=None):
    """The session's processes by role. `table`: pid -> (ppid, rss, cpu, command). In it: the app and its
    descendants; the daemon and its descendants; every process whose executable is inside the bundle (a helper or a
    daemon that outlived its parent; the bundle path has a space, so it is compared whole, never by its first word);
    the terminal hosts, which run from a copy outside the bundle and name their daemon (`--owner ...@<pid>`); every
    process macOS holds the app responsible for (`responsible`: pid -> pid; the WebKit XPC processes of its pages,
    which are children of launchd); and the descendants of all of those (the shells and programs of the hosts)."""
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
    roots = {root for root in (bundle, os.path.realpath(bundle), os.path.realpath(bundle).removeprefix("/private")) if root} if bundle else set()
    outside = []
    for pid, (_, _, _, command) in table.items():
        relative = next((command[len(root):] for root in roots if command.startswith(root + "/")), None)
        if pid not in role and relative is not None:
            role[pid] = "terminal_hosts" if relative.startswith("/Contents/Resources/bin/cmux-tui") else "bundle_other"
            outside.append(pid)
    for pid, (_, _, _, command) in table.items():
        owner = HOST_OWNER.search(command)
        if pid not in role and owner and int(owner.group(1)) in role:
            role[pid] = "terminal_hosts"
            outside.append(pid)
    for pid, (_, _, _, command) in table.items():
        if pid not in role and responsible is not None and responsible(pid) == app_pid:
            role[pid] = "webkit_xpc" if "com.apple.WebKit." in command else "app_responsible"
            outside.append(pid)
    for root in outside:
        for pid in below(root):
            role.setdefault(pid, daemon_child_kind(table[pid][3]) if role[root] == "terminal_hosts" else role[root])
    return role


def measure(args):
    daemon_socket, app_socket = sockets(args)
    if not app_socket:
        raise SystemExit("session_real: measure needs --app-socket")
    info = app_rpc(app_socket, "system.identify", timeout=10)
    app_pid, bundle = int(info["pid"]), info.get("app_bundle_path") or ""
    daemon_pid = daemon_of_app(app_socket)[0]
    sys.path.insert(0, HERE)
    import procs  # noqa: PLC0415  (xbench's per-process counters: proc_pid_rusage, no root)

    first = process_table()
    responsible = getattr(procs, "_responsible", None)
    role = groups(first, app_pid, daemon_pid, bundle, responsible)

    def soft(method, params=None):
        try:
            return app_rpc(app_socket, method, params, timeout=20) or {}
        except (RuntimeError, OSError, ValueError) as error:
            return {"error": str(error)}

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
        "app_idle": wakes, "counts": counts(conn, app_socket), "host": host_facts(), "socket_only": bool(args.socket_only),
        "process_set": "the app, the daemon, their descendants, the bundle's processes, the terminal hosts of the daemon "
                       "(--owner), the processes macOS holds the app responsible for (WebKit XPC), and their descendants; "
                       "read one time before the window (a process that starts in the window is not counted)",
        "note": "per group over the window: footprint_mb = sum of phys_footprint (Activity Monitor's Memory), rss_mb = sum of resident "
                "sizes (shared pages counted in each process), cpu_percent and wakeups_per_s from proc_pid_rusage (procs.py)",
    }
    if args.socket_only:
        result["socket_only_note"] = "no GUI session: the frame clock and the main-thread wakes are not a person's; memory and process counts only"
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


ROWS = ("workspace_switch_warm", "tab_switch", "new_tab", "split", "workspace_close", "workspace_switch_cold")


def cold_targets(real, runs):
    """The workspaces of the cold-switch row: `runs` DIFFERENT ones spread over the session, never real[0] (the warm
    row shows it). A session with fewer other workspaces than `runs` gives each one time: the row is then short and
    `map` says so, because a workspace that shows a second time is not a first show."""
    if runs <= len(real) - 2:
        step = max(1, (len(real) - 2) // runs)
        return [real[1 + i * step] for i in range(runs)]
    return list(real[1:])


def map_faults(asked, rows, runs, failed, skipped, untimed_errors):
    """Why the map is not the one asked for (empty: it is). `asked`: the row names in order; `rows`: the summaries;
    `failed`: (row, why); `skipped`: rows the time budget cut. A slow action (over 1 s, `unusable`) is a result of
    the app, not a failure of the map: it is in the row's numbers and is not a fault here."""
    faults = [f"row {name}: failed: {why}" for name, why in failed]
    faults += [f"row {name}: not run: the time budget of this map ended" for name in skipped]
    by_name = {row["row"]: row for row in rows}
    gone = {name for name, _ in failed} | set(skipped)
    for name in asked:
        row = by_name.get(name)
        if row is None:
            if name not in gone and not (name == "new_workspace" and "workspace_close" in gone):
                faults.append(f"row {name}: no result")
            continue
        if row["runs"] != runs:
            faults.append(f"row {name}: {row['runs']} runs, {runs} were asked for")
        if row["errors"]:
            faults.append(f"row {name}: {row['errors']} of {row['runs']} runs failed: first {str(row.get('first_error'))[:200]}")
        good = row["runs"] - row["errors"]
        timed = (row.get("commit_ms") or {}).get("n", 0)
        if timed < good:
            faults.append(f"row {name}: {timed} of {good} good runs have a commit time (debug.action_budget had no sample of the action)")
    if untimed_errors:
        faults.append(f"{len(untimed_errors)} set-up or clean-up actions failed (the next run then starts wrong): first {json.dumps(untimed_errors[0])[:240]}")
    return faults


def map_rows(args):
    """The first map of the app at this session: 20 runs per action, the app's own clocks."""
    wanted = set(args.rows.split(",")) if args.rows else None
    sampled = set(args.sample_rows.split(",")) if args.sample_rows else set()
    unknown = sorted(((wanted or set()) | sampled) - set(ROWS))
    if unknown:
        raise SystemExit(f"session_real: map has no row {', '.join(unknown)}; its rows are {', '.join(ROWS)}")
    daemon_socket, app_socket = sockets(args)
    if not app_socket:
        raise SystemExit("session_real: map needs --app-socket")
    app = AppDriver(app_socket, daemon_socket)
    runs, rows, raw = args.runs, [], {}
    failed, skipped = [], []
    asked = [name for name in ROWS if not wanted or name in wanted]
    if "workspace_close" in asked:
        asked.insert(asked.index("workspace_close") + 1, "new_workspace")
    stem = (args.out or args.sample or "/tmp/session-real-map").removesuffix(".json")
    deadline = time.time() + args.budget_seconds

    def row(name, note, make):
        if wanted and name not in wanted:
            return
        if time.time() > deadline:
            print(f"SESSION-REAL-ROW-SKIPPED {name}: the time budget of this run ended", flush=True)
            skipped.append(name)
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
            failed.append((name, f"{type(error).__name__}: {error}"))
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

    cold = cold_targets(real, runs)

    def switch_cold():
        return [app.timed("goToWorkspace", timer="debug.workspace_switch", workspace=ids[name]) for name in cold]

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
    row("workspace_switch_cold", f"first show of {len(cold)} other workspaces spread over the session, each one time in this map "
        "(a parked terminal starts its shell; a second map in one launch shows them a second time)", switch_cold)
    app.step("goToWorkspace", workspace=bench)
    app.step("closeWorkspace", confirm=True)
    sample = None
    if app.unusable and args.sample:
        sample = args.sample
        subprocess.run(["sample", str(app.pid), "3", "-file", sample], capture_output=True)
    faults = map_faults(asked, rows, runs, failed, skipped, app.untimed_errors)
    result = {"rows": rows, "unusable": app.unusable, "untimed_errors": app.untimed_errors, "sample": sample,
              "faults": faults, "rows_asked": asked, "socket_only": bool(args.socket_only),
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
    if args.socket_only:
        print("SESSION-REAL-MAP-SOCKET-ONLY no GUI session: these times are not for a table", flush=True)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=1)
    end_with("map", faults)


# ---------------------------------------------------------------- save, install

def state_root(home=None):
    """The folder of every tag's state. The app finds it from the ACCOUNT's home, not from $HOME (a bench runs with
    its own HOME, FLEET.md f3), so the default here is the account's home too."""
    return os.path.join(home or pwd.getpwuid(os.getuid()).pw_dir, "Library/Application Support/cmux-next/tags")


def teardown_module():
    """scripts/cmux-next/tag_teardown.py: the one reader of a tag's processes (by bundle path and `--owner`)."""
    folder = os.path.join(os.path.dirname(HERE), "cmux-next")
    if folder not in sys.path:
        sys.path.insert(0, folder)
    import tag_teardown  # noqa: PLC0415
    return tag_teardown


def process_rows():
    """{pid: (ppid, start, command)} of every process."""
    return teardown_module().TagTeardown._table()


BUNDLE = re.compile(r"/cmux DEV ([^/]+)\.app/Contents/")
OWNER = re.compile(r"(?:^|\s)--owner ([A-Za-z0-9._-]+):([A-Za-z0-9._-]+)@(\d+)(?:\s|$)")


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def tag_processes(tag, rows, exclude=()):
    """The commands in `rows` ({pid: (ppid, start, command)}) that are processes of `tag`, by what each one says
    itself, as whole words: a daemon of the tag's session (`--session cmux-app-<tag>`), a process that runs from a
    `cmux DEV <name>.app` bundle whose name gives this tag (the name is not always the tag: `cmux DEV Chrome Parity
    v2.app` is chrome-parity-v2), and a terminal host that names the tag (`--owner <bundle id>:<tag>@<pid>`; a host
    stays after its daemon). Never a substring of another tag's name."""
    session = re.compile(r"(?:^|\s)--session(?:=|\s+)cmux-app-" + re.escape(tag) + r"(?:\s|$)")
    found = {}
    for pid, (_, _, command) in rows.items():
        if pid in exclude:
            continue
        bundle = BUNDLE.search(command)
        owner = OWNER.search(command)
        if session.search(command) or (bundle and slug(bundle.group(1)) == tag) or (
                owner and (owner.group(2) == tag or owner.group(1).endswith(".debug." + tag))):
            found[pid] = command
    return found


def running_with_tag(tag, app=None):
    """The commands of the tag's processes that run now. With the bundle (`app`), also what the bench's own
    teardown finds for it (bundle path, host records, holders and their children)."""
    teardown = teardown_module()
    rows = process_rows()
    found = tag_processes(tag, rows, exclude=teardown.TagTeardown._lineage(rows, os.getpid()))
    if app:
        found.update(dict(teardown.TagTeardown(app).processes()))
    return [found[pid] for pid in sorted(found)]


def copy_tree(source, target):
    """An APFS clone copy (`cp -Rc`; `cp` copies plainly where it cannot clone). `target` must not exist. On a
    failure nothing is removed here: the caller made the folder around `target` (``OwnFolder``) and removes that."""
    if os.path.lexists(target):
        raise SystemExit(f"session_real: {target} exists; give a new folder (nothing is deleted for you)")
    done = subprocess.run(["cp", "-Rc", source, target], capture_output=True, text=True)
    if done.returncode != 0:
        raise SystemExit(f"session_real: the copy of {source} failed (cp exit {done.returncode}): {done.stderr.strip()[:300]}")


def save(args):
    source = os.path.join(state_root(args.home), check_tag(args.tag))
    if not os.path.isdir(source):
        raise SystemExit(f"session_real: no state folder {source}")
    alive = running_with_tag(args.tag)
    if alive:
        raise SystemExit(f"session_real: the tag {args.tag} still runs ({len(alive)} processes); quit it with "
                         "debug.quit {fixture_quit: end-sessions} first: a copy of a live session is not a saved session")
    to = OwnFolder(args.to, "save")
    try:
        copy_tree(source, os.path.join(to.path, "state"))
        meta = {"tag": args.tag, "session": f"cmux-app-{args.tag}", "saved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "host": host_facts(), "note": args.note}
        with open(os.path.join(to.path, "session-real.json"), "w", encoding="utf-8") as handle:
            json.dump(meta, handle, indent=1)
    except BaseException:
        with SignalsHeld():
            to.remove()  # the half copy, in the folder this run made
        raise
    to.keep()
    size = subprocess.run(["du", "-sk", args.to], capture_output=True, text=True).stdout.split()
    print(f"SESSION-REAL-SAVED {args.to} ({int(size[0]) // 1024 if size else '?'} MB) from tag {args.tag}", flush=True)


INSTALL_MARK = "session-real-installed.json"
KEPT = ".before-session-real"
INSTALLED_BY_THIS_RUN = {}  # the token of each install mark this process wrote


def install_mark(folder):
    """The install mark of `folder` (a dict), or None when it has none. A mark that cannot be read is {}."""
    try:
        with open(os.path.join(folder, INSTALL_MARK), encoding="utf-8") as handle:
            mark = json.load(handle)
        return mark if isinstance(mark, dict) else {}
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        return {}


def made_in_this_run(folder):
    """True when `folder` is an installed copy THIS process made: its mark has a token this process wrote, and the
    inode the copy had when the mark was written (a rename keeps it; a folder made in its place has another)."""
    mark = install_mark(folder)
    try:
        return bool(mark) and mark.get("token") in INSTALLED_BY_THIS_RUN.values() and mark.get("inode") == os.stat(folder).st_ino
    except OSError:
        return False


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
    alive = running_with_tag(args.tag, getattr(args, "app", None))
    if alive:
        raise SystemExit(f"session_real: the tag {args.tag} runs ({len(alive)} processes); stop it first")
    if not os.path.isdir(source):
        raise SystemExit(f"session_real: {args.saved} has no `state` folder; nothing changed")
    refuse_two_states(target)
    left_by_earlier_runs(target)
    # The copy is made BESIDE the tag's state, in a folder of this run. The tag's state changes only at the end, in
    # two renames no signal can part: a failed or stopped copy leaves the tag as it was, with nothing to put back.
    stage = OwnFolder(f"{target}.session-real-stage-{uuid.uuid4().hex[:12]}", "install stage")
    try:
        staged = os.path.join(stage.path, "state")
        copy_tree(source, staged)
        token = uuid.uuid4().hex
        with open(os.path.join(staged, INSTALL_MARK), "w", encoding="utf-8") as handle:
            json.dump({"from": os.path.abspath(args.saved), "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                       "token": token, "pid": os.getpid(), "inode": os.stat(staged).st_ino}, handle)
        INSTALLED_BY_THIS_RUN[target] = token
        with SignalsHeld():
            moved = put_aside(target)
            try:
                os.rename(staged, target)
            except BaseException:
                if moved and not os.path.lexists(target):
                    os.rename(moved, target)
                    print(f"session_real: the install failed; {target} is as it was before", flush=True)
                raise
    finally:
        with SignalsHeld():
            stage.remove()
    print(f"SESSION-REAL-INSTALLED {target} from {args.saved}. Launch the app with BENCH_LAUNCH_KEEP_STATE=1 "
          "(bench_launch moves a tag's state away at each launch without it); `uninstall` puts the old state back.", flush=True)


def refuse_two_states(target):
    """Stops before any change when the tag has a state that is not an installed copy AND a kept state from an
    earlier install: one of the two would have to go, and this tool does not choose."""
    kept = target + KEPT
    if os.path.lexists(target) and install_mark(target) is None and os.path.lexists(kept):
        raise SystemExit(f"session_real: {target} is not an installed copy and {kept} is there too (an earlier install was "
                         "not taken away, then the tag ran on a new state). Nothing changed. Look at both and move one away yourself")


def take_away(target):
    """Takes the installed copy at `target` out of the tag's place by one rename. The caller then removes it with
    ``remove_if_mine``."""
    away = f"{target}.session-real-removed-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{uuid.uuid4().hex[:8]}"
    os.rename(target, away)
    return away


def remove_if_mine(away):
    """Removes a taken-away installed copy only when THIS run made it (``made_in_this_run``). A copy an earlier run
    or another process installed stays, under the name ``take_away`` gave it, and is printed."""
    if made_in_this_run(away):
        try:
            shutil.rmtree(away)
        except OSError as error:
            print(f"session_real: the installed copy this run made is out of the tag's place but not all removed: {away}: {error}", flush=True)
            return False
        print(f"removed the installed copy this run made ({os.path.basename(away)})", flush=True)
        return True
    print(f"session_real: NOT deleted: this run did not make the installed copy; it is now {away} "
          "(its source is the saved folder its mark names; remove it yourself)", flush=True)
    return False


def put_aside(target):
    """Makes room at `target`; returns the path the old state moved to, or None. An installed copy of a saved
    session (it has the mark) is taken away (``take_away``, ``remove_if_mine``). Any other state moves to
    `<target>.before-session-real`, never deleted; when that name is taken, nothing changes (``refuse_two_states``)."""
    if not os.path.lexists(target):
        return None
    if install_mark(target) is not None:
        remove_if_mine(take_away(target))
        return None
    refuse_two_states(target)
    kept = target + KEPT
    os.rename(target, kept)
    print(f"moved the tag's old state to {kept} (not deleted)", flush=True)
    return kept


def uninstall(args):
    """Takes the installed copy away and puts the state from before `install` back (the next owner of the tag
    then finds what was there). The copy is deleted only when this same run installed it (`launch --saved`); the
    `uninstall` command of a later run moves it beside the tag's state and prints where."""
    target = os.path.join(state_root(args.home), check_tag(args.tag))
    kept = target + KEPT
    alive = running_with_tag(args.tag, getattr(args, "app", None))
    if alive:
        raise SystemExit(f"session_real: the tag {args.tag} runs ({len(alive)} processes); stop it first")
    if not os.path.lexists(target) and os.path.lexists(kept):
        # A run that was killed between its two renames: the state from before is the tag's state.
        os.rename(kept, target)
        print(f"SESSION-REAL-UNINSTALLED {target} (no installed copy was there; old state back)", flush=True)
        return
    if install_mark(target) is None:
        raise SystemExit(f"session_real: {target} is not an installed saved session (no {INSTALL_MARK}); nothing changed")
    with SignalsHeld():
        away = take_away(target)
        if os.path.lexists(kept):
            os.rename(kept, target)
    remove_if_mine(away)
    print(f"SESSION-REAL-UNINSTALLED {target} ({'old state back' if os.path.exists(target) else 'no old state'})", flush=True)


# The app's own environment at each launch this tool makes. CMUX_MOCK_KEYCHAIN: a Release or nightly bundle asks the
# system keychain for "Chromium"; on a host whose keychain is locked a system dialog then covers the window
# (aws-m4pro-7, 2026-11-10). With it Chromium uses its mock key store (CEFSwitches.swift), as chrome_parity.py does.
APP_ENV = {"CMUX_MOCK_KEYCHAIN": "1"}


def launch(args):
    """Starts the bench app ON its saved session and says how long the restore takes, then runs the other
    commands against it and quits it as a bench does ("End Sessions, Keep Layout"). Needs the GUI session of a
    bench host (`bench_launch.BenchApp`); with `--saved` the session is installed first and taken away after."""
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, os.path.join(os.path.dirname(here), "cmux-next"))
    from bench_launch import BenchApp  # noqa: PLC0415  (only this command needs it)

    tag = tag_of_app(args.app)
    os.makedirs(args.out, exist_ok=True)
    app = BenchApp(args.app, out=args.out, env=dict(APP_ENV), fresh_state=False, socket_only=args.socket_only)
    result = {"tag": tag, "want_workspaces": None, "host": host_facts(), "steps": {}, "socket_only": args.socket_only}
    held, installed = None, False
    failures = []  # each one makes this command end with exit 1, after the quit and the uninstall
    stop_on_signals()  # a SIGTERM (a hold's watchdog) in the install or the steps runs the quit and the uninstall below

    def sample(name):
        if app.process and app.process.poll() is None:
            path = os.path.join(args.out, name)
            subprocess.run(["sample", str(app.process.pid), "3", "-file", path], capture_output=True, timeout=60)
            return path
        return None

    ptys_before = ptys_in_use()
    try:
        if args.saved:
            install(argparse.Namespace(saved=args.saved, tag=tag, home=None, app=args.app))
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
        # One base for every time of this result: the spawn of the app (bench_launch's `ready_seconds` starts there;
        # its checks before the spawn are `before_spawn_s`).
        spawned = time.monotonic() - (time.time() - app.launched_at) if app.launched_at else started
        result["window_and_socket_s"] = app.ready_seconds
        result["before_spawn_s"] = round(spawned - started, 2)
        result["times_from"] = "the spawn of the app"
        seen, loaded_at = None, None
        while time.monotonic() - started < args.timeout:
            try:
                seen = app_counts(app.socket)
            except (RuntimeError, OSError, ValueError) as error:
                seen = {"error": str(error)}
            if seen.get("loaded") and (want is None or seen.get("workspaces", 0) >= want):
                loaded_at = round(time.monotonic() - spawned, 2)
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
                        result["kept_terminals_restarted_s"] = round(time.monotonic() - spawned, 2)
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
                if held:
                    failures.append(f"step {step}: a second clients step (the first one holds its connections to the end)")
                    continue
                ready_file = os.path.join(args.out, "clients.ready.json")
                if os.path.lexists(ready_file):
                    os.remove(ready_file)  # one file by its full path: the answer of an earlier launch into this folder
                held = subprocess.Popen(me + ["clients", "--app-socket", app.socket, "--ready-file", ready_file,
                                              "--total", extra or str(REAL["clients"])])
                deadline = time.monotonic() + 90
                while not os.path.exists(ready_file) and held.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.25)
                try:
                    with open(ready_file, encoding="utf-8") as handle:
                        result["clients"] = json.load(handle)
                except (OSError, ValueError):
                    failures.append(f"step {step}: the clients command did not say its count in 90 s")
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
            if name in ("measure", "map") and args.socket_only:
                base += ["--socket-only"]  # the step's output says that its times are not a person's
            base += extra.split() if extra else []
            began = time.monotonic()
            code = subprocess.run(base).returncode
            key = step_key(result["steps"], step)
            result["steps"][key] = {"exit": code, "seconds": round(time.monotonic() - began, 1)}
            print(f"SESSION-REAL-STEP {key}: exit {code} in {result['steps'][key]['seconds']} s", flush=True)
            if code:
                failures.append(f"step {key}: exit {code}")
    finally:
        launch_end(args, app, tag, held, installed, result, failures)
    if failures:
        raise SystemExit("session_real: the launch had failures: " + "; ".join(failures))


def step_key(steps, step):
    """The key of a step in the result: the step's text, with `#2`, `#3` for a step that is in the list again."""
    key, n = step, 1
    while key in steps:
        n += 1
        key = f"{step}#{n}"
    return key


def launch_end(args, app, tag, held, installed, result, failures):
    """The end of `launch`, each part also when the part before it fails or a signal comes: the clients command ends
    and its exit code counts; the app quits and the tag's daemons end; the result is written; the saved session
    this launch installed is taken away. A failure of one part is a line in `failures`, never a part skipped."""
    def part(what, run):
        try:
            run()
        except BaseException as error:  # also SystemExit: a signal, a refusal, the teardown's own failure
            failures.append(f"{what}: {type(error).__name__}: {error}")
            print(f"session_real: {what} failed: {type(error).__name__}: {error}", flush=True)

    def end_clients():
        if held.poll() is not None:  # it holds its connections until this script ends it
            failures.append(f"the clients step ended before the launch did (exit {held.poll()})")
            return
        held.terminate()  # the PID this script started
        try:
            code = held.wait(timeout=60)
        except subprocess.TimeoutExpired:
            held.kill()  # the same PID: it did not end in 60 s
            code = f"none in 60 s after SIGTERM (killed, exit {held.wait(timeout=10)})"
        if code:
            failures.append(f"step clients: exit {code}")

    def quit_app():
        began = time.monotonic()
        try:
            app.stop(quit_timeout=args.quit_timeout)
        finally:
            result["quit_s"] = round(time.monotonic() - began, 1)

    def end_what_is_left():
        # The quit failed: the same teardown one more time (exact PIDs of this bundle, which this launch started).
        if app.process is not None:
            teardown_module().TagTeardown(args.app).end()

    def write():
        result["failures"] = failures
        with open(os.path.join(args.out, "launch.json"), "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=1)

    def take_installed_away():
        with SignalsHeld():
            uninstall(argparse.Namespace(tag=tag, home=None, app=args.app))

    target = os.path.join(state_root(), tag)
    try:
        if held:
            part("the end of the clients step", end_clients)
        before = len(failures)
        part("the quit of the app", quit_app)
        if len(failures) > before:
            part("the second teardown", end_what_is_left)
    finally:  # also when a signal comes between two parts above
        # `installed` is not set when a signal ended `install` right after its renames: the mark of this run says it.
        if (installed or made_in_this_run(target)) and not args.keep_installed:
            part("the uninstall", take_installed_away)
            if install_mark(target) is not None:
                print(f"SESSION-REAL-STATE-LEFT the saved session is still installed for tag {tag}: stop the tag's processes, "
                      f"then run `session_real.py uninstall --tag {tag}`", flush=True)
        part("the result file", write)
        print("SESSION-REAL-LAUNCH-END " + json.dumps({k: result.get(k) for k in ("window_and_socket_s", "model_loaded_s", "quit_s", "steps", "failures")}), flush=True)


def tag_of_app(app):
    """The tag of a `cmux DEV <tag>.app` bundle, as bench_launch.tag_of reads it."""
    found = re.fullmatch(r"cmux DEV (.+)\.app", os.path.basename(os.path.realpath(app).rstrip("/")))
    if not found:
        raise SystemExit(f"session_real: expected a `cmux DEV <tag>.app` bundle, got {app}")
    return check_tag(re.sub(r"[^a-z0-9]+", "-", found.group(1).lower()).strip("-"))


def hosts_of(daemon_pid, rows):
    """The pids in `rows` of the terminal hosts that name this daemon pid as their owner (`--owner ...@<pid>`)."""
    return sorted(pid for pid, (_, _, command) in rows.items()
                  if (found := OWNER.search(command)) and int(found.group(3)) == daemon_pid)


def end_build_daemon(daemon, sock, rows=process_rows, connect=None, kill=os.kill, wait=30):
    """Ends the daemon `build` started and the terminal hosts it made, after a failure: first the daemon's own
    `shutdown-daemon` with `end_terminals` (it ends its hosts and their shells), then SIGTERM to the daemon's PID,
    then SIGTERM to each host that still names that daemon PID as its owner and still has the same start time
    (exact PIDs of processes this run's daemon started; never a name). Returns what it did."""
    did = {"hosts_before": [], "asked": False, "daemon_signalled": False, "hosts_signalled": []}
    before = rows()
    hosts = {pid: before[pid][1] for pid in hosts_of(daemon.pid, before)}
    did["hosts_before"] = sorted(hosts)
    if daemon.poll() is None:
        try:
            conn = (connect or (lambda: Conn(sock, timeout=20, busy_wait=5)))()
            identity = conn.must("identify")
            conn.must("shutdown-daemon", pid=identity["pid"], generation=identity["generation"], end_terminals=True, keep_layout=False)
            conn.close()
            did["asked"] = True
            daemon.wait(timeout=wait)
        except (OSError, RuntimeError, ValueError, SystemExit, subprocess.TimeoutExpired) as error:
            did["ask_error"] = f"{type(error).__name__}: {error}"[:200]
    if daemon.poll() is None:
        daemon.terminate()  # the PID this script started
        did["daemon_signalled"] = True
        try:
            daemon.wait(timeout=wait)
        except subprocess.TimeoutExpired:
            daemon.kill()
    after = rows()
    for pid, start in hosts.items():
        if pid in after and after[pid][1] == start and OWNER.search(after[pid][2]):
            try:
                kill(pid, signal.SIGTERM)  # an exact PID: a host of the daemon this run started, the same process as before
                did["hosts_signalled"].append(pid)
            except ProcessLookupError:
                pass
    return did


def build(args):
    """Makes the saved session of one bench app with NO app and no GUI lock: the bundle's own daemon runs
    headless as the app's session (`cmux-app-<tag>`) on a new state folder, `make` fills it, and the daemon stops
    as the app's "End Sessions, Keep Layout" stops it. About two minutes; then `install` on any host."""
    tag = tag_of_app(args.app)
    binary = os.path.join(os.path.realpath(args.app), "Contents/Resources/bin/cmux-tui")
    if os.path.lexists(args.to):
        raise SystemExit(f"session_real: {args.to} exists; give a new folder")
    alive = running_with_tag(tag, args.app)
    if alive:
        raise SystemExit(f"session_real: the tag {tag} runs ({len(alive)} processes); stop it first")
    to = OwnFolder(args.to, "build")  # a failed build leaves it, with its mark and the daemon's log, for the owner to read
    state = os.path.join(to.path, "state", "tui")
    os.makedirs(state)
    home = OwnFolder(os.path.join(to.path, "build-home"), "build home")
    sock = os.path.join(tempfile.mkdtemp(prefix="session-real-", dir="/private/tmp"), "tui.sock")  # a mkdtemp dir: a guessable /tmp name could be planted by another account
    env = dict(os.environ, HOME=home.path, XDG_CONFIG_HOME=home.path + "/.config", XDG_STATE_HOME=home.path + "/.local/state",
               XDG_DATA_HOME=home.path + "/.local/share", XDG_CACHE_HOME=home.path + "/.cache",
               CMUX_TUI_CONFIG=os.path.join(home.path, "config.json"), SHELL="/bin/zsh")
    log = open(os.path.join(to.path, "daemon.log"), "a")
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
        args.socket, args.app_socket, args.out = sock, None, os.path.join(to.path, "make.json")
        make(args)  # a session that is not the one asked for ends here (exit 3): the folder then has no session-real.json
        started = time.time()
        ended = conn.must("shutdown-daemon", pid=identity["pid"], generation=identity["generation"], end_terminals=True, keep_layout=True)
        conn.close()
        daemon.wait(timeout=300)
        print(f"daemon stopped, keep layout: {ended.get('ended_terminals')} terminals ended in {time.time() - started:.1f} s", flush=True)
    finally:
        with SignalsHeld():
            did = end_build_daemon(daemon, sock)
        if did["asked"] or did["daemon_signalled"] or did["hosts_signalled"]:
            print("session_real: the build did not end as planned; its daemon and hosts were ended: " + json.dumps(did), flush=True)
    with open(os.path.join(to.path, "make.json"), encoding="utf-8") as handle:
        made = json.load(handle)
    meta = {"tag": tag, "session": f"cmux-app-{tag}", "saved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "host": host_facts(), "note": "built headless by session_real.py build", "asked": made["asked"],
            "daemon": open(os.path.join(os.path.dirname(binary), "cmux-tui.version"), encoding="utf-8").read().split()
            if os.path.exists(os.path.join(os.path.dirname(binary), "cmux-tui.version")) else None}
    with open(os.path.join(to.path, "session-real.json"), "w", encoding="utf-8") as handle:
        json.dump(meta, handle, indent=1)
    home.remove()
    to.keep()
    size = subprocess.run(["du", "-sk", os.path.join(to.path, "state")], capture_output=True, text=True).stdout.split()
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
    p.add_argument("--force", action="store_true", help="no effect now (kept for old callers): a terminal gets the start line when no agent program runs in it, "
                        "read from the processes; a running agent program never gets a line")
    p.set_defaults(run=agents)

    p = sub.add_parser("clients")
    target(p)
    p.add_argument("--count", type=int, default=REAL["clients"] - 1, help="connections to hold (his 13 = the app + 12)")
    p.add_argument("--total", type=int, default=0, help="hold as many as make the daemon's client list this long (his is 13)")
    p.add_argument("--seconds", type=float, default=0, help="0 = until killed")
    p.add_argument("--ready-file", help="write the read-back count here (JSON) when the connections are held")
    p.set_defaults(run=clients)

    p = sub.add_parser("measure")
    target(p)
    p.add_argument("--seconds", type=float, default=60)
    p.add_argument("--out")
    p.add_argument("--socket-only", action="store_true", help="the app has no GUI session: the output says so")
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
    p.add_argument("--socket-only", action="store_true", help="the app has no GUI session: the output says that its times are not for a table")
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
    if args.command in ("save", "install", "uninstall", "build"):
        stop_on_signals()  # SIGTERM runs each `finally`: no half copy, no daemon left (`launch` and `clients` set their own)
    args.run(args)


if __name__ == "__main__":
    main()
