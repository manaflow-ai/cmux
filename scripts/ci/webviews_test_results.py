#!/usr/bin/env python3
"""Turn run-webviews-tests.sh's per-file summary into per-test results, for guards_new_reds.py.

    webviews_test_results.py SUMMARY OUT.json     # write {name: passed}
    webviews_test_results.py --failed-files OUT.json  # print the files with a red, one a line

SUMMARY has a `RESULT FILE LOG` line per file. A failed file lists each of its `(fail)` tests as
`FILE > TEST: false`. A file that timed out, or failed without naming a test (it did not load),
is `FILE: false`; a passing file is `FILE: true`. Results compare by exact name, so a base file
that crashed or hung says nothing about the tests it never reached: their reds stay the change's.
A file red again on its retry alone keeps a log of both runs; only the retry's `(fail)` tests count,
since the base reruns the file once, alone, too.
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import sys

FAIL_BYTES = re.compile(rb"^\(fail\) (.+?)(?: \[[0-9.]+m?s\])?$")
RETRY = "--- retry, alone ---"  # run-webviews-tests.sh's line between a twice-red file's two logs
RETRY_BYTES = RETRY.encode()
LOG_CHUNK_BYTES = 64 * 1024
MAX_LINE_BYTES = 1 * 1024 * 1024


def _named_failures(log: Path) -> set[str]:
    """Read a failure log in bounded chunks, including logs with no newline for hundreds of MB."""
    named: set[str] = set()
    line = bytearray()
    oversized = False

    def append(fragment: bytes) -> None:
        nonlocal oversized
        if oversized:
            return
        if len(line) + len(fragment) > MAX_LINE_BYTES:
            line.clear()
            oversized = True
            return
        line.extend(fragment)

    def finish() -> None:
        nonlocal oversized
        if not oversized:
            raw = bytes(line).rstrip(b"\r")
            if raw == RETRY_BYTES:
                named.clear()
            else:
                match = FAIL_BYTES.fullmatch(raw)
                if match:
                    named.add(match.group(1).decode("utf-8", errors="replace"))
        line.clear()
        oversized = False

    with log.open("rb") as stream:
        for chunk in iter(lambda: stream.read(LOG_CHUNK_BYTES), b""):
            parts = chunk.split(b"\n")
            append(parts[0])
            for part in parts[1:]:
                finish()
                append(part)
    finish()
    return named


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
            named = _named_failures(Path(log))
        except OSError:
            named = set()
        if result != "FAIL" or not named:
            results[file] = False
        for name in named:
            results[f"{file} > {name}"] = False
    return results


def failed_files(results: dict[str, bool]) -> list[str]:
    return sorted({name.split(" > ", 1)[0] for name, ok in results.items() if not ok})


def main(argv: list[str]) -> int:
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
