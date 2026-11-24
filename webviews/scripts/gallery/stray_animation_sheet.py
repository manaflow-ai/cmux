#!/usr/bin/env python3
"""Lay the stray-animation capture out as one before/after sheet per variant.

stray-animation-capture.ts writes every frame Chromium painted from the turn's end on
(`<label>/<variant>/painted/NNN-MMMMms.jpg`). This draws, for one variant:

    before   frames  |  each frame's change from the one before it (white = moved)
    after    frames  |  the same

so the motion the reader was not expecting is visible as white where nothing should move.

Usage: python3 -I stray_animation_sheet.py CAPTURE_DIR OUT_DIR
"""

import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

LABELS = ("before", "after")
THUMB_W = 300
PAD = 8
HEAD = 22


def frames(folder: Path) -> list[tuple[int, Path]]:
    out = []
    for path in sorted(folder.glob("*.jpg")):
        ms = int(path.stem.split("-")[1].removesuffix("ms"))
        out.append((ms, path))
    return out


def pick(items: list, most: int) -> list:
    if len(items) <= most:
        return items
    step = (len(items) - 1) / (most - 1)
    return [items[round(index * step)] for index in range(most)]


def changed_pixels(diff: Image.Image) -> int:
    return sum(diff.convert("L").histogram()[13:])


def row(folder: Path, most: int) -> tuple[list[Image.Image], list[Image.Image], list[str]]:
    shots, diffs, notes = [], [], []
    every = frames(folder)
    chosen = pick(every, most)
    for ms, path in chosen:
        image = Image.open(path).convert("RGB")
        scale = THUMB_W / image.width
        size = (THUMB_W, round(image.height * scale))
        shots.append(image.resize(size))
        index = [each[1] for each in every].index(path)
        if index == 0:
            diff = Image.new("RGB", image.size, (0, 0, 0))
            moved = 0
        else:
            diff = ImageChops.difference(image, Image.open(every[index - 1][1]).convert("RGB"))
            moved = changed_pixels(diff)
        diffs.append(diff.point(lambda value: min(255, value * 4)).resize(size))
        notes.append(f"{ms} ms   {moved:,} px moved")
    return shots, diffs, notes


def sheet(capture: Path, variant: str, out: Path, most: int = 7) -> None:
    rows: list[tuple[str, list[Image.Image], list[str]]] = []
    for label in LABELS:
        folder = capture / label / variant / "painted"
        if not folder.is_dir():
            raise SystemExit(f"no painted frames in {folder}")
        shots, diffs, notes = row(folder, most)
        painted = len(frames(folder))
        rows.append((f"{label.upper()}  ({painted} frames painted during the fold)", shots, notes))
        rows.append((f"{label} — what moved between frames", diffs, notes))

    width = PAD + max(len(shots) for _, shots, _ in rows) * (THUMB_W + PAD)
    height = PAD + sum(HEAD + (shots[0].height if shots else 0) + HEAD + PAD for _, shots, _ in rows)
    sheet_image = Image.new("RGB", (width, height), (18, 18, 20))
    draw = ImageDraw.Draw(sheet_image)
    y = PAD
    for title, shots, notes in rows:
        draw.text((PAD, y + 4), title, fill=(235, 235, 240))
        y += HEAD
        x = PAD
        for shot, note in zip(shots, notes):
            sheet_image.paste(shot, (x, y))
            draw.rectangle([x, y, x + shot.width - 1, y + shot.height - 1], outline=(70, 70, 80))
            draw.text((x + 4, y + shot.height + 4), note, fill=(170, 170, 180))
            x += THUMB_W + PAD
        y += (shots[0].height if shots else 0) + HEAD + PAD
    out.mkdir(parents=True, exist_ok=True)
    target = out / f"{variant}.png"
    sheet_image.save(target)
    print(target)


def main() -> None:
    capture = Path(sys.argv[1]).resolve()
    out = Path(sys.argv[2]).resolve()
    for variant in sorted(path.name for path in (capture / "before").iterdir() if path.is_dir()):
        sheet(capture, variant, out)


if __name__ == "__main__":
    main()
