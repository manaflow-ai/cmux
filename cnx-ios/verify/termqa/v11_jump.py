"""Round-11 verifier: per Jump to bottom tap, (a) is the pill gone in the first frame the
jump changes the page, and in the first source frame after the app handled the tap;
(b) landing time: the app's tap handling (`scroll: jump to bottom` log line) to the first
frame-log record in phase `following`; (c) black frames in the window.

    python3 v11_jump.py TAG [VERIFY_DIR] [RAW_DIR]
Reads VERIFY_DIR/TAG.log, TAG-result.json, events.jsonl (rec t0), the app's frame log, and
RAW_DIR/TAG.mp4. Writes VERIFY_DIR/TAG-jump.json.
"""
import datetime
import json
import os
import re
import subprocess
import sys

import numpy as np

W, H = 402, 874           # decode size (pt)
PILL = (268, 708, 116, 22)  # x, y, w, h in pt: the "Jump to bottom" label
BAND = (0, 70, 402, 620)


def frames(video):
    pts = [float(x.strip(",")) for x in subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=pts_time", "-of", "csv=p=0", video],
        capture_output=True, text=True).stdout.split() if x.strip(", ")]
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", video, "-fps_mode", "passthrough", "-vf", f"scale={W}:{H}",
                          "-pix_fmt", "gray", "-f", "rawvideo", "-"], capture_output=True).stdout
    n = len(raw) // (W * H)
    arr = np.frombuffer(raw[: n * W * H], dtype=np.uint8).reshape(n, H, W)
    return pts[:n], arr


def crop(a, box):
    x, y, w, h = box
    return a[y:y + h, x:x + w]


def main():
    tag = sys.argv[1]
    vd = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), "../design/terminal/verify11")
    rd = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser("~/cnx-ios-e2e/termqa-raw/tv11")
    t0 = [json.loads(l) for l in open(os.path.join(vd, "events.jsonl")) if '"rec_start"' in l and f'"name": "{tag}"' in l][-1]["t0"]
    jumps = []
    for line in open(os.path.join(vd, f"{tag}.log"), errors="replace"):
        if "scroll: jump to bottom" in line:
            ts = datetime.datetime.strptime(line[:23], "%Y-%m-%d %H:%M:%S.%f").timestamp()
            jumps.append(ts)
    U = json.load(open(os.path.expanduser("~/cnx-ios-e2e/termqa-state.json")))["udid"]
    d = subprocess.run(["xcrun", "simctl", "get_app_container", U, os.environ.get("TQ_BUNDLE", "dev.cmux.cnx.tq10"), "data"],
                       capture_output=True, text=True).stdout.strip()
    fl = []
    lo, hi = (jumps[0] - 5, jumps[-1] + 5) if jumps else (0, 0)
    with open(os.path.join(d, "Documents", "frame-log.ndjson")) as f:
        for line in f:
            if not line.startswith('{"t":17'):
                continue
            t = float(line[5:line.index(",")])
            if lo <= t <= hi:
                try:
                    fl.append(json.loads(line))
                except ValueError:
                    pass
    pts, arr = frames(os.path.join(rd, f"{tag}.mp4"))
    pill = np.array([(crop(a, PILL) > 140).mean() for a in arr])
    band = arr[:, BAND[1]:BAND[1] + BAND[3], :].astype(np.int16)
    diff = np.concatenate([[0.0], np.abs(band[1:] - band[:-1]).mean(axis=(1, 2))])
    lit = (band > 60).mean(axis=(1, 2))
    pill_on = float(np.median(pill[pill > 0.02])) if (pill > 0.02).any() else 0.0
    out = []
    for tj in jumps:
        vt = tj - t0
        idx = [i for i, p in enumerate(pts) if vt - 1.0 <= p <= vt + 1.5]
        if not idx:
            out.append({"t_v": round(vt, 3), "error": "no frames"}); continue
        # The first frame the jump changes the page: a big band change from vt - 0.3 s on.
        ch = next((i for i in idx if pts[i] >= vt - 0.3 and diff[i] > 6.0), None)
        first_after = next((i for i in idx if pts[i] > vt), None)
        land = next((r for r in fl if r["t"] > tj and r["phase"] == "following"), None)
        blank_fl = sum(1 for r in fl if tj - 0.2 <= r["t"] <= tj + 1.0 and r.get("blank"))
        black = [round(pts[i], 3) for i in idx if lit[i] < 0.004]
        rec = {"t_v": round(vt, 3),
               "first_change_v": round(pts[ch], 3) if ch is not None else None,
               "pill_at_first_change": round(float(pill[ch]), 3) if ch is not None else None,
               "pill_frame_before_change": round(float(pill[ch - 1]), 3) if ch else None,
               "first_frame_after_tap_v": round(pts[first_after], 3) if first_after is not None else None,
               "pill_first_frame_after_tap": round(float(pill[first_after]), 3) if first_after is not None else None,
               "land_ms": round((land["t"] - tj) * 1000, 1) if land else None,
               "framelog_blank_frames": blank_fl, "video_black_frames_v": black}
        rec["pill_gone_at_change"] = rec["pill_at_first_change"] is not None and rec["pill_at_first_change"] < pill_on * 0.3
        rec["pill_gone_first_after_tap"] = rec["pill_first_frame_after_tap"] is not None and rec["pill_first_frame_after_tap"] < pill_on * 0.3
        out.append(rec)
    lands = sorted(r["land_ms"] for r in out if r.get("land_ms") is not None)
    pct = lambda q: lands[min(len(lands) - 1, int(q * len(lands)))] if lands else None
    summ = {"tag": tag, "jumps": len(out), "pill_on_level": round(pill_on, 3),
            "pill_visible_at_first_change": sum(1 for r in out if r.get("pill_at_first_change") is not None and not r["pill_gone_at_change"]),
            "pill_visible_first_frame_after_tap": sum(1 for r in out if r.get("pill_first_frame_after_tap") is not None and not r["pill_gone_first_after_tap"]),
            "no_change_found": sum(1 for r in out if r.get("first_change_v") is None),
            "land_ms_p50": pct(0.5), "land_ms_p95": pct(0.95), "land_ms_max": lands[-1] if lands else None,
            "land_over_400ms": sum(1 for x in lands if x > 400),
            "video_black_frames": sum(len(r.get("video_black_frames_v", [])) for r in out),
            "framelog_blank_frames": sum(r.get("framelog_blank_frames", 0) for r in out)}
    json.dump({"summary": summ, "jumps": out}, open(os.path.join(vd, f"{tag}-jump.json"), "w"), indent=1)
    print(json.dumps(summ))



def ocr_check(tag, vd=None, rd=None, k=4):
    """Source-frame check: around each pill-off frame, OCR GEN ids of k frames before and
    after. The pill must be gone no later than the first frame showing the jump's rows;
    landing = first frame at the final window minus the pill-off frame."""
    import tempfile, shutil
    import rows as R
    vd = vd or os.path.join(os.path.dirname(os.path.abspath(__file__)), "../design/terminal/verify11")
    rd = rd or os.path.expanduser("~/cnx-ios-e2e/termqa-raw/tv11")
    video = os.path.join(rd, f"{tag}.mp4")
    pts, arr = frames(video)
    pill = np.array([(crop(a, PILL) > 140).mean() for a in arr])
    on = float(np.median(pill[pill > 0.02]))
    offs = [i for i in range(1, len(pill)) if pill[i - 1] > on * 0.6 and pill[i] < on * 0.3]
    want = sorted({j for i in offs for j in range(max(0, i - k), min(len(pts), i + k + 1))})
    d = tempfile.mkdtemp(prefix="v11j-")
    from PIL import Image
    wset = set(want)
    CW, CH = 420, 1860
    pr = subprocess.Popen(["ffmpeg", "-v", "error", "-i", video, "-fps_mode", "passthrough", "-vf", f"crop={CW}:{CH}:0:210",
                           "-pix_fmt", "gray", "-f", "rawvideo", "-"], stdout=subprocess.PIPE)
    n = 0
    while True:
        buf = pr.stdout.read(CW * CH)
        if len(buf) < CW * CH:
            break
        if n in wset:
            Image.frombytes("L", (CW, CH), buf).save(os.path.join(d, f"f{n:06d}.png"))
        n += 1
    pr.wait()
    files = sorted(f for f in os.listdir(d) if f.endswith(".png"))
    res = R.ocr([os.path.join(d, f) for f in files], 1, 2)
    idmap = {}
    rx = re.compile(r"GEN-(\d+)")
    for f in files:
        j = int(f[1:7])
        ids = [int(m.group(1)) for *_, t in res.get(os.path.join(d, f), []) for m in rx.finditer(t)]
        idmap[j] = (min(ids), max(ids)) if ids else None
    shutil.rmtree(d, ignore_errors=True)
    out = []
    for i in offs:
        seq = [(j, round(pts[j], 3), round(float(pill[j]), 3), idmap.get(j)) for j in range(max(0, i - k), min(len(pts), i + k + 1))]
        before = idmap.get(i - 1)
        # first frame (from i-k) whose max id jumped by > 100 rows from frame i-k's
        base = idmap.get(max(0, i - k))
        jump_f = next((j for j, _, _, w in seq if w and base and w[1] - base[1] > 100), None)
        out.append({"pill_off_frame": i, "pill_off_t": round(pts[i], 3),
                    "jump_frame": jump_f, "jump_t": round(pts[jump_f], 3) if jump_f is not None else None,
                    "pill_visible_on_jump_frame": bool(jump_f is not None and pill[jump_f] > on * 0.3),
                    "jump_before_pill_off_frames": (i - jump_f) if jump_f is not None and jump_f < i else 0,
                    "seq": seq})
    summ = {"tag": tag, "pill_offs": len(offs),
            "pill_visible_on_jump_frame": sum(r["pill_visible_on_jump_frame"] for r in out),
            "jump_not_seen_within_k": sum(1 for r in out if r["jump_frame"] is None),
            "jump_frame_minus_pill_off_ms": sorted(round((r["jump_t"] - r["pill_off_t"]) * 1000, 1) for r in out if r["jump_t"] is not None)}
    json.dump({"summary": summ, "jumps": out}, open(os.path.join(vd, f"{tag}-jumpocr.json"), "w"), indent=1)
    print(json.dumps({k2: v for k2, v in summ.items()}))
    return summ


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[2] == "ocr":
        ocr_check(sys.argv[1])
    else:
        main()
