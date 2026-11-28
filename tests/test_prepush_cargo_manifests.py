"""prepush-gate's "Cargo manifests parse" check, on a throwaway git repository.

#60612 (2026-11-27) merged a second `url.workspace = true` into
cmux-next-ios/rust/crates/cmux-mobile-link-ffi/Cargo.toml; cargo refused the manifest and every pull
request's `plan (changed Cargo workspaces)` failed until #62073 dropped it.
"""
from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("prepush_gate_cargo", ROOT / "scripts/cmux-next/prepush-gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

GOOD = '[package]\nname = "ffi"\n\n[dependencies]\nurl.workspace = true\nuuid.workspace = true\n'
BAD = GOOD + "url.workspace = true\n"


class CargoManifestParseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="cargo-manifest-parse-")
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_AUTHOR_NAME="F",
                        GIT_AUTHOR_EMAIL="f@example.com", GIT_COMMITTER_NAME="F", GIT_COMMITTER_EMAIL="f@example.com")
        self.git("init", "--quiet", "--initial-branch=base")
        self.write("README.md", "x\n")
        self.base = self.commit("base")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, text=True,
                              capture_output=True, check=True).stdout.strip()

    def write(self, rel, text):
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "--quiet", "--no-verify", "-m", message)
        return self.git("rev-parse", "HEAD")

    def test_duplicate_key_is_refused(self):
        self.write("crates/ffi/Cargo.toml", BAD)
        head = self.commit("bad")
        found = gate.cargo_manifest_problems(self.repo, self.base, head)
        self.assertEqual(len(found), 1, found)
        self.assertTrue(found[0].startswith("crates/ffi/Cargo.toml: Cannot overwrite a value"), found)

    def test_parsable_manifest_passes(self):
        self.write("crates/ffi/Cargo.toml", GOOD)
        head = self.commit("good")
        self.assertEqual(gate.cargo_manifest_problems(self.repo, self.base, head), [])

    def test_broken_then_fixed_in_the_same_push_passes(self):
        self.write("crates/ffi/Cargo.toml", BAD)
        self.commit("bad")
        self.write("crates/ffi/Cargo.toml", GOOD)
        head = self.commit("fix")
        self.assertEqual(gate.cargo_manifest_problems(self.repo, self.base, head), [])

    def test_unchanged_broken_manifest_is_not_read(self):
        # Constant cost: only the manifests the range changes; old debt elsewhere is not this push's.
        self.write("crates/ffi/Cargo.toml", BAD)
        start = self.commit("old debt")
        self.write("src/lib.rs", "fn main() {}\n")
        head = self.commit("unrelated")
        self.assertEqual(gate.cargo_manifest_problems(self.repo, start, head), [])

    def test_restrict_limits_the_files(self):
        self.write("crates/ffi/Cargo.toml", BAD)
        head = self.commit("bad")
        self.assertEqual(gate.cargo_manifest_problems(self.repo, self.base, head, restrict={"other/Cargo.toml"}), [])

    def test_non_manifest_toml_is_not_read(self):
        self.write("crates/ffi/NotCargo.toml", BAD)
        head = self.commit("other toml")
        self.assertEqual(gate.cargo_manifest_problems(self.repo, self.base, head), [])


if __name__ == "__main__":
    unittest.main()
