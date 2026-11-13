#!/usr/bin/env python3
"""Attribute shipped NEXT web bundles and flag regressions in tree shaking.

The input files are esbuild metafiles or the small Rolldown-compatible files emitted by
webviews/scripts/bundle-metafile.mjs.  This is deliberately CI-free: builders can hand the
report to a reviewer without making a size policy part of the pull-request gate.
"""

from __future__ import annotations

import argparse
import json
import os
import re
from collections import defaultdict
from pathlib import Path
from typing import Any


EXPORT_STAR = re.compile(r"\bexport\s*\*\s+from\s*[\"']([^\"']+)[\"']")
JS_COMMENTS_AND_STRINGS = re.compile(
    r"//[^\n]*|/\*[\s\S]*?\*/|(['\"`])(?:\\.|(?!\1)[^\\])*\1"
)


def package_name(path: str) -> str | None:
    normalized = "/" + path.replace("\\", "/").lstrip("/")
    parts = normalized.split("/node_modules/")
    if len(parts) < 2:
        return None
    tail = parts[-1].split("/")
    if not tail or not tail[0]:
        return None
    return "/".join(tail[:2]) if tail[0].startswith("@") and len(tail) > 1 else tail[0]


def package_instance(path: str) -> str | None:
    """Return the installed package root, keeping separate copies distinguishable."""
    marker = "/node_modules/"
    normalized = "/" + path.replace("\\", "/").lstrip("/")
    if marker not in normalized:
        return None
    prefix, tail = normalized.rsplit(marker, 1)
    parts = tail.split("/")
    if not parts or not parts[0]:
        return None
    count = 2 if parts[0].startswith("@") and len(parts) > 1 else 1
    return prefix + marker + "/".join(parts[:count])


def resolve_input(path: str, metafile: Path, source_root: Path | None) -> Path:
    candidate = Path(path)
    if candidate.is_absolute():
        return candidate
    # esbuild paths are relative to the process working directory, while the
    # metafile is commonly copied to a separate report directory. Callers pass
    # that working directory explicitly so source inspection remains accurate.
    return ((source_root or metafile.parent) / candidate).resolve()


def clean_javascript(text: str) -> str:
    """Remove comments and literals before checking for CommonJS syntax."""
    return JS_COMMENTS_AND_STRINGS.sub("", text)


def resolve_export(source: Path, specifier: str) -> Path | None:
    target = (source.parent / specifier).resolve()
    candidates = [target]
    if not target.suffix:
        candidates.extend(target.with_suffix(ext) for ext in (".ts", ".tsx", ".js", ".jsx", ".mjs", ".mts", ".json"))
        candidates.extend(target / f"index{ext}" for ext in (".ts", ".tsx", ".js", ".jsx", ".mjs", ".mts"))
    return next((candidate for candidate in candidates if candidate.is_file()), None)


def load_bundle(
    name: str,
    metafile: Path,
    bundle_dir: Path | None,
    source_root: Path | None = None,
) -> dict[str, Any]:
    raw = json.loads(metafile.read_text(encoding="utf-8"))
    outputs = raw.get("outputs", {})
    source_inputs = raw.get("inputs", {})
    modules: dict[str, dict[str, Any]] = {}
    output_rows = []
    for output, details in outputs.items():
        output_bytes = int(details.get("bytes", 0))
        output_rows.append({"path": output, "bytes": output_bytes, "entry": details.get("entryPoint")})
        for input_path, contribution in (details.get("inputs") or {}).items():
            row = modules.setdefault(
                input_path,
                {"path": input_path, "sourceBytes": 0, "reachableBytes": 0, "outputs": 0},
            )
            # esbuild records original source size in top-level inputs; output input
            # records contain only the contribution and may omit it entirely.
            source_record = source_inputs.get(input_path, {})
            row["sourceBytes"] = max(
                row["sourceBytes"],
                int(source_record.get("bytes", 0)),
                int(contribution.get("bytes", 0)),
            )
            row["reachableBytes"] += int(contribution.get("bytesInOutput", 0))
            row["outputs"] += 1
    rows = []
    commonjs = []
    barrels = []
    dev_inputs = []
    source_paths = {}
    source_texts = {}
    for row in modules.values():
        path = row["path"]
        source = None if "\x00" in path else resolve_input(path, metafile, source_root)
        text = ""
        try:
            if source is not None and source.is_file():
                source_size = source.stat().st_size
                row["sourceBytes"] = max(row["sourceBytes"], source_size)
                if source_size <= 2_000_000:
                    text = source.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            pass
        if source is not None:
            source_paths[path] = source
            source_texts[path] = text
        row["ratio"] = round(row["reachableBytes"] / row["sourceBytes"], 4) if row["sourceBytes"] else 0
        row["package"] = package_name(path)
        row["packageInstance"] = package_instance(path)
        row["barrel"] = len(EXPORT_STAR.findall(text))
        source_record = source_inputs.get(path, {})
        row["commonjs"] = (
            source_record.get("format") == "cjs"
            or any(edge.get("kind") == "require-call" for edge in source_record.get("imports", []))
            or path.endswith((".cjs", ".cts"))
            or any(token in clean_javascript(text) for token in ("require(", "module.exports", "exports."))
        )
        if row["barrel"]:
            barrels.append(row)
        if row["commonjs"]:
            commonjs.append(row)
        lowered = path.lower()
        if "/gallery/" in lowered or ".test." in lowered or "/fixtures/" in lowered:
            dev_inputs.append(row)
        rows.append(row)
    rows_by_source = {source_paths[row["path"]]: row for row in rows if row["path"] in source_paths}
    for row in rows:
        row["barrelReachableBytes"] = 0
        row["barrelRatio"] = 0
        if not row["barrel"] or row["path"] not in source_paths:
            continue
        source = source_paths[row["path"]]
        pending = [source]
        seen = set()
        descendants = {}
        while pending:
            current = pending.pop()
            if current in seen:
                continue
            seen.add(current)
            current_path = next((path for path, candidate in source_paths.items() if candidate == current), None)
            if current_path is None:
                continue
            current_row = rows_by_source.get(current)
            if current_row is not None:
                descendants[current] = current_row
            for specifier in EXPORT_STAR.findall(source_texts.get(current_path, "")):
                child = resolve_export(current, specifier)
                if child is not None and child in rows_by_source:
                    pending.append(child)
        row["barrelReachableBytes"] = sum(item["reachableBytes"] for item in descendants.values())
        source_bytes = sum(item["sourceBytes"] for item in descendants.values())
        row["barrelRatio"] = round(row["barrelReachableBytes"] / source_bytes, 4) if source_bytes else 0
    shipped = 0
    if bundle_dir and bundle_dir.is_dir():
        shipped = sum(p.stat().st_size for p in bundle_dir.rglob("*") if p.is_file())
    rows.sort(key=lambda item: item["reachableBytes"], reverse=True)
    return {
        "name": name,
        "metafile": str(metafile),
        "bundleDir": str(bundle_dir) if bundle_dir else None,
        "shippedBytes": shipped,
        "outputs": sorted(output_rows, key=lambda item: item["bytes"], reverse=True),
        "modules": rows,
        "barrels": sorted(barrels, key=lambda item: item["reachableBytes"], reverse=True),
        "commonjs": sorted(commonjs, key=lambda item: item["reachableBytes"], reverse=True),
        "devInputs": dev_inputs,
    }


def render_markdown(report: dict[str, Any]) -> str:
    lines = ["# NEXT web bundle attribution", "", "| Bundle | shipped bytes | reachable module bytes | outputs |", "| --- | ---: | ---: | ---: |"]
    for bundle in report["bundles"]:
        reachable = sum(row["reachableBytes"] for row in bundle["modules"])
        lines.append(f"| {bundle['name']} | {bundle['shippedBytes']:,} | {reachable:,} | {len(bundle['outputs'])} |")
    lines += ["", "## Top modules", "", "| Bundle | Module | source bytes | reachable bytes | ratio | flags |", "| --- | --- | ---: | ---: | ---: | --- |"]
    for bundle in report["bundles"]:
        for row in bundle["modules"][:20]:
            flags = []
            if row["barrel"] and row["barrelReachableBytes"] > 50 * 1024 and row["barrelRatio"] >= 0.95:
                flags.append(f"barrel({row['barrel']})")
            if row["commonjs"]:
                flags.append("commonjs")
            if "/gallery/" in row["path"].lower() or ".test." in row["path"].lower() or "/fixtures/" in row["path"].lower():
                flags.append("dev-only")
            lines.append(f"| {bundle['name']} | `{row['path']}` | {row['sourceBytes']:,} | {row['reachableBytes']:,} | {row['ratio']:.2f} | {', '.join(flags)} |")
    lines += ["", "## Duplicate packages", "", "| Package | bundles | installed copies | module paths |", "| --- | ---: | ---: | ---: |"]
    for package, entries in sorted(report["duplicates"].items()):
        lines.append(f"| `{package}` | {len(entries['bundles'])} | {len(entries['instances'])} | {len(entries['paths'])} |")
    lines += ["", "## Detector findings", ""]
    findings = report["findings"] or ["none"]
    lines.extend(f"- {finding}" for finding in findings)
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metafile", action="append", required=True, metavar="NAME=PATH")
    parser.add_argument("--bundle-dir", action="append", default=[], metavar="NAME=PATH")
    parser.add_argument(
        "--source-root",
        action="append",
        default=[],
        metavar="NAME=PATH",
        help="working directory used when the bundle's metafile recorded relative input paths",
    )
    parser.add_argument("--json", required=True, type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument(
        "--fail-on-findings",
        action="store_true",
        help="return status 1 when detector findings are present (default is report-only)",
    )
    args = parser.parse_args()
    dirs = {}
    for item in args.bundle_dir:
        name, path = item.split("=", 1)
        dirs[name] = Path(path)
    source_roots = {}
    for item in args.source_root:
        name, path = item.split("=", 1)
        source_roots[name] = Path(path)
    bundles = []
    for item in args.metafile:
        name, path = item.split("=", 1)
        bundles.append(load_bundle(name, Path(path), dirs.get(name), source_roots.get(name)))

    package_bundles: dict[str, set[str]] = defaultdict(set)
    package_paths: dict[str, set[str]] = defaultdict(set)
    package_instances: dict[str, set[str]] = defaultdict(set)
    bundle_instances: dict[tuple[str, str], set[str]] = defaultdict(set)
    findings = []
    for bundle in bundles:
        for row in bundle["modules"]:
            if row["package"]:
                package_bundles[row["package"]].add(bundle["name"])
                package_paths[row["package"]].add(row["path"])
                if row["packageInstance"]:
                    package_instances[row["package"]].add(row["packageInstance"])
                    bundle_instances[(bundle["name"], row["package"])].add(row["packageInstance"])
        for row in bundle["barrels"]:
            if row["barrel"] and row["barrelReachableBytes"] > 50 * 1024 and row["barrelRatio"] >= 0.95:
                findings.append(f"non-shaken barrel graph in {bundle['name']}: {row['path']} contributes {row['barrelReachableBytes']:,} bytes ({row['barrel']} export-star re-exports)")
        if bundle["commonjs"]:
            findings.append(f"CommonJS inputs in {bundle['name']}: {len(bundle['commonjs'])}")
        if bundle["devInputs"]:
            findings.append(f"dev-only input reached production in {bundle['name']}: {len(bundle['devInputs'])}")
    duplicates = {
        package: {"bundles": sorted(package_bundles[package]), "paths": sorted(package_paths[package])}
        for package in sorted(package_bundles)
        if len(package_bundles[package]) > 1
        or len(package_instances[package]) > 1
        or package in {"react", "react-dom"}
    }
    for package in ("react", "react-dom"):
        if package in duplicates and len(duplicates[package]["bundles"]) > 1:
            findings.append(f"duplicate {package} package across bundles: {', '.join(duplicates[package]['bundles'])}")
    for (bundle_name, package), instances in sorted(bundle_instances.items()):
        if len(instances) > 1:
            findings.append(f"duplicate {package} package within {bundle_name}: {len(instances)} installed copies")
    for package, entries in duplicates.items():
        entries["instances"] = sorted(package_instances[package])
    report = {"schema": 1, "bundles": bundles, "duplicates": duplicates, "findings": findings}
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(render_markdown(report), encoding="utf-8")
    print(render_markdown(report), end="")
    return 1 if args.fail_on_findings and findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
