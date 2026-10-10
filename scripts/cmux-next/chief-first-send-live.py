#!/usr/bin/env python3
"""Live proof that the first Home send after a fresh start reaches the Chief once (cx-ebm.55; cmux-lawrence-2 only).

Each round starts from nothing: no Chief home (`~/.cmux/chief/isolated/<tag>`,
which holds the conversation owner's store, the brain's memory and acpmux),
no Home cache, no app. It launches the tagged app (no-activate, scratch
config), opens Home, and sends one message through the Home composer
(`debug.home.drive` focus, type, send) as soon as the composer exists, while
the Chief owner and the brain host are still starting. The round passes when
the drive accepts the send and the brain's log (`optchat/memory.sqlite3`)
holds that message exactly once within --deadline seconds. A round that
fails prints `debug.home` (store online, conversations, pending sends) and
what the conversation owner stored. Each round ends with quitEndSessions,
which ends the app, the Chief host, its acpmux and the owner daemon.

Prints one row per round and a total; exits 0 only when every round passed.

Usage: chief-first-send-live.py --tag <tag> --app PATH [--rounds 20] [--deadline 120] [--mode both] [--keep-cache] [--out DIR]
"""
import argparse, glob, json, os, shutil, signal, socket, sqlite3, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--rounds", type=int, default=20)
parser.add_argument("--deadline", type=float, default=120, help="seconds for the message to reach the brain's log")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--mode", choices=("immediate", "settled", "both"), default="both",
                    help="immediate: send as soon as the composer exists; settled: send as chief-subagents-live.py's"
                         " first ask does (the Chief conversation listed, the host connected, its tools socket up,"
                         " 10 s, window snapshots each second); both: alternate, odd rounds immediate")
parser.add_argument("--keep-cache", action="store_true",
                    help="keep the app's Home cache (~/Library/Caches/cmux-home/<owner>) between rounds, as a user's"
                         " Mac does when the Chief home is made again at the same path (cx-ebm.55); from round 2 on"
                         " the cache names the previous round's Chief conversation")
opts = parser.parse_args()

TAG = opts.tag
APP = opts.app
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
MUX_HOME = os.path.expanduser(f"~/.cmux/chief/isolated/{TAG}")
OPTCHAT = os.path.join(MUX_HOME, "optchat")
ACPMUX_HOME = os.path.join(MUX_HOME, "acpmux")
# The app's own acpmux for its tag (AcpmuxEnvironment: ~/.acpmux/tags/<slug>).
TAG_ACPMUX_HOME = os.path.expanduser(f"~/.acpmux/tags/{TAG}")
SCRATCH = tempfile.mkdtemp(prefix=f"chief-first-send-{TAG}-")
os.makedirs(opts.out, exist_ok=True)


def rpc(method, params=None, timeout=30):
    """One request on the tagged app's control socket."""
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


def wait(predicate, seconds, step=0.25):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def sqlite_rows(path, query, args=()):
    if not os.path.exists(path):
        return []
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
        try:
            return db.execute(query, args).fetchall()
        finally:
            db.close()
    except sqlite3.Error:
        return []


def logged(text):
    """How many user items of the brain's log hold `text`."""
    rows = sqlite_rows(os.path.join(OPTCHAT, "memory.sqlite3"), "SELECT kind, text FROM messages ORDER BY id")
    return sum(1 for kind, body in rows if kind == "user" and text in body)


def owner_messages():
    """The conversation owner's stored messages (seq, author, text head), for a failed round."""
    found = []
    for path in glob.glob(os.path.join(MUX_HOME, "tui", "*", "conversations.sqlite3")):
        for conversation, seq, body in sqlite_rows(path, "SELECT conversation, seq, message_json FROM message ORDER BY conversation, seq"):
            try:
                message = json.loads(body)
            except ValueError:
                continue
            text = " ".join(p.get("text", "") for p in message.get("parts", []) if isinstance(p, dict))
            found.append({"conversation": conversation, "seq": seq, "author": message.get("author"), "text": text[:80]})
    return found


def host_log_tail():
    try:
        return open(os.path.join(MUX_HOME, "host.log"), errors="replace").read()[-2000:]
    except OSError:
        return ""


def launch(env, log):
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    up = wait(lambda: (rpc("debug.windows") or {}).get("windows"), 300, step=0.5)
    return app, bool(up)


def end_round(app, cache):
    """Quit, end sessions: the app, the Chief host, its acpmux and the owner daemon end."""
    rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        print(f"app {app.pid} did not quit; SIGKILL", flush=True)
        os.kill(app.pid, signal.SIGKILL)
        app.wait(timeout=10)
    env = {**os.environ, "ACPMUX_HOME": ACPMUX_HOME, "ACPMUX_SOCKET": os.path.join(ACPMUX_HOME, "acpmux.sock")}
    subprocess.run([ACPMUX, "daemon", "shutdown"], env=env, capture_output=True, timeout=30)
    tag_env = {k: v for k, v in os.environ.items() if not k.startswith("ACPMUX_")}
    tag_env["ACPMUX_HOME"] = TAG_ACPMUX_HOME
    subprocess.run([ACPMUX, "daemon", "shutdown"], env=tag_env, capture_output=True, timeout=30)
    # Each acpmux daemon starts a detached local router (its own session); it stops on its admin socket.
    for home in (TAG_ACPMUX_HOME, ACPMUX_HOME):
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5)
            conn.connect(os.path.join(home, "router", "router.sock"))
            conn.sendall(b'{"op":"shutdown"}\n')
            conn.recv(4096)
            conn.close()
        except OSError:
            pass
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    if cache and not opts.keep_cache:
        shutil.rmtree(os.path.dirname(cache), ignore_errors=True)


def chief_listed():
    home = rpc("debug.home") or {}
    return any("agent_mux" in c.get("participants", []) for c in home.get("conversations", []))


def settle(n, stop):
    """What chief-subagents-live.py does before its first ask; returns the recorder thread."""
    wait(chief_listed, 180, step=1)
    wait(lambda: "daemon connected" in host_log_tail() and os.path.exists(os.path.join(OPTCHAT, "tools.sock")), 180, step=1)
    time.sleep(10)  # test harness: the compactor start-up probe, as the subagent proof waits

    def record():
        frames = os.path.join(opts.out, f"frames-{n:02d}")
        os.makedirs(frames, exist_ok=True)
        k = 0
        while not stop.is_set():
            rpc("debug.window_snapshot", {"path": os.path.join(frames, f"frame-{k:05d}.png")}, timeout=10)
            k += 1
            stop.wait(1.0)
    recorder = threading.Thread(target=record, daemon=True)
    recorder.start()
    rpc("action.run", {"id": "home.show"})
    wait(lambda: (rpc("debug.home.drive", {"action": "geometry"}) or {}).get("ok"), 20)
    return recorder


def home_state():
    """debug.home's store and Chief rows, short: what the Home view had at the send."""
    home = rpc("debug.home") or {}
    owner = home.get("chief_owner") or {}
    chiefs = [{"id": c.get("id"), "shown": c.get("shown_count"), "pending": c.get("pending")}
              for c in home.get("conversations", []) if "agent_mux" in c.get("participants", [])]
    return {"store_online": owner.get("store_online"), "connected": owner.get("connected"), "chief": chiefs,
            "page": json.dumps(home.get("page"))[:300]}


def one_round(n, env):
    shutil.rmtree(MUX_HOME, ignore_errors=True)
    settled = opts.mode == "settled" or (opts.mode == "both" and n % 2 == 0)
    stop = threading.Event()
    text = f"first-send probe {TAG} round {n}: reply with only the word ok."
    log = open(os.path.join(opts.out, f"app-{TAG}-{n:02d}.log"), "w")
    started = time.time()
    app, up = launch(env, log)
    cache = None
    try:
        if not up:
            return False, "the app's control socket never answered", None
        rpc("action.run", {"id": "home.show"})
        # Send as soon as the composer exists: the owner and the brain host may still be starting.
        if not wait(lambda: (rpc("debug.home.drive", {"action": "geometry"}) or {}).get("ok"), 120):
            return False, f"no Home composer: {json.dumps(rpc('debug.home'))[:600]}", None
        if settled:
            settle(n, stop)
        shown_at = time.time() - started
        before = home_state()
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"round-{n:02d}-before-send.png")}, timeout=10)
        drive = {}
        for action, extra in (("focus", {}), ("type", {"text": text}), ("send", {})):
            drive = rpc("debug.home.drive", {"action": action, **extra}) or {}
            if not drive.get("ok"):
                break
        sent_at = time.time() - started
        home = rpc("debug.home") or {}
        cache = (home.get("chief_owner") or {}).get("cache")
        if not drive.get("ok"):
            return False, f"send refused at {sent_at:.1f}s: {json.dumps(drive)[:300]}; at the send {json.dumps(before)}; debug.home {json.dumps(home)[:1500]}", cache
        count = wait(lambda: logged(text), opts.deadline, step=0.5) or 0
        if count:
            time.sleep(3)  # test harness: a duplicate would follow within the same catch-up
            count = logged(text)
        reached_at = time.time() - started
        home = rpc("debug.home") or {}
        cache = (home.get("chief_owner") or {}).get("cache") or cache
        detail = (f"{'settled' if settled else 'immediate'}: composer {shown_at:.1f}s, send {sent_at:.1f}s, "
                  f"in the brain's log x{count} by {reached_at:.1f}s; at the send {json.dumps(before)}")
        if count == 1:
            return True, detail, cache
        return False, (f"{detail}; owner stored {json.dumps(owner_messages())[:800]}; "
                       f"debug.home {json.dumps(home)[:1500]}; host.log tail {host_log_tail()[-800:]!r}"), cache
    finally:
        stop.set()
        end_round(app, cache)
        log.close()


def main():
    if os.path.exists(SOCKET):
        sys.exit(f"{SOCKET} exists: another {TAG} app runs; pick a fresh tag")
    config = os.path.join(SCRATCH, "cmux.json")
    open(config, "w").write("{}")
    open(os.path.join(SCRATCH, "ghostty"), "w").write("")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900",
           # Model traffic only through the team subrouter (claude-sr).
           "MUX_HARNESS": os.environ.get("MUX_HARNESS", "claude-sr")}
    # The subrouter route of this host's login shell (run under `zsh -lic`); values pass through, never printed.
    for name in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "SUBROUTER_URL"):
        if os.environ.get(name):
            env[name] = os.environ[name]
    results = []
    for n in range(1, opts.rounds + 1):
        try:
            ok, detail, _ = one_round(n, env)
        except Exception as error:  # report, keep going
            ok, detail = False, f"raised {error!r}"
        results.append({"round": n, "ok": ok, "detail": detail})
        print(f"| first send, fresh start, round {n} | in the brain's log exactly once | {detail} | {'pass' if ok else 'FAIL'} |",
              flush=True)
    json.dump(results, open(os.path.join(opts.out, "first-send-rows.json"), "w"), indent=1)
    lost = sum(1 for r in results if not r["ok"])
    print(f"{len(results) - lost}/{len(results)} pass, {lost} lost or duplicated", flush=True)
    sys.exit(0 if lost == 0 else 1)


if __name__ == "__main__":
    main()
