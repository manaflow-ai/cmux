import os, pty, select, socket, json, time, sys, signal, subprocess, re

BIN = os.environ.get("CMUX_MUX_BIN", "target/debug/cmux-mux")
SESSION = f"smoke-{os.getpid()}"
SOCK = None
CONTROL_SOCKET_RE = re.compile(r"control socket at (.+)$")

def fallback_socket_path():
    base = os.environ.get("XDG_RUNTIME_DIR") or os.environ.get("TMPDIR") or "/tmp"
    return os.path.join(base, f"cmux-mux-{os.getuid()}", f"{SESSION}.sock")

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

def stop_process(process):
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)

def discover_socket_path():
    probe = subprocess.Popen(
        [BIN, "--headless", "--session", SESSION],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    path = None
    try:
        path = wait_for_control_socket(probe)
        return path
    finally:
        stop_process(probe)
        if path and os.path.exists(path):
            os.unlink(path)

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

def send_prefix_t_until_tab_count(count):
    last = None
    for _ in range(5):
        last = active_screen(tree()[0])
        if len(last["panes"][0]["tabs"]) >= count:
            return last
        os.write(fd, b"\x02t")
        drain(0.8)
    raise AssertionError(last)

SOCK = discover_socket_path()

pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.environ["CMUX_MUX_CDP_URL"] = "http://127.0.0.1:1/"
    os.environ.pop("NO_COLOR", None)
    os.execv(BIN, [BIN, "--session", SESSION, "--socket", SOCK])

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

def render_style_snapshot(data, rows=30, cols=100):
    grid = [[{"bg": None, "bold": False, "dim": False, "reverse": False} for _ in range(cols)] for _ in range(rows)]
    x = y = 0
    bg = None
    bold = False
    dim = False
    reverse = False
    i = 0
    while i < len(data):
        b = data[i]
        if b == 0x1b and i + 1 < len(data) and data[i + 1] == ord("["):
            j = i + 2
            while j < len(data) and not (0x40 <= data[j] <= 0x7e):
                j += 1
            if j >= len(data):
                break
            params = data[i + 2:j].decode("ascii", "ignore")
            final = chr(data[j])
            if final in ("H", "f"):
                parts = [p for p in params.split(";") if p and not p.startswith("?")]
                row = int(parts[0]) if len(parts) >= 1 and parts[0].isdigit() else 1
                col = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 1
                y = max(0, min(rows - 1, row - 1))
                x = max(0, min(cols - 1, col - 1))
            elif final == "m":
                raw = [p for p in params.split(";") if p]
                vals = [int(p) for p in raw if p.isdigit()] or [0]
                k = 0
                while k < len(vals):
                    if vals[k] == 0:
                        bg = None
                        bold = False
                        dim = False
                        reverse = False
                    elif vals[k] == 1:
                        bold = True
                    elif vals[k] == 2:
                        dim = True
                    elif vals[k] == 7:
                        reverse = True
                    elif vals[k] == 22:
                        bold = False
                        dim = False
                    elif vals[k] == 27:
                        reverse = False
                    elif vals[k] == 49:
                        bg = None
                    elif vals[k] == 48 and k + 2 < len(vals) and vals[k + 1] == 5:
                        bg = vals[k + 2]
                        k += 2
                    k += 1
            i = j + 1
            continue
        if b == 0x0d:
            x = 0
            i += 1
            continue
        if b == 0x0a:
            y = min(rows - 1, y + 1)
            i += 1
            continue
        if b < 0x20:
            i += 1
            continue
        if y < rows and x < cols:
            grid[y][x] = {"bg": bg, "bold": bold, "dim": dim, "reverse": reverse}
        if b < 0x80:
            i += 1
        elif b & 0xE0 == 0xC0:
            i += 2
        elif b & 0xF0 == 0xE0:
            i += 3
        elif b & 0xF8 == 0xF0:
            i += 4
        else:
            i += 1
        x = min(cols - 1, x + 1)
    return grid

def render_text_snapshot(data, rows=30, cols=100):
    chars = [[" " for _ in range(cols)] for _ in range(rows)]
    x = y = 0
    i = 0
    while i < len(data):
        b = data[i]
        if b == 0x1b and i + 1 < len(data) and data[i + 1] == ord("["):
            j = i + 2
            while j < len(data) and not (0x40 <= data[j] <= 0x7e):
                j += 1
            if j >= len(data):
                break
            params = data[i + 2:j].decode("ascii", "ignore")
            final = chr(data[j])
            if final in ("H", "f"):
                parts = [p for p in params.split(";") if p and not p.startswith("?")]
                row = int(parts[0]) if len(parts) >= 1 and parts[0].isdigit() else 1
                col = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 1
                y = max(0, min(rows - 1, row - 1))
                x = max(0, min(cols - 1, col - 1))
            elif final == "K":
                for xx in range(x, cols):
                    chars[y][xx] = " "
            elif final == "J":
                for yy in range(y, rows):
                    start = x if yy == y else 0
                    for xx in range(start, cols):
                        chars[yy][xx] = " "
            i = j + 1
            continue
        if b == 0x0d:
            x = 0
            i += 1
            continue
        if b == 0x0a:
            y = min(rows - 1, y + 1)
            i += 1
            continue
        if b < 0x20:
            i += 1
            continue
        step = 1
        if b >= 0x80:
            if b & 0xE0 == 0xC0:
                step = 2
            elif b & 0xF0 == 0xE0:
                step = 3
            elif b & 0xF8 == 0xF0:
                step = 4
        chars[y][x] = data[i : i + step].decode("utf-8", "replace")
        x = min(cols - 1, x + 1)
        i += step
    return "\n".join("".join(row) for row in chars)

deadline = time.time() + 15
while not os.path.exists(SOCK) and time.time() < deadline:
    drain(0.2)
assert os.path.exists(SOCK), f"socket missing at {SOCK}"
drain(1.0)
assert probe_answers[10] > 0 and probe_answers[11] > 0, probe_answers

ident = rpc({"id": 1, "cmd": "identify"})
assert ident["ok"] and ident["data"]["app"] == "cmux-mux", ident
assert ident["data"]["protocol"] == 6, ident
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

# Prefix-B creates a browser tab immediately and focuses its in-pane
# omnibar. The dead CDP endpoint keeps this Chrome-free and fast.
before_tabs = len(panes[0]["tabs"])
os.write(fd, b"\x02B")
drain(0.8)
screen0 = active_screen(tree()[0])
tabs = screen0["panes"][0]["tabs"]
assert len(tabs) == before_tabs + 1, screen0
assert tabs[-1]["kind"] == "browser", tabs
os.write(fd, b"example.com")
drain(0.5)
text = output.decode("utf-8", "replace")
assert "example.com" in text, text[-800:]
os.write(fd, b"\x1b")
drain(0.5)
# Close the browser TAB. prefix-X since the tmux-alignment flip: x kills the
# pane (which here is the only pane and would end the session), X the tab.
os.write(fd, b"\x02X")
drain(0.8)
screen0 = active_screen(tree()[0])
assert len(screen0["panes"][0]["tabs"]) == before_tabs, screen0
print("prefix-B browser omnibar focuses, Esc blurs, and close works ok")

# Host OSC replies must be consumed by the startup probe, not forwarded as
# keystrokes into the child shell.
screen = rpc({"id": 30, "cmd": "read-screen", "surface": surface_id})
assert "rgb:" not in screen["data"]["text"], screen["data"]["text"][-500:]
print("host color probe replies did not leak to shell ok")

# Type a command into the shell via the TUI's stdin path (real keystrokes).
os.write(fd, b"printf 'smoke-marker-%s\\n' ok\r")
wait_screen_contains(surface_id, "smoke-marker-ok")
print("keystroke -> pty -> ghostty screen ok")

color_output_start = len(output)
os.write(
    fd,
    b"printf '\\033[31mCF1\\033[93mCF2\\033[38;5;196mCF3\\033[48;5;236mCF4\\033[0m\\n'\r",
)
wait_screen_contains(surface_id, "CF1CF2CF3CF4")
color_output = output[color_output_start:]
assert re.search(rb"\x1b\[[0-9;]*(31|38;5;1)(;[0-9]*)?m", color_output), color_output[-2000:]
assert b"38;5;196" in color_output, color_output[-2000:]
assert b"48;5;236" in color_output, color_output[-2000:]
assert b"204;102;102" not in color_output, color_output[-2000:]
print("indexed color passthrough ok")

inner_osc_query = """python3 - <<'PY'
import os, select, termios, time, tty
fd = os.open('/dev/tty', os.O_RDWR)
old = termios.tcgetattr(fd)
try:
    tty.setraw(fd)
    os.write(fd, b'\\x1b]11;?\\x1b\\\\')
    data = b''
    # Generous deadline: the shell may still be consuming the pasted
    # heredoc and the TUI coalesces frames (this raced at 2s).
    end = time.time() + 8
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
os.write(fd, b"\x03")
drain(0.4)

# Drag-select the marker text: press, drag, release (SGR mouse, 1-based).
# Pane content starts at column 24 (sidebar 22 + left border 1; SGR
# 1-based) and row offset 1 for the top border. On release the TUI must
# copy the selection to the host clipboard as an OSC 52 sequence.
os.write(fd, b"clear; printf 'smoke-marker-%s\\n' ok\r")
wait_screen_contains(surface_id, "smoke-marker-ok")
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
assert "Copied" in render_text_snapshot(output), output[-1200:]
drain(1.7)
assert "Copied" not in render_text_snapshot(output), output[-1200:]
print("drag-select -> OSC52 clipboard copy ok")

os.write(fd, b"clear; for i in $(seq -w 0 80); do printf 'sel-line-%s\\n' \"$i\"; done\r")
wait_screen_contains(surface_id, "sel-line-80")
assert rpc({"id": 101, "cmd": "scroll-surface", "surface": surface_id, "delta": -24})["ok"]
drain(0.4)
before_scroll = rpc({"id": 102, "cmd": "read-screen", "surface": surface_id})["data"]["text"]
lines = before_scroll.splitlines()
vrow = next(i for i, l in enumerate(lines) if "sel-line-" in l)
start_col = 24 + lines[vrow].index("sel-line-")
start_row = vrow + 2
bottom_row = 28
os.write(fd, f"\x1b[<0;{start_col};{start_row}M".encode())
held_output_start = len(output)
os.write(fd, f"\x1b[<32;{start_col + 10};{bottom_row}M".encode())
drain(0.9)
held_render = output[held_output_start:].decode("utf-8", "replace")
assert re.search(r"sel-line-(2[0-9]|3[0-9]|4[0-9])", held_render), held_render[-2000:]
os.write(fd, f"\x1b[<0;{start_col + 10};{bottom_row}m".encode())
drain(0.6)
osc52 = re.findall(rb"\x1b\]52;c;([A-Za-z0-9+/=]+)", output)
assert osc52, "no OSC 52 clipboard write after auto-scroll drag-select"
copied = base64.b64decode(osc52[-1]).decode()
assert "sel-line-" in copied and "\n" in copied, repr(copied)
print("drag-select auto-scroll and scroll-stable copy ok")

# Click the + in the top border for a new tab (tab "1" label is 3 cols
# wide plus optional title; find via hits is not possible from outside,
# so use prefix-t which shares the same action path).
screen0 = send_prefix_t_until_tab_count(2)
screen0 = send_prefix_t_until_tab_count(3)
panes = screen0["panes"]
assert len(panes) == 1, screen0
assert len(panes[0]["tabs"]) == 3, screen0
assert panes[0]["active_tab"] == 2, screen0

# Alt-n: smart split. In this 75x27 content geometry, width > 2*height,
# so the visually longer axis is horizontal and the split is right.
os.write(fd, b"\x1bn")
drain(1.0)
screen0 = active_screen(tree()[0])
panes = screen0["panes"]
assert len(panes) == 2, screen0
assert screen0["layout"]["type"] == "split" and screen0["layout"]["dir"] == "right", screen0
print("alt-n smart split ok")

left_pane = panes[0]
right_pane = panes[1]
tab_order = [t["surface"] for t in left_pane["tabs"]]
os.write(fd, b"\x1b[<0;41;1M\x1b[<32;24;1M\x1b[<0;24;1m")
drain(1.0)
screen0 = active_screen(tree()[0])
panes_by_id = {p["id"]: p for p in screen0["panes"]}
left_pane = panes_by_id[left_pane["id"]]
right_pane = panes_by_id[right_pane["id"]]
reordered = [t["surface"] for t in left_pane["tabs"]]
assert reordered == [tab_order[2], tab_order[0], tab_order[1]], (tab_order, reordered, screen0)
print("tab drag reorder within pane ok")

os.write(fd, b"\x1b[<0;24;1M\x1b[<32;42;1M\x1b[<0;42;1m")
drain(1.0)
screen0 = active_screen(tree()[0])
panes_by_id = {p["id"]: p for p in screen0["panes"]}
left_pane = panes_by_id[left_pane["id"]]
end_reordered = [t["surface"] for t in left_pane["tabs"]]
assert end_reordered == [tab_order[0], tab_order[1], tab_order[2]], (tab_order, end_reordered, screen0)
print("tab drag past last chip inserts at end ok")

moving_surface = left_pane["tabs"][0]["surface"]
os.write(fd, b"\x1b[<0;27;1M\x1b[<32;63;1M\x1b[<0;63;1m")
drain(1.0)
screen0 = active_screen(tree()[0])
panes_by_id = {p["id"]: p for p in screen0["panes"]}
assert moving_surface not in [t["surface"] for t in panes_by_id[left_pane["id"]]["tabs"]], screen0
assert moving_surface in [t["surface"] for t in panes_by_id[right_pane["id"]]["tabs"]], screen0
print("tab drag to another pane ok")

left_pane = panes_by_id[left_pane["id"]]
right_pane = panes_by_id[right_pane["id"]]
content_surface = left_pane["tabs"][0]["surface"]
right_before = [t["surface"] for t in right_pane["tabs"]]
os.write(fd, b"\x1b[<0;27;1M\x1b[<32;82;8M\x1b[<0;82;8m")
drain(1.0)
screen0 = active_screen(tree()[0])
panes_by_id = {p["id"]: p for p in screen0["panes"]}
right_after = [t["surface"] for t in panes_by_id[right_pane["id"]]["tabs"]]
assert right_after == right_before + [content_surface], (right_before, right_after, screen0)
print("tab drag to pane content appends ok")

# Split via socket while TUI is attached.
new = rpc({"id": 6, "cmd": "split", "pane": panes[0]["id"], "dir": "down"})
assert new["ok"], new
drain(0.5)
screen0 = active_screen(tree()[0])
assert len(screen0["panes"]) == 3, screen0
print("socket-driven split visible ok")

# Prefix + c: new screen in the workspace; it becomes active with 1 pane.
os.write(fd, b"\x02c")
drain(1.0)
ws0 = tree()[0]
assert len(ws0["screens"]) == 2, ws0
assert ws0["screens"][1]["active"], ws0
assert len(ws0["screens"][1]["panes"]) == 1, ws0
print("prefix-c new screen ok")

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

# Drag the original workspace below the new one. Layout: row 0 header,
# row 1 blank, rows 2-3 workspace 1, row 4 blank, rows 5-6 workspace 2
# (SGR mouse coordinates are 1-based).
original_ws = ws_id
os.write(fd, b"\x1b[<0;2;3M\x1b[<32;2;7M\x1b[<0;2;7m")
drain(1.0)
workspaces = tree()
assert [w["id"] for w in workspaces] == [w["id"] for w in workspaces if w["id"] != original_ws] + [original_ws], workspaces
print("sidebar workspace drag reorder ok")

# Click the moved original workspace's sidebar entry.
os.write(fd, b"\x1b[<0;2;6M\x1b[<0;2;6m")
drain(1.0)
workspaces = tree()
assert workspaces[1]["active"] and workspaces[1]["id"] == original_ws, workspaces
print("sidebar click switches workspace ok")

# A workspace context menu overlaps the active sidebar row. The menu must
# repaint the cell style, not inherit the sidebar active background.
output = b""
os.write(fd, b"\x1b[<2;2;6M\x1b[<2;2;6m")
drain(0.8)
text = output.decode("utf-8", "replace")
assert "Rename workspace" in text, text[-800:]
assert "Copy workspace id" in text, text[-800:]
assert "┌" in text, text[-800:]
styles = render_style_snapshot(output)
overlap = styles[6][2]  # item 1: non-selected menu row over the active workspace subtitle row.
assert overlap["bg"] == 237 and not overlap["bold"] and not overlap["dim"], (overlap, text[-800:])
os.write(fd, b"\x1b")
drain(0.4)
print("sidebar-overlapping menu repaints menu background ok")

# Plain right-click inside the right-hand pane (col 81, row 6 SGR; clear
# of the sidebar and borders): the menu opens at the press cell and must
# stay open after release in place.
output = b""
os.write(fd, b"\x1b[<2;81;6M\x1b[<2;81;6m")
drain(0.8)
text = output.decode("utf-8", "replace")
assert "Rename tab" in text, text[-800:]
assert "Copy tab id" in text, text[-800:]
assert "Copy pane id" in text, text[-800:]
assert "Close tab" in text, text[-800:]
assert "┌" in text, text[-800:]
assert "[ OK ⏎ ]" not in text, text[-800:]
output = b""
os.write(fd, b"\x1b[<34;81;7M\x1b[<2;81;7m")
drain(0.8)
osc52 = re.findall(rb"\x1b\]52;c;([A-Za-z0-9+/=]+)", output)
assert osc52, "no OSC 52 clipboard write after menu copy"
copied_id = base64.b64decode(osc52[-1]).decode()
assert re.fullmatch(r"[0-9a-z]{6}", copied_id), copied_id
assert f"Copied {copied_id}" in render_text_snapshot(output), output[-1200:]
drain(1.7)
assert f"Copied {copied_id}" not in render_text_snapshot(output), output[-1200:]
print("right-click menu copy tab id -> OSC52 clipboard copy ok")

# Right-press, drag to another row, and release activates that row. New tab
# is below the copy-id rows, so total tab count increases.
tabs_before = sum(
    len(p["tabs"])
    for w in tree()
    for s in w["screens"]
    for p in s["panes"]
)
os.write(fd, b"\x1b[<2;81;6M\x1b[<34;81;9M\x1b[<2;81;9m")
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
# A centered rename dialog opens (title, input, and shortcut buttons).
text = output.decode("utf-8", "replace")
assert "[ Clear ^C ]" in text and "[ Cancel esc ]" in text and "[ OK ⏎ ]" in text, text[-800:]
os.write(fd, b"tab\x01my-\x1bf-ok")
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
assert "my-tab-ok" in tab_names, tab_names
text = output.decode("utf-8", "replace")
assert "my-tab-ok" in text, text[-1200:]
print("right-click menu -> rename tab prompt ok")

# "Close tab" closes the active tab for the pane under the context menu.
tabs_before = sum(
    len(p["tabs"])
    for w in tree()
    for s in w["screens"]
    for p in s["panes"]
)
# "Close tab" sits below the copy-id and split rows.
os.write(fd, b"\x1b[<2;81;6M\x1b[<34;81;13M\x1b[<2;81;13m")
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
