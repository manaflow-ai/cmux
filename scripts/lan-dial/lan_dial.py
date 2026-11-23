#!/usr/bin/env python3
"""lan-dial: reach a local-network machine from a background job on macOS, whatever started the job.

    lan_dial.py up                         load (or refresh) this user's relay; prints its socket
    lan_dial.py down                       unload it and remove its files
    lan_dial.py status                     JSON: loaded or not, the socket, the domain
    lan_dial.py connect HOST PORT          bridge stdin/stdout to HOST:PORT (an ssh ProxyCommand)
    lan_dial.py probe HOST PORT [--send TEXT] [--read N]
                                           one exchange; JSON receipt with the first bytes back
    lan_dial.py http URL                   GET an http:// URL; the body on stdout

    --via auto|direct|relay   (or LAN_DIAL_VIA) how to dial. auto, the default: a direct connect first, and on
                              macOS the relay when Local Network privacy refuses it (EHOSTUNREACH, ENETUNREACH,
                              EPERM, EACCES or a connect timeout). After one refusal this process goes straight
                              to the relay.

From Python: `sys.path.insert(0, "scripts/lan-dial"); import lan_dial; sock = lan_dial.dial(host, port)`.

Why: macOS Local Network privacy keeps every launchd-, runner- or worker-started third-party program off the LAN
(EHOSTUNREACH on 192.168.x, 172.16-31.x, 10.x and .local), and the grant cannot be given ahead of time on these Macs.
Apple's /usr/bin/python3 no longer gets through on macOS 27 (27.0.1, measured 2026-11-23), and under a CI runner
not even Apple's nc and ssh do: the runner is the responsible program for its whole process tree. A launchd job
rooted on Apple's /bin/sh that starts /usr/bin/nc does get through, and it is launchd's child, not the caller's.

The protocol (README.md beside this file): the relay is one launchd job per user, socket-activated on an
owner-only (0600) Unix socket. A caller connects, sends `CONNECT HOST PORT\\n`, reads one line (`OK` or
`ERR <why>`), and after `OK` the socket is the TCP stream. `up` loads the job on demand, so a CI step needs nothing
installed beforehand: the first dial that is refused loads it. Python 3.9 or later, stdlib only; any Python.
"""

from __future__ import annotations

import argparse
import contextlib
import errno
import fcntl
import json
import os
import platform
import plistlib
import select
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
RELAY_SCRIPT = HERE / "relay.sh"
LABEL = "com.cmux.lan-dial"
PROTOCOL = "CONNECT"
# Errors macOS Local Network privacy answers a connect with (EHOSTUNREACH is the usual one).
REFUSED = {errno.EHOSTUNREACH, errno.ENETUNREACH, errno.EPERM, errno.EACCES}
DIRECT_TIMEOUT = float(os.environ.get("LAN_DIAL_DIRECT_TIMEOUT") or 3)
_relay_preferred = False


class DialError(OSError):
    pass


def is_macos() -> bool:
    return platform.system() == "Darwin"


def home() -> Path:
    """The relay's folder: its script copy, plist, socket and log."""
    override = os.environ.get("LAN_DIAL_HOME")
    if override:
        return Path(override)
    return Path.home() / ".local/state/cmux/lan-dial"


def socket_path() -> Path:
    return Path(os.environ.get("LAN_DIAL_SOCKET") or home() / "relay.sock")


def domains() -> list[str]:
    """launchd domains to try, in order: root's system domain, else the user's GUI session, else its user domain."""
    uid = os.getuid()
    return ["system"] if uid == 0 else [f"gui/{uid}", f"user/{uid}"]


def launchctl(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["/bin/launchctl", *args], capture_output=True, text=True, timeout=30)


def plist_bytes(state: Path, sock: Path) -> bytes:
    return plistlib.dumps({
        "Label": LABEL,
        "ProgramArguments": ["/bin/sh", str(state / "relay.sh")],
        "inetdCompatibility": {"Wait": False},
        "Sockets": {"Listeners": {"SockPathName": str(sock), "SockPathMode": 0o600, "SockType": "stream"}},
        "StandardErrorPath": str(state / "relay.log"),
    })


def relay_answers(sock: Path, timeout: float = 3) -> bool:
    """True when the socket accepts a connection (launchd holds it while the job is loaded)."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(timeout)
        s.connect(str(sock))
        return True
    except OSError:
        return False
    finally:
        s.close()


def status() -> dict:
    state, sock = home(), socket_path()
    loaded = None
    if is_macos():
        for domain in domains():
            if launchctl("print", f"{domain}/{LABEL}").returncode == 0:
                loaded = domain
                break
    installed = state / "relay.sh"
    current = installed.is_file() and installed.read_bytes() == RELAY_SCRIPT.read_bytes()
    return {"label": LABEL, "loaded_in": loaded, "socket": str(sock), "answers": relay_answers(sock),
            "relay_current": current, "home": str(state)}


def up() -> dict:
    """Load the relay for this user, or refresh it when its script or plist changed. Safe to call at once from
    many jobs: one holds the lock, the rest find it loaded."""
    if not is_macos():
        raise DialError(errno.ENOTSUP, "the relay is a macOS launchd job; off macOS dial directly")
    state, sock = home(), socket_path()
    state.mkdir(parents=True, exist_ok=True)
    os.chmod(state, 0o700)
    want_script = RELAY_SCRIPT.read_bytes()
    want_plist = plist_bytes(state, sock)
    with open(state / "up.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        script, plist = state / "relay.sh", state / f"{LABEL}.plist"
        same = (script.is_file() and script.read_bytes() == want_script
                and plist.is_file() and plist.read_bytes() == want_plist)
        if same and relay_answers(sock):
            return status()
        for domain in domains():
            launchctl("bootout", f"{domain}/{LABEL}")
        script.write_bytes(want_script)
        os.chmod(script, 0o700)
        plist.write_bytes(want_plist)
        with contextlib.suppress(FileNotFoundError):
            sock.unlink()
        said = []
        for domain in domains():
            p = launchctl("bootstrap", domain, str(plist))
            if p.returncode == 0:
                break
            said.append(f"{domain}: {(p.stderr or p.stdout).strip()}")
        else:
            raise DialError(errno.EIO, "launchctl bootstrap refused: " + "; ".join(said))
        deadline = time.monotonic() + 5
        while not relay_answers(sock, timeout=1):
            if time.monotonic() > deadline:
                raise DialError(errno.EIO, f"relay loaded but {sock} does not answer")
            time.sleep(0.05)
    return status()


def down() -> dict:
    state = home()
    if is_macos():
        for domain in domains():
            launchctl("bootout", f"{domain}/{LABEL}")
    for name in ("relay.sh", f"{LABEL}.plist", "relay.sock", "up.lock"):
        with contextlib.suppress(FileNotFoundError):
            (state / name).unlink()
    return status()


def via_relay(host: str, port: int, timeout: Optional[float] = 30, sock: Optional[Path] = None) -> socket.socket:
    """A socket that is the TCP stream to HOST:PORT, made by the relay."""
    path = sock or socket_path()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(timeout)
        s.connect(str(path))
        s.sendall(f"{PROTOCOL} {host} {port}\n".encode())
        line = b""
        while not line.endswith(b"\n"):  # one byte at a time: what follows the line is the stream's
            byte = s.recv(1)
            if not byte:
                raise DialError(errno.ECONNRESET, "the relay closed before answering")
            line += byte
            if len(line) > 4096:
                raise DialError(errno.EPROTO, "the relay's answer has no newline")
        answer = line.decode(errors="replace").strip()
        if answer != "OK":
            raise DialError(errno.ECONNREFUSED, f"relay: {answer}")
        s.settimeout(None)
        return s
    except BaseException:
        s.close()
        raise


def direct(host: str, port: int, timeout: float) -> socket.socket:
    s = socket.create_connection((host, port), timeout=timeout)
    s.settimeout(None)
    return s


def refused_by_privacy(error: OSError) -> bool:
    return isinstance(error, (socket.timeout, TimeoutError)) or error.errno in REFUSED


def dial(host: str, port: int, via: Optional[str] = None, timeout: float = DIRECT_TIMEOUT) -> socket.socket:
    """A connected stream socket to HOST:PORT. See the module docstring for --via."""
    global _relay_preferred
    via = via or os.environ.get("LAN_DIAL_VIA") or "auto"
    if via not in ("auto", "direct", "relay"):
        raise ValueError(f"via takes auto, direct or relay, not {via}")
    if via == "direct" or (via == "auto" and not is_macos()):
        return direct(host, port, timeout)
    if via == "auto" and not _relay_preferred:
        try:
            return direct(host, port, timeout)
        except OSError as error:
            if not refused_by_privacy(error):
                raise
            _relay_preferred = True
    path = socket_path()
    if not relay_answers(path, timeout=1) or not status_current():
        up()
    return via_relay(host, port, sock=path)


def status_current() -> bool:
    installed = home() / "relay.sh"
    return installed.is_file() and installed.read_bytes() == RELAY_SCRIPT.read_bytes()


def bridge(sock: socket.socket, rfd: int, wfd: int) -> None:
    """Copy rfd to the socket and the socket to wfd until the far end closes."""
    open_in = True
    while True:
        ready, _, _ = select.select([sock, rfd] if open_in else [sock], [], [])
        if sock in ready:
            data = sock.recv(65536)
            if not data:
                return
            os.write(wfd, data)
        if open_in and rfd in ready:
            data = os.read(rfd, 65536)
            if data:
                sock.sendall(data)
            else:
                open_in = False
                with contextlib.suppress(OSError):
                    sock.shutdown(socket.SHUT_WR)


def read_all(sock: socket.socket, limit: int, timeout: float) -> bytes:
    sock.settimeout(timeout)
    data = b""
    with contextlib.suppress(socket.timeout, TimeoutError):
        while len(data) < limit:
            chunk = sock.recv(min(65536, limit - len(data)))
            if not chunk:
                break
            data += chunk
    return data


def probe(host: str, port: int, via: Optional[str], send: str = "", limit: int = 256, timeout: float = 10) -> dict:
    receipt = {"host": host, "port": port, "via": via or os.environ.get("LAN_DIAL_VIA") or "auto",
               "python": sys.executable, "pid": os.getpid(), "ppid": os.getppid()}
    start = time.monotonic()
    try:
        s = dial(host, port, via=via)
    except OSError as error:
        receipt.update(ok=False, errno=error.errno, error=str(error), ms=round((time.monotonic() - start) * 1000, 1))
        return receipt
    receipt["route"] = "unix" if s.family == socket.AF_UNIX else "direct"
    with s:
        if send:
            s.sendall(send.encode().decode("unicode_escape").encode("latin-1"))
        data = read_all(s, limit, timeout)
    receipt.update(ok=bool(data), bytes=len(data), first=data[:limit].decode(errors="replace"),
                   ms=round((time.monotonic() - start) * 1000, 1))
    if not data:
        receipt["error"] = "connected, then closed with nothing (refused or down past the relay)"
    return receipt


def http_get(url: str, via: Optional[str], timeout: float = 30) -> bytes:
    parts = urlsplit(url)
    if parts.scheme != "http" or not parts.hostname:
        raise ValueError("http takes an http:// URL")
    port = parts.port or 80
    path = (parts.path or "/") + (f"?{parts.query}" if parts.query else "")
    with dial(parts.hostname, port, via=via) as s:
        s.sendall(f"GET {path} HTTP/1.0\r\nHost: {parts.netloc}\r\nConnection: close\r\n\r\n".encode())
        data = read_all(s, 64 << 20, timeout)
    head, _, body = data.partition(b"\r\n\r\n")
    status_line = head.split(b"\r\n", 1)[0].decode(errors="replace")
    if not status_line.startswith("HTTP/") or " 200 " not in f"{status_line} ":
        raise DialError(errno.EPROTO, f"GET {url}: {status_line or 'no answer'}")
    return body


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="lan_dial.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--via", choices=("auto", "direct", "relay"))
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("up")
    sub.add_parser("down")
    sub.add_parser("status")
    c = sub.add_parser("connect")
    c.add_argument("host")
    c.add_argument("port", type=int)
    p = sub.add_parser("probe")
    p.add_argument("host")
    p.add_argument("port", type=int)
    p.add_argument("--send", default="")
    p.add_argument("--read", type=int, default=256)
    h = sub.add_parser("http")
    h.add_argument("url")
    args = parser.parse_args(argv)
    try:
        if args.cmd in ("up", "down", "status"):
            print(json.dumps({"up": up, "down": down, "status": status}[args.cmd]()))
            return 0
        if args.cmd == "connect":
            with dial(args.host, args.port, via=args.via) as s:
                bridge(s, sys.stdin.fileno(), sys.stdout.fileno())
            return 0
        if args.cmd == "probe":
            receipt = probe(args.host, args.port, args.via, args.send, args.read)
            print(json.dumps(receipt))
            return 0 if receipt["ok"] else 1
        sys.stdout.buffer.write(http_get(args.url, args.via))
        return 0
    except (OSError, ValueError) as error:
        print(f"lan_dial: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
