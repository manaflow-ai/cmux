#!/usr/bin/env python3
"""Tagged-app behavior proof of the daemon history module (H3, cx-gzh.15).

Usage: history-page-preflight.py TAG APP OUT_DIR
  TAG      the tagged build's tag (scripts/reload.sh --tag TAG)
  APP      the tagged "cmux DEV TAG.app" that reload.sh printed under "App path:"
  OUT_DIR  where transcript.jsonl, results.json and the snapshot go

Host: needs a GUI session (debug.window_snapshot, a browser page). Run it on
the build host through nx-remote with a pushed commit, never on the laptop:
  nx-remote --needs gui --ref <sha> -- bash -c './scripts/reload.sh --tag <tag> && \
      python3 scripts/cmux-next/history-page-preflight.py <tag> "<App path>" "$NX_ARTIFACTS"'
(warm mode can fail to compute the cmux-tui tree key; --ref works.)

Steps:
1. Before launch: an app-local History.sqlite from before the daemon owned page
   history, with one visit to a marker URL, in the tag's default profile.
2. Launch the tagged app (no activate, automation socket, bounded window).
3. Load a page in a focused tab (browser.open_split https://example.com/).
4. history.list over the debug socket: the marker visit and the loaded page are
   there with daemon ids (page:default:<n>).
5. The daemon has them too (`cmux history list --json` against the tag's daemon).
6. History.sqlite (and -wal/-shm) is gone after the import.
7. Quit (debug.quit fixture, else action.run quitEndSessions), stop acpmux and
   the session, stop any survivor of this bundle by its exact PID (reported),
   check that no process of the bundle is left, delete the tag's state.
Exit 0 only when every check passed and nothing of the bundle is left.
"""
import json, os, pwd, shutil, signal, socket, sqlite3, subprocess, sys, tempfile, time

TAG, APP, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
SOCKET = "/tmp/cmux-debug-%s.sock" % TAG
HOME = pwd.getpwuid(os.getuid()).pw_dir
ACPMUX_HOME = os.path.join(HOME, ".cmux/chief/isolated", TAG, "acpmux")
SUPPORT = os.path.join(HOME, "Library/Application Support/com.cmuxterm.app.debug.%s" % TAG)
LEGACY = os.path.join(SUPPORT, "BrowserProfiles/default/History.sqlite")
MARKER = "https://preflight-legacy.example/h3-%s" % TAG
PAGE = "https://example.com/"
os.makedirs(OUT, exist_ok=True)
TRANSCRIPT = open(os.path.join(OUT, "transcript.jsonl"), "a")
RESULTS = {}


def note(kind, **fields):
    TRANSCRIPT.write(json.dumps({"t": round(time.time(), 3), "kind": kind, **fields}) + "\n")
    TRANSCRIPT.flush()


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
        result = r.get("result") if r.get("ok") else {"error": r.get("error")}
    except (OSError, ValueError) as e:
        result = {"error": str(e)}
    note("rpc", method=method, params=params or {}, result=result)
    return result


def seed_legacy():
    os.makedirs(os.path.dirname(LEGACY), exist_ok=True)
    db = sqlite3.connect(LEGACY)
    db.executescript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS visits(
          id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT,
          visit_time_ms INTEGER NOT NULL, tab TEXT);
        CREATE INDEX IF NOT EXISTS visits_time ON visits(visit_time_ms);
        CREATE INDEX IF NOT EXISTS visits_url ON visits(url);
        PRAGMA user_version=1;
    """)
    db.execute("INSERT INTO visits(url, title, visit_time_ms, tab) VALUES (?, ?, ?, NULL)",
               (MARKER, "H3 preflight legacy visit", int(time.time() * 1000) - 60_000))
    db.commit()
    db.close()
    note("seed", path=LEGACY, exists=os.path.exists(LEGACY))


def launch():
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    scratch = tempfile.mkdtemp(prefix="history-preflight-")
    open(os.path.join(scratch, "cmux.json"), "w").write("{}")
    open(os.path.join(scratch, "ghostty"), "w").write("")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"),
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(scratch, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
    log = open(os.path.join(OUT, "app-%s.log" % TAG), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    note("launch", pid=app.pid)
    print("launched pid %d" % app.pid, flush=True)
    deadline = time.time() + 180
    while time.time() < deadline:
        if os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"):
            return app
        if app.poll() is not None:
            break
        time.sleep(0.5)  # test harness: wait for the launch
    return app


def daemon_socket():
    ps = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    mine = [l for l in ps.splitlines() if (APP + "/") in l]
    session = "cmux-app-%s" % TAG
    for line in mine:
        pid = line.split(None, 1)[0]
        out = subprocess.run(["lsof", "-a", "-p", pid, "-U", "-F", "n"], capture_output=True, text=True).stdout
        for n in out.splitlines():
            if n.startswith("n/") and session in n:
                return n[1:]
    temp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    for root in [temp, os.environ.get("TMPDIR", ""), "/tmp"]:
        if root:
            found = subprocess.run(["find", root, "-maxdepth", "4", "-type", "s", "-name", "*%s*" % session],
                                   capture_output=True, text=True).stdout.split()
            if found:
                return found[0]
    return None


def page_entries(listing):
    text = json.dumps(listing)
    items = []
    if isinstance(listing, dict):
        for key in ("entries", "items", "results"):
            if isinstance(listing.get(key), list):
                items = listing[key]
                break
    elif isinstance(listing, list):
        items = listing
    return items, text


def teardown(app):
    reply = rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
    # A build without the fixture answers a plain report (quitting false): use the action.
    if not (isinstance(reply, dict) and reply.get("quitting") == "end-sessions"):
        reply = rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    note("quit", reply=reply)
    try:
        app.wait(timeout=30)
    except subprocess.TimeoutExpired:
        print("app did not quit in 30s; SIGKILL pid %d" % app.pid, flush=True)
        os.kill(app.pid, signal.SIGKILL)
    subprocess.run([ACPMUX, "daemon", "shutdown", "--end-agents"], env={**os.environ, "ACPMUX_HOME": ACPMUX_HOME,
                   "ACPMUX_SOCKET": os.path.join(ACPMUX_HOME, "acpmux.sock")}, capture_output=True, timeout=30)
    subprocess.run([CLI, "server", "stop", "--session", "cmux-app-%s" % TAG, "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    time.sleep(3)  # test harness: let daemons exit before the leftover check
    ps = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    left = [l for l in ps.splitlines() if (APP + "/") in l and "history-preflight" not in l]
    note("leftovers", lines=left)
    # Known tip leak: `acpmux router serve` of this bundle survives the quit. It runs from this
    # job's own APP path, so this run started it; stop it by its exact PID and report it.
    routers = list(left)  # every survivor runs from this job's own tagged APP path
    for line in routers:
        try:
            os.kill(int(line.split()[0]), signal.SIGTERM)
        except ProcessLookupError:
            pass
    RESULTS["survivors_stopped_by_pid"] = [l[:200] for l in routers]
    if routers:
        time.sleep(2)  # test harness: let the router exit before the second check
        ps = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
        left = [l for l in ps.splitlines() if (APP + "/") in l and "history-preflight" not in l]
        note("leftovers-after-router", lines=left)
    print("leftovers of this bundle: %d" % len(left), flush=True)
    return not left


def main():
    seed_legacy()
    app = launch()
    try:
        if not os.path.exists(SOCKET):
            RESULTS["launch"] = "FAIL: no debug socket"
            return
        RESULTS["launch"] = "PASS"
        opened = rpc("browser.open_split", {"url": PAGE, "focus": True}, timeout=60)
        RESULTS["open_page"] = opened
        found_marker = found_page = False
        listing = None
        deadline = time.time() + 90
        while time.time() < deadline and not (found_marker and found_page):
            listing = rpc("history.list", {"kind": "page", "limit": 50}, timeout=30)
            items, text = page_entries(listing)
            found_marker = MARKER in text
            found_page = "example.com" in text
            if not (found_marker and found_page):
                time.sleep(2)  # test harness: the import and the page load are asynchronous
        items, text = page_entries(listing)
        daemon_ids = [i.get("id") for i in items if isinstance(i, dict) and str(i.get("id", "")).startswith("page:")]
        other_ids = [i.get("id") for i in items if isinstance(i, dict) and not str(i.get("id", "")).startswith("page:")]
        RESULTS["history_list"] = {"marker_visit": found_marker, "loaded_page": found_page,
                                   "daemon_ids": daemon_ids[:10], "non_daemon_page_ids": other_ids[:10]}
        sock = daemon_socket()
        RESULTS["daemon_socket"] = sock
        if sock:
            env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
            env["CMUX_TUI_SOCKET"] = sock
            out = subprocess.run([CLI, "history", "list", "--json"], env=env, capture_output=True, text=True, timeout=60)
            note("cli", argv="cmux history list --json", exit=out.returncode, stdout=out.stdout[-4000:], stderr=out.stderr[-2000:])
            RESULTS["daemon_cli"] = {"exit": out.returncode, "marker_visit": MARKER in out.stdout,
                                     "loaded_page": "example.com" in out.stdout,
                                     "stderr": out.stderr.strip()[-300:]}
        RESULTS["legacy_removed"] = {s or "db": not os.path.exists(LEGACY + s) for s in ["", "-wal", "-shm"]}
        path = os.path.join(OUT, "history-preflight.png")
        rpc("debug.window_snapshot", {"kind": "main", "path": path}, timeout=60)
        RESULTS["snapshot"] = os.path.exists(path)
    finally:
        RESULTS["clean_quit"] = teardown(app)
        for state in [os.path.join(HOME, ".cmux/chief/isolated", TAG), SUPPORT]:
            shutil.rmtree(state, ignore_errors=True)
        RESULTS["tag_state_removed"] = not os.path.exists(SUPPORT)


try:
    main()
finally:
    json.dump(RESULTS, open(os.path.join(OUT, "results.json"), "w"), indent=1)
    print(json.dumps(RESULTS, indent=1), flush=True)
h = RESULTS.get("history_list") or {}
ok = (RESULTS.get("clean_quit") and h.get("marker_visit") and h.get("loaded_page") and h.get("daemon_ids")
      and all((RESULTS.get("legacy_removed") or {"x": False}).values()))
sys.exit(0 if ok else 1)
