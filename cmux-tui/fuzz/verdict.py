#!/usr/bin/env python3
"""Verdict of one cmux-tui/fuzz fleet run: reads the job log on stdin, prints one line.

The run's own line is `FUZZ-VERDICT <mode> PASS ...`, `... FAIL <reason>` or `... NOVERDICT <reason>`
(cmux-tui/fuzz/run-fleet.sh). No such line (the job died, timed out or never started the script) is
NOVERDICT: a finished job is not a pass."""
import re
import sys

found = None
for line in sys.stdin:
    match = re.search(r"FUZZ-VERDICT (\S+) (PASS|FAIL|NOVERDICT)\b ?(.*)", line)
    if match:
        found = match
if found is None:
    print("NOVERDICT no FUZZ-VERDICT line in the log")
else:
    mode, word, rest = found.groups()
    print(f"{word} {mode} {rest}".rstrip() if word != "PASS" else f"PASS {mode} {rest}".rstrip())
