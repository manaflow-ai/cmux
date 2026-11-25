#!/usr/bin/env python3
"""Crop, pair, grid, trim and redact UI screenshots and clips, rigorously, before they go on a PR.

    media_polish.py crop SRC --out OUT (--bounds X,Y,W,H | --bounds-json FILE) --scale DPR [--margin 8]
    media_polish.py pair BEFORE AFTER [VARIANT ...] --out-dir DIR [--label NAME ...] [--fit] [--canvas WxH]
    media_polish.py grid SRC [SRC ...] --out OUT [--label NAME ...] [--metric TEXT ...] [--cols N] [--fit]
    media_polish.py trim CLIP --out OUT.mp4 (--start S --end E | --event-start-frame F --event-end-frame F)
    media_polish.py sbs BEFORE AFTER --out OUT.mp4 [--pad 2] [--max 15] [--label before --label after]
    media_polish.py redact SRC --out OUT --rect X,Y,W,H [--rect ...] --scale DPR [--style box|blur]
    media_polish.py scan FILE [FILE ...]

Leo, 2026-11-22: "the class of measurement errors for ui you guys need to do these things properly. likewise
with screenshots and vids and properly cropping them. you guys need to be more polished and rigorous about
them." What went wrong before: a full-screen shot where one pane mattered, window chrome left in, before and
after framed differently, a retina 2x read as 1x, a clip showing machine or account names, a clip not cut to
the event under test. Each subcommand closes one of those:

- crop takes the element's bounds in CSS px (a DOM getBoundingClientRect, an AX frame) and the device pixel
  ratio as --scale, which is required: retina is stated, never guessed. A fixed --margin (8 CSS px) goes around
  the bounds, and a crop that would leave the source is refused (wrong --scale, wrong --offset, stale bounds).
- pair puts before, after and any variants on one canvas at identical dimensions. Inputs whose dimensions (or
  given per-input --scale) differ are refused unless --fit, which letterboxes them (centered, padded, scaled
  down only when larger than the canvas; never stretched) and records the factor it used.
- grid lays them side by side (or --cols N) with each label, and the metric when given, drawn on the image in a
  built-in bitmap font, so the result is the same on every machine and needs no ffmpeg drawtext or font.
- trim cuts a clip to the event: its frames or times plus about 300 ms lead-in and lead-out, as an MP4 (h264,
  yuv420p, even dimensions, faststart), a GIF no wider than 720 px (palettegen, made with scripts/pr-media.py's
  encoder and size ladder) and a poster PNG.
- sbs takes a BEFORE and an AFTER clip of the same scenario, finds where they first and last differ (frames
  decoded at --analysis-fps, downscaled gray; a frame differs when more than --min-fraction of its pixels move
  by more than --threshold levels), keeps --pad seconds around that span, and writes ONE labeled side-by-side
  clip (before | after, identical size) no longer than --max seconds, plus a GIF and a poster. Leo,
  2026-11-22, on cmux#49596: "that clip goes for 1 minute long and the only relevant and differentiating bit is
  at the last 10 seconds." Clips that never differ are refused: a before/after that shows nothing is suspect.
- redact fills (or blurs) --rect boxes. Cropping is still the better fix: crop so the sidebar with machine or
  account names is outside the frame. scan reads no text and refuses nothing; it prints what each file's
  sidecar says and reminds you to run the privacy check (scripts/ci/pr_media_privacy.py check), which
  scripts/pr-media.py runs anyway before any upload.

Every output gets a sidecar `<output>.media.json` (scripts/ci/pr_media_lint.py reads it) with source,
crop_bounds, scale, dims {w,h}, margin, variable, control, runs, window_frames {start,end}, viewport, split
and labels. What the caller did not pass (--variable, --control, --runs, --viewport WxH, --split,
--window-frames S:E, --scale) is recorded as null, never invented.

Needs ffmpeg and ffprobe, nothing else. --dry-run prints the ffmpeg commands and writes nothing.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Sequence

ROOT = Path(__file__).resolve().parents[2]
PR_MEDIA = ROOT / "scripts/pr-media.py"
PRIVACY_CHECK = "scripts/ci/pr_media_privacy.py"

IMAGE_SUFFIXES = (".png", ".jpg", ".jpeg", ".webp", ".bmp")
VIDEO_SUFFIXES = (".mp4", ".mov", ".m4v", ".webm", ".gif")
IMAGE_OUTPUTS = (".png", ".jpg", ".jpeg")
VIDEO_OUTPUTS = (".mp4",)
SIDECAR_SUFFIX = ".media.json"
SIDECAR_FIELDS = ("source", "crop_bounds", "scale", "dims", "margin", "variable", "control", "runs",
                  "window_frames", "viewport", "split", "labels")
VIDEO_ENCODE = ["-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
DEFAULT_MARGIN = 8.0
DEFAULT_LEAD = 0.3
GIF_MAX_WIDTH = 720
BACKGROUND = "0x111111"

Runner = Callable[..., Any]


class PolishError(Exception):
    """A refusal or a failure; main() prints it and exits 1."""


# ---------------------------------------------------------------------------------------------------------
# Geometry


@dataclass(frozen=True)
class Rect:
    x: float
    y: float
    w: float
    h: float

    def as_dict(self) -> dict[str, float | int]:
        return {"x": tidy(self.x), "y": tidy(self.y), "w": tidy(self.w), "h": tidy(self.h)}


def tidy(value: float) -> float | int:
    """An integral float as an int, so JSON reads 8 rather than 8.0."""
    return int(value) if float(value).is_integer() else round(float(value), 4)


def number(text: str, what: str) -> float:
    try:
        value = float(text)
    except ValueError:
        raise PolishError(f"{what}: {text!r} is not a number") from None
    if not math.isfinite(value):
        raise PolishError(f"{what}: {text!r} is not a finite number")
    return value


def parse_rect(text: str, what: str = "--bounds") -> Rect:
    parts = [part.strip() for part in text.split(",")]
    if len(parts) != 4:
        raise PolishError(f"{what} takes X,Y,W,H (four numbers), got {text!r}")
    x, y, w, h = (number(part, what) for part in parts)
    if w <= 0 or h <= 0:
        raise PolishError(f"{what}: width and height must be positive, got {text!r}")
    return Rect(x, y, w, h)


def parse_pair(text: str, what: str) -> tuple[float, float]:
    parts = [part.strip() for part in text.split(",")]
    if len(parts) != 2:
        raise PolishError(f"{what} takes X,Y, got {text!r}")
    return number(parts[0], what), number(parts[1], what)


def parse_size(text: str, what: str) -> tuple[int, int]:
    match = re.fullmatch(r"\s*(\d+)\s*[xX]\s*(\d+)\s*", text)
    if not match or int(match.group(1)) <= 0 or int(match.group(2)) <= 0:
        raise PolishError(f"{what} takes WxH in whole positive pixels, e.g. 1280x800, got {text!r}")
    return int(match.group(1)), int(match.group(2))


def parse_window_frames(text: str) -> tuple[int, int]:
    match = re.fullmatch(r"\s*(\d+)\s*:\s*(\d+)\s*", text)
    if not match:
        raise PolishError(f"--window-frames takes START:END frame numbers, e.g. 12:48, got {text!r}")
    start, end = int(match.group(1)), int(match.group(2))
    if end < start:
        raise PolishError(f"--window-frames: END {end} is before START {start}")
    return start, end


def positive_scale(value: float | None, what: str = "--scale") -> float | None:
    if value is not None and (not math.isfinite(value) or value <= 0):
        raise PolishError(f"{what} is the device pixel ratio (1, 2, 3 ...), got {value}")
    return value


SCALE_KEYS = ("scale", "devicePixelRatio", "device_pixel_ratio", "dpr", "backingScaleFactor")
NESTED_KEYS = ("bounds", "frame", "rect", "boundingClientRect", "AXFrame")
NS_RECT = re.compile(r"\{\{\s*([-\d.e]+)\s*,\s*([-\d.e]+)\s*\}\s*,\s*\{\s*([-\d.e]+)\s*,\s*([-\d.e]+)\s*\}\}")


def rect_from_json(data: Any, key: str | None = None) -> tuple[Rect, float | None]:
    """The bounds and, when the JSON carries one, the device pixel ratio.

    Reads a DOMRect (`getBoundingClientRect().toJSON()`: x/y or left/top, width/height), {x,y,w,h}, an AX or
    AppKit frame ({origin:{x,y}, size:{width,height}} or the string "{{x, y}, {w, h}}"), a list [x,y,w,h], or
    any of those under bounds/frame/rect. `key` ("a.b.0") picks one out of a larger document first.
    """
    scale = None
    if key:
        for part in key.split("."):
            if isinstance(data, dict) and isinstance(data.get("devicePixelRatio"), (int, float)):
                scale = float(data["devicePixelRatio"])
            try:
                data = data[int(part)] if isinstance(data, list) else data[part]
            except (KeyError, IndexError, ValueError, TypeError):
                raise PolishError(f"--bounds-key {key!r}: no {part!r} in the bounds JSON") from None
    return _rect_from(data, scale)


def _rect_from(data: Any, scale: float | None) -> tuple[Rect, float | None]:
    if isinstance(data, str):
        match = NS_RECT.fullmatch(data.strip())
        if match:
            x, y, w, h = (float(group) for group in match.groups())
            return checked_rect(Rect(x, y, w, h)), scale
        raise PolishError(f"bounds JSON: the string {data!r} is not a frame like \"{{{{x, y}}, {{w, h}}}}\"")
    if isinstance(data, list) and len(data) == 4 and all(isinstance(item, (int, float)) for item in data):
        return checked_rect(Rect(*(float(item) for item in data))), scale
    if not isinstance(data, dict):
        raise PolishError("bounds JSON: expected an object with x, y, width and height")
    for name in SCALE_KEYS:
        if isinstance(data.get(name), (int, float)) and not isinstance(data.get(name), bool):
            scale = float(data[name])
            break
    for name in NESTED_KEYS:
        if name in data:
            return _rect_from(data[name], scale)
    if isinstance(data.get("origin"), dict) and isinstance(data.get("size"), dict):
        origin, size = data["origin"], data["size"]
        return checked_rect(Rect(float(origin.get("x", 0)), float(origin.get("y", 0)),
                                 float(size.get("width", size.get("w", 0))),
                                 float(size.get("height", size.get("h", 0))))), scale
    x = data.get("x", data.get("left"))
    y = data.get("y", data.get("top"))
    w = data.get("width", data.get("w"))
    h = data.get("height", data.get("h"))
    if not all(isinstance(value, (int, float)) and not isinstance(value, bool) for value in (x, y, w, h)):
        raise PolishError("bounds JSON: expected numeric x (or left), y (or top), width and height")
    return checked_rect(Rect(float(x), float(y), float(w), float(h))), scale


def checked_rect(rect: Rect) -> Rect:
    if not all(math.isfinite(value) for value in (rect.x, rect.y, rect.w, rect.h)) or rect.w <= 0 or rect.h <= 0:
        raise PolishError(f"bounds {rect.as_dict()} have no area")
    return rect


def device_rect(bounds: Rect, scale: float, source: tuple[int, int], *, margin: float = 0.0,
                offset: tuple[float, float] = (0.0, 0.0), even: bool = False, what: str = "crop") -> Rect:
    """`bounds` (CSS px, plus `offset` and `margin` on every side) in the source's device pixels.

    The near edges round down and the far edges up, so the element is never shaved. A box that would leave
    the source is refused, naming each edge and by how much: the usual causes are a wrong --scale, bounds
    from another viewport, or a window offset (title bar) left out. `even` (for h264) grows an odd side by
    one pixel where there is room and otherwise shrinks it.
    """
    width, height = source
    left = math.floor(round((bounds.x + offset[0] - margin) * scale, 6))
    top = math.floor(round((bounds.y + offset[1] - margin) * scale, 6))
    right = math.ceil(round((bounds.x + offset[0] + bounds.w + margin) * scale, 6))
    bottom = math.ceil(round((bounds.y + offset[1] + bounds.h + margin) * scale, 6))
    over = []
    if left < 0:
        over.append(f"left by {-left} px")
    if top < 0:
        over.append(f"top by {-top} px")
    if right > width:
        over.append(f"right by {right - width} px")
    if bottom > height:
        over.append(f"bottom by {bottom - height} px")
    if over:
        raise PolishError(
            f"the {what} {left},{top} to {right},{bottom} (device px, --scale {tidy(scale)}, margin {tidy(margin)} "
            f"CSS px) leaves the {width}x{height} source past the {', '.join(over)}. Check --scale (the capture's "
            f"device pixel ratio), --offset (window chrome above the viewport) and that the bounds come from this "
            f"capture; a smaller --margin only helps when the element really touches the edge.")
    if even:
        if (right - left) % 2:
            if right < width:
                right += 1
            elif left > 0:
                left -= 1
            else:
                right -= 1
        if (bottom - top) % 2:
            if bottom < height:
                bottom += 1
            elif top > 0:
                top -= 1
            else:
                bottom -= 1
    if right - left <= 0 or bottom - top <= 0:
        raise PolishError(f"the {what} is empty after rounding to whole pixels")
    return Rect(left, top, right - left, bottom - top)


@dataclass(frozen=True)
class Placement:
    """One input on the shared canvas: scaled to w x h (factor), then padded to the canvas at x, y."""
    w: int
    h: int
    x: int
    y: int
    factor: float


def even_up(value: int) -> int:
    return value + (value % 2)


def plan_canvas(sizes: Sequence[tuple[int, int]], *, fit: bool, canvas: tuple[int, int] | None = None,
                scales: Sequence[float] | None = None, even: bool = False) -> tuple[tuple[int, int], list[Placement]]:
    """The canvas every input is shown on, and where each one goes.

    Without `fit`, every input must already be the canvas's size at one scale, or it is refused with each
    input's size: a before and after that differ are a framing error to fix at capture, not to hide. With
    `fit`, inputs at different --scale are first resampled to the largest one, then each sits centered on the
    canvas (default: the largest input), scaled down only when larger, never up and never stretched.
    """
    if not sizes:
        raise PolishError("no inputs")
    scales = list(scales or [])
    if scales and len(scales) != len(sizes):
        raise PolishError(f"--scale was given {len(scales)} times for {len(sizes)} inputs; "
                          "give one value, or one per input")
    if len(set(scales)) > 1 and not fit:
        raise PolishError(
            f"the inputs were captured at different device pixel ratios ({', '.join(str(tidy(s)) for s in scales)}); "
            "recapture them at one scale, or pass --fit to resample them to the largest")
    target = max(scales) if scales else 1.0
    resampled = [(w * target / s, h * target / s) if scales else (float(w), float(h))
                 for (w, h), s in zip(sizes, scales or [1.0] * len(sizes))]
    if canvas is None:
        canvas = (max(math.ceil(w) for w, _ in resampled), max(math.ceil(h) for _, h in resampled))
    if even:
        canvas = (even_up(canvas[0]), even_up(canvas[1]))
    if not fit:
        wrong = [f"{index + 1}: {w}x{h}" for index, (w, h) in enumerate(sizes)
                 if (w, h) != canvas and not (even and (even_up(w), even_up(h)) == canvas)]
        if wrong:
            raise PolishError(
                f"the inputs are not all {canvas[0]}x{canvas[1]} ({'; '.join(wrong)}). Recapture them with the same "
                "crop (same bounds, margin and scale), or pass --fit to letterbox them on one canvas.")
    placements = []
    for (rw, rh), (w, h) in zip(resampled, sizes):
        shrink = min(1.0, canvas[0] / rw, canvas[1] / rh)
        sw = max(1, math.floor(rw * shrink + 1e-6))
        sh = max(1, math.floor(rh * shrink + 1e-6))
        if even:
            sw, sh = max(2, sw - sw % 2), max(2, sh - sh % 2)
        placements.append(Placement(sw, sh, (canvas[0] - sw) // 2, (canvas[1] - sh) // 2,
                                    round(sw / w, 4)))
    return canvas, placements


def place_filter(index: int, size: tuple[int, int], placement: Placement, canvas: tuple[int, int],
                 background: str, label: str) -> str:
    """ffmpeg filters putting input `index` on the canvas as [label]: scale only when the size changes."""
    steps = []
    if (placement.w, placement.h) != size:
        steps.append(f"scale={placement.w}:{placement.h}:flags=lanczos")
    if (placement.w, placement.h) != canvas:
        steps.append(f"pad={canvas[0]}:{canvas[1]}:{placement.x}:{placement.y}:color={background}")
    steps.append("setsar=1")
    return f"[{index}:v]{','.join(steps)}[{label}]"


# ---------------------------------------------------------------------------------------------------------
# Labels: a 5x7 bitmap font, so a grid's labels look the same on every machine and need no drawtext or font.

FONT_ROWS = 7
FONT_COLS = 5
FONT = {
    ' ': "00000000000000", '0': "0E11131519110E", '1': "040C040404040E", '2': "0E11010204081F", '3': "1F02040201110E",
    '4': "02060A121F0202", '5': "1F101E0101110E", '6': "0608101E11110E", '7': "1F010204080808", '8': "0E11110E11110E",
    '9': "0E11110F01020C", 'A': "0E1111111F1111", 'B': "1E11111E11111E", 'C': "0E11101010110E", 'D': "1C12111111121C",
    'E': "1F10101E10101F", 'F': "1F10101E101010", 'G': "0E11101711110F", 'H': "1111111F111111", 'I': "0E04040404040E",
    'J': "0702020202120C", 'K': "11121418141211", 'L': "1010101010101F", 'M': "111B1515111111", 'N': "11111915131111",
    'O': "0E11111111110E", 'P': "1E11111E101010", 'Q': "0E11111115120D", 'R': "1E11111E141211", 'S': "0F10100E01011E",
    'T': "1F040404040404", 'U': "1111111111110E", 'V': "11111111110A04", 'W': "1111111515150A", 'X': "11110A040A1111",
    'Y': "1111110A040404", 'Z': "1F01020408101F", 'a': "00000E010F110F", 'b': "1010161911111E", 'c': "00000E1010110E",
    'd': "01010D1311110F", 'e': "00000E111F100E", 'f': "0609081C080808", 'g': "000F11110F010E", 'h': "10101619111111",
    'i': "04000C0404040E", 'j': "0200060202120C", 'k': "10101214181412", 'l': "0C04040404040E", 'm': "00001A15151111",
    'n': "00001619111111", 'o': "00000E1111110E", 'p': "00001E111E1010", 'q': "00000D130F0101", 'r': "00001619101010",
    's': "00000E100E011E", 't': "08081C08080906", 'u': "0000111111130D", 'v': "00001111110A04", 'w': "0000111115150A",
    'x': "0000110A040A11", 'y': "000011110F010E", 'z': "00001F0204081F", '.': "00000000000C0C", ',': "00000000000C04",
    ':': "000C0C000C0C00", ';': "000C0C000C0408", '-': "0000001F000000", '_': "0000000000001F", '+': "0004041F040400",
    '=': "00001F001F0000", '/': "00010204081000", '(': "02040808080402", ')': "08040202020408", '%': "18190204081303",
    '#': "0A0A1F0A1F0A0A", '!': "04040404000004", '?': "0E110102040004", '<': "02040810080402", '>': "08040201020408",
    '*': "0004150E150400", '@': "0E11010D15150E", "'": "0C040800000000", '"': "0A0A0A00000000", '[': "0E08080808080E",
    ']': "0E02020202020E", '|': "04040404040404", '&': "0C12140815120D", '~': "00000815020000", '$': "040F140E051E04",
}


def glyph(char: str) -> list[int]:
    code = FONT.get(char, FONT["?"])
    return [int(code[index:index + 2], 16) for index in range(0, FONT_ROWS * 2, 2)]


def hex_color(text: str) -> tuple[int, int, int]:
    value = text.strip().lower().removeprefix("0x").removeprefix("#")
    if not re.fullmatch(r"[0-9a-f]{6}", value):
        raise PolishError(f"colors are RRGGBB hex (e.g. 111111), got {text!r}")
    return int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16)


def fit_text(text: str, max_chars: int) -> str:
    if len(text) <= max_chars:
        return text
    return text[:max(0, max_chars - 2)] + ".." if max_chars >= 2 else text[:max_chars]


def label_scale(width: int, texts: Sequence[str]) -> int:
    """Font pixel size for a band `width` wide: about 1/320 of the width (2 to 4), smaller if text needs it."""
    target = max(2, min(4, width // 320))
    longest = max([len(text) for text in texts] + [1])
    while target > 1 and (6 * target * longest + 6 * target) > width:
        target -= 1
    return target


def band_height(lines: int, scale: int) -> int:
    pad = 3 * scale
    return even_up(lines * FONT_ROWS * scale + max(0, lines - 1) * 3 * scale + 2 * pad)


def render_band(lines: Sequence[tuple[str, tuple[int, int, int]]], width: int, height: int, scale: int,
                background: tuple[int, int, int]) -> bytes:
    """A width x height binary PPM (P6): each (text, color) line left-aligned in the bitmap font."""
    pad = 3 * scale
    pixels = bytearray(bytes(background) * (width * height))
    max_chars = max(0, (width - 2 * pad + scale) // (6 * scale))
    for line_index, (text, color) in enumerate(lines):
        top = pad + line_index * (FONT_ROWS + 3) * scale
        for char_index, char in enumerate(fit_text(text, max_chars)):
            left = pad + char_index * 6 * scale
            for row, bits in enumerate(glyph(char)):
                for col in range(FONT_COLS):
                    if not bits & (1 << (FONT_COLS - 1 - col)):
                        continue
                    for dy in range(scale):
                        y = top + row * scale + dy
                        if y >= height:
                            continue
                        for dx in range(scale):
                            x = left + col * scale + dx
                            if x < width:
                                offset = (y * width + x) * 3
                                pixels[offset:offset + 3] = bytes(color)
    return f"P6\n{width} {height}\n255\n".encode() + bytes(pixels)


# ---------------------------------------------------------------------------------------------------------
# Media


@dataclass(frozen=True)
class Media:
    path: Path
    kind: str  # "image" or "video"
    w: int
    h: int
    fps: float | None = None
    duration: float | None = None


_PR_MEDIA: Any = None


def pr_media() -> Any:
    """scripts/pr-media.py, loaded once: its gif encoder and size ladder, and the trimmed env ffmpeg runs in."""
    global _PR_MEDIA
    if _PR_MEDIA is None:
        spec = importlib.util.spec_from_file_location("pr_media_tool", PR_MEDIA)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        _PR_MEDIA = module
    return _PR_MEDIA


def tool_env() -> dict[str, str]:
    return pr_media().tool_env()


def kind_of(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in IMAGE_SUFFIXES:
        return "image"
    if suffix in VIDEO_SUFFIXES:
        return "video"
    raise PolishError(f"{path.name}: not a screenshot ({', '.join(IMAGE_SUFFIXES)}) "
                      f"or clip ({', '.join(VIDEO_SUFFIXES)})")


def frame_rate(text: str | None) -> float | None:
    numerator, _, denominator = str(text or "").partition("/")
    try:
        rate = float(numerator) / float(denominator or 1)
    except (ValueError, ZeroDivisionError):
        return None
    return rate if 0 < rate <= 240 else None


def probe(path: Path, run: Runner) -> Media:
    if not path.is_file():
        raise PolishError(f"{path}: no such file")
    kind = kind_of(path)
    if shutil.which("ffprobe") is None and run is subprocess.run:
        raise PolishError("ffprobe (part of ffmpeg) is needed to read media dimensions")
    done = run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=width,height,r_frame_rate,avg_frame_rate:format=duration",
                "-of", "json", str(path)], capture_output=True, text=True, env=tool_env())
    try:
        data = json.loads(done.stdout or "{}")
        stream = data["streams"][0]
        width, height = int(stream["width"]), int(stream["height"])
        if width <= 0 or height <= 0:
            raise ValueError("no picture")
    except (ValueError, KeyError, IndexError, TypeError):
        detail = (done.stderr or "").strip()[:200]
        raise PolishError(f"{path.name}: ffprobe found no picture in it ({detail})") from None
    duration = None
    try:
        duration = float(data.get("format", {}).get("duration"))
    except (TypeError, ValueError):
        pass
    fps = None
    if kind == "video":
        fps = frame_rate(stream.get("r_frame_rate")) or frame_rate(stream.get("avg_frame_rate"))
    return Media(path, kind, width, height, fps, duration if kind == "video" else None)


def output_kind(out: Path, kind: str) -> None:
    allowed = IMAGE_OUTPUTS if kind == "image" else VIDEO_OUTPUTS
    if out.suffix.lower() not in allowed:
        hint = " (trim makes the gif)" if kind == "video" else ""
        raise PolishError(f"--out {out.name}: a {kind} source writes {', '.join(allowed)}{hint}")


def encode_args(kind: str, out: Path) -> list[str]:
    return (["-frames:v", "1", "-update", "1"] if kind == "image" else list(VIDEO_ENCODE)) + [str(out)]


def ffmpeg(args: Sequence[str]) -> list[str]:
    return ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", *args]


class Context:
    """How commands run: `dry_run` prints each ffmpeg command instead, and writes no file."""

    def __init__(self, run: Runner, dry_run: bool, out=sys.stdout):
        self.run, self.dry_run, self.out = run, dry_run, out

    def ffmpeg(self, argv: list[str], cwd: Path | None = None) -> None:
        if self.dry_run:
            print("would run: " + " ".join(shell_quote(part) for part in argv), file=self.out)
            return
        if shutil.which(argv[0]) is None and self.run is subprocess.run:
            raise PolishError(f"{argv[0]} is needed; install ffmpeg")
        done = self.run(argv, capture_output=True, text=True, env=tool_env(), cwd=cwd)
        if done.returncode != 0:
            raise PolishError(f"{argv[0]} failed: {(done.stderr or done.stdout or '').strip()[-600:]}")

    def write_json(self, path: Path, data: dict[str, Any]) -> None:
        if self.dry_run:
            print(f"would write {path}", file=self.out)
            return
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {path}", file=self.out)


def shell_quote(part: str) -> str:
    return part if re.fullmatch(r"[\w@%+=:,./-]+", part) else "'" + part.replace("'", "'\\''") + "'"


def private_path(path: Path) -> str:
    """The path as given, with the home folder (an account name) written as ~."""
    text = str(path)
    home = os.path.expanduser("~")
    if home and home != "~" and (text == home or text.startswith(home + os.sep)):
        return "~" + text[len(home):]
    return text


def sidecar_path(out: Path) -> Path:
    return Path(str(out) + SIDECAR_SUFFIX)


def sidecar(args: argparse.Namespace, *, command: str, source: Any, dims: tuple[int, int],
            crop_bounds: dict[str, Any] | None = None, scale: Any = None, margin: float | None = None,
            labels: list[str] | None = None, extra: dict[str, Any] | None = None) -> dict[str, Any]:
    """The `<output>.media.json` record. Every SIDECAR_FIELDS key is present; what was not given is null."""
    frames = args.window_frames
    viewport = args.viewport
    record: dict[str, Any] = {
        "source": source,
        "crop_bounds": crop_bounds,
        "scale": scale,
        "dims": {"w": dims[0], "h": dims[1]},
        "margin": tidy(margin) if margin is not None else None,
        "variable": args.variable,
        "control": args.control,
        "runs": args.runs,
        "window_frames": {"start": frames[0], "end": frames[1]} if frames else None,
        "viewport": {"w": viewport[0], "h": viewport[1]} if viewport else None,
        "split": args.split,
        "labels": labels,
        "tool": "scripts/media/media_polish.py",
        "command": command,
    }
    if extra:
        record.update(extra)
    return record


def prepare_out(out: Path, sources: Sequence[Path], ctx: Context) -> None:
    resolved = out.resolve()
    if any(resolved == source.resolve() for source in sources):
        raise PolishError(f"--out {out} is one of the inputs; write somewhere else")
    if not ctx.dry_run:
        out.parent.mkdir(parents=True, exist_ok=True)


def sanitize(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-.")
    return cleaned or "input"


# ---------------------------------------------------------------------------------------------------------
# Commands


def cmd_crop(args: argparse.Namespace, ctx: Context) -> int:
    source = probe(args.source, ctx.run)
    output_kind(args.out, source.kind)
    json_scale = None
    if args.bounds_json:
        try:
            data = json.loads(Path(args.bounds_json).read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise PolishError(f"--bounds-json {args.bounds_json}: {error}") from None
        bounds, json_scale = rect_from_json(data, args.bounds_key)
    else:
        bounds = parse_rect(args.bounds)
    scale = positive_scale(args.scale)
    json_scale = positive_scale(json_scale, "the bounds JSON's devicePixelRatio")
    if scale is not None and json_scale is not None and abs(scale - json_scale) > 1e-6:
        raise PolishError(f"--scale {tidy(scale)} disagrees with the bounds JSON's device pixel ratio "
                          f"{tidy(json_scale)}")
    scale = scale if scale is not None else json_scale
    if scale is None:
        raise PolishError("--scale (the capture's device pixel ratio: 2 on a retina Mac, 1 otherwise) is required; "
                          "it is never guessed")
    if args.margin < 0:
        raise PolishError("--margin cannot be negative")
    offset = parse_pair(args.offset, "--offset") if args.offset else (0.0, 0.0)
    box = device_rect(bounds, scale, (source.w, source.h), margin=args.margin, offset=offset,
                      even=source.kind == "video")
    prepare_out(args.out, [args.source], ctx)
    ctx.ffmpeg(ffmpeg(["-i", str(args.source),
                       "-vf", f"crop={int(box.w)}:{int(box.h)}:{int(box.x)}:{int(box.y)},setsar=1",
                       *encode_args(source.kind, args.out)]))
    crop_bounds = {**box.as_dict(), "unit": "device_px",
                   "css": bounds.as_dict(), "offset_css": {"x": tidy(offset[0]), "y": tidy(offset[1])}}
    ctx.write_json(sidecar_path(args.out), sidecar(
        args, command="crop", source=private_path(args.source), dims=(int(box.w), int(box.h)),
        crop_bounds=crop_bounds, scale=tidy(scale), margin=args.margin,
        labels=[args.label] if args.label else None,
        extra={"source_dims": {"w": source.w, "h": source.h}}))
    return 0


def default_labels(paths: Sequence[Path], given: Sequence[str] | None) -> list[str]:
    given = list(given or [])
    if given and len(given) != len(paths):
        raise PolishError(f"--label was given {len(given)} times for {len(paths)} inputs; give one per input")
    if given:
        labels = given
    elif len(paths) >= 2:
        labels = ["before", "after", *(path.stem for path in paths[2:])]
    else:
        labels = [path.stem for path in paths]
    seen: dict[str, int] = {}
    unique = []
    for label in labels:
        seen[label] = seen.get(label, 0) + 1
        unique.append(label if seen[label] == 1 else f"{label}-{seen[label]}")
    return unique


def load_inputs(paths: Sequence[Path], ctx: Context) -> list[Media]:
    inputs = [probe(path, ctx.run) for path in paths]
    kinds = {media.kind for media in inputs}
    if len(kinds) > 1:
        raise PolishError("mix of screenshots and clips; pair or grid stills with stills and clips with clips")
    return inputs


def input_scales(args: argparse.Namespace, count: int) -> list[float]:
    scales = [positive_scale(value) for value in (args.scale or [])]
    if len(scales) == 1:
        return scales * count
    return scales


def recorded_scale(scales: Sequence[float]) -> Any:
    if not scales:
        return None
    return tidy(scales[0]) if len(set(scales)) == 1 else [tidy(value) for value in scales]


def cmd_pair(args: argparse.Namespace, ctx: Context) -> int:
    paths = list(args.sources)
    if len(paths) < 2:
        raise PolishError("pair takes at least two inputs: before and after (then any variants)")
    inputs = load_inputs(paths, ctx)
    labels = default_labels(paths, args.label)
    scales = input_scales(args, len(inputs))
    kind = inputs[0].kind
    canvas, placements = plan_canvas([(m.w, m.h) for m in inputs], fit=args.fit, canvas=args.canvas,
                                     scales=scales, even=kind == "video")
    suffix = ".png" if kind == "image" else ".mp4"
    background = "0x" + "".join(f"{c:02x}" for c in hex_color(args.background))
    if not ctx.dry_run:
        args.out_dir.mkdir(parents=True, exist_ok=True)
    for index, (media, label, placement) in enumerate(zip(inputs, labels, placements)):
        out = args.out_dir / f"{sanitize(label)}{suffix}"
        prepare_out(out, paths, ctx)
        chain = place_filter(0, (media.w, media.h), placement, canvas, background, "v")
        ctx.ffmpeg(ffmpeg(["-i", str(media.path), "-filter_complex", chain, "-map", "[v]",
                           *encode_args(kind, out)]))
        ctx.write_json(sidecar_path(out), sidecar(
            args, command="pair", source=private_path(media.path), dims=canvas,
            scale=tidy(scales[index]) if scales else None, labels=[label],
            extra={"fit": bool(args.fit), "fit_factor": placement.factor,
                   "placed": {"x": placement.x, "y": placement.y, "w": placement.w, "h": placement.h},
                   "source_dims": {"w": media.w, "h": media.h},
                   "pair": [private_path(path) for path in paths]}))
    return 0


def grid_layout(count: int, cols: int, cell: tuple[int, int], gap: int) -> tuple[str, tuple[int, int]]:
    """xstack's layout string and the grid's size (cells and gaps, without the outer border)."""
    cols = max(1, min(cols, count))
    rows = math.ceil(count / cols)
    positions = [f"{(i % cols) * (cell[0] + gap)}_{(i // cols) * (cell[1] + gap)}" for i in range(count)]
    return "|".join(positions), (cols * cell[0] + (cols - 1) * gap, rows * cell[1] + (rows - 1) * gap)


def cmd_grid(args: argparse.Namespace, ctx: Context) -> int:
    paths = list(args.sources)
    inputs = load_inputs(paths, ctx)
    kind = inputs[0].kind
    output_kind(args.out, kind)
    labels = default_labels(paths, args.label)
    metrics = list(args.metric or [])
    if metrics and len(metrics) != len(paths):
        raise PolishError(f"--metric was given {len(metrics)} times for {len(paths)} inputs; give one per input")
    scales = input_scales(args, len(inputs))
    canvas, placements = plan_canvas([(m.w, m.h) for m in inputs], fit=args.fit, canvas=args.canvas,
                                     scales=scales, even=kind == "video")
    if args.gap < 0:
        raise PolishError("--gap cannot be negative")
    gap = even_up(args.gap)
    background_rgb = hex_color(args.background)
    background = "0x" + "".join(f"{c:02x}" for c in background_rgb)
    font = label_scale(canvas[0], labels + metrics)
    lines = 2 if metrics else 1
    band = band_height(lines, font)
    cell = (canvas[0], canvas[1] + band)
    layout, size = grid_layout(len(inputs), args.cols or len(inputs), cell, gap)
    prepare_out(args.out, paths, ctx)
    with tempfile.TemporaryDirectory(prefix="media-polish-") as work_dir:
        work = Path(work_dir)
        band_inputs = []
        for index, label in enumerate(labels):
            text = [(label, (255, 255, 255))]
            if metrics:
                text.append((metrics[index], (190, 190, 190)))
            band_file = work / f"label-{index}.ppm"
            band_file.write_bytes(render_band(text, canvas[0], band, font, background_rgb))
            band_inputs += (["-loop", "1"] if kind == "video" else []) + ["-i", str(band_file)]
        count = len(inputs)
        parts = [place_filter(i, (m.w, m.h), placements[i], canvas, background, f"f{i}") for i, m in enumerate(inputs)]
        parts += [f"[{count + i}:v]format=rgb24,setsar=1[l{i}]" for i in range(count)]
        parts += [f"[l{i}][f{i}]vstack=inputs=2:shortest=1[c{i}]" for i in range(count)]
        if count == 1:
            stacked = "[c0]"
        else:
            parts.append("".join(f"[c{i}]" for i in range(count))
                         + f"xstack=inputs={count}:layout={layout}:fill={background}:shortest=1[g]")
            stacked = "[g]"
        parts.append(f"{stacked}pad=iw+{2 * gap}:ih+{2 * gap}:{gap}:{gap}:color={background},"
                     f"format={'rgb24' if kind == 'image' else 'yuv420p'}[out]")
        argv = ffmpeg([*sum((["-i", str(m.path)] for m in inputs), []), *band_inputs,
                       "-filter_complex", ";".join(parts), "-map", "[out]", *encode_args(kind, args.out)])
        ctx.ffmpeg(argv)
    dims = (size[0] + 2 * gap, size[1] + 2 * gap)
    ctx.write_json(sidecar_path(args.out), sidecar(
        args, command="grid", source=[private_path(path) for path in paths], dims=dims,
        scale=recorded_scale(scales), labels=labels,
        extra={"metrics": metrics or None, "cell": {"w": canvas[0], "h": canvas[1]}, "fit": bool(args.fit),
               "fit_factors": [p.factor for p in placements], "cols": max(1, min(args.cols or count, count))}))
    return 0


@dataclass(frozen=True)
class TrimWindow:
    event_start: float
    event_end: float
    start: float
    end: float


def trim_window(media: Media, args: argparse.Namespace) -> TrimWindow:
    """The event's times (from frames: frame N spans N/fps to (N+1)/fps) and the cut with lead-in and -out."""
    by_frames = args.event_start_frame is not None or args.event_end_frame is not None
    by_time = args.start is not None or args.end is not None
    if by_frames == by_time:
        raise PolishError("give the event as --event-start-frame and --event-end-frame, or as --start and --end")
    if by_frames:
        if args.event_start_frame is None or args.event_end_frame is None:
            raise PolishError("give both --event-start-frame and --event-end-frame")
        fps = args.fps or media.fps
        if not fps:
            raise PolishError(f"{media.path.name}: its frame rate is unknown; pass --fps or use --start/--end seconds")
        event_start, event_end = args.event_start_frame / fps, (args.event_end_frame + 1) / fps
    else:
        if args.start is None or args.end is None:
            raise PolishError("give both --start and --end (seconds)")
        event_start, event_end = args.start, args.end
    if event_start < 0 or event_end <= event_start:
        raise PolishError(f"the event {event_start:.3f}s to {event_end:.3f}s is empty or negative")
    if args.lead_in < 0 or args.lead_out < 0:
        raise PolishError("--lead-in and --lead-out cannot be negative")
    if media.duration is not None and event_start >= media.duration:
        raise PolishError(f"the event starts at {event_start:.3f}s, after the {media.duration:.3f}s clip ends")
    start = max(0.0, event_start - args.lead_in)
    end = event_end + args.lead_out
    if media.duration is not None:
        end = min(end, media.duration)
    return TrimWindow(round(event_start, 4), round(event_end, 4), round(start, 4), round(end, 4))


def cmd_trim(args: argparse.Namespace, ctx: Context) -> int:
    media = probe(args.source, ctx.run)
    if media.kind != "video":
        raise PolishError(f"{args.source.name} is a still; trim cuts clips")
    output_kind(args.out, "video")
    window = trim_window(media, args)
    prepare_out(args.out, [args.source], ctx)
    gif = args.out.with_suffix(".gif")
    poster = args.out.with_suffix(".poster.png")
    even = "crop=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1"
    ctx.ffmpeg(ffmpeg(["-ss", f"{window.start:.3f}", "-i", str(args.source), "-t", f"{window.end - window.start:.3f}",
                       "-vf", even, *VIDEO_ENCODE, str(args.out)]))
    fps = args.fps or media.fps or 30.0
    at = window.event_start if args.poster_at == "start" else max(window.event_start, window.event_end - 1 / fps)
    ctx.ffmpeg(ffmpeg(["-ss", f"{at:.3f}", "-i", str(args.source), "-vf", even,
                       "-frames:v", "1", "-update", "1", str(poster)]))
    make_gif(args.out, gif, min(args.gif_width, GIF_MAX_WIDTH), ctx)
    dims = (media.w - media.w % 2, media.h - media.h % 2)
    gif_dims = dims if args.dry_run else probe_dims(gif, ctx, dims)
    frames = args.window_frames
    if frames is None and args.event_start_frame is not None:
        frames = (args.event_start_frame, args.event_end_frame)
    trim = {"event_start_s": window.event_start, "event_end_s": window.event_end, "start_s": window.start,
            "end_s": window.end, "lead_in_s": args.lead_in, "lead_out_s": args.lead_out,
            "poster_at_s": round(at, 4), "fps": media.fps}
    outputs = {"mp4": private_path(args.out), "gif": private_path(gif), "poster": private_path(poster)}
    for out, out_dims in ((args.out, dims), (gif, gif_dims), (poster, dims)):
        record_args = argparse.Namespace(**{**vars(args), "window_frames": frames})
        ctx.write_json(sidecar_path(out), sidecar(
            record_args, command="trim", source=private_path(args.source), dims=out_dims,
            scale=tidy(args.scale) if args.scale else None, labels=[args.label] if args.label else None,
            extra={"trim": trim, "outputs": outputs}))
    return 0


def probe_dims(path: Path, ctx: Context, fallback: tuple[int, int]) -> tuple[int, int]:
    try:
        media = probe(path, ctx.run)
        return media.w, media.h
    except PolishError:
        return fallback


def make_gif(mp4: Path, gif: Path, width: int, ctx: Context) -> None:
    """pr-media.py's gif: palettegen from the clip, stepping narrower then slower until under its inline limit."""
    module = pr_media()
    rate = None if ctx.dry_run else module.source_fps(mp4, ctx.run, tool_env())
    for fps, attempt_width in module.gif_attempts(module.gif_widths(width), None, rate):
        argv = module.gif_argv(mp4, gif, fps, attempt_width)
        ctx.ffmpeg(argv)
        if ctx.dry_run or (gif.is_file() and gif.stat().st_size <= module.INLINE_MAX_BYTES):
            return


# ---------------------------------------------------------------------------------------------------------
# Side by side, trimmed to where before and after differ

DEFAULT_PAD = 2.0
DEFAULT_SBS_MAX = 15.0
DEFAULT_ANALYSIS_FPS = 10.0
DEFAULT_ANALYSIS_WIDTH = 160
DEFAULT_THRESHOLD = 24
DEFAULT_MIN_FRACTION = 0.02
DEFAULT_CUT_FRACTION = 0.9


def analysis_size(media: Media, width: int) -> tuple[int, int]:
    width = max(8, min(width, media.w))
    return width, max(2, even_up(round(width * media.h / media.w)))


def gray_frames(media: Media, size: tuple[int, int], fps: float, ctx: Context) -> list[bytes]:
    """The clip decoded at `fps` to `size` 8-bit gray frames (ffmpeg rawvideo on stdout)."""
    if shutil.which("ffmpeg") is None and ctx.run is subprocess.run:
        raise PolishError("ffmpeg is needed; install ffmpeg")
    argv = ffmpeg(["-i", str(media.path), "-vf", f"fps={fps:g},scale={size[0]}:{size[1]}:flags=area,format=gray",
                   "-f", "rawvideo", "-pix_fmt", "gray", "-"])
    done = ctx.run(argv, capture_output=True, env=tool_env())
    if done.returncode != 0:
        detail = done.stderr.decode("utf-8", "replace") if isinstance(done.stderr, bytes) else str(done.stderr)
        raise PolishError(f"ffmpeg could not decode {media.path.name}: {detail.strip()[-300:]}")
    data = done.stdout if isinstance(done.stdout, bytes) else bytes(done.stdout or b"")
    step = size[0] * size[1]
    return [data[i:i + step] for i in range(0, len(data) - step + 1, step)]


def changed_fraction(a: bytes, b: bytes, threshold: int) -> float:
    if not a:
        return 0.0
    return sum(1 for x, y in zip(a, b) if abs(x - y) > threshold) / len(a)


def cut_frames(frames: Sequence[bytes], threshold: int, cut_fraction: float) -> set[int]:
    """Frames at a whole-picture change (first paint, a cut) and the two frames either side of it."""
    cuts = {i for i in range(1, len(frames)) if changed_fraction(frames[i - 1], frames[i], threshold) >= cut_fraction}
    return {j for i in cuts for j in range(i - 2, i + 3)}


def divergence(before: Sequence[bytes], after: Sequence[bytes], *, threshold: int, min_fraction: float,
               cut_fraction: float = 1.01) -> tuple[int, int, list[float]] | None:
    """(first, last) frame index where the two clips differ, and every frame's changed fraction; None if never.

    Where both clips make the same whole-picture change (>= cut_fraction of the pixels since the frame before:
    the first paint, a page load) within two frames of each other, those frames are not compared: the arms
    painting a frame apart is not the difference under test. A whole-picture change in one clip only counts."""
    fractions = [changed_fraction(a, b, threshold) for a, b in zip(before, after)]
    skip = cut_frames(before, threshold, cut_fraction) & cut_frames(after, threshold, cut_fraction)
    differing = [i for i, value in enumerate(fractions) if value >= min_fraction and i not in skip]
    if not differing:
        return None
    return differing[0], differing[-1], fractions


@dataclass(frozen=True)
class SbsWindow:
    start: float
    end: float
    diverge_start: float
    diverge_end: float
    pad: float
    capped: str | None


def sbs_window(diverge_start: float, diverge_end: float, duration: float, *, pad: float,
               limit: float) -> SbsWindow:
    """The cut: --pad around the differing span, shrinking the pad (then cutting the span's tail) to fit `limit`."""
    if pad < 0:
        raise PolishError("--pad cannot be negative")
    if limit <= 0:
        raise PolishError("--max must be positive")
    span = diverge_end - diverge_start
    capped = None
    used_pad = pad
    if span + 2 * pad > limit:
        used_pad = max(0.0, (limit - span) / 2)
        capped = f"pad shrunk from {pad:g}s to {used_pad:.2f}s to stay within {limit:g}s"
    start = max(0.0, diverge_start - used_pad)
    end = min(duration, diverge_end + used_pad)
    if end - start > limit:
        lead = min(pad, 1.0, diverge_start)
        start = max(0.0, diverge_start - lead)
        end = min(duration, start + limit)
        capped = (f"the clips differ for {span:.2f}s, longer than {limit:g}s: cut to {lead:.2f}s before the first "
                  f"difference and the {limit:g}s after it")
    return SbsWindow(round(start, 3), round(end, 3), round(diverge_start, 3), round(diverge_end, 3),
                     round(used_pad, 3), capped)


def cmd_sbs(args: argparse.Namespace, ctx: Context) -> int:
    paths = [args.before, args.after]
    before, after = (probe(path, ctx.run) for path in paths)
    for media in (before, after):
        if media.kind != "video" or media.path.suffix.lower() == ".gif":
            raise PolishError(f"{media.path.name}: sbs takes two clips (mp4, mov, webm)")
    output_kind(args.out, "video")
    scales = input_scales(args, 2)
    canvas, placements = plan_canvas([(before.w, before.h), (after.w, after.h)], fit=args.fit,
                                     scales=scales, even=True)
    if args.analysis_fps <= 0 or args.threshold < 0 or not 0 < args.min_fraction <= 1:
        raise PolishError("--analysis-fps must be positive, --threshold >= 0, --min-fraction in (0, 1]")
    duration = min(before.duration or 0.0, after.duration or 0.0)
    if duration <= 0:
        raise PolishError("ffprobe gave no duration for one of the clips")
    size = analysis_size(before, args.analysis_width)
    found = divergence(gray_frames(before, size, args.analysis_fps, ctx),
                       gray_frames(after, size, args.analysis_fps, ctx),
                       threshold=args.threshold, min_fraction=args.min_fraction, cut_fraction=args.cut_fraction)
    if found is None:
        raise PolishError(
            f"{before.path.name} and {after.path.name} never differ (no frame with >= {args.min_fraction:g} of "
            f"pixels changed by > {args.threshold} levels at {args.analysis_fps:g} fps). A before/after that "
            f"shows nothing measured nothing: check the arms really differ, or lower --threshold/--min-fraction")
    first, last, fractions = found
    step = 1 / args.analysis_fps
    window = sbs_window(first * step, min(duration, (last + 1) * step), duration, pad=args.pad, limit=args.max)
    labels = default_labels(paths, args.label)
    metrics = list(args.metric or [])
    if metrics and len(metrics) != 2:
        raise PolishError(f"--metric was given {len(metrics)} times; give one per clip (before, then after)")
    prepare_out(args.out, paths, ctx)
    gap = even_up(max(0, args.gap))
    background_rgb = hex_color(args.background)
    background = "0x" + "".join(f"{c:02x}" for c in background_rgb)
    font = label_scale(canvas[0], labels + metrics)
    band = band_height(2 if metrics else 1, font)
    length = window.end - window.start
    with tempfile.TemporaryDirectory(prefix="media-polish-") as work_dir:
        work = Path(work_dir)
        band_inputs: list[str] = []
        for index, label in enumerate(labels):
            text = [(label, (255, 255, 255))] + ([(metrics[index], (190, 190, 190))] if metrics else [])
            band_file = work / f"label-{index}.ppm"
            band_file.write_bytes(render_band(text, canvas[0], band, font, background_rgb))
            band_inputs += ["-loop", "1", "-i", str(band_file)]
        parts = [place_filter(i, (m.w, m.h), placements[i], canvas, background, f"f{i}")
                 for i, m in enumerate((before, after))]
        parts += [f"[{2 + i}:v]format=rgb24,setsar=1[l{i}]" for i in range(2)]
        parts += [f"[l{i}][f{i}]vstack=inputs=2:shortest=1[c{i}]" for i in range(2)]
        parts.append(f"[c0][c1]xstack=inputs=2:layout=0_0|{canvas[0] + gap}_0:fill={background}:shortest=1,"
                     f"pad=iw+{2 * gap}:ih+{2 * gap}:{gap}:{gap}:color={background},format=yuv420p[out]")
        inputs = sum((["-ss", f"{window.start:.3f}", "-t", f"{length:.3f}", "-i", str(m.path)]
                      for m in (before, after)), [])
        ctx.ffmpeg(ffmpeg([*inputs, *band_inputs, "-filter_complex", ";".join(parts), "-map", "[out]",
                           "-t", f"{length:.3f}", *VIDEO_ENCODE, str(args.out)]))
    gif = args.out.with_suffix(".gif")
    poster = args.out.with_suffix(".poster.png")
    poster_at = max(0.0, min(length, window.diverge_end - window.start) - 0.1)
    ctx.ffmpeg(ffmpeg(["-ss", f"{poster_at:.3f}", "-i", str(args.out), "-frames:v", "1", "-update", "1",
                       str(poster)]))
    make_gif(args.out, gif, GIF_MAX_WIDTH, ctx)
    dims = (2 * canvas[0] + 3 * gap, canvas[1] + band + 2 * gap)
    gif_dims = dims if args.dry_run else probe_dims(gif, ctx, dims)
    trim = {"start": window.start, "end": window.end, "diverge_start": window.diverge_start,
            "diverge_end": window.diverge_end, "source_duration": round(duration, 3), "pad": window.pad,
            "pad_requested": args.pad, "max": args.max, "capped": window.capped,
            "threshold": args.threshold, "min_fraction": args.min_fraction,
            "cut_fraction": args.cut_fraction, "analysis_fps": args.analysis_fps,
            "peak_changed_fraction": round(max(fractions), 4), "poster_at": round(window.start + poster_at, 3)}
    outputs = {"mp4": private_path(args.out), "gif": private_path(gif), "poster": private_path(poster)}
    for out, out_dims in ((args.out, dims), (gif, gif_dims), (poster, dims)):
        ctx.write_json(sidecar_path(out), sidecar(
            args, command="sbs", source=[private_path(path) for path in paths], dims=out_dims,
            scale=recorded_scale(scales), labels=labels,
            extra={"trim": trim, "outputs": outputs, "metrics": metrics or None, "fit": bool(args.fit),
                   "cell": {"w": canvas[0], "h": canvas[1]}}))
    note = f" ({window.capped})" if window.capped else ""
    print(f"sbs: the clips differ from {window.diverge_start:.2f}s to {window.diverge_end:.2f}s of "
          f"{duration:.2f}s; kept {window.start:.2f}s to {window.end:.2f}s ({length:.2f}s){note}", file=ctx.out)
    return 0


def cmd_redact(args: argparse.Namespace, ctx: Context) -> int:
    media = probe(args.source, ctx.run)
    output_kind(args.out, media.kind)
    scale = positive_scale(args.scale)
    if scale is None:
        raise PolishError("--scale (the capture's device pixel ratio) is required: --rect is in CSS px")
    boxes = [device_rect(parse_rect(text, "--rect"), scale, (media.w, media.h), what="redaction box")
             for text in args.rect]
    color = "0x" + "".join(f"{c:02x}" for c in hex_color(args.color))
    if args.style == "box":
        chain = ",".join(f"drawbox=x={int(b.x)}:y={int(b.y)}:w={int(b.w)}:h={int(b.h)}:color={color}:t=fill"
                         for b in boxes) + ",setsar=1"
        filters = ["-vf", chain]
    else:
        parts, last = [], "0:v"
        for index, b in enumerate(boxes):
            sigma = max(8, int(min(b.w, b.h) // 4))
            parts.append(f"[{last}]split=2[base{index}][cut{index}]")
            parts.append(f"[cut{index}]crop={int(b.w)}:{int(b.h)}:{int(b.x)}:{int(b.y)},"
                         f"gblur=sigma={sigma}[blur{index}]")
            parts.append(f"[base{index}][blur{index}]overlay={int(b.x)}:{int(b.y)}[r{index}]")
            last = f"r{index}"
        filters = ["-filter_complex", ";".join(parts), "-map", f"[{last}]"]
    prepare_out(args.out, [args.source], ctx)
    ctx.ffmpeg(ffmpeg(["-i", str(args.source), *filters, *encode_args(media.kind, args.out)]))
    ctx.write_json(sidecar_path(args.out), sidecar(
        args, command="redact", source=private_path(args.source), dims=(media.w, media.h), scale=tidy(scale),
        labels=[args.label] if args.label else None,
        extra={"redactions": [{**b.as_dict(), "unit": "device_px"} for b in boxes], "redact_style": args.style}))
    return 0


def cmd_scan(args: argparse.Namespace, ctx: Context) -> int:
    """Prints what is known about each file and reminders. Reads no text in the pictures; refuses nothing."""
    for path in args.files:
        print(f"{private_path(path)}:", file=ctx.out)
        try:
            media = probe(path, ctx.run)
            print(f"  {media.kind} {media.w}x{media.h}", file=ctx.out)
        except PolishError as error:
            print(f"  could not read it: {error}", file=ctx.out)
        record_path = sidecar_path(path)
        record = None
        if record_path.is_file():
            try:
                record = json.loads(record_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                print(f"  {record_path.name} is not valid JSON", file=ctx.out)
        if record is None:
            print("  no .media.json sidecar: make it with media_polish.py crop (or pair, grid, trim) so the "
                  "framing is recorded", file=ctx.out)
            continue
        missing = [field for field in SIDECAR_FIELDS if record.get(field) is None]
        if record.get("crop_bounds") is None and record.get("command") in (None, "redact"):
            print("  hint: no crop recorded; crop to the pane under test so sidebars with machine or account "
                  "names stay outside the frame", file=ctx.out)
        if record.get("scale") is None:
            print("  hint: no --scale recorded; state the device pixel ratio so retina is explicit", file=ctx.out)
        if missing:
            print(f"  not recorded: {', '.join(missing)}", file=ctx.out)
    print("\nThis scan reads no text and does not decide privacy. Before uploading, run the privacy check:\n"
          f"  python3 {PRIVACY_CHECK} check --path-prefix <PR number> FILE...\n"
          "(scripts/pr-media.py runs it on every upload anyway). Prefer a tighter crop over a redaction: a "
          "sidebar with machine or account names outside the crop cannot leak.", file=ctx.out)
    return 0


# ---------------------------------------------------------------------------------------------------------
# CLI


def arg(convert: Callable[[str], Any]) -> Callable[[str], Any]:
    """An argparse type that turns PolishError into argparse's own usage error."""
    def parse(text: str) -> Any:
        try:
            return convert(text)
        except PolishError as error:
            raise argparse.ArgumentTypeError(str(error)) from None
    parse.__name__ = getattr(convert, "__name__", "value")
    return parse


def record_options() -> argparse.ArgumentParser:
    parent = argparse.ArgumentParser(add_help=False)
    group = parent.add_argument_group("recorded in the .media.json sidecar (null when not given)")
    group.add_argument("--variable", help="what differs between the captures, e.g. 'fold look'")
    group.add_argument("--control", help="what was held fixed, e.g. 'same chat, same window size'")
    group.add_argument("--runs", type=int, help="how many runs the metric is from")
    group.add_argument("--viewport", type=arg(lambda t: parse_size(t, "--viewport")), metavar="WxH",
                       help="the viewport in CSS px")
    group.add_argument("--split", help="the pane split, e.g. 'chat|terminal 50/50'")
    group.add_argument("--window-frames", type=arg(parse_window_frames), metavar="S:E",
                       help="the measured frame window")
    parent.add_argument("--dry-run", action="store_true", help="print the ffmpeg commands; write nothing")
    return parent


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="media_polish.py", description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog="Each subcommand has --help.")
    commands = parser.add_subparsers(dest="command", required=True)
    common = record_options()

    crop = commands.add_parser("crop", parents=[common], help="crop a still or clip to an element's bounds",
                               description="Crop a still or clip to CSS-px bounds at an explicit device pixel "
                                           "ratio, with a fixed margin. Refuses a crop that leaves the source.")
    crop.add_argument("source", type=Path)
    crop.add_argument("--out", type=Path, required=True)
    where = crop.add_mutually_exclusive_group(required=True)
    where.add_argument("--bounds", metavar="X,Y,W,H", help="CSS px, e.g. from getBoundingClientRect()")
    where.add_argument("--bounds-json", metavar="FILE",
                       help="a DOMRect, {x,y,w,h}, AX frame or list, maybe with devicePixelRatio")
    crop.add_argument("--bounds-key", metavar="PATH", help="dotted path to the rect inside --bounds-json")
    crop.add_argument("--scale", type=float, help="device pixel ratio of the capture (2 on retina); required "
                                                  "unless the bounds JSON carries devicePixelRatio")
    crop.add_argument("--margin", type=float, default=DEFAULT_MARGIN, help="CSS px around the bounds (default 8)")
    crop.add_argument("--offset", metavar="X,Y", help="CSS px added to the bounds: the viewport's origin in the "
                                                      "capture (window chrome), or minus the window's screen origin")
    crop.add_argument("--label", help="a name for this capture, recorded in labels")

    for name, help_text in (("pair", "before, after and variants at identical dimensions"),
                            ("grid", "one labeled side-by-side or grid image or clip")):
        sub = commands.add_parser(name, parents=[common], help=help_text, description=help_text + ". Inputs of "
                                  "different sizes or scales are refused unless --fit, which letterboxes them on "
                                  "one canvas (centered, never stretched, scaled down only when larger).")
        sub.add_argument("sources", type=Path, nargs="+", metavar="SRC")
        if name == "pair":
            sub.add_argument("--out-dir", type=Path, required=True, help="writes LABEL.png (or .mp4) per input")
        else:
            sub.add_argument("--out", type=Path, required=True)
            sub.add_argument("--metric", action="append", help="text under each label, once per input")
            sub.add_argument("--cols", type=int, help="columns (default: all in one row)")
            sub.add_argument("--gap", type=int, default=8, help="px between and around cells (default 8)")
        sub.add_argument("--label", action="append", help="once per input (default: before, after, file names)")
        sub.add_argument("--fit", action="store_true", help="letterbox mismatched inputs instead of refusing")
        sub.add_argument("--canvas", type=arg(lambda t: parse_size(t, "--canvas")), metavar="WxH",
                         help="canvas size in px (default: the largest input)")
        sub.add_argument("--scale", type=float, action="append",
                         help="device pixel ratio: once for all inputs, or once per input")
        sub.add_argument("--background", default=BACKGROUND[2:], help="RRGGBB letterbox color (default 111111)")

    trim = commands.add_parser("trim", parents=[common], help="cut a clip to the event: mp4, gif and poster",
                               description="Cut a clip to the event plus lead-in and lead-out. Writes OUT.mp4 "
                                           "(h264, yuv420p, even dimensions, faststart), OUT.gif (<=720 px wide) "
                                           "and OUT.poster.png, each with a sidecar.")
    trim.add_argument("source", type=Path)
    trim.add_argument("--out", type=Path, required=True, help="the .mp4; the gif and poster go beside it")
    trim.add_argument("--event-start-frame", type=int)
    trim.add_argument("--event-end-frame", type=int, help="the event's last frame (inclusive)")
    trim.add_argument("--start", type=float, help="event start, seconds")
    trim.add_argument("--end", type=float, help="event end, seconds")
    trim.add_argument("--fps", type=float, help="frame rate for the frame numbers (default: the clip's)")
    trim.add_argument("--lead-in", type=float, default=DEFAULT_LEAD, help="seconds before the event (default 0.3)")
    trim.add_argument("--lead-out", type=float, default=DEFAULT_LEAD, help="seconds after the event (default 0.3)")
    trim.add_argument("--poster-at", choices=("start", "end"), default="end",
                      help="poster frame: the event's first or last frame (default end: the result)")
    trim.add_argument("--gif-width", type=int, default=GIF_MAX_WIDTH, help="gif width cap (at most 720)")
    trim.add_argument("--scale", type=float, help="the clip's device pixel ratio, recorded")
    trim.add_argument("--label", help="a name for this clip, recorded in labels")

    sbs = commands.add_parser("sbs", parents=[common], help="before | after, one clip cut to where they differ",
                              description="Find where BEFORE and AFTER first and last differ, keep --pad seconds "
                                          "around it (at most --max), and write one labeled side-by-side OUT.mp4, "
                                          "OUT.gif and OUT.poster.png, each with a sidecar recording the cut. "
                                          "Refuses clips that never differ.")
    sbs.add_argument("before", type=Path)
    sbs.add_argument("after", type=Path)
    sbs.add_argument("--out", type=Path, required=True, help="the .mp4; the gif and poster go beside it")
    sbs.add_argument("--pad", type=float, default=DEFAULT_PAD, help="seconds kept around the difference (default 2)")
    sbs.add_argument("--max", type=float, default=DEFAULT_SBS_MAX,
                     help="longest output in seconds (default 15): the pad shrinks, then the tail is cut")
    sbs.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD,
                     help="gray levels (0-255) a pixel must move to count as changed (default 24)")
    sbs.add_argument("--min-fraction", type=float, default=DEFAULT_MIN_FRACTION,
                     help="share of a frame's pixels that must change for it to differ (default 0.02; below "
                          "it, one row landing a frame early in one arm reads as a difference)")
    sbs.add_argument("--cut-fraction", type=float, default=DEFAULT_CUT_FRACTION,
                     help="a whole-picture change (first paint) both clips make within two frames of each "
                          "other, at least this share of pixels, is not compared (default 0.9)")
    sbs.add_argument("--analysis-fps", type=float, default=DEFAULT_ANALYSIS_FPS,
                     help="frames per second compared (default 10)")
    sbs.add_argument("--analysis-width", type=int, default=DEFAULT_ANALYSIS_WIDTH,
                     help="width the frames are compared at (default 160)")
    sbs.add_argument("--label", action="append", help="twice: before's, then after's (default before, after)")
    sbs.add_argument("--metric", action="append", help="text under each label, twice")
    sbs.add_argument("--fit", action="store_true", help="letterbox clips of different sizes instead of refusing")
    sbs.add_argument("--scale", type=float, action="append", help="device pixel ratio: once, or once per clip")
    sbs.add_argument("--gap", type=int, default=8, help="px between and around the two (default 8)")
    sbs.add_argument("--background", default=BACKGROUND[2:], help="RRGGBB (default 111111)")

    redact = commands.add_parser("redact", parents=[common], help="box or blur regions",
                                 description="Fill (default) or blur --rect regions. Cropping them out is better.")
    redact.add_argument("source", type=Path)
    redact.add_argument("--out", type=Path, required=True)
    redact.add_argument("--rect", action="append", required=True, metavar="X,Y,W,H", help="CSS px; repeatable")
    redact.add_argument("--scale", type=float, help="device pixel ratio (required)")
    redact.add_argument("--style", choices=("box", "blur"), default="box",
                        help="box fills solid (default; blur can leave text guessable)")
    redact.add_argument("--color", default="000000", help="RRGGBB fill for box (default 000000)")
    redact.add_argument("--label", help="a name for this capture, recorded in labels")

    scan = commands.add_parser("scan", help="print sidecar facts and privacy reminders; refuses nothing",
                               description="Reads no text and refuses nothing: prints each file's size and what "
                                           "its sidecar records, and reminds you to run the privacy check.")
    scan.add_argument("files", type=Path, nargs="+", metavar="FILE")
    scan.set_defaults(dry_run=False)
    return parser.parse_args(argv)


COMMANDS = {"crop": cmd_crop, "pair": cmd_pair, "grid": cmd_grid, "trim": cmd_trim, "sbs": cmd_sbs,
            "redact": cmd_redact, "scan": cmd_scan}


def main(argv: Sequence[str] | None = None, runner: Runner | None = None, out=None) -> int:
    args = parse_args(argv)
    if getattr(args, "runs", None) is not None and args.runs <= 0:
        print("media_polish: --runs must be positive", file=sys.stderr)
        return 2
    ctx = Context(runner or subprocess.run, args.dry_run, out or sys.stdout)
    try:
        return COMMANDS[args.command](args, ctx)
    except PolishError as error:
        print(f"media_polish {args.command}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
