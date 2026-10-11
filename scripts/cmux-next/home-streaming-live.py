#!/usr/bin/env python3
"""Live proof that Home shows the Chief's reply while it is written (cmux-lawrence-2, GUI lane).

Launches the tagged app (no-activate, scratch config, an isolated Chief home),
sends one Home message through the composer (`debug.home.drive`) that asks
for about 250 words, and then, until the reply is posted:
- takes a window snapshot every 0.5 s (`debug.window_snapshot`) into OUT,
  each named with its time since the send;
- reads `debug.home` every 0.25 s: the Chief conversation's live draft
  (`draft`, when the app reports one), its typing state and its posted tail.
Prints the time of the first visible draft text, how it grew, and the time
the reply was posted, and writes OUT/timeline.json.

On exit it quits the app with quitEndSessions, shuts down the tag's acpmux
daemon and stops this tag's cmux-tui sessions by name. It ends only the app
process it started.

Usage (under `zsh -lic`, for the subrouter route):
  home-streaming-live.py --tag <tag> --app <path to cmux DEV <tag>.app> --out DIR
"""
import argparse, json, os, shutil, signal, socket, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--timeout", type=float, default=300)
opts = parser.parse_args()

TAG = opts.tag
APP = opts.app
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
MUX_HOME = os.path.expanduser(f"~/.cmux/chief/isolated/{TAG}")
SCRATCH = tempfile.mkdtemp(prefix=f"home-streaming-{TAG}-")
PROMPT = "Write about 250 words on why tests should run at product boundaries. Plain prose, no lists."
os.makedirs(opts.out, exist_ok=True)
app = None


def fnv1a32(text):
    h = 0x811C9DC5
    for b in text.encode():
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return f"{h:08x}"


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
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


def wait(predicate, seconds, step=1.0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def chief_row():
    home = rpc("debug.home") or {}
    return next((c for c in home.get("conversations", []) if "agent_mux" in c.get("participants", [])), None)


def host_log():
    try:
        return open(os.path.join(MUX_HOME, "host.log"), errors="replace").read()
    except OSError:
        return ""


def stop_sessions():
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    for session in (f"cmux-app-{TAG}", f"cmux-chief-{fnv1a32(MUX_HOME)}"):
        subprocess.run([CLI, "server", "stop", "--session", session, "--end-terminals"],
                       env=env, capture_output=True, timeout=60)


def cleanup():
    rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    subprocess.run([ACPMUX, "daemon", "shutdown"], env={**os.environ, "ACPMUX_HOME": os.path.join(MUX_HOME, "acpmux")},
                   capture_output=True, timeout=60)
    stop_sessions()


def main():
    global app
    if os.path.exists(SOCKET):
        if "error" not in (rpc("debug.windows", timeout=3) or {"error": 1}):
            sys.exit(f"{SOCKET} answers: another {TAG} app runs; pick a fresh tag")
        os.unlink(SOCKET)  # left by an ended run of this tag: nothing listens
    stop_sessions()
    cache = os.path.expanduser(f"~/Library/Caches/cmux-home/cmux-chief-{fnv1a32(MUX_HOME)}")
    if os.path.isdir(cache):
        shutil.rmtree(cache)
    config = os.path.join(SCRATCH, "cmux.json")
    open(config, "w").write("{}")
    open(os.path.join(SCRATCH, "ghostty"), "w").write("")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900", "MUX_HARNESS": os.environ.get("MUX_HARNESS", "claude-sr")}
    for name in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "SUBROUTER_URL"):
        if os.environ.get(name):
            env[name] = os.environ[name]
    log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 600):
        sys.exit("the tagged app did not come up")
    rpc("action.run", {"id": "home.show"})
    wait(lambda: (rpc("debug.home.drive", {"action": "geometry"}) or {}).get("ok"), 20)
    if not wait(chief_row, 180):
        sys.exit(f"no Chief conversation: {json.dumps(rpc('debug.home'))[:600]}")
    if not wait(lambda: "daemon connected" in host_log(), 180):
        sys.exit("the Chief host did not connect")
    # A warm-up turn, so the measured turn does not include the session start.
    for action, extra in (("focus", {}), ("type", {"text": "Reply with one word: READY."}), ("send", {})):
        rpc("debug.home.drive", {"action": action, **extra})
    wait(lambda: any("READY" in (m.get("text") or "") and m.get("author") == "agent_mux"
                     for m in (chief_row() or {}).get("shown_tail", [])), 180, step=1)
    time.sleep(3)

    stop = threading.Event()
    t0 = time.time()
    samples = []

    def snapshots():
        k = 0
        while not stop.is_set():
            at = time.time() - t0
            rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"frame-{k:03d}-{at:06.2f}s.png")}, timeout=10)
            k += 1
            stop.wait(max(0.0, 0.5 - ((time.time() - t0) - at)))

    def reads():
        while not stop.is_set():
            row = chief_row() or {}
            draft = row.get("draft") or {}
            tail = [m for m in row.get("shown_tail", []) if m.get("author") == "agent_mux"]
            samples.append({"t": round(time.time() - t0, 3), "typing": "agent_mux" in row.get("typing", []),
                            "draft_chars": len(draft.get("text") or ""), "posted": len(tail),
                            "last_posted": (tail[-1].get("text") or "")[:60] if tail else ""})
            stop.wait(0.25)

    posted_before = len([m for m in (chief_row() or {}).get("shown_tail", []) if m.get("author") == "agent_mux"])
    threads = [threading.Thread(target=snapshots, daemon=True), threading.Thread(target=reads, daemon=True)]
    for thread in threads:
        thread.start()
    for action, extra in (("focus", {}), ("type", {"text": PROMPT}), ("send", {})):
        rpc("debug.home.drive", {"action": action, **extra})
    wait(lambda: samples and samples[-1]["posted"] > posted_before, opts.timeout, step=0.25)
    time.sleep(2)
    stop.set()
    for thread in threads:
        thread.join(timeout=15)
    first_draft = next((s["t"] for s in samples if s["draft_chars"] > 0), None)
    first_typing = next((s["t"] for s in samples if s["typing"]), None)
    posted = next((s["t"] for s in samples if s["posted"] > posted_before), None)
    growth = [(s["t"], s["draft_chars"]) for s in samples if s["draft_chars"] > 0]
    result = {"first_typing_s": first_typing, "first_draft_text_s": first_draft, "reply_posted_s": posted,
              "draft_samples": len(growth), "draft_growth": growth[:: max(1, len(growth) // 12)],
              "frames": len([f for f in os.listdir(opts.out) if f.startswith("frame-")])}
    json.dump({"result": result, "samples": samples}, open(os.path.join(opts.out, "timeline.json"), "w"), indent=1)
    print(json.dumps(result, indent=1), flush=True)


if __name__ == "__main__":
    try:
        main()
    finally:
        cleanup()
