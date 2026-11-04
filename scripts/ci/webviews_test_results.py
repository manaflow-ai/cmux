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

With CMUX_WEB_TEST_STATES set, it also writes {file: {"result": PASS, FAIL or TIMEOUT, "completed": bool}} there:
"completed" when the file's (last) run reached bun's closing `Ran N tests across M files.` line, so a FAIL that
names only some tests says the rest passed. The bisect's probes read it (web_coalesce.py), since the results name
no passing test.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sys

FAIL_BYTES = re.compile(rb"^\(fail\) (.+?)(?: \[[0-9.]+m?s\])?$")
PASS_BYTES = re.compile(rb"^\(pass\) (.+?)(?: \[[0-9.]+m?s\])?$")
RETRY = "--- retry, alone ---"  # run-webviews-tests.sh's line between a twice-red file's two logs
RETRY_BYTES = RETRY.encode()
LOG_CHUNK_BYTES = 64 * 1024
TALLY = re.compile(rb"^Ran \d+ tests? across \d+ files?\.", re.M)  # bun's last line once a file ran to its end
ANSI = re.compile(rb"\x1b\[[0-9;]*m")
MAX_LINE_BYTES = 1 * 1024 * 1024


def _named_outcomes(log: Path) -> tuple[set[str], set[str]]:
    """Read named pass/fail outcomes in bounded chunks, including huge diagnostic logs.

    The runner may retry a file after the first attempt; only the final attempt is evidence,
    so both sets are reset at the retry marker.
    """
    passed: set[str] = set()
    failed: set[str] = set()
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
                passed.clear()
                failed.clear()
            else:
                fail = FAIL_BYTES.fullmatch(raw)
                if fail:
                    failed.add(fail.group(1).decode("utf-8", errors="replace"))
                else:
                    success = PASS_BYTES.fullmatch(raw)
                    if success:
                        passed.add(success.group(1).decode("utf-8", errors="replace"))
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
    return passed, failed


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
        log_path = Path(log)
        try:
            passed, failed = _named_outcomes(log_path)
            complete = result == "FAIL" and bool(_completed(log_path))
        except OSError:
            passed, failed = set(), set()
            complete = False
        # A named pass is evidence only after the file reached Bun's closing tally.
        # A cut-short or crashed file remains a file-level red and must not hide it.
        if result != "FAIL" or not failed:
            results[file] = False
        if complete:
            for name in passed:
                results[f"{file} > {name}"] = True
        for name in failed:
            results[f"{file} > {name}"] = False
    return results


def _completed(log: Path) -> bool:
    """Whether the log's last run (after a retry line, if any) reached bun's closing tally."""
    with log.open("rb") as stream:
        stream.seek(0, 2)
        stream.seek(max(0, stream.tell() - LOG_CHUNK_BYTES))
        tail = ANSI.sub(b"", stream.read())
    last = tail.rsplit(RETRY_BYTES, 1)[-1]
    return bool(TALLY.search(last))


def states(summary: Path) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for line in summary.read_text(encoding="utf-8").splitlines():
        parts = line.split(" ", 2)
        if len(parts) != 3:
            continue
        result, file, log = parts
        try:
            completed = result == "PASS" or (result == "FAIL" and _completed(Path(log)))
        except OSError:
            completed = False
        out[file] = {"result": result, "completed": completed}
    return out


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
    if os.environ.get("CMUX_WEB_TEST_STATES"):
        Path(os.environ["CMUX_WEB_TEST_STATES"]).write_text(
            json.dumps(states(Path(argv[0])), indent=1, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
