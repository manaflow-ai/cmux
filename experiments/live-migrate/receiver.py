#!/usr/bin/env python3
# Fake cmux: receives a PTY master over SCM_RIGHTS. --relay bridges it to our own tty (so it shows in a cmux tab).
import os, sys, socket, array, select, fcntl, termios, struct, tty, signal
path = sys.argv[1]; relay = "--relay" in sys.argv
try: os.unlink(path)
except FileNotFoundError: pass
srv = socket.socket(socket.AF_UNIX); srv.bind(path); srv.listen(1)
c,_ = srv.accept()
fds = array.array("i")
msg, anc, _, _ = c.recvmsg(64, socket.CMSG_LEN(fds.itemsize))
for lvl, typ, data in anc:
    if lvl == socket.SOL_SOCKET and typ == socket.SCM_RIGHTS: fds.frombytes(data[:fds.itemsize])
m = fds[0]; child = int(msg)
sys.stderr.write(f"receiver pid={os.getpid()} got master fd={m} for child={child}\r\n")
def setsize(cols, rows): fcntl.ioctl(m, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
if relay:
    def sync(*a):
        try: setsize(*reversed(struct.unpack("HHHH", fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0"*8))[:2]))
        except Exception: pass
    signal.signal(signal.SIGWINCH, sync); sync()
    old = termios.tcgetattr(0); tty.setraw(0)
    try:
        while True:
            try: r,_,_ = select.select([0, m],[],[])
            except InterruptedError: continue
            if m in r:
                try: d = os.read(m, 65536)
                except OSError: break
                if not d: break
                os.write(1, d)
            if 0 in r: os.write(m, os.read(0, 65536))
    finally: termios.tcsetattr(0, termios.TCSADRAIN, old)
else:
    import time
    out = b""; t = time.time()
    while time.time() - t < 3:
        r,_,_ = select.select([m],[],[],0.2)
        if r: out += os.read(m, 4096)
    print("received output:", out[-120:])
    os.write(m, b"hello-from-receiver\n"); time.sleep(1.5)
    setsize(132, 40); time.sleep(1.5)
    r,_,_ = select.select([m],[],[],0.5)
    if r: print("after input:", os.read(m, 4096)[-200:])
    print("child alive:", os.system(f"kill -0 {child}") == 0)
