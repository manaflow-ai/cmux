import os, pty, select, socket, json, time, sys, signal, subprocess

BIN = os.environ.get("CMUX_MUX_BIN", "target/debug/cmux-mux")
SESSION = f"smoke-{os.getpid()}"
SOCK = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"cmux-mux-{os.getuid()}", f"{SESSION}.sock")

def rpc(cmd):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(15)
    s.connect(SOCK)
    s.sendall((json.dumps(cmd) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk: break
        buf += chunk
    s.close()
    return json.loads(buf)

pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(BIN, [BIN, "--session", SESSION])

# Set a real window size
import fcntl, termios, struct
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
os.kill(pid, signal.SIGWINCH)

output = b""
def drain(seconds):
    global output
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                output += os.read(fd, 65536)
            except OSError:
                break

deadline = time.time() + 15
while not os.path.exists(SOCK) and time.time() < deadline:
    drain(0.2)
assert os.path.exists(SOCK), f"socket missing at {SOCK}"
drain(1.0)

ident = rpc({"id": 1, "cmd": "identify"})
assert ident["ok"] and ident["data"]["app"] == "cmux-mux", ident
assert ident["data"]["protocol"] == 3, ident
print("identify ok:", ident["data"])

ws = rpc({"id": 2, "cmd": "list-workspaces"})
panes = ws["data"]["workspaces"][0]["panes"]
assert len(panes) == 1, ws
pane_id = panes[0]["id"]
surface_id = panes[0]["tabs"][0]["surface"]
print("initial tree ok, pane", pane_id, "surface", surface_id)

# Type a command into the shell via the TUI's stdin path (real keystrokes).
os.write(fd, b"printf 'smoke-marker-%s\\n' ok\r")
drain(1.5)
screen = rpc({"id": 3, "cmd": "read-screen", "surface": surface_id})
assert "smoke-marker-ok" in screen["data"]["text"], screen["data"]["text"][-500:]
print("keystroke -> pty -> ghostty screen ok")

# Prefix + c: new tab in the active pane (two tabs, one pane).
os.write(fd, b"\x02c")
drain(1.0)
ws = rpc({"id": 4, "cmd": "list-workspaces"})
panes = ws["data"]["workspaces"][0]["panes"]
assert len(panes) == 1, ws
assert len(panes[0]["tabs"]) == 2, ws
assert panes[0]["active_tab"] == 1, ws
print("prefix-c new tab in pane ok")

# The status line lists both tabs of the active pane ("1:... 2:...*").
drain(0.5)
text = output.decode("utf-8", "replace")
assert "2:" in text, text[-500:]
print("tab bar + status tabs rendered ok")

# Prefix + %: split right (two panes).
os.write(fd, b"\x02%")
drain(1.0)
ws = rpc({"id": 5, "cmd": "list-workspaces"})
panes = ws["data"]["workspaces"][0]["panes"]
assert len(panes) == 2, ws
print("prefix-%% split ok")

# Split via socket while TUI is attached.
new = rpc({"id": 6, "cmd": "split", "pane": panes[0]["id"], "dir": "down"})
assert new["ok"], new
drain(0.5)
ws = rpc({"id": 7, "cmd": "list-workspaces"})
assert len(ws["data"]["workspaces"][0]["panes"]) == 3, ws
print("socket-driven split visible ok")

# Rename the pane and workspace over the socket; the TUI must redraw with
# the new names.
target_pane = ws["data"]["workspaces"][0]["panes"][0]["id"]
ws_id = ws["data"]["workspaces"][0]["id"]
assert rpc({"id": 8, "cmd": "rename-pane", "pane": target_pane, "name": "smoke-pane"})["ok"]
assert rpc({"id": 9, "cmd": "rename-workspace", "workspace": ws_id, "name": "smoke-ws"})["ok"]
drain(1.0)
ws = rpc({"id": 10, "cmd": "list-workspaces"})
assert ws["data"]["workspaces"][0]["name"] == "smoke-ws", ws
assert ws["data"]["workspaces"][0]["panes"][0]["name"] == "smoke-pane", ws
text = output.decode("utf-8", "replace")
assert "smoke-ws" in text, text[-500:]
print("rename pane/workspace ok")

# TUI drew something plausible: status bar contains the session label.
assert SESSION.split("-")[0] in text, text[-300:]
print("TUI rendered status bar ok")

# Sidebar rendered: header + new-workspace row are sidebar-only strings.
assert "workspaces" in text, text[-500:]
assert "+ new workspace" in text, text[-500:]
print("sidebar rendered ok")

# Prefix-W: create a second workspace; it becomes active.
os.write(fd, b"\x02W")
drain(1.0)
ws = rpc({"id": 11, "cmd": "list-workspaces"})
workspaces = ws["data"]["workspaces"]
assert len(workspaces) == 2, ws
assert workspaces[1]["active"], ws
print("prefix-W new workspace ok")

# Click the first workspace's sidebar entry. Layout: row 0 header, rows
# 1-2 workspace 1, row 3 blank, rows 4-5 workspace 2. Click row 1 (SGR
# is 1-based: row 2).
os.write(fd, b"\x1b[<0;2;2M\x1b[<0;2;2m")
drain(1.0)
ws = rpc({"id": 12, "cmd": "list-workspaces"})
assert ws["data"]["workspaces"][0]["active"], ws
print("sidebar click switches workspace ok")

# Right-click inside the right-hand pane (col 81, row 6 SGR; clear of the
# sidebar and separators), then click the first menu item (Rename pane):
# the status line shows the prompt. Type a name and press Enter; the pane
# rename lands. The menu opens at the click cell, so its first row is the
# same cell.
os.write(fd, b"\x1b[<2;81;6M\x1b[<2;81;6m")
drain(0.8)
text = output.decode("utf-8", "replace")
assert "Rename pane" in text, text[-800:]
os.write(fd, b"\x1b[<0;81;6M\x1b[<0;81;6m")
drain(0.8)
os.write(fd, b"clicked-name\r")
drain(1.0)
ws = rpc({"id": 13, "cmd": "list-workspaces"})
names = [p.get("name") for w in ws["data"]["workspaces"] for p in w["panes"]]
assert "clicked-name" in names, ws
print("right-click menu -> rename prompt ok")

# Prefix + d: quit.
os.write(fd, b"\x02d")
deadline = time.time() + 5
while time.time() < deadline:
    done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        print("clean quit, status", status)
        break
    drain(0.2)
else:
    os.kill(pid, signal.SIGKILL)
    raise SystemExit("TUI did not quit on prefix-d")

assert not os.path.exists(SOCK), "socket not cleaned up"
print("socket cleanup ok")
print("SMOKE OK")
