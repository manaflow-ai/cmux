#!/usr/bin/env python3
"""Render cmux view code to PNGs in seconds, without building the app.

A harness is a Swift file whose top-level code builds views and hands them to
`UILab.render`. Its header names the app sources to compile with it:

    // ui-lab: source Sources/Sidebar/GPUSpinnerNSView.swift
    // ui-lab: shim SidebarAppearanceColorResolver

`source` paths are repo-relative; `shim` names a file in scripts/ui-lab/shims/
standing in for an app type the sources use. Sources are compiled as one
module with plain `swiftc` (their `import Cmux*` lines are dropped), so a
harness can only pull in files without package or app dependencies beyond
its shims. Keep view code that way when you want it here.

    scripts/ui-lab/ui-lab.py scripts/ui-lab/harnesses/gpu-spinner.swift
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
# `import CmuxFoo`, `@testable import CmuxFoo`, `import struct CmuxFoo.Bar`...
# Blanked, not deleted, so compiler line numbers still match the real file.
PACKAGE_IMPORT = re.compile(
    r"^[ \t]*(?:@\w+[ \t]+)*(?:(?:public|internal|package|private|fileprivate)[ \t]+)?"
    r"import[ \t]+(?:(?:struct|class|enum|protocol|typealias|func|var|let|actor)[ \t]+)?Cmux\w*[^\n]*$",
    re.M,
)
CACHE_DAYS = 14
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


def toolchain() -> str:
    """What else decides the binary: compiler, SDK and developer dir."""
    try:
        version = subprocess.run(["swiftc", "--version"], capture_output=True, text=True, check=True).stdout
        sdk = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"ui-lab: swiftc is not available ({error}); install Xcode or the command line tools")
    return version + sdk + os.environ.get("DEVELOPER_DIR", "")


def prune_cache() -> None:
    cutoff = time.time() - CACHE_DAYS * 86400
    for entry in CACHE.glob("*/lab"):
        try:
            if entry.stat().st_mtime < cutoff:
                shutil.rmtree(entry.parent, ignore_errors=True)
        except OSError:
            pass


def build(harness: Path) -> Path:
    files = inputs(harness)
    digest = hashlib.sha256(Path(__file__).read_bytes())  # flags and source rewriting
    for path in files:
        digest.update(str(path).encode())
        digest.update(path.read_bytes())
    digest.update(toolchain().encode())
    binary = CACHE / digest.hexdigest()[:16] / "lab"
    if binary.exists():
        os.utime(binary)
        return binary
    prune_cache()

    work = Path(tempfile.mkdtemp(prefix="cmux-ui-lab-"))
    try:
        compiled = []
        for index, path in enumerate(files):
            text = path.read_text()
            if path != harness:
                # One module: package imports resolve to shims or nothing.
                text = PACKAGE_IMPORT.sub("", text)
            name = "main.swift" if path == harness else f"{index:02d}-{path.name}"
            (work / name).write_text(text)
            compiled.append(str(work / name))
        binary.parent.mkdir(parents=True, exist_ok=True)
        started = time.monotonic()
        # Build beside the cache entry, then rename: concurrent runs of the
        # same harness never see a half-written binary.
        partial = work / "lab"
        result = subprocess.run(
            ["swiftc", "-Onone", "-swift-version", "5", "-o", str(partial), *compiled],
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
        shutil.copy2(partial, binary.with_name(f"lab.{os.getpid()}"))
        os.replace(binary.with_name(f"lab.{os.getpid()}"), binary)
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
