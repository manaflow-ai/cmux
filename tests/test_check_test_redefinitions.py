#!/usr/bin/env python3
"""scripts/cmux-next/check-test-redefinitions.py: a test file never defines one name twice in one body (F811).

Also its pre-push gate row ("Test redefinitions", prepush-gate.py): only a redefinition a push adds refuses.
Manual lane: no new CI tests (CLAUDE.md); the gate is local only, like SwiftFormat.
"""
from __future__ import annotations

# tests/git_fixture_env.py, loaded by path (`python3 -I` puts no script folder on sys.path).
import importlib.util
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/check-test-redefinitions.py"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


check = _load("check_test_redefinitions", SCRIPT)
git_fixture_env = _load("git_fixture_env", ROOT / "tests/git_fixture_env.py")
gate = _load("cmux_next_prepush_gate", ROOT / "scripts/cmux-next/prepush-gate.py")


def scan(source: str) -> list[str]:
    return check.scan_source(textwrap.dedent(source), "tests/test_x.py")


class RedefinitionTest(unittest.TestCase):
    def test_a_second_helper_in_one_testcase_is_refused(self) -> None:
        # cmux#41779: the second count_fetches replaced the locked one, and the parallel test lost its lock.
        hits = scan("""
            class ShallowClone(unittest.TestCase):
                def count_fetches(self):
                    with lock:
                        pass

                def test_parallel(self):
                    pass

                def count_fetches(self, stderr=None):
                    pass
        """)
        self.assertEqual(len(hits), 1, hits)
        self.assertTrue(hits[0].startswith("tests/test_x.py:10: ShallowClone.count_fetches redefines line 3"), hits)

    def test_a_module_function_defined_twice_is_refused(self) -> None:
        hits = scan("""
            def helper():
                return 1

            def helper():
                return 2
        """)
        self.assertEqual([hit.split(";")[0] for hit in hits], ["tests/test_x.py:5: helper redefines line 2"])

    def test_a_test_method_defined_twice_is_refused(self) -> None:
        # The common copy-paste loss: the first test never runs, and the count still looks right.
        hits = scan("""
            class T(unittest.TestCase):
                async def test_a(self):
                    pass

                def test_a(self):
                    pass
        """)
        self.assertEqual(len(hits), 1, hits)

    def test_a_class_defined_twice_and_a_class_in_a_function_are_read(self) -> None:
        hits = scan("""
            class Fixture:
                pass

            class Fixture:
                pass

            def make():
                class Local:
                    def go(self):
                        pass

                    def go(self):
                        pass
                return Local
        """)
        self.assertEqual(sorted(hit.split(":")[1] for hit in hits), ["13", "5"], hits)

    def test_one_name_in_different_bodies_passes(self) -> None:
        self.assertEqual(scan("""
            def setUp():
                pass

            class A(unittest.TestCase):
                def setUp(self):
                    pass

            class B(unittest.TestCase):
                def setUp(self):
                    pass
        """), [])

    def test_property_setters_and_overloads_pass(self) -> None:
        self.assertEqual(scan("""
            class Box:
                @property
                def value(self):
                    return self._value

                @value.setter
                def value(self, new):
                    self._value = new

                @typing.overload
                def get(self, key: int) -> int: ...

                @overload
                def get(self, key: str) -> str: ...

                def get(self, key):
                    return key
        """), [])

    def test_a_reassigned_variable_is_not_a_redefinition(self) -> None:
        self.assertEqual(scan("""
            RETRIES = 1
            RETRIES = 2

            class T:
                value = 1
                value = 2
        """), [])

    def test_the_command_exits_1_naming_each_hit_and_0_on_a_clean_tree(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "tests" / "nested").mkdir(parents=True)
            (root / "tests" / "test_clean.py").write_text("def a():\n    pass\n")
            clean = subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(root)],
                                   capture_output=True, text=True, check=False)
            self.assertEqual((clean.returncode, clean.stdout), (0, ""), clean.stderr)
            (root / "tests" / "nested" / "test_dup.py").write_text("def a():\n    pass\n\n\ndef a():\n    pass\n")
            dirty = subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(root)],
                                   capture_output=True, text=True, check=False)
            self.assertEqual(dirty.returncode, 1, dirty.stdout + dirty.stderr)
            self.assertIn("tests/nested/test_dup.py:5: a redefines line 1", dirty.stdout)

    def test_the_tree_is_clean(self) -> None:
        result = subprocess.run([sys.executable, "-I", str(SCRIPT)], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


LOCKED = "class T:\n    def helper(self):\n        return 1\n"
SHADOWED = LOCKED + "\n    def helper(self):\n        return 2\n"


class GateRowTest(unittest.TestCase):
    """prepush-gate.py's test_redefinition_problems over a throwaway repository, base and head commits."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = git_fixture_env.init_repo(Path(tmp.name) / "repo", "-b", "main")
        self.env = git_fixture_env.fixture_env(os.environ)
        (self.repo / "scripts/cmux-next").mkdir(parents=True)
        (self.repo / "scripts/cmux-next/check-test-redefinitions.py").write_bytes(SCRIPT.read_bytes())
        (self.repo / "tests").mkdir()

    def commit(self, files: dict[str, str]) -> str:
        for name, text in files.items():
            (self.repo / name).write_text(text)
        for args in (["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "c"]):
            subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, check=True, capture_output=True)
        return subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"], env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def test_a_push_that_adds_a_redefinition_is_refused(self) -> None:
        base = self.commit({"tests/test_a.py": LOCKED})
        head = self.commit({"tests/test_a.py": SHADOWED})
        found = gate.test_redefinition_problems(self.repo, base, head)
        self.assertEqual(len(found), 1, found)
        self.assertTrue(found[0].startswith("tests/test_a.py:5: T.helper redefines line 2"), found)

    def test_a_redefinition_the_base_already_had_does_not_block_and_moving_it_is_not_new(self) -> None:
        base = self.commit({"tests/test_a.py": SHADOWED})
        head = self.commit({"tests/test_a.py": "import os\n\n\n" + SHADOWED})
        self.assertEqual(gate.test_redefinition_problems(self.repo, base, head), [])

    def test_a_push_that_leaves_tests_alone_runs_nothing(self) -> None:
        base = self.commit({"tests/test_a.py": SHADOWED})
        head = self.commit({"README": "x"})
        self.assertEqual(gate.test_redefinition_problems(self.repo, base, head), [])

    def test_the_gate_reports_it_under_its_own_check(self) -> None:
        base = self.commit({"tests/test_a.py": LOCKED})
        (self.repo / "tests/nested").mkdir()
        head = self.commit({"tests/nested/test_b.py": SHADOWED})
        found = gate.gate(self.repo, base, head, only={"redefinitions"}, timings=False)
        self.assertEqual([name for name, _ in found], [gate.REDEFINITION_CHECK], found)
        self.assertIn("tests/nested/test_b.py:5: T.helper redefines line 2", found[0][1][0])


if __name__ == "__main__":
    unittest.main()
