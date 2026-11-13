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


EXPORT_STAR = re.compile(r"(?:^|[;\n\r}])\s*export\s*\*\s+from\s*[\"']([^\"']+)[\"']")
JS_COMMENTS = re.compile(r"//[^\n]*|/\*[\s\S]*?\*/")


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


def clean_comments(text: str) -> str:
    """Remove comments while preserving export specifier strings."""
    return JS_COMMENTS.sub("", text)


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
    tool = raw.get("tool")
    is_rolldown = tool == "rolldown"
    modules: dict[str, dict[str, Any]] = {}
    output_rows = []
    for output, details in outputs.items():
        output_bytes = int(details.get("bytes", 0))
        output_rows.append({"path": output, "bytes": output_bytes, "entry": details.get("entryPoint")})
        for input_path, contribution in (details.get("inputs") or {}).items():
            row = modules.setdefault(
                input_path,
                {
                    "path": input_path,
                    "sourceBytes": 0,
                    "attributionValue": 0,
                    "renderedLength": 0,
                    "emittedBytes": 0,
                    "unknownValue": 0,
                    "outputs": 0,
                    "attributionMetric": None,
                },
            )
            # esbuild records original source size in top-level inputs; output input
            # records contain only the contribution and may omit it entirely.
            source_record = source_inputs.get(input_path, {})
            row["sourceBytes"] = max(
                row["sourceBytes"],
                int(source_record.get("sourceBytes", source_record.get("bytes", 0)) or 0),
                int(contribution.get("bytes", 0) or 0) if not is_rolldown else 0,
            )
            metric = contribution.get("metric")
            if metric is None and is_rolldown:
                # Schema 1 Rolldown reports only had bytesInOutput, which is
                # rendered pre-minification. Do not silently call it emitted.
                metric = "unknown"
            elif metric is None:
                metric = "emitted"
            if metric == "rolldown-rendered-length" and contribution.get("renderedLength") is None:
                metric = "unknown"
            row["attributionMetric"] = metric if row["attributionMetric"] in (None, metric) else "mixed"
            contribution_bytes = int(contribution.get("bytesInOutput", 0) or 0)
            if metric == "rolldown-rendered-length":
                rendered = int(contribution["renderedLength"])
                row["renderedLength"] += rendered
                row["attributionValue"] += rendered
            elif metric == "emitted":
                row["emittedBytes"] += contribution_bytes
                row["attributionValue"] += contribution_bytes
            else:
                row["unknownValue"] += contribution_bytes
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
                # Captured builder sizes belong to the measured revision. A source
                # checkout used for inspection may since have changed.
                if not row["sourceBytes"]:
                    row["sourceBytes"] = source_size
                if source_size <= 2_000_000:
                    text = source.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            pass
        if source is not None:
            source_paths[path] = source
            source_texts[path] = text
        row["ratio"] = round(row["attributionValue"] / row["sourceBytes"], 4) if row["sourceBytes"] and row["attributionMetric"] == "emitted" else 0
        row["reachableBytes"] = row["emittedBytes"] if row["attributionMetric"] == "emitted" else None
        row["package"] = package_name(path)
        # esbuild reports paths relative to its working directory; Rolldown
        # reports absolute paths. Resolve both before counting installed roots,
        # while keeping nested node_modules (actual separate copies) distinct.
        row["packageInstance"] = package_instance(str(source) if source is not None else path)
        row["barrel"] = len(EXPORT_STAR.findall(clean_comments(text)))
        source_record = source_inputs.get(path, {})
        row["commonjs"] = (
            source_record.get("format") == "cjs"
            or any(edge.get("kind") == "require-call" for edge in source_record.get("imports", []))
            or path.endswith((".cjs", ".cts"))
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
            for specifier in EXPORT_STAR.findall(clean_comments(source_texts.get(current_path, ""))):
                child = resolve_export(current, specifier)
                if child is not None and child in rows_by_source:
                    pending.append(child)
        if any(item["attributionMetric"] != "emitted" for item in descendants.values()):
            continue
        row["barrelReachableBytes"] = sum(item["emittedBytes"] for item in descendants.values())
        source_bytes = sum(item["sourceBytes"] for item in descendants.values())
        row["barrelRatio"] = round(row["barrelReachableBytes"] / source_bytes, 4) if source_bytes else 0
    shipped = None
    if bundle_dir and bundle_dir.is_dir():
        shipped = sum(p.stat().st_size for p in bundle_dir.rglob("*") if p.is_file())
    rows.sort(key=lambda item: item["attributionValue"], reverse=True)
    metrics = {row["attributionMetric"] for row in rows if row["attributionMetric"] is not None}
    attribution_metric = next(iter(metrics)) if len(metrics) == 1 else ("mixed" if metrics else "unknown")
    reachable = sum(row["attributionValue"] for row in rows) if attribution_metric not in ("unknown", "mixed") else None
    omitted = None
    if "inputs" in raw and not is_rolldown:
        omitted = sorted(
            ({"path": name, "sourceBytes": int(details.get("bytes", 0))}
             for name, details in source_inputs.items() if name not in modules),
            key=lambda item: item["sourceBytes"], reverse=True,
        )
    return {
        "name": name,
        "metafile": str(metafile),
        "sourceRoot": str(source_root) if source_root else None,
        "bundleDir": str(bundle_dir) if bundle_dir else None,
        "shippedBytes": shipped,
        "attributionMetric": attribution_metric,
        "attributionValue": reachable,
        "reachableBytes": reachable if attribution_metric == "emitted" else None,
        "omittedInputs": omitted,
        "outputs": sorted(output_rows, key=lambda item: item["bytes"], reverse=True),
        "modules": rows,
        "barrels": sorted(barrels, key=lambda item: item["attributionValue"], reverse=True),
        "commonjs": sorted(commonjs, key=lambda item: item["attributionValue"], reverse=True),
        "devInputs": dev_inputs,
    }


def render_markdown(report: dict[str, Any]) -> str:
    lines = ["# NEXT web bundle attribution", "", "| Bundle | shipped bytes | module attribution | metric | outputs |", "| --- | ---: | ---: | --- | ---: |"]
    for bundle in report["bundles"]:
        reachable = bundle["attributionValue"]
        value = f"{reachable:,}" if reachable is not None else "unknown"
        shipped = f"{bundle['shippedBytes']:,}" if bundle["shippedBytes"] is not None else "unknown"
        lines.append(f"| {bundle['name']} | {shipped} | {value} | {bundle['attributionMetric']} | {len(bundle['outputs'])} |")
    lines += [
        "", "Shipped bytes come from the output directory. Module attribution describes the bundler graph;",
        "Rolldown pre-minification lengths are not emitted bytes. Postprocessed files (including Pages CSS)",
        "can differ from that graph. Do not sum unlike metrics or treat attribution as a savings estimate.",
        "CommonJS findings use bundler format/import metadata or explicit .cjs/.cts extensions;",
        "metadata without that evidence is not proof that a module is ESM. Source text is not parsed for this check.",
        "", "## Top modules", "", "| Bundle | Module | source bytes | attribution | metric | ratio | flags |",
        "| --- | --- | ---: | ---: | --- | ---: | --- |",
    ]
    for bundle in report["bundles"]:
        for row in bundle["modules"][:20]:
            flags = []
            if row["barrel"] and row["barrelReachableBytes"] > 50 * 1024 and row["barrelRatio"] >= 0.95:
                flags.append(f"barrel({row['barrel']})")
            if row["commonjs"]:
                flags.append("commonjs")
            if "/gallery/" in row["path"].lower() or ".test." in row["path"].lower() or "/fixtures/" in row["path"].lower():
                flags.append("dev-only")
            known = row["attributionMetric"] not in ("unknown", "mixed")
            value = f"{row['attributionValue']:,}" if known else "unknown"
            ratio = f"{row['ratio']:.2f}" if row["attributionMetric"] == "emitted" else "unknown"
            lines.append(f"| {bundle['name']} | `{row['path']}` | {row['sourceBytes']:,} | {value} | {row['attributionMetric']} | {ratio} | {', '.join(flags)} |")
    lines += [
        "", "## Resolved inputs omitted from outputs", "",
        "These resolved source modules contribute no output. This demonstrates elimination in this graph;",
        "their source sizes are not shipped savings. Missing resolved-input metadata is unknown.",
        "", "| Bundle | omitted inputs | source bytes (not savings) |", "| --- | ---: | ---: |",
    ]
    for bundle in report["bundles"]:
        omitted = bundle["omittedInputs"]
        count = str(len(omitted)) if omitted is not None else "unknown"
        size = f"{sum(item['sourceBytes'] for item in omitted):,}" if omitted is not None else "unknown"
        lines.append(f"| {bundle['name']} | {count} | {size} |")
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
            if row["package"] and (row["attributionValue"] > 0 or row["attributionMetric"] in ("unknown", "mixed")):
                package_bundles[row["package"]].add(bundle["name"])
                package_paths[row["package"]].add(row["path"])
                if row["packageInstance"]:
                    package_instances[row["package"]].add(row["packageInstance"])
                    bundle_instances[(bundle["name"], row["package"])].add(row["packageInstance"])
        for row in bundle["barrels"]:
            if row["barrel"] and row["barrelReachableBytes"] > 50 * 1024 and row["barrelRatio"] >= 0.95:
                findings.append(f"suspicious barrel retention in {bundle['name']}: {row['path']} contributes {row['barrelReachableBytes']:,} attribution bytes ({row['barrel']} export-star re-exports; heuristic, not proof of failed shaking)")
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
    report = {"schema": 2, "bundles": bundles, "duplicates": duplicates, "findings": findings}
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(render_markdown(report), encoding="utf-8")
    print(render_markdown(report), end="")
    return 1 if args.fail_on_findings and findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
