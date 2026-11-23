"""Run a unittest file's tests in forked workers, one test per worker.

A guard test file whose tests each wait on subprocesses (git, a fake gh, a
helper script) spends most of its time waiting, so its tests overlap well.
Run serially, the slowest of them set how long the "CI fast guards" job takes
(tests/test_gh_merge_green.py alone ran 186 s of a 210 s suite).

    if __name__ == "__main__":
        sys.exit(parallel_unittest.main())

Each test runs in its own forked process, so a test that patches module state
or the environment cannot leak into the next one; setUpClass runs once per
test. CMUX_TEST_WORKERS sets the worker count (1 runs the file in order in
this process, as unittest.main() would). Off Linux only an explicit
CMUX_TEST_WORKERS forks. Any command-line argument (a test name, -k) runs
unittest.main() unchanged.
"""

from __future__ import annotations

import io
import os
import sys
import unittest

DEFAULT_WORKERS = 4
TEST_TIMEOUT_SECONDS = 600


def _test_ids(suite: unittest.TestSuite) -> list[str]:
    ids: list[str] = []
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            ids.extend(_test_ids(item))
        else:
            ids.append(item.id())
    return ids


def _run_one(test_id: str) -> tuple[str, bool, str]:
    name = test_id.removeprefix("__main__.")
    suite = unittest.defaultTestLoader.loadTestsFromName(name, sys.modules["__main__"])
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream, verbosity=0, buffer=True).run(suite)
    return test_id, result.wasSuccessful(), stream.getvalue()


def worker_count() -> int:
    requested = os.environ.get("CMUX_TEST_WORKERS", "")
    if requested:
        if not requested.isdigit():
            raise SystemExit(f"CMUX_TEST_WORKERS must be a whole number, got {requested!r}")
        return int(requested)
    if sys.platform != "linux":
        return 1
    cores = len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else (os.cpu_count() or 1)
    return min(DEFAULT_WORKERS, cores)


def main() -> int:
    workers = worker_count()
    if len(sys.argv) > 1 or workers <= 1:
        unittest.main(module="__main__")
        return 0  # unittest.main exits itself
    ids = _test_ids(unittest.defaultTestLoader.loadTestsFromModule(sys.modules["__main__"]))
    import multiprocessing

    failures: list[tuple[str, str]] = []
    with multiprocessing.get_context("fork").Pool(min(workers, max(1, len(ids))), maxtasksperchild=1) as pool:
        results = pool.imap_unordered(_run_one, ids)
        pending = set(ids)
        while pending:
            try:
                # A worker that dies outright (a signal, os._exit) never
                # returns its test, and Pool would wait forever.
                test_id, ok, output = results.next(timeout=TEST_TIMEOUT_SECONDS)
            except multiprocessing.TimeoutError:
                failures.extend(
                    (test_id, f"no result within {TEST_TIMEOUT_SECONDS} s: the test hung or its worker died\n")
                    for test_id in sorted(pending)
                )
                pool.terminate()
                break
            pending.discard(test_id)
            if not ok:
                failures.append((test_id, output))
    for test_id, output in sorted(failures):
        print(f"FAIL: {test_id}\n{output}", file=sys.stderr)
    print(f"Ran {len(ids)} tests in {workers} workers: {len(ids) - len(failures)} passed, {len(failures)} failed")
    return 1 if failures else 0
