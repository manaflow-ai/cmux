#!/usr/bin/env python3
"""An Objective-C exception that ends the app is named at the next launch (bd cx-d0d.2;
crash-elimination.md section 3, class 10).

Two phases around a relaunch the caller does (a capture slot: `capture-host launch`):

  --phase raise   `debug.crash.exception` raises an NSException from a run-loop perform, which
                  AppKit catches in reportException: and crashes on (NSApplicationCrashOnExceptions,
                  cx-r3q). The app's process must end.
  --phase check   after the relaunch: `debug.crashes` says the previous run ended, its restart
                  notice names the exception, and the app's crash report holds its name and reason.

The script never launches or quits the app itself.

Usage: exception-report-e2e.py --socket <path> --phase raise|check [--app-pid PID]
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--phase", required=True, choices=["raise", "check"])
parser.add_argument("--app-pid", type=int, help="raise: the app's pid, to see it end")
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
    reply = rpc("debug.crash.exception") or {}
    print(f"debug.crash.exception: {json.dumps(reply)}", flush=True)
    if not reply.get("scheduled") or not reply.get("crash_on_exceptions"):
        sys.exit("FAIL the exception was not scheduled with NSApplicationCrashOnExceptions on")
    if opts.app_pid and not wait(lambda: ended(opts.app_pid), 30):
        sys.exit(f"FAIL the app ({opts.app_pid}) still runs after the exception")
    print("PASS the exception ended the app")
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
