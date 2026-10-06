"""Runs row_probe.js against gallery.html in both densities and prints slot, gap, icon size and offset stats.

Usage: python3 row_probe.py [label]   (writes ../measure/rows-<label>.json)
"""
import html
import json
import re
import statistics
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
label = sys.argv[1] if len(sys.argv) > 1 else "now"
probe = (ROOT / "src" / "row_probe.js").read_text()
result = {}
for density in ("regular", "compact"):
    pre = "<script>document.documentElement.dataset.theme='dark'" + (";document.documentElement.dataset.density='compact'" if density == "compact" else "") + "</script>"
    page = Path(f"/tmp/rowprobe-{density}.html")
    page.write_text(pre + (ROOT / "gallery.html").read_text() + probe)
    dom = subprocess.run(["google-chrome", "--headless=new", "--disable-gpu", "--window-size=1400,900", "--virtual-time-budget=4000",
                          "--dump-dom", page.as_uri()], capture_output=True, text=True).stdout
    rows = json.loads(html.unescape(re.search(r'<pre id="probe">(.*?)</pre>', dom, re.S).group(1)))
    ink = json.loads((ROOT / "measure" / "ink-after.json").read_text())
    for r in rows:
        box = ink.get(f"{r['name']}|{r['variant']}") or ink.get(f"{r['name']}|line")
        x0, y0, w, _ = r["vb"]
        scale = r["sw"] / w
        r["ink"] = round(max(box["w"], box["h"]) * scale, 1)
        r["vgap"] = round(r["lab"] - (r["sx"] + (box["x1"] - x0) * scale), 1)
        r["pad"] = round((box["x0"] - x0) * scale, 1)
        r["inkdy"] = round(r["sy"] + (box["cy"] - y0) * scale - r["capMid"], 2)
    result[density] = rows
    print(f"== {density}: {len(rows)} rows")
    for key in ("slot", "gap", "icon", "pad", "vgap", "ink"):
        c = Counter(r[key] for r in rows)
        print(f"  {key:5s} min {min(c)} max {max(c)} median {statistics.median(r[key] for r in rows)}  common {c.most_common(3)}")
    dys = [r["inkdy"] for r in rows]
    print(f"  font {Counter(r['font'] for r in rows).most_common(2)}  icon/font {statistics.median(r['icon'] / r['font'] for r in rows):.2f}")
    print(f"  ink/font {statistics.median(r['ink'] / r['font'] for r in rows):.2f}  visible gap median {statistics.median(r['vgap'] for r in rows)} spread {min(r['vgap'] for r in rows)}..{max(r['vgap'] for r in rows)}")
    print(f"  ink dy (ink center minus cap middle, px) median {statistics.median(dys):+.2f}  worst {max(dys, key=abs):+.2f}  |dy|>0.75: {sum(abs(d) > 0.75 for d in dys)}")
(ROOT / "measure" / f"rows-{label}.json").write_text(json.dumps(result))
