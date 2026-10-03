"""Coverage trim: glyphs whose silhouette fills most of the box, or whose line ink is heavy, read bigger
than open glyphs at the same extent (Leo, 2026-10-02). Trims them 6 to 10 percent about their center.

Usage: python3 coverage_trim.py ink.json   (measurements from measure.py, including fill and ink areas)
Applies once per drawing: trims are recorded in ../measure/coverage-trims.json and never reapplied.
"""
import json
import sys
from pathlib import Path

from optical import transform_svg, DOTS

ROOT = Path(__file__).resolve().parent.parent
LIVE = 18 * 18            # the 3..21 live area, square units
THRESHOLD, FULL = 0.90, 1.05
MIN_TRIM, MAX_TRIM = 0.06, 0.10
# Leo named the AI sparkle as reading too big. Its thin points reach the box edges with little area, so
# coverage misses it; it takes the minimum trim by name.
BY_NAME = {"task.ai": MIN_TRIM}


def score(box):
    """Silhouette fill of the live area, or the line ink plus 0.3 for filled glyphs (a disc, an octagon)."""
    return max(box["fill"] / LIVE, box["ink"] / LIVE + 0.3)


def trim_for(name, box):
    if DOTS.search(name):
        return 0.0
    if name in BY_NAME:
        return BY_NAME[name]
    s = score(box)
    if s < THRESHOLD:
        return 0.0
    return round(min(MAX_TRIM, MIN_TRIM + (s - THRESHOLD) / (FULL - THRESHOLD) * (MAX_TRIM - MIN_TRIM)), 3)


def main():
    ink = json.loads(Path(sys.argv[1]).read_text())
    record_path = ROOT / "measure" / "coverage-trims.json"
    record = json.loads(record_path.read_text()) if record_path.exists() else {}
    for path in sorted((ROOT / "icons").glob("*.json")):
        data = json.loads(path.read_text())
        for icon in data["icons"]:
            targets = [(icon["name"], f"{icon['name']}|line", icon, ("line", "solid", "cat"))]
            targets += [(f"{icon['name']} alt{i}", f"{icon['name']}|alt{i}.line", alt, ("line", "solid"))
                        for i, alt in enumerate(icon.get("alts") or [])]
            for key, measure_key, holder, variants in targets:
                box = ink.get(measure_key)
                if key in record or not box:
                    continue
                trim = trim_for(icon["name"], box)
                if not trim:
                    continue
                s = 1 - trim
                ox, oy = box["cx"] - s * box["cx"], box["cy"] - s * box["cy"]
                for k in variants:
                    if holder.get(k):
                        holder[k] = transform_svg(holder[k], s, ox, oy)
                record[key] = {"trim": trim, "score": round(score(box), 3)}
        path.write_text(json.dumps(data, indent=1, ensure_ascii=False))
    record_path.write_text(json.dumps(record, indent=1, sort_keys=True))
    for key, r in sorted(record.items(), key=lambda kv: -kv[1]["trim"]):
        print(f"{key:40s} -{r['trim'] * 100:.0f}%  score {r['score']:.2f}")
    print(f"{len(record)} trimmed")


if __name__ == "__main__":
    main()
