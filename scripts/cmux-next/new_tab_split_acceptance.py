#!/usr/bin/env python3
"""Judge CURRENT native split captures, separately from browser and detector unit tests.

Capture debug.new_tab frame_strip with the split key, debug.motion trace_stop and
debug.key last:true. After three seconds capture another keyless frame_strip at
the SAME scale, plus debug.new_tab field. Pass their JSON and PNG directories here.
No whole-window equality is required during the legitimate split animation.
Exit 0 requires a real split in the requested direction and every target-content
frame after geometry settles to equal the independent, nonblank settled endpoint.
This is capture acceptance, not a replacement for visually checking the composer.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path

from PIL import Image, ImageChops


def require(condition, message):
    if not condition:
        raise ValueError(message)


def close(a, b):
    return len(a) == len(b) and all(abs(x - y) <= 1 for x, y in zip(a, b))


def visible(sample):
    width, height = sample["window"][:2]
    return {p[0]: p[1:5] for p in sample["panes"]
            if p[3] > 0 and p[4] > 0 and p[1] >= 0 and p[2] >= 0
            and p[1] + p[3] <= width + 1 and p[2] + p[4] <= height + 1}


def target_geometry(strip, trace, direction):
    """Infer the added pane and source from actual geometry, never the shortcut name."""
    sent = (strip["sent_host_s"] - trace["t0_s"]) * 1000
    samples = trace["samples"]
    before = [s for s in samples if s["t"] <= sent - trace["refresh_ms"]]
    require(before, "trace has no pre-input geometry")
    old, final = visible(before[-1]), visible(samples[-1])
    added = set(final) - set(old)
    require(len(added) == 1 and len(final) == len(old) + 1, "expected exactly one added visible pane")
    target = added.pop()
    x, y, width, height = final[target]
    sources = [pid for pid, (ox, oy, ow, oh) in old.items()
               if pid in final and ox <= x + 1 and oy <= y + 1
               and ox + ow >= x + width - 1 and oy + oh >= y + height - 1]
    require(len(sources) == 1, "new pane does not split one existing pane")
    source = sources[0]
    sx, sy, sw, sh = final[source]
    if direction == "right":
        valid = close([y, height], [sy, sh]) and 0 <= x - (sx + sw) <= 3
    else:
        valid = close([x, width], [sx, sw]) and 0 <= y - (sy + sh) <= 3
    require(valid, "actual pane geometry is not a split " + direction)
    after = [s for s in samples if s["t"] >= sent]
    bad = [i for i, s in enumerate(after) if not all(
        pid in visible(s) and close(visible(s)[pid], final[pid]) for pid in (source, target))]
    first = (max(bad) + 1) if bad else 0
    require(first < len(after), "target geometry never settles")
    return final[target], after[first]["t"] - sent, samples[-1]["window"][:2], target


def changed_pixels(first, final, tolerance=8):
    require(first.size == final.size, "capture sizes differ")
    difference = ImageChops.difference(first.convert("RGB"), final.convert("RGB"))
    red, green, blue = difference.split()
    return sum(ImageChops.lighter(ImageChops.lighter(red, green), blue).histogram()[tolerance + 1:])


def nonblank(image):
    # A tab heading can survive above an otherwise blank composer. Require content
    # below the top quarter too; the recorded native baseline falsifies a whole-crop check.
    image = image.crop((0, image.height // 4, image.width, image.height)).convert("RGB")
    colors = image.getcolors(image.width * image.height) or []
    return bool(colors) and len(colors) >= 8 and max(
        high - low for low, high in image.convert("RGB").getextrema()) >= 16


def accept(strip, trace, last_action, settled, field, focus, frames_dir, settled_dir, direction):
    action = "splitRight" if direction == "right" else "splitDown"
    require(last_action.get("ran") is True and last_action.get("action") == action,
            "split action was refused, missing or different")
    key = strip.get("key", {})
    require(key.get("action") == action and not key.get("refused_action"), "strip did not execute requested split")
    require(strip.get("capture") == settled.get("capture") == "screencapturekit", "native compositor capture required")
    require(settled["sent_host_s"] - strip["sent_host_s"] >= 3, "endpoint must be captured independently after three seconds")
    require(not settled.get("key"), "endpoint capture must not execute another action")
    require(field.get("focused") is True, "settled focused tab is not New Tab")
    rect, layout_ms, window, target = target_geometry(strip, trace, direction)
    focused = [w for w in focus.get("windows", []) if w.get("model", {}).get("resolved_pane") == target
               and w.get("layout_focused_pane") == target]
    require(len(focused) == 1, "settled New Tab focus is not bound to the added target pane")
    tab = focused[0]["model"].get("resolved_tab")
    selected = [p for p in focused[0].get("topology", []) if p.get("pane") == target and p.get("selected") == tab]
    require(bool(tab) and len(selected) == 1, "settled focused tab does not match target topology")
    endpoint_frames = [f for f in settled["frames"] if f["ms"] >= 0]
    require(len(endpoint_frames) >= 6, "endpoint has fewer than six compositor frames")
    endpoint = Image.open(Path(settled_dir) / endpoint_frames[-1]["file"]).convert("RGB")
    scale_x, scale_y = endpoint.width / window[0], endpoint.height / window[1]
    require(abs(scale_x - scale_y) < 0.005, "endpoint aspect ratio differs from trace window")
    x, y, width, height = rect
    # Inset the divider edge; the compositor's content, model and effort remain included.
    crop = (math.ceil((x + 2) * scale_x), math.ceil((y + 2) * scale_y),
            math.floor((x + width - 2) * scale_x), math.floor((y + height - 2) * scale_y))
    require(crop[2] > crop[0] and crop[3] > crop[1], "target crop is empty")
    final = endpoint.crop(crop)
    require(nonblank(final), "settled target is blank; cannot prove composer readiness")
    for frame in endpoint_frames:
        image = Image.open(Path(settled_dir) / frame["file"]).convert("RGB")
        require(image.size == endpoint.size, "endpoint capture changed dimensions")
        require(changed_pixels(image.crop(crop), final) == 0, "independent endpoint is still changing")
    frames = [f for f in strip["frames"] if f["ms"] >= layout_ms]
    require(len(frames) >= 6, "transition ends before six frames at settled target geometry")
    rows = []
    for frame in frames:
        image = Image.open(Path(frames_dir) / frame["file"]).convert("RGB")
        require(image.size == endpoint.size, "transition and endpoint capture scales differ")
        rows.append({"file": frame["file"], "ms": frame["ms"],
                     "changed_pixels": changed_pixels(image.crop(crop), final)})
    return {"pass": all(row["changed_pixels"] == 0 for row in rows), "target": target, "target_tab": tab,
            "direction": direction, "layout_settled_ms": layout_ms, "crop": crop,
            "endpoint_sha256": hashlib.sha256(endpoint.tobytes()).hexdigest(), "frames": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("strip", "trace", "last-action", "settled-strip", "settled-field", "settled-focus", "frames", "settled-frames",
                 "source-sha", "build-id"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--direction", choices=["right", "down"], required=True)
    args = parser.parse_args()
    def read(path):
        return json.loads(Path(path).read_text())
    try:
        require(len(args.source_sha) == 40 and all(c in "0123456789abcdef" for c in args.source_sha), "full source SHA required")
        result = accept(read(args.strip), read(args.trace), read(args.last_action), read(args.settled_strip),
                        read(args.settled_field), read(args.settled_focus), args.frames, args.settled_frames, args.direction)
    except (ValueError, KeyError, IndexError, OSError, TypeError) as error:
        result = {"pass": False, "error": str(error)}
    result.update(source_sha=args.source_sha, build_id=args.build_id)
    print(json.dumps(result, indent=2))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
