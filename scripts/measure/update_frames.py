"""Judges one Restart to Update of scripts/measure/update-click-ab.sh frames=1 for transition frames (ask-ad4a68e740).

Leo, 2026-11-25: "we dont want the transition frames in between, they're bad and we should just have the end to end
proess be fast so that it just works". What a person may see is three states: the app as it was at the click, nothing
of it (the quit), and the relaunched app as it settles, in the same place. Anything else on screen between the click
and the settle is a transition frame:

  windows   (windows.ndjson, update-frames/watch.swift, every 8 ms, no grant): a window state other than those three,
            such as a window at partial alpha, a window that moves or resizes, a window that shows and leaves, the
            relaunched windows somewhere other than where the old ones were.
  content   (the display recording, when CuaDriver recorded one, decoded to gray by tab-switch-frames/tools.swift):
            the distinct frames inside the relaunched window from its first appearance until its pixels stop changing
            (more than one is a page drawing in steps), and frames of the old window that changed after the click.

Usage: python3 -I update_frames.py crop ROUND_DIR VIDEO_W   the relaunched windows' box in video pixels ("X Y W H")
       python3 -I update_frames.py ROUND_DIR   (timeline.json from update-harness/run.py, windows.ndjson; optionally
       frames.gray + frames.json from `tools decode`, rec.log with `READY epoch_ms=N`). Prints one JSON object.
"""
import json
import re
import struct
import sys
from pathlib import Path

SETTLE_QUIET_MS = 1500  # a window state that lasts this long after the relaunch counts as settled
PIXEL_STEP = 24  # gray levels: a pixel changed (framewatch's threshold)
CHANGED_SHARE = 0.002  # a frame differs when more than this share of its pixels changed


def load_windows(path):
    display, samples = None, []
    for line in path.read_text().splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if "display" in row:
            display = row["display"]
        elif "t" in row:
            samples.append((row["t"], [tuple(w) for w in row["w"]]))
    return display, samples


def shape(windows, role):
    """The visible state of a window list: (role, layer, alpha, x, y, w, h) per window, ignoring window numbers."""
    return tuple(sorted((role(w[0]), w[2], w[3], *w[4:8]) for w in windows))


def judge_windows(samples, click, v1_pid):
    role = lambda pid: "old" if pid == v1_pid else "new"
    before = [w for t, w in samples if t <= click]
    at_click = shape(before[-1] if before else [], role)
    after = [(t - click, w) for t, w in samples if t > click]
    old_gone = next((t for t, w in after if not any(x[0] == v1_pid for x in w)), None)
    new_first = next((t for t, w in after if any(x[0] != v1_pid for x in w)), None)
    # The relaunched app's settled state: the first new-only state that lasts SETTLE_QUIET_MS (or the last one).
    settled, settled_at = None, None
    for i, (t, w) in enumerate(after):
        if not w or any(x[0] == v1_pid for x in w):
            continue
        nxt = after[i + 1][0] if i + 1 < len(after) else None
        if nxt is None or nxt - t >= SETTLE_QUIET_MS:
            settled, settled_at = shape(w, role), t
            break
    allowed = {at_click, (), settled}
    extra, seen = [], set()
    for i, (t, w) in enumerate(after):
        if settled_at is not None and t > settled_at:
            break
        s = shape(w, role)
        if s in allowed:
            continue
        lasted = (after[i + 1][0] if i + 1 < len(after) else t) - t
        extra.append({"at_ms": t, "lasted_ms": lasted, "windows": [list(x) for x in s]})
        seen.add(s)
    partial_alpha = sum(1 for _, w in after for x in w if 0 < x[3] < 1)
    old_frames = sorted(tuple(x[4:8]) for x in (before[-1] if before else []) if x[2] == 0)
    new_frames = sorted(tuple(x[3:7]) for x in settled or () if x[1] == 0)
    return {
        "old_gone_ms": old_gone,
        "new_first_ms": new_first,
        "blank_gap_ms": None if old_gone is None or new_first is None else new_first - old_gone,
        "new_settled_ms": settled_at,
        "transition_states": len(seen),
        "transition_ms": sum(e["lasted_ms"] for e in extra),
        "partial_alpha_samples": partial_alpha,
        "same_frame": old_frames == new_frames if settled is not None else None,
        "old_frames": [list(f) for f in old_frames],
        "new_frames": [list(f) for f in new_frames],
        "extra": extra[:20],
    }


def judge_content(round_dir, click, ready_ms, window_new_first_ms):
    meta_path, gray_path = round_dir / "frames.json", round_dir / "frames.gray"
    if not meta_path.exists() or not gray_path.exists() or ready_ms is None:
        return {"recorded": False}
    meta = json.loads(meta_path.read_text())
    w, h = meta["w"], meta["h"]
    size = w * h
    data = gray_path.read_bytes()
    frames = []
    for off in range(0, len(data) - 8 - size + 1, 8 + size):
        (t,) = struct.unpack_from("<d", data, off)
        frames.append((ready_ms + t * 1000 - click, data[off + 8: off + 8 + size]))
    if not frames:
        return {"recorded": True, "frames": 0}

    def differs(a, b):
        changed = sum(1 for x, y in zip(a, b) if abs(x - y) > PIXEL_STEP)
        return changed > CHANGED_SHARE * size

    start = window_new_first_ms if window_new_first_ms is not None else 0
    tail = [(t, f) for t, f in frames if t >= start]
    if not tail:
        return {"recorded": True, "frames": len(frames), "note": "the recording ended before the relaunch"}
    final = tail[-1][1]
    last_change = next((t for (t, f) in reversed(tail) if differs(f, final)), None)
    distinct, prev = 0, None
    for t, f in tail:
        if last_change is not None and t > last_change:
            break
        if prev is None or differs(f, prev):
            distinct += 1
        prev = f
    before = [(t, f) for t, f in frames if t <= 0]
    clicked = before[-1][1] if before else frames[0][1]
    old_changes = sum(1 for (t, f) in frames if 0 < t < start and differs(f, clicked))
    return {
        "recorded": True,
        "frames": len(frames),
        "fps": meta.get("fps"),
        "content_settled_ms": last_change,
        "content_transition_frames": distinct if last_change is not None else 0,
        "old_window_changed_frames": old_changes,
        "sync": "recorder READY epoch, about +-50 ms",
    }


def main(round_dir):
    timeline = json.loads((round_dir / "timeline.json").read_text())
    click = (timeline.get("timeline") or {}).get("click_unix_ms")
    v1_pid = timeline.get("v1_pid")
    result = {"round": round_dir.name}
    windows_path = round_dir / "windows.ndjson"
    if click is None or v1_pid is None or not windows_path.exists():
        result["error"] = "no click time, v1 pid or window log"
        print(json.dumps(result))
        return
    display, samples = load_windows(windows_path)
    result["display"] = display
    result["windows"] = judge_windows(samples, click, v1_pid)
    ready = None
    rec = round_dir / "rec.log"
    if rec.exists():
        m = re.search(r"READY epoch_ms=(\d+)", rec.read_text())
        ready = int(m.group(1)) if m else None
    result["content"] = judge_content(round_dir, click, ready, result["windows"]["new_first_ms"])
    w, c = result["windows"], result["content"]
    result["transition_frames"] = (w["transition_states"] > 0 or w["partial_alpha_samples"] > 0 or w["same_frame"] is False
                                   or (c.get("content_transition_frames") or 0) > 1)
    print(json.dumps(result))


def crop(round_dir, video_w):
    """The settled relaunched windows' union box (or the old ones' when none settled), scaled to the video's pixels."""
    timeline = json.loads((round_dir / "timeline.json").read_text())
    click = (timeline.get("timeline") or {}).get("click_unix_ms")
    display, samples = load_windows(round_dir / "windows.ndjson")
    w = judge_windows(samples, click, timeline.get("v1_pid"))
    frames = w["new_frames"] or w["old_frames"]
    if not frames or not display:
        return None
    scale = video_w / display[0]
    x0, y0 = min(f[0] for f in frames), min(f[1] for f in frames)
    x1, y1 = max(f[0] + f[2] for f in frames), max(f[1] + f[3] for f in frames)
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(display[0], x1), min(display[1], y1)
    return [round(v * scale) for v in (x0, y0, x1 - x0, y1 - y0)]


if __name__ == "__main__":
    if sys.argv[1] == "crop":
        box = crop(Path(sys.argv[2]), float(sys.argv[3]))
        if box is None:
            sys.exit(1)
        print(*box)
    else:
        main(Path(sys.argv[1]))
