"""The app FFI pin check fails a pull request only for FFI drift the pull request itself made.

2026-10-07: three source changes on feat-cmux-next without a re-pin (2914fa52,
d7167cb6, 45845b2d) each made `swift test` red on every pull request into it.
"""
import json
import os
import shutil
import subprocess
import sys
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
PIN_READER = ROOT / "scripts/ci/app_ffi_pin.py"
# Imported by name, never loaded by path: one module object per file (tests/test_script_module_loads.py).
if str(PIN_READER.parent) not in sys.path:
    sys.path.insert(0, str(PIN_READER.parent))
import app_ffi_pin  # noqa: E402
SOURCE = "cmux-tui/crates/cmux-rd-core/src/lib.rs"
CHECKSUM = "c" * 64


MANIFEST = "import Foundation\nimport PackageDescription\n\n" + app_ffi_pin.loader(CHECKSUM)


class PullRequestScope(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "scripts/cmux-next").mkdir(parents=True)
        shutil.copy(SCRIPT, self.root / "scripts/cmux-next/check-app-ffi-pin.sh")
        (self.root / "scripts/ci").mkdir(parents=True)
        shutil.copy(PIN_READER, self.root / "scripts/ci/app_ffi_pin.py")
        self.env = git_fixture_env.without_auto_maintenance(dict(
            os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t",
            GIT_COMMITTER_EMAIL="t@e"))
        self.git("init", "-q", "-b", "main")
        # The pinned source commit, then the pin to it: the base starts clean.
        self.write("cmux-tui/crates/cmux-app-ffi/Cargo.toml", '[dependencies]\nrd = { path = "../cmux-rd-core" }\n')
        self.write("cmux-tui/crates/cmux-rd-core/Cargo.toml", "[package]\nname = \"cmux-rd-core\"\nversion = \"0.1.0\"\n")
        self.write(SOURCE, "v1\n")
        self.pinned = self.commit("ffi v1")
        self.pin(self.pinned)
        self.commit("pin v1")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def pin(self, sha):
        self.write("Packages/macOS/CmuxNext/Package.swift", MANIFEST)
        self.write("Packages/macOS/CmuxNext/app-ffi-pin.json", app_ffi_pin.render(sha, CHECKSUM))

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

    def test_a_pin_that_is_not_canonical_fails_naming_the_reason(self):
        # The check reads the pin only through scripts/ci/app_ffi_pin.py: a pin file off its one format, or a
        # Package.swift with anything but its one loader block, fails with the reader's reason.
        good = app_ffi_pin.render(self.pinned, CHECKSUM)
        url = json.loads(good)["url"]
        pin_cases = (
            (json.dumps({"url": url, "checksum": CHECKSUM, "extra": 1}) + "\n", "must be exactly"),
            (good.rstrip("\n"), "is not in its one format"),
            ("not json\n", "is not JSON"),
        )
        for text, why in pin_cases:
            with self.subTest(why=why):
                self.write("Packages/macOS/CmuxNext/app-ffi-pin.json", text)
                result = self.check()
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("error: no canonical cmux-app-ffi pin in ", result.stderr)
                self.assertIn(why, result.stderr)
        self.pin(self.pinned)
        manifest_cases = (
            (MANIFEST + 'let note = """\n"""\n', "has '\"\"\"'"),
            (MANIFEST + '.target(name: "CCmuxAppFFI", path: "Shim"),\n', "CCmuxAppFFI"),
        )
        for text, why in manifest_cases:
            with self.subTest(why=why):
                self.write("Packages/macOS/CmuxNext/Package.swift", text)
                result = self.check()
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("does not read the pin through its one loader block", result.stderr)
                self.assertIn(why, result.stderr)

    def test_a_base_whose_pin_is_not_canonical_pins_nothing(self):
        # The base's pin is read the same way: a base that is not canonical never counts as pinning this sha, so
        # source drift is this change's own error, as with a base that pins nothing.
        self.write("Packages/macOS/CmuxNext/app-ffi-pin.json", app_ffi_pin.render(self.pinned, CHECKSUM) + "\n")
        self.write(SOURCE, "v2\n")
        base = self.commit("a base whose pin is not canonical, with FFI drift")
        self.pin(self.pinned)
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
        self.pin(source)
        self.commit("re-pin v2")
        self.assertEqual(self.check("--base", base).returncode, 0)
        # A re-pin to a sha whose sources are not the head's still fails.
        self.pin(self.pinned)
        self.write(SOURCE, "v3\n")
        self.commit("re-pin back, change again")
        self.assertNotEqual(self.check("--base", base).returncode, 0)

    def test_an_unknown_base_checks_everything(self):
        self.write(SOURCE, "v2\n")
        self.commit("ffi v2 on the base, not re-pinned")
        result = self.check("--base", "f" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checking against the pin only", result.stderr)

    # A crate's tests/, benches/ and examples/ never reach the archive (app_ffi_pin.NOT_BUILT). 2026-11-11: a cargo
    # fmt of cmux-layout-reducer-ffi/tests/sidebar_caps.rs (cmux#41522) and two tests/ files of
    # cmux-agent-pane-policy and cmux-layout-reducer-ffi (cmux#41508) failed the pin check.
    NOT_BUILT_FILES = ("cmux-tui/crates/cmux-rd-core/tests/sidebar_caps.rs",
                       "cmux-tui/crates/cmux-rd-core/benches/ffi_bench.rs",
                       "cmux-tui/crates/cmux-rd-core/examples/demo.rs",
                       "cmux-tui/crates/cmux-app-ffi/tests/drag_handle.rs")
    BUILT_FILES = (SOURCE, "cmux-tui/crates/cmux-rd-core/build.rs", "cmux-tui/crates/cmux-rd-core/Cargo.toml",
                   "cmux-tui/crates/cmux-rd-core/src/tests/mod.rs")

    def test_a_change_to_a_crates_tests_benches_or_examples_is_not_an_ffi_change(self):
        for path in self.NOT_BUILT_FILES:
            with self.subTest(path=path):
                base = self.git("rev-parse", "HEAD")
                self.write(path, f"// {path}\n")
                self.commit(f"the pull request changes {path}")
                for args in ((), ("--base", base)):
                    result = self.check(*args)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("app FFI pin: sources match", result.stdout)

    def test_a_change_to_src_build_rs_or_the_manifest_still_is(self):
        base = self.git("rev-parse", "HEAD")
        for path in self.BUILT_FILES:
            with self.subTest(path=path):
                self.git("reset", "-q", "--hard", base)
                old = (self.root / path).read_text() if (self.root / path).exists() else ""
                self.write(path, old + "# changed\n")
                self.commit(f"the pull request changes {path}")
                result = self.check("--base", base)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("changed since the pinned source", result.stderr)
                self.assertIn(path.rsplit("/", 1)[-1], result.stderr)

    def test_a_tests_folder_a_library_file_names_stays_an_input(self):
        # cmux-rd-ffi's line reader test includes cmux-rd-proto/tests/vectors/app_lines.json; a build script may
        # compute such a path, so one that names the folder keeps it too.
        cases = (
            (SOURCE, 'const V: &str = include_str!("../tests/vectors/a.json");\n',
             "cmux-tui/crates/cmux-rd-core/tests/vectors/a.json"),
            ("cmux-tui/crates/cmux-app-ffi/build.rs", 'fn main() { let _ = std::path::Path::new("benches"); }\n',
             "cmux-tui/crates/cmux-app-ffi/benches/x.rs"),
        )
        start = self.git("rev-parse", "HEAD")
        for library, text, named in cases:
            with self.subTest(named=named):
                self.git("reset", "-q", "--hard", start)
                self.write(library, text)
                self.write(named, "v1\n")
                self.pin(self.commit("a library file names a tests folder"))
                base = self.commit("re-pin")
                self.write(named, "v2\n")
                self.commit("the pull request changes the named file")
                result = self.check("--base", base)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(named.rsplit("/", 1)[-1], result.stderr)


class EveryReaderAgrees(unittest.TestCase):
    """check-app-ffi-pin.sh, the router (and build_class.py, the dev-loop apply tools through it) and
    base_red_excuse.py read one definition of what is not an input: app_ffi_pin.NOT_BUILT."""

    @classmethod
    def setUpClass(cls):
        import sys  # noqa: PLC0415
        if str(ROOT / "scripts/ci") not in sys.path:
            sys.path.insert(0, str(ROOT / "scripts/ci"))
        import base_red_excuse  # noqa: PLC0415
        import build_class  # noqa: PLC0415
        import cmux_next_route  # noqa: PLC0415
        cls.excuse, cls.build_class, cls.route = base_red_excuse, build_class, cmux_next_route

        def listed(flag):
            return subprocess.run(["bash", str(SCRIPT), flag], check=True, capture_output=True, text=True).stdout.split()
        cls.inputs, cls.excluded = listed("--list-inputs"), listed("--list-excluded")
        cls.crates = [i for i in cls.inputs if (ROOT / i / "Cargo.toml").is_file()]

    def verdicts(self, path):
        return {
            "check-app-ffi-pin.sh": app_ffi_pin.is_input(path, self.inputs, self.excluded),
            "cmux_next_route.app_ffi_input": self.route.app_ffi_input(ROOT, path),
            "build_class.classify_path": "CCmuxAppFFI source" in self.build_class.classify_path(ROOT, path)[1],
            "base_red_excuse.ffi_input": self.excuse.ffi_input(path),
        }

    def test_the_router_excludes_what_the_pin_check_excludes(self):
        self.assertEqual(self.route.app_ffi_excluded(ROOT), self.excluded)
        self.assertIn("cmux-tui/crates/cmux-layout-reducer-ffi/tests", self.excluded)
        self.assertIn("cmux-tui/crates/cmux-agent-pane-policy/tests", self.excluded)

    def test_the_red_prs_test_files_are_no_input_for_any_reader(self):
        for path in ("cmux-tui/crates/cmux-layout-reducer-ffi/tests/sidebar_caps.rs",
                     "cmux-tui/crates/cmux-agent-pane-policy/tests/ffi_bench.rs",
                     "cmux-tui/crates/cmux-layout-reducer-ffi/tests/drag_handle.rs",
                     "cmux-tui/crates/cmux-app-ffi/benches/new.rs",
                     "cmux-tui/bindings/rust/examples/new.rs"):
            with self.subTest(path=path):
                self.assertEqual(set(self.verdicts(path).values()), {False}, self.verdicts(path))
        for directory in self.excluded:
            with self.subTest(directory=directory):
                self.assertFalse(any(self.verdicts(directory + "/x.rs").values()), self.verdicts(directory + "/x.rs"))

    def test_src_build_rs_and_the_manifest_are_inputs_for_every_reader(self):
        for crate in self.crates:
            for name in ("src/lib.rs", "src/tests/mod.rs", "src/x_tests.rs", "build.rs", "Cargo.toml"):
                path = f"{crate}/{name}"
                with self.subTest(path=path):
                    self.assertEqual(set(self.verdicts(path).values()), {True}, self.verdicts(path))
        for path in ("cmux-tui/rust-toolchain.toml", "scripts/cmux-next/build-app-ffi.sh"):
            with self.subTest(path=path):
                verdicts = self.verdicts(path)
                del verdicts["build_class.classify_path"]  # outside the crates: its own rule, before the inputs
                self.assertEqual(set(verdicts.values()), {True}, verdicts)


# The checks job's pin step and its pull request scope (the base's copy, --base the merge commit's first parent) are
# run, not read: tests/test_cmux_next_checks_workflow.py AppFfiPinStepJudgesWithTheBaseCopy.


if __name__ == "__main__":
    unittest.main()
