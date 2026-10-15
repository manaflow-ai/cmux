"""Frame log over a run window: every frame-save (time, its ms, the frame's dt), the
longest frames while following, and hitches (> 33.4 ms at 60 Hz).
    python3 v11_hitch.py TAG T0 T1"""
import json, os, sys, subprocess
tag, t0, t1 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
U = json.load(open(os.path.expanduser("~/cnx-ios-e2e/termqa-state.json")))["udid"]
d = subprocess.run(["xcrun", "simctl", "get_app_container", U, os.environ.get("TQ_BUNDLE", "dev.cmux.cnx.tq10"), "data"], capture_output=True, text=True).stdout.strip()
rs = []
with open(os.path.join(d, "Documents", "frame-log.ndjson")) as f:
    for line in f:
        if not line.startswith('{"t":17'):
            continue
        t = float(line[5:line.index(",")])
        if t0 <= t <= t1:
            try: rs.append(json.loads(line))
            except ValueError: pass
saves = [{"t": round(r["t"] - t0, 2), "save_ms": r["parts"]["frame-save"], "dt_ms": r["dt_ms"], "work_ms": r["work_ms"], "phase": r["phase"], "surface": r["surface"]}
         for r in rs if "frame-save" in r.get("parts", {})]
# the frame after a save: did the save make the next frame late?
idx = {id(r): i for i, r in enumerate(rs)}
after = []
for i, r in enumerate(rs):
    if "frame-save" in r.get("parts", {}) and i + 1 < len(rs):
        after.append(rs[i + 1]["dt_ms"])
fol = [r for r in rs if r["phase"] == "following"]
longest = sorted(fol, key=lambda r: -r["dt_ms"])[:10]
hit = [r for r in fol if r["dt_ms"] > 33.4]
gaps = [round(b["t"] - a["t"], 2) for a, b in zip(saves, saves[1:])]
out = {"tag": tag, "frames": len(rs), "following_frames": len(fol), "saves": saves, "save_interval_s": gaps,
       "save_ms_max": max((s["save_ms"] for s in saves), default=None),
       "dt_of_frame_after_save": after,
       "following_hitches_over_33ms": len(hit), "following_over_100ms": sum(1 for r in fol if r["dt_ms"] > 100),
       "following_longest": [{"t": round(r["t"] - t0, 2), "dt_ms": r["dt_ms"], "work_ms": r["work_ms"], "parts": r.get("parts")} for r in longest]}
vd = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../design/terminal/verify11")
json.dump(out, open(os.path.join(vd, f"{tag}-hitch.json"), "w"), indent=1)
print(json.dumps({k: v for k, v in out.items() if k not in ("saves",)}, default=str)[:1800])
