#!/usr/bin/env python3
"""Capture path-selected tours for a base app and a head app.

This is the shared entry point for PR media and incremental DEV builds. The
caller supplies already-built tagged app bundles. It never builds, installs,
or launches an untagged app. Output contains adjacent ``*-before`` and
``*-after`` tour folders, each with its own manifest and clip frames.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Any

from path_map import map_paths


ROOT = Path(__file__).resolve().parents[3]
TOURS = ROOT / "scripts/cmux-next/media/tours"


def tour_file(name: str) -> Path:
    """The tour file for a tour name path_map selected: tours/<name>.json."""
    return TOURS / f"{name}.json"


def read_paths(args: argparse.Namespace) -> list[str]:
    paths = list(args.paths)
    if args.paths_file:
        paths.extend(args.paths_file.read_text(encoding="utf-8").splitlines())
    return paths


def write_failure(directory: Path, title: str, detail: str, variant: str) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "manifest.json").write_text(
        json.dumps({
            "name": directory.name,
            "title": f"{title} ({variant})",
            "variant": variant,
            "comparison": directory.name.removesuffix(f"-{variant}"),
            "steps": [],
            "frames": [],
            "error": detail,
            "capture_mode": "unavailable",
        }, indent=2) + "\n",
        encoding="utf-8",
    )


def run_variant(
    *,
    app: Path | None,
    variant: str,
    tours: list[str],
    out: Path,
    fresh_state: bool,
) -> int:
    raw = out / f".{variant}-raw"
    raw.mkdir(parents=True, exist_ok=True)
    if app is None or not app.is_dir():
        for name in tours:
            write_failure(out / f"{name}-{variant}", name.replace("-", " ").title(),
                          f"{variant} tagged app is unavailable", variant)
        return 1

    command = [sys.executable, str(Path(__file__).with_name("tour.py")),
               "--app", str(app), "--out", str(raw)]
    if fresh_state:
        command.append("--fresh-state")
    command.extend(str(tour_file(name)) for name in tours)
    completed = subprocess.run(command, check=False)
    status = completed.returncode
    for name in tours:
        source = raw / name
        target = out / f"{name}-{variant}"
        if target.exists():
            shutil.rmtree(target)
        if not source.is_dir():
            write_failure(target, name.replace("-", " ").title(),
                          f"{variant} recorder produced no {name} manifest", variant)
            status = 1
            continue
        shutil.move(str(source), str(target))
        manifest_path = target / "manifest.json"
        try:
            manifest: dict[str, Any] = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["variant"] = variant
            manifest["comparison"] = name
            manifest["title"] = f"{manifest.get('title') or name} ({variant})"
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            if manifest.get("error") or manifest.get("frames_error"):
                status = 1
        except (OSError, ValueError, TypeError) as error:
            write_failure(target, name.replace("-", " ").title(),
                          f"invalid {variant} recorder manifest: {error}", variant)
            status = 1
    shutil.rmtree(raw, ignore_errors=True)
    return status


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--paths-file", type=Path)
    parser.add_argument("--base-app", type=Path)
    parser.add_argument("--head-app", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--no-fresh-state", action="store_true")
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args(argv)

    mapping = map_paths(read_paths(args))
    args.out.mkdir(parents=True, exist_ok=True)
    receipt = {
        **mapping,
        "base_app": str(args.base_app) if args.base_app else "",
        "head_app": str(args.head_app) if args.head_app else "",
        "variants": ["before", "after"] if mapping["is_ui"] else [],
        "status": "no-ui-paths" if not mapping["is_ui"] else "pending",
    }
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    if not mapping["is_ui"]:
        receipt["status"] = "no-ui-paths"
        args.receipt.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        return 0

    # A pull request that deletes a tour file names a tour with nothing left to run.
    tours = [name for name in mapping["tours"] if tour_file(name).is_file()]
    status = run_variant(app=args.base_app, variant="before", tours=tours, out=args.out,
                         fresh_state=not args.no_fresh_state)
    status |= run_variant(app=args.head_app, variant="after", tours=tours, out=args.out,
                          fresh_state=not args.no_fresh_state)
    receipt["status"] = "ok" if status == 0 else "recorder-failed"
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    return status


if __name__ == "__main__":
    sys.exit(main())
