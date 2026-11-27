"""Bakes a wrapping <g transform='scale(1.5)'> (16-grid drawings at stroke 1.25, drawn 1.875) into the geometry at stroke 1.5 (Solid 2)."""
import importlib.util
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("optical", root / "tools/optical.py")
o = importlib.util.module_from_spec(spec)
spec.loader.exec_module(o)
WRAP = re.compile(r"<g transform='scale\(1\.5\)'>(.*)</g></svg>$", re.S)


def bake(svg, width):
    svg = svg.replace('"', "'")
    m = WRAP.search(svg)
    if not m or "stroke-width='1.25'" not in svg[: m.start()]:
        return None
    inner = re.sub(r">\s+<", "><", m.group(1)).strip()
    if "stroke-width" in inner or "transform" in inner:
        return None
    head = svg[: m.start()].replace("stroke-width='1.25'", f"stroke-width='{width}'")
    return o.transform_svg(head + inner + "</svg>", 1.5, 0, 0)


for path in sorted((root / "source").glob("*.json")):
    if path.name == "chromium.json":
        continue
    raw = path.read_text()
    data = json.loads(raw)
    n = 0
    for icon in data["icons"]:
        for k, w in (("line", "1.5"), ("solid", "2")):
            v = icon.get(k)
            if v and "scale(1.5)" in v:
                new = bake(v, w)
                if new is None:
                    print("LEFT", path.name, icon["name"], k)
                    continue
                icon[k] = new
                n += 1
    if n:
        path.write_text(json.dumps(data, indent=1, ensure_ascii=False) + ("\n" if raw.endswith("\n") else ""))
        print(path.name, n)
