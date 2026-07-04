import os, pty, select, socket, json, time, sys, signal, subprocess, re

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
probe_pending = b""
probe_answers = {10: 0, 11: 0}

def answer_host_color_queries(chunk):
    global probe_pending
    probe_pending += chunk
    while True:
        start = probe_pending.find(b"\x1b]")
        if start < 0:
            probe_pending = probe_pending[-1:]
            return
        if start > 0:
            probe_pending = probe_pending[start:]

        bel = probe_pending.find(b"\x07", 2)
        st = probe_pending.find(b"\x1b\\", 2)
        ends = [(bel, b"\x07", 1), (st, b"\x1b\\", 2)]
        ends = [e for e in ends if e[0] >= 0]
        if not ends:
            probe_pending = probe_pending[-64:]
            return
        end, terminator, term_len = min(ends, key=lambda e: e[0])
        seq = probe_pending[:end]
        if seq == b"\x1b]10;?":
            os.write(fd, b"\x1b]10;rgb:d8d8/d9d9/dada" + terminator)
            probe_answers[10] += 1
        elif seq == b"\x1b]11;?":
            os.write(fd, b"\x1b]11;rgb:1313/1414/1515" + terminator)
            probe_answers[11] += 1
        probe_pending = probe_pending[end + term_len:]

def drain(seconds):
    global output
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, 65536)
                output += chunk
                answer_host_color_queries(chunk)
            except OSError:
                break

def wait_screen_contains(surface_id, needle, seconds=15):
    deadline = time.time() + seconds
    last = ""
    while time.time() < deadline:
        drain(0.2)
        screen = rpc({"id": 300, "cmd": "read-screen", "surface": surface_id})
        last = screen["data"]["text"]
        if needle in last:
            return last
    raise AssertionError(last[-500:])

deadline = time.time() + 15
while not os.path.exists(SOCK) and time.time() < deadline:
    drain(0.2)
assert os.path.exists(SOCK), f"socket missing at {SOCK}"
drain(1.0)
assert probe_answers[10] > 0 and probe_answers[11] > 0, probe_answers

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
# box eats one cell on every side plus a dedicated scrollbar column -> content 75x27.
size = panes[0]["tabs"][0]["size"]
assert size == {"cols": 75, "rows": 27}, size
print("initial surface spawned at final size ok")

# The tab bar is always visible: a single-tab pane still shows its
# numbered tab and the + button in the top border.
drain(0.5)
text = output.decode("utf-8", "replace")
assert " 1 " in text, text[-500:]
assert " + " in text, text[-500:]
print("always-on tab bar with numbered tab ok")

# Host OSC replies must be consumed by the startup probe, not forwarded as
# keystrokes into the child shell.
screen = rpc({"id": 30, "cmd": "read-screen", "surface": surface_id})
assert "rgb:" not in screen["data"]["text"], screen["data"]["text"][-500:]
print("host color probe replies did not leak to shell ok")

# Type a command into the shell via the TUI's stdin path (real keystrokes).
os.write(fd, b"printf 'smoke-marker-%s\\n' ok\r")
wait_screen_contains(surface_id, "smoke-marker-ok")
print("keystroke -> pty -> ghostty screen ok")

inner_osc_query = """python3 - <<'PY'
import os, select, termios, time, tty
fd = os.open('/dev/tty', os.O_RDWR)
old = termios.tcgetattr(fd)
try:
    tty.setraw(fd)
    os.write(fd, b'\\x1b]11;?\\x1b\\\\')
    data = b''
    end = time.time() + 2
    while time.time() < end and not (data.endswith(b'\\x1b\\\\') or data.endswith(b'\\x07')):
        r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
        if not r:
            break
        data += os.read(fd, 128)
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    os.close(fd)
print(data.decode('ascii', 'ignore').replace('\\x1b', '<ESC>').replace('\\x07', '<BEL>'))
PY
"""
os.write(fd, inner_osc_query.replace("\n", "\r").encode())
wait_screen_contains(surface_id, "1313/1414/1515")
print("inner OSC 11 query receives seeded background ok")

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
import base64
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

# Plain right-click inside the right-hand pane (col 81, row 6 SGR; clear
# of the sidebar and borders): the menu opens at the press cell and must
# stay open after release in place.
os.write(fd, b"\x1b[<2;81;6M\x1b[<2;81;6m")
drain(0.8)
text = output.decode("utf-8", "replace")
assert "Rename tab" in text, text[-800:]
assert "Close tab" in text, text[-800:]
assert "[ OK ]" not in text, text[-800:]
os.write(fd, b"\x1b")  # close menu
drain(0.4)

# Right-press, drag to another row, and release activates that row. Row 2
# is "New tab", so total tab count increases.
tabs_before = sum(
    len(p["tabs"])
    for w in tree()
    for s in w["screens"]
    for p in s["panes"]
)
os.write(fd, b"\x1b[<2;81;6M\x1b[<34;81;7M\x1b[<2;81;7m")
drain(1.0)
tabs_after = sum(
    len(p["tabs"])
    for w in tree()
    for s in w["screens"]
    for p in s["panes"]
)
assert tabs_after == tabs_before + 1, (tabs_before, tabs_after, tree())
print("right-drag menu row activation ok")

# Open the menu normally again and left-click "Rename tab".
os.write(fd, b"\x1b[<2;81;6M\x1b[<2;81;6m")
drain(0.8)
text = output.decode("utf-8", "replace")
assert "Rename tab" in text, text[-800:]
assert "Close tab" in text, text[-800:]
os.write(fd, b"\x1b[<0;82;6M\x1b[<0;82;6m")
drain(0.8)
# A centered rename dialog opens (title + OK/Cancel buttons).
text = output.decode("utf-8", "replace")
assert "[ OK ]" in text and "[ Cancel ]" in text, text[-800:]
os.write(fd, b"clicked-tab")
drain(0.5)
output = b""
os.write(fd, b"\x1b[<0;65;17M\x1b[<0;65;17m")
drain(1.0)
tab_names = [
    t.get("name")
    for w in tree()
    for s in w["screens"]
    for p in s["panes"]
    for t in p["tabs"]
]
assert "clicked-tab" in tab_names, tab_names
text = output.decode("utf-8", "replace")
assert "clicked-tab" in text, text[-1200:]
print("right-click menu -> rename tab prompt ok")

# "Close tab" closes the active tab for the pane under the context menu.
tabs_before = sum(
    len(p["tabs"])
    for w in tree()
    for s in w["screens"]
    for p in s["panes"]
)
os.write(fd, b"\x1b[<2;81;6M\x1b[<34;81;10M\x1b[<2;81;10m")
drain(1.0)
tabs_after = sum(
    len(p["tabs"])
    for w in tree()
    for s in w["screens"]
    for p in s["panes"]
)
assert tabs_after == tabs_before - 1, (tabs_before, tabs_after, tree())
print("right-click menu -> close tab ok")

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
