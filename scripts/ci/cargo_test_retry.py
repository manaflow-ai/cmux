#!/usr/bin/env python3
"""Run a test command once; run it again only when a fetch fault, not a test, failed it.

    cargo_test_retry.py --log LOG [--attempts N] [--require-tests] [--what TEXT] -- cargo test ...

The command's output streams to stdout and to LOG. What ends the run:

- It passed: exit 0. With --require-tests, a run that printed no `test result: ok. N passed` with N > 0 (the
  filter matched nothing) is red, at once.
- A stale Cargo.lock (scripts/cmux-next/cargo-locks.py explain names it and its fix): its exit code, at once.
- A fetch fault (a registry, git or download error before any test binary ran: FETCH_FAULTS below): again, up to
  --attempts runs in all, sleeping --backoff * attempt seconds between them; red after the last.
- Anything else (an assertion failure, a panic, a compile error, a crash): its exit code, at once. Running the
  same tests again on the same tree fails them the same way.

Before this, cmux-tui-artifacts.yml's `cargo test cmux_next_` step ran any red 3 times: identical completed
assertion failures cost 146 s (run 43304980866, job 131513680527) and 133 s (run 43337528090, job 131597798256)
extra per red run (cmuxterm-hq#14034). Leo, 2026-11-19: "we can skip stuff. Like a lot of stuff, like 90%, and
then we just have to fix forward a bit every now and then."

scripts/ci/check_test_retry_loops.py fails on a workflow or shell script that retries a test command in a loop of
its own instead of running it through this script. Tests: tests/test_ci_cargo_test_retry.py (a fake cargo).
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCKS = ROOT / "scripts/cmux-next/cargo-locks.py"

# cargo's and libcurl's words for a fetch that did not complete. They count only in a run where no test binary
# started (no `running N tests` line): a test's own output can hold "Connection refused" and is a test failure.
FETCH_FAULTS = re.compile(
    r"failed to download|failed to fetch|failed to clone|failed to update registry|unable to update registry"
    r"|failed to query replaced source registry|failed to load source for dependency|spurious network error"
    r"|network failure seems to have happened|could(?:n't| not) resolve host|connection reset by peer"
    r"|connection refused|connection timed out|operation timed out|timeout was reached|ssl connect error"
    r"|empty reply from server|failure when receiving data from the peer|error sending request"
    r"|http/2 stream \d+ was not closed cleanly|the remote end hung up unexpectedly|early eof"
    r"|\b(?:502|503|504) (?:bad gateway|service unavailable|gateway time-?out)",
    re.IGNORECASE)
TEST_STARTED = re.compile(r"^running \d+ tests?$", re.MULTILINE)
PASSED_SOME = re.compile(r"test result: ok\. [1-9][0-9]* passed")


def run_once(command: list[str], log: Path) -> int:
    """Runs COMMAND, its stdout and stderr streamed to our stdout and to LOG; returns its exit code."""
    with log.open("wb") as sink:
        proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        assert proc.stdout is not None
        for chunk in iter(lambda: proc.stdout.readline(), b""):
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            sink.write(chunk)
        return proc.wait()


def stale_lock(log: Path) -> bool:
    """cargo-locks.py explain printed the stale-lock cause and fix for LOG."""
    sys.stdout.flush()
    return subprocess.run([sys.executable, str(LOCKS), "explain", str(log)]).returncode == 0


def fetch_fault(text: str) -> bool:
    return not TEST_STARTED.search(text) and bool(FETCH_FAULTS.search(text))


def error(message: str) -> None:
    sys.stdout.flush()
    print(f"::error::{message}" if os.environ.get("GITHUB_ACTIONS") else f"error: {message}", file=sys.stderr,
          flush=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--log", required=True, type=Path, help="where the last run's output is kept")
    parser.add_argument("--attempts", type=int, default=3, help="runs in all when each is a fetch fault")
    parser.add_argument("--backoff", type=float, default=10.0, help="seconds times the attempt between runs")
    parser.add_argument("--require-tests", action="store_true", help="a run that passed no test is red")
    parser.add_argument("--what", default="the tests", help="the tests' name in messages")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.attempts < 1:
        parser.error("give a command after -- and --attempts of 1 or more")
    args.log.parent.mkdir(parents=True, exist_ok=True)

    for attempt in range(1, args.attempts + 1):
        status = run_once(command, args.log)
        text = args.log.read_text(encoding="utf-8", errors="replace")
        if status == 0:
            if args.require_tests and not PASSED_SOME.search(text):
                error(f"{args.what}: the run passed no test (the filter matched nothing)")
                return 1
            return 0
        if stale_lock(args.log):
            return status
        if not fetch_fault(text):
            error(f"{args.what} failed (exit {status}); a test failure is not run again")
            return status
        if attempt < args.attempts:
            print(f"{args.what}: a fetch fault failed attempt {attempt}/{args.attempts}; running again",
                  file=sys.stderr, flush=True)
            time.sleep(args.backoff * attempt)
    error(f"{args.what}: a fetch fault failed all {args.attempts} attempts (exit {status})")
    return status


if __name__ == "__main__":
    sys.exit(main())
