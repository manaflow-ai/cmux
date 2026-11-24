#!/usr/bin/env python3
"""Count the relaunches of cmux-next-ios that drew the stock look instead of the cached Mac theme.

    ios_theme_relaunch_count.py --stock STOCK.png --themed THEMED.png --out verdict.json DIR [DIR ...]

Each DIR is one relaunch: its PNG frames, in name order (a burst from launch, then `settled.png`).
STOCK.png is the same screen with no Mac theme ever applied; THEMED.png is it with the theme
applied live. All images are the same small size (the caller downscales them with sips). A frame
is nearest to whichever reference it differs from less (mean absolute channel difference, 0-255);
a frame nearer the stock one by a clear margin (MARGIN) counts as stock. A relaunch lost the theme
when any of its frames counts as stock. The launch screen (LaunchMark on LaunchBackground) is
neither reference; it is reported but decides nothing unless it lands that near the stock screen.
Standard library only (the fleet's Macs have no Pillow): PNG decoding is ios_gate_screen_diff's.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ios_gate_screen_diff import _rgba, _rows, read_png  # noqa: E402

# A frame counts as stock when its distance to the stock screen is under this share of its
# distance to the themed one.
MARGIN = 0.6


def pixels(path: Path) -> tuple[int, int, bytes]:
    png = read_png(path.read_bytes())
    return png.width, png.height, b"".join(_rgba(row, png) for row in _rows(png))


def distance(a: tuple[int, int, bytes], b: tuple[int, int, bytes]) -> float | None:
    if a[:2] != b[:2]:
        return None
    pa, pb = a[2], b[2]
    total = 0
    count = 0
    for i in range(0, len(pa), 4):
        total += abs(pa[i] - pb[i]) + abs(pa[i + 1] - pb[i + 1]) + abs(pa[i + 2] - pb[i + 2])
        count += 3
    return total / count if count else 0.0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stock", type=Path, required=True)
    parser.add_argument("--themed", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("launches", type=Path, nargs="+")
    args = parser.parse_args(argv)
    stock = pixels(args.stock)
    themed = pixels(args.themed)
    refs_apart = distance(stock, themed)
    launches = []
    lost = 0
    for folder in args.launches:
        frames = []
        launch_lost = False
        for frame in sorted(folder.glob("*.png")):
            try:
                image = pixels(frame)
            except Exception as error:  # noqa: BLE001 - a frame we cannot read is reported, not fatal
                frames.append({"frame": frame.name, "error": str(error)})
                continue
            d_stock = distance(image, stock)
            d_themed = distance(image, themed)
            if d_stock is None or d_themed is None:
                frames.append({"frame": frame.name, "error": "size differs from the references"})
                continue
            verdict = "stock" if d_stock < MARGIN * d_themed else "themed" if d_themed < MARGIN * d_stock else "neither"
            launch_lost = launch_lost or verdict == "stock"
            frames.append({"frame": frame.name, "to_stock": round(d_stock, 2), "to_themed": round(d_themed, 2),
                           "verdict": verdict})
        lost += launch_lost
        launches.append({"launch": folder.name, "lost": launch_lost, "frames": frames})
    result = {"metric": "ios_theme_lost_of_relaunches", "lost": lost, "relaunches": len(launches),
              "references_apart": round(refs_apart, 2) if refs_apart is not None else None,
              "margin": MARGIN, "launches": launches}
    args.out.write_text(json.dumps(result, indent=2) + "\n")
    print(f"theme lost on {lost} of {len(launches)} relaunches (references {result['references_apart']} apart)")
    for launch in launches:
        marks = " ".join(f"{f['frame']}:{f.get('verdict', 'error')}" for f in launch["frames"])
        print(f"  {launch['launch']}: {'LOST' if launch['lost'] else 'kept'}  {marks}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
