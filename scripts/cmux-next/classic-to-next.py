#!/usr/bin/env python3
"""List classic cmux workspaces and agent chats, and reopen them in cmux-next.

  scripts/cmux-next/classic-to-next.py                 # list (newest first)
  scripts/cmux-next/classic-to-next.py --json          # the same, machine-readable
  scripts/cmux-next/classic-to-next.py --commands      # print the cmux-next commands, run nothing
  scripts/cmux-next/classic-to-next.py --apply --select a1,w3 [--socket /tmp/cmux-nightly.sock]

The playbook is docs/cmux-next/classic-to-next.md.

Reads only. Classic's files are opened read-only (SQLite with mode=ro and
immutable=1) and never written, moved or locked:
  ~/Library/Application Support/cmux/session-<bundle>.json        (the live snapshot)
  ~/Library/Application Support/cmux/session-<bundle>-previous.json
  ~/Library/Application Support/cmux/session-history/session-<bundle>-*.json
  ~/Library/Application Support/cmux/agent-journal-<bundle>.sqlite3
  ~/.cmuxterm/<agent>-hook-sessions.json                          (hook session stores)
and, to find a past chat's folder, the agent's own transcript
(~/.claude/projects/*/<id>.jsonl, ~/.codex/sessions/**/rollout-*<id>.jsonl).

Each row has a short id: w<N> for a workspace (its folder, title, split layout
and terminals with their launch commands), a<N> for an agent chat (Claude Code
or Codex session id and folder). --apply reopens the selected rows in a running
cmux-next through its control socket (session.transfer.open): an agent chat as a cmux-next agent chat
resumed by its session id, a workspace as a new workspace in its folder with
one terminal per classic terminal (cwd and launch or SSH command), in classic's
panes and splits.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shlex
import sqlite3
import sys
import time
from dataclasses import asdict, dataclass, field

HOME = os.path.expanduser("~")
AGENTS = ("claude", "codex")
BUNDLES = ("com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc", "com.cmuxterm.app.staging")


@dataclass
class Terminal:
    title: str
    cwd: str | None
    command: str | None
    panel: str | None = None  # classic panel id, which its layout names


@dataclass
class Agent:
    harness: str
    session: str
    cwd: str | None
    title: str
    last_seen: float  # unix seconds, 0 when unknown
    sources: list[str] = field(default_factory=list)
    workspace: str | None = None  # classic workspace id
    id: str = ""


@dataclass
class Workspace:
    key: str  # classic workspace id (or title + folder when it has none)
    title: str
    cwd: str | None
    layout: dict | None  # split tree over `terminals` (layout_of); None for one pane
    terminals: list[Terminal]
    ssh: str | None
    last_seen: float
    sources: list[str] = field(default_factory=list)
    agents: list[str] = field(default_factory=list)  # a<N> ids inside it
    id: str = ""


def safe_bundle(bundle: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", bundle)


def read_json(path: str):
    try:
        with open(path, "rb") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def command_text(value) -> str | None:
    """A launch command as a shell line (classic stores a string or an argv object)."""
    if value is None:
        return None
    if isinstance(value, str):
        return value.strip() or None
    if isinstance(value, list):
        return shlex.join(str(v) for v in value) or None
    if isinstance(value, dict):
        argv = value.get("arguments") or value.get("argv") or value.get("args")
        exe = value.get("executable") or value.get("command") or value.get("launcherPath")
        if isinstance(argv, list):
            parts = ([exe] if exe and (not argv or argv[0] != exe) else []) + argv
            return shlex.join(str(v) for v in parts) or None
        if isinstance(exe, str):
            return exe
    return None


def session_from_command(harness: str, command: str | None) -> str | None:
    """`claude --resume|-r|--session-id <id>` or `codex resume <id>`."""
    if not command:
        return None
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()
    flags = {"resume"} if harness == "codex" else {"--resume", "-r", "--session-id"}
    for i, token in enumerate(tokens[:-1]):
        if token in flags and not tokens[i + 1].startswith("-"):
            return tokens[i + 1]
    return None


def harness_of(value: str | None) -> str | None:
    value = (value or "").lower()
    return next((a for a in AGENTS if value == a or value.startswith(a + "-") or value.startswith(a + ":")), None)


class Inventory:
    def __init__(self, opts):
        self.opts = opts
        self.workspaces: dict[str, Workspace] = {}
        self.agents: dict[tuple[str, str], Agent] = {}
        self.files: list[str] = []

    # -- agents --------------------------------------------------------------
    def add_agent(self, harness, session, cwd, title, last_seen, source, workspace=None):
        if not harness or not session:
            return
        key = (harness, session)
        agent = self.agents.get(key)
        if agent is None:
            agent = self.agents[key] = Agent(harness, session, cwd, title or "", last_seen, [], workspace)
        agent.cwd = agent.cwd or cwd
        agent.title = agent.title or title or ""
        agent.workspace = agent.workspace or workspace
        agent.last_seen = max(agent.last_seen, last_seen)
        if source not in agent.sources:
            agent.sources.append(source)

    # -- snapshots -----------------------------------------------------------
    def snapshots(self):
        base = self.opts.classic_dir
        found = []
        for bundle in self.opts.bundle or BUNDLES:
            safe = safe_bundle(bundle)
            for name in (f"session-{safe}.json", f"session-{safe}-previous.json"):
                found.append(os.path.join(base, name))
            found += sorted(glob.glob(os.path.join(base, "session-history", f"session-{safe}-*.json")))
        return [p for p in found if os.path.isfile(p)]

    def read_snapshot(self, path):
        data = read_json(path)
        if not isinstance(data, dict):
            return
        self.files.append(path)
        created = data.get("createdAt")
        when = os.path.getmtime(path)
        if isinstance(created, (int, float)):
            # Foundation's default Date encoding: seconds since 2001-01-01.
            when = created + 978307200 if created < 1e9 else created
        label = os.path.relpath(path, self.opts.classic_dir)
        for window in data.get("windows") or []:
            for ws in ((window or {}).get("tabManager") or {}).get("workspaces") or []:
                self.read_workspace(ws, when, label)

    def read_workspace(self, ws, when, label):
        title = ws.get("customTitle") or ws.get("processTitle") or ""
        cwd = ws.get("currentDirectory")
        key = ws.get("stableId") or ws.get("workspaceId") or f"{title}|{cwd}"
        remote = ws.get("remote") or {}
        ssh = remote.get("destination")
        if ssh and remote.get("port"):
            ssh = f"{ssh} -p {remote['port']}"
        terminals, agent_ids = [], []
        for panel in ws.get("panels") or []:
            if (panel or {}).get("type") != "terminal":
                continue
            term = panel.get("terminal") or {}
            ptitle = panel.get("customTitle") or panel.get("title") or ""
            pcwd = term.get("workingDirectory") or panel.get("directory") or cwd
            agent = term.get("agent") or {}
            binding = term.get("resumeBinding") or {}
            harness = harness_of(agent.get("kind")) or harness_of(binding.get("kind"))
            session = agent.get("sessionId") or session_from_command(harness, command_text(binding.get("command"))) \
                or session_from_command(harness, command_text(binding.get("launchCommand"))) if harness else None
            if harness and session:
                acwd = agent.get("workingDirectory") or binding.get("cwd") or pcwd
                self.add_agent(harness, session, acwd, ptitle, when, label, key)
                agent_ids.append((harness, session))
                continue
            command = command_text(binding.get("command")) if binding.get("kind") == "ssh" else None
            command = command or command_text(term.get("tmuxStartCommand"))
            terminals.append(Terminal(ptitle, pcwd, command, panel.get("id")))
        # A canvas workspace (freeform panes) has no split tree to keep: its terminals come over as tabs.
        terminals, layout = layout_of(None if ws.get("layoutMode") == "canvas" else ws.get("layout"), terminals)
        existing = self.workspaces.get(key)
        if existing and existing.last_seen >= when:
            existing.sources.append(label)
            return
        self.workspaces[key] = Workspace(key, title, cwd, layout, terminals, ssh, when,
                                         (existing.sources if existing else []) + [label],
                                         [f"{h}:{s}" for h, s in agent_ids])

    # -- journal and hook stores ---------------------------------------------
    def read_journal(self):
        for bundle in self.opts.bundle or BUNDLES:
            path = os.path.join(self.opts.classic_dir, f"agent-journal-{safe_bundle(bundle)}.sqlite3")
            if not os.path.isfile(path):
                continue
            try:
                db = sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True, timeout=1)
                rows = db.execute(
                    "SELECT agent_key, session_id, workspace_id, MAX(occurred_at_ms) FROM agent_journal "
                    "WHERE session_id IS NOT NULL AND session_id != '' AND is_subagent = 0 "
                    "GROUP BY agent_key, session_id").fetchall()
                db.close()
            except sqlite3.Error as error:
                print(f"warning: {path}: {error}", file=sys.stderr)
                continue
            self.files.append(path)
            for agent_key, session, workspace, at_ms in rows:
                self.add_agent(harness_of(agent_key), session, None, "", (at_ms or 0) / 1000,
                               os.path.basename(path), workspace)

    def read_hook_stores(self):
        for harness in AGENTS:
            path = os.path.join(self.opts.hook_dir, f"{harness}-hook-sessions.json")
            data = read_json(path)
            if not isinstance(data, dict):
                continue
            self.files.append(path)
            for record in (data.get("sessions") or {}).values():
                if not isinstance(record, dict) or record.get("isRestorable") is False:
                    continue
                updated = record.get("updatedAt")
                when = updated + 978307200 if isinstance(updated, (int, float)) and updated < 1e9 else (updated or 0)
                self.add_agent(harness, record.get("sessionId"), record.get("cwd"), "",
                               when if isinstance(when, (int, float)) else 0, os.path.basename(path),
                               record.get("workspaceId"))

    def resolve_agent_folders(self):
        """A past chat the journal names without a folder: read it from the agent's own transcript."""
        for agent in self.agents.values():
            if agent.cwd:
                continue
            if agent.harness == "claude":
                paths = glob.glob(os.path.join(self.opts.claude_dir, "projects", "*", f"{agent.session}.jsonl"))
            else:
                paths = glob.glob(os.path.join(self.opts.codex_dir, "sessions", "**", f"rollout-*{agent.session}.jsonl"),
                                  recursive=True)
            for path in paths[:1]:
                agent.cwd = transcript_cwd(path)
                agent.last_seen = max(agent.last_seen, os.path.getmtime(path))

    def build(self):
        for path in self.snapshots():
            self.read_snapshot(path)
        self.read_journal()
        self.read_hook_stores()
        self.resolve_agent_folders()
        cutoff = time.time() - self.opts.days * 86400 if self.opts.days else 0
        workspaces = sorted((w for w in self.workspaces.values() if w.last_seen >= cutoff or not w.last_seen),
                            key=lambda w: -w.last_seen)
        agents = sorted((a for a in self.agents.values() if a.last_seen >= cutoff or not a.last_seen),
                        key=lambda a: -a.last_seen)
        for i, agent in enumerate(agents, 1):
            agent.id = f"a{i}"
        by_key = {f"{a.harness}:{a.session}": a.id for a in agents}
        for i, ws in enumerate(workspaces, 1):
            ws.id = f"w{i}"
            ws.agents = [by_key[k] for k in ws.agents if k in by_key]
        return workspaces, agents


def layout_of(node, terminals: list[Terminal]) -> tuple[list[Terminal], dict | None]:
    """Classic's split tree as cmux-next's: terminals in pane order, and the tree
    with each pane's terminals as indices into them (None for a single pane).

    Classic: {"type": "pane", "pane": {"panelIds": [...]}} or {"type": "split",
    "split": {"orientation": "horizontal"|"vertical", "dividerPosition", "first",
    "second"}}. cmux-next: {"terminals": [i, ...]} or {"split": "right"|"down",
    "ratio", "first", "second"}. A pane left with no terminal (its chats open
    as their own workspaces, browsers do not come over) folds into its sibling;
    a terminal the tree misses joins the first pane.
    """
    # A damaged file can repeat an id or hold a non-string one: the first
    # terminal with an id is the one the tree places; the rest join the first pane.
    by_panel: dict[str, Terminal] = {}
    for t in terminals:
        if isinstance(t.panel, str):
            by_panel.setdefault(t.panel, t)
    ordered: list[Terminal] = []

    def walk(node):
        if not isinstance(node, dict):
            return None
        if node.get("type") == "pane":
            pane = node.get("pane")
            ids = pane.get("panelIds") if isinstance(pane, dict) else None
            panes = [by_panel.pop(p) for p in ids if isinstance(p, str) and p in by_panel] if isinstance(ids, list) else []
            ordered.extend(panes)
            return {"terminals": [len(ordered) - len(panes) + i for i in range(len(panes))]} if panes else None
        split = node.get("split")
        if not isinstance(split, dict):
            return None
        first, second = walk(split.get("first")), walk(split.get("second"))
        if not (first and second):
            return first or second
        ratio = split.get("dividerPosition")
        return {"split": "down" if split.get("orientation") == "vertical" else "right",
                "ratio": ratio if isinstance(ratio, (int, float)) and 0 < ratio < 1 else 0.5,
                "first": first, "second": second}

    tree = walk(node)
    placed = {id(t) for t in ordered}
    missed = [t for t in terminals if id(t) not in placed]
    if not tree or "terminals" in tree:
        return ordered + missed, None
    first = tree
    while "terminals" not in first:
        first = first["first"]
    first["terminals"] += range(len(ordered), len(ordered) + len(missed))
    return ordered + missed, tree


def transcript_cwd(path: str) -> str | None:
    try:
        with open(path, "rb") as f:
            for _, line in zip(range(50), f):
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                cwd = record.get("cwd") or (record.get("payload") or {}).get("cwd")
                if isinstance(cwd, str) and cwd:
                    return cwd
    except OSError:
        pass
    return None


# -- cmux-next side ----------------------------------------------------------
def resume_command(agent: Agent) -> str:
    """The harness's own resume line, for an agent run in a plain terminal."""
    return f"codex resume {shlex.quote(agent.session)}" if agent.harness == "codex" \
        else f"claude --resume {shlex.quote(agent.session)}"


def socket_call(path: str, method: str, params: dict | None = None, timeout: float = 120) -> dict:
    """One v2 request on a cmux control socket: {"ok": true, "result": ...} or {"error": ...}."""
    import socket as sockets
    try:
        with sockets.socket(sockets.AF_UNIX, sockets.SOCK_STREAM) as s:
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
        return {"error": line or "no reply"}  # classic's plain "ERROR: Access denied ..." line
    return {"result": reply.get("result")} if reply.get("ok") else {"error": reply.get("error")}


class Next:
    """A running cmux-next, through its control socket (same user; its default socket mode)."""

    def __init__(self, socket: str):
        self.socket = socket

    def call(self, method: str, params: dict) -> dict:
        return socket_call(self.socket, method, params)

    @staticmethod
    def agent_params(agent: Agent) -> dict:
        name = agent.title or (os.path.basename(agent.cwd.rstrip("/")) if agent.cwd else None)
        return {"agent": {"cwd": agent.cwd, "name": name or None, "harness": agent.harness, "session": agent.session}}

    @staticmethod
    def workspace_params(ws: Workspace) -> dict:
        terminals = ws.terminals or [Terminal(ws.title, ws.cwd, None)]
        workspace = {"name": ws.title or None, "cwd": ws.cwd,
                     "terminals": [{"title": t.title or None, "cwd": t.cwd or ws.cwd,
                                    "command": t.command or (f"exec ssh {ws.ssh}" if ws.ssh else None)}
                                   for t in terminals]}
        if ws.layout and ws.terminals:
            workspace["layout"] = ws.layout
        return {"workspace": workspace}


def fallback_commands(row, socket: str) -> list[str]:
    """Commands that work with any cmux-next build's CLI (`app call` is debug-only):
    a workspace per terminal, and an agent chat resumed in a terminal."""
    def new_workspace(name, cwd, command):
        argv = ["cmux", "--app-socket", socket, "action", "run", "newTab", f"--cwd={cwd or '~'}"]
        argv += [f"--name={name}"] if name else []
        argv += [f"--command={command}"] if command else []
        return shlex.join(argv)
    if isinstance(row, Agent):
        return [new_workspace(row.title, row.cwd, resume_command(row))]
    terminals = row.terminals or [Terminal(row.title, row.cwd, None)]
    return [new_workspace(row.title or t.title, t.cwd or row.cwd, t.command or (f"exec ssh {row.ssh}" if row.ssh else None))
            for t in terminals]


def find_next_socket() -> str | None:
    """The first socket whose system.identify answers like cmux-next (it reports a pid; classic does not)."""
    for path in sorted(glob.glob("/tmp/cmux-*.sock")) + [os.path.join(HOME, ".local/state/cmux/cmux.sock")]:
        if os.path.exists(path):
            result = socket_call(path, "system.identify", timeout=3).get("result") or {}
            if isinstance(result, dict) and "pid" in result and "bundle_identifier" not in result:
                return path
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--classic-dir", default=os.path.join(HOME, "Library/Application Support/cmux"))
    parser.add_argument("--hook-dir", default=os.environ.get("CMUX_AGENT_HOOK_STATE_DIR") or os.path.join(HOME, ".cmuxterm"))
    parser.add_argument("--claude-dir", default=os.path.join(HOME, ".claude"))
    parser.add_argument("--codex-dir", default=os.environ.get("CODEX_HOME") or os.path.join(HOME, ".codex"))
    parser.add_argument("--bundle", action="append", help="classic bundle id (repeatable; default: release, nightly, rc, staging)")
    parser.add_argument("--days", type=float, default=30, help="only rows seen in the last N days (0: all; default 30)")
    parser.add_argument("--json", action="store_true", help="print the inventory as JSON")
    parser.add_argument("--commands", action="store_true", help="print the cmux-next commands for the selection; run nothing")
    parser.add_argument("--apply", action="store_true", help="reopen the selection in the running cmux-next")
    parser.add_argument("--select", default="", help="comma-separated row ids (w1,a2); 'all' for every row")
    parser.add_argument("--socket", help="cmux-next control socket (default: the first one that answers as cmux-next)")
    opts = parser.parse_args()

    workspaces, agents = Inventory(opts).build()
    rows = {r.id: r for r in [*workspaces, *agents]}

    if not (opts.commands or opts.apply):
        if opts.json:
            print(json.dumps({"workspaces": [asdict(w) for w in workspaces], "agents": [asdict(a) for a in agents]}, indent=2))
            return 0
        def age(t):
            return time.strftime("%Y-%m-%d %H:%M", time.localtime(t)) if t else "unknown"
        print(f"{len(workspaces)} workspace(s), {len(agents)} agent chat(s) from classic cmux (read only)\n")
        for a in agents:
            print(f"{a.id:>4}  {a.harness:<6} {a.session}  {age(a.last_seen)}  {a.cwd or '(folder unknown)'}  {a.title}")
        if agents:
            print()
        for w in workspaces:
            extra = f"  agents {','.join(w.agents)}" if w.agents else ""
            print(f"{w.id:>4}  {w.title or '(untitled)'}  {age(w.last_seen)}  {w.cwd or ''}  "
                  f"{len(w.terminals)} terminal(s){'  ssh ' + w.ssh if w.ssh else ''}{extra}")
            for t in w.terminals:
                print(f"        - {t.title or 'terminal'}  {t.cwd or ''}  {t.command or ''}")
        return 0

    ids = list(rows) if opts.select == "all" else [s.strip() for s in opts.select.split(",") if s.strip()]
    unknown = [i for i in ids if i not in rows]
    if not ids or unknown:
        print(f"select rows with --select (unknown: {unknown})" if unknown else "nothing selected: pass --select w1,a2 or --select all",
              file=sys.stderr)
        return 2
    # A workspace brings its agent chats; a workspace that held only agent
    # chats is those chats. Each row opens once.
    expanded = []
    for row_id in ids:
        row = rows[row_id]
        if isinstance(row, Workspace):
            if row.terminals or not row.agents:
                expanded.append(row_id)
            expanded += row.agents
        else:
            expanded.append(row_id)
    ids = list(dict.fromkeys(expanded))
    socket = opts.socket or find_next_socket()
    if opts.apply and not socket:
        print("no running cmux-next found: start it, or pass --socket", file=sys.stderr)
        return 2
    next_app = Next(socket or "<cmux-next socket>")
    if opts.apply:
        print(f"cmux-next socket: {socket}", flush=True)
    failures = 0
    for row_id in ids:
        row = rows[row_id]
        params = Next.agent_params(row) if isinstance(row, Agent) else Next.workspace_params(row)
        if not opts.apply:
            print(f"# {row_id}: " + (f"{row.harness} {row.session}" if isinstance(row, Agent) else (row.title or row.cwd or "")))
            print(f"#   --apply sends {json.dumps({'method': 'session.transfer.open', 'params': params})}")
            for line in fallback_commands(row, next_app.socket):
                print(line)
            continue
        result = next_app.call("session.transfer.open", params)
        ok = "error" not in result
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {row_id}: {json.dumps(result)[:300]}", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
