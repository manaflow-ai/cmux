#!/usr/bin/env python3
"""The nightly visual gate: automated checks on real light and dark stills of the app.

    visual_gate.py [--json REPORT] [--summary MD] [--states STATES_DIR] CAPTURE_DIR...

Each CAPTURE_DIR is one state's capture, in the shape both capture paths
write (capture_states.py on a CI runner, `cmux-ci capture` / HQ pr-capture on
a fleet capture mini):

    light.png, dark.png   the app's main window after the state's steps
    result.json           {"steps": [{"title", "status": ok|failed|unavailable, "detail"}],
                           "errors": [...], optionally "window_points": [w, h]}
    text-boxes.json       optional: ocr_boxes.swift's output for the two stills

With --states (the folder of state files the capture drove), every state
there with no CAPTURE_DIR of its name fails: a state that was never captured
is not a pass.

Checks (docs/ci/nightly-next-visual-gate.md says why each one exists):

  steps        a required step failed, the capture reported an error, a still is missing, or
               (with --states) the state was never captured                             -> fail;
               result.json without a `steps` list, or with a step whose status is not ok,
               failed or unavailable                                                  -> error
  appearance   light.png and dark.png differ in size (not comparable)                  -> error;
               light.png and dark.png are the same picture. Before blaming the build it reads
               what the app reported (result.json "appearance", debug.appearance after each
               switch): the build's fault (the app stayed dark, its bundle has no themes, the
               terminal stayed dark on the app's own settings, or the theme switched and the
               window did not repaint) -> fail; the host's (the capture used the Mac's own
               settings, whose pinned theme is dark-only, or recorded nothing to tell)      -> host
  scale        the stills are below 2x (a 1-px seam or a hairline is then half a point), with
               the backing scale measured (pixels over the window's points)            -> warn;
               fail with --require-2x (VISUAL_GATE_REQUIRE_2X=1), the switch to throw once the
               capture Macs have a HiDPI display: debug.window_snapshot draws at the
               display's backing scale, 1x on the capture minis today
  seam         a 1-2 px line of one neutral colour runs through 60% of the window's height or
               width and contrasts with both sides (a gap between layers showing through)     -> fail
  overlap      text drawn over text (a panel drawn see-through over a message, a pill over a
               line): two text boxes that overlap, or one line read much taller than the
               window's other lines that, read again on its own and scaled up, stays garbled
               or comes back as lines on top of each other (Vision reads two pieces of text
               drawn over each other as one tall, garbled line; two wrapped lines it ran
               together read cleanly, one above the other). Garbled means two unknown words,
               or one the reread reads differently: a large heading holding one word the
               spell checker does not know reads the same both times                          -> fail

Levels: fail blocks (in enforce mode), host is the capture Mac's configuration
drifting (named, never blocks: one mini's config must not fail every nightly),
warn and info are notes, and error says the gate could not judge a state (its
files could not be read; the other states are still judged).

Pure Python and stdlib only (PNGs are decoded with zlib), so it runs on any
runner and the tests run on Linux; only producing text-boxes.json needs macOS
Vision. Exit 0 when every state passed, 1 when a check failed, 3 when none
failed but a state could not be judged, 2 on bad input or a crash: the
workflow reads 1 as `fail` and anything else but 0 as `unavailable`.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

# appearance: a real switch repaints most of the window. Fewer changed pixels than
# this, with means this close, is the same picture.
APPEARANCE_PIXEL_DELTA = 24
APPEARANCE_MIN_CHANGED = 0.10
APPEARANCE_MIN_MEAN_DELTA = 12.0
# scale: the gate wants Retina stills.
MIN_SCALE = 2.0
# seam: how far a line must stand out from both sides, how neutral it must be,
# how constant along its length, how much of the window it must cross, and the
# longest interruption (text or a control drawn across it) that still joins a run.
SEAM_CONTRAST = 40
SEAM_MAX_CHROMA = 24
SEAM_COLOR_TOLERANCE = 16
SEAM_MIN_FRACTION = 0.60
SEAM_MAX_GAP = 10
SEAM_WIDTHS = (1, 2)
# overlap: share of the smaller box two text boxes must share, and the smallest
# box (pixels) that counts, so a stray glyph read as its own line is ignored.
OVERLAP_MIN_SHARE = 0.25
OVERLAP_MIN_AREA = 40
OVERLAP_MIN_CONFIDENCE = 0.3
# stacked text: a line at least this many characters long, at least this many
# times the median height of such lines, holding an unknown word at least this
# long (after the reread, when there is one). Product names are not words.
STACKED_MIN_CHARS = 12
STACKED_TALL_RATIO = 1.4
STACKED_MIN_GARBLE = 6
# One unknown word is garbled only when the reread reads it differently; a
# large heading holding one jargon word reads the same both times. Two or more
# unknown words on one tall line are garbled whatever the reread says.
STACKED_MIN_GARBLED_WORDS = 2
KNOWN_WORDS = {"cmux", "acpmux", "glaeda", "webview", "webviews", "showcase", "codex", "worktree", "worktrees",
               "repo", "repos", "localhost", "chromium", "proration", "changelog", "async", "tooltip", "ghostty"}


STEP_STATUSES = {"ok", "failed", "unavailable"}


class BadInput(Exception):
    pass


# ---------------------------------------------------------------- PNG decoding

@dataclass
class Image:
    width: int
    height: int
    channels: int
    pixels: bytes  # 8-bit, row-major, `channels` bytes per pixel, no filter bytes

    def luminance(self) -> bytes:
        """One byte per pixel: Rec. 601 luma, alpha ignored."""
        c, px = self.channels, self.pixels
        if c in (1, 2):
            return px[::c]
        r, g, b = px[0::c], px[1::c], px[2::c]
        return bytes((299 * x + 587 * y + 114 * z) // 1000 for x, y, z in zip(r, g, b))

    def chroma(self) -> bytes:
        """One byte per pixel: max - min of R, G and B (0 for grey)."""
        c, px = self.channels, self.pixels
        if c in (1, 2):
            return bytes(self.width * self.height)
        r, g, b = px[0::c], px[1::c], px[2::c]
        return bytes(max(x, y, z) - min(x, y, z) for x, y, z in zip(r, g, b))


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
CHANNELS = {0: 1, 2: 3, 4: 2, 6: 4}


def decode_png(data: bytes) -> Image:
    """An 8-bit, non-interlaced grey, grey+alpha, RGB or RGBA PNG (what the app's snapshot writes)."""
    if not data.startswith(PNG_SIGNATURE):
        raise BadInput("not a PNG")
    pos, header, chunks = len(PNG_SIGNATURE), None, []
    while pos + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            chunks.append(body)
        elif kind == b"IEND":
            break
    if header is None:
        raise BadInput("PNG without IHDR")
    width, height, depth, color, _, _, interlace = header
    if depth != 8 or color not in CHANNELS or interlace:
        raise BadInput(f"unsupported PNG (bit depth {depth}, colour type {color}, interlace {interlace})")
    channels = CHANNELS[color]
    raw = zlib.decompress(b"".join(chunks))
    stride = width * channels
    if len(raw) < height * (stride + 1):
        raise BadInput("truncated PNG data")
    out = bytearray(height * stride)
    prev = bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind, line = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        if kind == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif kind == 2:
            line = bytearray((a + b) & 0xFF for a, b in zip(line, prev))
        elif kind == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif kind == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        elif kind != 0:
            raise BadInput(f"bad PNG filter {kind} on row {y}")
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return Image(width, height, channels, bytes(out))


def read_png(path: Path) -> Image:
    try:
        return decode_png(path.read_bytes())
    except (OSError, zlib.error, struct.error) as error:
        raise BadInput(f"{path}: {error}") from error


# ---------------------------------------------------------------- checks

def finding(check: str, level: str, message: str, **where: Any) -> dict[str, Any]:
    return {"check": check, "level": level, "message": message, **where}


def check_steps(result: dict[str, Any], stills: dict[str, bool]) -> list[dict[str, Any]]:
    """A failed required step, a capture error or a missing still fails; an optional one is noted."""
    found = []
    steps, errors = result.get("steps"), result.get("errors", [])
    # result.json's schema is the capture's contract. One the gate cannot trust leaves the
    # state unjudged (`error`, so a run with no `fail` is `unavailable`), never a silent pass;
    # a failed step or a capture error beside it still fails.
    if not isinstance(errors, list):
        found.append(finding("steps", "error", f"result.json `errors` is not a list: {errors!r}; steps not checked"))
        errors = []
    if not isinstance(steps, list):
        found.append(finding("steps", "error", "result.json has no `steps` list; steps not checked"))
        steps = []
    for step in steps:
        if not isinstance(step, dict):
            raise BadInput(f"result.json holds a step that is not an object: {step!r}")
        status = step.get("status")
        title = step.get("title") or "(untitled step)"
        detail = f": {step['detail']}" if step.get("detail") else ""
        if status == "failed":
            found.append(finding("steps", "fail", f"step failed: {title}{detail}"))
        elif status == "unavailable":
            found.append(finding("steps", "info", f"optional step unavailable: {title}{detail}"))
        elif status != "ok":
            found.append(finding("steps", "error", f"step {title} has status {status!r}, not one of "
                                                   f"{sorted(STEP_STATUSES)}; not checked"))
    for error in errors:
        found.append(finding("steps", "fail", f"capture error: {error}"))
    for name, present in sorted(stills.items()):
        if not present:
            found.append(finding("steps", "fail", f"{name} is missing"))
    return found


def appearance_difference(light: bytes, dark: bytes) -> tuple[float, float]:
    """(share of pixels whose luma moved more than APPEARANCE_PIXEL_DELTA, light mean - dark mean)."""
    if not light or len(light) != len(dark):
        raise BadInput("the stills differ in size")
    changed = sum(1 for a, b in zip(light, dark) if abs(a - b) > APPEARANCE_PIXEL_DELTA)
    return changed / len(light), (sum(light) - sum(dark)) / len(light)


def colour_luma(text: Any) -> int | None:
    """The luma of a `#RRGGBB` colour, or None."""
    if not isinstance(text, str) or len(text) != 7 or not text.startswith("#"):
        return None
    try:
        r, g, b = (int(text[i:i + 2], 16) for i in (1, 3, 5))
    except ValueError:
        return None
    return (299 * r + 587 * g + 114 * b) // 1000


def same_picture_cause(result: dict[str, Any]) -> tuple[str, str]:
    """Whose fault light == dark is: ("fail", why) for the build, ("host", why) for the Mac.

    Reads debug.appearance as the capture read it back after each switch."""
    host = result.get("host") or "an unnamed host"
    replies = result.get("appearance") or {}
    light = replies.get("light") if isinstance(replies.get("light"), dict) else None
    dark = replies.get("dark") if isinstance(replies.get("dark"), dict) else None
    if light is None:
        return "host", (f"the capture on {host} recorded no appearance from the app, so this cannot be "
                        "pinned on the build; a light still that matches dark is usually that Mac's config "
                        "(a dark-only theme pinned in its cmux-next.json). Recapture on another host")
    if light.get("effective") != "light":
        return "fail", f"the app stayed {light.get('effective') or 'unknown'} after switching to light"
    if "themes" in light and light.get("themes") is None:
        return "fail", "the app bundle ships no Ghostty themes, so its terminal theme cannot follow light"
    light_bg, dark_bg = colour_luma(light.get("terminal_background")), colour_luma((dark or {}).get("terminal_background"))
    if light_bg is not None and light_bg < 128:
        if result.get("settings_source") != "own":
            return "host", (f"on {host} the terminal stayed dark ({light.get('terminal_background')}) in light: the "
                            "capture used that Mac's own settings, whose theme is dark-only (host config drift)")
        return "fail", (f"the terminal stayed dark ({light.get('terminal_background')}) in light on the app's own "
                        "settings: its theme does not follow the appearance")
    if light_bg is not None and dark_bg is not None and light_bg != dark_bg:
        return "fail", (f"the theme switched ({light.get('terminal_background')} light, "
                        f"{dark.get('terminal_background')} dark) but the window did not repaint")
    return "fail", "the appearance switch did not repaint the window"


def check_appearance(light: Image, dark: Image, result: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    if (light.width, light.height) != (dark.width, dark.height):
        # Stills that cannot be compared are a malformed capture: unjudged, never a pass.
        return [finding("appearance", "error", f"light is {light.width}x{light.height}, dark is "
                                               f"{dark.width}x{dark.height}; not compared")]
    changed, mean_delta = appearance_difference(light.luminance(), dark.luminance())
    facts = {"changed": round(changed, 4), "mean_delta": round(mean_delta, 1)}
    if changed < APPEARANCE_MIN_CHANGED and abs(mean_delta) < APPEARANCE_MIN_MEAN_DELTA:
        level, why = same_picture_cause(result or {})
        if level == "host":
            facts["host"] = (result or {}).get("host") or ""
        return [finding("appearance", level,
                        f"light and dark are the same picture ({changed:.1%} of pixels changed, mean luma "
                        f"{mean_delta:+.1f}): {why}", **facts)]
    if mean_delta < 0:
        return [finding("appearance", "warn", f"light is darker than dark (mean luma {mean_delta:+.1f})", **facts)]
    return [finding("appearance", "info", f"{changed:.1%} of pixels changed between light and dark", **facts)]


def check_scale(image: Image, window_points: Iterable[float] | None, *, require: bool = False) -> list[dict[str, Any]]:
    """The still's backing scale (pixels per window point), when the capture recorded the window's
    size in points. Below MIN_SCALE warns, or fails when `require`."""
    points = list(window_points or [])
    if len(points) != 2 or not points[0]:
        return [finding("scale", "fail" if require else "warn",
                        f"{image.width}x{image.height} px; the capture did not record the window size in points, "
                        "so the backing scale is unknown")]
    scale = image.width / float(points[0])
    facts = {"scale": round(scale, 2)}
    if scale + 0.01 < MIN_SCALE:
        return [finding("scale", "fail" if require else "warn",
                        f"backing scale {scale:.2g}x ({image.width}x{image.height} px for a {points[0]:g}x{points[1]:g} "
                        f"pt window); want {MIN_SCALE:g}x", **facts)]
    return [finding("scale", "info", f"stills are {scale:.2g}x", **facts)]


def seam_runs(line: bytes, before: bytes, after: bytes, chroma: bytes) -> list[tuple[int, int, int]]:
    """Runs along one line (a column or a row) where it is a neutral, constant colour that stands
    out from the lines on both sides in the same direction: (start, end exclusive, colour).
    Interruptions up to SEAM_MAX_GAP long are bridged."""
    runs: list[tuple[int, int, int]] = []
    start = last = -1
    colour = 0
    for i, (v, a, b, c) in enumerate(zip(line, before, after, chroma)):
        hit = c <= SEAM_MAX_CHROMA and ((v - a >= SEAM_CONTRAST and v - b >= SEAM_CONTRAST)
                                        or (a - v >= SEAM_CONTRAST and b - v >= SEAM_CONTRAST))
        if not hit:
            continue
        if start >= 0 and i - last <= SEAM_MAX_GAP + 1 and abs(v - colour) <= SEAM_COLOR_TOLERANCE:
            last = i
            continue
        if start >= 0:
            runs.append((start, last + 1, colour))
        start = last = i
        colour = v
    if start >= 0:
        runs.append((start, last + 1, colour))
    return runs


def _line(plane: bytes, width: int, height: int, axis: str, index: int) -> bytes:
    """Column `index` (axis x) or row `index` (axis y) of a one-byte-per-pixel plane."""
    if axis == "x":
        return plane[index::width][:height]
    return plane[index * width:(index + 1) * width]


def find_seams(luma: bytes, chroma: bytes, width: int, height: int) -> list[dict[str, Any]]:
    """Every 1-2 px vertical or horizontal seam crossing SEAM_MIN_FRACTION of the window."""
    seams = []
    for axis, count, length in (("x", width, height), ("y", height, width)):
        need = SEAM_MIN_FRACTION * length
        line = lambda plane, i: _line(plane, width, height, axis, i)
        taken: set[int] = set()
        for span in SEAM_WIDTHS:
            for i in range(1, count - span):
                if i in taken:
                    continue
                body, before = line(luma, i), line(luma, i - 1)
                if span == 2:
                    # Where the two lines differ it is no 2-px line: the side's own value there
                    # is never a hit, while the rest of the run still counts.
                    second = line(luma, i + 1)
                    body = bytes(p if abs(p - q) <= SEAM_COLOR_TOLERANCE else a
                                 for p, q, a in zip(body, second, before))
                for start, end, colour in seam_runs(body, before, line(luma, i + span), line(chroma, i)):
                    if end - start >= need:
                        taken.update(range(i, i + span))
                        seams.append({"axis": axis, "at": i, "width": span, "start": start, "end": end,
                                      "colour": colour, "fraction": round((end - start) / length, 3)})
    return seams


def check_seams(image: Image, name: str) -> list[dict[str, Any]]:
    seams = find_seams(image.luminance(), image.chroma(), image.width, image.height)
    found = []
    for seam in seams:
        kind = "vertical" if seam["axis"] == "x" else "horizontal"
        where = f"x={seam['at']}" if seam["axis"] == "x" else f"y={seam['at']}"
        found.append(finding("seam", "fail",
                             f"{name}: {seam['width']}-px {kind} seam at {where}, luma {seam['colour']}, "
                             f"{seam['start']}-{seam['end']} ({seam['fraction']:.0%} of the window)",
                             image=name, **seam))
    return found


def box_overlap(a: list[float], b: list[float]) -> float:
    """Intersection area over the smaller box's area; boxes are [x, y, w, h]."""
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    ix = max(0.0, min(ax + aw, bx + bw) - max(ax, bx))
    iy = max(0.0, min(ay + ah, by + bh) - max(ay, by))
    smaller = min(aw * ah, bw * bh)
    return (ix * iy) / smaller if smaller > 0 else 0.0


def clean_merge(observation: dict[str, Any]) -> bool:
    """Vision ran wrapped lines together (and often reads the second one again on its own): the
    reread splits it into clean lines, one above the other. Such a box overlapping another read
    of its own text is not text over text."""
    reread = observation.get("reread")
    if not isinstance(reread, dict) or len(reread.get("lines") or []) < 2:
        return False
    return not garbled_words(observation) and not reread_collisions(observation)


def text_overlaps(observations: list[dict[str, Any]]) -> list[tuple[dict[str, Any], dict[str, Any], float]]:
    """Pairs of separately read text whose boxes share at least OVERLAP_MIN_SHARE of the smaller box."""
    usable = [o for o in observations
              if isinstance(o, dict) and not clean_merge(o)
              and isinstance(o.get("box"), list) and len(o["box"]) == 4
              and o["box"][2] * o["box"][3] >= OVERLAP_MIN_AREA
              and float(o.get("confidence", 1.0)) >= OVERLAP_MIN_CONFIDENCE
              and str(o.get("text", "")).strip()]
    pairs = []
    for i, a in enumerate(usable):
        for b in usable[i + 1:]:
            share = box_overlap(a["box"], b["box"])
            if share >= OVERLAP_MIN_SHARE:
                pairs.append((a, b, share))
    return pairs


def _line_text(line: Any) -> str:
    return str(line.get("text", "")) if isinstance(line, dict) else str(line)


def clipped_tail(texts: Iterable[str]) -> set[str]:
    """The last word of each line that ends in a letter: a line cut off at a pane's edge ends
    in half a word (`sentenc`), which is clipping, not text over text."""
    tails = set()
    for text in texts:
        run = ""
        for char in reversed(text.rstrip()):
            if not char.isalpha():
                break
            run = char + run
        if run:
            tails.add(run)
    return tails


def garbled_words(observation: dict[str, Any]) -> list[str]:
    """Unknown words long enough to be garbage rather than a name: from the reread when the
    helper made one (two lines Vision ran together read cleanly there), else from the line."""
    reread = observation.get("reread")
    if isinstance(reread, dict):
        words, texts = reread.get("misspelled"), [_line_text(line) for line in reread.get("lines") or []]
    else:
        words, texts = observation.get("misspelled"), [str(observation.get("text", ""))]
    tails = clipped_tail(texts)
    return [w for w in words or [] if isinstance(w, str) and len(w) >= STACKED_MIN_GARBLE
            and w.lower() not in KNOWN_WORDS and w not in tails]


def reread_collisions(observation: dict[str, Any]) -> list[tuple[str, str]]:
    """Pairs of lines the reread found on top of each other (a tab title under a toast)."""
    reread = observation.get("reread")
    lines = [line for line in (reread.get("lines") or []) if isinstance(line, dict)] if isinstance(reread, dict) else []
    lines = [line for line in lines if isinstance(line.get("box"), list) and len(line["box"]) == 4
             and str(line.get("text", "")).strip()]
    return [(a["text"], b["text"]) for i, a in enumerate(lines) for b in lines[i + 1:]
            if box_overlap(a["box"], b["box"]) >= OVERLAP_MIN_SHARE]


def unsteady_words(observation: dict[str, Any], words: list[str]) -> list[str]:
    """Of the reread's unknown `words`, those the first read did not read the same: garbage
    changes from one read to the next, a real word Vision knows the shape of does not."""
    if not isinstance(observation.get("reread"), dict):
        return []
    first = str(observation.get("text", "")).lower()
    return [w for w in words if w.lower() not in first]


def garbled_evidence(observation: dict[str, Any]) -> list[str]:
    """The garbled words of a tall line, when they are evidence of text over text: two or more,
    or one the reread read differently. One steady unknown word (jargon in a large heading, or a
    word one host's spell checker lacks) is not."""
    words = garbled_words(observation)
    if len(words) >= STACKED_MIN_GARBLED_WORDS or unsteady_words(observation, words):
        return [f"garbled {w!r}" for w in words]
    return []


def stacked_lines(observations: list[dict[str, Any]]) -> list[tuple[dict[str, Any], float, list[str]]]:
    """Lines read much taller than the window's other lines that stay garbled, or whose reread
    puts lines on top of each other: text over text. (line, height ratio, evidence)."""
    lines = [o for o in observations if isinstance(o, dict) and isinstance(o.get("box"), list)
             and len(o["box"]) == 4 and len(str(o.get("text", ""))) >= STACKED_MIN_CHARS]
    if len(lines) < 3:
        return []
    heights = sorted(o["box"][3] for o in lines)
    median = heights[len(heights) // 2] if len(heights) % 2 else (heights[len(heights) // 2 - 1] + heights[len(heights) // 2]) / 2
    if median <= 0:
        return []
    found = []
    for o in lines:
        ratio = o["box"][3] / median
        if ratio >= STACKED_TALL_RATIO:
            evidence = garbled_evidence(o)
            evidence += [f"{a!r} on top of {b!r}" for a, b in reread_collisions(o)]
            if evidence:
                found.append((o, ratio, evidence))
    return found


def check_overlaps(boxes: dict[str, Any] | None, name: str) -> list[dict[str, Any]]:
    # No text boxes means the text-over-text check could not run: the state is not judged
    # (`error`, so a run with no `fail` is `unavailable`), never a silent pass.
    if boxes is None:
        return [finding("overlap", "error", f"{name}: no text boxes (text-boxes.json); overlap not checked")]
    observations = boxes.get("observations") if isinstance(boxes, dict) else None
    if not isinstance(observations, list):
        return [finding("overlap", "error", f"{name}: text-boxes.json has no observation list; overlap not checked")]
    found = []
    for a, b, share in text_overlaps(observations):
        found.append(finding("overlap", "fail",
                             f"{name}: {a['text']!r} at {a['box']} overlaps {b['text']!r} at {b['box']} "
                             f"({share:.0%} of the smaller)", image=name, boxes=[a["box"], b["box"]]))
    for o, ratio, evidence in stacked_lines(observations):
        found.append(finding("overlap", "fail",
                             f"{name}: text over text at {o['box']}: read as {o['text']!r}, {ratio:.1f}x the "
                             f"usual line height; {'; '.join(evidence[:3])}", image=name, boxes=[o["box"]]))
    return found


# ---------------------------------------------------------------- driver

def read_json(path: Path) -> Any:
    """The JSON in `path`; BadInput when it cannot be read or parsed (an empty file included)."""
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise BadInput(f"{path.name}: {error}") from error


def read_boxes(directory: Path) -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
    """(text boxes by still name, findings); None when there are none to read."""
    boxes_file = directory / "text-boxes.json"
    if not boxes_file.is_file():
        return None, []
    try:
        data = read_json(boxes_file)
    except BadInput as error:
        return None, [finding("overlap", "error", f"{error}; overlap not checked")]
    if not isinstance(data, dict):
        return None, [finding("overlap", "error", "text-boxes.json is not an object; overlap not checked")]
    return {Path(key).name: value for key, value in data.items()}, []


def gate_capture(directory: Path, *, require_2x: bool = False,
                 findings: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    """Every check on one state's capture directory. Findings go into `findings` as they are
    made, so a caller that catches a later error still has the ones found before it."""
    findings = [] if findings is None else findings
    result_path = directory / "result.json"
    # No result.json: the capture of the state never finished, which fails it. One the gate
    # cannot read is the capture tool's fault, not the build's: BadInput, and judge() keeps it.
    result: Any = read_json(result_path) if result_path.is_file() else {"steps": [], "errors": ["no result.json"]}
    if not isinstance(result, dict):
        raise BadInput("result.json is not an object")
    stills = {name: (directory / name).is_file() for name in ("light.png", "dark.png")}
    findings += check_steps(result, stills)
    images = {name: read_png(directory / name) for name, present in stills.items() if present}
    boxes_by_name, box_findings = read_boxes(directory)
    findings += box_findings
    if len(images) == 2:
        findings += check_appearance(images["light.png"], images["dark.png"], result)
    if images:
        first = images.get("light.png") or next(iter(images.values()))
        findings += check_scale(first, result.get("window_points"), require=require_2x)
    for name, image in sorted(images.items()):
        findings += check_seams(image, name)
        if not box_findings:  # an unreadable text-boxes.json warned once already
            findings += check_overlaps(None if boxes_by_name is None else boxes_by_name.get(name), name)
    return report(directory, result.get("state") or directory.name, result.get("host"), findings)


def report(directory: Path, state: str, host: Any, findings: list[dict[str, Any]]) -> dict[str, Any]:
    failed = any(f["level"] == "fail" for f in findings)
    verdict = "fail" if failed else "error" if any(f["level"] == "error" for f in findings) else "pass"
    return {"capture": str(directory), "state": state, "host": host, "ok": verdict == "pass",
            "verdict": verdict, "findings": findings}


def judge(directory: Path, *, require_2x: bool = False) -> dict[str, Any]:
    """gate_capture(), with any error reading the state's files kept as that state's finding, so
    one bad still never stops the others from being judged."""
    found: list[dict[str, Any]] = []
    try:
        return gate_capture(directory, require_2x=require_2x, findings=found)
    except Exception as error:  # noqa: BLE001 - one state's bad file must not end the gate
        # Keep what was found before the error: a failed step stays `fail`, never `error`.
        return report(directory, directory.name, None,
                      found + [finding("gate", "error", f"could not judge this state: {type(error).__name__}: {error}")])


def never_captured(captures: list[Path], states: Path) -> list[dict[str, Any]]:
    """A failing report for each state file in `states` with no capture folder of its name."""
    captured = {directory.name for directory in captures}
    return [report(states / path.name, path.stem, None,
                   [finding("steps", "fail", f"the state was never captured (no {path.stem}/ folder)")])
            for path in sorted(states.glob("*.json")) if path.stem not in captured]


def summary_markdown(reports: list[dict[str, Any]]) -> str:
    lines = ["## Nightly visual gate", "",
             "| State | Host | Result | Failures | Host drift | Warnings |", "| --- | --- | --- | --- | --- | --- |"]
    for report in reports:
        count = lambda level: sum(1 for f in report["findings"] if f["level"] == level)
        result = {"pass": "pass", "fail": "FAIL"}.get(report.get("verdict", ""), "not judged")
        lines.append(f"| `{report['state']}` | {report.get('host') or ''} | {result} "
                     f"| {count('fail')} | {count('host')} | {count('warn')} |")
    for report in reports:
        shown = [f for f in report["findings"] if f["level"] in ("fail", "error", "host", "warn")]
        if shown:
            lines += ["", f"### `{report['state']}`", ""]
            lines += [f"- **{f['level']}** {f['check']}: {f['message']}" for f in shown]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    parser.add_argument("captures", nargs="+", type=Path, help="one directory per captured state")
    parser.add_argument("--json", type=Path, help="write the full report here")
    parser.add_argument("--summary", type=Path, help="append a Markdown summary here ($GITHUB_STEP_SUMMARY)")
    parser.add_argument("--states", type=Path, help="the state files the capture drove: each one not captured fails")
    parser.add_argument("--require-2x", action="store_true", default=os.environ.get("VISUAL_GATE_REQUIRE_2X") == "1",
                        help="fail stills below 2x instead of warning (default: VISUAL_GATE_REQUIRE_2X=1)")
    args = parser.parse_args(argv)
    try:
        return run(args)
    except Exception as error:  # noqa: BLE001 - a crash is `unavailable`, never a build failure
        print(f"visual-gate: crashed: {type(error).__name__}: {error}", file=sys.stderr)
        return 2


def run(args: argparse.Namespace) -> int:
    reports = [judge(directory, require_2x=args.require_2x) for directory in args.captures]
    if args.states:
        reports += never_captured(args.captures, args.states)
    for report in reports:
        print(f"{report['verdict'].upper()} {report['state']}")
        for f in report["findings"]:
            print(f"  {f['level']:>5} {f['check']}: {f['message']}")
            if f["level"] == "host" and os.environ.get("GITHUB_ACTIONS"):
                print(f"::warning title=visual gate host drift::{report['state']}: {f['message']}")
    if args.json:
        args.json.write_text(json.dumps(reports, indent=2) + "\n")
    if args.summary:
        with args.summary.open("a") as out:
            out.write(summary_markdown(reports))
    verdicts = {report["verdict"] for report in reports}
    return 1 if "fail" in verdicts else 3 if "error" in verdicts else 0


if __name__ == "__main__":
    sys.exit(main())
