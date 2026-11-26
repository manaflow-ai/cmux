"""The nightly-next fast pass's risk rule (scripts/ci/nightly_fast_pass.py) and its use in the rolling rule."""
from __future__ import annotations

import datetime as dt
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / "ci" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(name, module)
    spec.loader.exec_module(module)
    return module


fast = load("nightly_fast_pass")
rolling = load("nightly_next_rolling")
SURFACE = fast.surface_patterns()


def small(path: str, added: str = "3", deleted: str = "1"):
    return (added, deleted, path)


class RiskRuleTests(unittest.TestCase):
    def test_reads_the_release_surface(self):
        self.assertTrue(any(p.match("scripts/ci/nightly_next_rolling.py") for p in SURFACE))
        self.assertTrue(any(p.match("scripts/sign-app.sh") for p in SURFACE))
        self.assertFalse(any(p.match("Sources/Panels/Chat.swift") for p in SURFACE))

    def test_a_small_source_fix_is_a_fast_pass(self):
        verdict = fast.classify(1, [small("Sources/Panels/Chat.swift"), small("cmux-tui/src/app.rs")],
                                [("100644", "100644", "Sources/Panels/Chat.swift")], SURFACE)
        self.assertTrue(verdict.fast, verdict.reason)
        self.assertEqual((verdict.commits, verdict.files, verdict.lines), (1, 2, 8))

    def test_size_bounds(self):
        files = [small(f"Sources/F{i}.swift") for i in range(fast.MAX_FILES + 1)]
        self.assertIn("files changed", fast.classify(1, files, [], SURFACE).reason)
        self.assertIn("lines changed", fast.classify(1, [small("a.swift", str(fast.MAX_LINES), "1")], [], SURFACE).reason)
        self.assertIn("commits wait", fast.classify(fast.MAX_COMMITS + 1, [small("a.swift")], [], SURFACE).reason)
        self.assertFalse(fast.classify(0, [], [], SURFACE).fast)

    def test_risky_paths_are_never_a_fast_pass(self):
        for path in (".github/workflows/cmux-next.yml", "scripts/ci/nightly_next_rolling.py", "Package.swift",
                     "cmux-tui/Cargo.lock", "web/package.json", "cmux.nightly.entitlements",
                     "GhosttyTabs.xcodeproj/project.pbxproj", "Resources/Info.plist", "scripts/verify-app.sh",
                     "cmux-tui/build-support/notices/LICENSES.txt"):
            with self.subTest(path=path):
                verdict = fast.classify(1, [small(path)], [], SURFACE)
                self.assertFalse(verdict.fast, path)

    def test_binary_submodule_and_mode_changes_are_never_a_fast_pass(self):
        self.assertIn("binary", fast.classify(1, [small("Assets/icon.png", "-", "-")], [], SURFACE).reason)
        self.assertIn("submodule", fast.classify(1, [small("ghostty")], [("160000", "160000", "ghostty")], SURFACE).reason)
        self.assertIn("file mode", fast.classify(1, [small("tools/run.sh")],
                                                 [("100644", "100755", "tools/run.sh")], SURFACE).reason)
        # A new or deleted file is not a mode change.
        self.assertTrue(fast.classify(1, [small("Sources/New.swift")], [("000000", "100644", "Sources/New.swift")],
                                      SURFACE).fast)


class LocalGitTests(unittest.TestCase):
    def git(self, *args):
        return subprocess.run(["git", "-C", self.dir, *args], check=True, capture_output=True, text=True).stdout.strip()

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = self._tmp.name
        self.git("init", "-q")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        Path(self.dir, "a.swift").write_text("let a = 1\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD")

    def tearDown(self):
        self._tmp.cleanup()

    def runner(self, *args):
        return subprocess.run(["git", "-C", self.dir, *args], check=True, capture_output=True, text=True,
                              timeout=60).stdout

    def test_reads_a_real_range(self):
        Path(self.dir, "a.swift").write_text("let a = 2\n")
        self.git("commit", "-qam", "fix")
        verdict = fast.evaluate(self.base, self.git("rev-parse", "HEAD"), git=self.runner, surface=SURFACE)
        self.assertTrue(verdict.fast, verdict.reason)
        self.assertEqual((verdict.commits, verdict.files, verdict.lines), (1, 1, 2))

    def test_an_unreadable_range_is_not_a_fast_pass(self):
        verdict = fast.evaluate("0" * 40, self.base, git=self.runner, surface=SURFACE)
        self.assertFalse(verdict.fast)
        self.assertIn("could not read", verdict.reason)


NOW = dt.datetime(2026, 11, 26, 12, 0, tzinfo=dt.timezone.utc)
HEAD = "a" * 40
TIP = "b" * 40


def iso(minutes_ago: float) -> str:
    return (NOW - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def api_with(starts):
    def api(path):
        if "branch=nightly-next" in path:
            return {"workflow_runs": starts}
        if "branch=main" in path:
            return {"workflow_runs": []}
        raise AssertionError(path)
    return api


class RollingFastPassTests(unittest.TestCase):
    """A safe fix shortens the even cadence; it never promotes beside a running build."""

    finished_start = [{"id": 1, "event": "push", "status": "completed", "conclusion": "success",
                       "created_at": iso(8), "head_sha": HEAD, "display_title": "x"}]

    def evaluate(self, verdict, starts=None):
        return rolling.evaluate(NOW, "o/r", TIP, api=api_with(self.finished_start if starts is None else starts),
                                ls_remote=lambda repo, ref: HEAD, local_gap=lambda head, tip: (TIP, NOW),
                                cadence_minutes=20, fast_pass=lambda head, tip: verdict)

    def test_without_a_fast_pass_the_cadence_waits(self):
        go, why = self.evaluate(fast.Verdict(False, "Package.swift is a build, dependency or signing file"))
        self.assertFalse(go, why)
        self.assertIn("even cadence", why)

    def test_a_fast_pass_promotes_after_its_shorter_cadence(self):
        go, why = self.evaluate(fast.Verdict(True, "a safe fix", 1, 1, 2))
        self.assertTrue(go, why)
        self.assertIn("fast pass", why)

    def test_a_fast_pass_still_waits_its_own_cadence(self):
        starts = [dict(self.finished_start[0], created_at=iso(2.5))]
        go, why = self.evaluate(fast.Verdict(True, "a safe fix", 1, 1, 2), starts)
        self.assertFalse(go, why)
        self.assertIn(f"of {fast.FAST_PASS_CADENCE_MINUTES:g} min", why)

    def test_a_fast_pass_never_promotes_beside_a_running_build(self):
        running = [dict(self.finished_start[0], status="in_progress", conclusion=None, created_at=iso(30))]
        jobs = {"jobs": [{"name": "nightly-next-one", "status": "in_progress", "steps": []}]}

        def api(path):
            if "/jobs" in path:
                return jobs
            return api_with(running)(path)
        go, why = rolling.evaluate(NOW, "o/r", TIP, api=api, ls_remote=lambda repo, ref: HEAD,
                                   local_gap=lambda head, tip: (TIP, NOW), cadence_minutes=20,
                                   fast_pass=lambda head, tip: fast.Verdict(True, "a safe fix", 1, 1, 2))
        self.assertFalse(go, why)
        self.assertIn("is building", why)


if __name__ == "__main__":
    unittest.main()
