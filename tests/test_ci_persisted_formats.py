#!/usr/bin/env python3
"""Behavioral tests for scripts/ci/persisted_formats.py (cmux-tui/persisted-formats/formats.toml)."""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/persisted_formats.py"
sys.path.insert(0, str(ROOT / "scripts/ci"))
import persisted_formats  # noqa: E402
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

REGISTRY = """
[[format]]
file = "crates/host/src/lib.rs"
const = "RECORD_VERSION"
name = "host-record"
policy = "migrate"
floor = 1
fixtures = "host-record"
test = "cmux_next_persisted_host_record"

[[format]]
file = "crates/host/src/cache.rs"
const = "CACHE_VERSION"
name = "host-cache"
policy = "rebuild"
why = "derived"

[[format]]
file = "crates/host/src/state.rs"
const = "STATE_VERSION"
name = "host-state"
policy = "unreviewed"
"""

TEST_SOURCE = "#[test]\nfn cmux_next_persisted_host_record_loads() {}\n"


class PersistedFormatsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = git_fixture_env.fixture_env()
        git_fixture_env.init_repo(self.root, "-b", "main", env=self.env)
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.write("cmux-tui/persisted-formats/formats.toml", REGISTRY)
        self.write("cmux-tui/persisted-formats/host-record/v1.json", '{"record_version": 1}\n')
        self.write("cmux-tui/crates/host/src/lib.rs", "pub const RECORD_VERSION: u32 = 1;\n" + TEST_SOURCE)
        self.write("cmux-tui/crates/host/src/cache.rs", "const CACHE_VERSION: u32 = 3;\n")
        self.write("cmux-tui/crates/host/src/state.rs", "pub(crate) const STATE_VERSION: u8 = 2;\n")
        self.write("cmux-tui/crates/host/src/wire.rs", "pub const PROTOCOL_VERSION: u16 = 9;\n")
        self.base = self.commit()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True, text=True,
                              env=self.env).stdout.strip()

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def commit(self) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "change")
        return self.git("rev-parse", "HEAD")

    def errors(self) -> list[str]:
        return persisted_formats.check(self.root, self.base)

    def assert_error(self, needle: str) -> None:
        errors = self.errors()
        self.assertTrue(any(needle in e for e in errors), f"{needle!r} not in {errors}")

    def test_clean_tree_passes(self) -> None:
        self.assertEqual(self.errors(), [])
        self.assertEqual(persisted_formats.check(self.root, None), [])

    def test_version_raise_without_fixture_fails(self) -> None:
        self.write("cmux-tui/crates/host/src/lib.rs", "pub const RECORD_VERSION: u32 = 2;\n" + TEST_SOURCE)
        self.assert_error("no fixture of version 2")
        self.write("cmux-tui/persisted-formats/host-record/v2.json", '{"record_version": 2}\n')
        self.assertEqual(self.errors(), [])

    def test_editing_a_fixture_fails(self) -> None:
        self.write("cmux-tui/persisted-formats/host-record/v1.json", '{"record_version": 1, "new": true}\n')
        self.assert_error("v1.json: edited")

    def test_additive_shape_is_a_new_revision(self) -> None:
        self.write("cmux-tui/persisted-formats/host-record/v1-2.json", '{"record_version": 1, "new": true}\n')
        self.assertEqual(self.errors(), [])

    def test_deleting_a_fixture_needs_a_floor_raise(self) -> None:
        self.write("cmux-tui/crates/host/src/lib.rs", "pub const RECORD_VERSION: u32 = 2;\n" + TEST_SOURCE)
        self.write("cmux-tui/persisted-formats/host-record/v2.json", '{"record_version": 2}\n')
        (self.root / "cmux-tui/persisted-formats/host-record/v1.json").unlink()
        self.assert_error("v1.json: deleted")
        registry = self.root / "cmux-tui/persisted-formats/formats.toml"
        registry.write_text(REGISTRY.replace("floor = 1", "floor = 2"), encoding="utf-8")
        self.assertEqual(self.errors(), [])

    def test_version_going_down_fails(self) -> None:
        self.write("cmux-tui/crates/host/src/cache.rs", "const CACHE_VERSION: u32 = 2;\n")
        self.assert_error("went down from 3 to 2")

    def test_unregistered_stored_version_fails_and_wire_version_does_not(self) -> None:
        self.write("cmux-tui/crates/host/src/journal.rs", "const JOURNAL_VERSION: u32 = 1;\n")
        self.write("cmux-tui/crates/host/src/abi.rs", "const FILES_ABI_VERSION: u32 = 1;\n")
        self.write("cmux-tui/crates/host/src/tests/fixture.rs", "const FILE_VERSION: u32 = 1;\n")
        errors = self.errors()
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("JOURNAL_VERSION", errors[0])

    def test_unreviewed_version_change_needs_a_policy(self) -> None:
        self.write("cmux-tui/crates/host/src/state.rs", "pub(crate) const STATE_VERSION: u8 = 3;\n")
        self.assert_error("while the format is unreviewed")

    def test_new_unreviewed_entry_fails(self) -> None:
        self.write("cmux-tui/crates/host/src/journal.rs", "const JOURNAL_VERSION: u32 = 1;\n")
        registry = self.root / "cmux-tui/persisted-formats/formats.toml"
        registry.write_text(REGISTRY + '\n[[format]]\nfile = "crates/host/src/journal.rs"\nconst = "JOURNAL_VERSION"\n'
                            'name = "journal"\npolicy = "unreviewed"\n', encoding="utf-8")
        self.assert_error("a new entry cannot be unreviewed")

    def test_migrate_needs_its_test(self) -> None:
        self.write("cmux-tui/crates/host/src/lib.rs", "pub const RECORD_VERSION: u32 = 1;\n")
        self.assert_error("no test `cmux_next_persisted_host_record*`")

    def test_rebuild_needs_why_and_moved_const_fails(self) -> None:
        registry = self.root / "cmux-tui/persisted-formats/formats.toml"
        registry.write_text(REGISTRY.replace('why = "derived"\n', ""), encoding="utf-8")
        self.assert_error("says `why`")
        self.write("cmux-tui/crates/host/src/state.rs", "// moved\n")
        self.assert_error("no `const STATE_VERSION")

    def test_script_exit_code(self) -> None:
        ok = subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(self.root), "--base", self.base],
                            capture_output=True, text=True, env=self.env)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.write("cmux-tui/persisted-formats/host-record/v1.json", "{}\n")
        bad = subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(self.root), "--base", self.base],
                             capture_output=True, text=True, env=self.env)
        self.assertEqual(bad.returncode, 1)
        self.assertIn("edited", bad.stderr)

    def test_repo_registry_is_clean(self) -> None:
        self.assertEqual(persisted_formats.check(ROOT, None), [])


if __name__ == "__main__":
    unittest.main()
