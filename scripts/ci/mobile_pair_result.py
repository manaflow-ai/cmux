#!/usr/bin/env python3
"""Fail-closed transport/identify receipt validation for mobile-pair-skew.sh."""
import json
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


def main():
    with open(sys.argv[1]) as source:
        bad = validate(source, int(sys.argv[2]))
    for error in bad:
        print(f"::error::{error}")
    if not bad:
        print("ok: both transports exited successfully and answered identify")
    return bool(bad)


if __name__ == "__main__":
    sys.exit(main())
