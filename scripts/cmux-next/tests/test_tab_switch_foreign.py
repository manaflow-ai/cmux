"""tab_switch_foreign.py: which windows count as covering the measured app, which rounds are left out of the settled
stats, and the run's own setup (crash dialog off and restored, the run's settings file). The 2026-11-17 NIGHTLY run
measured through a crash dialog, a Keychain prompt and a notification banner (Leo: "infinite everything feels like
nothing"; the settled column was invalid)."""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import tab_switch_foreign as foreign  # noqa: E402
import tab_switch_frames as tsf  # noqa: E402
import tab_switch_judge as judge  # noqa: E402
import tab_switch_settle as settle  # noqa: E402

APP_PID, MARKER_PID = 100, 101
WINDOW = [40, 40, 1000, 600]  # the app window, global points
SCALE = 0.48  # recorded pixels per point (480 px wide recording of 1000 points)
CONTENT = (100, 20, 480, 280)  # px, relative to the window
SIDEBAR = (0, 0, 90, 288)


def win(owner, bounds, pid=200, alpha=1.0, layer=0):
    return {"owner": owner, "pid": pid, "alpha": alpha, "layer": layer, "bounds": bounds}


class Geometry(unittest.TestCase):
    def test_bounds_become_window_relative_pixels(self):
        self.assertEqual(foreign.rect_of_bounds([140, 140, 100, 50], WINDOW, 0.5), (50.0, 50.0, 100.0, 75.0))

    def test_overlap_is_area_and_touching_is_none(self):
        self.assertEqual(foreign.overlap((0, 0, 10, 10), (5, 5, 20, 20)), 25)
        self.assertEqual(foreign.overlap((0, 0, 10, 10), (10, 0, 20, 10)), 0)  # shares an edge only
        self.assertEqual(foreign.overlap((0, 0, 10, 10), (50, 50, 60, 60)), 0)


class WhichWindowsCount(unittest.TestCase):
    def over(self, windows, rects=(CONTENT, SIDEBAR)):
        return foreign.foreign_over(windows, {APP_PID, MARKER_PID}, rects, WINDOW, SCALE)

    def test_a_crash_dialog_over_the_content_counts(self):
        found = self.over([win("UserNotificationCenter", [400, 300, 400, 200])])
        self.assertEqual([w["owner"] for w in found], ["UserNotificationCenter"])

    def test_a_banner_over_only_the_sidebar_counts(self):
        found = self.over([win("NotificationCenter", [45, 60, 120, 60], layer=23)])
        self.assertEqual([w["owner"] for w in found], ["NotificationCenter"])

    def test_the_apps_own_and_the_markers_windows_do_not(self):
        self.assertEqual(self.over([win("cmux NIGHTLY", [40, 40, 1000, 600], pid=APP_PID),
                                    win("tab-switch-tools", [40, 40, 24, 24], pid=MARKER_PID)]), [])

    def test_system_furniture_and_invisible_windows_do_not(self):
        everywhere = [40, 40, 1000, 600]
        for owner in foreign.IGNORED_OWNERS:
            self.assertEqual(self.over([win(owner, everywhere)]), [], owner)
        self.assertEqual(self.over([win("Anything", everywhere, alpha=0.0)]), [])
        self.assertEqual(self.over([win("Anything", [100, 100, 1, 500])]), [])  # a hairline

    def test_the_recorders_cursor_overlay_does_not(self):
        # The overlay's real CGWindowList owner name has a space; the old list named only CuaDriver and cua-driver.
        self.assertEqual(self.over([win("Cua Driver", [40, 40, 1000, 600], layer=25)]), [])

    def test_only_windows_above_the_apps_window_count(self):
        # CGWindowList is front to back: a banner before the app's window covers it; Finder's desktop and
        # WindowManager's strip after it are behind it, though their bounds overlap the content.
        app = win("cmux NIGHTLY", WINDOW, pid=APP_PID)
        marker = win("tab-switch-tools", [0, 0, 24, 24], pid=MARKER_PID, layer=25)
        banner = win("NotificationCenter", [400, 300, 300, 100], layer=23)
        behind = [win("Finder", [0, 0, 2000, 1200]), win("WindowManager", [40, 200, 80, 300])]
        found = self.over([marker, banner, app, *behind])
        self.assertEqual([w["owner"] for w in found], ["NotificationCenter"])
        self.assertEqual(self.over([marker, app, *behind]), [])
        # A window between the marker and the app's window still counts: the marker is not the app's window.
        self.assertEqual([w["owner"] for w in self.over([marker, banner, app])], ["NotificationCenter"])

    def test_a_sample_without_the_apps_window_keeps_every_window(self):
        found = self.over([win("Finder", [0, 0, 2000, 1200]), win("cmux NIGHTLY", [40, 40, 30, 30], pid=APP_PID)])
        self.assertEqual([w["owner"] for w in found], ["Finder"])

    def test_a_window_outside_the_measured_rects_does_not(self):
        # Over the window's top band (above the content, right of the sidebar) and off the window: no measured rect.
        above = [300, 40, 200, 8]  # y 40..48 points = 0..3.8 px, content starts at 20 px
        self.assertEqual(self.over([win("Other", above), win("Other", [2000, 40, 100, 100])]), [])

    def test_a_missing_sidebar_leaves_the_content_checked(self):
        self.assertEqual(self.over([win("Other", [45, 60, 120, 60])], rects=(CONTENT, None)), [])
        self.assertEqual(len(self.over([win("Other", [400, 300, 100, 100])], rects=(CONTENT, None))), 1)


class RoundsInTime(unittest.TestCase):
    def log(self):
        log = foreign.ForeignLog({APP_PID, MARKER_PID}, WINDOW, SCALE)
        log.add(1.0, [win("cmux NIGHTLY", [40, 40, 1000, 600], pid=APP_PID)])
        log.add(5.0, [win("securityd", [400, 300, 300, 150])])
        log.add(5.2, [win("securityd", [400, 300, 300, 150]), win("NotificationCenter", [45, 60, 120, 60])])
        log.add(9.0, [])
        return log

    def test_only_samples_in_the_span_count(self):
        log = self.log()
        self.assertEqual(log.between(0.0, 4.9, [CONTENT, SIDEBAR]), [])
        self.assertEqual(foreign.owners(log.between(4.0, 6.0, [CONTENT, SIDEBAR])), ["securityd", "NotificationCenter"])
        self.assertEqual(log.between(6.0, 10.0, [CONTENT, SIDEBAR]), [])

    def test_the_apps_own_windows_are_never_kept(self):
        self.assertEqual(self.log().samples[0][1], [])

    def test_a_window_behind_the_app_is_never_kept(self):
        log = foreign.ForeignLog({APP_PID, MARKER_PID}, WINDOW, SCALE)
        log.add(1.0, [win("securityd", [400, 300, 300, 150]), win("cmux NIGHTLY", WINDOW, pid=APP_PID),
                      win("Finder", [0, 0, 2000, 1200]), win("WindowManager", [40, 200, 80, 300])])
        self.assertEqual(foreign.owners(log.samples[0][1]), ["securityd"])
        self.assertEqual(foreign.owners(log.between(0.0, 2.0, [CONTENT, SIDEBAR])), ["securityd"])

    def test_exclude_splits_the_rounds(self):
        log = self.log()
        spans = {"a": (0.0, 2.0), "b": (4.0, 6.0), "c": (8.0, 10.0)}
        switches = [{"label": k} for k in spans]
        kept, lost = foreign.exclude(switches, lambda s: log.between(*spans[s["label"]], [CONTENT, SIDEBAR]))
        self.assertEqual([s["label"] for s in kept], ["a", "c"])
        self.assertEqual([(x["label"], x["foreign_window"]) for x in lost], [("b", "securityd+NotificationCenter")])


class RunGate(unittest.TestCase):
    def rows(self, kept, excluded):
        return [{"switches": [{}] * kept, "excluded": [{"foreign_window": "securityd"}] * excluded}]

    def test_twenty_percent_passes_and_more_fails(self):
        self.assertFalse(foreign.too_many(self.rows(8, 2)))   # 20%: at the limit
        self.assertTrue(foreign.too_many(self.rows(7, 3)))    # 30%
        self.assertFalse(foreign.too_many(self.rows(10, 0)))
        self.assertFalse(foreign.too_many([]))
        self.assertEqual(foreign.by_owner(self.rows(7, 3)), {"securityd": 3})

    def test_excluded_rounds_are_in_no_stat_and_counted_in_the_table(self):
        good = {"label": "x", "to_content_ms": 80, "settled_ms": 100, "changed_after_first": 0}
        covered = {"label": "y", "foreign_window": "securityd", "windows": []}
        row = judge.scenario_row("terminal-return", "L0", [good, covered])
        self.assertEqual(len(row["switches"]), 1)
        self.assertEqual(row["excluded"][0]["foreign_window"], "securityd")
        line = settle.table([row])[0]
        self.assertEqual((line["n"], line["excluded"], line["settled_p50"]), (1, 1, 100))
        self.assertIn("| terminal-return | L0 | 1 | 1 |", settle.table_markdown([line]))

    def test_a_row_with_every_round_excluded_says_why(self):
        row = judge.scenario_row("new-tab", "L0", [{"label": "y", "foreign_window": "securityd"}])
        self.assertEqual(row["switches"], [])
        self.assertIn("1 excluded: foreign window", row["budget_fail"][0])


class RunSetup(unittest.TestCase):
    def fake(self, existing):
        calls = []

        def run(argv, **_kw):
            calls.append(argv[1:])
            code, out = (0, existing + "\n") if argv[1] == "read" and existing is not None else (1, "")
            return subprocess.CompletedProcess(argv, code, out, "")
        return run, calls

    def test_crash_dialog_off_then_the_old_value_back(self):
        run, calls = self.fake("crashreport")
        with foreign.CrashDialogOff(run):
            self.assertEqual(calls[-1], ["write", "com.apple.CrashReporter", "DialogType", "none"])
        self.assertEqual(calls[-1], ["write", "com.apple.CrashReporter", "DialogType", "crashreport"])

    def test_crash_dialog_key_removed_when_it_was_unset(self):
        run, calls = self.fake(None)
        with foreign.CrashDialogOff(run):
            pass
        self.assertEqual(calls[-1], ["delete", "com.apple.CrashReporter", "DialogType"])

    def test_crash_dialog_restored_when_the_run_raises(self):
        run, calls = self.fake(None)
        with self.assertRaises(RuntimeError):
            with foreign.CrashDialogOff(run):
                raise RuntimeError("boom")
        self.assertEqual(calls[-1][0], "delete")

    def test_crash_reports_since_the_run_started(self):
        with tempfile.TemporaryDirectory() as folder:
            old = Path(folder, "Python-2026-11-16-000000.ips")
            old.write_text('{"procPath": "/old"}')
            os.utime(old, (time.time() - 3600, time.time() - 3600))
            new = Path(folder, "Python-2026-11-17-040000.ips")
            new.write_text('{"app_name":"Python"}\n  "procPath" : "/usr/bin/python3",\n')
            found = foreign.crash_reports(folder, time.time() - 60)
            self.assertEqual([(r["file"], r["process"]) for r in found], [("Python-2026-11-17-040000.ips", "Python")])
            self.assertEqual(found[0]["path"], "/usr/bin/python3")

    def test_the_runs_settings_turn_off_banners_and_the_hang_card_in_its_own_home(self):
        with tempfile.TemporaryDirectory() as home:
            path = tsf.write_run_settings(Path(home))
            self.assertEqual(path, Path(home, ".config/cmux/cmux-next.json"))
            data = json.loads(path.read_text())
            self.assertEqual(data["notifications"]["desktop"], "never")
            self.assertIs(data["diagnostics"]["hangReports"], False)


if __name__ == "__main__":
    unittest.main()
