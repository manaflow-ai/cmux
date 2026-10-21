#!/usr/bin/env python3
"""A crash ends the app within a bounded time, never freezes it (CI regression guard).

On 2026-10-20 two cmux NIGHTLY crashes froze the app until Force Quit: an uncaught Objective-C
exception with Sentry running. Sentry's reportException: hook turned its crash monitors off; its
Mach exception thread then took AppKit's trap while off and exited without giving back the task's
exception ports; the trap that ran again after the app's signal handler waited forever on a port
nothing received. This guard launches a Debug `cmux DEV <tag>.app` twice, with Sentry on
(CMUX_NEXT_DEV_SENTRY=1, the condition that took away Sentry's primary handler thread), and:

  exception  `debug.crash.exception` (exception-report-e2e.py --expect-reporting): the process must
             end within --exception-seconds (default 8, under the crash deadline's 10 s, so the
             exception path itself ends the app, not only the deadline);
  frozen     `debug.crash.app {"signal": "frozen"}`: a crash path that blocks on a trap whose Mach
             exception nothing receives; the crash deadline must end it within --frozen-seconds
             (default 30).
  suspended  `debug.crash.app {"signal": "suspended"}`: a crash path that suspends every other thread
             (the crash deadline's too, as Sentry does while it writes its report) and blocks. Only
             the out-of-process watcher (`cmux __app-watch`, #22844) can end it: not before 14 s
             (the deadline did not do it), within --watch-seconds (default 30). The watcher then
             relaunches the app: its debug socket must answer within --relaunch-seconds (default
             60) and its restart notice must say the watcher ended the run.
  hang       `debug.crash.app {"signal": "hang"}`: the main thread blocks with no crash. With
             CMUX_NEXT_APP_WATCH_HANG_SECONDS=5 the watcher ends the run about 7 s later (2 s
             watchdog report + 5 s) and relaunches it, checked as for suspended.

The exception and frozen runs start no watcher (CMUX_NEXT_APP_WATCH=0), so they prove the in-process
paths alone; the watched runs turn its relaunch on (an agent launch is not relaunched by default).
Each run prints `ended_s` (crash to process end) and, for suspended and hang, `relaunch_s`
(process end to the relaunched app's socket) and `notice_s` (to its restart notice, the first
window shown): the measured time to a usable window after a crash.

Before each crash it checks with `sample` that Sentry's primary Mach handler thread runs, so the
guard holds the failing setup. A process that does not end is sampled into --out and then stopped
by its exact PID. Exit 0 when every run ended in time.

Usage: crash-ends-app-gate.py --app "<dir>/cmux DEV <tag>.app" --out <dir>
"""
import argparse, json, os, plistlib, re, signal, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PRIMARY = "SentryCrash Exception Handler (Primary)"

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--exception-seconds", type=float, default=8)
parser.add_argument("--frozen-seconds", type=float, default=30)
parser.add_argument("--watch-seconds", type=float, default=30)
parser.add_argument("--relaunch-seconds", type=float, default=60)
parser.add_argument("--runs", default="exception,frozen,suspended,hang",
                    help="comma list of exception, frozen, suspended, hang")
opts = parser.parse_args()

bundle = os.path.realpath(opts.app).rstrip("/")
match = re.fullmatch(r"cmux DEV (.+)\.app", os.path.basename(bundle))
if not match:
    sys.exit(f"crash-ends-app-gate: expected a `cmux DEV <tag>.app` bundle, got {bundle}")
tag = match.group(1)
sock = f"/tmp/cmux-debug-{tag}.sock"
with open(os.path.join(bundle, "Contents/Info.plist"), "rb") as plist:
    bundle_id = plistlib.load(plist).get("CFBundleIdentifier", "")
# The app's run-marker folder (AppRunMarker.standardDirectory): run.json, run.watch, watch.log.
if not bundle_id:
    sys.exit(f"crash-ends-app-gate: {bundle} has no CFBundleIdentifier")
marker_dir = os.path.expanduser(f"~/Library/Application Support/cmux-next/{bundle_id}")
os.makedirs(opts.out, exist_ok=True)


def rpc(method, params=None, timeout=10):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(sock)
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


def wait(check, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if check():
            return True
        time.sleep(step)  # test harness polling a live app
    return False


def sample(pid, path, seconds=1):
    subprocess.run(["/usr/bin/sample", str(pid), str(seconds), "-mayDie", "-file", path],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    try:
        with open(path, errors="replace") as file:
            return file.read()
    except OSError:
        return ""


def read(path):
    try:
        with open(path, errors="replace") as file:
            return file.read()
    except OSError:
        return ""


def run(kind):
    scratch = tempfile.mkdtemp(prefix=f"crash-gate-{tag}-")
    ghostty = os.path.join(scratch, "ghostty")
    open(ghostty, "w").close()
    config = os.path.join(scratch, "cmux.json")
    with open(config, "w") as file:
        json.dump({}, file)
    if os.path.exists(sock):
        os.unlink(sock)
    # Each run starts as a first launch: the previous run's crash would make this launch a restart,
    # and the watcher does not relaunch a restart that dies within 60 s (no restart loop).
    for name in ("run.json", "run.signal", "run.exception", "run.watch", "watch.restarts", "watch.log"):
        try:
            os.unlink(os.path.join(marker_dir, name))
        except FileNotFoundError:
            pass
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_GHOSTTY_CONFIG": ghostty,
           "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(scratch, "chief"),
           "CMUX_NEXT_DEV_SENTRY": "1"}
    watched = kind in ("suspended", "hang")
    # The exception and frozen runs prove the in-process paths alone: no watcher may end them.
    env["CMUX_NEXT_APP_WATCH"] = "1" if watched else "0"
    if watched:
        env["CMUX_NEXT_APP_WATCH_RELAUNCH"] = "1"
    if kind == "hang":
        env["CMUX_NEXT_APP_WATCH_HANG_SECONDS"] = "5"
    teardown = TagTeardown(bundle)
    teardown.install()
    log = open(os.path.join(opts.out, f"app-{kind}.log"), "a")
    process = subprocess.Popen([os.path.join(bundle, "Contents/MacOS/cmux DEV")], env=env,
                               stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    pid = process.pid
    print(f"crash-ends-app-gate: {kind}: launched {tag} pid {pid}", flush=True)
    try:
        if not wait(lambda: "error" not in (rpc("debug.crashes") or {"error": 1}), 180):
            return f"{kind}: the app's debug socket never answered (a Debug build is required)"
        if watched:
            return watched_run(kind, process, pid)
        before = sample(pid, os.path.join(opts.out, f"before-{kind}.txt"))
        if PRIMARY not in before:
            return f"{kind}: Sentry's primary Mach exception thread does not run before the crash (CMUX_NEXT_DEV_SENTRY=1 not honored?)"
        limit = opts.exception_seconds if kind == "exception" else opts.frozen_seconds
        args = ["--expect-reporting"] if kind == "exception" else ["--crash", "frozen"]
        started = time.time()
        # No --app-pid: the app is this script's child, so it stays a zombie (alive to kill -0) until
        # it is reaped here; process.wait times the end.
        result = subprocess.run([sys.executable, os.path.join(HERE, "exception-report-e2e.py"), "--socket", sock,
                                 "--phase", "raise"] + args, timeout=limit + 120)
        try:
            process.wait(max(limit - (time.time() - started), 0.1))
        except subprocess.TimeoutExpired:
            pass
        elapsed = time.time() - started
        if process.poll() is None:
            text = sample(pid, os.path.join(opts.out, f"frozen-{kind}.txt"), seconds=2)
            main = text.split("com.apple.main-thread", 1)[-1][:1600] if text else ""
            print(f"crash-ends-app-gate: {kind}: the app still runs {elapsed:.0f} s after the crash; "
                  f"main thread:\n{main}", flush=True)
            return f"{kind}: the crash froze the app instead of ending it within {limit:.0f} s"
        if result.returncode != 0:
            return f"{kind}: exception-report-e2e.py exited {result.returncode}"
        # A frozen crash that ended early never blocked: the deadline was not tested.
        if kind == "frozen" and elapsed < 8:
            return f"frozen: the app ended after {elapsed:.1f} s, before the crash deadline: its trap did not block"
        print(f"crash-ends-app-gate: {kind}: ended in {elapsed:.1f} s (exit status {process.returncode})", flush=True)
        return None
    finally:
        if process.poll() is None:
            os.kill(pid, signal.SIGKILL)  # this script's own child, by exact PID
            process.wait(30)
        teardown.end()


def watched_run(kind, process, pid):
    """suspended / hang: the watcher ends the run, records why and relaunches it."""
    started = time.time()
    # The call never returns: the main thread blocks inside it.
    rpc("debug.crash.app", {"signal": kind}, timeout=3)
    try:
        process.wait(opts.watch_seconds)
    except subprocess.TimeoutExpired:
        pass
    ended = time.time()
    elapsed = ended - started
    if process.poll() is None:
        sample(pid, os.path.join(opts.out, f"frozen-{kind}.txt"), seconds=2)
        return f"{kind}: the watcher did not end the app within {opts.watch_seconds:.0f} s"
    if kind == "suspended" and elapsed < 14:
        return f"suspended: the app ended after {elapsed:.1f} s, before the watcher's 15 s grace (not the watcher)"
    # The old process is gone; only the relaunched app answers (the one whose previous run is `pid`).
    def relaunched_app():
        launch = (rpc("debug.crashes", timeout=3) or {}).get("launch") or {}
        return (launch.get("previous") or {}).get("pid") == pid
    if not wait(relaunched_app, opts.relaunch_seconds, 0.1):
        log = read(os.path.join(marker_dir, "watch.log"))
        print(f"crash-ends-app-gate: {kind}: watch.log:\n{log[-1200:]}", flush=True)
        return f"{kind}: no relaunched app answered on its socket within {opts.relaunch_seconds:.0f} s"
    relaunched = time.time()
    noticed = {}

    def notice():
        launch = (rpc("debug.crashes", timeout=3) or {}).get("launch") or {}
        noticed.update(launch)
        return bool(launch.get("notice"))
    has_notice = wait(notice, 30, 0.1)
    shown = time.time()
    ending = (noticed.get("previous") or {}).get("watch_ending") or {}
    expected = "crash_stuck" if kind == "suspended" else "hang"
    print(f"crash-ends-app-gate: {kind}: ended_s={elapsed:.1f} relaunch_s={relaunched - ended:.1f} "
          f"notice_s={shown - ended:.1f} recovery={noticed.get('recovery')} watch_ending={ending} "
          f"notice={noticed.get('notice')!r}", flush=True)
    if noticed.get("recovery") not in ("restarted", "restartedSafely"):
        return f"{kind}: the relaunched app did not restore as a restart: {noticed.get('recovery')!r}"
    if ending.get("reason") != expected:
        return f"{kind}: the relaunched app does not know the watcher ended the run ({expected}): {ending!r}"
    if not has_notice or "watcher" not in (noticed.get("notice") or ""):
        return f"{kind}: the restart notice does not say the watcher ended the run: {noticed.get('notice')!r}"
    return None


failures = [failure for failure in (run(kind.strip()) for kind in opts.runs.split(",") if kind.strip()) if failure]
for failure in failures:
    print(f"FAIL {failure}", flush=True)
if failures:
    sys.exit(1)
print("PASS every crash ended the app in time", flush=True)
