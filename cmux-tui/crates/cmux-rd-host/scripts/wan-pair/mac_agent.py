#!/usr/bin/env python3
"""On the fleet Mac: run cmux-rd sessions the lane VM's hub asks for, over udprel.

  mac_agent.py HUB_IP:PORT TOKEN BIN [MINUTES]

Only BIN runs (the hub picks its arguments); every datagram carries TOKEN."""
import os, socket, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from udprel import Chan

hub, token, binary = sys.argv[1], sys.argv[2], sys.argv[3]
minutes = float(sys.argv[4]) if len(sys.argv) > 4 else 100
if os.fork():
    print("agent started", flush=True)
    os._exit(0)
os.setsid()
logf = open(os.path.expanduser("~/ssl3/agent.log"), "a", buffering=1)
sys.stdout = sys.stderr = logf
host, port = hub.rsplit(":", 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
ch = Chan(s, token, (host, int(port)))
end = time.time() + minutes * 60
proc = None


def pump_out(p):
    for line in p.stdout:
        ch.send({"out": line.rstrip("\n"), "t": time.time()})


def pump_err(p, tail):
    for line in p.stderr:
        tail.append(line.rstrip("\n"))
        del tail[:-30]


while time.time() < end:
    m = ch.recv(timeout=1)
    if proc is not None and proc.poll() is not None:
        time.sleep(0.3)
        ch.send({"exit": proc.returncode, "err": err_tail[-30:]})
        print("exit", proc.returncode, flush=True)
        proc = None
    if m is None:
        continue
    if "start" in m:
        if proc is not None:
            proc.kill()
        err_tail = []
        env = dict(os.environ, **m.get("env", {}))
        proc = subprocess.Popen([binary, *m["start"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, bufsize=1, env=env)
        threading.Thread(target=pump_out, args=(proc,), daemon=True).start()
        threading.Thread(target=pump_err, args=(proc, err_tail), daemon=True).start()
        print("start", m["start"], flush=True)
        ch.send({"started": proc.pid})
    elif "in" in m and proc is not None:
        try:
            proc.stdin.write(m["in"] + "\n")
            proc.stdin.flush()
        except BrokenPipeError:
            pass
    elif "kill" in m and proc is not None:
        proc.terminate()
    elif "quit" in m:
        break
if proc is not None:
    proc.kill()
