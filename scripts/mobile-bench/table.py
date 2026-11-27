#!/usr/bin/env python3
"""Side-by-side timing tables from measured clips.

    table.py DIR... [--flow FLOW] [--links BASE] [--json]

Every DIR is searched for */result.json (measure.py's output; meta.json
"unsupported" clips count too). Prints one Markdown table per flow, one row
per app, in flows.json order. A bold cell is worse than the best app's by more
than 10% and two frames (dropped: any more); --json lists, per flow, the apps
with a bold response or settle. --links
BASE turns each app's cell into a link to BASE/<path of its clip>.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(dirs: list[Path]) -> list[dict]:
    rows = []
    for d in dirs:
        for meta_path in sorted(d.rglob("meta.json")):
            res_path = meta_path.with_name("result.json")
            meta = json.loads(meta_path.read_text())
            if meta.get("unsupported"):
                row = {"app": meta.get("app"), "flow": meta.get("flow"), "unsupported": meta["unsupported"],
                       "source": meta.get("source")}
            elif res_path.exists():
                row = json.loads(res_path.read_text())
            else:
                continue
            row["_clip"] = str(meta_path.with_name("clip.mp4"))
            rows.append(row)
    return rows


def ms(v) -> str:
    return "–" if v is None else f"{v:.0f}"


def worse(row: dict, best: dict, key: str) -> bool:
    """row's key is worse than the best app's by more than 10% and two frames (dropped: any more)."""
    a, b = row.get(key), best.get(key)
    if a is None or b is None:
        return False
    if key == "dropped":
        return a > b
    frame = row.get("frame_period_ms") or 8.3
    return a > b * 1.10 and a - b > 2 * frame


def best_values(rows: list[dict]) -> dict:
    out = {}
    for key in ("response_ms", "settle_ms", "dropped"):
        vals = [r[key] for r in rows if r.get(key) is not None]
        if vals:
            out[key] = min(vals)
    return out


def tables(rows: list[dict], flow_filter: str | None, links: str | None, root: Path | None) -> tuple[str, dict]:
    order = [f["id"] for f in json.loads((HERE / "flows.json").read_text())["flows"]]
    titles = {f["id"]: f["title"] for f in json.loads((HERE / "flows.json").read_text())["flows"]}
    by_flow: dict[str, list[dict]] = {}
    for r in rows:
        by_flow.setdefault(r["flow"], []).append(r)
    out, verdict = [], {}
    for flow in order:
        if flow_filter and flow != flow_filter or flow not in by_flow:
            continue
        group = sorted(by_flow[flow], key=lambda r: (r.get("response_ms") is None, r.get("response_ms") or 0))
        best = best_values([r for r in group if not r.get("unsupported")])
        out.append(f"### {titles[flow]} (`{flow}`)\n")
        out.append("| App | Response ms | Settle ms | Motion ms | Dropped | Worst gap ms | Jumps | Bursts | Spring (response s / damping) | Overshoot | fps | Source |")
        out.append("|---|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---|")
        for r in group:
            app = r.get("app") or "?"
            if links and root:
                app = f"[{app}]({links.rstrip('/')}/{os.path.relpath(r['_clip'], root)})"
            if r.get("unsupported"):
                out.append(f"| {app} | not in the app: {r['unsupported']} |  |  |  |  |  |  |  |  |  | {r.get('source') or ''} |")
                continue
            c = r.get("curve") or {}
            spring = f"{c['spring_response_s']} / {c['spring_damping_fraction']}" if c else "–"
            bad = {k for k in ("response_ms", "settle_ms", "dropped") if worse(r, best, k)}
            if bad & {"response_ms", "settle_ms"}:
                verdict.setdefault(flow, []).append(r.get("app"))

            def cell(key: str, text: str) -> str:
                return f"**{text}**" if key in bad else text

            out.append(
                f"| {app} | {cell('response_ms', ms(r.get('response_ms')))} | {cell('settle_ms', ms(r.get('settle_ms')))} | "
                f"{ms(r.get('motion_ms'))} | {cell('dropped', str(r.get('dropped', '–')))} | {ms(r.get('worst_gap_ms'))} | {r.get('jumps') if r.get('jumps') is not None else '–'} | "
                f"{r.get('bursts', '–')} | {spring} | {str(c.get('overshoot_pct')) + '%' if c else '–'} | "
                f"{r.get('fps_nominal', '–')} | {r.get('source') or ''} |")
        out.append("")
    return "\n".join(out), verdict


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dirs", nargs="+", type=Path)
    ap.add_argument("--flow")
    ap.add_argument("--links", help="URL or path prefix for clip links, relative to --root")
    ap.add_argument("--root", type=Path, help="the directory --links is relative to")
    ap.add_argument("--json", action="store_true", help="print {flow: [slower apps]} instead")
    args = ap.parse_args()
    text, verdict = tables(load(args.dirs), args.flow, args.links, args.root)
    print(json.dumps(verdict) if args.json else text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
