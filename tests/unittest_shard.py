"""`--shard I/N` for a unittest file, so a long file runs as N pool commands instead of one.

A test file whose cases are independent (each in its own temporary directory) ends with

    if __name__ == "__main__":
        unittest_shard.main()

and runs whole as before (`python3 tests/test_x.py`, every unittest.main flag intact), or as one of N
parts (`python3 tests/test_x.py --shard 2/4`). The parts split the file's test IDs, sorted, round-robin:
every test runs in exactly one part, and N parts started side by side in the checks job's pool
(scripts/ci/run-checks-concurrently.sh) take about 1/N of the file's time. The prepush gate suite ran
145 cases one after another for 238 s on Linux and 576 s on a mini, the checks pool's longest command
by twice the next one.
"""
from __future__ import annotations

import sys
import unittest


def _flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from _flatten(item)
        else:
            yield item


def parse_shard(argv: list[str]) -> tuple[list[str], tuple[int, int] | None]:
    """(argv without --shard, (index, count) or None). Exits 2 on a malformed shard."""
    rest, shard = [], None
    items = iter(argv)
    for arg in items:
        value = None
        if arg == "--shard":
            value = next(items, "")
        elif arg.startswith("--shard="):
            value = arg.split("=", 1)[1]
        if value is None:
            rest.append(arg)
            continue
        index, _, count = value.partition("/")
        if not (index.isdigit() and count.isdigit() and 1 <= int(index) <= int(count)):
            print(f"error: --shard is I/N with 1 <= I <= N, not {value!r}", file=sys.stderr)
            raise SystemExit(2)
        shard = (int(index), int(count))
    return rest, shard


class _ShardProgram(unittest.TestProgram):
    shard: tuple[int, int] | None = None

    def createTests(self, *args, **kwargs):
        super().createTests(*args, **kwargs)
        if self.shard is None:
            return
        index, count = self.shard
        tests = sorted(_flatten(self.test), key=lambda test: test.id())
        self.test = unittest.TestSuite(test for n, test in enumerate(tests) if n % count == index - 1)
        print(f"shard {index}/{count}: {self.test.countTestCases()} of {len(tests)} tests", file=sys.stderr)


def main(module: str = "__main__") -> None:
    argv, shard = parse_shard(sys.argv)
    _ShardProgram.shard = shard
    _ShardProgram(module=module, argv=argv)
