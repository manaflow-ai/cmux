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
py39_names = _load("py39_names", ROOT / "tests/test_py39_names.py")  # its python39(): a real 3.9
gate.load_push_range(ROOT, ROOT / "scripts/cmux-next")  # gate_own reads it from sys.modules


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

    def test_a_class_under_two_ifs_or_an_except_is_read(self) -> None:
        # #41818 review (F3): the scope walk read a class only one `if`/`try`/`with` deep, and never under `except`.
        hits = scan("""
            if HAVE_GIT:
                if sys.platform == "linux":
                    class Deep(unittest.TestCase):
                        def test_a(self):
                            pass

                        def test_a(self):
                            pass

            try:
                import fcntl
            except ImportError:
                class Fallback:
                    def lock(self):
                        pass

                    def lock(self):
                        pass
        """)
        self.assertEqual([hit.split(";")[0] for hit in hits],
                         ["tests/test_x.py:8: Deep.test_a redefines line 5",
                          "tests/test_x.py:18: Fallback.lock redefines line 15"])

    def test_a_class_nested_in_a_method_is_read_once_under_its_own_scope(self) -> None:
        # #41818 review (F3): ast.walk() over a function also reached a class nested in a class inside it, so that
        # class was read twice, once under the function's scope instead of the class it sits in.
        hits = scan("""
            def make():
                class Outer:
                    class Inner:
                        def go(self):
                            pass

                        def go(self):
                            pass
                return Outer
        """)
        self.assertEqual([hit.split(";")[0] for hit in hits], ["tests/test_x.py:8: make.Outer.Inner.go redefines line 5"])

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

    def test_a_path_with_a_colon_is_scanned_without_crashing(self) -> None:
        # #41827 review: the hits were sorted by `int(hit.split(":")[1])`, which raised on `tests/a:b.py`.
        hits = check.scan_source("def a():\n    pass\n\n\ndef a():\n    pass\n\n\ndef b():\n    pass\n\n\n"
                                 "def b():\n    pass\n", "tests/test_a:b.py")
        self.assertEqual([hit.split(";")[0] for hit in hits],
                         ["tests/test_a:b.py:5: a redefines line 1", "tests/test_a:b.py:13: b redefines line 9"])

    def test_a_file_that_does_not_parse_is_no_verdict(self) -> None:
        # #41818 review (F2): it exited 1, a verdict, and the gate took that as "no redefinition" for the file.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "tests").mkdir()
            (root / "tests" / "test_broken.py").write_text("def a():\n    pass\n\n\ndef a(:\n    pass\n")
            result = subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(root)],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, check.UNPARSED_EXIT, result.stdout + result.stderr)
            self.assertIn("tests/test_broken.py:5: does not parse: ", result.stdout)

    def test_the_tree_is_clean(self) -> None:
        result = subprocess.run([sys.executable, "-I", str(SCRIPT)], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class Python39Test(unittest.TestCase):
    """The checker as a Mac's hook runs it: install-git-hooks.sh takes any python3, and macOS's is 3.9.6."""

    def test_a_39_run_on_a_plain_file_passes(self) -> None:
        # cmux#41827 review (F1): `ast.match_case` (3.10+) in the scope walk raised AttributeError on 3.9 for any file
        # with a block in it, so the gate refused clean pushes as no verdict.
        python = py39_names.python39()
        if python is None:
            self.fail("no Python 3.9 (PY39, python3.9, /usr/bin/python3 or uv): this row needs a real 3.9")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "tests").mkdir()
            (root / "tests" / "test_plain.py").write_text(textwrap.dedent("""
                import unittest


                class Plain(unittest.TestCase):
                    def setUp(self):
                        if True:
                            self.x = 1

                    def test_x(self):
                        for _ in range(2):
                            with self.subTest():
                                try:
                                    self.assertEqual(self.x, 1)
                                except AssertionError:
                                    raise
            """))
            result = subprocess.run([python, "-I", str(SCRIPT), "--root", str(root)], capture_output=True, text=True,
                                    check=False)
        self.assertEqual((result.returncode, result.stdout), (0, ""), result.stdout + result.stderr)


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

    def test_a_head_file_that_does_not_parse_refuses_with_no_verdict(self) -> None:
        # #41818 review (F2): the file holds a redefinition the parse error hides; the gate passed it.
        base = self.commit({"tests/test_a.py": LOCKED})
        head = self.commit({"tests/test_a.py": SHADOWED + "\ndef broken(:\n    pass\n"})
        found = gate.test_redefinition_problems(self.repo, base, head)
        self.assertEqual(len(found), 1, found)
        self.assertIsInstance(found[0], gate.NoVerdict, found)
        self.assertIn("could not parse tests/test_a.py:", found[0])

    def test_an_installed_checker_that_says_exit_1_on_a_parse_error_still_refuses(self) -> None:
        # The hook runs the installed reviewed copy, which can be older than the exit 2: its parse line alone refuses.
        installed = Path(tempfile.mkdtemp(dir=self.repo.parent))
        (installed / "check-test-redefinitions.py").write_text(
            "print('tests/test_a.py:7: does not parse: invalid syntax')\nraise SystemExit(1)\n")
        base = self.commit({"tests/test_a.py": LOCKED})
        head = self.commit({"tests/test_a.py": SHADOWED + "\ndef broken(:\n    pass\n"})
        found = gate.test_redefinition_problems(self.repo, base, head, trusted_scripts=installed)
        self.assertEqual(len(found), 1, found)
        self.assertIsInstance(found[0], gate.NoVerdict, found)

    def test_gate_own_subtracts_a_redefinition_an_upstream_range_added(self) -> None:
        # #41818 review (F1): a merge brings in upstream's tests/ redefinition. gate_own's runs over the upstream range
        # read only the files in its restrict set, which left tests/ out, so nothing was taken off and the push was
        # blamed for upstream's debt. The push's own redefinition still refuses.
        base = self.commit({"tests/test_a.py": LOCKED})
        upstream = self.commit({"tests/test_a.py": SHADOWED})
        head = self.commit({"tests/test_b.py": SHADOWED})
        own_range = sys.modules[gate.PUSH_RANGE_MODULE].OwnRange(head=head, base=base, before=((base, upstream),))
        found = dict(gate.gate_own(self.repo, own_range, {"redefinitions"}, False))
        self.assertEqual(list(found), [gate.REDEFINITION_CHECK], found)
        self.assertEqual([line.split(":")[0] for line in found[gate.REDEFINITION_CHECK]], ["tests/test_b.py"], found)

    def old_checker(self, body: str) -> Path:
        """An installed checker copy that prints BODY's lines, as an older or broken one would."""
        installed = Path(tempfile.mkdtemp(dir=self.repo.parent))
        (installed / "check-test-redefinitions.py").write_text(body)
        return installed

    def test_a_redefinition_in_a_test_path_with_a_colon_is_refused(self) -> None:
        # #41827 review (F1): the finding pattern read the path as `[^:]+`, so `tests/test_a:b.py:5: ...` matched
        # nothing and the push passed the redefinition it added.
        base = self.commit({"tests/test_a:b.py": LOCKED})
        head = self.commit({"tests/test_a:b.py": SHADOWED})
        found = gate.test_redefinition_problems(self.repo, base, head)
        self.assertEqual(len(found), 1, found)
        self.assertTrue(found[0].startswith("tests/test_a:b.py:5: T.helper redefines line 2"), found)

    def test_an_old_checkers_parse_error_on_a_path_with_a_colon_refuses(self) -> None:
        # #41827 review (F1): an installed checker older than exit 2 says exit 1 for a parse error, and the parse
        # pattern's `[^:]+` path never matched `tests/test_a:b.py`, so the push read as clean.
        installed = self.old_checker("print('tests/test_a:b.py:7: does not parse: invalid syntax')\nraise SystemExit(1)\n")
        base = self.commit({"tests/test_a:b.py": LOCKED})
        head = self.commit({"tests/test_a:b.py": SHADOWED + "\ndef broken(:\n    pass\n"})
        found = gate.test_redefinition_problems(self.repo, base, head, trusted_scripts=installed)
        self.assertEqual(len(found), 1, found)
        self.assertIsInstance(found[0], gate.NoVerdict, found)
        self.assertIn("could not parse tests/test_a:b.py:7", found[0])

    def test_an_exit_1_the_gate_cannot_read_refuses(self) -> None:
        # Exit 1 is the checker's "findings" verdict only when its output names them; a line in another shape, or none,
        # is no verdict.
        for body in ("print('something went sideways')\nraise SystemExit(1)\n", "raise SystemExit(1)\n"):
            with self.subTest(body=body):
                installed = self.old_checker(body)
                base = self.commit({"tests/test_a.py": LOCKED + "\n# " + body[:5] + "\n"})
                head = self.commit({"tests/test_a.py": SHADOWED + "\n# " + body[:5] + "\n"})
                found = gate.test_redefinition_problems(self.repo, base, head, trusted_scripts=installed)
                self.assertEqual(len(found), 1, found)
                self.assertIsInstance(found[0], gate.NoVerdict, found)

    def test_old_debt_in_a_path_with_a_colon_still_subtracts(self) -> None:
        base = self.commit({"tests/test_a:b.py": SHADOWED})
        head = self.commit({"tests/test_a:b.py": "import os\n\n\n" + SHADOWED})
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
