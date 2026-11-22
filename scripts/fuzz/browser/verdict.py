#!/usr/bin/env python3
"""The browser fuzz's verdict for the mini scheduler: reads a job log on stdin and prints one line,
PASS ..., FAIL ... or NOVERDICT ..., from the run's own last "BROWSER-FUZZ-VERDICT" line only.
A log without that line (a build that failed, a step that was cancelled, "done") is NOVERDICT."""
import re
import sys

last = None
for line in sys.stdin:
    match = re.search(r"BROWSER-FUZZ-VERDICT (PASS|FAIL|NOVERDICT)\b ?(.*)", line)
    if match:
        last = (match.group(1), match.group(2).strip())
if last is None:
    print("NOVERDICT the log has no BROWSER-FUZZ-VERDICT line (the build or the step did not finish)")
else:
    print(f"{last[0]} {last[1]}".strip())
