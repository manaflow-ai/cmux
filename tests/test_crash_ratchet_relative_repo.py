#!/usr/bin/env python3
"""scripts/cmux-next/crash_ratchet.py counts the same Rust hits for `--repo .` as for the absolute path.

A test-only module declared with #[path] (`#[cfg(test)] #[path = "helpers.rs"] mod helpers;`) is test code. Its
target was normalised with os.path.normpath, which drops a leading `./`, while the scanned paths kept it, so with a
relative repo the target never matched and its unwraps counted as the crate's own: a false red.
"""

import importlib.util
import os
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "crash_ratchet", os.path.join(HERE, "..", "scripts", "cmux-next", "crash_ratchet.py"))
crash_ratchet = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(crash_ratchet)

LIB = """pub fn one() -> u8 {
    1
}

#[cfg(test)]
#[path = "helpers.rs"]
mod helpers;
"""
HELPERS = """#[test]
fn reads() {
    assert_eq!(Some(super::one()).unwrap(), 1);
}
"""


class RelativeRepo(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="crash-ratchet-relative-")
        src = os.path.join(self.root, "cmux-tui", "crates", "demo", "src")
        os.makedirs(src)
        with open(os.path.join(src, "lib.rs"), "w") as f:
            f.write(LIB)
        with open(os.path.join(src, "helpers.rs"), "w") as f:
            f.write(HELPERS)
        self.cwd = os.getcwd()

    def tearDown(self):
        os.chdir(self.cwd)
        shutil.rmtree(self.root)

    def rust_counts(self, repo):
        scan = crash_ratchet.Scan()
        crash_ratchet.scan_rust(repo, scan, True)
        return scan.counts["rust"]

    def test_a_path_test_module_is_test_code_for_a_relative_repo(self):
        self.assertEqual(self.rust_counts(self.root), {})
        os.chdir(self.root)
        self.assertEqual(self.rust_counts("."), {})

    def test_a_plain_test_module_is_test_code_for_a_relative_repo(self):
        src = os.path.join(self.root, "cmux-tui", "crates", "demo", "src")
        with open(os.path.join(src, "lib.rs"), "w") as f:
            f.write(LIB.replace('#[path = "helpers.rs"]\n', ""))
        self.assertEqual(self.rust_counts(self.root), {})
        os.chdir(self.root)
        self.assertEqual(self.rust_counts("."), {})


if __name__ == "__main__":
    unittest.main()
