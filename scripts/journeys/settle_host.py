#!/usr/bin/python3 -I
"""Wait out the Shortcuts load that each lease's new bundles cause, before the first measured journey (HARNESS CORES,
STATUS 7817). Runs on the mini under the stock /usr/bin/python3 (standard library only); read-only for the system.

  settle_host.py --app CLONE.app [--max-seconds 75] [--quiet-seconds 20] [--interval 0.5]

Each LaunchServices registration of a new bundle (a lease registers 3 to 4: the virtual display app, the app clone,
the clone's CEF helper bundles when the app first starts them) makes siriactionsd start a BackgroundShortcutRunner
twice: about 3 s later for 0.6 s and about 14 s later for 5-6 s, at about 65 % CPU, plus siriactionsd at 25-30 %.
The helpers register up to 30 s after launch, inside the first journeys (cmux22 and cmux18 logs, 2026-11-02).

1. Registers the clone's nested helper apps (CLONE/Contents/Frameworks/*.app) with lsregister now, the same
   registration their first launch does, so their burst comes during this wait and not in a journey.
2. Waits until no BackgroundShortcutRunner runs and siriactionsd is under 2 % CPU for --quiet-seconds without a
   break (and at least that long from the start), at most --max-seconds.
Prints one JSON line: {"registered", "register_errors", "waited_s", "quiet", "runners_seen", "siriactionsd_max_pcpu"}.
--ps and --lsregister replace the tools (tests).
"""
import argparse
import glob
import json
import os
import subprocess
import time

LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
RUNNER = "BackgroundShortcutRunner"
DAEMON = "siriactionsd"
DAEMON_BUSY_PCPU = 2.0


def processes(ps):
    """[(pid, pcpu, command)] of every process (ps -A)."""
    out = subprocess.run(ps + ["-A", "-o", "pid=,pcpu=,comm="], capture_output=True, text=True, timeout=10).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3:
            try:
                rows.append((int(parts[0]), float(parts[1]), parts[2]))
            except ValueError:
                continue
    return rows


def register_helpers(app, lsregister):
    registered, errors = [], []
    for helper in sorted(glob.glob(os.path.join(app, "Contents", "Frameworks", "*.app"))):
        try:
            done = subprocess.run(lsregister + ["-f", helper], capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as error:
            errors.append(f"{os.path.basename(helper)}: {error}"[:200])
            continue
        (registered if done.returncode == 0 else errors).append(
            os.path.basename(helper) if done.returncode == 0 else f"{os.path.basename(helper)}: exit {done.returncode} {done.stderr.strip()[-120:]}")
    return registered, errors


def settle(ps, max_seconds, quiet_seconds, interval, clock=time.monotonic, sleep=time.sleep):
    start = clock()
    quiet_since = start
    runners, daemon_max = set(), 0.0
    while True:
        now = clock()
        busy = False
        try:
            rows = processes(ps)
        except (OSError, subprocess.TimeoutExpired):
            rows, busy = [], True  # no reading is not quiet
        for pid, pcpu, command in rows:
            name = os.path.basename(command)
            if RUNNER in name:
                runners.add(pid)
                busy = True
            elif name == DAEMON:
                daemon_max = max(daemon_max, pcpu)
                busy = busy or pcpu >= DAEMON_BUSY_PCPU
        if busy:
            quiet_since = now
        if now - quiet_since >= quiet_seconds and now - start >= quiet_seconds:
            return {"waited_s": round(now - start, 1), "quiet": True, "runners_seen": len(runners),
                    "siriactionsd_max_pcpu": daemon_max}
        if now - start >= max_seconds:
            return {"waited_s": round(now - start, 1), "quiet": False, "runners_seen": len(runners),
                    "siriactionsd_max_pcpu": daemon_max}
        sleep(interval)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", required=True)
    ap.add_argument("--max-seconds", type=float, default=75.0)
    ap.add_argument("--quiet-seconds", type=float, default=20.0)
    ap.add_argument("--interval", type=float, default=0.5)
    ap.add_argument("--ps", default="/bin/ps")
    ap.add_argument("--lsregister", default=LSREGISTER)
    o = ap.parse_args()
    registered, errors = register_helpers(o.app, [o.lsregister])
    result = settle([o.ps], o.max_seconds, o.quiet_seconds, o.interval)
    result.update({"registered": registered, "register_errors": errors})
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
