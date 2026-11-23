#!/usr/bin/env python3
"""pr_media_lint: warn-only checks for a pull request's UI measurements, screenshots and clips.

This is the Detector the hq handbook page ui-measurement-confounded.md names. It never blocks: it prints
`warning: <path>: <rule>: <what to do>` lines to stderr (plus `::warning file=...::` annotations when
GITHUB_ACTIONS is set) and always exits 0, even when the lint itself crashes.

    usage: pr_media_lint.py [--body FILE|-] [MEDIA ...]

    --body   the PR body: a text file, or `-` for stdin. Text that parses as a JSON object with a "body" key
             (`gh pr view N --json body`) uses that key.
    MEDIA    png/jpg/gif/mp4/mov files. A sidecar `<media>.media.json` (or `<stem>.media.json`), written by
             scripts/media/media_polish.py, is read when present: source, crop_bounds, scale, dims{w,h}, margin,
             variable, control, runs, window_frames{start,end}, viewport, split, labels (missing means null).

Rules:
    uncropped-full-display        a still or clip the size of a whole display (or its retina half), with no
                                  sidecar crop_bounds: crop to the part the change touches.
    before-after-mismatch         a before/after (base/head, -a/-b) pair whose sizes differ.
    measurement-table-unqualified a PR body table of measurements (px, ms, fps, jump, gap, duration) that does
                                  not say the variable under test, the control, the run count, and the frame
                                  window or viewport; or whose measurements are all ~0 (measured nothing is
                                  suspect, not a pass: the event may have been off screen).
    sidecar-gaps                  a sidecar whose variable, control or runs is null.

Dimensions come from the PNG/GIF/JPEG headers, and from ffprobe for mp4/mov (skipped quietly without it).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path
from typing import Iterable, TextIO

STILLS = frozenset({".png", ".jpg", ".jpeg", ".gif"})
CLIPS = frozenset({".mp4", ".mov"})
MEDIA_SUFFIXES = STILLS | CLIPS

_DISPLAYS = ((1440, 900), (1512, 982), (1728, 1117), (1920, 1080), (2560, 1440), (2880, 1800), (3024, 1964),
             (3456, 2234), (3840, 2160))
FULL_DISPLAYS = frozenset(_DISPLAYS) | frozenset((w // 2, h // 2) for w, h in _DISPLAYS)
SCREEN_SOURCES = frozenset({"screen", "display", "fullscreen", "full-screen", "desktop"})

# A measurement column: its header names one of these.
MEASURE_HEADER = re.compile(r"\b(px|ms|fps|jump|gap|duration|shift|delta|offset|latency)\b", re.I)
NEAR_ZERO = 0.5
QUALIFIERS = {
    "variable under test": re.compile(r"\bvariables?\b|\bunder test\b|\bonly (?:change|difference)\b|\bvaried\b", re.I),
    "control run": re.compile(r"\bcontrols?\b|\bbaseline\b", re.I),
    "run count (median of 3+)": re.compile(r"\bmedian\b|\b\d+\s+(?:runs|trials|repeats|recordings)\b|\bn\s*=\s*\d+",
                                           re.I),
    "frame window / viewport": re.compile(r"\bviewport\b|\bframe window\b|\bframes?\s+\d+\s*(?:-|–|to)\s*\d+|"
                                          r"\b\d{3,4}\s*[x×]\s*\d{3,4}\b", re.I),
}
OFF_SCREEN = re.compile(r"\b(?:out of (?:the )?view|off[- ]?screen|not (?:in|on) (?:view|screen)|outside the viewport)\b",
                        re.I)
NUMBER = re.compile(r"^[~≈<>]?\s*(-?\d+(?:\.\d+)?)\s*(?:px|ms|fps|s|%)?$", re.I)

PAIR_TOKENS = (("before", "after"), ("base", "head"), ("a", "b"))


# --- dimensions -----------------------------------------------------------------------------------------------

def dimensions(path: Path) -> tuple[int, int] | None:
    """(width, height) from the file's header, or ffprobe for a clip; None when it cannot be read."""
    suffix = path.suffix.lower()
    try:
        if suffix in CLIPS:
            return _ffprobe(path)
        with path.open("rb") as f:
            head = f.read(32)
            if head.startswith(b"\x89PNG\r\n\x1a\n") and head[12:16] == b"IHDR":
                return struct.unpack(">II", head[16:24])
            if head[:6] in (b"GIF87a", b"GIF89a"):
                return struct.unpack("<HH", head[6:10])
            if head[:2] == b"\xff\xd8":
                f.seek(2)
                return _jpeg(f)
    except (OSError, struct.error):
        return None
    return None


def _jpeg(f) -> tuple[int, int] | None:
    while True:
        byte = f.read(1)
        while byte and byte != b"\xff":
            byte = f.read(1)
        while byte == b"\xff":
            byte = f.read(1)
        if not byte:
            return None
        marker = byte[0]
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            continue
        length = f.read(2)
        if len(length) < 2:
            return None
        size = struct.unpack(">H", length)[0]
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            data = f.read(5)
            if len(data) < 5:
                return None
            h, w = struct.unpack(">HH", data[1:5])
            return w, h
        f.seek(size - 2, 1)


def _ffprobe(path: Path) -> tuple[int, int] | None:
    exe = shutil.which("ffprobe")
    if not exe:
        return None
    try:
        out = subprocess.run([exe, "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                              "-of", "csv=p=0:s=x", str(path)], capture_output=True, text=True, timeout=30,
                             stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.match(r"(\d+)x(\d+)", out.stdout.strip())
    return (int(m.group(1)), int(m.group(2))) if out.returncode == 0 and m else None


# --- sidecars -------------------------------------------------------------------------------------------------

def sidecar(path: Path) -> dict | None:
    """The media_polish sidecar next to path, or None. An unreadable one counts as absent."""
    for candidate in (path.with_name(path.name + ".media.json"), path.with_name(path.stem + ".media.json")):
        if candidate.is_file():
            try:
                doc = json.loads(candidate.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                return None
            return doc if isinstance(doc, dict) else None
    return None


# --- rules ----------------------------------------------------------------------------------------------------

Warning = tuple[str, str, str]  # (path, rule, what to do)


def uncropped(name: str, dims: tuple[int, int] | None, side: dict | None) -> list[Warning]:
    if side is not None and side.get("crop_bounds"):
        return []
    full = dims in FULL_DISPLAYS
    screen = side is not None and str(side.get("source") or "").lower() in SCREEN_SOURCES
    if not (full or screen):
        return []
    size = f"{dims[0]}x{dims[1]}" if dims else "unknown size"
    why = f"{size} is a whole display" if full else "its sidecar says a whole-screen source with crop_bounds null"
    return [(name, "uncropped-full-display",
             f"{why}; crop to the window or the part the change touches (scripts/media/media_polish.py records "
             "crop_bounds)")]


def pair_key(name: str) -> tuple[str, str] | None:
    """(the name with its before/after token taken out, which side) or None when the name has no such token."""
    p = Path(name)
    words = [w for w in re.split(r"[-_. ]+", p.stem.lower()) if w]
    for first, second in PAIR_TOKENS:
        for side in (first, second):
            # -a/-b only as the last word: "a" anywhere else is just a word
            at = ([len(words) - 1] if len(words) > 1 and words[-1] == side else []) if side in ("a", "b") else \
                [i for i, w in enumerate(words) if w == side][:1]
            if at:
                rest = words[:at[0]] + words[at[0] + 1:]
                return str(p.parent / ("-".join(rest) + suffix_group(p.suffix.lower()))), side
    return None


def suffix_group(suffix: str) -> str:
    """A png/jpg pairs with a png/jpg; a gif, mp4 or mov (a clip) with a clip."""
    return ".still" if suffix in {".png", ".jpg", ".jpeg"} else ".clip"


def mismatched_pairs(items: list[tuple[str, tuple[int, int] | None]]) -> list[Warning]:
    groups: dict[str, dict[str, tuple[str, tuple[int, int] | None]]] = {}
    for name, dims in items:
        key = pair_key(name)
        if key:
            groups.setdefault(key[0], {})[key[1]] = (name, dims)
    out = []
    for sides in groups.values():
        for first, second in PAIR_TOKENS:
            if first in sides and second in sides:
                (a, da), (b, db) = sides[first], sides[second]
                if da and db and da != db:
                    aspect = "" if da[0] * db[1] == da[1] * db[0] else " and aspect ratio"
                    out.append((b, "before-after-mismatch",
                                f"{a} is {da[0]}x{da[1]} but {b} is {db[0]}x{db[1]} (different size{aspect}); "
                                "capture both with the same window size and crop so they compare"))
    return out


def tables(body: str) -> list[list[list[str]]]:
    """Each markdown table in body as rows of cells, header first, the --- row dropped."""
    found, current = [], []
    for line in body.splitlines() + [""]:
        s = line.strip()
        if s.startswith("|") and s.count("|") >= 2:
            cells = [c.strip() for c in s.strip("|").split("|")]
            if not all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c):
                current.append(cells)
            continue
        if len(current) >= 2:
            found.append(current)
        current = []
    return found


def number(cell: str) -> float | None:
    m = NUMBER.match(cell.strip().strip("`*").strip())
    return float(m.group(1)) if m else None


def measurement_columns(table: list[list[str]]) -> list[tuple[str, list[float | None]]]:
    header, rows = table[0], table[1:]
    cols = []
    for i, title in enumerate(header):
        if not MEASURE_HEADER.search(title):
            continue
        values = [number(r[i]) if i < len(r) else None for r in rows]
        if sum(v is not None for v in values) * 2 >= len(values) > 0:
            cols.append((title, values))
    return cols


def measurement_table(body: str | None, where: str = "PR body") -> list[Warning]:
    if not body:
        return []
    out = []
    measured = [(t, measurement_columns(t)) for t in tables(body)]
    measured = [(t, cols) for t, cols in measured if cols]
    if not measured:
        return []
    missing = [what for what, pattern in QUALIFIERS.items() if not pattern.search(body)]
    if missing:
        out.append((where, "measurement-table-unqualified",
                    f"the measurement table does not state: {', '.join(missing)}; say what one thing changed, "
                    "what the control run was, how many runs (median of 3+), and the frame window and viewport"))
    if OFF_SCREEN.search(body):
        out.append((where, "measurement-table-unqualified",
                    "the body says the event happened out of view; a measurement of something off screen is ~0 by "
                    "construction, so re-record with the event inside the viewport and frame window"))
    for table, cols in measured:
        rows = table[1:]
        for title, values in cols:
            nums = [v for v in values if v is not None]
            if nums and all(abs(v) < NEAR_ZERO for v in nums):
                out.append((where, "measurement-table-unqualified",
                            f"every '{title}' value is ~0: measured nothing is suspect, not a pass; check the "
                            "event happened in view and inside the frame window"))
                continue
            # Rows that share their first cell (one chat, one fixture) whose values are all ~0.
            groups: dict[str, list[float]] = {}
            for row, v in zip(rows, values):
                if v is not None and row:
                    groups.setdefault(row[0], []).append(v)
            for label, vs in groups.items():
                if len(vs) >= 2 and all(abs(v) < NEAR_ZERO for v in vs):
                    out.append((where, "measurement-table-unqualified",
                                f"every '{title}' value for '{label}' is ~0: measured nothing is suspect, not a "
                                "pass; check the event happened in view and inside the frame window"))
    return out


def sidecar_gaps(name: str, side: dict | None) -> list[Warning]:
    if side is None:
        return []
    out = []
    missing = [key for key in ("variable", "control", "runs") if side.get(key) in (None, "", [])]
    if missing:
        out.append((name, "sidecar-gaps",
                    f"sidecar has no {', '.join(missing)}; record the variable under test, the control run and "
                    "the run count"))
    runs = side.get("runs")
    if isinstance(runs, (int, float)) and not isinstance(runs, bool) and runs < 3:
        out.append((name, "sidecar-gaps", f"runs is {runs:g}; take the median of 3 or more runs"))
    return out


def lint(media: Iterable[tuple[str, Path]], body: str | None = None) -> list[Warning]:
    """Every warning for media (shown name, local file) and the PR body."""
    out: list[Warning] = []
    sized = []
    for name, local in media:
        local = Path(local)
        suffix = (Path(name).suffix or local.suffix).lower()
        if suffix not in MEDIA_SUFFIXES:
            continue
        dims = dimensions(local)
        side = sidecar(local)
        if dims is None and side and isinstance(side.get("dims"), dict):
            try:
                dims = (int(side["dims"]["w"]), int(side["dims"]["h"]))
            except (KeyError, TypeError, ValueError):
                dims = None
        sized.append((name, dims))
        out += uncropped(name, dims, side)
        out += sidecar_gaps(name, side)
    out += mismatched_pairs(sized)
    out += measurement_table(body)
    return out


def report(warnings: list[Warning], out: TextIO = sys.stderr, env: dict | None = None) -> None:
    env = os.environ if env is None else env
    for path, rule, what in warnings:
        print(f"warning: {path}: {rule}: {what}", file=out)
        if env.get("GITHUB_ACTIONS"):
            text = what.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::warning file={path},title=pr-media-lint {rule}::{text}", file=out)


def read_body(arg: str | None, stdin: TextIO) -> str | None:
    if not arg:
        return None
    text = stdin.read() if arg == "-" else Path(arg).read_text(encoding="utf-8")
    try:
        doc = json.loads(text)
    except ValueError:
        return text
    if isinstance(doc, dict) and isinstance(doc.get("body"), str):
        return doc["body"]
    return text


def main(argv: list[str] | None = None, stdin: TextIO = sys.stdin, out: TextIO = sys.stderr) -> int:
    try:
        parser = argparse.ArgumentParser(prog="pr_media_lint.py", description="Warn-only PR media lint; exits 0.")
        parser.add_argument("--body", help="the PR body: a file, or - for stdin (text or {\"body\": ...})")
        parser.add_argument("media", nargs="*", help="png/jpg/gif/mp4/mov files")
        args = parser.parse_args(argv)
        report(lint([(m, Path(m)) for m in args.media], read_body(args.body, stdin)), out)
    except SystemExit as stop:  # --help, or bad arguments: argparse has printed why
        return 0
    except Exception as error:  # noqa: BLE001 - a lint never blocks, a crash included
        print(f"warning: pr_media_lint crashed ({type(error).__name__}: {error}); no media was linted", file=out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
