#!/usr/bin/env python3
"""Verdict of a scripts/measure/idle-cpu.sh step from its log on stdin (mini scheduler; idle-cpu-run.py).
PASS / FAIL from the step's last IDLE-CPU-VERDICT line (pass / fail with the processes over budget);
NOVERDICT when it says cannot-run or has none (the app never rendered, the download failed). One line."""
import os
import re
import sys

text = sys.stdin.read()
lines = re.findall(r"^IDLE-CPU-VERDICT (\S+)(.*)$", text, re.M)
kinds = re.findall(r"^IDLE-CPU-KIND (\S+) n=\d+ cpu_pct=(\S+) wakeups_per_s=(\S+)", text, re.M)
summary = ", ".join(f"{k} {c}% {w}/s" for k, c, w in kinds if k.startswith(("acpmux", "tui-daemon", "app")))[:300]
if not lines:
    print("NOVERDICT no IDLE-CPU-VERDICT line (download, launch or idle did not finish)")
elif lines[-1][0] == "pass" and os.environ.get("MINI_JOB_EXIT", "0") == "0":
    print(f"PASS idle within budget{lines[-1][1][:200]}; {summary}")
elif lines[-1][0] == "fail":
    print(f"FAIL{lines[-1][1][:300]}; {summary}")
elif lines[-1][0] == "pass":
    print(f"NOVERDICT the step said pass but exited {os.environ.get('MINI_JOB_EXIT')}")
else:
    print(f"NOVERDICT {lines[-1][0]}{lines[-1][1][:200]}")
