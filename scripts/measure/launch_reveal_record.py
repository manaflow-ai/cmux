#!/usr/bin/env python3
"""The display recording of launch-reveal-capture.sh, through CuaDriver (the fleet's granted recorder).

`screencapture -v` run by the fleet step holds no Screen Recording grant on any fleet Mac (share-grant.sh status,
2026-11-25: cmux20's run of the NIGHTLY wrote no .mov, cold or relaunch, and the step still passed). CuaDriver is the
one signed app the fleet grants it; tab_switch_capture.CuaSession drives it the way tab-switch.sh does.

  launch_reveal_record.py preflight           exit 0 when CuaDriver starts and holds Screen Recording, else 3
  launch_reveal_record.py record DIR SECONDS  record the main display SECONDS seconds into DIR; prints
                                              `READY epoch_ms=N` once the stream runs and `VIDEO PATH` at the end
Exit 3 when it cannot record (the reason on stdout as `CANNOT ...`).
"""
from __future__ import annotations

import os
import signal
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cmux-next"))
from tab_switch_capture import CaptureError, CuaSession, preflight  # noqa: E402


def record(folder, seconds):
    session = CuaSession()
    stop_early = []
    signal.signal(signal.SIGTERM, lambda *_: stop_early.append(True))
    try:
        session.open()
        session.start(folder)
        print(f"READY epoch_ms={int(time.time() * 1000)}", flush=True)
        end = time.monotonic() + seconds
        while time.monotonic() < end and not stop_early:
            time.sleep(0.1)  # sleep-ok: the recording window itself
        print(f"VIDEO {session.stop(folder)}", flush=True)
        return 0
    finally:
        session.close()


def main(argv):
    try:
        if argv[1:2] == ["preflight"] and len(argv) == 2:
            preflight()
            print("READY cua-driver holds Screen Recording")
            return 0
        if argv[1:2] == ["record"] and len(argv) == 4:
            return record(argv[2], float(argv[3]))
    except CaptureError as error:
        print(f"CANNOT {error}", flush=True)
        return 3
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
