#!/usr/bin/env python3
"""Turn run-webviews-tests.sh's per-file summary into per-test results, for guards_new_reds.py.

    webviews_test_results.py SUMMARY OUT.json     # write {name: passed}
    webviews_test_results.py --failed-files OUT.json  # print the files with a red, one a line
    webviews_test_results.py --mark-unreached FILES OUT.json  # name in OUT.json the FILES it has no result for
    webviews_test_results.py --first-replay-stop-at STARTED TIMEOUT_MINUTES RESERVE [NOW]  # the first base replay's stop

SUMMARY has a `RESULT FILE LOG` line per file. A failed file lists each of its `(fail)` tests as
`FILE > TEST: false`; a complete failed file also lists its explicit `(pass)` tests as true. A file that timed out, or failed without naming a test (it did not load),
is `FILE: false`; a passing file is `FILE: true`. Results compare by exact name, so a base file
that crashed or hung says nothing about the tests it never reached: their reds stay the change's.
A file red again on its retry alone keeps a log of both runs; only the retry's outcomes count,
since the base reruns the file once, alone, too.

With CMUX_WEB_TEST_STATES set, it also writes {file: {"result": PASS, FAIL or TIMEOUT, "completed": bool}} there:
"completed" when the file's (last) run reached bun's closing `Ran N tests across M files.` line, so a FAIL that
names only some tests says the rest passed. The bisect's probes read it (web_coalesce.py) for tests with no explicit result.
CMUX_WEB_TEST_RETRY_SKIPPED names a file (run-webviews-tests.sh writes it) listing, one a line, the red files whose
retry was due but never ran to its end (a budget, the deadline or the retry cap stopped it). Such a file's log holds
only its first run, whose tally says nothing about a retry, so it is never "completed" (#34017).
"""
from __future__ import annotations

import json
import importlib.util
import os
from pathlib import Path
import re
import sys

FAIL_BYTES = re.compile(rb"^\(fail\) (.+?)(?: \[[0-9.]+m?s\])?$")
PASS_BYTES = re.compile(rb"^\(pass\) (.+?)(?: \[[0-9.]+m?s\])?$")
RETRY = "--- retry, alone ---"  # run-webviews-tests.sh's line between a twice-red file's two logs
RETRY_BYTES = RETRY.encode()
RETRY_STOPPED = "--- retry stopped at shared budget ---"
RETRY_STOPPED_BYTES = RETRY_STOPPED.encode()
LOG_CHUNK_BYTES = 64 * 1024
TALLY = re.compile(rb"^Ran \d+ tests? across \d+ files?\.", re.M)  # bun's last line once a file ran to its end
ANSI = re.compile(rb"\x1b\[[0-9;]*m")
MAX_LINE_BYTES = 1 * 1024 * 1024


def _named_outcomes(log: Path) -> tuple[set[str], set[str], bool]:
    """Read named pass/fail outcomes in bounded chunks, including huge diagnostic logs.

    The runner may retry a file after the first attempt; only the final attempt is evidence,
    so both sets are reset at the retry marker.
    """
    passed: set[str] = set()
    failed: set[str] = set()
    retry_stopped = False
    in_stopped_retry = False
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
        nonlocal oversized, retry_stopped, in_stopped_retry
        if not oversized:
            raw = bytes(line).rstrip(b"\r")
            if raw == RETRY_BYTES:
                passed.clear()
                failed.clear()
                in_stopped_retry = False
            elif raw == RETRY_STOPPED_BYTES:
                # The first run is the only complete evidence when the retry budget
                # is cut short. Ignore any partial retry output and keep its red names.
                passed.clear()
                retry_stopped = True
                in_stopped_retry = True
            elif raw == b"--- first failure retained ---":
                passed.clear()
                failed.clear()
                in_stopped_retry = False
            else:
                if in_stopped_retry:
                    line.clear()
                    oversized = False
                    return
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
    return passed, failed, retry_stopped


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
            passed, failed, retry_stopped = _named_outcomes(log_path)
            complete = result == "FAIL" and bool(_completed(log_path)) and not retry_stopped
        except OSError:
            passed, failed, retry_stopped = set(), set(), False
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


def _retry_skipped() -> set[str]:
    path = os.environ.get("CMUX_WEB_TEST_RETRY_SKIPPED")
    if not path:
        return set()
    try:
        return {line for line in Path(path).read_text(encoding="utf-8").splitlines() if line}
    except OSError:
        return set()


def states(summary: Path) -> dict[str, dict]:
    out: dict[str, dict] = {}
    skipped = _retry_skipped()
    for line in summary.read_text(encoding="utf-8").splitlines():
        parts = line.split(" ", 2)
        if len(parts) != 3:
            continue
        result, file, log = parts
        try:
            completed = result == "PASS" or (result == "FAIL" and _completed(Path(log)))
        except OSError:
            completed = False
        if file in skipped and result != "PASS":
            out[file] = {"result": result, "completed": False, "retry": "skipped"}
            continue
        out[file] = {"result": result, "completed": completed}
    return out


def failed_files(results: dict[str, bool]) -> list[str]:
    return sorted({name.split(" > ", 1)[0] for name, ok in results.items() if not name.startswith("_cmux_") and not ok})


def mark_unreached(files: Path, out: Path) -> list[str]:
    """Record in OUT (`_cmux_unreached`) each file of FILES that OUT has no result for, and return them.

    A replay cut by CMUX_WEB_TEST_STOP_AT (react-apps-base-check's first base replay) leaves the files it did not reach
    out of its results. guards_new_reds.py would read such a file's absence from a finished replay as "not red on the
    base" and charge its head reds to the change; named here, they are "base result unavailable" instead. Unreadable
    results are left alone (guards_new_reds.py already treats a base it cannot read as unavailable)."""
    try:
        results = json.loads(out.read_text(encoding="utf-8"))
        wanted = [line.strip() for line in files.read_text(encoding="utf-8").splitlines() if line.strip()]
    except (OSError, ValueError):
        return []
    if not isinstance(results, dict):
        return []
    reached = {name.split(" > ", 1)[0] for name in results if not name.startswith("_cmux_")}
    unreached = sorted({file for file in wanted if file not in reached})
    if unreached:
        results["_cmux_unreached"] = sorted(set(results.get("_cmux_unreached") or []) | set(unreached))
        out.write_text(json.dumps(results, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    return unreached


def tap_observations(summary: Path, *, log_dir: Path | None = None):
    """Explicit outcomes from each file's final whole attempt, with bounded line/diagnostic buffers.

    Huge diagnostic floods supply no samples, preserving the existing MAX_LINE_BYTES safety bound rather than
    trimming an error into a signature that could match a different failure. Memory is per-file test results plus
    that buffer; a green file's complete console output is never retained in memory or printed.
    """
    parser_path = Path(__file__).with_name("test_reds.py")
    # Older downloaded runner artifacts omit the classifier. Their base replay still works; it contributes no
    # scoring evidence until the artifact includes the same canonical parser as the source checkout.
    if not parser_path.is_file():
        return
    spec = importlib.util.spec_from_file_location("tap_test_reds", parser_path)
    reds = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reds)

    class Unreadable(Exception):
        pass

    def bounded_lines(stream):
        while raw := stream.readline(MAX_LINE_BYTES + 1):
            if len(raw) > MAX_LINE_BYTES:
                while raw and not raw.endswith(b"\n"):
                    raw = stream.readline(MAX_LINE_BYTES + 1)
                yield None
            else:
                yield ANSI.sub(b"", raw.rstrip(b"\r\n"))

    with summary.open(encoding="utf-8") as listed:
        for line in listed:
            parts = line.rstrip("\n").split(" ", 2)
            if len(parts) != 3 or parts[0] not in {"PASS", "FAIL"}:
                continue
            outcome, file, path = parts
            if log_dir is not None:
                path = str(log_dir / Path(path).name)  # artifact downloads relocate the runner's absolute paths
            file = reds.BUN_PACKAGE.sub("", file)
            try:
                if not _completed(Path(path)):
                    continue
                # A twice-red log includes the first attempt for diagnosis. It cannot supply outcomes for the
                # final attempt (a first-attempt crash may have a whole, passing retry).
                offset = 0
                with open(path, "rb") as stream:
                    for raw in bounded_lines(stream):
                        if raw == RETRY_BYTES:
                            offset = stream.tell()
                found = reds.Result()
                with open(path, "rb") as stream:
                    stream.seek(offset)
                    def checked_lines():
                        diagnostic_bytes = 0
                        for raw in bounded_lines(stream):
                            if raw is None:
                                raise Unreadable()
                            text = raw.decode("utf-8", errors="replace")
                            exited = reds.PROCESS_EXIT.match(text)
                            if (reds.BUN_PANIC.match(text) or reds.TRUNCATED.search(text)
                                    or reds.LOST_RUNNER.search(text) or reds.BLOB_NOT_FOUND.search(text)
                                    or (exited and 129 <= int(exited.group(1)) <= 192)
                                    or ((reds.CRASH.search(text) or reds.CRASH_AT_START.search(text)
                                         or reds.SIGNALED.search(text)) and not reds.TEST_LINE.search(text))
                                    or text.startswith("--- retry stopped at shared budget ---")):
                                raise Unreadable()
                            if reds.BUN_TEST.match(text) or reds.BUN_COUNT.match(text):
                                diagnostic_bytes = 0
                            else:
                                diagnostic_bytes += len(raw)
                                if diagnostic_bytes > MAX_LINE_BYTES:
                                    raise Unreadable()
                            yield text
                    reds.read_bun(checked_lines(), found)
                if found.truncated or (outcome == "PASS" and found.failed) or (outcome == "FAIL" and not found.failed):
                    continue
                for name in sorted(found.passed | found.failed):
                    if not name.startswith(file + " > "):
                        continue
                    yield {"schema": "tap-test/v1", "file": file, "test": name,
                           "outcome": "fail" if name in found.failed else "pass",
                           "signature": found.messages.get(name, "") if name in found.failed else ""}
            except (OSError, Unreadable):
                continue


FILE_CEILING = 900  # run-webviews-tests.sh's per-file limit (CMUX_WEB_TEST_MAX_FILE_TIMEOUT's default)
VERDICT_MARGIN = 120  # the head re-run's margin before the job's timeout


def first_replay_stop_at(started: int, timeout_minutes: int, reserve: int, now: int) -> int | None:
    """The epoch second react-apps-base-check's first base replay stops at (None: no job clock, no stop).

    The first replay holds only the head's reds, so it is the base verdict: it always gets one whole file's time
    from when it starts. A fixed reserve counted from the job's start let a slow setup use the replay's budget up
    before its one file ran (cmux#53976, job 138896898305: NOT RUN ... past CMUX_WEB_TEST_STOP_AT), and a red from
    the base then had no base verdict and failed the change. The reserve for the head re-run holds when there is
    time for both; it never pushes the replay past the verdict's margin before the job's timeout.
    """
    if started <= 0:
        return None
    end = started + timeout_minutes * 60
    return min(max(end - reserve, now + FILE_CEILING), end - VERDICT_MARGIN)


def main(argv: list[str]) -> int:
    if len(argv) in (4, 5) and argv[0] == "--first-replay-stop-at":
        try:
            started, minutes, reserve = (int(value) for value in argv[1:4])
            now = int(argv[4]) if len(argv) == 5 else int(__import__("time").time())
        except ValueError:
            started, minutes, reserve, now = 0, 0, 0, 0
        stop = first_replay_stop_at(started, minutes, reserve, now)
        print("" if stop is None else stop)
        return 0
    if len(argv) == 2 and argv[0] == "--tap-markers":
        print("::group::TAP final named results")
        for row in tap_observations(Path(argv[1])):
            print("tap-test/v1 " + json.dumps(row, ensure_ascii=True, separators=(",", ":")))
        print("::endgroup::")
        return 0
    if len(argv) == 2 and argv[0] == "--failed-files":
        print("\n".join(failed_files(json.loads(Path(argv[1]).read_text(encoding="utf-8")))))
        return 0
    if len(argv) == 3 and argv[0] == "--mark-unreached":
        unreached = mark_unreached(Path(argv[1]), Path(argv[2]))
        if unreached:
            print(f"the replay did not reach {len(unreached)} files (no base result):")
            for file in unreached:
                print(f"  {file}")
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
