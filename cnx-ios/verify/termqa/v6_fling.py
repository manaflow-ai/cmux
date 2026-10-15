"""VERIFY-round6: flings toward older history during fast output with the history at the
cap (V5-2, T-SCROLL-04), Jump to bottom from deep history after each trip (V5-1,
T-SCROLL-09), and optionally a drop while reading (V2-3, T-LIFE-09).

    python3 v6_fling.py TAG [--fill] [--trips 10] [--flings 10] [--drop]

Every command is typed on the phone (composer paste + Send). Records the whole run.
Writes verify6/TAG.log (app log), TAG-taps.json (host times of flings/jumps), TAG-result.json.
"""
import argparse
import json
import os
import re
import time

import tq
import v6
from v6 import ev, shot, ctx, ocr_rows, ids

GEN = "for i in $(seq 1 60000); do echo GEN-$i; sleep 0.01; done"
FILL = "for i in $(seq 100001 130000); do echo HIST-$i; done"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tag")
    ap.add_argument("--fill", action="store_true")
    ap.add_argument("--trips", type=int, default=10)
    ap.add_argument("--flings", type=int, default=10)
    ap.add_argument("--drop", action="store_true")
    ap.add_argument("--no-gen", action="store_true")
    a = ap.parse_args()
    s, m, j = ctx()
    t0 = time.strftime("%Y-%m-%d %H:%M:%S")
    v6.clear_composer()
    if not a.no_gen:
        v6.interrupt()
    if a.fill:
        tq.paste_composer(FILL)
        j.hide_keyboard()
        time.sleep(20)  # stimulus pacing: the fill streams (30k rows)
    if not a.no_gen:
        tq.paste_composer(GEN)
    j.hide_keyboard()
    time.sleep(3)  # stimulus pacing: the loop streams
    video = tq.rec_start(a.tag)
    vt0 = json.load(open(os.path.expanduser("~/cnx-ios-e2e/termqa-state.json")))["rec"]["t0"]
    ev("rec_start", tag=a.tag, video=video)
    taps = []
    trips = []
    for trip in range(a.trips):
        for _ in range(a.flings):
            t = time.time()
            s.swipe(200, 250, 200, 650, duration=0.12)
            taps.append({"t": t, "kind": "swipe", "dur": 0.12})
            time.sleep(0.35)  # stimulus pacing between flings
        time.sleep(2.5)  # the last fling settles
        jb = v6.jump_button()
        rec = {"trip": trip, "jump_visible_before": bool(jb), "top_before": ids(ocr_rows(60, 300))[:3]}
        if a.drop and trip == a.trips - 1:
            rec["before"] = ids(ocr_rows(60, 520))[:6]
            tk = v6.kill_hostd()
            rec["kill"] = tk
            ev("kill", tag=a.tag, trip=trip, before=rec["before"])
            time.sleep(10)  # reconnect plus replay
            rec["after"] = ids(ocr_rows(60, 520))[:6]
            rec["hostd"] = v6.hostd_events(tk - 1)
            ev("drop_report", tag=a.tag, before=rec["before"], after=rec["after"], hostd=rec["hostd"])
            jb = v6.jump_button()
            rec["jump_visible_after_drop"] = bool(jb)
        if jb:
            t = time.time()
            s.tap(*jb.center)
            taps.append({"t": t, "kind": "tap", "dur": 0.1, "what": "jump"})
            rec["jump_tap"] = round(t - vt0, 2)
            time.sleep(2.5)  # the jump lands and follows
            rec["jump_visible_after"] = bool(v6.jump_button())
        trips.append(rec)
        ev("trip", tag=a.tag, **{k: v for k, v in rec.items() if k != "hostd"})
    tq.rec_stop()
    ev("rec_stop", tag=a.tag)
    v6.applog(t0, os.path.join(v6.V6, f"{a.tag}.log"))
    json.dump({"video_t0": vt0, "taps": taps}, open(os.path.join(v6.V6, f"{a.tag}-taps.json"), "w"))
    lg = open(os.path.join(v6.V6, f"{a.tag}.log")).read()
    res = {"tag": a.tag, "video": video, "flings": sum(1 for x in taps if x["kind"] == "swipe"),
           "jumps": sum(1 for x in taps if x["kind"] == "tap"),
           "fling_reached_bottom": lg.count("a fling reached the bottom"),
           "history_pruned": lg.count("history pruned"),
           "settled_following": len(re.findall(r"settled -> following", lg)),
           "settled_reading": len(re.findall(r"settled -> reading", lg)),
           "jump_logs": lg.count("scroll: jump to bottom"),
           "trips": trips}
    json.dump(res, open(os.path.join(v6.V6, f"{a.tag}-result.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in res.items() if k != "trips"}))
    for t in trips:
        print(t)


if __name__ == "__main__":
    main()
