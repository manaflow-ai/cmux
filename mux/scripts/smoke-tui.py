import os, pty, select, socket, json, time, sys, signal, subprocess

BIN = os.environ.get("CMUX_MUX_BIN", "target/debug/cmux-mux")
SESSION = f"smoke-{os.getpid()}"
SOCK = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"cmux-mux-{os.getuid()}", f"{SESSION}.sock")

def rpc(cmd):
    s = socket.socket(socket.AF_UNIX)
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

drain(2.0)
assert os.path.exists(SOCK), f"socket missing at {SOCK}"

ident = rpc({"id": 1, "cmd": "identify"})
assert ident["ok"] and ident["data"]["app"] == "cmux-mux", ident
print("identify ok:", ident["data"])

ws = rpc({"id": 2, "cmd": "list-workspaces"})
tabs = ws["data"]["workspaces"][0]["tabs"]
assert len(tabs) == 1, ws
pane_id = tabs[0]["panes"][0]["id"]
print("initial tree ok, pane", pane_id)

# Type a command into the shell via the TUI's stdin path (real keystrokes).
os.write(fd, b"printf 'smoke-marker-%s\\n' ok\r")
drain(1.5)
screen = rpc({"id": 3, "cmd": "read-screen", "pane": pane_id})
assert "smoke-marker-ok" in screen["data"]["text"], screen["data"]["text"][-500:]
print("keystroke -> pty -> ghostty screen ok")

# Prefix + c: new tab.
os.write(fd, b"\x02c")
drain(1.0)
ws = rpc({"id": 4, "cmd": "list-workspaces"})
tabs = ws["data"]["workspaces"][0]["tabs"]
assert len(tabs) == 2, ws
print("prefix-c new tab ok")

# Prefix + %: split right.
os.write(fd, b"\x02%")
drain(1.0)
ws = rpc({"id": 5, "cmd": "list-workspaces"})
panes = ws["data"]["workspaces"][0]["tabs"][1]["panes"]
assert len(panes) == 2, ws
print("prefix-%% split ok")

# Split via socket while TUI is attached.
new = rpc({"id": 6, "cmd": "split", "pane": panes[0]["id"], "dir": "down"})
assert new["ok"], new
drain(0.5)
ws = rpc({"id": 7, "cmd": "list-workspaces"})
assert len(ws["data"]["workspaces"][0]["tabs"][1]["panes"]) == 3, ws
print("socket-driven split visible ok")

# TUI drew something plausible: status bar contains the session label.
text = output.decode("utf-8", "replace")
assert SESSION.split("-")[0] in text, text[-300:]
print("TUI rendered status bar ok")

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
