#!/usr/bin/env python3
"""Render cmux view code to PNGs in seconds, without building the app.

A harness is a Swift file whose top-level code builds views and hands them to
`UILab.render`. Its header names the app sources to compile with it:

    // ui-lab: source Sources/Sidebar/SidebarCompactStatusGlyph.swift
    // ui-lab: shim RenderableSystemSymbol

`source` paths are repo-relative; `shim` names a file in scripts/ui-lab/shims/
standing in for an app type the sources use. Sources are compiled as one
module with plain `swiftc` (their `import Cmux*` lines are dropped), so a
harness can only pull in files without package or app dependencies beyond
its shims. Keep view code that way when you want it here.

    scripts/ui-lab/ui-lab.py scripts/ui-lab/harnesses/sidebar-compact-status.swift
    scripts/ui-lab/ui-lab.py <harness> --watch     # re-render on every save
    scripts/ui-lab/ui-lab.py <harness> --out DIR

Each render writes light and dark PNGs at 2x, plus a 4x crop for detail, and
prints their paths. The binary is cached by input hash, so an unchanged
re-run only renders. This is a design loop, not proof: the CI UI tests
(`scripts/ui-test`) still check the real app.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LAB = Path(__file__).resolve().parent
DIRECTIVE = re.compile(r"^//\s*ui-lab:\s*(source|shim)\s+(\S+)\s*$")
CACHE = Path(os.environ.get("CMUX_UI_LAB_CACHE", Path.home() / "Library/Caches/cmux-ui-lab"))


def inputs(harness: Path) -> list[Path]:
    """The Swift files one harness compiles: support, shims, sources, harness."""
    files = [LAB / "UILab.swift"]
    for line in harness.read_text().splitlines():
        match = DIRECTIVE.match(line.strip())
        if not match:
            continue
        kind, value = match.groups()
        path = LAB / "shims" / f"{value}.swift" if kind == "shim" else ROOT / value
        if not path.exists():
            raise SystemExit(f"ui-lab: {kind} {value} not found at {path}")
        files.append(path)
    return files + [harness]


def build(harness: Path) -> Path:
    files = inputs(harness)
    digest = hashlib.sha256()
    for path in files:
        digest.update(str(path).encode())
        digest.update(path.read_bytes())
    digest.update(subprocess.run(["swiftc", "--version"], capture_output=True, text=True).stdout.encode())
    binary = CACHE / digest.hexdigest()[:16] / "lab"
    if binary.exists():
        return binary

    work = Path(tempfile.mkdtemp(prefix="cmux-ui-lab-"))
    try:
        compiled = []
        for index, path in enumerate(files):
            text = path.read_text()
            if path != harness:
                # One module: package imports resolve to shims or nothing.
                text = re.sub(r"^(?:@_implementationOnly |public |internal )?import Cmux\w*\s*$", "", text, flags=re.M)
            name = "main.swift" if path == harness else f"{index:02d}-{path.name}"
            (work / name).write_text(text)
            compiled.append(str(work / name))
        binary.parent.mkdir(parents=True, exist_ok=True)
        started = time.monotonic()
        result = subprocess.run(
            ["swiftc", "-Onone", "-swift-version", "5", "-o", str(binary), *compiled],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            # Point errors at the real files, not the temp copies.
            output = result.stderr
            for index, path in enumerate(files):
                name = "main.swift" if path == harness else f"{index:02d}-{path.name}"
                output = output.replace(str(work / name), str(path))
            sys.stderr.write(output)
            raise SystemExit("ui-lab: compile failed")
        print(f"ui-lab: compiled {len(files)} files in {time.monotonic() - started:.1f}s", file=sys.stderr)
        return binary
    finally:
        shutil.rmtree(work, ignore_errors=True)


def render(harness: Path, out: Path) -> None:
    binary = build(harness)
    out.mkdir(parents=True, exist_ok=True)
    result = subprocess.run([str(binary), str(out)], capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode != 0:
        raise SystemExit(f"ui-lab: harness exited {result.returncode}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("harness", type=Path)
    parser.add_argument("--out", type=Path, help="default: $TMPDIR/cmux-ui-lab/<harness name>")
    parser.add_argument("--watch", action="store_true", help="re-render whenever an input changes")
    args = parser.parse_args(argv)

    harness = args.harness.resolve()
    out = args.out or Path(tempfile.gettempdir()) / "cmux-ui-lab" / harness.stem
    try:
        render(harness, out)
    except SystemExit as error:
        if not args.watch:
            raise
        print(error, file=sys.stderr)
    if not args.watch:
        return 0

    def stamp() -> tuple[float, ...]:
        try:
            return tuple(path.stat().st_mtime for path in inputs(harness))
        except (OSError, SystemExit):
            return ()

    last = stamp()
    print("ui-lab: watching; Ctrl-C to stop", file=sys.stderr)
    while True:
        time.sleep(0.4)
        current = stamp()
        if current and current != last:
            last = current
            try:
                render(harness, out)
            except SystemExit as error:
                print(error, file=sys.stderr)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
