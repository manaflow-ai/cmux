#!/usr/bin/env python3
"""scripts/measure/nightly-fresh-launch.py `--arms update`: the arm cmuxterm-hq's next-dogfood runs for
app_update_launch_ms (nightly_dogfood.update_launch_reading reads the `prewarm-update-moved` rows: before.main_start_at,
before.chromium_exit 0, then a launch that rendered Home). On 2026-11-20 the dogfood's call failed at argparse
("invalid choice: 'update'") because no such arm existed, and the row read STALE.

No Mac: the smoke module, the launches and the pre-warm runs are fakes. So this proves which arms run, with which
pre-warm, from which folder, NOT what a launch on a Mac measures.
Run: python3 -I scripts/measure/tests/nightly-fresh-launch-update-arm.test.py"""
import importlib.util, os, shutil, subprocess, tempfile, unittest
from pathlib import Path
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("nfl", os.path.join(HERE, "..", "nightly-fresh-launch.py"))
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)


class FakeSmoke:
    def __init__(self, root: Path):
        self.root = root

    def copy_app(self, source, root):
        dest = Path(root) / "app" / "cmux NIGHTLY.app"
        (dest / "Contents" / "MacOS").mkdir(parents=True)
        return dest

    class DefaultsAside:
        def __init__(self, *_):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

    def stop(self, *_):
        pass

    def own_pids(self, *_):
        return []


class UpdateArm(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="nfl-update-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.smoke = FakeSmoke(self.tmp)
        self.launched = []
        self.log_premain_flags = []

    def fake_launch(self, smoke, root, app, executable, home, seconds, label, sample=False, log_premain=False):
        self.launched.append((label, Path(app)))
        self.log_premain_flags.append(log_premain)
        return {"exit": None, "rendered_at": 3.0, "phases": {}, "marks": {"main_start": 50.0}, "repeats": []}

    def run_round(self, arms: str):
        more = {"update": M.UPDATE_ARMS, "prewarm": M.PREWARM_ARMS,
                "premain": M.PREMAIN_ARMS}[arms]
        chromium = subprocess.CompletedProcess([], 0, "loaded", "")
        with mock.patch.object(M, "launch", self.fake_launch), \
                mock.patch.object(M, "prewarm_until_main", return_value={"seconds": 0.4, "main_start_at": 0.3}), \
                mock.patch.object(M, "run_text", return_value="ok"), \
                mock.patch.object(M, "facts", return_value={}), \
                mock.patch.object(M.subprocess, "run", return_value=chromium):
            return M.round_once(self.smoke, Path("/Volumes/x/cmux NIGHTLY.app"), "com.cmuxterm.app.nightly", "cmux",
                                0.0, 1, {}, more=more, base=arms != "update", log_premain=arms == "premain")

    def test_update_runs_only_the_update_arm(self):
        rows = self.run_round("update")
        self.assertEqual([r["arm"] for r in rows], ["prewarm-update-moved"])
        self.assertEqual([label for label, _ in self.launched], ["measured"])

    def test_update_arm_has_the_fields_the_dogfood_reader_needs(self):
        row = self.run_round("update")[0]
        self.assertEqual(row["before"]["main_start_at"], 0.3)
        self.assertEqual(row["before"]["chromium_exit"], 0)
        self.assertEqual(row["rendered_at"], 3.0)
        self.assertIsNone(row["exit"])

    def test_update_arm_launches_the_copy_moved_out_of_its_staging_folder(self):
        self.run_round("update")
        _, app = self.launched[0]
        self.assertEqual(app.parent.name, "app")
        self.assertEqual(app.parent.parent.name, "placed")

    def test_other_modes_still_run_the_base_arms_first(self):
        rows = self.run_round("prewarm")
        self.assertEqual([r["arm"] for r in rows][:3], list(M.ARMS))
        self.assertNotIn("prewarm-update-moved", [r["arm"] for r in rows])

    def test_premain_streams_the_log_around_every_launch(self):
        rows = self.run_round("premain")
        self.assertEqual([r["arm"] for r in rows], list(M.ARMS) + list(M.PREMAIN_ARMS))
        self.assertTrue(self.log_premain_flags and all(self.log_premain_flags))

    def test_other_modes_keep_no_log_stream(self):
        self.run_round("prewarm")
        self.assertFalse(any(self.log_premain_flags))

    def test_the_cli_accepts_premain(self):
        with mock.patch.object(M, "load_smoke", side_effect=SystemExit(9)):
            with self.assertRaises(SystemExit) as raised:
                M.main(["--dmg", "x.dmg", "--out", str(self.tmp / "o"), "--arms", "premain", "--rounds", "1"])
        self.assertEqual(raised.exception.code, 9)

    def test_the_cli_accepts_update(self):
        with mock.patch.object(M, "load_smoke", side_effect=SystemExit(9)):
            with self.assertRaises(SystemExit) as raised:
                M.main(["--dmg", "x.dmg", "--out", str(self.tmp / "o"), "--arms", "update", "--rounds", "1"])
        self.assertEqual(raised.exception.code, 9)  # past argparse: an unknown choice exits 2 before load_smoke


class PageWait(unittest.TestCase):
    """2026-11-22 run 44973349615: the update arm ran with --seconds 0, the watch ended at Home's tab (~1 s), and the
    app was stopped before home.first_page, so update_launch_reading read "did not render Home with app marks"."""

    class Alive:
        def poll(self):
            return None

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="nfl-page-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.marks = self.tmp / "marks"
        self.marks.write_text("main_start 33.0\nfirst_window_frame_committed 624.6\n")
        self.read, self.write = os.pipe()
        os.set_blocking(self.read, False)
        self.addCleanup(os.close, self.read)

    def smoke(self):
        import types
        return types.SimpleNamespace(read_marks=lambda path: dict(
            (line.rpartition(" ")[0], float(line.rpartition(" ")[2])) for line in path.read_text().splitlines() if line))

    def test_waits_for_homes_page_mark(self):
        os.write(self.write, b"reveal.pane 883.3\nhome.first_page 2410.0\n")
        os.close(self.write)
        M.wait_for_page(self.smoke(), self.Alive(), self.read, self.marks, timeout=5)
        self.assertIn("home.first_page", self.smoke().read_marks(self.marks))

    def test_a_reveal_deadline_ends_it_too(self):
        self.assertTrue(M.page_shown({"reveal.home.by_deadline": 4000.0}))
        self.assertFalse(M.page_shown({"first_window_frame_committed": 624.6, "reveal.home": 700.0}))

    def test_gives_up_at_its_timeout_without_a_page(self):
        os.write(self.write, b"reveal.pane 883.3\n")
        M.wait_for_page(self.smoke(), self.Alive(), self.read, self.marks, timeout=0.3)
        os.close(self.write)
        self.assertNotIn("home.first_page", self.smoke().read_marks(self.marks))
        self.assertIn("reveal.pane", self.smoke().read_marks(self.marks))


if __name__ == "__main__":
    unittest.main()
