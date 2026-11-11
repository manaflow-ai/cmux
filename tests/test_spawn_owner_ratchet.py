#!/usr/bin/env python3
"""scripts/cmux-next/check-spawn-owner.py (cmuxterm-hq#9096, proposal 2): a spawn with no owner
in a file with no row fails, a file at its row passes, one below it passes and --update lowers the
row, and a baseline raised above the base's copy fails."""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path. It turns
# git's auto maintenance off in the fixture repository (scripts/check-test-determinism.py).
_spec = importlib.util.spec_from_file_location(
    "git_fixture_env", os.path.join(os.path.dirname(os.path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(git_fixture_env)

SOURCE = Path(__file__).resolve().parents[1]
CHECK = SOURCE / "scripts/cmux-next/check-spawn-owner.py"
BASELINE = "scripts/cmux-next/spawn-owner-baseline.tsv"
HUB = "cmux-tui/crates/acpmux/src/hub/fresh.rs"


class SpawnOwnerRatchet(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="spawn-owner-"))
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / "scripts/cmux-next").mkdir(parents=True)

    def write(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def baseline(self, rows):
        self.write(BASELINE, "# path\tcount\n" + "".join(f"{p}\t{n}\n" for p, n in rows.items()))

    def check(self, *args):
        result = subprocess.run([sys.executable, "-I", str(CHECK), str(self.root), *args],
                                capture_output=True, text=True)
        return result.returncode, result.stdout + result.stderr

    def git(self, *args):
        env = git_fixture_env.fixture_env({"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                                           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
                                           "PATH": "/usr/bin:/bin"})
        if args[0] == "init":
            git_fixture_env.init_repo(self.root, *args[1:], env=env)
            return
        subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True, env=env)

    def test_a_new_file_with_one_bare_spawn_fails_and_names_scope_spawn(self):
        self.baseline({})
        self.write(HUB, "fn f() {\n    tokio::spawn(async {});\n}\n")
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn("fresh.rs:2", out)
        self.assertIn("a new file", out)
        self.assertIn("next:", out)
        self.assertIn("Scope::spawn", out)

    def test_each_kind_of_unowned_spawn_counts(self):
        self.baseline({})
        self.write(HUB, "\n".join([
            "use std::process::Command;",
            "fn f() {",
            "    tokio::task::spawn(async {});",
            "    std::thread::spawn(|| {});",
            "    thread::spawn(|| {});",
            "    let child = Command::new(\"git\").spawn();",
            "}",
        ]))
        code, out = self.check("--list")
        self.assertEqual(code, 0, out)
        self.assertEqual(len([l for l in out.splitlines() if "fresh.rs:" in l]), 4, out)

    def test_owned_spawns_comments_tests_and_the_owner_crates_are_not_counted(self):
        self.baseline({})
        self.write(HUB, "\n".join([
            "use cmux_process::Command;",
            "fn f(hub: &Hub) {",
            "    hub.scope.spawn(async {});",
            "    hub.scope.spawn_named(\"x\", async {});",
            "    let child = Command::new(\"git\").spawn();",
            "    // tokio::spawn(async {}) was the old way",
            "    set.spawn(async {});",
            "}",
            "#[cfg(test)]",
            "mod tests {",
            "    fn t() { tokio::spawn(async {}); }",
            "}",
        ]))
        self.write("cmux-tui/crates/acpmux/src/hub/fresh_tests.rs", "fn t() { tokio::spawn(async {}); }\n")
        self.write("cmux-tui/crates/acpmux/tests/it.rs", "fn t() { tokio::spawn(async {}); }\n")
        self.write("cmux-tui/crates/cmux-scope/src/lib.rs", "fn t() { tokio::spawn(async {}); }\n")
        self.write("cmux-tui/crates/cmux-process/src/child.rs", "fn t() { std::thread::spawn(|| {}); }\n")
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertIn("check-spawn-owner: ok (0 baselined line(s) in 0 file(s))", out)

    def test_a_module_declared_cfg_test_is_test_code_whatever_its_name(self):
        # cmux#41040's hub/remote_table_bench.rs, a `#[cfg(test)] mod remote_table_bench;` with a
        # thread::spawn, turned feat-cmux-next red once #41081 landed beside it.
        self.baseline({})
        self.write("cmux-tui/crates/acpmux/src/hub/mod.rs", "\n".join([
            "mod fresh;",
            "#[cfg(test)]",
            "mod remote_table_bench;",
            "#[cfg(test)]",
            "#[allow(dead_code)]",
            "pub(crate) mod soak;",
            "",
        ]))
        self.write("cmux-tui/crates/acpmux/src/hub/remote_table_bench.rs", "fn t() { std::thread::spawn(|| {}); }\n")
        self.write("cmux-tui/crates/acpmux/src/hub/soak/mod.rs", "fn t() { tokio::spawn(async {}); }\n")
        self.write("cmux-tui/crates/acpmux/src/hub/soak/deep.rs", "fn t() { tokio::spawn(async {}); }\n")
        self.write("cmux-tui/crates/acpmux/src/lib.rs", "#[cfg(test)]\nmod probe;\nmod hub;\n")
        self.write("cmux-tui/crates/acpmux/src/probe.rs", "fn t() { tokio::spawn(async {}); }\n")
        code, out = self.check()
        self.assertEqual(code, 0, out)
        # A product module beside them still counts.
        self.write(HUB, "fn f() { tokio::spawn(async {}); }\n")
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn("fresh.rs:1", out)
        self.assertNotIn("remote_table_bench", out)

    def test_a_file_at_its_row_passes(self):
        self.baseline({HUB: 2})
        self.write(HUB, "fn f() {\n    tokio::spawn(a());\n    tokio::spawn(b());\n}\n")
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertIn("ok (2 baselined line(s) in 1 file(s))", out)

    def test_one_more_than_its_row_fails(self):
        self.baseline({HUB: 1})
        self.write(HUB, "fn f() {\n    tokio::spawn(a());\n    tokio::spawn(b());\n}\n")
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn("baseline 1", out)

    def test_below_its_row_passes_and_update_lowers_it(self):
        self.baseline({HUB: 3, "cmux-tui/crates/acpmux/src/gone.rs": 2})
        self.write(HUB, "fn f() {\n    tokio::spawn(a());\n}\n")
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertIn("Lower its row", out)
        code, out = self.check("--update")
        self.assertEqual(code, 0, out)
        text = (self.root / BASELINE).read_text()
        self.assertIn(f"{HUB}\t1\n", text)
        self.assertNotIn("gone.rs", text, "a row at 0 is deleted")
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertNotIn("Lower its row", out)

    def test_update_never_raises_a_row(self):
        self.baseline({HUB: 1})
        self.write(HUB, "fn f() {\n    tokio::spawn(a());\n    tokio::spawn(b());\n}\n")
        code, out = self.check("--update")
        self.assertEqual(code, 1, out)
        self.assertIn(f"{HUB}\t1\n", (self.root / BASELINE).read_text())

    def test_init_writes_a_new_baseline_only(self):
        self.write(HUB, "fn f() {\n    tokio::spawn(a());\n}\n")
        code, out = self.check("--init")
        self.assertEqual(code, 0, out)
        self.assertIn(f"{HUB}\t1\n", (self.root / BASELINE).read_text())
        code, out = self.check("--init")
        self.assertEqual(code, 2, out)

    def test_a_baseline_raised_above_the_base_fails_in_ci(self):
        self.git("init", "-q")
        self.baseline({HUB: 1})
        self.write(HUB, "fn f() {\n    tokio::spawn(a());\n}\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "base")
        self.baseline({HUB: 2, "cmux-tui/crates/acpmux/src/new.rs": 1})
        self.write(HUB, "fn f() {\n    tokio::spawn(a());\n    tokio::spawn(b());\n}\n")
        self.write("cmux-tui/crates/acpmux/src/new.rs", "fn g() { tokio::spawn(c()); }\n")
        code, out = self.check("--base-ref", "HEAD")
        self.assertEqual(code, 1, out)
        self.assertIn("raises", out)
        self.assertIn("new.rs", out)
        # Lowered against the base: green.
        self.baseline({})
        self.write(HUB, "fn f() {}\n")
        self.write("cmux-tui/crates/acpmux/src/new.rs", "fn g() {}\n")
        code, out = self.check("--base-ref", "HEAD")
        self.assertEqual(code, 0, out)

    def test_the_committed_baseline_holds_on_this_tree(self):
        result = subprocess.run([sys.executable, "-I", str(CHECK), str(SOURCE)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
