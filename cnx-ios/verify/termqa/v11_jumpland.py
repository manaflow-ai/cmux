"""Landing per jump from TAG-jumpocr.json: the first frame (from the pill-off frame on) whose
OCR window is within 3 rows of the steady bottom, where the steady bottom is a frame whose
next frame advances by fewer than 8 rows. Also: is the motion monotonic (no window going back)."""
import json, sys, os
tag = sys.argv[1]
vd = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../design/terminal/verify11")
d = json.load(open(os.path.join(vd, f"{tag}-jumpocr.json")))
out = []
for r in d["jumps"]:
    seq = [s for s in r["seq"] if s[0] >= r["pill_off_frame"] and s[3]]
    land = None
    for a, b in zip(seq, seq[1:]):
        if 0 <= b[3][1] - a[3][1] < 8:
            land = a; break
    mono = all(b[3][1] >= a[3][1] for a, b in zip(seq, seq[1:]))
    inter = 0 if not seq or not land else sum(1 for s in seq if s[1] < land[1])
    out.append({"pill_off_t": r["pill_off_t"], "land_t": land[1] if land else None,
                "land_ms_from_pill_off": round((land[1] - r["pill_off_t"]) * 1000, 1) if land else None,
                "intermediate_frames": inter, "monotonic": mono})
L = sorted(x["land_ms_from_pill_off"] for x in out if x["land_ms_from_pill_off"] is not None)
summ = {"tag": tag, "n": len(out), "landed_seen": len(L), "land_ms_max": L[-1] if L else None,
        "land_ms_p50": L[len(L)//2] if L else None, "over_400": sum(1 for x in L if x > 400),
        "non_monotonic": sum(1 for x in out if not x["monotonic"]),
        "intermediate_frames_hist": {k: sum(1 for x in out if x["intermediate_frames"] == k) for k in sorted({x["intermediate_frames"] for x in out})}}
json.dump({"summary": summ, "jumps": out}, open(os.path.join(vd, f"{tag}-jumpland.json"), "w"), indent=1)
print(json.dumps(summ))
