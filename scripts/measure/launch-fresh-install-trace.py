#!/usr/bin/env python3
"""One traced first launch (launch-fresh-install.sh trace=1) reduced to an LF-TRACE row.

usage: launch-fresh-install-trace.py FS_USAGE_TXT LOG_TXT APP RUN_JSON

fs_usage's wide lines end in "ELAPSED [W] COMMAND.THREAD". Times are ms after the spawn of the app's executable (the
posix_spawn or execve line naming APP's Contents/MacOS/), and spawn_elapsed is how long that call took. A check paid
inside exec makes spawn_elapsed long and everything of the app's after it; a check paid at dyld's load of the
framework makes the gap from the app's first file call to its open of CmuxNextApp.framework long.
"""
import json
import os
import plistlib
import re
import sys

LINE = re.compile(r"(\d\d:\d\d:\d\d\.\d+)\s+(.*?)\s+(\d+\.\d+)\s+W?\s*(.+)\.(\d+)\s*$")
CHECKERS = ("syspolicyd", "XprotectService", "amfid", "trustd")


def secs(stamp):
    h, m, s = stamp.split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def parse(path):
    events = []
    try:
        with open(path, errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return events
    for line in lines:
        m = LINE.match(line.rstrip())
        if m:
            events.append({"t": secs(m.group(1)), "body": m.group(2), "elapsed": float(m.group(3)),
                           "proc": m.group(4).strip()})
    return events


def top_files(checks, bundle, n=12):
    """The files inside the bundle the checkers spent the most call time on: [path in the bundle, calls, ms]."""
    per = {}
    for e in checks:
        m = re.search(re.escape(bundle) + r"(/\S*(?: \S+)*?)(?:\s+\S+=|$)", e["body"])
        path = m.group(1) if m else "?"
        calls, secs_ = per.get(path, (0, 0.0))
        per[path] = (calls + 1, secs_ + e["elapsed"])
    ranked = sorted(per.items(), key=lambda kv: -kv[1][1])[:n]
    return [[path, calls, round(s * 1000, 1)] for path, (calls, s) in ranked]


def reduce(events, log_lines, app, run):
    bundle = os.path.basename(app.rstrip("/"))
    exe = "cmux"
    try:
        with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
            exe = plistlib.load(f).get("CFBundleExecutable", exe)
    except (OSError, plistlib.InvalidFileException):
        pass
    spawns = [e for e in events if re.match(r"(posix_spawn|execve)\b", e["body"])
              and bundle in e["body"] and "/Contents/MacOS/" in e["body"]]
    out = {"tag": run.get("label"), "row": run.get("row"), "fs_events": len(events), "spawns": len(spawns)}
    if spawns:
        base = spawns[0]["t"]
        out["spawn_by"] = spawns[0]["proc"]
        out["spawn_elapsed"] = round(spawns[0]["elapsed"] * 1000, 1)

        def ms(t):
            return round((t - base) * 1000, 1)
        mine = [e for e in events if e["proc"] == exe and e["t"] >= base]
        out["app_first_call"] = ms(mine[0]["t"]) if mine else None
        hit = next((e for e in mine if "CmuxNextApp.framework" in e["body"]), None)
        out["app_open_framework"] = ms(hit["t"]) if hit else None
        hit = next((e for e in events if e["t"] >= base and "Chromium Embedded Framework" in e["body"]), None)
        out["chromium_first_open"] = ms(hit["t"]) if hit else None
        out["chromium_first_open_by"] = hit["proc"] if hit else None
        checks = [e for e in events if e["proc"] in CHECKERS and bundle in e["body"]]
        out["checker_reads"] = len(checks)
        if checks:
            out["checker_first_read"] = ms(checks[0]["t"])
            out["checker_last_read"] = ms(checks[-1]["t"])
            out["checker_reads_before_spawn"] = sum(1 for e in checks if e["t"] < base)
            out["checker_reads_after_first_call"] = sum(1 for e in checks if mine and e["t"] > mine[0]["t"])
        out["checker_files"] = top_files(checks, bundle)
    out["log_lines"] = len(log_lines)
    out["log_scan_lines"] = sum(1 for line in log_lines if re.search(r"(?i)xprotect|scan|assess|gatekeeper", line))
    return out


def main(argv):
    if len(argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        log_lines = open(argv[2], errors="replace").read().splitlines()
    except OSError:
        log_lines = []
    print("LF-TRACE", json.dumps(reduce(parse(argv[1]), log_lines, argv[3], json.loads(argv[4]))), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
