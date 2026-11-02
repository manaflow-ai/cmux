#!/usr/bin/env python3
"""Names the crashed thread of the test helper's crash reports from one run.

Usage: ips-crash-summary.py REPORTS_DIRS OUT_DIR SINCE_EPOCH [WAIT_SECONDS [PIDS]]

Reads the macOS crash reports (.ips) in REPORTS_DIRS written at or after
SINCE_EPOCH by a Swift test process (swiftpm-testing-helper, xctest or a
*PackageTests bundle), copies each to OUT_DIR for upload, and prints one line
per report: its file name, the exception and the crashed thread's top
symbolicated frames. ReportCrash writes a report a few seconds after the
process dies, so this waits up to WAIT_SECONDS (default 20) for the first one.
Never fails the caller.

REPORTS_DIRS is a colon-separated list, because there is more than one place a
report can land and looking in one of them is how a real crash reads as no
crash at all. A test helper on a CI Mac leaves its report in the SYSTEM
/Library/Logs/DiagnosticReports, not the $HOME one a login session gets, so a
lookup in $HOME alone found nothing for a run that had plainly died on signal 6
(cmux#25391, run 40330489336).

When nothing matches, this says what it looked at rather than staying quiet:
every directory, whether it exists, how many reports it holds and how many were
skipped as older than the run or as another process's. "No crash report from
this run" and "I looked in the wrong directory" are different facts, and the
caller cannot tell them apart from silence -- which is what made that signal 6
undiagnosable.

PIDS is a comma-separated list of the run's own pids (the `swift test` process
and the test helpers it saw). When given, a report counts only if its `pid` or
`parentPid` is one of them. A name and a time are not an identity: on a shared
CI Mac another job's swiftpm-testing-helper or PackageTests crash in the same
minutes matches both, and was read as this run's (or copied up beside it).
"""

import json
import os
import shutil
import sys
import time

PROCESSES = ("swiftpm-testing-helper", "xctest")
FRAMES = 8


def owner(path):
    """The report's pid and parent pid, from its body (or its header)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            header = json.loads(handle.readline() or "{}")
            body = json.loads(handle.read() or "{}")
    except (OSError, ValueError):
        return set()
    return {str(part.get(key)) for part in (body, header) for key in ("pid", "parentPid") if part.get(key) is not None}


def reports(directory, since, pids):
    """The matching reports in `directory`, and a count of what it passed over."""
    try:
        names = sorted(os.listdir(directory))
    except OSError as error:
        return [], f"{directory}: unreadable ({error.__class__.__name__})"
    found = []
    stale = 0
    other = 0
    for name in names:
        path = os.path.join(directory, name)
        if not name.endswith(".ips") or not os.path.isfile(path):
            continue
        if os.path.getmtime(path) < since:
            stale += 1
            continue
        if not (name.startswith(PROCESSES) or "PackageTests" in name):
            other += 1
        elif pids and not owner(path) & pids:
            # Same name, another job's process: a shared mini runs many.
            other += 1
        else:
            found.append(path)
    if found:
        return found, None
    return found, f"{directory}: {len(found)} matched, {stale} older than this run, {other} another process"


def summary(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        header = handle.readline()
        body = json.loads(handle.read() or "{}")
    process = json.loads(header or "{}").get("app_name") or os.path.basename(path)
    exception = body.get("exception") or {}
    cause = " ".join(str(exception.get(key)) for key in ("type", "signal") if exception.get(key)) or "unknown exception"
    threads = body.get("threads") or []
    crashed = next((thread for thread in threads if thread.get("triggered")), None)
    if crashed is None and isinstance(body.get("faultingThread"), int) and body["faultingThread"] < len(threads):
        crashed = threads[body["faultingThread"]]
    images = body.get("usedImages") or []
    frames = []
    for frame in (crashed or {}).get("frames") or []:
        symbol = frame.get("symbol")
        if not symbol:
            index = frame.get("imageIndex")
            image = images[index].get("name") if isinstance(index, int) and index < len(images) else None
            symbol = f"??? ({image})" if image else "???"
        frames.append(symbol)
        if len(frames) == FRAMES:
            break
    return f"{os.path.basename(path)} ({process}, {cause}): " + (" <- ".join(frames) or "no crashed thread")


def main(argv):
    if len(argv) not in (4, 5, 6):
        print(__doc__, file=sys.stderr)
        return 2
    directories = [part for part in argv[1].split(":") if part]
    out, since = argv[2], float(argv[3])
    deadline = time.time() + (float(argv[4]) if len(argv) >= 5 else 20.0)
    pids = {part for part in argv[5].split(",") if part} if len(argv) == 6 else set()

    def look():
        found = []
        missed = []
        for directory in directories:
            here, why = reports(directory, since, pids)
            found.extend(here)
            if why:
                missed.append(why)
        return found, missed

    found, missed = look()
    while not found and time.time() < deadline:
        time.sleep(1)
        found, missed = look()
    if not found:
        # Say where this looked. Silence here reads as "the process left no report",
        # which is a different fact from "this searched the wrong directory".
        print("no crash report matched; searched " + "; ".join(missed or directories))
        return 0
    os.makedirs(out, exist_ok=True)
    for path in found:
        try:
            shutil.copy2(path, out)
            print(summary(path))
        except (OSError, ValueError) as error:
            print(f"{os.path.basename(path)}: unreadable crash report ({error})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
