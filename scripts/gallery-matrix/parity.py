#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy>=1.26", "pillow>=10"]
# ///
"""Linux vs Mac parity for the webview gallery: is a Linux render a faithful stand-in for the Mac?

Pairs two gallery-matrix runner output folders (each holds results.json and the PNGs it names) by
case id and engine, and compares each pair with shotdiff (scripts/ci/shotdiff.py, F1). The Linux
side is the gallery CI render (Chromium, Playwright WebKit on Ubuntu); the Mac side is
scripts/measure/gallery-mac-reference.sh on a fleet Mac (system Chrome, the engine CEF embeds, and
Playwright WebKit, the engine WKWebView embeds). Engines pair as chromium<->chromium and
webkit<->webkit.

Every pair gets a verdict:
  same      shotdiff passes the parity spec for its entry (parity-tolerances.json)
  differs   it does not; the reasons name SSIM, moved pixels and the box that moved
  size      the two renders have different sizes (a layout height differs, or the device pixel ratio)
  missing   a case rendered on one side only, or errored on one side
The report groups by gallery entry, worst first, so a surface where Linux is no stand-in shows at
the top; parity-tolerances.json then holds that entry's own bounds (or "mac_only": true, which says
the Linux gallery is not the verdict for it).

  uv run scripts/gallery-matrix/parity.py --linux DIR --mac DIR [--out parity.json] [--report parity.md] [--diff-dir DIR]
            [--tolerances FILE] [--strict]

Exit 0 when it ran (the report is the result); with --strict, 1 when an entry not marked mac_only
differs; 2 on an error.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "ci"))
import shotdiff  # noqa: E402  (scripts/ci/shotdiff.py)

DEFAULT_TOLERANCES = HERE / "parity-tolerances.json"


def load_results(folder: Path) -> dict[tuple[str, str], dict[str, Any]]:
    path = folder / "results.json"
    try:
        rows = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {path}: {error}") from error
    if isinstance(rows, dict):
        rows = rows.get("results", [])
    return {(str(row["id"]), str(row["engine"])): row for row in rows if "id" in row and "engine" in row}


def entry_of(row: dict[str, Any]) -> str:
    params = row.get("params") or {}
    return str(params.get("entry") or row["id"].split("--")[0])


def spec_for(entry: str, tolerances: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    spec = dict(tolerances.get("default", {}))
    own = tolerances.get("entries", {}).get(entry, {})
    mac_only = bool(own.get("mac_only"))
    spec.update({key: value for key, value in own.items() if key not in ("mac_only", "why")})
    return spec, mac_only


def compare_pair(linux_dir: Path, mac_dir: Path, linux: dict[str, Any] | None, mac: dict[str, Any] | None,
                 spec: dict[str, Any], diff_out: Path | None) -> dict[str, Any]:
    for side, row in (("linux", linux), ("mac", mac)):
        if row is None:
            return {"verdict": "missing", "reasons": [f"no {side} render"]}
        if row.get("error") or not row.get("screenshot"):
            return {"verdict": "missing", "reasons": [f"{side} render failed: {str(row.get('error'))[:200]}"]}
    linux_png, mac_png = linux_dir / linux["screenshot"], mac_dir / mac["screenshot"]
    for side, png in (("linux", linux_png), ("mac", mac_png)):
        if not png.is_file():
            return {"verdict": "missing", "reasons": [f"{side} screenshot {png.name} absent"]}
    # The Mac is the reference ("golden"); the Linux render is the shot judged against it.
    result = shotdiff.compare(mac_png, linux_png, spec, diff_out)
    verdict = "same" if result.ok else ("size" if result.ssim is None else "differs")
    return {"verdict": verdict, **result.to_json()}


def build(linux_dir: Path, mac_dir: Path, tolerances: dict[str, Any], diff_dir: Path | None) -> dict[str, Any]:
    linux_rows, mac_rows = load_results(linux_dir), load_results(mac_dir)
    keys = sorted(set(linux_rows) | set(mac_rows))
    if diff_dir:
        diff_dir.mkdir(parents=True, exist_ok=True)
    pairs = []
    for case_id, engine in keys:
        linux, mac = linux_rows.get((case_id, engine)), mac_rows.get((case_id, engine))
        entry = entry_of(linux or mac or {"id": case_id})
        spec, mac_only = spec_for(entry, tolerances)
        diff_out = diff_dir / f"{case_id}-{engine}-parity.png" if diff_dir else None
        pair = compare_pair(linux_dir, mac_dir, linux, mac, spec, diff_out)
        pairs.append({"id": case_id, "engine": engine, "entry": entry, "mac_only": mac_only, **pair})
    entries: dict[str, dict[str, Any]] = defaultdict(lambda: {"same": 0, "differs": 0, "size": 0, "missing": 0,
                                                            "min_ssim": None, "max_changed": 0.0})
    for pair in pairs:
        summary = entries[pair["entry"]]
        summary[pair["verdict"]] += 1
        summary["mac_only"] = pair["mac_only"]
        if pair.get("ssim") is not None:
            summary["min_ssim"] = pair["ssim"] if summary["min_ssim"] is None else min(summary["min_ssim"], pair["ssim"])
        summary["max_changed"] = max(summary["max_changed"], float(pair.get("changed") or 0.0))
    totals = {verdict: sum(1 for p in pairs if p["verdict"] == verdict) for verdict in ("same", "differs", "size", "missing")}
    return {"schema": 1, "totals": totals, "entries": dict(entries), "pairs": pairs}


def markdown(report: dict[str, Any]) -> str:
    totals = report["totals"]
    lines = ["## Webview gallery: Linux vs Mac parity", "",
             f"{totals['same']} same, {totals['differs']} differ, {totals['size']} differ in size, "
             f"{totals['missing']} missing on one side.", "",
             "| entry | same | differs | size | missing | min SSIM | max moved | mac only |",
             "|---|---:|---:|---:|---:|---:|---:|---|"]

    def badness(item: tuple[str, dict[str, Any]]) -> tuple[int, float]:
        summary = item[1]
        return (-(summary["differs"] + summary["size"] + summary["missing"]), summary["min_ssim"] or 0.0)

    for entry, s in sorted(report["entries"].items(), key=badness):
        ssim = f"{s['min_ssim']:.4f}" if s["min_ssim"] is not None else "-"
        lines.append(f"| {entry} | {s['same']} | {s['differs']} | {s['size']} | {s['missing']} | {ssim} | "
                     f"{s['max_changed']:.2%} | {'yes' if s.get('mac_only') else ''} |")
    worst = [p for p in report["pairs"] if p["verdict"] != "same"][:40]
    if worst:
        lines += ["", "### Pairs that differ (first 40)", ""]
        for pair in worst:
            lines.append(f"- `{pair['id']}` {pair['engine']}: {pair['verdict']}; {'; '.join(pair.get('reasons') or [])}")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--linux", type=Path, required=True, help="gallery-matrix output folder rendered on Linux")
    parser.add_argument("--mac", type=Path, required=True, help="gallery-matrix output folder rendered on a Mac")
    parser.add_argument("--tolerances", type=Path, default=DEFAULT_TOLERANCES)
    parser.add_argument("--out", type=Path, default=Path("parity.json"))
    parser.add_argument("--report", type=Path, help="write (append) the markdown summary here")
    parser.add_argument("--diff-dir", type=Path)
    parser.add_argument("--strict", action="store_true", help="exit 1 when an entry not marked mac_only differs")
    args = parser.parse_args(argv)
    try:
        tolerances = json.loads(args.tolerances.read_text())
        report = build(args.linux, args.mac, tolerances, args.diff_dir)
    except (OSError, ValueError, shotdiff.ShotdiffError) as error:
        print(f"parity: {error}", file=sys.stderr)
        return 2
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    text = markdown(report)
    if args.report:
        with args.report.open("a") as handle:
            handle.write(text)
    print(text)
    bad = [p for p in report["pairs"] if p["verdict"] != "same" and not p["mac_only"]]
    return 1 if args.strict and bad else 0


if __name__ == "__main__":
    sys.exit(main())
