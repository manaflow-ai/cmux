#!/usr/bin/env python3
"""launch-ready-cef.py: one launch-ready LR-RUN row (JSON on stdin) with Chromium's start added to its marks, from the
app's own unified log line `CEF ready trigger=... load=... map=... initialize=...` (CEFRuntime.finishStart), printed
as the same row (JSON) on stdout. launch-ready.sh engines= runs it after each launch.

Marks added, in ms from the app's process start (the clock of every other mark): cef.ready (the log line, as
CefInitialize returned) and cef.initialize_start (cef.ready less CefInitialize's duration); and durations, in ms:
cef.initialize_dur (CefInitialize on the main thread), cef.load_dur (the shim and framework load) and cef.map_dur (the
framework map). cef_started is true when the launch logged the line, false when Chromium never started before the
quit, and the line's trigger is cef_trigger. A release build serves no `debug.cef`, so the log is the one source.

The row's pid and start_epoch_ms pick the launch; `log show` reads the store, so this runs after the app quit.
"""
import datetime
import json
import re
import subprocess
import sys

DURATION = re.compile(r"\b(load|map|initialize)=([0-9.eE+-]+) seconds")
TRIGGER = re.compile(r"trigger=(\S+)")


def main() -> int:
    row = json.loads(sys.stdin.read())
    pid, start = row.get("pid"), row.get("start_epoch_ms")
    if not pid or not start:
        print(json.dumps(row))
        return 0
    since = datetime.datetime.fromtimestamp(start / 1000 - 1).strftime("%Y-%m-%d %H:%M:%S")
    predicate = f'processID == {int(pid)} AND subsystem == "com.cmuxterm.app.next" AND category == "cef"'
    try:
        shown = subprocess.run(["/usr/bin/log", "show", "--style", "ndjson", "--info", "--start", since,
                                "--predicate", predicate], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as error:
        row["cef_log_error"] = str(error)
        print(json.dumps(row))
        return 0
    if shown.returncode != 0:  # unread is not "never started"
        row["cef_log_error"] = f"log show exited {shown.returncode}: {shown.stderr.strip()[:300]}"
        print(json.dumps(row))
        return 0
    print(json.dumps(add_marks(row, shown.stdout)))
    return 0


def add_marks(row: dict, ndjson: str) -> dict:
    """ROW with Chromium's start from `log show --style ndjson` output NDJSON (the launch's first `CEF ready` line)."""
    start = row["start_epoch_ms"]
    ready = None
    for line in ndjson.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if (event.get("eventMessage") or "").startswith("CEF ready"):
            ready = event
            break
    row["cef_started"] = ready is not None
    if ready is not None:
        message = ready["eventMessage"]
        stamp = datetime.datetime.strptime(ready["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z").timestamp() * 1000
        marks = row.setdefault("marks", {})
        marks["cef.ready"] = round(stamp - start, 1)
        durations = {name: float(value) * 1000 for name, value in DURATION.findall(message)}
        for name, ms in durations.items():
            marks[f"cef.{name}_dur"] = round(ms, 1)
        if "initialize" in durations:
            marks["cef.initialize_start"] = round(stamp - start - durations["initialize"], 1)
        trigger = TRIGGER.search(message)
        row["cef_trigger"] = trigger.group(1) if trigger else None
    return row


if __name__ == "__main__":
    sys.exit(main())
