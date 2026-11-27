#!/usr/bin/env python3
"""Reads a restore-fuzz or acpmux-fuzz job log on stdin and prints one line: PASS, FAIL <reason> or NOVERDICT <reason>.

The verdict comes only from the oracle's own lines (`RESTORE-FUZZ SUMMARY ...` / `FUZZ-G SUMMARY ...` and their
VIOLATION lines), never from an exit code or a "done" (fuzz catalog shared rule 5).
"""
import re
import sys


def verdict(text):
    summaries = re.findall(r"^.*(?:RESTORE-FUZZ|FUZZ-G) SUMMARY .*$", text, re.M)
    if not summaries:
        return "NOVERDICT the log has no SUMMARY line of the oracle"
    last = summaries[-1]
    found = re.search(r"violations=(\d+)", last)
    if not found:
        return "NOVERDICT the SUMMARY line has no violations count"
    if int(found.group(1)):
        first = re.search(r"^.*(?:RESTORE-FUZZ|FUZZ-G) VIOLATION (.*)$", text, re.M)
        return f"FAIL {found.group(1)} violation(s): {(first.group(1) if first else last)[:300]}"
    if "RESTORE-FUZZ SUMMARY" in last:
        judged = re.search(r"judged=(\d+)", last)
        if not judged or not int(judged.group(1)):
            return "NOVERDICT no iteration was judged"
        kills = re.search(r"kills=(\{[^}]*\})", last)
        if kills and kills.group(1) == "{}":
            return "NOVERDICT no iteration killed anything (only refusals or not-run iterations)"
        lost = re.search(r"chaos_lost=(\d+)", last)
        if lost and int(lost.group(1)):
            return "NOVERDICT the chaos process ended early"
    else:
        ops = re.search(r"ops=(\d+)", last)
        if not ops or not int(ops.group(1)):
            return "NOVERDICT the SUMMARY line has no operations"
    return "PASS"


if __name__ == "__main__":
    print(verdict(sys.stdin.read()))
