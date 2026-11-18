#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Live check of the cmux Computer Use helper v2: agent -> acpmux cua-mcp -> helper v2 -> Cua Driver.

  cua-helper-v2-live.py (--job <cmux-ci job id> | --app PATH) --tag <the build's tag> [--out DIR]
      [--while-locked] [--lock-with PROGRAM] [--window-python PATH]

Run it on the GUI host only, as one GUI-slot job:
  nx-remote --needs gui --ref <sha> -- python3 scripts/cmux-next/cua-helper-v2-live.py --job ID --tag TAG
It downloads the tagged DEV build of `--job` (built from an exact pushed SHA with
`cmux-ci build cmux --backend-mode local`), or takes the unpacked .app at `--app` (a tagged DEV
build with that tag), and starts it with no activation, an isolated cmux.json
(`computerUse.enabled = true`, `computerUse.driver = "upstream"`, and `computerUse.whileLocked =
true` with `--while-locked`) and its own ACPMUX_HOME, whose config.json adds one harness,
`cuaprobe` (cua_v2_probe_agent.py: a scripted ACP agent, no model). `--window-python` is the python
that runs the test window (default /usr/bin/python3).

`--lock-with PROGRAM` locks the screen before step 5: it runs `PROGRAM lock` (the lockprobe of
scripts/measure/macos-locked-screen-cu, which calls SACLockScreenImmediate and prints JSON with
session.locked), and the session must read locked. Only in a throwaway guest
(macos-locked-screen-cu.sh app=SHA): a locked fleet Mac needs a restart or a break-glass password.
With `--while-locked`, step 5 must then work on the locked screen: get_window_state returns a
screenshot with content (screenshot.png in --out), the test window records the click, and the
session still reads locked afterward (`PROGRAM state`). Without `--while-locked`, the opposite:
get_window_state answers `mac_locked`, the test window records no click, and the session still
reads locked. With `--lock-with` the agent goes on past `mac_locked` answers (it takes the window id
from the test window's own state file), so every call of step 5 is made and each answer recorded.

Checks, each recorded in cua-helper-v2-live.json in --out:
1. The build embeds "cmux Computer Use (dev).app" (com.cmuxterm.cua.dev).
2. The app logs the helper's `ready` line; its socket is under this user's Darwin temp dir
   (`getconf DARWIN_USER_TEMP_DIR`), in a 0700 directory of this user.
3. The app logs the helper's `{"type":"ack","of":"register_acpmux","ok":true}` for the acpmux
   daemon it started.
4. A raw `nc -U` connect to the helper socket is refused (`{"ok":false,"error":"refused",...}`).
5. `acpmux exec -m cuaprobe` starts one agent session. The agent starts its `cmux-cua` MCP server
   (`acpmux cua-mcp`), lists the tools and reads `check_permissions {"prompt": false}`. When both
   grants are present it takes ONE screenshot (`get_window_state`) of a bounded test window
   (cua_v2_probe_window.py: fixed 360x180, never activated, never key) and clicks its checkbox
   ONCE; the window must record the click and must not take focus.

TCC: this script never changes TCC and never asks for a grant. `check_permissions` runs with
`prompt: false`. A missing grant stops the screenshot and click, prints the exact grant as a
physical step, and exits 2.

On exit (also a failure, Ctrl-C or SIGTERM) the test window closes, the app quits with
`quitEndSessions`, and the tag's daemons end (tag_teardown.py). Only processes of this job's own
copy of the app, and the window this script started, are stopped, each by its exact PID.
Never Lawrence's running cmux. Exit 0 pass, 1 fail, 2 a missing grant.
"""
import argparse, datetime, glob, json, os, plistlib, secrets, signal, socket, stat, subprocess, sys, time
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tag_teardown import TagTeardown, pty_count  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--job")
parser.add_argument("--app", help="an unpacked tagged DEV .app to use instead of downloading --job")
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/cua-helper-v2-live")
parser.add_argument("--while-locked", action="store_true", help="cmux.json also gets computerUse.whileLocked = true")
parser.add_argument("--lock-with", metavar="PROGRAM", help="lock the screen with `PROGRAM lock` before step 5")
parser.add_argument("--window-python", default="/usr/bin/python3", help="the python that runs the test window")
opts = parser.parse_args()
if not opts.job and not opts.app:
    parser.error("one of --job or --app is required")
OUT = os.path.realpath(opts.out)
os.makedirs(OUT, exist_ok=True)
LOG = open(os.path.join(OUT, "live.log"), "a")
report = {"job": opts.job, "tag": opts.tag, "while_locked": opts.while_locked, "lock_with": opts.lock_with,
          "checks": []}
failures = []
missing_grants = []


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(line + "\n")
    LOG.flush()


def check(label, ok, detail=""):
    report["checks"].append({"check": label, "ok": bool(ok), "detail": detail})
    say("ok  " if ok else "FAIL", label, detail)
    if not ok:
        failures.append(label)
    return ok


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # a bounded test-harness wait, not app code
    return None


# 1. The fleet build (or the .app given).
if opts.app:
    APP = os.path.realpath(opts.app)
    if not (APP.endswith(".app") and os.path.isfile(os.path.join(APP, "Contents/Info.plist"))):
        sys.exit(f"--app {opts.app} is not an app bundle")
else:
    zip_path = os.path.join(OUT, "app.zip")
    if not os.path.exists(zip_path):
        subprocess.run([os.path.expanduser("~/.local/bin/cmux-ci"), "artifact", opts.job, zip_path], check=True,
                       env=dict(os.environ, CMUX_CI_CONTROLLER="http://100.89.225.106:18765"))
    app_dir = os.path.join(OUT, "app")
    if not os.path.isdir(app_dir):
        subprocess.run(["ditto", "-x", "-k", zip_path, app_dir], check=True)
    APP = next(iter(glob.glob(os.path.join(app_dir, "*.app"))), None)
    if not APP:
        sys.exit("no .app in the artifact")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
HELPER = os.path.join(APP, "Contents/Library/cmux Computer Use (dev).app")
report.update(app=APP, bundle_id=INFO.get("CFBundleIdentifier"), version=INFO.get("CFBundleVersion"))
say("app", APP, INFO.get("CFBundleIdentifier"))
helper_id = None
if os.path.isdir(HELPER):
    with open(os.path.join(HELPER, "Contents/Info.plist"), "rb") as f:
        helper_id = plistlib.load(f).get("CFBundleIdentifier")
    signing = subprocess.run(["codesign", "-dv", HELPER], capture_output=True, text=True)
    report["helper_signature"] = [l for l in signing.stderr.splitlines() if l.startswith(("Identifier", "TeamIdentifier", "CDHash", "Authority"))]
check("1 the build embeds the helper v2 (com.cmuxterm.cua.dev)", helper_id == "com.cmuxterm.cua.dev",
      f"{HELPER} -> {helper_id}")
if not os.path.exists(ACPMUX):
    check("the build bundles acpmux", False, ACPMUX)
if failures:
    with open(os.path.join(OUT, "cua-helper-v2-live.json"), "w") as f:
        json.dump(dict(report, failures=failures), f, indent=1)
    sys.exit(1)

# 2. Isolated config, acpmux home and the test window.
TAG = opts.tag
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
HOME_ACP = os.path.join(OUT, "acpmux-home")
ACP_SOCKET = os.path.join(tempfile.mkdtemp(prefix="cuav2-", dir="/tmp"), "acp.sock")  # a mkdtemp dir: a guessable /tmp name could be planted by another account
WORK = os.path.join(OUT, "work")
for path in (HOME_ACP, WORK):
    os.makedirs(path, exist_ok=True)
CONFIG = os.path.join(OUT, "cmux.json")
with open(CONFIG, "w") as f:
    computer_use = {"enabled": True, "driver": "upstream"}
    if opts.while_locked:
        computer_use["whileLocked"] = True
    json.dump({"computerUse": computer_use}, f)
TITLE = f"cmux CUA v2 probe {secrets.token_hex(4)}"
TARGET = os.path.join(OUT, "window-state.json")
STOP = os.path.join(OUT, "window-stop")
with open(os.path.join(HOME_ACP, "config.json"), "w") as f:
    json.dump({"harnesses": {"cuaprobe": {
        "argv": [sys.executable, os.path.join(HERE, "cua_v2_probe_agent.py")],
        "env": dict({"CUA_PROBE_OUT": OUT, "CUA_PROBE_TARGET": TARGET, "CUA_PROBE_TITLE": TITLE},
                    **({"CUA_PROBE_LOCKED": "1"} if opts.lock_with else {})),
        "description": "cua-helper-v2-live.py scripted agent"}},
        # No real agent ever starts: the probe is the default and no session is pre-created.
        "defaultHarness": "cuaprobe", "pool": {"enabled": False}}, f, indent=1)
# NEXT's own folder and the one in classic's that a build from before it used (a new build adopts that at launch).
for TAG_STATE in (os.path.expanduser(f"~/Library/Application Support/cmux-next/tags/{TAG}"),
                  os.path.expanduser(f"~/Library/Application Support/cmux/tags/{TAG}")):
    if os.path.isdir(TAG_STATE) and not os.path.islink(TAG_STATE):
        os.rename(TAG_STATE, TAG_STATE + ".old-" + str(int(time.time())))
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
USER_TMP = os.path.realpath(subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip())
report["darwin_user_temp_dir"] = USER_TMP


def rpc(method, params=None, timeout=30):
    """One request on the tagged app's JSON-lines debug socket."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def unified_log(since, predicate):
    """Messages from the unified log since `since` (ndjson), for this host's user only."""
    done = subprocess.run(["log", "show", "--start", since, "--predicate", predicate, "--style", "ndjson"],
                          capture_output=True, text=True, timeout=120)
    rows = []
    for line in done.stdout.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("eventMessage"):
            rows.append({"time": row.get("timestamp"), "pid": row.get("processID"), "message": row["eventMessage"]})
    return rows


def bundle_processes():
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[2].startswith(APP + "/"):
            found.append({"pid": int(parts[0]), "ppid": int(parts[1]), "command": parts[2][len(APP):][:160]})
    return found


def environment_of(pid):
    out = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
    return dict(w.split("=", 1) for w in out.split() if "=" in w and w.split("=", 1)[0].isupper())


def frontmost():
    """The frontmost app's name (a read: `lsappinfo front` names its ASN, `info` its name)."""
    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    if not asn:
        return None
    return subprocess.run(["lsappinfo", "info", "-only", "name", asn], capture_output=True, text=True).stdout.strip() or None


def lockprobe(command):
    """`--lock-with PROGRAM COMMAND` (lock or state): its last JSON line, or {"error": ...}."""
    try:
        done = subprocess.run([opts.lock_with, command], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"error": str(error)}
    for line in reversed(done.stdout.splitlines()):
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            return value
    return {"error": f"exit {done.returncode}, no JSON: {done.stdout[-200:]} {done.stderr[-200:]}"}


def is_mac_locked(reply):
    """Whether a tool's reply is the helper's ScreenLockedRefusal (its code and message start "mac_locked")."""
    return reply is not None and "mac_locked" in json.dumps(reply)


def image_stats(path):
    """Width, height, distinct colours (of up to 4096 sampled pixels) and the lit share (any channel above 24)
    of a screenshot, so a black or flat lock-screen picture does not count as one with content. A PNG of
    8-bit RGB or RGBA is read here; anything else is first converted with `sips`."""
    import struct, zlib
    try:
        with open(path, "rb") as f:
            data = f.read()
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            converted = path + ".stats.png"
            subprocess.run(["sips", "-s", "format", "png", path, "--out", converted], capture_output=True, timeout=60)
            with open(converted, "rb") as f:
                data = f.read()
        pos, idat, width = 8, b"", 0
        while pos < len(data):
            length, kind = struct.unpack(">I4s", data[pos:pos + 8])
            body = data[pos + 8:pos + 8 + length]
            if kind == b"IHDR":
                width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
                if depth != 8 or colour not in (2, 6) or interlace:
                    return {"w": width, "h": height, "error": f"PNG depth {depth} colour {colour} interlace {interlace}"}
                bpp = 3 if colour == 2 else 4
            elif kind == b"IDAT":
                idat += body
            pos += 12 + length
        raw = zlib.decompress(idat)
        stride = width * bpp
        rows, previous = [], bytearray(stride)
        for y in range(height):
            kind, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b, c = previous[i], previous[i - bpp] if i >= bpp else 0
                if kind == 1:
                    line[i] = (line[i] + a) & 255
                elif kind == 2:
                    line[i] = (line[i] + b) & 255
                elif kind == 3:
                    line[i] = (line[i] + (a + b) // 2) & 255
                elif kind == 4:
                    p = a + b - c
                    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                    line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
            rows.append(line)
            previous = line
        step = max(1, int((width * height / 4096) ** 0.5))
        colours, lit, seen = set(), 0, 0
        for y in range(0, height, step):
            for x in range(0, width, step):
                pixel = tuple(rows[y][x * bpp:x * bpp + 3])
                colours.add(pixel)
                lit += max(pixel) > 24
                seen += 1
        return {"w": width, "h": height, "colors": len(colours), "lit": round(lit / max(seen, 1), 3)}
    except (OSError, ValueError, struct.error, zlib.error, subprocess.TimeoutExpired, IndexError, UnboundLocalError) as error:
        return {"error": f"cannot read {path}: {error!r}"}


env = dict(os.environ)
env.update({"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
            "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1000,700",
            "ACPMUX_HOME": HOME_ACP, "ACPMUX_SOCKET": ACP_SOCKET})
TEARDOWN = TagTeardown(APP, acpmux_home=HOME_ACP, acpmux_socket=ACP_SOCKET, log=say)
TEARDOWN.install()
PTYS_BEFORE = pty_count()
window = None
app = None
since = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
try:
    report["frontmost_before"] = frontmost()
    window = subprocess.Popen([opts.window_python, os.path.join(HERE, "cua_v2_probe_window.py"), TARGET, STOP, TITLE,
                               "--seconds", "600"], stdin=subprocess.DEVNULL,
                              stdout=open(os.path.join(OUT, "window.log"), "a"), stderr=subprocess.STDOUT)
    report["window_pid"] = window.pid
    started = wait(lambda: os.path.exists(TARGET) and json.load(open(TARGET)), 20)
    check("test window shown (fixed 360x180, title " + TITLE + ")", bool(started) and started.get("window_visible"),
          json.dumps(started)[:300])
    app = subprocess.Popen([BINARY], env=env, stdin=subprocess.DEVNULL,
                           stdout=open(os.path.join(OUT, "app.log"), "a"), stderr=subprocess.STDOUT)
    report["app_pid"] = app.pid
    say("started app pid", app.pid, "log since", since)
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 120, 0.5):
        raise SystemExit("the tagged app did not come up")

    # The acpmux daemon the app started (its executable is the bundled acpmux) and its v2 endpoint folder.
    def daemon():
        for p in bundle_processes():
            if p["command"].startswith("/Contents/Resources/bin/acpmux daemon run"):
                return p
        return None
    found = wait(daemon, 60, 0.5)
    check("the app started its bundled acpmux daemon", bool(found), json.dumps(found))
    v2_dir = environment_of(found["pid"]).get("CMUX_NEXT_CUA_V2_DIR") if found else None
    report["daemon"] = found
    report["v2_dir"] = v2_dir
    endpoint = os.path.join(v2_dir, "endpoint.json") if v2_dir else None
    has_endpoint = wait(lambda: endpoint and os.path.exists(endpoint), 30, 0.5)
    mode = oct(os.stat(endpoint).st_mode & 0o777) if has_endpoint else None
    check("helper v2 endpoint.json exists, 0600 (its secret is not read here)", has_endpoint and mode == "0o600",
          f"{endpoint} mode {mode}")

    # 2-3. The ready line and the register_acpmux ack, from the app's unified log.
    predicate = 'subsystem == "com.cmuxterm.app.next" AND category == "computer-use-v2"'

    def acked():
        rows = [r for r in unified_log(since, predicate) if r["pid"] == app.pid]
        return rows if any('"of":"register_acpmux"' in r["message"] and '"ok":true' in r["message"] for r in rows) else None
    rows = wait(acked, 60, 3) or [r for r in unified_log(since, predicate) if r["pid"] == app.pid]
    report["app_log"] = rows
    ready = next((r for r in rows if "helper v2 ready" in r["message"]), None)
    sock = ready["message"].split("socket=", 1)[1].strip() if ready and "socket=" in ready["message"] else None
    report["helper_socket"] = sock
    check("2 helper ready line logged", bool(ready), ready["message"] if ready else json.dumps(rows)[:600])
    helper = next((p for p in bundle_processes() if "cmux-cua-helper" in p["command"]), None)
    remote = None
    if helper is None and os.path.isdir(os.path.join(APP, "Contents/Library/cmux Remote (dev).app")):
        # cmux Remote (docs/cmux-remote.md): the worker is the host's child, the host the daemon's.
        listing = subprocess.run(["ps", "-Aww", "-o", "pid=,ppid=,command="], capture_output=True, text=True).stdout.splitlines()
        procs = [r.strip().split(None, 2) for r in listing if "MacOS/cmux-remote " in r]
        hosts = [p for p in procs if len(p) == 3 and " host " in f" {p[2]} "]
        workers = [p for p in procs if len(p) == 3 and "worker computer-use" in p[2]]
        host = hosts[0] if hosts else None
        worker = next((w for w in workers if host and w[1] == host[0]), None)
        daemon = next((p for p in bundle_processes() if p["pid"] == int(host[1])), None) if host else None
        remote = {"host": host, "worker": worker, "host_parent": daemon,
                  "host_outside_app": bool(host) and not host[2].startswith(APP)}
        report["cmux_remote"] = remote
    report["helper_process"] = helper
    if remote is not None:
        check("Computer Use runs as cmux Remote's worker (worker <- host <- the app's cmux-tui daemon; host outside the app)",
              bool(remote["worker"]) and bool(remote["host_parent"]) and "cmux-tui" in remote["host_parent"]["command"]
              and remote["host_outside_app"], json.dumps(remote)[:600])
    else:
        check("helper v2 runs as a child of the app", bool(helper) and helper["ppid"] == app.pid, json.dumps(helper))
    if sock:
        real = os.path.realpath(sock)
        st = os.stat(sock)
        dir_st = os.stat(os.path.dirname(sock))
        check("2 helper socket is under the Darwin user temp dir", real.startswith(USER_TMP + "/"), f"{real} under {USER_TMP}")
        check("2 helper socket is a socket of this user in a 0700 directory",
              stat.S_ISSOCK(st.st_mode) and st.st_uid == os.getuid() and dir_st.st_uid == os.getuid()
              and dir_st.st_mode & 0o777 == 0o700, f"socket uid {st.st_uid}, dir mode {oct(dir_st.st_mode & 0o777)}")
    ack = next((r for r in rows if '"of":"register_acpmux"' in r["message"]), None)
    check("3 register_acpmux ack ok:true logged", bool(ack) and '"ok":true' in ack["message"],
          ack["message"] if ack else "no ack line")

    # 4. A raw same-user connect is refused before the helper reads a byte.
    if sock:
        try:
            raw = subprocess.run(["/usr/bin/nc", "-U", sock], input=b"", capture_output=True, timeout=15)
            raw_out = raw.stdout.decode(errors="replace").strip()
        except subprocess.TimeoutExpired as error:
            raw_out = f"timeout: {(error.stdout or b'').decode(errors='replace')}"
        report["nc"] = raw_out
        check("4 raw nc -U connect is refused", '"error":"refused"' in raw_out and '"ok":false' in raw_out, raw_out[:300])

    # 5L. Lock the screen first (--lock-with): the session must read locked before the agent starts.
    if opts.lock_with:
        locked_before = lockprobe("lock")
        report["lock"] = locked_before
        check("5L the session reads locked before the agent's step (lockprobe lock)",
              (locked_before.get("session") or {}).get("locked") is True, json.dumps(locked_before)[:300])

    # 5. One agent session: the scripted agent drives cmux-cua through acpmux cua-mcp.
    session =subprocess.run([ACPMUX, "exec", "-m", "cuaprobe", "--cwd", WORK, "--policy", "approve-all", "--timeout", "150",
                              "take one screenshot of the probe window and click its checkbox once"],
                             env=dict(os.environ, ACPMUX_HOME=HOME_ACP, ACPMUX_SOCKET=ACP_SOCKET),
                             capture_output=True, text=True, timeout=200)
    report["session"] = {"exit": session.returncode, "stdout": session.stdout[-3000:], "stderr": session.stderr[-2000:]}
    say("acpmux exec exit", session.returncode, session.stdout.strip()[-600:], session.stderr.strip()[-400:])
    result_path = os.path.join(OUT, "agent-result.json")
    result = json.load(open(result_path)) if os.path.exists(result_path) else {}
    report["agent"] = {k: result.get(k) for k in ("cua_server", "bridge_is_acpmux_cua_mcp", "bridge_pid", "probe_pid",
                                                    "tools", "permissions", "missing_grants", "skipped", "window",
                                                    "screenshot", "click_target", "window_after_click", "click_landed",
                                                    "error", "tools_list_error", "bridge_exit")}
    report["agent"]["steps"] = result.get("steps")
    check("5 agent session ran (acpmux exec exit 0)", session.returncode == 0, f"exit {session.returncode}")
    check("5 the session's cmux-cua server is `acpmux cua-mcp`", result.get("bridge_is_acpmux_cua_mcp") is True,
          json.dumps(result.get("cua_server"))[:300])
    check("5 tools/list through the bridge", bool(result.get("tools")), json.dumps(result.get("tools"))[:400])
    perms = result.get("permissions") or {}
    steps = {s.get("tool"): s for s in result.get("steps") or []}
    refused_locked = sorted(name for name, s in steps.items() if is_mac_locked(s.get("reply")))
    report["agent"]["refused_mac_locked"] = refused_locked
    refusal_pass = bool(opts.lock_with) and not opts.while_locked
    if refusal_pass:
        # check_permissions may answer or be refused mac_locked (the gate refuses every call on a locked
        # screen with the setting off): either is recorded, neither fails.
        say("check_permissions on the locked screen:", "mac_locked" if "check_permissions" in refused_locked
            else json.dumps(perms)[:300])
    else:
        check("5 check_permissions {prompt:false} answered", perms.get("accessibility") is not None,
              json.dumps(perms)[:300])
    missing_grants[:] = result.get("missing_grants") or []
    if refusal_pass:
        shot_step = steps.get("get_window_state") or {}
        check("5L whileLocked off: get_window_state on the locked screen answers mac_locked",
              is_mac_locked(shot_step.get("reply")), json.dumps(shot_step.get("reply"))[:400])
        clicked = json.load(open(TARGET)).get("clicks", 0) if os.path.exists(TARGET) else None
        check("5L whileLocked off: nothing was clicked (the test window recorded no click)", clicked == 0,
              f"clicks {clicked}; click reply {json.dumps((steps.get('click') or {}).get('reply'))[:300]}")
    elif missing_grants:
        say("MISSING GRANT (physical step for Lawrence, on cmux-lawrence-2): System Settings > Privacy & Security > "
            + " and ".join(missing_grants) + ": turn on \"cmux Computer Use (dev)\" (com.cmuxterm.cua.dev). "
            "Screenshot and click were skipped; TCC was not changed.")
    else:
        shot = result.get("screenshot") or {}
        check("5 one screenshot (get_window_state) saved", shot.get("bytes", 0) > 0, json.dumps(shot))
        click = steps.get("click") or {}
        click_error = (click.get("reply") or {}).get("error") or ((click.get("reply") or {}).get("result") or {}).get("isError")
        check("5 one click answered without an error", bool(click) and not click_error,
              json.dumps(click.get("reply"))[:400])
        check("5 the click landed in the test window (checkbox toggled)", result.get("click_landed") is True,
              json.dumps(result.get("window_after_click"))[:300])
        if opts.lock_with:
            stats = image_stats(shot.get("path")) if shot.get("path") else {"error": "no screenshot"}
            report["screenshot_stats"] = stats
            check("5L whileLocked on: get_window_state on the locked screen returned a screenshot with content",
                  shot.get("bytes", 0) > 0 and stats.get("colors", 0) >= 8 and stats.get("lit", 0) >= 0.05
                  and "get_window_state" not in refused_locked, json.dumps(dict(stats, path=shot.get("path")))[:300])
            check("5L whileLocked on: the click on the locked screen landed in the test window",
                  result.get("click_landed") is True and "click" not in refused_locked,
                  json.dumps(result.get("window_after_click"))[:300])
    if opts.lock_with:
        locked_after = lockprobe("state")
        report["lock_after"] = locked_after
        check("5L the session still reads locked after the agent's step", locked_after.get("locked") is True,
              json.dumps(locked_after)[:300])
    report["frontmost_after"] = frontmost()
    state = json.load(open(TARGET)) if os.path.exists(TARGET) else {}
    check("the test window never took focus (app never active, window never key)",
          state.get("ever_active") is False and state.get("ever_key") is False, json.dumps(state)[:300])
    # Informational: the window's own state above is the focus check (this read has no fail path).
    say("frontmost app before/after:", report["frontmost_before"], "->", report["frontmost_after"])
    report["helper_refusals"] = [r for r in unified_log(since, 'subsystem == "com.cmuxterm.cua"')
                                 if helper and r["pid"] == helper["pid"]][-20:]
finally:
    # The test window closes first (stop file, then its exact PID).
    if window is not None:
        open(STOP, "w").close()
        try:
            window.wait(15)
        except subprocess.TimeoutExpired:
            window.terminate()  # the exact PID this script started
            window.wait(10)
        final = json.load(open(TARGET)) if os.path.exists(TARGET) else {}
        report["window_final"] = final
        check("the test window closed after the run", window.returncode is not None and final.get("closing") is True
              and final.get("window_visible_after_close") is False, json.dumps(final)[:300])
    if app is not None:
        if app.poll() is None:
            report["quit"] = rpc("action.run", {"action": "quitEndSessions"}, timeout=15)
            say("quitEndSessions", json.dumps(report["quit"])[:300])
            if not wait(lambda: app.poll() is not None, 45, 0.5):
                app.send_signal(signal.SIGTERM)  # the PID launched here
                try:
                    app.wait(30)
                except subprocess.TimeoutExpired:
                    app.kill()
                    app.wait()
        report["app_exit"] = app.returncode
    TEARDOWN.end()
    left = bundle_processes()
    report["left_after_teardown"] = left
    check("no process of this tag's app copy is left", not left, json.dumps(left)[:300])
    report["ptys"] = {"before": PTYS_BEFORE, "after": pty_count()}
    report["failures"] = failures
    report["missing_grants"] = missing_grants
    with open(os.path.join(OUT, "cua-helper-v2-live.json"), "w") as f:
        json.dump(report, f, indent=1)
    verdict = "FAIL" if failures else ("MISSING GRANT " + ", ".join(missing_grants) if missing_grants else "PASS")
    say(verdict, f"(evidence {OUT}/cua-helper-v2-live.json)")
sys.exit(1 if failures else 2 if missing_grants else 0)
