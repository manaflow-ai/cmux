#!/usr/bin/env python3
"""scripts/measure/nightly-fresh-launch.py `--arms update`: the arm `prewarm-update-moved` runs what an updating
person's staged copy gets (CmuxNextUpdater StagedUpdatePrewarm), in its order: the executable to main_start, the bundled
`cmux` and `cmux-tui` --version, each Chromium helper --version, every Frameworks page, the executable with
--cmux-prewarm-chromium; then the copy is renamed into place and launched. cmuxterm-hq's nightly dogfood reads this
arm's launch into NOW's "NEXT update launch to Home, prewarmed copy" row.

No Mac, no app: the copy is a folder of empty files and every run, read and launch is replaced by a recorder. So this
proves the order of the pre-warm's steps and that the launch is of the renamed copy, NOT what they cost on a Mac.
Run: python3 -I scripts/measure/tests/nightly-fresh-launch-update-arm.test.py"""
import contextlib, importlib.util, os, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("nightly_fresh_launch", HERE.parent / "nightly-fresh-launch.py")
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)
REAL_MKDTEMP = tempfile.mkdtemp


class FakeSmoke:
    """The few fresh_home_launch_smoke calls extra_arm makes: a copy is a folder of empty files under DEST."""

    def __init__(self, source: Path):
        self.source = source

    def copy_app(self, mount_app: Path, dest: Path) -> Path:
        app = dest / mount_app.name
        shutil.copytree(mount_app, app)
        return app

    def DefaultsAside(self, bundle_id, root):
        return contextlib.nullcontext()

    def own_pids(self, root):
        return []

    def stop(self, pids):
        pass


class UpdateArm(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="nfl-update-arm-"))
        app = self.tmp / "mnt" / "cmux.app" / "Contents"
        for rel in ("MacOS/cmux", "Resources/bin/cmux", "Resources/bin/cmux-tui",
                    "Frameworks/cmux Helper.app/Contents/MacOS/cmux Helper",
                    "Frameworks/cmux Helper (GPU).app/Contents/MacOS/cmux Helper (GPU)",
                    "Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp"):
            (app / rel).parent.mkdir(parents=True, exist_ok=True)
            (app / rel).write_bytes(b"x")
        self.mount_app = app.parent
        self.ran = []

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def short(self, path) -> str:
        return str(path).split("cmux.app/", 1)[-1] if "cmux.app/" in str(path) else Path(path).name

    def test_the_update_arm_prewarms_in_the_updaters_order_then_launches_the_renamed_copy(self):
        def prewarm_until_main(smoke, root, app, executable, home_root):
            self.ran.append(("main", self.short(app / "Contents" / "MacOS" / executable)))
            return {"seconds": 0.5, "main_start_at": 0.4}

        def run_text(args, timeout=120):
            self.ran.append(("version", self.short(args[0]), args[1]))
            return "1.0"

        def touch_pages(root):
            self.ran.append(("pages", root.name))
            return {"files": 1, "pages": 1, "seconds": 0.1}

        def run(args, **_):
            self.ran.append(("chromium", self.short(args[0]), args[1]))
            return subprocess.CompletedProcess(args, 0, "", "")

        def launch(smoke, root, app, executable, home_root, seconds, name, sample=False):
            self.ran.append(("launch", app.parent.parent.name, name))
            return {"exit": None, "rendered_at": 1.3, "host": None,
                    "phases": {"pre_main": 60.0, "page": 1281.0}, "marks": {}, "repeats": []}

        with mock.patch.object(M, "prewarm_until_main", prewarm_until_main), mock.patch.object(M, "run_text", run_text), \
                mock.patch.object(M, "touch_pages", touch_pages), mock.patch.object(M.subprocess, "run", run), \
                mock.patch.object(M, "launch", launch), mock.patch.object(M.tempfile, "mkdtemp",
                                                                          lambda **_: REAL_MKDTEMP(dir=self.tmp)):
            row = M.extra_arm(FakeSmoke(self.mount_app), self.mount_app, "com.example", "cmux", 8.0,
                              "prewarm-update-moved")
        self.assertEqual(self.ran, [
            ("main", "Contents/MacOS/cmux"),
            ("version", "Contents/Resources/bin/cmux", "--version"),
            ("version", "Contents/Resources/bin/cmux-tui", "--version"),
            ("version", "Contents/Frameworks/cmux Helper (GPU).app/Contents/MacOS/cmux Helper (GPU)", "--version"),
            ("version", "Contents/Frameworks/cmux Helper.app/Contents/MacOS/cmux Helper", "--version"),
            ("pages", "Frameworks"),
            ("chromium", "Contents/MacOS/cmux", "--cmux-prewarm-chromium"),
            ("launch", "placed", "measured"),  # renamed out of the staging folder, as Sparkle installs it
        ])
        self.assertEqual(row["arm"], "prewarm-update-moved")
        self.assertEqual(row["before"]["chromium_exit"], 0)
        self.assertEqual(row["phases"]["page"], 1281.0)

    def test_arms_update_is_the_update_arm_beside_the_base_arms(self):
        self.assertEqual(M.UPDATE_ARMS, ("prewarm-update-moved",))
        for group in (M.MAIN_FIRST, M.WITH_BINS, M.WITH_HELPERS, M.WITH_PAGES, M.WITH_CHROMIUM, M.MOVED):
            self.assertIn("prewarm-update-moved", group)
        script = (HERE.parent / "nightly-fresh-launch.sh").read_text()
        self.assertIn("arms=update)", script.replace("|arms=update)", " arms=update)"))


if __name__ == "__main__":
    unittest.main()
