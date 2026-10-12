#!/usr/bin/env python3
"""Names the crashed thread of the test helper's crash reports from one run.

Usage: ips-crash-summary.py REPORTS_DIR OUT_DIR SINCE_EPOCH [WAIT_SECONDS]

Reads the macOS crash reports (.ips) in REPORTS_DIR written at or after
SINCE_EPOCH by a Swift test process (swiftpm-testing-helper, xctest or a
*PackageTests bundle), copies each to OUT_DIR for upload, and prints one line
per report: its file name, the exception and the crashed thread's top
symbolicated frames. ReportCrash writes a report a few seconds after the
process dies, so this waits up to WAIT_SECONDS (default 20) for the first one.
Prints nothing when there is none; never fails the caller.
"""

import json
import os
import shutil
import sys
import time

PROCESSES = ("swiftpm-testing-helper", "xctest")
FRAMES = 8


def reports(directory, since):
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return []
    found = []
    for name in names:
        path = os.path.join(directory, name)
        if not name.endswith(".ips") or not os.path.isfile(path) or os.path.getmtime(path) < since:
            continue
        if name.startswith(PROCESSES) or "PackageTests" in name:
            found.append(path)
    return found


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
    if len(argv) not in (4, 5):
        print(__doc__, file=sys.stderr)
        return 2
    directory, out, since = argv[1], argv[2], float(argv[3])
    deadline = time.time() + (float(argv[4]) if len(argv) == 5 else 20.0)
    found = reports(directory, since)
    while not found and time.time() < deadline:
        time.sleep(1)
        found = reports(directory, since)
    if found:
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
