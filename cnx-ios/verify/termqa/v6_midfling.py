"""VERIFY-round6: Jump to bottom tapped 100, 300 and 600 ms after a fling's touch-up
(user report), while output streams.

    python3 v6_midfling.py TAG [--reps 4]

Per rep: 3 flings toward older history (deep), settle, one more fling, then the Jump tap
DELAY s after the swipe command returned (touch-up). Records the run; afterwards checks
the button is gone and reads the app log's `jump to bottom (decelerating …)` lines.
"""
import argparse
import json
import os
import re
import subprocess
import time

import tq
import v6
from v6 import ev, ctx


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tag")
    ap.add_argument("--reps", type=int, default=4)
    a = ap.parse_args()
    s, m, j = ctx()
    t0 = time.strftime("%Y-%m-%d %H:%M:%S")
    j.hide_keyboard()
    # find the Jump button's centre once
    s.swipe(200, 250, 200, 650, duration=0.12)
    time.sleep(2)
    jb = v6.jump_button()
    if not jb:
        raise SystemExit("no Jump to bottom button after a fling")
    cx, cy = jb.center
    s.tap(cx, cy)
    time.sleep(2)
    video = tq.rec_start(a.tag)
    vt0 = json.load(open(os.path.expanduser("~/cnx-ios-e2e/termqa-state.json")))["rec"]["t0"]
    out = []
    for rep in range(a.reps):
        for delay in (0.1, 0.3, 0.6):
            for _ in range(3):
                s.swipe(200, 250, 200, 650, duration=0.12)
                time.sleep(0.35)
            time.sleep(2.0)  # settle deep in history
            ts = time.time()
            s.swipe(200, 250, 200, 650, duration=0.12)
            tu = time.time()  # the swipe command returned: touch-up delivered
            time.sleep(delay)
            tt = time.time()
            subprocess.run(["axe", "tap", "--udid", s.udid, "-x", f"{cx:.1f}", "-y", f"{cy:.1f}", "--tap-style", "simulator"],
                           capture_output=True, timeout=25)
            time.sleep(2.5)  # the jump lands
            gone = not v6.jump_button()
            r = {"rep": rep, "delay": delay, "swipe_v": round(ts - vt0, 2), "touch_up_v": round(tu - vt0, 2),
                 "tap_cmd_v": round(tt - vt0, 2), "jump_gone_after_2.5s": gone}
            out.append(r)
            ev("midfling", tag=a.tag, **r)
    tq.rec_stop()
    v6.applog(t0, os.path.join(v6.V6, f"{a.tag}.log"))
    lg = open(os.path.join(v6.V6, f"{a.tag}.log")).read()
    jumps = re.findall(r"jump to bottom \(decelerating (\w+), tracking (\w+)\) -> offset (\d+) of (\d+)", lg)
    res = {"video": video, "video_t0": vt0, "reps": out, "jump_logs": jumps,
           "settled_following": len(re.findall(r"settled -> following", lg))}
    json.dump(res, open(os.path.join(v6.V6, f"{a.tag}-result.json"), "w"), indent=1)
    print(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
