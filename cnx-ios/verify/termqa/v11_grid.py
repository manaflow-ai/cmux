"""Round-11 verifier, V2-1 / T-TABS-03 (black frames only) and V3-4 / T-TABS-14: a GEN loop typed
on the phone streams in e2e-t2; N grid round trips (Tabs -> the e2e-t2 card); the grid's AX
tree is dumped on the first trip.
    TQ_BUNDLE=... python3 v11.py v11_grid TAG [N=10]"""
import json, os, subprocess, sys, time
import tq, v8
from v8 import ev
HERE = os.path.dirname(os.path.abspath(__file__))

def main():
    tag = sys.argv[1]; n = int(sys.argv[2]) if len(sys.argv) > 2 else 10
    s, m, j = tq.ctx()
    tq.paste_composer("for i in $(seq 1 60000); do echo GEN-$i; sleep 0.01; done")
    time.sleep(1); j.hide_keyboard(); time.sleep(3)
    video = tq.rec_start(tag); vt0 = tq.load()["rec"]["t0"]
    trips = []
    for i in range(n):
        ta = time.time(); s.tap_q(label="Tabs", kind="Button"); time.sleep(1.8)
        if i == 0:
            els = s.tree()
            with open(os.path.join(v8.V6, f"{tag}-grid-ax.txt"), "w") as f:
                for e in els:
                    f.write(repr(e) + "\n")
        c = [e for e in s.find(kind="Button") if (e.label or "").startswith("e2e-t2, tab")]
        tb = time.time()
        if c: s.tap_el(c[0])
        time.sleep(1.8)
        trips.append((round(ta - vt0, 2), round(tb - vt0, 2), bool(c)))
    tq.rec_stop(); v8.interrupt()
    bj = os.path.join(v8.V6, f"{tag}-black.json")
    subprocess.run([sys.executable, os.path.join(HERE, "v8v_black.py"), video, "--json", bj], capture_output=True)
    b = json.load(open(bj))
    ev("grid", tag=tag, trips=trips, video_black_runs=[(r["start"], r["dur_ms"]) for r in b["black_runs"]],
       frac_gaps_over_34ms=b["frac_gaps_over_34ms"])

if __name__ == "__main__":
    main()
