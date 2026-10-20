"""Pixel pin scan: per frame, the composer card's top edge (pixel scan of the card's fill)
and the bottom edge of the lowest lit text row above it. Prints json summary.
usage: pin.py VIDEO OUT.json [--fps 10] [--start S] [--dur D] [--ymax-pt 800]"""
import json, subprocess, sys, os, tempfile
import numpy as np
from PIL import Image
a = sys.argv
video, out = a[1], a[2]
def opt(n, d):
    return float(a[a.index(n) + 1]) if n in a else d
fps, start, dur = opt("--fps", 10), opt("--start", 0), opt("--dur", 0)
ymin = opt("--ymin", 200)
d = tempfile.mkdtemp(prefix="pin-")
cmd = ["ffmpeg", "-v", "error", "-ss", str(start)] + (["-t", str(dur)] if dur else []) + ["-i", video, "-vf", f"fps={fps}", f"{d}/f%05d.png"]
subprocess.run(cmd, check=True)
res = []
for i, f in enumerate(sorted(os.listdir(d))):
    im = np.asarray(Image.open(os.path.join(d, f)).convert("L"), dtype=np.int16)
    H, W = im.shape
    s = W / 402.0
    # composer card: the first y (from 600 pt down) where the row's median luma in x 40..360 pt
    # rises above the black terminal (card fill ~ 20-35) and stays for 10 px.
    xs = slice(int(150 * s), int(330 * s))
    med = np.median(im[:, xs], axis=1)
    card = None
    for y in range(int(ymin * s), int(860 * s)):
        if med[y] >= 18 and np.mean(med[y + 4:y + int(10 * s)]) >= 1.2:
            card = y; break
    # lowest text row above the card: rows with > 3 px of luma > 90 (text), searching upward
    lit = (im[:, int(2 * s):int(400 * s)] > 90).sum(axis=1)
    bottom = None
    if card:
        for y in range(card - 2, int(40 * s), -1):
            if lit[y] > 3:
                bottom = y; break
    res.append({"i": i, "t": round(start + i / fps, 2), "card_top_pt": round(card / s, 2) if card else None,
                "text_bottom_pt": round(bottom / s, 2) if bottom else None,
                "gap_pt": round((card - bottom) / s, 2) if card and bottom else None})
for f in os.listdir(d): os.remove(os.path.join(d, f))
os.rmdir(d)
gaps = [r["gap_pt"] for r in res if r["gap_pt"] is not None]
summ = {"frames": len(res), "with_gap": len(gaps), "gap_min": min(gaps) if gaps else None, "gap_max": max(gaps) if gaps else None,
        "gap_median": float(np.median(gaps)) if gaps else None,
        "frames_gap_negative": sum(1 for g in gaps if g < 0), "frames_gap_over_row": sum(1 for g in gaps if g > 20),
        "card_top_values": sorted(set(r["card_top_pt"] for r in res if r["card_top_pt"]))[:10]}
json.dump({"summary": summ, "frames": res}, open(out, "w"))
print(json.dumps(summ))
