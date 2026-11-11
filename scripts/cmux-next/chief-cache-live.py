#!/usr/bin/env python3
"""Live proof that short warm Chief turns read >= --min-hit percent of their first request from the
prompt cache in the real tagged app (cx-4a5w2; cmux-lawrence-2 only, real model through the subrouter).

The fleet guard (scripts/ci/chief-first-turn-cost.sh real=1) runs the brain with only acpmux and
cmux in its bin folder. The app's bundle also has cmux-cua, so its Chief turns got the computer
use, secret and offer MCP servers, whose tool names and instructions Claude Code puts after the
turn's cache mark: 2,905 uncached tokens per turn and about 70% read from the cache (dogfood pass 2,
2026-10-16), against about 90% in the fleet guard.

It starts from no Chief home (`~/.cmux/chief/isolated/<tag>`), launches the tagged app (no-activate,
scratch config), opens Home and sends --turns short messages through the Home composer, one at a
time, each after the last turn's usage line. It reads the brain's host.log lines
"turn ... cache: first request read R written W uncached U" and computes R / (R + W + U) of each
turn's first request. Every turn after the first must reach --min-hit. It also prints the deferred
MCP tool servers of the turns' Claude Code transcripts, for a failed run. Ends with quitEndSessions,
acpmux shutdown and the tag's daemon stop.

Usage: chief-cache-live.py --tag <tag> --app PATH [--turns 5] [--min-hit 87] [--out DIR]
Submit the nx-remote job with --allow-agents, under `zsh -lic` (the subrouter route).
"""
import argparse, glob, json, os, re, shutil, signal, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--turns", type=int, default=5)
parser.add_argument("--min-hit", type=float, default=87.0,
                    help="percent of a warm turn's first request read from the cache (hq-6d 2026-10-16: 87 with the"
                         " live Home block after the cache mark, about 1,170 uncached tokens; 90 needs the block in the"
                         " cached delta, cx-4a5w2)")
parser.add_argument("--turn-deadline", type=float, default=180)
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
if os.environ.get("ACPMUX_AGENT_LAUNCH", "").strip().lower() == "deny" or os.environ.get("CMUX_AGENTS_DISABLED", "").strip() == "1":
    sys.exit("chief-cache-live.py: this Chief proof needs agents; submit the job with `nx-remote --allow-agents`")

TAG = opts.tag
APP = opts.app
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
MUX_HOME = os.path.expanduser(f"~/.cmux/chief/isolated/{TAG}")
OPTCHAT = os.path.join(MUX_HOME, "optchat")
ACPMUX_HOME = os.path.join(MUX_HOME, "acpmux")
TAG_ACPMUX_HOME = os.path.expanduser("~/.acpmux/builds/com.cmuxterm.app.debug." + re.sub(r"[^a-z0-9]+", ".", TAG.lower()).strip("."))
SCRATCH = tempfile.mkdtemp(prefix=f"chief-cache-{TAG}-")
USAGE = re.compile(r"turn (\S+) cache: first request read (\d+) written (\d+) uncached (\d+)")
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


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def host_log():
    try:
        return open(os.path.join(MUX_HOME, "host.log"), errors="replace").read()
    except OSError:
        return ""


def usages():
    return [(m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))) for m in USAGE.finditer(host_log())]


def chief_listed():
    home = rpc("debug.home") or {}
    return any("agent_mux" in c.get("participants", []) for c in home.get("conversations", []))


def deferred_servers(since):
    """MCP servers of the deferred tool names in this tag's Chief turn transcripts (Claude Code)
    written since `since` (Claude Code's project folder name: every character not [A-Za-z0-9] is -)."""
    found = {}
    folder = re.sub(r"[^A-Za-z0-9]", "-", os.path.join(OPTCHAT, "session"))
    for path in glob.glob(os.path.expanduser(f"~/.claude/projects/{folder}/*.jsonl")):
        if os.path.getmtime(path) < since:
            continue
        for line in open(path, errors="replace"):
            try:
                attachment = json.loads(line).get("attachment") or {}
            except ValueError:
                continue
            if attachment.get("type") != "deferred_tools_delta":
                continue
            for name in attachment.get("addedNames", []):
                server = name.split("__")[1] if name.startswith("mcp__") else "built-in"
                found[server] = found.get(server, 0) + 1
    return found


def end_run(app):
    """Quit, end sessions: the app, the Chief host, its acpmux and the owner daemon end."""
    rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        print(f"app {app.pid} did not quit; SIGKILL", flush=True)
        os.kill(app.pid, signal.SIGKILL)
        app.wait(timeout=10)
    env = {**os.environ, "ACPMUX_HOME": ACPMUX_HOME, "ACPMUX_SOCKET": os.path.join(ACPMUX_HOME, "acpmux.sock")}
    subprocess.run([ACPMUX, "daemon", "shutdown", "--end-agents"], env=env, capture_output=True, timeout=30)
    tag_env = {k: v for k, v in os.environ.items() if not k.startswith("ACPMUX_")}
    tag_env["ACPMUX_HOME"] = TAG_ACPMUX_HOME
    subprocess.run([ACPMUX, "daemon", "shutdown", "--end-agents"], env=tag_env, capture_output=True, timeout=30)
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


def send(text):
    for action, extra in (("focus", {}), ("type", {"text": text}), ("send", {})):
        drive = rpc("debug.home.drive", {"action": action, **extra}) or {}
        if not drive.get("ok"):
            return drive
    return {"ok": True}


def main():
    if os.path.exists(SOCKET):
        sys.exit(f"{SOCKET} exists: another {TAG} app runs; pick a fresh tag")
    shutil.rmtree(MUX_HOME, ignore_errors=True)
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
    for name in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "SUBROUTER_URL"):
        if os.environ.get(name):
            env[name] = os.environ[name]
    log = open(os.path.join(opts.out, f"app-{TAG}.log"), "w")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    failures = []
    started = time.time()
    start = 0
    try:
        if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 300):
            sys.exit("the app's control socket never answered")
        rpc("action.run", {"id": "home.show"})
        if not wait(lambda: (rpc("debug.home.drive", {"action": "geometry"}) or {}).get("ok"), 240):
            sys.exit(f"no Home composer: {json.dumps(rpc('debug.home'))[:600]}")
        wait(chief_listed, 180, step=1)
        wait(lambda: "daemon connected" in host_log() and os.path.exists(os.path.join(OPTCHAT, "tools.sock")), 180, step=1)
        # Only this probe's turns count: one the brain started on its own before is left out.
        start = len(usages())
        for n in range(1, opts.turns + 1):
            before = len(usages())
            drive = send(f"cache probe {TAG} turn {n}: reply with only the word ok{n}.")
            if not drive.get("ok"):
                failures.append(f"turn {n}: send refused {json.dumps(drive)[:300]}")
                break
            if not wait(lambda: len(usages()) > before, opts.turn_deadline):
                failures.append(f"turn {n}: no usage line in {opts.turn_deadline:.0f}s; host.log tail {host_log()[-800:]!r}")
                break
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"cache-{TAG}-home.png")}, timeout=10)
    finally:
        rows = usages()[start:]
        servers = deferred_servers(started)
        end_run(app)
        log.close()
        shutil.rmtree(SCRATCH, ignore_errors=True)
        try:
            shutil.copy(os.path.join(MUX_HOME, "host.log"), os.path.join(opts.out, f"host-{TAG}.log"))
        except OSError:
            pass
    turns = []
    for index, (turn, read, written, uncached) in enumerate(rows):
        hit = 100.0 * read / max(1, read + written + uncached)
        warm = index > 0
        ok = not warm or hit >= opts.min_hit
        turns.append({"turn": turn, "read": read, "written": written, "uncached": uncached, "hit": round(hit, 1), "warm": warm})
        print(f"| {turn} | {'warm' if warm else 'first'} | read {read} written {written} uncached {uncached} | "
              f"{hit:.1f}% | {'pass' if ok else 'FAIL'} |", flush=True)
        if not ok:
            failures.append(f"{turn} read {hit:.1f}% from the cache, under {opts.min_hit:g}% (uncached {uncached})")
    if len(rows) < 2:
        failures.append(f"only {len(rows)} turn usage lines; no warm turn to check")
    print("CHIEF-CACHE-DEFERRED-SERVERS " + json.dumps(servers, sort_keys=True), flush=True)
    json.dump({"turns": turns, "deferred_servers": servers, "failures": failures},
              open(os.path.join(opts.out, "chief-cache.json"), "w"), indent=1)
    for failure in failures:
        print("FAIL " + failure, flush=True)
    print("CHIEF-CACHE " + ("PASS" if not failures else "FAIL"), flush=True)
    sys.exit(0 if not failures else 1)


if __name__ == "__main__":
    main()
