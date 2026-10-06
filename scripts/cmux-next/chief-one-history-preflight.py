#!/usr/bin/env python3
"""Preflight of one Chief history across builds and restarts (cmux-lawrence-2
only; plans/cmux-next/home-state-ownership.md). Two tagged builds share one
scratch Chief home (CMUX_NEXT_CHIEF_HOME) and take turns:

  1. build A sends a message; the Chief answers;
  2. A quits; build B shows the same conversation and history, and sends;
  3. engine switch: the host stops and B relaunches with MUX_HARNESS=codex;
     the history stays and the next message is answered on codex;
  4. B quits and relaunches (same history);
  5. the Chief owner daemon is stopped; the app reconnects (same history);
  6. reboot-equivalent: app, host, Chief owner and the Chief's acpmux all
     stop; A starts again (same history).

Each step saves debug.home JSON and a window snapshot. Only processes this
script started, or that run for its scratch Chief home, are stopped (by pid).

Usage: chief-one-history-preflight.py --app-a APP --tag-a TAG --app-b APP --tag-b TAG [--out DIR]
"""
import argparse, json, os, signal, socket, subprocess, sys, tempfile, time

ap = argparse.ArgumentParser()
ap.add_argument("--app-a", required=True)
ap.add_argument("--tag-a", required=True)
ap.add_argument("--app-b", required=True)
ap.add_argument("--tag-b", required=True)
ap.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "chief-one-history"))
ap.add_argument("--reply-wait", type=int, default=240)
opts = ap.parse_args()
os.makedirs(opts.out, exist_ok=True)
CHIEF = os.path.join(opts.out, "chief-home")
SCRATCH = tempfile.mkdtemp(prefix="onehist-")
CONFIG, GHOSTTY = os.path.join(SCRATCH, "cmux.json"), os.path.join(SCRATCH, "ghostty")
open(CONFIG, "w").write("{}")
open(GHOSTTY, "w").write("")
APPS = {"A": (opts.app_a, opts.tag_a), "B": (opts.app_b, opts.tag_b)}
summary = []


def rpc(tag, method, params=None):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30)
        conn.connect(f"/tmp/cmux-debug-{tag}.sock")
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def chief_row(home):
    rows = [c for c in (home or {}).get("conversations", []) if "agent_mux" in c.get("participants", [])]
    return rows[0] if rows else None


def texts(row):
    return [(m["author"], m["text"]) for m in (row or {}).get("shown_tail", [])]


def launch(which, extra=None):
    app, tag = APPS[which]
    sock = f"/tmp/cmux-debug-{tag}.sock"
    if os.path.exists(sock):
        os.unlink(sock)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,818,1060",
           "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY, "CMUX_NEXT_CHIEF_HOME": CHIEF}
    env.update(extra or {})
    binary = os.path.join(app, "Contents/MacOS", os.path.basename(app)[:-4])
    log = open(os.path.join(opts.out, f"app-{tag}.log"), "a")
    proc = subprocess.Popen([binary], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    ok = wait(lambda: (chief_row(rpc(tag, "debug.home")) or {}).get("id") and rpc(tag, "debug.home").get("chief_owner", {}).get("connected"), 180)
    print(f"launched {which} ({tag}) pid {proc.pid}: {'ready' if ok else 'NOT READY'}", flush=True)
    return proc


def step(name, which):
    tag = APPS[which][1]
    home = rpc(tag, "debug.home")
    json.dump(home, open(os.path.join(opts.out, f"{name}.json"), "w"), indent=2)
    print(name, "snapshot", rpc(tag, "debug.window_snapshot", {"path": os.path.join(opts.out, f"{name}.png")}), flush=True)
    row = chief_row(home)
    entry = {"step": name, "build": tag, "conversation": (row or {}).get("id"), "shown": texts(row),
             "owner": home.get("chief_owner")}
    summary.append(entry)
    return entry


def send(which, text):
    tag = APPS[which][1]
    print("drive", rpc(tag, "debug.home.drive", {"action": "focus"}), rpc(tag, "debug.home.drive", {"action": "type", "text": text}),
          rpc(tag, "debug.home.drive", {"action": "send"}), flush=True)
    def answered():
        shown = texts(chief_row(rpc(tag, "debug.home")))
        mine = [i for i, (a, t) in enumerate(shown) if t == text]
        return mine and any(a == "agent_mux" for a, _ in shown[mine[-1] + 1:])
    got = wait(answered, opts.reply_wait, 2)
    print(f"reply to {text!r}: {'yes' if got else 'NO REPLY within %ds' % opts.reply_wait}", flush=True)


def stop(proc):
    if proc and proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(20)
        except subprocess.TimeoutExpired:
            proc.kill()


def pid_of_lock(path):
    try:
        return int(open(path).read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def kill_pid(pid, what):
    if not pid:
        return
    try:
        os.kill(pid, signal.SIGTERM)
        print(f"stopped {what} pid {pid}", flush=True)
    except OSError as error:
        print(f"{what} pid {pid}: {error}", flush=True)
    wait(lambda: subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0, 20)


def stop_host():
    kill_pid(pid_of_lock(os.path.join(CHIEF, "state", "host.lock")), "Chief host")


def stop_owner(entry):
    kill_pid((entry.get("owner") or {}).get("daemon_pid"), "Chief owner daemon")


def stop_acpmux():
    sock = os.path.join(CHIEF, "acpmux", "acpmux.sock")
    out = subprocess.run(["lsof", "-t", sock], capture_output=True, text=True).stdout.split()
    for pid in sorted(set(out)):
        kill_pid(int(pid), "Chief acpmux daemon")


a = b = None
try:
    a = launch("A")
    step("01-a-start", "A")
    send("A", "one history check: message from build A")
    first = step("02-a-sent", "A")
    stop(a)
    b = launch("B")
    second = step("03-b-start", "B")
    send("B", "one history check: message from build B")
    step("04-b-sent", "B")
    # Engine switch: the next host runs codex turns on the same memory.
    stop_host()
    stop(b)
    b = launch("B", {"MUX_HARNESS": "codex"})
    step("05-b-codex-start", "B")
    send("B", "one history check: after switching the engine to codex")
    step("06-b-codex-sent", "B")
    stop(b)
    b = launch("B", {"MUX_HARNESS": "codex"})
    relaunch = step("07-b-relaunched", "B")
    stop_owner(relaunch)
    wait(lambda: rpc(APPS["B"][1], "debug.home").get("chief_owner", {}).get("connected")
         and rpc(APPS["B"][1], "debug.home").get("chief_owner", {}).get("daemon_pid") != relaunch["owner"].get("daemon_pid"), 120, 1)
    step("08-owner-restarted", "B")
    last = summary[-1]
    stop(b)
    stop_host()
    stop_owner(last)
    stop_acpmux()
    a = launch("A")
    step("09-after-reboot-equivalent", "A")
finally:
    stop(a)
    stop(b)
    json.dump(summary, open(os.path.join(opts.out, "summary.json"), "w"), indent=2)
    log = os.path.join(CHIEF, "optchat", "chat", "main")
    entries = []
    for name in sorted(os.listdir(log)) if os.path.isdir(log) else []:
        entries += [json.loads(line) for line in open(os.path.join(log, name)) if line.strip()]
    users = [e["text"] for e in sorted(entries, key=lambda e: e["i"]) if e["kind"] == "user"]
    print("memory user entries:", users)
    convs = {s["conversation"] for s in summary}
    print("conversations seen:", convs)
    for s in summary:
        print(s["step"], s["build"], len(s["shown"]), "shown;", [t for a, t in s["shown"] if a.startswith("user")])
