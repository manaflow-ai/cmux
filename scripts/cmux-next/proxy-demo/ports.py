#!/usr/bin/env python3
"""Find the TCP ports a terminal's programs listen on, through tmux.

A tmux server daemonizes, so a server started in a tmux pane is NOT a
descendant of the cmux terminal's shell. The chain is:

  cmux terminal tty -> tmux client on that tty -> its session -> the
  session's pane pids -> their descendants -> LISTEN sockets.

Without tmux the chain is shorter: the terminal's root pid -> descendants.
This is the prototype of the daemon verb `terminal ports` (design doc section
6); the parsing functions are pure so tests feed them fixtures.

Usage:
  ports.py --tmux-session NAME        ports of every pane in that session
  ports.py --tty /dev/ttys012         ports of the tmux session attached there,
                                      else of the processes on that tty
  ports.py --pid 1234                 ports of pid 1234 and its descendants
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path

# Run with `python3 -I`, which leaves the script's folder off sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import macsockets  # noqa: E402


@dataclass(frozen=True, order=True)
class Listener:
    port: int
    host: str
    pid: int
    command: str


def parse_ps(text: str) -> dict[int, list[int]]:
    """`ps -axo pid=,ppid=` -> children by parent."""
    children: dict[int, list[int]] = defaultdict(list)
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        children[ppid].append(pid)
    return children


def descendants(roots: list[int], children: dict[int, list[int]]) -> set[int]:
    seen: set[int] = set()
    stack = list(roots)
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        stack.extend(children.get(pid, ()))
    return seen


def parse_lsof(text: str, pids: set[int] | None = None) -> list[Listener]:
    """Parse `lsof -nP -iTCP -sTCP:LISTEN -F pcn`.

    Field lines: p<pid>, c<command>, f<fd>, n<addr:port>. Wildcard hosts
    (`*`) become `0.0.0.0`; IPv6 hosts keep their brackets stripped.
    """
    out: set[Listener] = set()
    pid = -1
    command = ""
    for line in text.splitlines():
        if not line:
            continue
        tag, value = line[0], line[1:]
        if tag == "p":
            pid = int(value)
            command = ""
        elif tag == "c":
            command = value
        elif tag == "n":
            if pids is not None and pid not in pids:
                continue
            host, _, port = value.rpartition(":")
            if not port.isdigit():
                continue
            host = host.strip("[]")
            if host == "*":
                host = "0.0.0.0"
            out.add(Listener(int(port), host, pid, command))
    return sorted(out)


def parse_tmux_clients(text: str) -> dict[str, str]:
    """`tmux list-clients -F '#{client_tty} #{session_name}'` -> session by tty."""
    out: dict[str, str] = {}
    for line in text.splitlines():
        tty, _, session = line.partition(" ")
        if tty and session:
            out[tty] = session
    return out


def parse_ints(text: str) -> list[int]:
    return [int(x) for x in text.split() if x.strip().isdigit()]


def _run(argv: list[str]) -> str:
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def tmux_pane_pids(session: str) -> list[int]:
    return parse_ints(_run(["tmux", "list-panes", "-s", "-t", f"={session}", "-F", "#{pane_pid}"]))


def tty_pids(tty: str) -> list[int]:
    short = tty.removeprefix("/dev/")
    return parse_ints(_run(["ps", "-t", short, "-o", "pid="]))


def roots_for(args: argparse.Namespace) -> tuple[list[int], str]:
    if args.tmux_session:
        return tmux_pane_pids(args.tmux_session), f"tmux session {args.tmux_session}"
    if args.tty:
        session = parse_tmux_clients(
            _run(["tmux", "list-clients", "-F", "#{client_tty} #{session_name}"])
        ).get(args.tty)
        if session:
            return tmux_pane_pids(session), f"tmux session {session} on {args.tty}"
        return tty_pids(args.tty), f"processes on {args.tty}"
    return [args.pid], f"pid {args.pid}"


def find(args: argparse.Namespace) -> dict[str, object]:
    roots, source = roots_for(args)
    pids = descendants(roots, parse_ps(_run(["ps", "-axo", "pid=,ppid="])))
    return {"source": source, "pids": sorted(pids), "listeners": [asdict(l) for l in listening(pids)]}


def listening(pids: set[int]) -> list[Listener]:
    """LISTEN sockets owned by `pids`.

    macOS: libproc on just these pids (macsockets.py). lsof takes about 5 s
    on a Mac with 3,000 processes, even with `-p`, too slow to poll; and
    netstat -anv prints an empty socket list when Python runs it (measured
    2026-10-21). Linux: `ss -ltnp`. lsof stays the last fallback.
    """
    if not pids:
        return []
    if macsockets.available():
        found: set[Listener] = set()
        for pid in pids:
            sockets = macsockets.tcp_sockets(pid)
            name = macsockets.process_name(pid) if sockets else ""
            for sock in sockets:
                if sock.listening:
                    host = "0.0.0.0" if sock.local_host in ("0.0.0.0", "::") else sock.local_host
                    found.add(Listener(sock.local_port, host, pid, name))
        return sorted(found)
    if sys.platform == "darwin":
        text = _run(["netstat", "-anv", "-p", "tcp"])
        if text:
            return parse_netstat_darwin(text, pids)
    elif sys.platform.startswith("linux"):
        text = _run(["ss", "-H", "-ltnp"])
        if text:
            return parse_ss(text, pids)
    return parse_lsof(_run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]), pids)


_NETSTAT_LISTEN = re.compile(
    r"^tcp(?:4|6|46)\s+\d+\s+\d+\s+(?P<local>\S+)\s+\S+\s+LISTEN\s+\d+\s+\d+\s+\d+\s+\d+\s+(?P<proc>.+?):(?P<pid>\d+)\s+[0-9a-f]{5}\s"
)


def parse_netstat_darwin(text: str, pids: set[int] | None = None) -> list[Listener]:
    out: set[Listener] = set()
    for line in text.splitlines():
        m = _NETSTAT_LISTEN.match(line)
        if not m:
            continue
        pid = int(m["pid"])
        if pids is not None and pid not in pids:
            continue
        host, _, port = m["local"].rpartition(".")
        if not port.isdigit():
            continue
        out.add(Listener(int(port), "0.0.0.0" if host == "*" else host, pid, m["proc"]))
    return sorted(out)


_SS_PID = re.compile(r'\("(?P<proc>[^"]*)",pid=(?P<pid>\d+)')


def parse_ss(text: str, pids: set[int] | None = None) -> list[Listener]:
    """`ss -H -ltnp`: State Recv-Q Send-Q Local Peer Process."""
    out: set[Listener] = set()
    for line in text.splitlines():
        parts = line.split(None, 5)
        if len(parts) < 6:
            continue
        host, _, port = parts[3].rpartition(":")
        if not port.isdigit():
            continue
        host = host.strip("[]")
        host = "0.0.0.0" if host in ("*", "") else host
        for m in _SS_PID.finditer(parts[5]):
            pid = int(m["pid"])
            if pids is None or pid in pids:
                out.add(Listener(int(port), host, pid, m["proc"]))
    return sorted(out)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--tmux-session")
    group.add_argument("--tty")
    group.add_argument("--pid", type=int)
    parser.add_argument("--json", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    result = find(args)
    if args.json:
        print(json.dumps(result))
    else:
        for l in result["listeners"]:
            print(f"{l['port']}\t{l['host']}\t{l['pid']}\t{l['command']}")
    return 0 if result["listeners"] else 1


if __name__ == "__main__":
    sys.exit(main())
