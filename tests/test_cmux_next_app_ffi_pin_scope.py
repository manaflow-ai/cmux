"""The app FFI pin check fails a pull request only for FFI drift the pull request itself made.

2026-10-07: three source changes on feat-cmux-next without a re-pin (2914fa52,
d7167cb6, 45845b2d) each made `swift test` red on every pull request into it.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/check-app-ffi-pin.sh"
SOURCE = "cmux-tui/crates/cmux-rd-core/src/lib.rs"
CHECKSUM = "c" * 64


def manifest(sha: str) -> str:
    return ("let appFFI: Target = .binaryTarget(\n    name: \"CCmuxAppFFI\",\n"
            f"    url: \"https://github.com/manaflow-ai/cmux/releases/download/cmux-app-ffi-{sha}/CCmuxAppFFI.xcframework.zip\",\n"
            f"    checksum: \"{CHECKSUM}\"\n)\n")


class PullRequestScope(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "scripts/cmux-next").mkdir(parents=True)
        shutil.copy(SCRIPT, self.root / "scripts/cmux-next/check-app-ffi-pin.sh")
        (self.root / "scripts/ci").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/ci/app_ffi_pin.py", self.root / "scripts/ci/app_ffi_pin.py")
        self.env = git_fixture_env.without_auto_maintenance(dict(
            os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t",
            GIT_COMMITTER_EMAIL="t@e"))
        self.git("init", "-q", "-b", "main")
        # The pinned source commit, then the pin to it: the base starts clean.
        self.write("cmux-tui/crates/cmux-app-ffi/Cargo.toml", '[dependencies]\nrd = { path = "../cmux-rd-core" }\n')
        self.write("cmux-tui/crates/cmux-rd-core/Cargo.toml", "[package]\nname = \"cmux-rd-core\"\nversion = \"0.1.0\"\n")
        self.write(SOURCE, "v1\n")
        self.pinned = self.commit("ffi v1")
        self.write("Packages/macOS/CmuxNext/Package.swift", manifest(self.pinned))
        self.commit("pin v1")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def check(self, *args):
        return subprocess.run(["bash", str(self.root / "scripts/cmux-next/check-app-ffi-pin.sh"), *args],
                              env=self.env, capture_output=True, text=True)

    def test_a_valid_canonical_pin_passes(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_pin_that_is_not_canonical_fails_naming_its_first_bad_line(self):
        # The check reads the pin only through scripts/ci/app_ffi_pin.py: a shape the canonical match does not know
        # fails, with the first line that does not match, even when the url and checksum are still there.
        good = manifest(self.pinned)
        cases = (
            (good.replace('name: "CCmuxAppFFI"', "name: ffiName"),
             "Package.swift line 2 is not the canonical CCmuxAppFFI pin line"),
            ('let note = """\n' + good + '"""\n', "Package.swift line 1 has '\"\"\"'"),
            (good + good.replace("let appFFI", "let b"), "Package.swift has 2 'binaryTarget', not one"),
            (good + '.target(name: "CCmuxAppFFI", path: "Shim"),\n',
             "Package.swift line 6 names CCmuxAppFFI or appFFI outside the canonical pin"),
        )
        for text, why in cases:
            with self.subTest(why=why):
                self.write("Packages/macOS/CmuxNext/Package.swift", text)
                result = self.check()
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("error: no canonical cmux-app-ffi pin in ", result.stderr)
                self.assertIn(why, result.stderr)

    def test_a_base_whose_pin_is_not_canonical_pins_nothing(self):
        # The base's pin is read the same way: a base that is not canonical never counts as pinning this sha, so
        # source drift is this change's own error, as with a base that pins nothing.
        self.write("Packages/macOS/CmuxNext/Package.swift", manifest(self.pinned) + "let r = #/x/#\n")
        self.write(SOURCE, "v2\n")
        base = self.commit("a base whose pin is not canonical, with FFI drift")
        self.write("Packages/macOS/CmuxNext/Package.swift", manifest(self.pinned))
        self.write("README.md", "unrelated\n")
        self.commit("the pull request")
        result = self.check("--base", base)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("error: the app FFI sources changed since the pinned source", result.stderr)

    def test_base_drift_is_a_note_for_a_pull_request_that_does_not_touch_ffi(self):
        self.write(SOURCE, "v2\n")
        base = self.commit("ffi v2 on the base, not re-pinned")
        self.write("README.md", "unrelated\n")
        self.commit("the pull request")
        scoped = self.check("--base", base)
        self.assertEqual(scoped.returncode, 0, scoped.stderr)
        self.assertIn("base drift", scoped.stdout + scoped.stderr)
        # Without a base (a push), the drift still fails, so the owning lane sees it.
        self.assertNotEqual(self.check().returncode, 0)

    def test_a_pull_request_changing_ffi_sources_without_a_re_pin_fails(self):
        base = self.git("rev-parse", "HEAD")
        self.write(SOURCE, "v2\n")
        self.commit("the pull request changes the FFI")
        result = self.check("--base", base)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed since the pinned source", result.stderr)

    def test_a_pull_request_changing_ffi_sources_on_a_drifted_base_fails(self):
        self.write(SOURCE, "v2\n")
        base = self.commit("ffi v2 on the base, not re-pinned")
        self.write(SOURCE, "v3\n")
        self.commit("the pull request changes the FFI too")
        self.assertNotEqual(self.check("--base", base).returncode, 0)

    def test_a_pull_request_that_re_pins_is_checked_against_its_new_pin(self):
        base = self.git("rev-parse", "HEAD")
        self.write(SOURCE, "v2\n")
        source = self.commit("ffi v2")
        self.write("Packages/macOS/CmuxNext/Package.swift", manifest(source))
        self.commit("re-pin v2")
        self.assertEqual(self.check("--base", base).returncode, 0)
        # A re-pin to a sha whose sources are not the head's still fails.
        self.write("Packages/macOS/CmuxNext/Package.swift", manifest(self.pinned))
        self.write(SOURCE, "v3\n")
        self.commit("re-pin back, change again")
        self.assertNotEqual(self.check("--base", base).returncode, 0)

    def test_an_unknown_base_checks_everything(self):
        self.write(SOURCE, "v2\n")
        self.commit("ffi v2 on the base, not re-pinned")
        result = self.check("--base", "f" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checking against the pin only", result.stderr)


# The checks job's pin step and its pull request scope (the base's copy, --base the merge commit's first parent) are
# run, not read: tests/test_cmux_next_checks_workflow.py AppFfiPinStepJudgesWithTheBaseCopy.


if __name__ == "__main__":
    unittest.main()
