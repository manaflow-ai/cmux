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

def tree():
    return rpc({"id": 999, "cmd": "list-workspaces"})["data"]["workspaces"]

def active_screen(ws):
    return next(s for s in ws["screens"] if s["active"])

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
assert ident["data"]["protocol"] == 4, ident
print("identify ok:", ident["data"])

ws0 = tree()[0]
screen0 = active_screen(ws0)
panes = screen0["panes"]
assert len(panes) == 1, ws0
pane_id = panes[0]["id"]
surface_id = panes[0]["tabs"][0]["surface"]
print("initial tree ok, screen", screen0["id"], "pane", pane_id, "surface", surface_id)

# Spawn-at-size: the first surface was created at its final render size.
# Window 100x30, sidebar 22, status bar 1 -> pane rect 78x29; the border
# box eats one cell on every side -> content 76x27.
size = panes[0]["tabs"][0]["size"]
assert size == {"cols": 76, "rows": 27}, size
print("initial surface spawned at final size ok")

# The tab bar is always visible: a single-tab pane still shows its
# numbered tab and the + button in the top border.
drain(0.5)
text = output.decode("utf-8", "replace")
assert " 1 " in text, text[-500:]
assert " + " in text, text[-500:]
print("always-on tab bar with numbered tab ok")

# Type a command into the shell via the TUI's stdin path (real keystrokes).
os.write(fd, b"printf 'smoke-marker-%s\\n' ok\r")
drain(1.5)
screen = rpc({"id": 3, "cmd": "read-screen", "surface": surface_id})
assert "smoke-marker-ok" in screen["data"]["text"], screen["data"]["text"][-500:]
print("keystroke -> pty -> ghostty screen ok")

# Drag-select the marker text: press, drag, release (SGR mouse, 1-based).
# Pane content starts at column 24 (sidebar 22 + left border 1; SGR
# 1-based) and row offset 1 for the top border. On release the TUI must
# copy the selection to the host clipboard as an OSC 52 sequence.
lines = rpc({"id": 100, "cmd": "read-screen", "surface": surface_id})["data"]["text"].splitlines()
vrow = next(i for i, l in enumerate(lines) if "smoke-marker-ok" in l)
row = vrow + 2  # +1 top border, +1 SGR 1-based
col0 = 24 + lines[vrow].index("smoke-marker-ok")
os.write(fd, f"\x1b[<0;{col0};{row}M".encode())
os.write(fd, f"\x1b[<32;{col0 + 14};{row}M".encode())
os.write(fd, f"\x1b[<0;{col0 + 14};{row}m".encode())
drain(1.0)
import base64, re
osc52 = re.findall(rb"\x1b\]52;c;([A-Za-z0-9+/=]+)", output)
assert osc52, "no OSC 52 clipboard write after drag-select"
copied = base64.b64decode(osc52[-1]).decode()
assert "smoke-marker-ok" in copied, repr(copied)
print("drag-select -> OSC52 clipboard copy ok")

# Click the + in the top border for a new tab (tab "1" label is 3 cols
# wide plus optional title; find via hits is not possible from outside,
# so use prefix-c which shares the same action path).
os.write(fd, b"\x02c")
drain(1.0)
screen0 = active_screen(tree()[0])
panes = screen0["panes"]
assert len(panes) == 1, screen0
assert len(panes[0]["tabs"]) == 2, screen0
assert panes[0]["active_tab"] == 1, screen0
print("prefix-c new tab in pane ok")

# Prefix + %: split right (two panes).
os.write(fd, b"\x02%")
drain(1.0)
screen0 = active_screen(tree()[0])
panes = screen0["panes"]
assert len(panes) == 2, screen0
print("prefix-%% split ok")

# Split via socket while TUI is attached.
new = rpc({"id": 6, "cmd": "split", "pane": panes[0]["id"], "dir": "down"})
assert new["ok"], new
drain(0.5)
screen0 = active_screen(tree()[0])
assert len(screen0["panes"]) == 3, screen0
print("socket-driven split visible ok")

# Prefix + S: new screen in the workspace; it becomes active with 1 pane.
os.write(fd, b"\x02S")
drain(1.0)
ws0 = tree()[0]
assert len(ws0["screens"]) == 2, ws0
assert ws0["screens"][1]["active"], ws0
assert len(ws0["screens"][1]["panes"]) == 1, ws0
print("prefix-S new screen ok")

# The status bar shows both screens; click screen 1's entry to switch
# back. Status bar row is the last row (30). The bar starts after the
# sidebar (col 23 SGR) with " screens " (9 cols), so entry 1 starts at
# col 32.
os.write(fd, b"\x1b[<0;33;30M\x1b[<0;33;30m")
drain(1.0)
ws0 = tree()[0]
assert ws0["screens"][0]["active"], ws0
print("status-bar screen click switches ok")

# Rename the active screen over the socket; the status bar redraws with it.
screen_id = ws0["screens"][0]["id"]
assert rpc({"id": 7, "cmd": "rename-screen", "screen": screen_id, "name": "smoke-scr"})["ok"]
drain(1.0)
text = output.decode("utf-8", "replace")
assert "smoke-scr" in text, text[-500:]
print("rename screen visible in status bar ok")

# Rename the pane and workspace over the socket; the TUI must redraw with
# the new names.
ws0 = tree()[0]
target_pane = active_screen(ws0)["panes"][0]["id"]
ws_id = ws0["id"]
assert rpc({"id": 8, "cmd": "rename-pane", "pane": target_pane, "name": "smoke-pane"})["ok"]
assert rpc({"id": 9, "cmd": "rename-workspace", "workspace": ws_id, "name": "smoke-ws"})["ok"]
drain(1.0)
ws0 = tree()[0]
assert ws0["name"] == "smoke-ws", ws0
assert active_screen(ws0)["panes"][0]["name"] == "smoke-pane", ws0
text = output.decode("utf-8", "replace")
assert "smoke-ws" in text, text[-500:]
print("rename pane/workspace ok")

# Sidebar rendered: header + new-workspace row are sidebar-only strings.
assert "workspaces" in text, text[-500:]
assert "+ new workspace" in text, text[-500:]
print("sidebar rendered ok")

# Prefix-W: create a second workspace; it becomes active.
os.write(fd, b"\x02W")
drain(1.0)
workspaces = tree()
assert len(workspaces) == 2, workspaces
assert workspaces[1]["active"], workspaces
print("prefix-W new workspace ok")

# Click the first workspace's sidebar entry. Layout: row 0 header, row 1
# blank, rows 2-3 workspace 1, row 4 blank, rows 5-6 workspace 2. Click
# row 2 (SGR is 1-based: row 3).
os.write(fd, b"\x1b[<0;2;3M\x1b[<0;2;3m")
drain(1.0)
assert tree()[0]["active"], tree()
print("sidebar click switches workspace ok")

# Right-click inside the right-hand pane (col 81, row 6 SGR; clear of the
# sidebar and borders): a menu opens at the click cell with one-cell side
# padding and no top padding, so the first item row IS the click row and
# labels start one cell right. Click "Rename pane", type a name, Enter.
os.write(fd, b"\x1b[<2;81;6M\x1b[<2;81;6m")
drain(0.8)
text = output.decode("utf-8", "replace")
assert "Rename pane" in text, text[-800:]
os.write(fd, b"\x1b[<0;82;6M\x1b[<0;82;6m")
drain(0.8)
# A centered rename dialog opens (title + OK/Cancel buttons).
text = output.decode("utf-8", "replace")
assert "[ OK ]" in text and "[ Cancel ]" in text, text[-800:]
os.write(fd, b"clicked-name\r")
drain(1.0)
names = [
    p.get("name")
    for w in tree()
    for s in w["screens"]
    for p in s["panes"]
]
assert "clicked-name" in names, names
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
