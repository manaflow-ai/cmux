#!/usr/bin/env python3
"""Rules of scripts/cmux-next/check-sans-io.py: which files are sans-IO, and what they may not do."""

from __future__ import annotations

import importlib.util
import io
import os
import tempfile
import unittest
from contextlib import redirect_stdout

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "cmux-next", "check-sans-io.py")
spec = importlib.util.spec_from_file_location("check_sans_io", SCRIPT)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

SANS = "//! The leg, sans-IO: frames in, frames and a deadline out.\n//!\n//! More.\n\n"


class Tree:
    made: list[tempfile.TemporaryDirectory] = []

    def __init__(self, files: dict[str, str]):
        self.dir = tempfile.TemporaryDirectory()
        Tree.made.append(self.dir)
        for rel, text in files.items():
            path = os.path.join(self.dir.name, "cmux-tui", "crates", rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(text)

    def run(self, *args: str) -> tuple[int, str]:
        out = io.StringIO()
        with redirect_stdout(out):
            code = guard.main([self.dir.name, *args])
        return code, out.getvalue()

    def listed(self) -> list[str]:
        return [os.path.relpath(p, os.path.join(self.dir.name, "cmux-tui", "crates"))
                for p in guard.covered(self.dir.name)]


class SansIoGuardTest(unittest.TestCase):
    def tearDown(self):
        while Tree.made:
            Tree.made.pop().cleanup()

    def test_a_marked_module_that_reads_the_clock_fails(self):
        tree = Tree({"a/src/leg.rs": SANS + "fn f() { let now = Instant::now(); }\n"})
        code, out = tree.run()
        self.assertEqual(code, 1)
        self.assertIn("a/src/leg.rs:5 reads the clock", out)
        self.assertIn("next:", out)

    def test_each_forbidden_kind_is_caught(self):
        for line in ("tokio::time::sleep(d).await;", "std::thread::sleep(d);", "let s = UdpSocket::bind(a);",
                     "tokio::spawn(async {});", "let r = rand::thread_rng();", "SystemTime::now();",
                     "let t = tokio::time::timeout(d, f);"):
            with self.subTest(line=line):
                code, _ = Tree({"a/src/leg.rs": SANS + f"fn f() {{ {line} }}\n"}).run()
                self.assertEqual(code, 1)

    def test_values_comments_and_tests_pass(self):
        text = (SANS + "use tokio::time::Instant;\nuse std::net::SocketAddr;\n"
                "fn f(now: Instant, to: SocketAddr) {} // not Instant::now()\n"
                "// Instant::now() is the driver's job\n"
                "#[cfg(test)]\nmod tests {\n    fn t() { let _ = Instant::now(); }\n}\n")
        code, out = Tree({"a/src/leg.rs": text}).run()
        self.assertEqual(code, 0, out)

    def test_child_modules_are_covered_and_unmarked_files_are_not(self):
        tree = Tree({
            "a/src/hop.rs": "//! hop/1 on one leg. This module is\n//! its sans-IO implementation.\n\nmod rx;\n",
            "a/src/hop/rx.rs": "fn f() { Instant::now(); }\n",
            "a/src/driver.rs": "//! The driver: owns the socket.\n\nfn f() { Instant::now(); }\n",
            "a/src/lib.rs": "//! The crate.\n//!\n//! - [`hop`]: sans-IO.\n\nfn f() { Instant::now(); }\n",
        })
        self.assertEqual(tree.listed(), ["a/src/hop.rs", "a/src/hop/rx.rs"])
        code, out = tree.run()
        self.assertEqual(code, 1)
        self.assertIn("a/src/hop/rx.rs:1", out)
        self.assertNotIn("driver.rs", out)

    def test_a_cfg_test_child_module_is_not_covered(self):
        tree = Tree({
            "a/src/hop.rs": SANS + "#[cfg(test)]\nmod sim;\n",
            "a/src/hop/sim.rs": "fn f() { Instant::now(); }\n",
        })
        self.assertEqual(tree.listed(), ["a/src/hop.rs"])
        self.assertEqual(tree.run()[0], 0)

    def test_the_tree_passes(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = guard.main([ROOT])
        self.assertEqual(code, 0, out.getvalue())


if __name__ == "__main__":
    unittest.main()
