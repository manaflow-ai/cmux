#!/usr/bin/env python3
"""Measures the cmux NEXT app bundle and checks it against a size budget.

    bundle-size.py report APP [--dmg DMG] [--compressed] [--json OUT]
    bundle-size.py check  APP --budget BUDGET.json --variant arm64 [--dmg DMG]

`report` prints the bundle by component: bytes on disk (file sizes, symlinks
not followed, so the CEF framework's top-level links count once) and, with
--compressed, an xz -6 estimate of what each component adds to the LZMA DMG.

`check` fails (exit 1) and names every rule that is broken:
  - a path that matches one of the variant's `forbidden` globs (files that a
    feature never reads, e.g. the x86_64 V8 snapshot in an arm64 app);
  - a component over its `components` cap;
  - the whole app over `app_max_bytes`, or the DMG over `dmg_max_bytes`.

The budget is a ratchet: when a cut lands, lower its caps to the new size
plus a little headroom, so the size never grows back unnoticed. See
plans/cmux-next/bundle-size-DESIGN.md.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import lzma
import os
import sys
from pathlib import Path

MIB = 1024 * 1024

# Components the report lists on their own; everything else in a listed
# parent folder is grouped under that parent. Paths are relative to the .app.
DEFAULT_COMPONENT_ROOTS = (
    "Contents/Frameworks",
    "Contents/Resources",
    "Contents/MacOS",
    "Contents/Library",
    "Contents/PlugIns",
    "Contents/Helpers",
    "Contents/XPCServices",
)


def walk_files(root: Path):
    """Yields (relative posix path, size) for every regular file under root."""
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames.sort()
        for name in sorted(filenames):
            p = Path(dirpath) / name
            if p.is_symlink() or not p.is_file():
                continue
            yield p.relative_to(root).as_posix(), p.stat().st_size


def all_paths(root: Path):
    """Every file, directory and symlink under root, relative, posix."""
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            yield (Path(dirpath) / name).relative_to(root).as_posix()


def component_of(rel: str, roots=DEFAULT_COMPONENT_ROOTS) -> str:
    """The component a file belongs to: <root>/<first child>, e.g.
    Contents/Frameworks/Chromium Embedded Framework.framework."""
    for r in roots:
        if rel == r or rel.startswith(r + "/"):
            rest = rel[len(r) + 1:]
            first = rest.split("/", 1)[0] if rest else ""
            return f"{r}/{first}" if first else r
    return rel.split("/", 2)[0] + "/" + (rel.split("/", 2)[1] if rel.count("/") else "")


def measure(app: Path) -> dict:
    """Sizes of the app by component, plus the file list."""
    if not (app / "Contents").is_dir():
        raise SystemExit(f"bundle-size: {app} is not an app bundle (no Contents/)")
    comps: dict[str, int] = {}
    files: dict[str, int] = {}
    for rel, size in walk_files(app):
        files[rel] = size
        c = component_of(rel)
        comps[c] = comps.get(c, 0) + size
    return {"app_bytes": sum(files.values()), "components": comps, "files": files}


def compressed_size(app: Path, rels: list[str]) -> int:
    """xz -6 size of the concatenated files: an estimate of DMG bytes."""
    comp = lzma.LZMACompressor(preset=6)
    n = 0
    for rel in rels:
        with open(app / rel, "rb") as f:
            while chunk := f.read(4 * MIB):
                n += len(comp.compress(chunk))
    return n + len(comp.flush())


def matches(rel: str, pattern: str) -> bool:
    """fnmatch where `**/` may also match nothing (top level)."""
    if fnmatch.fnmatchcase(rel, pattern):
        return True
    if pattern.startswith("**/"):
        return fnmatch.fnmatchcase(rel, pattern[3:])
    return False


def check(app: Path, budget: dict, variant: str, dmg: Path | None) -> list[str]:
    """The broken rules, empty when the app fits its budget."""
    try:
        rules = budget["variants"][variant]
    except KeyError:
        return [f"budget has no variant {variant!r}"]
    m = measure(app)
    problems: list[str] = []
    for pattern in rules.get("forbidden", []):
        hits = sorted(p for p in all_paths(app) if matches(p, pattern))
        for hit in hits[:5]:
            problems.append(f"forbidden: {hit} (rule {pattern})")
        if len(hits) > 5:
            problems.append(f"forbidden: {len(hits) - 5} more paths match {pattern}")
    for comp, cap in sorted(rules.get("components", {}).items()):
        size = m["components"].get(comp, 0)
        if size > cap:
            problems.append(
                f"component over budget: {comp} is {size} bytes ({size / MIB:.1f} MiB), cap {cap} ({cap / MIB:.1f} MiB)"
            )
    cap = rules.get("app_max_bytes")
    if cap is not None and m["app_bytes"] > cap:
        problems.append(f"app over budget: {m['app_bytes']} bytes ({m['app_bytes'] / MIB:.1f} MiB), cap {cap} ({cap / MIB:.1f} MiB)")
    cap = rules.get("dmg_max_bytes")
    if cap is not None:
        if dmg is None:
            problems.append("dmg_max_bytes is set but no --dmg was given")
        else:
            size = dmg.stat().st_size
            if size > cap:
                problems.append(f"DMG over budget: {dmg.name} is {size} bytes ({size / MIB:.1f} MiB), cap {cap} ({cap / MIB:.1f} MiB)")
    return problems


def report(app: Path, dmg: Path | None, compressed: bool) -> dict:
    m = measure(app)
    rows = []
    by_comp: dict[str, list[str]] = {}
    for rel in m["files"]:
        by_comp.setdefault(component_of(rel), []).append(rel)
    for comp, size in sorted(m["components"].items(), key=lambda kv: -kv[1]):
        row = {"component": comp, "bytes": size}
        if compressed:
            row["xz_bytes"] = compressed_size(app, by_comp[comp])
        rows.append(row)
    out = {"app": app.name, "app_bytes": m["app_bytes"], "components": rows}
    if dmg is not None:
        out["dmg"] = dmg.name
        out["dmg_bytes"] = dmg.stat().st_size
    return out


def print_report(r: dict) -> None:
    print(f"{r['app']}: {r['app_bytes'] / MIB:.1f} MiB on disk")
    if "dmg_bytes" in r:
        print(f"{r['dmg']}: {r['dmg_bytes'] / MIB:.1f} MiB")
    for row in r["components"]:
        if row["bytes"] < 512 * 1024:
            continue
        xz = f"  xz {row['xz_bytes'] / MIB:7.1f} MiB" if "xz_bytes" in row else ""
        print(f"  {row['bytes'] / MIB:8.1f} MiB{xz}  {row['component']}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("report")
    r.add_argument("app", type=Path)
    r.add_argument("--dmg", type=Path)
    r.add_argument("--compressed", action="store_true")
    r.add_argument("--json", type=Path)
    c = sub.add_parser("check")
    c.add_argument("app", type=Path)
    c.add_argument("--budget", type=Path, required=True)
    c.add_argument("--variant", required=True)
    c.add_argument("--dmg", type=Path)
    a = ap.parse_args(argv)
    if a.cmd == "report":
        out = report(a.app, a.dmg, a.compressed)
        print_report(out)
        if a.json:
            a.json.write_text(json.dumps(out, indent=2) + "\n")
        return 0
    budget = json.loads(a.budget.read_text())
    problems = check(a.app, budget, a.variant, a.dmg)
    for p in problems:
        print(f"bundle-size: {p}", file=sys.stderr)
    if problems:
        print("bundle-size: over budget; see plans/cmux-next/bundle-size-DESIGN.md", file=sys.stderr)
        return 1
    print(f"bundle-size: {a.app.name} fits the {a.variant} budget")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
