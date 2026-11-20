#!/usr/bin/env python3
"""Run one CI step's command and end it when it prints nothing for too long.

A job's `timeout-minutes` is the only bound most steps have, so a step that
hangs silently holds its runner until that cap: the perf cron plan step printed
nothing for 74 minutes and was cancelled at its 75-minute job cap (run
44731310755, 2026-11-20). This wrapper streams the command's output unchanged
and, after `--silent-seconds` with no output on stdout or stderr, prints the
last lines it saw and the processes in the step's group, kills the whole
process group, writes one `::error title=Silent step: LABEL::` annotation and
exits SILENT_EXIT (97), a code no tool here uses, so a caller and a log reader
tell a silent hang from a failure or from the whole-step `--timeout-seconds`
(124). The command's own exit status passes through otherwise.

The command's stdout and stderr are a pipe, as the runner gives a step, so a
tool that checks for a terminal (bun, vite, cargo) behaves as it does without
the wrapper. `--pty` runs it on a pseudo-terminal instead (TERM=dumb,
NO_COLOR=1), for a Python step whose prints would otherwise sit in a pipe
buffer and read as silence.

Pick N from the step's measured longest silent gap times two
(step_silence_gaps.py reads it from past job logs); a step that is quiet on
purpose (a long wait) prints a heartbeat inside N.

    python3 scripts/ci/step_watchdog.py --silent-seconds 600 --label "perf cron plan" -- \\
      python3 -I scripts/cmux-next/perf-cron.py plan ...
"""

from __future__ import annotations

import argparse
import shlex
import sys
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

import hung_test_watchdog  # noqa: E402

SILENT_EXIT = 97
DEFAULT_TAIL_LINES = 30


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--silent-seconds", type=float, required=True,
                        help="end the step after this long with no output (the step's longest healthy gap x 2)")
    parser.add_argument("--timeout-seconds", type=float, default=0,
                        help="also end it after this long in total (0: only the job's cap); exits 124")
    parser.add_argument("--label", help="the step's name for the annotation; defaults to the command")
    parser.add_argument("--tail-lines", type=int, default=DEFAULT_TAIL_LINES,
                        help=f"lines of output to repeat when it fires (default {DEFAULT_TAIL_LINES})")
    parser.add_argument("--sample-seconds", type=int, default=3,
                        help="seconds of macOS `sample` per process in the group when it fires (0: none)")
    parser.add_argument("--log", type=Path, help="also write the command's output here")
    parser.add_argument("--pty", action="store_true",
                        help="run it on a pseudo-terminal (line-buffered Python output) instead of a pipe")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    if args.silent_seconds <= 0:
        parser.error("--silent-seconds must be positive")
    if min(args.timeout_seconds, args.tail_lines, args.sample_seconds) < 0:
        parser.error("--timeout-seconds, --tail-lines and --sample-seconds must not be negative")
    if args.log:
        args.log.parent.mkdir(parents=True, exist_ok=True)
    return hung_test_watchdog.run(
        command,
        label=args.label or shlex.join(command)[:120],
        silence_seconds=args.silent_seconds,
        timeout_seconds=args.timeout_seconds,
        sample_seconds=args.sample_seconds,
        log_path=args.log,
        step=True,
        tail_lines=args.tail_lines,
        silence_exit=SILENT_EXIT,
        use_pty=args.pty,
    )


if __name__ == "__main__":
    raise SystemExit(main())
