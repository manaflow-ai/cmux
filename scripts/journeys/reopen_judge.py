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


def shifted_share(frame, ref, sl, mask, reach=6):
    """changed_share of the pane against its last frame, the least over shifts of up to REACH film pixels (a pane
    whose layout settles by a few pixels still shows its own content; another text of the same density does not)."""
    best = 1.0
    y, x = sl
    h, w = frame.shape
    for dy in range(-reach, reach + 1):
        for dx in range(-reach, reach + 1):
            ys, xs = slice(y.start + dy, y.stop + dy), slice(x.start + dx, x.stop + dx)
            if ys.start < 0 or xs.start < 0 or ys.stop > h or xs.stop > w:
                continue
            best = min(best, changed_share(frame[ys, xs], ref[sl], mask))
            if best < 0.01:
                return best
    return best


def changed_share(a, b, mask=None):
    d = np.abs(a.astype(np.int16) - b.astype(np.int16)) > DIFF
    if mask is not None:
        d = d[mask]
    return float(d.mean()) if d.size else 1.0


def is_glyph(frame, cell, scale, bg):
    """Whether CELL shows a character (the echoed marker): part of its inner area is ink. An empty cell (or a
    cursor blinked off) has almost none, a block cursor nearly all, a hollow cursor only its border (outside the
    inner area)."""
    inner = box({"x": cell["x"] + 1.5, "y": cell["y"] + 2, "w": cell["w"] - 3, "h": cell["h"] - 4}, scale, frame.shape)
    part = frame[inner]
    if not part.size:
        return False
    ink = float((np.abs(part.astype(np.int16) - bg) > DIFF).mean())
    return 0.06 <= ink <= 0.7


def clock_offset(frames, record, scale, refresh_s=1 / 60.0):
    """The film's offset to the wall clock: wall = record_started_wall + pts + offset. Each sync event bounds it:
    an event between wall times [lo, hi] first seen in frame k (so after frame k-1) gives
    offset in [lo - start - pts_k, hi - start - pts_(k-1)]. Events: the pointer's arrivals at new points (a warp
    is drawn up to one refresh after its call returns) and the reopened app's front-app switch on the menu bar."""
    start = record.get("record_started_wall")
    sync = record.get("sync") or []
    if not start or len(frames) < 3:
        return None, None, "no film clock"
    cursor = []
    visited = set()
    # Kit v1 records (no sync_method) moved the pointer with CuaDriver's slow, animated move_cursor and left it at a
    # sync point between cycles: those arrivals are not clean events.
    for move in (sync if record.get("sync_method") else []):
        # Only an ARRIVAL at a point never visited before in this film is a clean event (a revisited point's
        # region also changes when the pointer leaves it).
        if move["x"] in visited:
            continue
        visited.add(move["x"])
        r = {"x": move["x"] - 10, "y": max(0, move["y"] - 10), "w": 24, "h": 24}
        sl = box(r, scale, frames[0][1].shape)
        for k in range(1, len(frames)):
            t = frames[k][0] + start
            # Menu bar status items change too (seen on cmux20 at x 1560): look only from shortly before the jump
            # (the film's offset to the wall clock is under 0.2 s in every cycle so far).
            if t < move["sent_wall"] - 0.5:
                continue
            a, b = frames[k - 1][1][sl], frames[k][1][sl]
            if a.size and float(np.abs(a.astype(np.int16) - b.astype(np.int16)).mean()) > 6.0:
                cursor.append((move["sent_wall"] - start - frames[k][0],
                               move["done_wall"] + refresh_s - start - frames[k - 1][0]))
                break
    front = None
    if record.get("front_wall") and record.get("process_start_wall"):
        fprev = record.get("front_prev_wall") or record["front_wall"] - 0.05
        fdone = record.get("front_done_wall") or record["front_wall"] + 0.034
        menu = (slice(0, int(24 * scale)), slice(0, int(700 * scale)))
        # The old app's own end also changes the menu bar (to the Finder's), seconds earlier when pre-main is long:
        # look only from shortly before the front poll saw the switch (the film's offset is well under 0.4 s).
        p0 = max(fprev, record["front_wall"] - 0.3) - start - 0.4
        for k in range(1, len(frames)):
            if frames[k][0] < p0:
                continue
            a, b = frames[k - 1][1][menu], frames[k][1][menu]
            if float(np.abs(a.astype(np.int16) - b.astype(np.int16)).mean()) > 1.0:
                # Drawn at or after the switch (up to a refresh after the poll that saw it ended); the frame
                # before still showed the old menu bar.
                front = (fprev - start - frames[k][0], fdone + refresh_s - start - frames[k - 1][0])
                break
    events = cursor + ([front] if front else [])
    if not events:
        return None, None, "no cursor jump or front-app switch seen on film"
    lo, hi = max(e[0] for e in events), min(e[1] for e in events)
    if lo <= hi:
        return (lo + hi) / 2, (hi - lo) / 2, f"{len(cursor)} cursor arrivals + {'the' if front else 'no'} front-app switch"
    return (lo + hi) / 2, abs(lo - hi) / 2, f"SYNC BOUNDS CROSS by {round((lo - hi) * 1000, 1)} ms ({len(events)} events): clock not trusted"


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
    offset, err, sync_note = clock_offset(frames, record, scale, 1.0 / hz)
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
           "differences": record.get("differences") or [], "refresh_ms": round(refresh_ms, 3),
           "pid_matches": record.get("pid_matches"), "settled": record.get("settled"),
           "markers_error": record.get("markers_error"), "clean_errors": record.get("clean_errors")}
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
    windows = sorted(before.get("server_windows") or [], key=lambda w: -(w.get("w") or 0) * (w.get("h") or 0))
    rects = record.get("pane_rects") or {}
    # The marker cells, again from the screen text and the pane's grid (the kit's cursor_cell: wrap aware).
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import ext_reopen
    screens = (before.get("screens") or {})
    for m in record.get("markers") or []:
        if m.get("pane") in rects and m.get("pane") in screens:
            m["cell"] = ext_reopen.cursor_cell(screens[m["pane"]], rects[m["pane"]]) or m.get("cell")
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
    # The film shows a change at most one film frame late: the gap to the frame before each event.
    gaps = [round((b[0] - a[0]) * 1000, 1) for a, b in zip(frames, frames[1:])]
    out["film"]["max_gap_ms"] = max(gaps) if gaps else None
    out["film"]["median_gap_ms"] = sorted(gaps)[len(gaps) // 2] if gaps else None
    # (2) each pane back to its last content (the marker cell and the cursor cell masked).
    key_times = [to_film(m["key_sent_wall"]) for m in record.get("markers") or [] if m.get("key_sent_wall")]
    first_key = min(key_times) if key_times else None
    panes = {}
    masks = {}
    bgs = {}
    for pane, rect in rects.items():
        sl = box(rect, scale, shape, inset=2)
        mask = np.ones((sl[0].stop - sl[0].start, sl[1].stop - sl[1].start), dtype=bool)
        cell = cells.get(pane)
        if cell:
            c = box({"x": cell["x"] - 2, "y": cell["y"] - 2, "w": cell["w"] * 3 + 4, "h": cell["h"] + 4}, scale, shape)
            mask[max(0, c[0].start - sl[0].start):max(0, c[0].stop - sl[0].start),
                 max(0, c[1].start - sl[1].start):max(0, c[1].stop - sl[1].start)] = False
        masks[pane] = (sl, mask)
        ref_pane = ref[sl]
        bg = int(np.bincount(ref_pane.ravel()).argmax())
        bgs[pane] = bg
        ref_ink = float((np.abs(ref_pane.astype(np.int16) - bg) > DIFF)[mask].mean())
        # A pane whose program draws all the time (a TUI animation) has no fixed last frame: it counts as back
        # once its ink is on screen (no blank), not once it matches the last frame before the end.
        lead = [f for p, f in frames if f_end - 0.8 <= p <= f_end - 0.02]
        moving = max([changed_share(b[sl], a[sl], mask) for a, b in zip(lead, lead[1:])], default=0.0)
        animated = moving > 0.02
        visible, exact, lost_after, worst, inks = None, None, [], None, []
        for i, p, f in after_launch:
            part = f[sl]
            share = changed_share(part, ref_pane, mask)
            ink = float((np.abs(part.astype(np.int16) - bg) > DIFF)[mask].mean())
            if visible is None and ref_ink > 0 and ink >= (0.6 if animated else 0.8) * ref_ink and (
                    animated or share < MATCH_SHARE or shifted_share(f, ref, sl, mask) < 0.05):
                visible = p
            if exact is None:
                worst = share if worst is None else min(worst, share)
                if share < MATCH_SHARE:
                    exact = p
            elif not animated and share >= MATCH_SHARE and (first_key is None or p < first_key):
                lost_after.append(ms_of(p))
            if animated and visible is not None and ink < 0.3 * ref_ink and (first_key is None or p < first_key):
                lost_after.append(ms_of(p))
            if len(inks) < 40:
                inks.append([ms_of(p), round(ink / ref_ink, 2) if ref_ink else None, round(share, 3)])
        panes[pane] = {"content_ms": ms_of(visible) if visible is not None else None, "animated": animated,
                       "exact_ms": ms_of(exact) if exact is not None else None,
                       "ref_ink": round(ref_ink, 4), "best_share_before_match": round(worst, 4) if worst is not None else None,
                       "lost_after_shown_ms": lost_after[:6], "lost_after_shown_frames": len(lost_after),
                       "trace": inks}
    # (3) each marker's echo: after its key and once its pane matches its last content (marker cells masked), the
    # first frame whose marker cell differs from the last frame before the end.
    markers = record.get("markers") or []
    for n, m in enumerate(markers):
        cell, pane = m.get("cell"), m.get("pane")
        if not cell or pane not in panes:
            continue
        c = box(cell, scale, shape)
        sl, mask = masks[pane]
        k0 = to_film(m["key_sent_wall"])
        # The search ends when the next marker's click or key goes out (its key could land in this pane).
        later = [x.get("click_sent_wall") or x.get("key_sent_wall") for x in markers[n + 1:]]
        k1 = to_film(min(later)) if later and None not in later else float("inf")
        echo = None
        if is_glyph(ref, cell, scale, bgs[pane]):
            panes[pane]["echo_invalid"] = "the marker cell already held a character before the end"
        else:
            for i, p, f in after_launch:
                # The pane shows its content (a click on it changes its focus look, so not an exact match).
                if p < k0 or p >= k1 or changed_share(f[sl], ref[sl], mask) >= 0.25:
                    continue
                if (is_glyph(f, cell, scale, bgs[pane])
                        and float(np.abs(f[c].astype(np.int16) - ref[c].astype(np.int16)).mean()) > ECHO_LEVEL):
                    echo = p
                    break
        key_s = (m.get("key_done_wall") or m["key_sent_wall"]) - m["key_sent_wall"]
        panes[pane].update(key_sent_ms=ms_of(k0), key_path=m.get("key_path"), received=m.get("received"),
                           key_call_ms=round(key_s * 1000, 1), key_precise=key_s <= 0.05, echo_ms=ms_of(echo) if echo is not None else None,
                           key_to_echo_ms=round((echo - k0) * 1000, 1) if echo is not None else None,
                           focused_before=m.get("focused_before"))
    out["panes"] = panes
    contents = [p["content_ms"] for p in panes.values()]
    exacts = [p["exact_ms"] for p in panes.values()]
    out["all_exact_ms"] = None if not exacts or None in exacts else max(exacts)
    echoes = [p.get("echo_ms") for p in panes.values()]
    out["all_content_ms"] = None if not contents or None in contents else max(contents)
    out["all_echo_ms"] = None if not echoes or None in echoes else max(echoes)
    out["first_echo_ms"] = min([e for e in echoes if e is not None], default=None)
    for key in ("window_ms", "all_content_ms", "all_exact_ms", "all_echo_ms", "first_echo_ms"):
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
    for key in ("window_ms", "all_content_ms", "all_exact_ms", "first_echo_ms", "all_echo_ms", "pre_main_ms"):
        vals = [r.get(key) for r in rows]
        out[key] = {"p50": pct(vals, 0.5), "p95": pct(vals, 0.95), "max": max([v for v in vals if v is not None], default=None),
                    "missing": sum(1 for v in vals if v is None)}
    out["cycles_with_differences"] = sum(1 for r in rows if r.get("differences"))
    out["flashes"] = sum(p.get("lost_after_shown_frames", 0) for r in rows for p in (r.get("panes") or {}).values())
    for key in ("window_ms", "all_content_ms", "all_exact_ms", "first_echo_ms", "all_echo_ms"):
        out[key]["refreshes_p50"] = None if out[key]["p50"] is None else round(out[key]["p50"] / rows[0]["refresh_ms"], 1) if rows else None
    return out


CONTENT_TARGET_MS = 300.0
INTERACTIVE_TARGET_MS = 500.0


def verdict(row):
    """The film's verdict on one cycle (REOPEN VIDEO rules, lead 2026-11-02 01:05Z: every metric per visible pane,
    the reopen number is the max over them): a list of failures, empty when the cycle is clean."""
    fails = []
    if row.get("error"):
        return [row["error"]]
    panes = row.get("panes") or {}
    window = row.get("window_ms")
    if "CROSS" in str((row.get("clock") or {}).get("note")):
        return [f"NOT JUDGED: {(row.get('clock') or {}).get('note')}"]
    if window is None:
        fails.append("no window frame on film after the launch")
    for pane, p in sorted(panes.items()):
        name = pane[-8:]
        if p.get("content_ms") is None:
            fails.append(f"pane {name}: never back to its last content on film")
            continue
        if window is not None and p["content_ms"] > window + 1.0:
            fails.append(f"pane {name}: not in the first window frame ({window} ms): its last content only at {p['content_ms']} ms")
        if p.get("lost_after_shown_frames"):
            fails.append(f"pane {name}: its content went away again after it showed ({p['lost_after_shown_ms'][:3]} ms)")
    worst = row.get("all_content_ms")
    if worst is not None and worst > CONTENT_TARGET_MS:
        fails.append(f"every visible terminal's last content at {worst} ms after main() > {CONTENT_TARGET_MS:.0f} ms")
    # A key whose call returned within 50 ms has a known time (CGEventPost, or CuaDriver's desktop-scope key in a
    # session that does not record); a slower call's key time is unknown, so its echo is not judged.
    for pane, p in sorted(panes.items()):
        if p.get("received") is not None and p["received"] != 1:
            fails.append(f"pane {pane[-8:]}: received {p['received']} marker keys, not 1 (a key went to another pane)")
    # Interactive: a pane's echo on film is an UPPER bound of when it accepted keys (the key went out at or after
    # key_sent). An echo within the target passes; a late or missing echo fails only when the key's time is known
    # (its call returned within 50 ms) and it went out before the target; else that pane's (3) is not judged.
    for pane, p in sorted(panes.items()):
        if p.get("key_sent_ms") is None:
            continue
        e = p.get("echo_ms")
        if e is not None and e <= INTERACTIVE_TARGET_MS:
            continue
        if not (p.get("key_precise") and p["key_sent_ms"] <= INTERACTIVE_TARGET_MS):
            fails.append(f"NOT JUDGED (3) pane {pane[-8:]}: its key went out at {p['key_sent_ms']} ms"
                         + ("" if p.get("key_precise") else " with an unknown time (slow key call)"))
            continue
        if True:
            fails.append(f"pane {pane[-8:]}: " + ("its marker key never echoed (a lost key)" if e is None else
                         f"its marker key (sent {p['key_sent_ms']} ms) echoed at {e} ms > {INTERACTIVE_TARGET_MS:.0f} ms"))
    for key, why in (("pid_matches", "the measured process is not the app that answered after the reopen"),
                     ("settled", "the visible terminals never all went live after the reopen")):
        if row.get(key) is False:
            fails.append(why)
    if row.get("markers_error"):
        fails.append(f"markers: {row['markers_error']}")
    for error in row.get("clean_errors") or []:
        fails.append(f"cleanup after the cycle failed (the next cycle starts from another state): {error}")
    for difference in row.get("differences") or []:
        if difference.startswith("NOT COMPARED"):
            continue  # listed in the row, not a defect
        fails.append(f"not restored exactly: {difference}")
    return fails


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dirs", nargs="+", type=Path)
    ap.add_argument("--json", type=Path)
    ap.add_argument("--frames", action="store_true", help="write the key frames as PNG beside each film")
    ap.add_argument("--verdict", action="store_true", help="PASS/FAIL per cycle (exit 1 when any cycle fails)")
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
                                                      "all_echo_ms", "all_exact_ms", "pre_main_ms", "clock", "differences")}))
    result = {"rows": rows, "summary": summary([r for r in rows if "error" not in r])}
    failed = 0
    if a.verdict:
        for row in rows:
            fails = verdict(row)
            hard = [f for f in fails if not f.startswith("NOT JUDGED (3)")]
            row["verdict"] = "FAIL" if hard else "PASS"
            row["failures"] = fails
            failed += bool(hard)
            print(f"{row['verdict']} {row.get('dir')} cycle {row.get('cycle')}" + "".join(f"\n  - {f}" for f in fails))
    print(json.dumps(result["summary"], indent=1))
    if a.json:
        a.json.write_text(json.dumps(result, indent=1) + "\n")
    if a.verdict and failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
