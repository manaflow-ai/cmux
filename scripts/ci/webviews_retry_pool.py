#!/usr/bin/env python3
"""What a red webviews file's pooled retry settles (run-webviews-tests.sh, CMUX_WEB_TEST_RETRY_POOL).

    webviews_retry_pool.py decide FIRST_LOG POOL_RESULT POOL_LOG   # prints pass, red-again or alone

run-webviews-tests.sh retries a pull request shard's red files a few at a time first, on an otherwise idle runner,
instead of one at a time. Each file's pooled retry then says one of:

- pass: it passed beside the other retries, so its first red was the contention of the full first pass.
- red-again: it failed again, naming exactly the tests its first run named, so two runs under two different loads
  agree on which tests are red. It gets no alone retry on the shard: react-apps-base-check replays every red on the
  base and re-runs alone on the head any red it would charge to the change, so a contention flake still passes there.
  In 14 shard logs after #49329 (2026-11-22 08:57-09:40Z), 108 of the 113 files red again on their alone retry named
  exactly the tests of their first run.
- alone: anything else (a timeout, a file that did not load or named no test, a different set of red tests, no pooled
  run at all): it gets its alone retry as before.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys

_spec = importlib.util.spec_from_file_location("webviews_test_results", Path(__file__).with_name("webviews_test_results.py"))
assert _spec and _spec.loader
_results = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_results)


def failed_names(log: Path) -> set[str]:
    """The `(fail)` tests a log names (its last attempt's, as webviews_test_results.py reads it)."""
    try:
        return _results._named_outcomes(log)[1]
    except OSError:
        return set()


def decide(first_log: Path, pool_result: str, pool_log: Path) -> str:
    if pool_result == "PASS":
        return "pass"
    if pool_result == "FAIL":
        again = failed_names(pool_log)
        if again and again == failed_names(first_log):
            return "red-again"
    return "alone"


def main(argv: list[str]) -> int:
    if len(argv) == 4 and argv[0] == "decide":
        print(decide(Path(argv[1]), argv[2], Path(argv[3])))
        return 0
    print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
