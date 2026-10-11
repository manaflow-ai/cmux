"""readiness-soak.py counts only its own app copy's crash reports.

The soak runs on capture minis, where other tagged builds crash into the same
~/Library/Logs/DiagnosticReports (the 2026-10-11 cua-2 soak failed on 9 reports, none of them
its app's). A report is the soak's when its header names the copy's bundle ID or its process is
one the soak saw (the app, its daemon, acpmux).
"""

import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).parents[2]

# The soak reads macOS process stats (libproc) at import; its helpers are not under test.
for name, attrs in {
    "bench_idle": ("Client", "process_table", "usage"),
    "daemon_teardown": ("daemon_status", "request", "terminal_hosts"),
    "tag_teardown": ("TagTeardown",),
}.items():
    sys.modules.setdefault(name, types.SimpleNamespace(**{attr: None for attr in attrs}))
SPEC = importlib.util.spec_from_file_location("readiness_soak", ROOT / "scripts" / "cmux-next" / "readiness-soak.py")
soak_module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(soak_module)

SOAK_BUNDLE = "com.cmuxterm.app.debug.soak"


def write_report(directory, name, header, pid, mtime, parent=1, body=None):
    path = os.path.join(directory, name)
    with open(path, "w") as handle:
        handle.write(json.dumps(header) + "\n")
        handle.write(body if body is not None else json.dumps(
            {"pid": pid, "parentPid": parent, "procPath": "/Users/USER/*/x", "threads": []}))
    os.utime(path, (mtime, mtime))
    return path


class CrashReportTests(unittest.TestCase):
    def test_counts_only_the_soak_copys_reports(self):
        with tempfile.TemporaryDirectory() as home:
            reports = os.path.join(home, "Library", "Logs", "DiagnosticReports")
            os.makedirs(reports)
            started = 1_800_000_000
            after = started + 60
            # Another lane's tagged build on the same capture mini.
            write_report(reports, "cmux DEV-2026-10-11-035305.ips",
                         {"bundleID": "com.cmuxterm.app.debug.hcomb.capslot1", "app_name": "cmux DEV"}, 81950, after)
            # A report from before the soak, rewritten after it started.
            write_report(reports, "cmux DEV-2026-10-10-183016.ips",
                         {"bundleID": "com.cmuxterm.app.debug.sweep5.capslot2", "app_name": "cmux DEV"}, 91891, after)
            # Another copy's acpmux.
            write_report(reports, "acpmux-2026-10-11-090000.ips", {"app_name": "acpmux"}, 999, after)
            ours_app = write_report(reports, "cmux DEV-2026-10-11-120000.ips",
                                    {"bundleID": SOAK_BUNDLE, "app_name": "cmux DEV"}, 56604, after)
            ours_daemon = write_report(reports, "cmux-tui-2026-10-11-130000.ips", {"app_name": "cmux-tui"}, 56650, after)
            # One of the soak's terminal hosts (a cmux-tui process the soak saw).
            ours_host = write_report(reports, "cmux-tui-2026-10-11-140000.ips", {"app_name": "cmux-tui"}, 56700, after)
            # A helper the app started and that crashed before any sample saw it.
            ours_helper = write_report(reports, "cmux DEV Helper-2026-10-11-150000.ips",
                                       {"bundleID": "com.cmuxterm.app.debug.soak.helper"}, 60001, after, parent=56604)
            # This copy's report whose body is not JSON: the header alone says whose it is.
            ours_header_only = write_report(reports, "cmux DEV-2026-10-11-160000.ips", {"bundleID": SOAK_BUNDLE},
                                            0, after, body="not json")
            # This copy's report from an earlier run.
            write_report(reports, "cmux DEV-2026-10-09-120000.ips", {"bundleID": SOAK_BUNDLE}, 100, started - 3600)

            soak = soak_module.Soak.__new__(soak_module.Soak)
            soak.started = started
            soak.bundle_id = SOAK_BUNDLE
            soak.seen_pids = {56604, 56650, 56700}
            soak.app_pid = 56604
            with mock.patch.dict(os.environ, {"HOME": home}):
                self.assertEqual(soak.crash_reports(), sorted([ours_app, ours_daemon, ours_host, ours_helper, ours_header_only]))


if __name__ == "__main__":
    unittest.main()
