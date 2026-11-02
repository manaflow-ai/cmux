#!/usr/bin/env python3
"""Per-frame judge of browser-video.py's DevTools rounds (BROWSER VIDEO suite).

  browser-video-judge.py DIR [--stills DIR] [--json OUT]

DIR is the unpacked artifact (rounds.json, <theme>/<case>-rN.mov and .frames.json). Each movie frame has its host
display time (frames.json; ScreenCaptureKit's idle frames are on the same refresh grid but not in the movie). Per
round, reference frames: A = the last frame before the open key, B = the last frame before the close key (DevTools
open and settled), C = the movie's last frame (closed). Page geometry comes from the page's own markers: a magenta
square at the page's (8, 8) after the scroll to y=400, and a cyan fixed badge 6 px from the viewport's bottom-right.

Checks, open and close:
  first     the first frame that differs from the frame before the key, in refreshes after the key send
            (refresh = the median frame interval; target: 1, the next refresh);
  settle    the last frame that still changes, in refreshes after the key;
  flash     a frame whose near-white share (min channel >= 230) in the DevTools area or the page area is 25 points
            above both steady states (dark theme only: in the light theme the page itself is near-white);
  jump      a frame where the page's static column (its 520 CSS px left column, under the magenta marker) differs
            from A: the page moved, scrolled or stretched. Pixels that move before the key (canvas, spinner) are masked;
  badge     the fixed badge's positions: it must go from its A place to its B place in one step (an extra place is an
            intermediate viewport: a stretched or twice-laid-out frame);
  restore   C against A outside the masked pixels: the closed layout must equal the layout before the open.
Writes stills (PNG) of A, B, C, each first frame and each flagged frame. Needs numpy, Pillow and imageio-ffmpeg.
"""
import argparse, json, os, statistics, sys

import numpy as np

try:
    import imageio_ffmpeg
except ImportError:  # pragma: no cover
    sys.exit("needs imageio-ffmpeg (pip install imageio-ffmpeg numpy pillow)")
from PIL import Image

WHITE = 230
DIFF = 40          # summed |RGB| difference that counts a pixel as changed (codec noise stays well under it)
CHANGED = 0.0005   # share of the window's pixels that must change for a frame to count as changed


def load_frames(movie):
    """The movie's frame times (in_movie entries of PATH.frames.json) and the refresh period."""
    with open(movie + ".frames.json") as f:
        raw = json.load(f)
    rows = raw if isinstance(raw, list) else raw.get("frames", [])
    all_t = [r[0] for r in rows]
    shown = [r[0] for r in rows if (len(r) < 3 or r[2]) and (len(r) < 2 or r[1] != "idle")]
    deltas = [b - a for a, b in zip(all_t, all_t[1:]) if b > a]
    period = statistics.median(deltas) if deltas else 1 / 120
    return shown, period, rows


def decode(movie):
    reader = imageio_ffmpeg.read_frames(movie, pix_fmt="rgb24")
    meta = next(reader)
    w, h = meta["size"]
    for buf in reader:
        yield np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 3)


def find(frame, test):
    ys, xs = np.nonzero(test(frame.astype(np.int16)))
    if len(xs) < 20:
        return None
    return int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())


def magenta(f):
    return (f[..., 0] > 200) & (f[..., 1] < 90) & (f[..., 2] > 200)


def cyan(f):
    return (f[..., 0] < 90) & (f[..., 1] > 170) & (f[..., 2] > 200)


def white_share(frame, rect):
    if rect is None:
        return None
    x0, y0, x1, y1 = rect
    crop = frame[y0:y1, x0:x1]
    if crop.size == 0:
        return None
    return float((crop.min(axis=2) >= WHITE).mean())


def changed_mask(a, b):
    return np.abs(a.astype(np.int16) - b.astype(np.int16)).sum(axis=2) > DIFF


def bbox(mask):
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return None
    return [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1]


def save(frame, path, rect=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img = frame if rect is None else frame[rect[1]:rect[3], rect[0]:rect[2]]
    Image.fromarray(img).save(path)


def judge_round(root, entry, stills, window_px):
    movie = os.path.join(root, entry["movie"].replace("run/", "", 1)) if not os.path.exists(os.path.join(root, entry["movie"])) else os.path.join(root, entry["movie"])
    times, period, rows = load_frames(movie)
    t_open, t_close = entry["open"]["t_send"], entry["close"]["t_send"]
    frames = list(decode(movie))
    n = min(len(frames), len(times))
    if len(frames) != len(times):
        print(f"  note: {len(frames)} decoded frames, {len(times)} in frames.json; mapped by order", flush=True)
    frames, times = frames[:n], times[:n]
    H, W = frames[0].shape[:2]
    win = window_px or (W, H)
    cropw = lambda f: f[: min(H, win[1]), : min(W, win[0])]
    frames = [cropw(f) for f in frames]
    H, W = frames[0].shape[:2]
    before = [i for i, t in enumerate(times) if t < t_open]
    during = [i for i, t in enumerate(times) if t_open <= t < t_close]
    after = [i for i, t in enumerate(times) if t >= t_close]
    if not before or not during or not after:
        return {"error": f"frames before/during/after the keys: {len(before)}/{len(during)}/{len(after)}"}
    ia, ib, ic = before[-1], during[-1], len(frames) - 1
    A, B, C = frames[ia], frames[ib], frames[ic]
    # Pixels that move on their own before the key (canvas, spinner, caret): masked from jump and restore.
    anim = np.zeros((H, W), bool)
    for x in before[:-1]:
        anim |= changed_mask(frames[x], frames[before[-1]])
    anim_share = float(anim.mean())
    dpr = float((entry.get("state_before") or {}).get("dpr") or 2)
    mark_a = find(A, magenta)
    badge_a, badge_b = find(A, cyan), find(B, cyan)
    res = {"case": entry["case"], "theme": entry["theme"], "round": entry["round"], "cold": entry.get("cold"),
           "period_ms": round(period * 1000, 3), "frames": n, "anim_share": round(anim_share, 4),
           "state": {k: entry.get(k) for k in ("state_before", "state_open", "state_after")}}
    if mark_a is None or badge_a is None:
        res["error"] = "page markers not found in A (magenta square or cyan badge)"
        save(A, os.path.join(stills, f"{entry['theme']}-{entry['case']}-r{entry['round']}-A-nomarker.png"))
        return res
    page_a = [mark_a[0] - round(8 * dpr), mark_a[1] - round(8 * dpr), badge_a[2] + 1 + round(6 * dpr), badge_a[3] + 1 + round(6 * dpr)]
    page_b = [page_a[0], page_a[1], badge_b[2] + 1 + round(6 * dpr), badge_b[3] + 1 + round(6 * dpr)] if badge_b else None
    res["page_a"], res["page_b"] = page_a, page_b
    # Static column: 520 CSS px wide from the page's left, inside the page in BOTH layouts, less the badge corner.
    col_bottom = min(page_a[3], page_b[3] if page_b else page_a[3]) - round(40 * dpr)
    column = [page_a[0], page_a[1], min(page_a[0] + round(520 * dpr), page_b[2] if page_b else page_a[2]), col_bottom]
    res["column"] = column
    # DevTools area: what changed between A and B outside the shrunk page.
    ab = changed_mask(A, B) & ~anim
    if page_b:
        ab[page_b[1]:page_b[3], page_b[0]:page_b[2]] = False
    dev = bbox(ab)
    res["devtools_area"] = dev
    page_area = page_b or page_a
    dark = entry["theme"] == "dark"
    steady = {"dev_white_B": white_share(B, dev), "dev_white_A": white_share(A, dev),
              "page_white_A": white_share(A, page_a), "page_white_B": white_share(B, page_area)}
    res["steady"] = {k: (round(v, 3) if v is not None else None) for k, v in steady.items()}
    x0, y0, x1, y1 = column
    colmask = ~anim[y0:y1, x0:x1]

    def phase(indices, t_key, ref, end_ref, label):
        out = {"key_t": t_key, "first": None, "settle": None, "flash": [], "jump": [], "badge_places": []}
        prev = ref
        places = []
        for i in indices:
            f = frames[i]
            refreshes = round((times[i] - t_key) / period, 2)
            diff = changed_mask(f, prev) & ~anim
            if diff.mean() > CHANGED:
                if out["first"] is None:
                    out["first"] = {"frame": i, "refreshes": refreshes, "bbox": bbox(diff)}
                    save(f, os.path.join(stills, f"{entry['theme']}-{entry['case']}-r{entry['round']}-{label}-first-f{i}.png"))
                out["settle"] = {"frame": i, "refreshes": refreshes}
            prev = f
            if dark:
                for name, rect, base in (("devtools", dev, max(steady["dev_white_A"] or 0, steady["dev_white_B"] or 0)),
                                         ("page", page_area, max(steady["page_white_A"] or 0, steady["page_white_B"] or 0))):
                    share = white_share(f, rect)
                    if share is not None and share - base > 0.25:
                        out["flash"].append({"frame": i, "refreshes": refreshes, "area": name, "white": round(share, 3)})
                        save(f, os.path.join(stills, f"{entry['theme']}-{entry['case']}-r{entry['round']}-{label}-flash-{name}-f{i}.png"))
            cmp = np.abs(f[y0:y1, x0:x1].astype(np.int16) - A[y0:y1, x0:x1].astype(np.int16)).sum(axis=2) > DIFF
            hit = cmp & colmask
            share = float(hit.mean())
            if hit.sum() >= 64:
                out["jump"].append({"frame": i, "refreshes": refreshes, "column_changed": round(share, 5), "bbox": bbox(hit)})
                if len(out["jump"]) <= 3:
                    save(f, os.path.join(stills, f"{entry['theme']}-{entry['case']}-r{entry['round']}-{label}-jump-f{i}.png"))
            b = find(f, cyan)
            if b and (not places or places[-1][1] != b):
                places.append((i, b))
        out["badge_places"] = [{"frame": i, "rect": list(b)} for i, b in places]
        known = {tuple(badge_a), tuple(badge_b) if badge_b else None}
        out["badge_extra"] = [p for p in out["badge_places"] if not any(k and all(abs(a - c) <= 2 for a, c in zip(p["rect"], k)) for k in known)]
        return out

    res["open"] = phase(during, t_open, A, B, "open")
    res["close"] = phase(after, t_close, B, A, "close")
    restore = changed_mask(C, A) & ~anim
    res["restore"] = {"changed_share": round(float(restore.mean()), 6), "bbox": bbox(restore),
                      "state_equal": (entry.get("state_before") or {}) == (entry.get("state_after") or {})}
    for tag, frame in (("A", A), ("B", B), ("C", C)):
        save(frame, os.path.join(stills, f"{entry['theme']}-{entry['case']}-r{entry['round']}-{tag}.png"))
    if restore.mean() > CHANGED:
        vis = C.copy()
        vis[restore] = [255, 0, 0]
        save(vis, os.path.join(stills, f"{entry['theme']}-{entry['case']}-r{entry['round']}-restore-diff.png"))
    return res


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dir")
    parser.add_argument("--stills")
    parser.add_argument("--json")
    parser.add_argument("--only", help="case name filter")
    opts = parser.parse_args()
    root = opts.dir
    with open(os.path.join(root, "rounds.json")) as f:
        report = json.load(f)
    stills = opts.stills or os.path.join(root, "stills")
    results = []
    for entry in report["rounds"]:
        if opts.only and opts.only not in entry["case"]:
            continue
        print(f"{entry['theme']} {entry['case']} r{entry['round']}", flush=True)
        scale = (entry.get("record") or {}).get("scale") or 2
        win = None
        try:
            res = judge_round(root, entry, stills, win)
        except Exception as error:  # noqa: BLE001  one bad round does not stop the rest
            res = {"case": entry["case"], "round": entry["round"], "theme": entry["theme"], "error": repr(error)}
        results.append(res)
        for ph in ("open", "close"):
            p = res.get(ph) or {}
            print(f"  {ph}: first {p.get('first')} settle {p.get('settle')} flash {len(p.get('flash') or [])} "
                  f"jump {len(p.get('jump') or [])} badge_extra {len(p.get('badge_extra') or [])}", flush=True)
        if res.get("restore") or res.get("error"):
            print(f"  restore {res.get('restore')} error {res.get('error')}", flush=True)
    if opts.json:
        with open(opts.json, "w") as f:
            json.dump(results, f, indent=1)


if __name__ == "__main__":
    main()
