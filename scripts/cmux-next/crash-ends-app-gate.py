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
  suspended  `debug.crash.app {"signal": "suspended"}` (#22844): the crash path begins, the deadline
             thread is suspended (as Sentry's report writer suspends every thread) and the main thread
             blocks; only the out-of-process crash watcher (CrashWatcher, 15 s) can end it, within
             --suspended-seconds (default 20). The watcher's sample and the run marker (the next
             launch names the crash) must be in the app's marker folder.

Before each crash it checks with `sample` that Sentry's primary Mach handler thread runs, so the
guard holds the failing setup. A process that does not end is sampled into --out and then stopped
by its exact PID. Exit 0 when every run ended in time.

Usage: crash-ends-app-gate.py --app "<dir>/cmux DEV <tag>.app" --out <dir>
"""
import argparse, json, os, re, signal, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PRIMARY = "SentryCrash Exception Handler (Primary)"

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--exception-seconds", type=float, default=8)
parser.add_argument("--frozen-seconds", type=float, default=30)
parser.add_argument("--suspended-seconds", type=float, default=20)
# suspended is opt-in (`--runs suspended`): run it yourself on the fleet; CI keeps its two runs.
parser.add_argument("--runs", default="exception,frozen", help="comma list of exception, frozen, suspended")
opts = parser.parse_args()

bundle = os.path.realpath(opts.app).rstrip("/")
match = re.fullmatch(r"cmux DEV (.+)\.app", os.path.basename(bundle))
if not match:
    sys.exit(f"crash-ends-app-gate: expected a `cmux DEV <tag>.app` bundle, got {bundle}")
tag = match.group(1)
sock = f"/tmp/cmux-debug-{tag}.sock"
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


def marker_folder():
    """The app's run marker folder (AppRunMarker.standardDirectory: the bundle id, made path-safe)."""
    import plistlib
    with open(os.path.join(bundle, "Contents/Info.plist"), "rb") as file:
        bundle_id = plistlib.load(file).get("CFBundleIdentifier", "unknown")
    root = os.path.expanduser("~/Library/Application Support/cmux-next")
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", bundle_id)
    return os.path.join(root, safe)


def run(kind):
    scratch = tempfile.mkdtemp(prefix=f"crash-gate-{tag}-")
    ghostty = os.path.join(scratch, "ghostty")
    open(ghostty, "w").close()
    config = os.path.join(scratch, "cmux.json")
    with open(config, "w") as file:
        json.dump({}, file)
    if os.path.exists(sock):
        os.unlink(sock)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_GHOSTTY_CONFIG": ghostty,
           "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(scratch, "chief"),
           "CMUX_NEXT_DEV_SENTRY": "1"}
    teardown = TagTeardown(bundle)
    teardown.install()
    log = open(os.path.join(opts.out, f"app-{kind}.log"), "a")
    process = subprocess.Popen([os.path.join(bundle, "Contents/MacOS/cmux DEV")], env=env,
                               stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    pid = process.pid
    print(f"crash-ends-app-gate: {kind}: launched {tag} pid {pid}", flush=True)
    try:
        last = {}

        def answered():
            last["reply"] = rpc("debug.crashes") or {"error": "empty reply"}
            return "error" not in last["reply"]

        if not wait(answered, 180):
            # Infra, not a crash freeze: say what the socket did, so the cause is in the log.
            state = "a socket" if os.path.exists(sock) else "absent"
            return (f"{kind}: the app's debug socket never answered (a Debug build is required); "
                    f"{sock} is {state}, alive={process.poll() is None}, last reply {last.get('reply')}")
        before = sample(pid, os.path.join(opts.out, f"before-{kind}.txt"))
        if PRIMARY not in before:
            return f"{kind}: Sentry's primary Mach exception thread does not run before the crash (CMUX_NEXT_DEV_SENTRY=1 not honored?)"
        limit = {"exception": opts.exception_seconds, "frozen": opts.frozen_seconds}.get(kind, opts.suspended_seconds)
        started = time.time()
        if kind == "suspended":
            # The app blocks before it answers: no reply is expected.
            rpc("debug.crash.app", {"signal": "suspended"}, timeout=2)
            result = subprocess.CompletedProcess([], 0)
        else:
            args = ["--expect-reporting"] if kind == "exception" else ["--crash", "frozen"]
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
        if kind == "suspended":
            if elapsed < 14:
                return f"suspended: the app ended after {elapsed:.1f} s, before the watcher's 15 s: the path did not block"
            if process.returncode != -signal.SIGKILL:
                return f"suspended: the app ended with status {process.returncode}, not the watcher's SIGKILL"
            folder = marker_folder()
            for name in ("crash-watcher-sample.txt", "run.json"):
                path = os.path.join(folder, name)
                if not os.path.exists(path) or os.path.getmtime(path) < started - 300:
                    return f"suspended: no fresh {name} in {folder}"
        print(f"crash-ends-app-gate: {kind}: ended in {elapsed:.1f} s (exit status {process.returncode})", flush=True)
        return None
    finally:
        if process.poll() is None:
            os.kill(pid, signal.SIGKILL)  # this script's own child, by exact PID
            process.wait(30)
        teardown.end()


failures = [failure for failure in (run(kind.strip()) for kind in opts.runs.split(",") if kind.strip()) if failure]
for failure in failures:
    print(f"FAIL {failure}", flush=True)
if failures:
    sys.exit(1)
print("PASS every crash ended the app in time", flush=True)
