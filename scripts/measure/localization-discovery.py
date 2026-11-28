#!/usr/bin/env python3
"""Measure Swift discovery work with growing excluded dependency trees.

cmux-ci run --class exclusive --measurement --ref SHA \
  --script scripts/measure/localization-discovery.py --arg=--excluded --arg=2000
Registered: scripts/bench/cmux-bench localization-discovery --build local --host anywhere
The baseline retains the old rglob/filter algorithm. Timings describe this fixture,
not the full localization check; directory_reads is the deterministic work counter.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--excluded", type=int, default=2000)
    parser.add_argument("--algorithm", choices=("baseline", "current"), default="current")
    args = parser.parse_args()
    if args.excluded < 0:
        parser.error("--excluded must be nonnegative")
    spec = importlib.util.spec_from_file_location("localization_defaults", ROOT / "scripts/localization_defaults.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        (root / "Sources").mkdir()
        (root / "Sources/A.swift").write_text("", encoding="utf-8")
        for index in range(args.excluded):
            folder = root / ".build/checkouts" / str(index) / "Sources"
            folder.mkdir(parents=True)
            (folder / "Ignored.swift").write_text("", encoding="utf-8")
        reads = 0
        original = os.scandir

        def counted(path):
            nonlocal reads
            reads += 1
            return original(path)

        start = time.perf_counter()
        with mock.patch.object(os, "scandir", side_effect=counted):
            if args.algorithm == "baseline":
                paths = sorted(path for path in root.rglob("*.swift")
                               if module.SKIP_DIRS.isdisjoint(path.relative_to(root).parts[:-1]))
            else:
                paths = module.swift_files(root)
        elapsed = time.perf_counter() - start
        files = [path.relative_to(root).as_posix() for path in paths]
        if files != ["Sources/A.swift"]:
            raise RuntimeError(f"discovery changed coverage: {files!r}")
        print(json.dumps({"algorithm": args.algorithm, "excluded": args.excluded,
                          "seconds": elapsed, "directory_reads": reads, "files": files}))


if __name__ == "__main__":
    main()
