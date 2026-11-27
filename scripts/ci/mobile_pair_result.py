#!/usr/bin/env python3
"""Fail-closed transport/identify receipt validation for mobile-pair-skew.sh."""
import json
import os
from pathlib import Path
import sys


def validate(lines, status):
    bad = [f"dial exited {status}"] if status else []
    seen = set()
    for line in lines:
        if not line.lstrip().startswith("{"):
            continue
        try:
            row = json.loads(line)
            transport = row["transport"]
            if transport in seen or transport not in {"webrtc", "wireguard"}:
                bad.append(f"unexpected or repeated transport: {transport}")
            seen.add(transport)
            answers = [json.loads(a) for a in (row.get("daemon") or "").splitlines() if a.strip()]
            identify = next((a for a in answers if a.get("id") == 1), None)
            if row.get("error") or not (identify and identify.get("ok") is True):
                bad.append(f"{transport}: failed dial/identify: {row}")
        except (ValueError, TypeError, KeyError, AttributeError) as error:
            bad.append(f"malformed dial receipt: {error}")
    for transport in sorted({"webrtc", "wireguard"} - seen):
        bad.append(f"{transport}: missing transport receipt")
    return bad


def assertion_verdict(lines, status):
    bad = validate(lines, status)
    if not bad:
        return "success"
    # Incomplete/malformed receipts and killed or unlaunchable children are no verdict.
    if status in (124, 126, 127, 137) or status < 0:
        return ""
    rows = []
    try:
        for line in lines:
            if line.lstrip().startswith("{"):
                row = json.loads(line)
                if not isinstance(row, dict):
                    return ""
                rows.append(row)
        if len(rows) != 2 or {row["transport"] for row in rows} != {"webrtc", "wireguard"}:
            return ""
        failed = False
        for row in rows:
            answers = [json.loads(a) for a in (row.get("daemon") or "").splitlines() if a.strip()]
            if not all(isinstance(answer, dict) for answer in answers):
                return ""
            identify = next((a for a in answers if a.get("id") == 1), None)
            failed = failed or bool(row.get("error")) or not (identify and identify.get("ok") is True)
        return "failure" if failed else ""
    except (ValueError, TypeError, KeyError, AttributeError):
        return ""


def main():
    with open(sys.argv[1]) as source:
        lines = source.readlines()
    status = int(sys.argv[2])
    bad = validate(lines, status)
    if os.environ.get("SKEW_LOG_DIR"):
        Path(os.environ["SKEW_LOG_DIR"], "assertion-verdict").write_text(assertion_verdict(lines, status))
    for error in bad:
        print(f"::error::{error}")
    if not bad:
        print("ok: both transports exited successfully and answered identify")
    return bool(bad)


if __name__ == "__main__":
    sys.exit(main())
