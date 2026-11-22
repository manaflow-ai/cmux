#!/usr/bin/env python3
"""Flag a PR proof clip that runs long or loses the changed element in a large frame.

    proof_clip_check.py CLIP [CLIP ...] [--json] [--strict] [--max-seconds 15] [--min-coverage 0.3]

Leo, 2026-11-22, on a whole-app walkthrough where the changed thinking dots were lost: "these app walkthroughs
and shit, you guys need to just be stripping this shit down bare into the constituent parts of what the fuck
actually matters. speed up the walkthrough". The Mac hot-verify clips then were a 1100x720 whole window, median
21.8 s, about 72% idle frames. A clip is flagged when it runs over --max-seconds (15), or when the changed
element covers less than --min-coverage (0.30) of the frame.

Coverage comes from the clip's sidecar `<clip>.media.json` when it records `element_coverage` (the gallery's
webviews/scripts/gallery/proof-clip.mjs writes it: the element's area over the frame's). Otherwise it is
estimated from the clip itself: frames sampled at up to 2 per second, downscaled to gray, the first one
ignored (a window appearing), and the union bounding box of the pixels that change between consecutive samples
(a difference over a noise threshold, in rows and columns with more than one changed pixel) over the frame's
area. A step that changes over a quarter of the frame (a theme flip, a cut) is left out of the box when any
step is smaller. Each line says which method gave the number.

It warns and never refuses: exit 0 whatever it finds, unless --strict (then 1 when any clip is flagged). A clip
it cannot read is reported as unreadable, not flagged. scripts/pr-media.py prints these flags before an upload;
scripts/media/media_polish.py lean makes a clip that passes (crop to the change, drop idle frames, speed up).
Needs ffmpeg and ffprobe.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable, Sequence

MAX_SECONDS = 15.0
MIN_COVERAGE = 0.30
SIDECAR_SUFFIX = ".media.json"
SAMPLE_WIDTH = 160  # the estimate's frame width in px; a change smaller than one of these pixels is noise
SAMPLE_FPS = 2.0
MAX_SAMPLES = 90
NOISE = 24  # a gray-level difference (of 255) at or under this is encoder noise, not a change
CUT_FRACTION = 0.25  # a step changing more of the frame than this is a cut or theme flip, not the element
MIN_LINE_PIXELS = 2  # a row or column with fewer changed pixels is a speck of noise

Runner = Callable[..., Any]


@dataclass(frozen=True)
class ChangeBox:
    """The union box of change in source pixels, the source size, and how many sampled frames it came from."""
    x: int
    y: int
    w: int
    h: int
    width: int
    height: int
    samples: int

    @property
    def coverage(self) -> float:
        return (self.w * self.h) / float(self.width * self.height) if self.width and self.height else 0.0


@dataclass
class Result:
    clip: str
    ok: bool
    flags: list[str]
    duration_s: float | None
    coverage: float | None
    coverage_method: str | None
    error: str | None = None


def tool_env() -> dict[str, str]:
    return {key: value for key, value in os.environ.items() if not key.startswith("DYLD_")}


def probe(path: Path, run: Runner = subprocess.run) -> tuple[int, int, float | None]:
    """(width, height, duration seconds or None) from ffprobe; ValueError when it finds no picture."""
    done = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                "stream=width,height,duration:format=duration", "-of", "json", str(path)],
               capture_output=True, text=True, env=tool_env())
    try:
        data = json.loads(done.stdout or "{}")
        stream = data["streams"][0]
        width, height = int(stream["width"]), int(stream["height"])
    except (ValueError, KeyError, IndexError, TypeError):
        raise ValueError(f"ffprobe found no picture ({(done.stderr or '').strip()[:160]})") from None
    if width <= 0 or height <= 0:
        raise ValueError("ffprobe found no picture")
    duration = None
    for value in (data.get("format", {}).get("duration"), stream.get("duration")):
        try:
            duration = float(value)
            break
        except (TypeError, ValueError):
            continue
    return width, height, duration


def change_box(path: Path, run: Runner = subprocess.run) -> ChangeBox | None:
    """The union bounding box of what changes in the clip, in its own pixels; None when nothing changes."""
    width, height, duration = probe(path, run)
    sample_w = min(SAMPLE_WIDTH, width)
    sample_h = max(1, round(sample_w * height / width))
    fps = SAMPLE_FPS if not duration else min(SAMPLE_FPS, MAX_SAMPLES / max(duration, 0.1))
    done = run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-i", str(path), "-vf",
                f"fps={fps:.4f},scale={sample_w}:{sample_h}:flags=area,format=gray", "-f", "rawvideo", "-"],
               capture_output=True, env=tool_env())
    if done.returncode != 0:
        detail = done.stderr.decode(errors="replace") if isinstance(done.stderr, bytes) else str(done.stderr)
        raise ValueError(f"ffmpeg could not sample it ({detail.strip()[-160:]})")
    size = sample_w * sample_h
    raw = done.stdout or b""
    frames = [raw[i:i + size] for i in range(0, len(raw) - size + 1, size)][1:]  # the first frame is ignored
    masks = []
    for before, after in zip(frames, frames[1:]):
        mask = [i for i, (a, b) in enumerate(zip(before, after)) if abs(a - b) > NOISE]
        if mask:
            masks.append(mask)
    # A step that changes most of the frame (a theme flip, a scene cut, the window repainting) says nothing about
    # where the changed element is; the box comes from the local steps, or from all of them when none is local.
    local = [mask for mask in masks if len(mask) <= CUT_FRACTION * size]
    rows = [0] * sample_h
    cols = [0] * sample_w
    changed = bytearray(size)
    for mask in local or masks:
        for i in mask:
            if not changed[i]:
                changed[i] = 1
                rows[i // sample_w] += 1
                cols[i % sample_w] += 1
    live_rows = [y for y, count in enumerate(rows) if count >= MIN_LINE_PIXELS]
    live_cols = [x for x, count in enumerate(cols) if count >= MIN_LINE_PIXELS]
    if not live_rows or not live_cols:
        return None
    sx, sy = width / sample_w, height / sample_h
    x0, x1 = int(live_cols[0] * sx), min(width, int(-(-(live_cols[-1] + 1) * sx // 1)))
    y0, y1 = int(live_rows[0] * sy), min(height, int(-(-(live_rows[-1] + 1) * sy // 1)))
    return ChangeBox(x0, y0, x1 - x0, y1 - y0, width, height, len(frames))


def read_sidecar(path: Path) -> dict:
    side = Path(str(path) + SIDECAR_SUFFIX)
    try:
        data = json.loads(side.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def number(value: Any) -> float | None:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def check(path: Path, max_seconds: float = MAX_SECONDS, min_coverage: float = MIN_COVERAGE,
          run: Runner = subprocess.run) -> Result:
    side = read_sidecar(path)
    duration: float | None = None
    try:
        _w, _h, duration = probe(path, run)
    except (ValueError, OSError) as error:
        duration = number(side.get("duration_s"))
        if duration is None:
            return Result(str(path), True, [], None, None, None, error=str(error))
    if duration is None:
        duration = number(side.get("duration_s"))
    coverage = number(side.get("element_coverage"))
    method = "sidecar element_coverage" if coverage is not None else None
    if coverage is None:
        try:
            box = change_box(path, run)
        except (ValueError, OSError) as error:
            box, method = None, f"unreadable: {error}"
        else:
            coverage = round(box.coverage, 3) if box else 0.0
            method = "estimated from frame changes"
    flags = []
    if duration is not None and duration > max_seconds:
        flags.append(f"runs {duration:.1f} s, over {max_seconds:g} s")
    if coverage is not None and coverage < min_coverage:
        what = "nothing changes in it" if coverage == 0 else f"the changed element covers {coverage:.0%} of the frame"
        flags.append(f"{what}, under {min_coverage:.0%}")
    return Result(str(path), not flags, flags, round(duration, 2) if duration is not None else None,
                  coverage, method)


def line(result: Result) -> str:
    name = Path(result.clip).name
    if result.error:
        return f"{name}: unreadable ({result.error})"
    facts = []
    if result.duration_s is not None:
        facts.append(f"{result.duration_s:g} s")
    if result.coverage is not None:
        facts.append(f"coverage {result.coverage:.0%} ({result.coverage_method})")
    elif result.coverage_method:
        facts.append(f"coverage {result.coverage_method}")
    detail = ", ".join(facts)
    if result.ok:
        return f"{name}: ok ({detail})"
    return f"{name}: FLAG: {'; '.join(result.flags)} ({detail}). Lean it: scripts/media/media_polish.py lean"


def main(argv: Sequence[str] | None = None, run: Runner = subprocess.run, out=None) -> int:
    out = out or sys.stdout
    parser = argparse.ArgumentParser(prog="proof_clip_check.py", description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    parser.add_argument("clips", type=Path, nargs="+", metavar="CLIP")
    parser.add_argument("--json", action="store_true", help="one JSON list instead of lines")
    parser.add_argument("--strict", action="store_true", help="exit 1 when any clip is flagged")
    parser.add_argument("--max-seconds", type=float, default=MAX_SECONDS)
    parser.add_argument("--min-coverage", type=float, default=MIN_COVERAGE)
    args = parser.parse_args(argv)
    results = [check(clip, args.max_seconds, args.min_coverage, run) for clip in args.clips]
    if args.json:
        print(json.dumps([asdict(result) for result in results], indent=2), file=out)
    else:
        for result in results:
            print(line(result), file=out)
    return 1 if args.strict and any(not result.ok for result in results) else 0


if __name__ == "__main__":
    sys.exit(main())
