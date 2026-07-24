#!/usr/bin/env python3
"""Print the cmux crash reports written since a given local time.

The test runner's "Restarting after unexpected exit, crash, or test timeout" line is the
event to grade a run on, because it is the runner noticing a host it has to replace. It
misses a crash with nothing left to restart — one during teardown, after the last verdict
has already printed. That crash is still an over-release, and without this the shard reads
clean.

Reports are matched on the timestamp inside the report's own JSON header, not the file's
mtime: macOS rewrites those mtimes when it prunes the directory, so an mtime window silently
loses reports. Pruning also means a count of zero is not proof that nothing crashed, which
is why this backs up the restart check rather than replacing it.

Usage:
  scripts/crash-reports-since.py '2026-07-23 17:40:00'   # prints one filename per line
  scripts/crash-reports-since.py --self-test             # verify against known fixtures

Exit 0 whether or not anything is found; the caller decides what a hit means.
"""

from __future__ import annotations

import glob
import io
import json
import os
import sys
import tempfile

REPORT_DIR = "~/Library/Logs/DiagnosticReports"


def header_of(path: str) -> dict:
    """An .ips file is a JSON header line followed by a separate JSON body."""
    with io.open(path, encoding="utf-8", errors="replace") as handle:
        try:
            return json.loads(handle.readline())
        except json.JSONDecodeError:
            return {}


def crashes_since(since: str, directory: str = REPORT_DIR) -> list[str]:
    hits = []
    for path in sorted(glob.glob(os.path.join(os.path.expanduser(directory), "*.ips"))):
        header = header_of(path)
        name = str(header.get("app_name") or header.get("procName") or "")
        if "cmux" not in name.lower():
            continue
        # Header timestamps look like "2026-07-23 17:44:22.00 -0700"; compare the
        # second-resolution prefix, which sorts correctly as text in local time.
        if str(header.get("timestamp", ""))[:19] >= since:
            hits.append(os.path.basename(path))
    return hits


def self_test() -> int:
    """Check the filter against reports whose answers are known by construction."""
    fixtures = {
        "cmux DEV-2026-07-23-174422.ips": ("cmux DEV", "2026-07-23 17:44:22.00 -0700"),
        "cmux DEV-2026-07-23-100000.ips": ("cmux DEV", "2026-07-23 10:00:00.00 -0700"),
        "Safari-2026-07-23-180000.ips": ("Safari", "2026-07-23 18:00:00.00 -0700"),
    }
    with tempfile.TemporaryDirectory() as directory:
        for name, (app, stamp) in fixtures.items():
            body = {"faultingThread": 0, "threads": []}
            with io.open(os.path.join(directory, name), "w", encoding="utf-8") as handle:
                handle.write(json.dumps({"app_name": app, "timestamp": stamp}) + "\n")
                handle.write(json.dumps(body))
        # A junk file must not crash the scan.
        with io.open(os.path.join(directory, "truncated.ips"), "w", encoding="utf-8") as handle:
            handle.write("not json at all\n")

        cases = [
            ("2026-07-23 17:00:00", ["cmux DEV-2026-07-23-174422.ips"]),
            ("2026-07-23 09:00:00", [
                "cmux DEV-2026-07-23-100000.ips",
                "cmux DEV-2026-07-23-174422.ips",
            ]),
            ("2026-07-23 19:00:00", []),
        ]
        failures = 0
        for since, expected in cases:
            got = crashes_since(since, directory)
            ok = got == expected
            failures += 0 if ok else 1
            print(f"  {'ok  ' if ok else 'FAIL'} since {since} -> {got}")
            if not ok:
                print(f"       expected {expected}")
        # Safari must never appear, at any window.
        if any("Safari" in name for name in crashes_since("2026-01-01 00:00:00", directory)):
            print("  FAIL a non-cmux crash was counted")
            failures += 1
        else:
            print("  ok   a non-cmux crash is ignored")
    print("self-test passed" if not failures else f"self-test FAILED ({failures})")
    return 1 if failures else 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[-3].strip(), file=sys.stderr)
        return 2
    for name in crashes_since(sys.argv[1]):
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
