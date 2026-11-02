#!/usr/bin/env python3
"""REOPEN VIDEO judge: reads each cycle's film (reopen-N.mp4) and record (reopen-N.json, ext_reopen.py) and says,
from the film alone, when after the new process's main():
  (1) window   the first frame with the app's window on screen again,
  (2) content  every visible terminal shows its last content (its pane matches the last frame before the end),
  (3) echo     each visible terminal's marker key is on screen (its cursor cell changed after the HID key),
in ms and in display refreshes. It also reports, per pane, whether the content went away again after it showed
(a flash), and the window and pane exactness from the record.

    reopen_judge.py DIR [DIR ...] [--json OUT] [--frames]     DIR holds reopen-N.json and reopen-N.mp4

Needs numpy and an ffmpeg binary (imageio-ffmpeg, or ffmpeg on PATH). Runs on the VM, never on the mini.

Clock: the film's frame times are its own (pts from the first frame). They are put on the wall clock (the clock
of the kernel's process start and of every event in the record) by the four cursor jumps on the menu bar the
record logs (sent and done wall times): each jump is first seen in one frame, which bounds the film's offset;
the offset is the middle of the intersection of those bounds, and its half width is reported as the clock error.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import zlib
from pathlib import Path

import numpy as np

# A pane matches its last content when fewer than this share of its pixels differ by more than DIFF levels.
DIFF = 28
MATCH_SHARE = 0.02
# The window is on screen when this share of its rect differs from the frame before the reopen.
WINDOW_SHARE = 0.05
# A marker echoed when its cell's mean absolute change passes this many levels.
ECHO_LEVEL = 12.0


def ffmpeg_exe():
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        found = shutil.which("ffmpeg")
        if not found:
            sys.exit("reopen_judge: no ffmpeg (pip install imageio-ffmpeg)")
        return found


def decode(movie):
    """Every frame of MOVIE as (pts seconds, gray uint8 HxW)."""
    exe = ffmpeg_exe()
    probe = subprocess.run([exe, "-hide_banner", "-i", str(movie)], capture_output=True, text=True)
    size = re.search(r"Video: .*?(\d{2,5})x(\d{2,5})", probe.stderr)
    if not size:
        raise SystemExit(f"{movie}: no video stream: {probe.stderr[-300:]}")
    w, h = int(size.group(1)), int(size.group(2))
    proc = subprocess.run([exe, "-hide_banner", "-i", str(movie), "-vf", "showinfo", "-vsync", "0", "-f", "rawvideo",
                           "-pix_fmt", "gray", "-"], capture_output=True)
    pts = [float(m.group(1)) for m in re.finditer(rb"pts_time:\s*([0-9.]+)", proc.stderr)]
    data = np.frombuffer(proc.stdout, dtype=np.uint8)
    count = len(data) // (w * h)
    frames = data[:count * w * h].reshape(count, h, w)
    if len(pts) != count:
        pts = pts[:count] if len(pts) > count else pts + [None] * (count - len(pts))
    return [(p, frames[i]) for i, p in enumerate(pts) if p is not None], (w, h)


def box(rect, scale, shape, inset=0):
    """A screen-point rect {x,y,w,h} as film pixel slices, clipped to the frame."""
    h, w = shape
    x0 = int(round((rect["x"] + inset) * scale)); y0 = int(round((rect["y"] + inset) * scale))
    x1 = int(round((rect["x"] + rect["w"] - inset) * scale)); y1 = int(round((rect["y"] + rect["h"] - inset) * scale))
    return slice(max(0, y0), min(h, y1)), slice(max(0, x0), min(w, x1))


def changed_share(a, b, mask=None):
    d = np.abs(a.astype(np.int16) - b.astype(np.int16)) > DIFF
    if mask is not None:
        d = d[mask]
    return float(d.mean()) if d.size else 1.0


def clock_offset(frames, record, scale):
    """The film's offset to the wall clock from the cursor jumps: wall = record_started_wall + pts + offset."""
    start = record.get("record_started_wall")
    sync = record.get("sync") or []
    if not start or not sync or len(frames) < 3:
        return None, None, "no sync moves"
    lows, highs, seen = [], [], []
    for move in sync:
        r = {"x": move["x"] - 10, "y": max(0, move["y"] - 10), "w": 24, "h": 24}
        sl = box(r, scale, frames[0][1].shape)
        hit = None
        for k in range(1, len(frames)):
            t = frames[k][0] + start
            if t < move["sent_wall"] - 2.0:
                continue
            a, b = frames[k - 1][1][sl], frames[k][1][sl]
            if a.size and float(np.abs(a.astype(np.int16) - b.astype(np.int16)).mean()) > 6.0 and t >= move["sent_wall"] - 1.0:
                hit = k
                break
        if hit is None:
            continue
        # The jump happened between the sent and done wall times, and the film first shows it at frame `hit`
        # (so after frame hit-1): offset in [sent - start - pts_hit, done - start - pts_(hit-1)].
        lows.append(move["sent_wall"] - start - frames[hit][0])
        highs.append(move["done_wall"] - start - frames[hit - 1][0])
        seen.append(hit)
    if not lows:
        return None, None, "no cursor jump seen on film (the recorder may hide the pointer)"
    lo, hi = max(lows), min(highs)
    if lo > hi:
        # Inconsistent bounds (a jump drawn late): the widest consistent guess, flagged.
        mid = (lo + hi) / 2
        return mid, abs(lo - hi) / 2, f"sync bounds cross by {round((lo - hi) * 1000, 1)} ms ({len(lows)} jumps)"
    return (lo + hi) / 2, (hi - lo) / 2, f"{len(lows)} of {len(sync)} jumps seen"


def frame_index_at(frames, film_t):
    """The last frame shown at film time FILM_T."""
    k = 0
    for i, (p, _) in enumerate(frames):
        if p <= film_t:
            k = i
        else:
            break
    return k


def write_png(path, gray):
    """A gray PNG, standard library only."""
    h, w = gray.shape
    raw = b"".join(b"\x00" + gray[y].tobytes() for y in range(h))
    def chunk(kind, data):
        return len(data).to_bytes(4, "big") + kind + data + zlib.crc32(kind + data).to_bytes(4, "big")
    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", w.to_bytes(4, "big") + h.to_bytes(4, "big") + b"\x08\x00\x00\x00\x00")
                           + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def judge_cycle(record, movie, frames_out=None):
    frames, (vw, vh) = decode(movie)
    screen = record.get("screen") or {}
    scale = vw / float(screen.get("w") or vw)
    hz = float(screen.get("hz") or 60) or 60.0
    refresh_ms = 1000.0 / hz
    offset, err, sync_note = clock_offset(frames, record, scale)
    start = record.get("record_started_wall")
    to_film = (lambda wall: wall - start - (offset or 0.0)) if start else None
    main_wall = record.get("main_wall") or record.get("process_start_wall")
    out = {"cycle": record.get("cycle"), "how": record.get("how"), "film": {"frames": len(frames), "size": [vw, vh],
           "fps": round((len(frames) - 1) / (frames[-1][0] - frames[0][0]), 1) if len(frames) > 2 else None},
           "clock": {"offset_s": offset, "error_ms": round(err * 1000, 1) if err is not None else None, "note": sync_note},
           "from": "main_start" if record.get("main_wall") else "process start (no main_start mark)",
           "pre_main_ms": round((record["main_wall"] - record["process_start_wall"]) * 1000, 1)
           if record.get("main_wall") and record.get("process_start_wall") else None,
           "open_to_process_ms": round((record["process_start_wall"] - record["open_wall"]) * 1000, 1)
           if record.get("process_start_wall") and record.get("open_wall") else None,
           "differences": record.get("differences") or [], "refresh_ms": round(refresh_ms, 3)}
    if not (to_film and main_wall and frames):
        out["error"] = "no film clock or no main()"
        return out
    ms_of = lambda film_t: round((film_t + start + (offset or 0.0) - main_wall) * 1000, 1)
    shape = frames[0][1].shape
    f_end, f_main = to_film(record["end_wall"]), to_film(main_wall)
    f_open = to_film(record["open_wall"])
    ref = frames[frame_index_at(frames, f_end - 0.05)][1]
    base = frames[frame_index_at(frames, max(f_open - 0.01, to_film(record.get("gone_wall") or record["open_wall"]) + 0.1))][1]
    before = record.get("before") or {}
    windows = before.get("server_windows") or []
    rects = record.get("pane_rects") or {}
    cells = {m["pane"]: m.get("cell") for m in record.get("markers") or [] if m.get("cell")}
    after_launch = [(i, p, f) for i, (p, f) in enumerate(frames) if p >= to_film(record["process_start_wall"]) - 0.001]
    # (1) the window: the first frame where the window's rect differs from the frame before the reopen.
    window_t = None
    if windows:
        wsl = box(windows[0], scale, shape)
        for i, p, f in after_launch:
            if changed_share(f[wsl], base[wsl]) > WINDOW_SHARE:
                window_t = p
                break
    out["window_ms"] = ms_of(window_t) if window_t is not None else None
    # (2) each pane back to its last content (the marker cell and the cursor cell masked).
    key_times = [to_film(m["key_sent_wall"]) for m in record.get("markers") or [] if m.get("key_sent_wall")]
    first_key = min(key_times) if key_times else None
    panes = {}
    for pane, rect in rects.items():
        sl = box(rect, scale, shape, inset=2)
        mask = np.ones((sl[0].stop - sl[0].start, sl[1].stop - sl[1].start), dtype=bool)
        cell = cells.get(pane)
        if cell:
            c = box({"x": cell["x"] - 2, "y": cell["y"] - 2, "w": cell["w"] * 3 + 4, "h": cell["h"] + 4}, scale, shape)
            mask[max(0, c[0].start - sl[0].start):max(0, c[0].stop - sl[0].start),
                 max(0, c[1].start - sl[1].start):max(0, c[1].stop - sl[1].start)] = False
        first, lost_after, worst = None, [], None
        for i, p, f in after_launch:
            share = changed_share(f[sl], ref[sl], mask)
            if first is None:
                worst = share if worst is None else min(worst, share)
                if share < MATCH_SHARE:
                    first = p
            elif share >= MATCH_SHARE and (first_key is None or p < first_key):
                lost_after.append(ms_of(p))
        panes[pane] = {"content_ms": ms_of(first) if first is not None else None,
                       "best_share_before_match": round(worst, 4) if worst is not None else None,
                       "lost_after_shown_ms": lost_after[:6], "lost_after_shown_frames": len(lost_after)}
    # (3) each marker's echo: its cell changes from the last frame before the end, after its key.
    for m in record.get("markers") or []:
        cell, pane = m.get("cell"), m.get("pane")
        if not cell or pane not in panes:
            continue
        c = box(cell, scale, shape)
        k0 = to_film(m["key_sent_wall"])
        echo = None
        for i, p, f in after_launch:
            if p < k0:
                continue
            if float(np.abs(f[c].astype(np.int16) - ref[c].astype(np.int16)).mean()) > ECHO_LEVEL:
                echo = p
                break
        panes[pane].update(key_sent_ms=ms_of(k0), echo_ms=ms_of(echo) if echo is not None else None,
                           key_to_echo_ms=round((echo - k0) * 1000, 1) if echo is not None else None,
                           focused_before=m.get("focused_before"))
    out["panes"] = panes
    contents = [p["content_ms"] for p in panes.values()]
    echoes = [p.get("echo_ms") for p in panes.values()]
    out["all_content_ms"] = None if not contents or None in contents else max(contents)
    out["all_echo_ms"] = None if not echoes or None in echoes else max(echoes)
    out["first_echo_ms"] = min([e for e in echoes if e is not None], default=None)
    for key in ("window_ms", "all_content_ms", "all_echo_ms", "first_echo_ms"):
        out[key.replace("_ms", "_refreshes")] = (round(out[key] / refresh_ms, 1) if out.get(key) is not None else None)
    out["app_marks_ms"] = record.get("app_marks_ms")
    if frames_out:
        frames_out.mkdir(parents=True, exist_ok=True)
        n = record.get("cycle")
        write_png(frames_out / f"c{n}-0-before-end.png", ref)
        write_png(frames_out / f"c{n}-1-before-open.png", base)
        for name, t in (("2-window", window_t), ("3-all-content", None if out["all_content_ms"] is None else
                        out["all_content_ms"] / 1000 - (start + (offset or 0.0) - main_wall)),
                        ("4-all-echo", None if out["all_echo_ms"] is None else out["all_echo_ms"] / 1000 - (start + (offset or 0.0) - main_wall))):
            if t is not None:
                write_png(frames_out / f"c{n}-{name}.png", frames[frame_index_at(frames, t + 1e-6)][1])
    return out


def pct(values, q):
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    k = (len(vals) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(vals) - 1)
    return round(vals[lo] + (vals[hi] - vals[lo]) * (k - lo), 1)


def summary(rows):
    out = {"cycles": len(rows)}
    for key in ("window_ms", "all_content_ms", "first_echo_ms", "all_echo_ms", "pre_main_ms"):
        vals = [r.get(key) for r in rows]
        out[key] = {"p50": pct(vals, 0.5), "p95": pct(vals, 0.95), "max": max([v for v in vals if v is not None], default=None),
                    "missing": sum(1 for v in vals if v is None)}
    out["cycles_with_differences"] = sum(1 for r in rows if r.get("differences"))
    out["flashes"] = sum(p.get("lost_after_shown_frames", 0) for r in rows for p in (r.get("panes") or {}).values())
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dirs", nargs="+", type=Path)
    ap.add_argument("--json", type=Path)
    ap.add_argument("--frames", action="store_true", help="write the key frames as PNG beside each film")
    a = ap.parse_args()
    rows = []
    for d in a.dirs:
        for rec_path in sorted(d.glob("reopen-*.json"), key=lambda p: int(re.search(r"(\d+)", p.stem).group(1))):
            record = json.loads(rec_path.read_text())
            movie = d / (record.get("movie") or "")
            if not record.get("movie") or not movie.is_file():
                rows.append({"cycle": record.get("cycle"), "dir": str(d), "error": "no film"})
                continue
            row = judge_cycle(record, movie, d / "frames" if a.frames else None)
            row["dir"] = str(d)
            rows.append(row)
            print(json.dumps({k: row.get(k) for k in ("dir", "cycle", "window_ms", "all_content_ms", "first_echo_ms",
                                                      "all_echo_ms", "pre_main_ms", "clock", "differences")}))
    result = {"rows": rows, "summary": summary([r for r in rows if "error" not in r])}
    print(json.dumps(result["summary"], indent=1))
    if a.json:
        a.json.write_text(json.dumps(result, indent=1) + "\n")


if __name__ == "__main__":
    main()
