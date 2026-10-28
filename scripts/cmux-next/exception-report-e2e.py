#!/usr/bin/env python3
"""An Objective-C exception that ends the app is named at the next launch (bd cx-d0d.2;
crash-elimination.md section 3, class 10).

Two phases around a relaunch the caller does (a capture slot: `capture-host launch`):

  --phase raise   `debug.crash.exception` raises an NSException from a run-loop perform, which
                  AppKit catches in reportException: and crashes on (NSApplicationCrashOnExceptions,
                  cx-r3q). The app's process must end.
                  With --crash frozen it instead calls `debug.crash.app {"signal": "frozen"}`: a crash
                  path that blocks (a trap whose Mach exception nothing receives, the 2026-10-20
                  NIGHTLY freezes); the crash deadline must end the process, not before 8 s.
                  (--phase check applies to the exception crash only.)
                  --expect-reporting: Sentry must run in the app (launch it with
                  CMUX_NEXT_DEV_SENTRY=1), the setup that froze instead of crashing.
  --phase check   after the relaunch: `debug.crashes` says the previous run ended, its restart
                  notice names the exception, and the app's crash report holds its name and reason.

The script never launches or quits the app itself.

Usage: exception-report-e2e.py --socket <path> --phase raise|check [--app-pid PID]
       [--crash exception|frozen] [--expect-reporting] [--end-within SECONDS]
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--phase", required=True, choices=["raise", "check"])
parser.add_argument("--app-pid", type=int, help="raise: the app's pid, to see it end")
parser.add_argument("--crash", choices=["exception", "frozen"], default="exception",
                    help="raise: an NSException (default) or a crash path that blocks")
parser.add_argument("--expect-reporting", action="store_true",
                    help="raise: fail unless Sentry runs in the app (CMUX_NEXT_DEV_SENTRY=1)")
parser.add_argument("--end-within", type=float, default=30, help="raise: seconds the app has to end")
# Accepted for the capture-slot harness, which passes them to every e2e.
parser.add_argument("--runs", type=int, default=1)
parser.add_argument("--out", default="/tmp/exception-report-e2e")
opts = parser.parse_args()

EXCEPTION = "NSInternalInconsistencyException"
REASON = "debug.crash.exception"


def rpc(method, params=None, timeout=20):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
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
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def ended(pid):
    try:
        os.kill(pid, 0)
        return False
    except ProcessLookupError:
        return True
    except PermissionError:
        return False


if opts.phase == "raise":
    if not wait(lambda: "error" not in (rpc("debug.crashes", timeout=5) or {"error": "no reply"}), 60):
        sys.exit("FAIL the app does not answer on its socket")
    started = time.time()
    if opts.crash == "frozen":
        # The verb never replies: the main thread traps inside it.
        print(f"debug.crash.app frozen: {json.dumps(rpc('debug.crash.app', {'signal': 'frozen'}, timeout=5))}", flush=True)
    else:
        reply = rpc("debug.crash.exception") or {}
        print(f"debug.crash.exception: {json.dumps(reply)}", flush=True)
        if not reply.get("scheduled") or not reply.get("crash_on_exceptions"):
            sys.exit("FAIL the exception was not scheduled with NSApplicationCrashOnExceptions on")
        if opts.expect_reporting and not reply.get("crash_reporting"):
            sys.exit("FAIL Sentry does not run in the app (launch it with CMUX_NEXT_DEV_SENTRY=1)")
    if opts.app_pid and not wait(lambda: ended(opts.app_pid), opts.end_within):
        sys.exit(f"FAIL the app ({opts.app_pid}) still runs {opts.end_within:.0f} s after the {opts.crash} crash")
    elapsed = time.time() - started
    # A frozen crash that ended early never blocked (the dead exception port was not set): the
    # deadline (10 s) did not end it, so it proves nothing.
    if opts.crash == "frozen" and opts.app_pid and elapsed < 8:
        sys.exit(f"FAIL the frozen crash ended after {elapsed:.1f} s: its trap did not block, the deadline was not tested")
    print(f"PASS the {opts.crash} crash ended the app" + (f" after {elapsed:.1f} s" if opts.app_pid else ""))
    sys.exit(0)

report = wait(lambda: (lambda r: r if "error" not in r else None)(rpc("debug.crashes", timeout=5) or {"error": "no reply"}), 60)
if not report:
    sys.exit("FAIL the relaunched app does not answer on its socket")
launch = report.get("launch") or {}
print(json.dumps(launch, indent=1), flush=True)
failures = []
if (launch.get("previous") or {}).get("survived") is not False:
    failures.append("the previous run is not recorded as ended")
notice = launch.get("notice") or ""
if EXCEPTION not in notice:
    failures.append(f"the restart notice does not name {EXCEPTION}: {notice!r}")
path = launch.get("report")
text = ""
if path and os.path.exists(path):
    with open(path, errors="replace") as file:
        text = file.read()
if EXCEPTION not in text or REASON not in text:
    failures.append(f"the crash report ({path}) does not hold the exception's name and reason")
if failures:
    sys.exit("FAIL " + "; ".join(failures))
print("PASS the next launch names the exception")
