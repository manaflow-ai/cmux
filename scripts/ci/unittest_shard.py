#!/usr/bin/env python3
"""Run one shard of a unittest file: every COUNT-th test, starting at INDEX.

  python3 scripts/ci/unittest_shard.py INDEX COUNT tests/test_x.py

run_ci_guards.py splits a long guard step (`python3 tests/test_x.py`) into
COUNT of these so its tests spread over the runner's workers instead of
holding one worker for minutes (SHARDED_STEPS there). The file is imported
the way `python3 tests/test_x.py` runs it, with its own directory first on
sys.path, and the shards together run exactly the tests unittest.main() would.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


def tests_of(suite: unittest.TestSuite) -> list[unittest.TestCase]:
    found: list[unittest.TestCase] = []
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            found.extend(tests_of(item))
        else:
            found.append(item)
    return found


def main(argv: list[str]) -> int:
    if len(argv) != 3 or not argv[0].isdigit() or not argv[1].isdigit():
        print("usage: unittest_shard.py INDEX COUNT FILE", file=sys.stderr)
        return 2
    index, count, path = int(argv[0]), int(argv[1]), Path(argv[2]).resolve()
    if count < 1 or index >= count:
        print(f"unittest_shard.py: shard {index} of {count} does not exist", file=sys.stderr)
        return 2
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if spec is None or spec.loader is None:
        print(f"unittest_shard.py: cannot import {path}", file=sys.stderr)
        return 2
    module = importlib.util.module_from_spec(spec)
    sys.modules[path.stem] = module
    spec.loader.exec_module(module)
    every = sorted(tests_of(unittest.defaultTestLoader.loadTestsFromModule(module)), key=lambda t: t.id())
    if not every:
        print(f"unittest_shard.py: {path} has no tests", file=sys.stderr)
        return 1
    mine = unittest.TestSuite(every[index::count])
    print(f"{path.name}: shard {index + 1} of {count}, {mine.countTestCases()} of {len(every)} tests", flush=True)
    result = unittest.TextTestRunner(buffer=True, verbosity=1).run(mine)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
