#!/usr/bin/env python3
"""The xbench template launch waits until the browser's first-run writes end (settle_template), so a launch
cloned from it measures idle, not first-run work. Before this file's fix the template slept a flat 45 s and
cmux NEXT's Chromium downloaded its components (60 s check, done by about 95 s) in every measured launch's
Home window: 23 to 62 MB of budget-idle-disk-writes-home (run 43649027609). Each test fails on xbench
before the fix (no settle_template; the template ended at 45 s whatever was still writing).
Run: python3 -I scripts/perf-bench/tests/test_settle_template.py"""
import os, sys, types, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
# procs.py loads /usr/lib/libproc.dylib at import (macOS only); nothing here reads a process, so an empty module
# stands in for it when the real one does not load, and is taken out again after the import.
_PROCS_STUB = None
try:
    import procs  # noqa: F401
except OSError:
    _PROCS_STUB = sys.modules["procs"] = types.ModuleType("procs")
try:
    import xbench  # noqa: E402
finally:
    if _PROCS_STUB is not None and sys.modules.get("procs") is _PROCS_STUB:
        del sys.modules["procs"]


class FakeProfile:
    """A clock and a profile tree whose files change at the given times (seconds after launch)."""

    def __init__(self, writes):
        self.t = 0.0
        self.writes = sorted(writes)

    def clock(self):
        return self.t

    def wait(self, seconds):
        self.t += seconds

    def states(self, _root):
        done = [(at, path) for at, path in self.writes if at <= self.t]
        tree = {}
        for at, path in done:
            tree[path] = (at, 1)
        return tree


class SettleTemplate(unittest.TestCase):
    def run_settle(self, writes, minimum=75.0):
        fake = FakeProfile(writes)
        took, writing = xbench.settle_template("/profile", minimum, clock=fake.clock, wait=fake.wait,
                                               states=fake.states)
        return took, writing

    def test_waits_past_first_run_writes(self):
        # run 43649027609's first-run writers: the component updater's downloads from 60 s on (Widevine,
        # CRL set, crx cache copies) until about 95 s.
        writes = [(53, "Preferences"), (61, "component_crx_cache/a"),
                  (70, "WidevineCdm/libwidevinecdm.dylib"), (82, "CertificateRevocation/crl-set"),
                  (95, "component_crx_cache/b")]
        took, writing = self.run_settle(writes)
        self.assertEqual(writing, [])
        self.assertGreaterEqual(took, 95 + xbench.TEMPLATE_QUIET_S)
        self.assertLess(took, xbench.TEMPLATE_MAX_S)

    def test_quiet_profile_ends_after_minimum_and_quiet_window(self):
        took, writing = self.run_settle([(5, "Preferences")])
        self.assertEqual(writing, [])
        self.assertAlmostEqual(took, 75 + xbench.TEMPLATE_QUIET_S)

    def test_minimum_outlasts_component_updater_check(self):
        # The 60 s component-updater check must fall inside even a quiet template's minimum (the
        # --template-settle default); the old flat 45 s ended before it.
        self.assertGreater(xbench.TEMPLATE_MIN_S, xbench.CHROMIUM_COMPONENT_CHECK_S)
        self.assertGreaterEqual(xbench.CHROMIUM_COMPONENT_CHECK_S, 60)

    def test_never_quiet_stops_at_cap_and_names_writers(self):
        writes = [(t, "Logs/chatty.log") for t in range(0, 1000, 3)]
        took, writing = self.run_settle(writes)
        self.assertLessEqual(took, xbench.TEMPLATE_MAX_S + xbench.TEMPLATE_POLL_S)
        self.assertGreaterEqual(took, xbench.TEMPLATE_MAX_S)
        self.assertEqual(writing, ["Logs/chatty.log"])


if __name__ == "__main__":
    unittest.main()
