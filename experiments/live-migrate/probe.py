#!/usr/bin/env python3
# Target process: heartbeat to a log file + its tty; logs SIGWINCH/SIGHUP/SIGCONT; echoes input lines.
import os, sys, time, signal, fcntl, termios, struct, select
log = open(sys.argv[1], "a", buffering=1)
def L(m): log.write(f"{time.strftime('%H:%M:%S')} pid={os.getpid()} {m}\n")
def winsz():
    try: r,c,_,_ = struct.unpack("HHHH", fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0"*8)); return f"{c}x{r}"
    except Exception as e: return f"err:{e}"
def onwinch(*a): L(f"SIGWINCH size={winsz()}")
signal.signal(signal.SIGWINCH, onwinch)
if os.environ.get("PROBE_LOG_HUP"):
    signal.signal(signal.SIGHUP, lambda *a: (L("SIGHUP (logged, exiting)"), sys.exit(129)))
try: tty = os.ttyname(0)
except Exception: tty = "?"
L(f"start ppid={os.getppid()} sid={os.getsid(0)} pgid={os.getpgid(0)} tty={tty} size={winsz()}")
n = 0
while True:
    r,_,_ = select.select([0],[],[],1.0)
    if r:
        data = os.read(0, 1024)
        if not data: L("stdin EOF"); 
        else: L(f"input {data!r}"); os.write(1, b"ECHO:" + data)
    n += 1
    try: os.write(1, f"beat {n} pid={os.getpid()}\r\n".encode())
    except OSError as e: L(f"write error {e}"); 
    L(f"beat {n} ppid={os.getppid()}")
