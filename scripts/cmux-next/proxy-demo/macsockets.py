"""TCP sockets of macOS processes through libproc (no netstat, no lsof).

Why: on macOS 27 `netstat -anv` prints nothing when its responsible process
is Python (an empty PCB list, measured 2026-10-21: 1,163 lines from zsh, 0
from python3), and lsof takes about 5 s even with `-p`. libproc reads one
process's sockets directly: proc_pidinfo(PROC_PIDLISTFDS), then
proc_pidfdinfo(PROC_PIDFDSOCKETINFO) per socket fd.

Offsets are those of `struct socket_fdinfo` in <sys/proc_info.h> (64-bit):
checked live against a Python listener (port, address, SO_ACCEPTCONN).
"""

from __future__ import annotations

import ctypes
import ipaddress
import struct
import sys
from dataclasses import dataclass

PROC_PIDLISTFDS = 1
PROC_PIDFDSOCKETINFO = 3
PROC_ALL_PIDS = 1
PROX_FDTYPE_SOCKET = 2
SOCKINFO_TCP = 2
AF_INET, AF_INET6 = 2, 30
SO_ACCEPTCONN = 0x2

# Offsets in struct socket_fdinfo: pfi (24) + socket_info.
OFF_FAMILY = 184
OFF_OPTIONS = 188
OFF_KIND = 256
OFF_FPORT = 264
OFF_LPORT = 268
OFF_FADDR = 296
OFF_LADDR = 312
SOCKET_FDINFO_SIZE = 792


@dataclass(frozen=True)
class TcpSocket:
    pid: int
    fd: int
    listening: bool
    local_host: str
    local_port: int
    remote_host: str
    remote_port: int


def _port(raw: bytes, offset: int) -> int:
    (value,) = struct.unpack_from("<i", raw, offset)
    return ((value & 0xFF) << 8) | ((value >> 8) & 0xFF)


def _addr(raw: bytes, offset: int, family: int) -> str:
    if family == AF_INET:
        return str(ipaddress.IPv4Address(raw[offset + 12 : offset + 16]))
    address = ipaddress.IPv6Address(raw[offset : offset + 16])
    return str(address.ipv4_mapped or address)


def parse_socket_fdinfo(pid: int, fd: int, raw: bytes) -> TcpSocket | None:
    """One socket_fdinfo buffer -> a TCP socket, else None."""
    if len(raw) < OFF_LADDR + 16:
        return None
    (kind,) = struct.unpack_from("<i", raw, OFF_KIND)
    (family,) = struct.unpack_from("<i", raw, OFF_FAMILY)
    if kind != SOCKINFO_TCP or family not in (AF_INET, AF_INET6):
        return None
    (options,) = struct.unpack_from("<h", raw, OFF_OPTIONS)
    return TcpSocket(
        pid=pid,
        fd=fd,
        listening=bool(options & SO_ACCEPTCONN),
        local_host=_addr(raw, OFF_LADDR, family),
        local_port=_port(raw, OFF_LPORT),
        remote_host=_addr(raw, OFF_FADDR, family),
        remote_port=_port(raw, OFF_FPORT),
    )


_lib = None


def _libproc():
    global _lib
    if _lib is None:
        _lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    return _lib


def available() -> bool:
    return sys.platform == "darwin"


def tcp_sockets(pid: int) -> list[TcpSocket]:
    lib = _libproc()
    size = lib.proc_pidinfo(pid, PROC_PIDLISTFDS, 0, None, 0)
    if size <= 0:
        return []
    buf = ctypes.create_string_buffer(size + 64 * 8)
    size = lib.proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf, len(buf))
    out: list[TcpSocket] = []
    info = ctypes.create_string_buffer(SOCKET_FDINFO_SIZE)
    for i in range(0, max(size, 0), 8):
        fd, fdtype = struct.unpack_from("<iI", buf.raw, i)
        if fdtype != PROX_FDTYPE_SOCKET:
            continue
        if lib.proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, info, SOCKET_FDINFO_SIZE) < SOCKET_FDINFO_SIZE:
            continue
        sock = parse_socket_fdinfo(pid, fd, info.raw)
        if sock:
            out.append(sock)
    return out


def all_pids() -> list[int]:
    lib = _libproc()
    count = lib.proc_listpids(PROC_ALL_PIDS, 0, None, 0)
    buf = (ctypes.c_int * (count // 4 + 256))()
    got = lib.proc_listpids(PROC_ALL_PIDS, 0, buf, ctypes.sizeof(buf))
    return [p for p in buf[: got // 4] if p > 0]


def process_name(pid: int) -> str:
    buf = ctypes.create_string_buffer(256)
    n = _libproc().proc_name(pid, buf, len(buf))
    return buf.raw[:n].decode("utf-8", "replace") if n > 0 else ""


def connection_owner(local_port: int, remote_port: int) -> tuple[int, str] | None:
    """(pid, name) of the process whose TCP socket is local_port -> remote_port,
    scanning every process this user can read."""
    for pid in all_pids():
        for sock in tcp_sockets(pid):
            if not sock.listening and sock.local_port == local_port and sock.remote_port == remote_port:
                return pid, process_name(pid)
    return None
