#!/usr/bin/env python3
"""ReadFirstUITests' READFIRST lines in, NETCOND rows out (ios-network-conditions.sh leg=sim).

Reads a fleet simulator evidence folder or evidence.zip (cmux-next-ios-sim.sh test
ui=ReadFirstUITests,ReadFirstColdUITests): ui-console.txt and ui-cold/*-console.txt, each one
preferring its attachments folder (the same sample can be in both, as ios_launch_samples.py reads
them). Each READFIRST {tap, phase, r1_ms, r2_ms} becomes up to two NETCOND rows, surface
`sim:<tap>`, profile `offline-sim@1` (no Mac reachable), scale 1x, metric r1_ms and r2_ms; a null
is a miss. Prints `after {json}` lines, the form ios-network-conditions-report.py reads.
"""

from __future__ import annotations

import json
import re
import sys
import tempfile
import zipfile
from pathlib import Path

PATTERN = re.compile(r"READFIRST (\{.*\})")


def samples(path: Path) -> list[dict]:
    rows = []
    for line in path.read_text(errors="replace").splitlines():
        match = PATTERN.search(line)
        if match:
            try:
                rows.append(json.loads(match.group(1)))
            except json.JSONDecodeError:
                print(f"ios-read-first-rows: skipped a bad line in {path}", file=sys.stderr)
    return rows


def collect(out: Path) -> list[dict]:
    rows = []
    consoles = sorted(out.rglob("ui-console.txt")) + sorted(out.rglob("ui-cold/*-console.txt"))
    for console in consoles:
        attachments = console.with_name(console.name.removesuffix("-console.txt").removesuffix(".txt") + "-attachments")
        attached = [row for path in sorted(attachments.rglob("*.txt")) for row in samples(path)] if attachments.is_dir() else []
        rows.extend(attached if attached else samples(console))
    return rows


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: ios-read-first-rows.py EVIDENCE_DIR_OR_ZIP", file=sys.stderr)
        return 2
    source = Path(sys.argv[1])
    with tempfile.TemporaryDirectory() as tmp:
        if source.is_file():
            with zipfile.ZipFile(source) as archive:
                archive.extractall(tmp)
            source = Path(tmp)
        rows = collect(source)
    if not rows:
        print(f"ios-read-first-rows: no READFIRST lines under {sys.argv[1]}", file=sys.stderr)
        return 1
    runs: dict[tuple, int] = {}
    for row in rows:
        key = (row.get("tap"), row.get("phase"))
        runs[key] = runs.get(key, 0) + 1
        for metric in ("r1_ms", "r2_ms"):
            print("after " + json.dumps({"surface": f"sim:{row.get('tap')}", "profile": "offline-sim@1",
                                         "phase": row.get("phase"), "scale": "1x", "metric": metric,
                                         "value": row.get(metric), "run": runs[key], "seed": 0}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
