"""scripts/ci/cmux-next-daemon-test-packages.sh names only the test targets that hold cmux_next_ tests.

The cmux_next_ daemon tests (cmux-tui-artifacts.yml) built every test target of each member that
names cmux_next_ anywhere: acpmux alone has about 300. After cmux-tui turned on acpmux's
hub-carrier feature (#43753, 171c1fa97a7) each of them linked the hub carrier, and the job ran out
of disk on its 8-vCPU runner on every run ("No space left on device", run 43758800604), so no
tree was marked daemon-tested. These tests run the script on a fixture workspace and on this
repository.

Run: python3 -I tests/test_cmux_next_daemon_test_packages.py
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cmux-next-daemon-test-packages.sh"


def run(repo: Path) -> list[str]:
    out = subprocess.run(["bash", str(repo / "scripts/ci/cmux-next-daemon-test-packages.sh")], cwd=repo,
                         check=True, capture_output=True, text=True).stdout
    return out.split()


def pairs(args: list[str], flag: str) -> set[str]:
    return {args[i + 1] for i, a in enumerate(args) if a == flag}


class Fixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        (root / "scripts/ci").mkdir(parents=True)
        shutil.copy(SCRIPT, root / "scripts/ci/cmux-next-daemon-test-packages.sh")
        self.write("cmux-tui/Cargo.toml", '[workspace]\nmembers = ["crates/*"]\n')

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def crate(self, name: str, extra: str = "") -> None:
        self.write(f"cmux-tui/crates/{name}/Cargo.toml", f'[package]\nname = "{name}"\nversion = "0.1.0"\n{extra}')

    def commit(self) -> None:
        git = ["git", "-C", str(self.root), "-c", "user.name=t", "-c", "user.email=t@example.com"]
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run([*git, "add", "."], check=True)
        subprocess.run([*git, "commit", "-qm", "c"], check=True)


class TargetsOfTheMatches(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.box = Fixture(Path(self.tmp.name))

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_only_the_test_targets_that_name_cmux_next_are_built(self) -> None:
        box = self.box
        box.crate("a")
        box.write("cmux-tui/crates/a/src/lib.rs", "#[test] fn cmux_next_lib() {}\n")
        box.write("cmux-tui/crates/a/tests/hits.rs", "#[test] fn cmux_next_hit() {}\n")
        box.write("cmux-tui/crates/a/tests/misses.rs", "#[test] fn other() {}\n")
        # A module of tests/nested.rs under tests/nested/: its target is `nested`.
        box.write("cmux-tui/crates/a/tests/nested.rs", "mod inner;\n")
        box.write("cmux-tui/crates/a/tests/nested/inner.rs", "#[test] fn cmux_next_inner() {}\n")
        box.crate("b")
        box.write("cmux-tui/crates/b/src/main.rs", "fn main() {}\n")
        box.write("cmux-tui/crates/b/tests/journey.rs", "#[test] fn cmux_next_journey() {}\n")
        box.crate("c")
        box.write("cmux-tui/crates/c/tests/untouched.rs", "#[test] fn other() {}\n")
        box.commit()
        args = run(box.root)
        self.assertEqual(pairs(args, "-p"), {"a", "b"}, args)
        self.assertEqual(pairs(args, "--test"), {"hits", "nested", "journey"}, args)
        self.assertIn("--lib", args)
        self.assertIn("--bins", args)

    def test_a_match_with_only_test_targets_builds_no_lib(self) -> None:
        self.box.crate("a")
        self.box.write("cmux-tui/crates/a/src/lib.rs", "pub fn f() {}\n")
        self.box.write("cmux-tui/crates/a/tests/hits.rs", "#[test] fn cmux_next_hit() {}\n")
        self.box.commit()
        args = run(self.box.root)
        self.assertEqual(args, ["-p", "a", "--test", "hits"])

    def test_a_match_it_cannot_place_builds_the_whole_members(self) -> None:
        # A member that sets autotests = false names its own targets; a match outside src/ and
        # tests/ (a bench) belongs to no target the script names. Either keeps every test target.
        for extra, rel in (("autotests = false\n", "tests/hits.rs"), ("", "benches/b.rs")):
            with self.subTest(rel=rel, extra=extra):
                with tempfile.TemporaryDirectory() as tmp:
                    box = Fixture(Path(tmp))
                    box.crate("a", extra)
                    box.write("cmux-tui/crates/a/src/lib.rs", "#[test] fn cmux_next_lib() {}\n")
                    box.write(f"cmux-tui/crates/a/{rel}", "#[test] fn cmux_next_x() {}\n")
                    box.commit()
                    self.assertEqual(run(box.root), ["-p", "a"])

    def test_a_match_outside_a_member_tests_the_workspace(self) -> None:
        self.box.write("cmux-tui/loose/x.rs", "#[test] fn cmux_next_x() {}\n")
        self.box.commit()
        self.assertEqual(run(self.box.root), ["--workspace"])


class ThisRepository(unittest.TestCase):
    def test_every_named_test_target_exists_in_a_named_member(self) -> None:
        args = run(ROOT)
        self.assertNotIn("--workspace", args)
        tests = pairs(args, "--test")
        self.assertTrue(tests, args)
        found = set()
        for member in (ROOT / "cmux-tui").glob("**/Cargo.toml"):
            if "/target/" in str(member):
                continue
            tests_dir = member.parent / "tests"
            for name in tests:
                if (tests_dir / f"{name}.rs").is_file() or (tests_dir / name / "main.rs").is_file():
                    found.add(name)
        self.assertEqual(found, tests)
        # acpmux's ~300 test binaries are what filled the disk: only its targets with cmux_next_ remain.
        self.assertIn("harness_health", tests)
        self.assertNotIn("hub_carrier", tests)


if __name__ == "__main__":
    unittest.main()
