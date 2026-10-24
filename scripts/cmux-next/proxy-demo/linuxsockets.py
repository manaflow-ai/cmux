"""Owner of a TCP connection on Linux through /proc (the Freestyle VM case).

/proc/net/tcp{,6} gives each socket's local and remote address in hex and its
inode; /proc/<pid>/fd/* links read `socket:[inode]`. A process can read the
fds of processes of its own user, which covers the session daemon (same user
as the dev server on a cmux Cloud machine).
"""

from __future__ import annotations

import os
import sys


def available() -> bool:
    return sys.platform.startswith("linux") and os.path.isdir("/proc/net")


def parse_proc_net_tcp(text: str) -> list[tuple[int, int, int, str]]:
    """(local_port, remote_port, inode, state hex) per socket line."""
    out = []
    for line in text.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 10:
            continue
        try:
            local_port = int(parts[1].rsplit(":", 1)[1], 16)
            remote_port = int(parts[2].rsplit(":", 1)[1], 16)
            inode = int(parts[9])
        except (ValueError, IndexError):
            continue
        out.append((local_port, remote_port, inode, parts[3]))
    return out


ESTABLISHED = "01"


def connection_owner(local_port: int, remote_port: int) -> tuple[int, str] | None:
    inodes = set()
    for name in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            text = open(name).read()
        except OSError:
            continue
        for lp, rp, inode, state in parse_proc_net_tcp(text):
            if lp == local_port and rp == remote_port and state == ESTABLISHED and inode:
                inodes.add(inode)
    if not inodes:
        return None
    wanted = {f"socket:[{i}]" for i in inodes}
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            for fd in os.listdir(f"/proc/{pid}/fd"):
                if os.readlink(f"/proc/{pid}/fd/{fd}") in wanted:
                    with open(f"/proc/{pid}/comm") as f:
                        return int(pid), f.read().strip()
        except OSError:
            continue
    return None
