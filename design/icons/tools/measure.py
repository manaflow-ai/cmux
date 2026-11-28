"""Measures each icon's ink bounding box by rasterizing in headless Chrome.

Usage: python3 measure.py [out.json]
Renders every variant (line, solid, cat with its accent, alt line/solid) black on white
at 96 px (4 px per unit), then reads the ink box per cell with PIL. Writes
{key: {"x0","y0","x1","y1","cx","cy","w","h"}} in viewBox units, where key is
"<name>|<variant>" and variant is line, solid, cat, alt<i>.line or alt<i>.solid.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ICONS = Path(os.environ.get("ICONS_DIR", ROOT / "icons"))
OUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "measure" / "ink.json"
CELL, COLS, UNIT = 96, 16, 4


def variants():
    for path in sorted(ICONS.glob("*.json")):
        for icon in json.loads(path.read_text())["icons"]:
            yield f"{icon['name']}|line", icon["line"]
            yield f"{icon['name']}|solid", icon["solid"]
            if icon.get("cat"):
                yield f"{icon['name']}|cat", icon["cat"]
            for i, alt in enumerate(icon.get("alts") or []):
                for k in ("line", "solid"):
                    if alt.get(k):
                        yield f"{icon['name']}|alt{i}.{k}", alt[k]


def coverage(cell):
    """Ink and silhouette area in square units. The silhouette is everything the outline encloses: close
    small gaps (dashes, the space between a badge and its shape) by 2 units, flood the outside from the
    corner, and count what the flood cannot reach, then erode by the same 2 units. A full square frame and a
    chevron of the same extent differ here, not in their bounding boxes."""
    ink = cell.point(lambda v: 255 if v < 128 else 0)
    pad = Image.new("L", (CELL + 16, CELL + 16), 0)
    pad.paste(ink, (8, 8))
    closed = pad.filter(ImageFilter.MaxFilter(4 * UNIT + 1))
    ImageDraw.floodfill(closed, (0, 0), 128)
    inside = closed.point(lambda v: 0 if v == 128 else 255).filter(ImageFilter.MinFilter(4 * UNIT + 1))
    area = lambda im: sum(1 for v in im.get_flattened_data() if v) / UNIT ** 2
    return {"ink": round(area(ink), 2), "fill": round(area(inside), 2)}


def measure(items):
    rows = (len(items) + COLS - 1) // COLS
    cells = "".join(
        f"<div>{svg.replace('<svg', f'<svg width={CELL} height={CELL}', 1)}</div>" for _, svg in items)
    html = (f"<style>html,body{{margin:0;background:#fff;color:#000}}"
            f"svg *{{fill-opacity:1!important;stroke-opacity:1!important;opacity:1!important}}"
            f"#g{{display:grid;grid-template-columns:repeat({COLS},{CELL}px);grid-auto-rows:{CELL}px}}"
            f"#g>div{{width:{CELL}px;height:{CELL}px;overflow:hidden}}#g svg{{display:block}}</style>"
            f"<div id=g>{cells}</div>")
    page = OUT.parent / "measure.html"
    png = OUT.parent / "measure.png"
    page.write_text(html)
    subprocess.run(["google-chrome", "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=1", f"--window-size={COLS * CELL},{rows * CELL}",
                    f"--screenshot={png}", page.as_uri()], check=True, capture_output=True)
    img = Image.open(png).convert("L")
    result = {}
    for index, (key, _) in enumerate(items):
        x, y = (index % COLS) * CELL, (index // COLS) * CELL
        # Ink: anything darker than 50% grey, so antialiasing at the edge counts half.
        box = img.crop((x, y, x + CELL, y + CELL)).point(lambda v: 255 if v < 128 else 0).getbbox()
        if not box:
            continue
        x0, y0, x1, y1 = (v / UNIT for v in box)
        result[key] = {"x0": x0, "y0": y0, "x1": x1, "y1": y1, "cx": (x0 + x1) / 2, "cy": (y0 + y1) / 2,
                       "w": x1 - x0, "h": y1 - y0, **coverage(img.crop((x, y, x + CELL, y + CELL)))}
    return result


if __name__ == "__main__":
    OUT.parent.mkdir(exist_ok=True)
    items = list(variants())
    OUT.write_text(json.dumps(measure(items), indent=0))
    print(f"{len(items)} variants -> {OUT}")
