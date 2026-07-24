#!/usr/bin/env python3
"""Print the cmux crash reports a run produced, and keep a copy of them.

macOS writes crash reports to one fixed per-user directory and gives no way to redirect it, so
a run cannot have its own. What a run can have is a snapshot taken before it starts: anything
cmux-named that appears afterwards belongs to it. That is a set difference, which beats
comparing timestamps — it survives a clock that jumped, a report written in another timezone,
and macOS rewriting mtimes when it prunes. Copying the matches into a per-run directory is what
makes the evidence outlive both the pruner and the job.

The test runner's "Restarting after unexpected exit, crash, or test timeout" line is the
event to grade a run on, because it is the runner noticing a host it has to replace. It
misses a crash with nothing left to restart — one during teardown, after the last verdict
has already printed. That crash is still an over-release, and without this the shard reads
clean.

A count of zero still is not proof that nothing crashed: ReportCrash writes the file
asynchronously, so a report can land after the scan. This backs the restart check up rather
than replacing it.

Usage:
  scripts/crash-reports-since.py --snapshot FILE               # before the run
  scripts/crash-reports-since.py --new-since FILE [--copy-to DIR]
  scripts/crash-reports-since.py '2026-07-23 17:40:00'         # timestamp fallback
  scripts/crash-reports-since.py --self-test

Prints one filename per line. Exit 0 whether or not anything is found; the caller decides what
a hit means. Exits non-zero only when the scan itself could not run, so a caller must not
swallow the status.
"""

from __future__ import annotations

import glob
import io
import json
import os
import shutil
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


def cmux_reports(directory: str = REPORT_DIR) -> list[str]:
    """Every cmux-named report currently in the directory."""
    hits = []
    for path in sorted(glob.glob(os.path.join(os.path.expanduser(directory), "*.ips"))):
        header = header_of(path)
        name = str(header.get("app_name") or header.get("procName") or "")
        if "cmux" in name.lower():
            hits.append(os.path.basename(path))
    return hits


def write_snapshot(snapshot: str, directory: str = REPORT_DIR) -> list[str]:
    names = cmux_reports(directory)
    with io.open(snapshot, "w", encoding="utf-8") as handle:
        handle.write("\n".join(names) + ("\n" if names else ""))
    return names


def new_since_snapshot(
    snapshot: str, directory: str = REPORT_DIR, copy_to: str | None = None
) -> list[str]:
    """Reports that appeared after the snapshot.

    A missing snapshot returns every cmux report in the directory rather than none. The shard
    writes the snapshot before the run, so its absence means something went wrong with the scan
    rather than that the run was clean, and the caller should see the reports and decide.
    """
    before: set[str] = set()
    if os.path.exists(snapshot):
        before = {
            line.strip()
            for line in io.open(snapshot, encoding="utf-8").read().splitlines()
            if line.strip()
        }
    fresh = [name for name in cmux_reports(directory) if name not in before]
    if copy_to and fresh:
        os.makedirs(copy_to, exist_ok=True)
        for name in fresh:
            src = os.path.join(os.path.expanduser(directory), name)
            try:
                shutil.copy2(src, os.path.join(copy_to, name))
            except OSError as error:
                print(f"warning: could not keep {name}: {error}", file=sys.stderr)
    return fresh


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

        # The snapshot path: what existed before a run must not be blamed on it, and what
        # appears during it must be kept somewhere the pruner cannot reach.
        with tempfile.TemporaryDirectory() as scratch:
            snapshot = os.path.join(scratch, "before.txt")
            write_snapshot(snapshot, directory)
            if new_since_snapshot(snapshot, directory) == []:
                print("  ok   a pre-existing crash is not blamed on the run")
            else:
                print("  FAIL a pre-existing crash was blamed on the run")
                failures += 1

            with io.open(os.path.join(directory, "cmux DEV-2026-07-23-235959.ips"), "w") as h:
                h.write(json.dumps({"app_name": "cmux DEV", "timestamp": "2026-07-23 23:59:59.00 -0700"}) + "\n")
                h.write("{}")
            kept = os.path.join(scratch, "kept")
            fresh = new_since_snapshot(snapshot, directory, copy_to=kept)
            if fresh == ["cmux DEV-2026-07-23-235959.ips"]:
                print("  ok   a crash during the run is attributed to it")
            else:
                print(f"  FAIL attribution returned {fresh}")
                failures += 1
            if os.path.isdir(kept) and os.listdir(kept) == fresh:
                print("  ok   the report is copied into the per-run directory")
            else:
                print("  FAIL the per-run copy is missing")
                failures += 1

            # A snapshot that was never written must not silently blame the run for history.
            missing = os.path.join(scratch, "never-written.txt")
            if new_since_snapshot(missing, directory) == cmux_reports(directory):
                print("  ok   a missing snapshot reports everything rather than nothing")
            else:
                print("  FAIL a missing snapshot did not fail loudly enough")
                failures += 1

    print("self-test passed" if not failures else f"self-test FAILED ({failures})")
    return 1 if failures else 0


def arg_after(flag: str) -> str | None:
    if flag in sys.argv:
        index = sys.argv.index(flag)
        if index + 1 < len(sys.argv):
            return sys.argv[index + 1]
    return None


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    snapshot = arg_after("--snapshot")
    if snapshot:
        kept = write_snapshot(snapshot)
        print(f"recorded {len(kept)} pre-existing cmux crash reports", file=sys.stderr)
        return 0

    new_since = arg_after("--new-since")
    if new_since:
        for name in new_since_snapshot(new_since, copy_to=arg_after("--copy-to")):
            print(name)
        return 0

    if len(sys.argv) < 2 or sys.argv[1].startswith("--"):
        print("usage: crash-reports-since.py --snapshot FILE | --new-since FILE | '<local time>'", file=sys.stderr)
        return 2
    for name in crashes_since(sys.argv[1]):
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
