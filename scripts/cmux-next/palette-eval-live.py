#!/usr/bin/env python3
"""Live palette-ranking evidence from a tagged cmux DEV build
(plans/cmux-next/palette-ranking.md).

Launches the tagged app headless (no activation, bounded window), then:
  1. writes the root palette's ranker input (debug.palette.entries) to OUT/root-entries.json,
     the source of webviews/test/fixtures/palette-eval/root-entries.json;
  2. runs palette.query for every query of the eval cases and writes OUT/live-results.json
     (score them with `bun webviews/scripts/palette-eval.ts --live OUT/live-results.json`);
  3. opens the palette with each --shot query and captures it (debug.palette.capture) to
     OUT/shot-<n>-<slug>.png.
Then quits with debug.quit fixture_quit end-sessions and stops the tag's daemons. Kills only the PID it started.

Usage: palette-eval-live.py TAG APP OUT_DIR CASES_JSON [--shot QUERY ...]
"""
import json, os, pwd, re, signal, socket, subprocess, sys, tempfile, time

TAG, APP, OUT, CASES = sys.argv[1:5]
SHOTS = []
rest = sys.argv[5:]
while rest:
    flag = rest.pop(0)
    if flag == "--shot" and rest:
        SHOTS.append(rest.pop(0))
    else:
        sys.exit("unknown argument %s" % flag)

BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
SOCKET = "/tmp/cmux-debug-%s.sock" % TAG
ACCOUNT_HOME = pwd.getpwuid(os.getuid()).pw_dir
ACPMUX_HOME = os.path.join(ACCOUNT_HOME, ".cmux/chief/isolated", TAG, "acpmux")
os.makedirs(OUT, exist_ok=True)


def rpc(method, params=None, timeout=30):
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(timeout)
        c.connect(SOCKET)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close()
        r = json.loads(buf)
        return r.get("result") if r.get("ok") else {"error": r.get("error")}
    except (OSError, ValueError) as e:
        return {"error": str(e)}


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "empty"


cases = json.load(open(CASES))
queries = []
for case in cases["cases"]:
    if case["query"] not in queries:
        queries.append(case["query"])

if os.path.exists(SOCKET):
    sys.exit("%s exists: pick a fresh tag" % SOCKET)
scratch = tempfile.mkdtemp(prefix="palette-eval-")
open(os.path.join(scratch, "cmux.json"), "w").write("{}")
open(os.path.join(scratch, "ghostty"), "w").write("")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"),
       "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(scratch, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
log = open(os.path.join(OUT, "app-%s.log" % TAG), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
print("launched pid %d" % app.pid, flush=True)
rc = 1
try:
    deadline = time.time() + 180
    wins = None
    while time.time() < deadline:
        if os.path.exists(SOCKET):
            wins = (rpc("debug.windows") or {}).get("windows")
            if wins:
                break
        if app.poll() is not None:
            break
        time.sleep(0.5)
    if not wins:
        sys.exit("no window")
    time.sleep(3)  # let providers (settings, apps) publish their first rows
    print("entries:", json.dumps(rpc("debug.palette.entries", {"path": os.path.join(OUT, "root-entries.json")}, timeout=60)),
          flush=True)
    results = {}
    for query in queries:
        reply = rpc("palette.query", {"scope": "root", "query": query, "limit": 10}, timeout=30)
        results[query] = [{"id": item["id"], "title": item["title"], "section": item.get("section"), "score": item["score"]}
                          for item in (reply or {}).get("items", [])] if "items" in (reply or {}) else reply
    json.dump({"tag": TAG, "results": results}, open(os.path.join(OUT, "live-results.json"), "w"), indent=1)
    print("live queries: %d" % len(results), flush=True)
    for n, query in enumerate(SHOTS):
        opened = rpc("action.run", {"action": "palette.open", "args": {"query": query}, "focus": True}, timeout=20)
        time.sleep(1.5)
        path = os.path.join(OUT, "shot-%d-%s.png" % (n, slug(query)))
        shot = rpc("debug.palette.capture", {"path": path}, timeout=30)
        print("shot %r: open=%s capture=%s" % (query, json.dumps(opened)[:120], json.dumps(shot)[:160]), flush=True)
        rpc("debug.key", {"key": "escape"}, timeout=10)
        time.sleep(0.5)
    rc = 0
finally:
    print("quit:", json.dumps(rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10))[:200], flush=True)
    try:
        app.wait(timeout=30)
        print("app exited %s" % app.returncode, flush=True)
    except subprocess.TimeoutExpired:
        print("app did not quit in 30s; SIGKILL pid %d" % app.pid, flush=True)
        os.kill(app.pid, signal.SIGKILL)
    subprocess.run([ACPMUX, "daemon", "shutdown"], env={**os.environ, "ACPMUX_HOME": ACPMUX_HOME,
                   "ACPMUX_SOCKET": os.path.join(ACPMUX_HOME, "acpmux.sock")}, capture_output=True, timeout=30)
    subprocess.run([CLI, "server", "stop", "--session", "cmux-app-%s" % TAG, "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
sys.exit(rc)
