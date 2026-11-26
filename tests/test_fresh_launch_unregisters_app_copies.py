#!/usr/bin/env python3
"""The fresh-home launch smoke and nightly-fresh-launch take their app copies back from LaunchServices.

LaunchServices keeps a record of every app bundle a run copies or launches after the run deletes its
private root (/tmp/cmux-fresh-*, /tmp/cmux-nfl-*). A later `open -a "cmux NIGHTLY"` or bundle-id lookup
on that Mac could then pick a dead copy: capture mini cmux12s showed eleven "The application "cmux
NIGHTLY" can't be opened." alerts on 2026-11-16, with 22 dead cmux-fresh-* NIGHTLY records among 2,690
dead app records. Each run now unregisters every app under its root, nested apps included, by path,
before it deletes the root.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SMOKE = ROOT / "scripts" / "ci" / "fresh_home_launch_smoke.py"
NFL = ROOT / "scripts" / "measure" / "nightly-fresh-launch.py"
spec = importlib.util.spec_from_file_location("fresh_home_launch_smoke_forget", SMOKE)
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class ForgetApps(unittest.TestCase):
    def test_every_app_under_the_root_is_unregistered_by_path_nested_ones_too(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            outer = root / "app" / "cmux NIGHTLY.app"
            nested = outer / "Contents" / "Library" / "cmux Computer Use.app"
            helper = outer / "Contents" / "Frameworks" / "cmux Helper (Alerts).app"
            for bundle in (nested, helper):
                bundle.mkdir(parents=True)
            (root / "not-an-app").mkdir()
            with mock.patch.object(smoke.os.path, "exists", side_effect=lambda p: p == smoke.LSREGISTER or Path(p).exists()), \
                    mock.patch.object(smoke.subprocess, "run", return_value=mock.Mock(returncode=0)) as run:
                forgotten = smoke.forget_apps(root)
        called = [c.args[0] for c in run.call_args_list]
        self.assertEqual(sorted(called), sorted([[smoke.LSREGISTER, "-u", str(p)] for p in (outer, nested, helper)]))
        self.assertEqual(sorted(forgotten), sorted(str(p) for p in (outer, nested, helper)))

    def test_a_linked_app_is_never_unregistered_through_its_link(self) -> None:
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory() as elsewhere:
            target = Path(elsewhere) / "Real.app"
            target.mkdir()
            (Path(raw) / "Link.app").symlink_to(target)
            with mock.patch.object(smoke.os.path, "exists", side_effect=lambda p: p == smoke.LSREGISTER or Path(p).exists()), \
                    mock.patch.object(smoke.subprocess, "run", return_value=mock.Mock(returncode=0)) as run:
                self.assertEqual(smoke.forget_apps(Path(raw)), [])
        run.assert_not_called()

    def test_without_lsregister_or_a_root_it_does_nothing_and_never_raises(self) -> None:
        with mock.patch.object(smoke.subprocess, "run") as run:
            self.assertEqual(smoke.forget_apps(Path("/nonexistent/cmux-fresh-x")), [])
            with tempfile.TemporaryDirectory() as raw, \
                    mock.patch.object(smoke.os.path, "exists", return_value=False):
                (Path(raw) / "a.app").mkdir()
                self.assertEqual(smoke.forget_apps(Path(raw)), [])
        run.assert_not_called()

    def test_a_failing_lsregister_does_not_stop_the_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            (Path(raw) / "a.app").mkdir()
            (Path(raw) / "b.app").mkdir()
            with mock.patch.object(smoke.os.path, "exists", return_value=True), \
                    mock.patch.object(smoke.subprocess, "run", side_effect=OSError("boom")) as run:
                self.assertEqual(smoke.forget_apps(Path(raw)), [])
            self.assertEqual(run.call_count, 2)


def function_body(text: str, name: str) -> str:
    match = re.search(rf"^def {name}\(.*?(?=^def |^if __name__)", text, re.M | re.S)
    if not match:
        raise AssertionError(f"no def {name}")
    return match.group(0)


class EveryRootIsForgottenBeforeItIsDeleted(unittest.TestCase):
    def test_the_smoke_forgets_its_root_before_removing_it(self) -> None:
        body = function_body(SMOKE.read_text(encoding="utf-8"), "main")
        self.assertLess(body.index("forget_apps(root)"), body.index("shutil.rmtree(root"))

    def test_each_dmg_mount_is_forgotten_before_it_is_detached(self) -> None:
        body = function_body(SMOKE.read_text(encoding="utf-8"), "copy_app_from_dmg")
        self.assertLess(body.index("forget_apps(mount)"), body.index("detach(mount)"))
        body = function_body(NFL.read_text(encoding="utf-8"), "main")
        self.assertLess(body.index("smoke.forget_apps(mount)"), body.index("smoke.detach(mount)"))

    def test_nightly_fresh_launch_forgets_each_root_before_removing_it(self) -> None:
        text = NFL.read_text(encoding="utf-8")
        for name in ("extra_arm", "round_once"):
            body = function_body(text, name)
            self.assertLess(body.index("smoke.forget_apps(root)"), body.index("shutil.rmtree(root"), name)


if __name__ == "__main__":
    unittest.main()
