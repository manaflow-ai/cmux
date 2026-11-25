#!/usr/bin/env python3
"""Run one unittest file and write each test's verdict, for guards_new_reds.py to compare with the base's.

    unittest_results.py TEST_FILE RESULTS_JSON

RESULTS_JSON is {"Class.test_name": passed, ..., "_cmux_complete": true}. A file that cannot load or
whose run is cut short writes `TEST_FILE: false` with `_cmux_complete` false, so the compare counts it
unresolved, never a pass. The test output goes to stderr as `python3 TEST_FILE` prints it. The exit
status is the run's: 0 when every test passed.

ci-web.yml's "Check PR-scoped webview rules" runs scripts/tests/test_pr_scoped_webviews_checks.py this
way on a pull request's merge commit, and, when it is red, the base's copy of the file in a worktree of
the merge parent: the fixture copies the real webviews tree, so a finding already on the base (#48230's
experiment id agent-pane.high-contrast-look) failed it, and with it every web-view pull request's shard 1.
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import unittest


def test_id(test: unittest.TestCase) -> str:
    # "module.Class.test_name" minus the module: the head's and the base's copies load under one name.
    return ".".join(test.id().split(".")[-2:])


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    source, out = Path(argv[0]).resolve(), Path(argv[1])
    results: dict[str, bool] = {}
    complete = False
    status = 1
    try:
        spec = importlib.util.spec_from_file_location(f"unittest_results_{source.stem}", source)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        suite = unittest.defaultTestLoader.loadTestsFromModule(module)
        # Listed before the run: a suite drops each test once it ran.
        stack = [suite]
        while stack:
            item = stack.pop()
            if isinstance(item, unittest.TestSuite):
                stack.extend(item)
            else:
                results[test_id(item)] = True
        result = unittest.TextTestRunner(stream=sys.stderr, verbosity=2).run(suite)
        for test, _ in [*result.failures, *result.errors, *[(t, "") for t in result.unexpectedSuccesses]]:
            # A failed subTest reports its parent test.
            results[test_id(getattr(test, "test_case", test))] = False
        complete = True
        status = 0 if result.wasSuccessful() else 1
    except BaseException as error:  # noqa: BLE001 - a file that cannot load is a red, recorded, not a crash
        print(f"{source}: {type(error).__name__}: {error}", file=sys.stderr)
        results[str(argv[0])] = False
    finally:
        out.write_text(json.dumps({**results, "_cmux_complete": complete}, indent=1, sort_keys=True) + "\n",
                       encoding="utf-8")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
