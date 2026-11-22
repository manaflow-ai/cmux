#!/usr/bin/env python3
# Fake terminal emulator: owns the PTY master. --handoff SOCK sends the master via SCM_RIGHTS, then exits.
import os, sys, pty, socket, select, time, array
args = sys.argv[1:]; handoff = None; wait = float(os.environ.get("OWNER_WAIT", "3"))
if args[0] == "--handoff": handoff = args[1]; args = args[2:]
pid, master = pty.fork()
if pid == 0: os.execvp(args[0], args)
print(f"owner pid={os.getpid()} child={pid}", flush=True)
end = time.time() + wait
while time.time() < end:
    r,_,_ = select.select([master],[],[],0.2)
    if r: os.read(master, 4096)
if handoff:
    s = socket.socket(socket.AF_UNIX); s.connect(handoff)
    s.sendmsg([f"{pid}".encode()], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [master]))])
    s.close(); print("owner: handed off master, exiting", flush=True)
else:
    print("owner: exiting WITHOUT handoff (closing master)", flush=True)
os._exit(0)
