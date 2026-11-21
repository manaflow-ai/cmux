#!/usr/bin/env bash
# Fleet signal-quit probe (cmux#33416, the follow-up of cmux#33199): launch a given DEV build, open a Chromium tab so
# the built-in uBlock Origin loads, end the app one way, and report what the quit left behind.
#
#   cmux-ci run --class light --display --script scripts/ci/signal-quit-probe.sh --ref <feat-cmux-next tip> \
#     --arg=--app=sha256:<the build's artifact digest> [--arg=--mode=all|term|int|kill-app|quit] \
#     --artifact artifacts/signal-quit-probe.tgz
#
# --app is a finished fleet cmux build's artifact (`cmux-ci status BUILD_ID`, its "artifact"): the zip of the app,
# fetched from the controller and checked against that digest. Modes, one fresh launch each (--mode=all runs every
# one in this order):
#   term      SIGTERM to every process of the bundle (what `pkill -TERM` by the app's name does)
#   int       SIGINT to the app's process group (Ctrl-C in the terminal that started it)
#   kill-app  SIGKILL to the app (browser) process only
#   quit      a normal Quit (action quitKeepSessions on the app's socket)
# For each it records, every 100 ms for 30 s: when the app ended and when each helper ended. A helper of the
# extension process (uBlock's background page, `--extension-process`) that ends while the app still runs is the
# condition in which Chromium shows "uBlock Origin has crashed" (cmux#33199), so that fails the mode; so does a
# helper still running 30 s after the app ended, and a new crash report of the bundle's processes in
# ~/Library/Logs/DiagnosticReports. A screenshot 1.5 s after the signal (while the app may still draw a balloon) and
# one after the app ended go in the artifact with verdict.json and each launch's app log.
#
# Needs a console (Aqua) session: run it with --display. The app gets an empty HOME, CFFIXED_USER_HOME and TMPDIR
# of its own, a socket path of its own and no activation; crash reports are read from the step user's real home,
# where ReportCrash writes them. Every process it signals or ends is one whose executable is inside the bundle this
# probe unpacked, found by that path, never by name. Exit 0 when every mode passed, 1 when one failed, 2 on a usage
# or setup failure. The worker runs this only when its bytes equal the version on feat-cmux-next or main
# (cmuxterm-hq build-fleet/cmd/worker/step_reviewed.go).
set -euo pipefail

usage() { echo "signal-quit-probe: $*" >&2; exit 2; }

app_digest="" mode="all"
for arg in "$@"; do
  case "$arg" in
    --app=sha256:*) app_digest="${arg#--app=}" ;;
    --mode=all|--mode=term|--mode=int|--mode=kill-app|--mode=quit) mode="${arg#--mode=}" ;;
    *) usage "unknown argument $arg (takes --app=sha256:HEX, --mode=all|term|int|kill-app|quit)" ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || usage "runs only on macOS (the build is a Mac app)"
[[ "$app_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || usage "needs --app=sha256:<64 lowercase hex> (a fleet cmux build's artifact)"
[[ "$(/bin/launchctl managername 2>/dev/null || true)" == Aqua ]] || usage "needs a console (Aqua) session: run the step with --display"
real_home="$(/usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
[[ -n "$real_home" && -d "$real_home" ]] || usage "cannot read the real home of $(/usr/bin/id -un)"

cd "$(git rev-parse --show-toplevel)"
out="$(pwd)/artifacts/signal-quit-probe"
report="$(pwd)/artifacts/signal-quit-probe.tgz"
rm -rf "$out" "$report"  # this step's results only: a reused checkout must not upload an earlier job's files
mkdir -p "$out"
work="$(/usr/bin/mktemp -d /tmp/sqp.XXXXXX)"  # short: the app's socket path lives here (104-byte sun_path)
runner_pid=""

# shellcheck disable=SC2317,SC2329 # run by the traps below
cleanup() {
  trap - EXIT TERM INT HUP
  if [[ -n "$runner_pid" ]] && kill -0 "$runner_pid" 2>/dev/null; then
    kill -TERM "$runner_pid" 2>/dev/null || true  # the runner ends the app it started (its finally)
    wait "$runner_pid" 2>/dev/null || true
  fi
  tar -czf "$report" -C "$out" . 2>/dev/null || echo "signal-quit-probe: could not pack $out" >&2
  rm -rf "$work"
}
# shellcheck disable=SC2317,SC2329 # run by the traps below
on_signal() { echo "signal-quit-probe: signal $1; ending the probe" >&2; cleanup; exit $((128 + $2)); }
trap cleanup EXIT
trap 'on_signal TERM 15' TERM
trap 'on_signal INT 2' INT
trap 'on_signal HUP 1' HUP

# The app zip: the controller's signed store URL first, else its own GET, checked against the digest either way.
controller="${CMUX_CI_CONTROLLER:-http://100.89.225.106:18765}"
zip="$work/app.zip"
hex="${app_digest#sha256:}"
signed="$(curl --fail --silent --connect-timeout 5 --max-time 30 -A cmux-signal-quit-probe \
  "${controller%/}/v1/artifacts/sha256:$hex/url" 2>/dev/null |
  /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("url", ""))' 2>/dev/null || true)"
fetched=0
case "$signed" in https://*|http://*)
  curl --fail --silent --location --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 900 \
    -A cmux-signal-quit-probe -o "$zip" "$signed" 2>/dev/null && fetched=1 ;;
esac
unset signed  # a read capability: never printed
if (( ! fetched )); then
  curl --fail --silent --show-error --retry 3 --retry-delay 2 --connect-timeout 5 --max-time 900 \
    -A cmux-signal-quit-probe -o "$zip" "${controller%/}/v1/artifacts/sha256:$hex" || usage "could not download $app_digest"
fi
actual="$(/usr/bin/shasum -a 256 "$zip" | /usr/bin/awk '{print $1}')"
[[ "$actual" == "$hex" ]] || usage "the download is sha256:$actual, not $app_digest"
mkdir -p "$work/app"
/usr/bin/ditto -x -k "$zip" "$work/app" || usage "$app_digest is not an app zip"
rm -f "$zip"
app="$(/usr/bin/find "$work/app" -maxdepth 2 -name '*.app' -type d | /usr/bin/head -n 1)"
[[ -n "$app" ]] || usage "no .app in $app_digest"

# In the background and waited for, so a TERM reaches the trap at once (bash runs a trap only between commands).
status=0
/usr/bin/python3 -I - "$app" "$work" "$out" "$mode" "$real_home" <<'PY' &
import json, os, plistlib, signal, socket, subprocess, sys, threading, time, http.server

APP, WORK, OUT, MODE, REAL_HOME = sys.argv[1:6]
MODES = ["term", "int", "kill-app", "quit"] if MODE == "all" else [MODE]
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as handle:
    info = plistlib.load(handle)
BINARY = os.path.join(APP, "Contents/MacOS", info["CFBundleExecutable"])
EXEC_NAME = info["CFBundleExecutable"]
UBLOCK = os.path.isdir(os.path.join(APP, "Contents/Resources/Extensions/ublock-origin"))
REPORT_DIRS = [os.path.join(REAL_HOME, "Library/Logs/DiagnosticReports"), "/Library/Logs/DiagnosticReports"]
current = {"app": None}


def log(text):
    print("signal-quit-probe: " + text, flush=True)


def bundle_processes():
    """{pid: command} of every process whose executable is inside this probe's bundle."""
    found = {}
    try:
        listing = subprocess.run(["/bin/ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True,
                                 timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return found
    for line in listing.splitlines():
        pid, _, command = line.strip().partition(" ")
        if command.startswith(APP + "/") and pid.isdigit():
            found[int(pid)] = command
    return found


def reports():
    names = set()
    for folder in REPORT_DIRS:
        try:
            names.update(os.path.join(folder, n) for n in os.listdir(folder))
        except OSError:
            pass
    return names


def ours(path):
    base = os.path.basename(path)
    return base.startswith(EXEC_NAME) or ("Helper" in base and EXEC_NAME.split(" ")[0] in base)


def rpc(sock, method, params=None, timeout=10):
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


def wait(predicate, seconds, step=0.25):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # probe wait on an outside process, not app code
    return None


def serve():
    page = b"<!doctype html><title>sqp-ready</title><p>signal-quit probe</p>"

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(page)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/"


def shot(name):
    path = os.path.join(OUT, name + ".png")
    subprocess.run(["/usr/sbin/screencapture", "-x", path], timeout=30, check=False)
    return os.path.basename(path) if os.path.exists(path) else None


def end_all(signum=signal.SIGKILL):
    for pid in bundle_processes():
        try:
            os.kill(pid, signum)
        except OSError:
            pass


def run(mode, url):
    root = os.path.join(WORK, mode)
    home, tmp = os.path.join(root, "h"), os.path.join(root, "t")
    for sub in ("Library/Preferences", "Library/Application Support", "Library/Caches", "Library/Logs"):
        os.makedirs(os.path.join(home, sub), exist_ok=True)
    os.makedirs(tmp, exist_ok=True)
    sock = os.path.join(WORK, mode[:4] + ".sock")
    result = {"mode": mode, "ublock_bundled": UBLOCK, "failures": []}
    end_all()  # nothing of this bundle from an earlier mode
    env = {"HOME": home, "CFFIXED_USER_HOME": home, "TMPDIR": tmp + "/", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
           "USER": os.environ.get("USER", ""), "LOGNAME": os.environ.get("LOGNAME", ""), "LANG": "en_US.UTF-8",
           "SHELL": "/bin/zsh", "CMUX_NEXT_SOCKET_PATH": sock, "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_NO_ACTIVATE": "1", "ACPMUX_AGENT_LAUNCH": "deny",
           "CMUX_NEXT_TEST_WINDOW_FRAME": "60,60,1100,760"}
    with open(os.path.join(OUT, mode + "-app.log"), "w") as app_log:
        app = subprocess.Popen([BINARY], env=env, stdout=app_log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                               start_new_session=True)
    current["app"] = app
    try:
        if not wait(lambda: "error" not in (rpc(sock, "debug.focus") or {"error": 1}), 180):
            result["failures"].append("the app's socket never answered")
            return result
        rpc(sock, "action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True})
        extension = wait(lambda: [p for p, c in bundle_processes().items() if "--extension-process" in c], 90)
        result["extension_helpers"] = len(extension or [])
        if not extension:
            result["failures"].append("no extension helper started (uBlock never loaded)")
        time.sleep(3)  # probe settle: let the tab finish loading before the quit
        before = bundle_processes()
        result["processes_before"] = len(before)
        known_reports = reports()
        started = time.time()
        if mode == "term":
            for pid in before:
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError:
                    pass
        elif mode == "int":
            try:
                os.killpg(app.pid, signal.SIGINT)
            except OSError:
                pass
        elif mode == "kill-app":
            os.kill(app.pid, signal.SIGKILL)
        else:
            result["quit_answer"] = str(rpc(sock, "action.run", {"action": "quitKeepSessions"}, timeout=20))[:200]
        ext_pids = set(extension or [])
        gone_at, app_gone = {}, None
        shots = []
        while time.time() - started < 30:
            now = time.time() - started
            alive = bundle_processes()
            if app_gone is None and app.poll() is not None:
                app_gone = now
            for pid in before:
                if pid != app.pid and pid not in alive and pid not in gone_at:
                    gone_at[pid] = now
            if not shots and now >= 1.5:
                shots.append(shot(mode + "-1s5"))
            if app_gone is not None and not alive and now > 2:
                break
            time.sleep(0.1)  # probe sampling interval
        if app_gone is None and app.poll() is not None:
            app_gone = time.time() - started
        shots.append(shot(mode + "-after"))
        result["screenshots"] = [s for s in shots if s]
        result["app_exit"] = app.poll()
        result["app_gone_s"] = None if app_gone is None else round(app_gone, 2)
        early = sorted(round(gone_at[p], 2) for p in ext_pids if p in gone_at and (app_gone is None or gone_at[p] < app_gone - 0.05))
        result["extension_helper_ended_before_app_s"] = early
        if early:
            result["failures"].append("the extension helper ended while the app ran (the crash-balloon condition)")
        if app_gone is None:
            result["failures"].append("the app still ran 30 s after the quit")
        left = bundle_processes()
        result["left_behind"] = sorted(c.split(" --")[0].removeprefix(APP + "/") for c in left.values())
        if left and app_gone is not None:
            result["failures"].append("%d helper(s) still ran 30 s after the quit" % len(left))
        time.sleep(5)  # probe settle: ReportCrash writes a report a few seconds after the crash
        new = sorted(os.path.basename(p) for p in reports() - known_reports if ours(p))
        result["new_crash_reports"] = new
        if new:
            result["failures"].append("new crash report(s): " + ", ".join(new))
        return result
    finally:
        if app.poll() is None:
            rpc(sock, "action.run", {"action": "quitEndSessions"}, timeout=10)
            try:
                app.wait(20)
            except subprocess.TimeoutExpired:
                pass
        end_all()
        current["app"] = None


def on_term(signum, _frame):
    end_all()
    sys.exit(128 + signum)


signal.signal(signal.SIGTERM, on_term)
log("%s, uBlock bundled: %s, modes: %s" % (os.path.basename(APP), UBLOCK, ",".join(MODES)))
url = serve()
results = []
for mode in MODES:
    result = run(mode, url)
    results.append(result)
    log("%s: %s %s" % (mode, "PASS" if not result["failures"] else "FAIL", json.dumps(result, sort_keys=True)))
with open(os.path.join(OUT, "verdict.json"), "w") as handle:
    json.dump({"app": os.path.basename(APP), "results": results}, handle, indent=1, sort_keys=True)
failed = [r["mode"] for r in results if r["failures"]]
log("verdict: " + ("PASS" if not failed else "FAIL " + ",".join(failed)))
sys.exit(1 if failed else 0)
PY
runner_pid=$!
wait "$runner_pid" || status=$?
runner_pid=""
exit "$status"
