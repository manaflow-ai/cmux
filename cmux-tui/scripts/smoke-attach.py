"""Detach/reattach smoke test.

Starts a headless session, attaches the TUI client in a scripted pty,
types a marker, detaches (prefix-d), reattaches in a fresh pty, and
verifies the marker is rendered from the VT replay. The session server
must survive both detaches.
"""

import fcntl
import base64
import json
import os
import pty
import re
import select
import signal
import socket
import struct
import subprocess
import termios
import time

BIN = os.environ.get("CMUX_TUI_BIN", "target/debug/cmux-tui")
SESSION = f"smoke-attach-{os.getpid()}"
SOCK = None
CONTROL_SOCKET_RE = re.compile(r"control socket at (.+)$")
MARKER = f"reattach-marker-{os.getpid()}"


def fallback_socket_path():
    base = os.environ.get("XDG_RUNTIME_DIR") or os.environ.get("TMPDIR") or "/tmp"
    return os.path.join(base, f"cmux-tui-{os.getuid()}", f"{SESSION}.sock")


def wait_for_control_socket(server, seconds=15):
    deadline = time.time() + seconds
    output = []
    assert server.stdout is not None
    while time.time() < deadline:
        if server.poll() is not None:
            rest = server.stdout.read() or ""
            if rest:
                output.append(rest)
            break
        wait = min(0.1, max(0.0, deadline - time.time()))
        readable, _, _ = select.select([server.stdout], [], [], wait)
        if not readable:
            continue
        line = server.stdout.readline()
        if not line:
            continue
        output.append(line)
        match = CONTROL_SOCKET_RE.search(line.strip())
        if match:
            path = match.group(1)
            socket_deadline = time.time() + 5
            while time.time() < socket_deadline:
                if os.path.exists(path):
                    return path
                if server.poll() is not None:
                    break
                time.sleep(0.05)
            raise AssertionError(f"control socket line found but socket missing at {path}")

    fallback = fallback_socket_path()
    if os.path.exists(fallback):
        print("control socket line not seen; using fallback", fallback)
        return fallback
    raise AssertionError(
        "headless server socket missing; expected startup line or fallback at "
        + fallback
        + "; output:\n"
        + "".join(output)[-2000:]
    )


def render_client_frame(data, rows=30, cols=100):
    chars = [[" " for _ in range(cols)] for _ in range(rows)]
    reverse = [[False for _ in range(cols)] for _ in range(rows)]
    x = y = 0
    rev = False
    i = 0
    while i < len(data):
        b = data[i]
        if b == 0x1B and i + 1 < len(data) and data[i + 1] == ord("["):
            j = i + 2
            while j < len(data) and not (0x40 <= data[j] <= 0x7E):
                j += 1
            if j >= len(data):
                break
            params = data[i + 2 : j].decode("ascii", "ignore")
            final = chr(data[j])
            if final in ("H", "f"):
                parts = [p for p in params.split(";") if p and not p.startswith("?")]
                row = int(parts[0]) if len(parts) >= 1 and parts[0].isdigit() else 1
                col = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 1
                y = max(0, min(rows - 1, row - 1))
                x = max(0, min(cols - 1, col - 1))
            elif final in ("A", "B", "C", "D"):
                amount = int(params) if params.isdigit() else 1
                if final == "A":
                    y = max(0, y - amount)
                elif final == "B":
                    y = min(rows - 1, y + amount)
                elif final == "C":
                    x = min(cols - 1, x + amount)
                else:
                    x = max(0, x - amount)
            elif final == "G":
                col = int(params) if params.isdigit() else 1
                x = max(0, min(cols - 1, col - 1))
            elif final == "J":
                mode = int(params) if params.isdigit() else 0
                if mode in (2, 3):
                    chars = [[" " for _ in range(cols)] for _ in range(rows)]
                    reverse = [[False for _ in range(cols)] for _ in range(rows)]
                elif mode == 0:
                    for yy in range(y, rows):
                        start = x if yy == y else 0
                        for xx in range(start, cols):
                            chars[yy][xx] = " "
                            reverse[yy][xx] = rev
            elif final == "K":
                mode = int(params) if params.isdigit() else 0
                if mode == 2:
                    start, end = 0, cols
                elif mode == 1:
                    start, end = 0, x + 1
                else:
                    start, end = x, cols
                for xx in range(start, end):
                    chars[y][xx] = " "
                    reverse[y][xx] = rev
            elif final == "X":
                amount = int(params) if params.isdigit() else 1
                for xx in range(x, min(cols, x + amount)):
                    chars[y][xx] = " "
                    reverse[y][xx] = rev
            elif final == "P":
                amount = int(params) if params.isdigit() else 1
                amount = min(amount, cols - x)
                for xx in range(x, cols - amount):
                    chars[y][xx] = chars[y][xx + amount]
                    reverse[y][xx] = reverse[y][xx + amount]
                for xx in range(cols - amount, cols):
                    chars[y][xx] = " "
                    reverse[y][xx] = rev
            elif final == "@":
                amount = int(params) if params.isdigit() else 1
                amount = min(amount, cols - x)
                for xx in range(cols - 1, x + amount - 1, -1):
                    chars[y][xx] = chars[y][xx - amount]
                    reverse[y][xx] = reverse[y][xx - amount]
                for xx in range(x, x + amount):
                    chars[y][xx] = " "
                    reverse[y][xx] = rev
            elif final == "m":
                vals = [int(p) for p in params.split(";") if p.isdigit()] or [0]
                for val in vals:
                    if val == 0:
                        rev = False
                    elif val == 7:
                        rev = True
                    elif val == 27:
                        rev = False
            i = j + 1
            continue
        if b == 0x0D:
            x = 0
            i += 1
            continue
        if b == 0x0A:
            y = min(rows - 1, y + 1)
            i += 1
            continue
        if b < 0x20:
            i += 1
            continue
        if b < 0x80:
            ch = chr(b)
            width = 1
        elif b & 0xE0 == 0xC0:
            width = 2
            ch = data[i : i + width].decode("utf-8", "replace")
        elif b & 0xF0 == 0xE0:
            width = 3
            ch = data[i : i + width].decode("utf-8", "replace")
        elif b & 0xF8 == 0xF0:
            width = 4
            ch = data[i : i + width].decode("utf-8", "replace")
        else:
            width = 1
            ch = "�"
        if y < rows and x < cols:
            chars[y][x] = ch
            reverse[y][x] = rev
        i += width
        x = min(cols - 1, x + 1)
    return chars, reverse


def reverse_percent_cells(frame):
    chars, reverse = frame
    rows = len(chars)
    cols = len(chars[0]) if rows else 0
    return [(row, col) for row in range(rows) for col in range(cols) if chars[row][col] == "%" and reverse[row][col]]


def rust_round(value):
    return int(value + 0.5)


def split_sides(rect, direction, ratio):
    x, y, width, height = rect
    if direction == "right":
        a_w = max(1, min(rust_round(width * ratio), max(1, width - 1)))
        return (x, y, a_w, height), (x + a_w, y, width - a_w, height)
    a_h = max(1, min(rust_round(height * ratio), max(1, height - 1)))
    return (x, y, width, a_h), (x, y + a_h, width, height - a_h)


def layout_panes(node, rect):
    if node["type"] == "leaf":
        return {node["pane"]: rect}
    if (node["dir"] == "right" and rect[2] < 2) or (node["dir"] == "down" and rect[3] < 2):
        out = layout_panes(node["a"], rect)
        out.update(layout_panes(node["b"], (rect[0], rect[1], 0, 0)))
        return out
    a_rect, b_rect = split_sides(rect, node["dir"], node["ratio"])
    out = layout_panes(node["a"], a_rect)
    out.update(layout_panes(node["b"], b_rect))
    return out


def content_rect(rect):
    x, y, width, height = rect
    if width >= 3 and height >= 3:
        return (x + 1, y + 1, max(0, width - 3), height - 2)
    return rect


def frame_region_text(frame, rect):
    chars, _ = frame
    x, y, width, height = rect
    lines = []
    for yy in range(y, y + height):
        line = "".join(chars[yy][x : x + width]) if 0 <= yy < len(chars) else ""
        lines.append(line.strip())
    return lines


def server_region_text(surface, width, height):
    screen = rpc({"id": 2000 + surface, "cmd": "read-screen", "surface": surface})
    lines = screen["data"]["text"].splitlines()
    out = []
    for row in range(height):
        line = lines[row] if row < len(lines) else ""
        out.append((line + " " * width)[:width].strip())
    return out


def client_server_mismatch(client):
    ws = rpc({"id": 1999, "cmd": "list-workspaces"})
    active_ws = next(w for w in ws["data"]["workspaces"] if w["active"])
    screen = next(s for s in active_ws["screens"] if s["active"])
    pane_rects = layout_panes(screen["layout"], (22, 0, client.cols - 22, client.rows - 1))
    panes = {pane["id"]: pane for pane in screen["panes"]}
    frame = render_client_frame(client.output, client.rows, client.cols)
    for pane_id, rect in pane_rects.items():
        pane = panes.get(pane_id)
        if not pane or not pane["tabs"]:
            continue
        tab = pane["tabs"][pane["active_tab"]]
        cx, cy, width, height = content_rect(rect)
        if width == 0 or height == 0:
            continue
        client_lines = frame_region_text(frame, (cx, cy, width, height))
        server_lines = server_region_text(tab["surface"], width, height)
        if client_lines != server_lines:
            return frame, {
                "pane": pane_id,
                "surface": tab["surface"],
                "rect": (cx, cy, width, height),
                "client": client_lines,
                "server": server_lines,
            }
    return frame, None


def assert_client_matches_server(client):
    deadline = time.time() + 4.0
    last_mismatch = None
    stable_since = None
    while True:
        frame, mismatch = client_server_mismatch(client)
        if mismatch is None:
            return frame
        key = json.dumps(mismatch, sort_keys=True)
        now = time.time()
        if key != last_mismatch:
            last_mismatch = key
            stable_since = now
        if now >= deadline and stable_since is not None and now - stable_since >= 0.5:
            raise AssertionError(mismatch)
        if now >= deadline + 1.0:
            raise AssertionError(mismatch)
        client.drain(0.2)


def active_surfaces():
    ws = rpc({"id": 2999, "cmd": "list-workspaces"})
    active_ws = next(w for w in ws["data"]["workspaces"] if w["active"])
    screen = next(s for s in active_ws["screens"] if s["active"])
    surfaces = []
    for pane in screen["panes"]:
        if pane["tabs"]:
            surfaces.append(pane["tabs"][pane["active_tab"]]["surface"])
    return surfaces


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
    def __init__(self, rows=30, cols=100):
        self.rows = rows
        self.cols = cols
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ["TERM"] = "xterm-256color"
            os.execv(BIN, [BIN, "attach", "--session", SESSION, "--socket", SOCK])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
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

    def drain_until_quiet(self, quiet=0.5, timeout=8.0):
        deadline = time.time() + timeout
        quiet_deadline = time.time() + quiet
        while time.time() < deadline:
            wait = min(0.1, max(0.0, quiet_deadline - time.time()))
            r, _, _ = select.select([self.fd], [], [], wait)
            if r:
                try:
                    self.output += os.read(self.fd, 65536)
                    quiet_deadline = time.time() + quiet
                except OSError:
                    return
            elif time.time() >= quiet_deadline:
                return
        raise AssertionError("client output did not quiesce")

    def wait_output(self, needle, seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            self.drain(0.2)
            if needle.encode() in self.output:
                return True
        return False

    def send(self, data):
        os.write(self.fd, data)

    def force_redraw(self):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", self.rows, self.cols, 0, 0))
        os.kill(self.pid, signal.SIGWINCH)

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
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    bufsize=1,
)
SOCK = wait_for_control_socket(server)

try:
    # First attach: type a marker into the shell.
    c1 = Client()
    c1.drain(1.5)
    c1.send(f"printf '{MARKER}\\n'\r".encode())
    assert c1.wait_output(MARKER, 15), "marker never rendered on first attach"
    status = c1.detach()
    print("first attach + detach ok, status", status)

    assert server.poll() is None, "server died on client detach"

    # Server still has the surface and the marker on screen.
    ws = rpc({"id": 1, "cmd": "list-workspaces"})
    surface_id = ws["data"]["workspaces"][0]["screens"][0]["panes"][0]["tabs"][0]["surface"]
    screen = rpc({"id": 2, "cmd": "read-screen", "surface": surface_id})
    assert MARKER in screen["data"]["text"], "marker lost server-side after detach"
    print("server survived detach with state intact")

    # Reattach: the marker must be rendered from the VT replay alone.
    c2 = Client()
    assert c2.wait_output(MARKER, 15), "marker not rendered after reattach"
    # Live path still works after replay: type another command.
    c2.send(b"printf '\\033[3J\\033[H\\033[2J'; printf 'live-after-reattach\\n'\r")
    assert c2.wait_output("live-after-reattach", 15), "live stream broken after reattach"
    live_screen = rpc({"id": 3, "cmd": "read-screen", "surface": surface_id})
    assert "live-after-reattach" in live_screen["data"]["text"], live_screen["data"]["text"]

    # Resize churn while an attach mirror is live must not strand zsh's
    # reverse-video partial-line marker in the final client frame.
    storm_start = len(c2.output)
    for i in range(4):
        ws = rpc({"id": 100 + i, "cmd": "list-workspaces"})
        pane = ws["data"]["workspaces"][0]["screens"][0]["panes"][0]["id"]
        direction = "right" if i % 2 == 0 else "down"
        split = rpc({"id": 110 + i, "cmd": "split", "pane": pane, "dir": direction})
        assert split["ok"], split
        time.sleep(0.03)
        c2.drain(0.2)
    c2.drain_until_quiet()
    frame = render_client_frame(c2.output)
    assert not reverse_percent_cells(frame), c2.output[storm_start:][-2000:]

    repaint = base64.b64encode(b"\x0c").decode()
    for surface in active_surfaces():
        assert rpc({"id": 3000 + surface, "cmd": "send", "surface": surface, "bytes": repaint})[
            "ok"
        ]
    c2.drain_until_quiet()

    # Force one more client repaint, then compare the final rendered pane
    # regions against server state and check for stranded prompt markers.
    c2.force_redraw()
    c2.drain_until_quiet()
    frame = assert_client_matches_server(c2)
    assert not reverse_percent_cells(frame), c2.output[storm_start:][-2000:]
    print("attach split storm produced no reverse-video percent artifact")

    c2.detach()
    print("reattach replay + live stream ok")

    c3 = Client(rows=60, cols=231)
    c3.drain_until_quiet()
    storm_start = len(c3.output)
    for _ in range(4):
        c3.send(b"\x1bn")
        time.sleep(0.04)
        c3.drain(0.1)
    c3.send(b"\x02%")
    time.sleep(0.04)
    c3.drain(0.2)
    c3.send(b"\x02t")
    c3.drain_until_quiet()

    repaint = base64.b64encode(b"\x0c").decode()
    for surface in active_surfaces():
        assert rpc({"id": 4000 + surface, "cmd": "send", "surface": surface, "bytes": repaint})[
            "ok"
        ]
    c3.drain_until_quiet()
    c3.force_redraw()
    c3.drain_until_quiet()
    frame = assert_client_matches_server(c3)
    assert not reverse_percent_cells(frame), c3.output[storm_start:][-4000:]
    print("231x60 mixed attach storm produced no reverse-video percent artifact")

    c3.detach()
    print("large attach storm ok")

finally:
    server.terminate()
    server.wait(timeout=10)
    if SOCK and os.path.exists(SOCK):
        os.unlink(SOCK)

print("ATTACH SMOKE OK")
