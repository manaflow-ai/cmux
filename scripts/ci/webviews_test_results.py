#!/usr/bin/env python3
"""Turn run-webviews-tests.sh's per-file summary into per-test results, for guards_new_reds.py.

    webviews_test_results.py SUMMARY OUT.json     # write {name: passed}
    webviews_test_results.py --failed-files OUT.json  # print the files with a red, one a line
    webviews_test_results.py --passed-alone OUT.json AGAIN.json  # drop the reds of files that passed again

SUMMARY has a `RESULT FILE LOG` line per file. A failed file lists each of its `(fail)` tests as
`FILE > TEST: false`. A file that timed out, or failed without naming a test (it did not load),
is `FILE: false`; a passing file is `FILE: true`. Results compare by exact name, so a base file
that crashed or hung says nothing about the tests it never reached: their reds stay the change's.
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import sys

FAIL = re.compile(r"^\(fail\) (.+?)(?: \[[0-9.]+m?s\])?$")


def collect(summary: Path) -> dict[str, bool]:
    results: dict[str, bool] = {}
    for line in summary.read_text(encoding="utf-8").splitlines():
        parts = line.split(" ", 2)
        if len(parts) != 3:
            continue
        result, file, log = parts
        if result == "PASS":
            results[file] = True
            continue
        try:
            text = Path(log).read_text(encoding="utf-8", errors="replace")
        except OSError:
            text = ""
        named = {m.group(1) for m in map(FAIL.match, text.splitlines()) if m}
        if result != "FAIL" or not named:
            results[file] = False
        for name in named:
            results[f"{file} > {name}"] = False
    return results


def failed_files(results: dict[str, bool]) -> list[str]:
    return sorted({name.split(" > ", 1)[0] for name, ok in results.items() if not ok})


def passed_alone(results: dict[str, bool], again: dict[str, bool]) -> tuple[dict[str, bool], list[str]]:
    """The results without the reds of each file that passed when run again alone (a flake under the
    shard's load), and those files. A file that failed again, or did not run, keeps every red."""
    flaky = sorted(file for file in failed_files(results) if again.get(file) is True)
    kept = {name: ok for name, ok in results.items() if name.split(" > ", 1)[0] not in flaky}
    return kept, flaky


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[0] == "--passed-alone":
        out = Path(argv[1])
        try:
            again = json.loads(Path(argv[2]).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            again = {}
        kept, flaky = passed_alone(json.loads(out.read_text(encoding="utf-8")), again)
        for file in flaky:
            print(f"::warning title=Webview test file red only beside the others::{file} passed when run again alone")
        out.write_text(json.dumps(kept, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        return 0
    if len(argv) == 2 and argv[0] == "--failed-files":
        print("\n".join(failed_files(json.loads(Path(argv[1]).read_text(encoding="utf-8")))))
        return 0
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    Path(argv[1]).write_text(json.dumps(collect(Path(argv[0])), indent=1, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
