# Records codex's raw VT output in a 104x40 pty, answering the queries a
# terminal answers (cursor position, device attributes, kitty keyboard).
import os, pty, select, struct, fcntl, termios, time, sys, re
out = open(sys.argv[1], "wb")
cols, rows = 104, 40
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.environ["COLORTERM"] = "truecolor"
    os.chdir(os.path.expanduser("~"))
    os.execvp("codex", ["codex"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
start = time.time(); typed = False; quit_sent = 0; buf = b""
def reply(data):
    global buf
    buf += data
    for m in re.finditer(rb"\x1b\[(\??)6n", buf): os.write(fd, b"\x1b[1;1R")
    for m in re.finditer(rb"\x1b\[c|\x1b\[0c", buf): os.write(fd, b"\x1b[?62;22c")
    for m in re.finditer(rb"\x1b\[\?u", buf): os.write(fd, b"\x1b[?0u")
    for m in re.finditer(rb"\x1b\]1[01];\?\x1b\\\\|\x1b\]1[01];\?\x07", buf):
        os.write(fd, b"\x1b]11;rgb:ffff/ffff/ffff\x1b\\")
    buf = buf[-64:]
while True:
    t = time.time() - start
    if t > 6 and not typed:
        os.write(fd, b"say hi in one word"); time.sleep(0.3); os.write(fd, b"\r"); typed = True
    if t > 40 and quit_sent < 3:
        os.write(fd, b"\x03"); quit_sent += 1; time.sleep(0.5)
    if t > 48: break
    r, _, _ = select.select([fd], [], [], 0.2)
    if fd in r:
        try: data = os.read(fd, 65536)
        except OSError: break
        if not data: break
        out.write(data); out.flush(); reply(data)
out.close()
try: os.kill(pid, 9)
except Exception: pass
