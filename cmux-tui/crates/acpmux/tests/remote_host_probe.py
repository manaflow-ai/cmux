#!/usr/bin/env python3
"""Probe host capabilities before handing the ACP stream to fake_claude."""
import json, os, socket, sys
from pathlib import Path


def write(path: Path) -> bool:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("remote-host")
        return True
    except OSError:
        return False


def main() -> None:
    cwd = Path.cwd()
    home = Path(os.environ.get("HOME", "."))
    result = {
        "git": write(cwd / ".git" / "hooks" / "remote-probe"),
        "home": write(home / ".acpmux-remote-probe"),
        "socket": False,
    }
    path = os.environ.get("ACPMUX_REMOTE_PROBE_SOCKET")
    if path:
        try:
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(2)
                client.connect(path)
                client.sendall(b"remote-probe")
                result["socket"] = True
        except OSError:
            pass
    tcp_port = os.environ.get("ACPMUX_REMOTE_PROBE_TCP")
    result["network"] = False
    if tcp_port:
        try:
            with socket.create_connection(("127.0.0.1", int(tcp_port)), timeout=2) as client:
                client.sendall(b"remote-probe")
                result["network"] = True
        except OSError:
            pass
    output = os.environ.get("ACPMUX_REMOTE_PROBE_OUTPUT")
    if output:
        Path(output).write_text(json.dumps(result))
    fake = sys.argv[1]
    os.execv(sys.executable, [sys.executable, fake, *sys.argv[2:]])


if __name__ == "__main__":
    main()
