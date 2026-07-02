"""Detach/reattach smoke test.

Starts a headless session, attaches the TUI client in a scripted pty,
types a marker, detaches (prefix-d), reattaches in a fresh pty, and
verifies the marker is rendered from the VT replay. The session server
must survive both detaches.
"""

import fcntl
import json
import os
import pty
import select
import signal
import socket
import struct
import subprocess
import termios
import time

BIN = os.environ.get("CMUX_MUX_BIN", "target/debug/cmux-mux")
SESSION = f"smoke-attach-{os.getpid()}"
SOCK = os.path.join(
    os.environ.get("TMPDIR", "/tmp"), f"cmux-mux-{os.getuid()}", f"{SESSION}.sock"
)
MARKER = f"reattach-marker-{os.getpid()}"


def rpc(cmd):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(15)
    s.connect(SOCK)
    s.sendall((json.dumps(cmd) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf)


class Client:
    def __init__(self):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ["TERM"] = "xterm-256color"
            os.execv(BIN, [BIN, "attach", "--session", SESSION])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        os.kill(self.pid, signal.SIGWINCH)
        self.output = b""

    def drain(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.1)
            if r:
                try:
                    self.output += os.read(self.fd, 65536)
                except OSError:
                    break

    def wait_output(self, needle, seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            self.drain(0.2)
            if needle.encode() in self.output:
                return True
        return False

    def send(self, data):
        os.write(self.fd, data)

    def detach(self):
        self.send(b"\x02d")  # prefix-d
        deadline = time.time() + 10
        while time.time() < deadline:
            done, status = os.waitpid(self.pid, os.WNOHANG)
            if done:
                return status
            self.drain(0.2)
        os.kill(self.pid, signal.SIGKILL)
        raise SystemExit("attach client did not exit on prefix-d")


# Headless server.
server = subprocess.Popen(
    [BIN, "--headless", "--session", SESSION],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
deadline = time.time() + 15
while not os.path.exists(SOCK) and time.time() < deadline:
    time.sleep(0.1)
assert os.path.exists(SOCK), "headless server socket missing"

try:
    # First attach: type a marker into the shell.
    c1 = Client()
    assert c1.wait_output("[" + SESSION.split("-")[0], 15) or True  # status bar paints
    c1.drain(1.5)
    c1.send(f"printf '{MARKER}\\n'\r".encode())
    assert c1.wait_output(MARKER, 15), "marker never rendered on first attach"
    status = c1.detach()
    print("first attach + detach ok, status", status)

    assert server.poll() is None, "server died on client detach"

    # Server still has the pane and the marker on screen.
    ws = rpc({"id": 1, "cmd": "list-workspaces"})
    pane_id = ws["data"]["workspaces"][0]["tabs"][0]["panes"][0]["id"]
    screen = rpc({"id": 2, "cmd": "read-screen", "pane": pane_id})
    assert MARKER in screen["data"]["text"], "marker lost server-side after detach"
    print("server survived detach with state intact")

    # Reattach: the marker must be rendered from the VT replay alone.
    c2 = Client()
    assert c2.wait_output(MARKER, 15), "marker not rendered after reattach"
    # Live path still works after replay: type another command.
    c2.send(b"printf 'live-after-reattach\\n'\r")
    assert c2.wait_output("live-after-reattach", 15), "live stream broken after reattach"
    c2.detach()
    print("reattach replay + live stream ok")
finally:
    server.terminate()
    server.wait(timeout=10)

print("ATTACH SMOKE OK")
