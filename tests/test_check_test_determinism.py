#!/usr/bin/env python3
"""Behavioral CLI coverage for scripts/check-test-determinism.py."""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
CHECKER = pathlib.Path(
    os.environ.get(
        "CMUX_TEST_DETERMINISM_CHECKER",
        REPO_ROOT / "scripts" / "check-test-determinism.py",
    )
)


class DeterminismCheckerCLITests(unittest.TestCase):
    def run_checker(
        self,
        files: dict[str, str],
        *,
        strict: bool = True,
        allowlist: str = "",
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            repo_root = pathlib.Path(temporary)
            fixture_root = repo_root / "fixtures"
            for relative_path, source in files.items():
                path = fixture_root / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source, encoding="utf-8")
            allowlist_path = repo_root / "allowlist.txt"
            allowlist_path.write_text(allowlist, encoding="utf-8")
            command = [
                sys.executable,
                str(CHECKER),
                "--repo-root",
                str(repo_root),
                "--roots",
                "fixtures",
                "--allowlist",
                str(allowlist_path),
            ]
            if strict:
                command.append("--strict")
            return subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )

    def test_explicit_real_sleep_apis_are_reported(self) -> None:
        fixtures = {
            "task.swift": (
                "try await Task.sleep(nanoseconds: 1)\n"
                "#expect(finished)\n"
            ),
            "specialized-task.swift": (
                "try await Task<Never, Never>.sleep(nanoseconds: 1)\n"
                "#expect(finished)\n"
            ),
            "thread.swift": (
                "Thread.sleep(forTimeInterval: 0.01)\n"
                "#expect(finished)\n"
            ),
            "posix.swift": "sleep(1)\n#expect(finished)\n",
            "darwin.swift": "Darwin.sleep(1)\n#expect(finished)\n",
            "glibc.swift": "Glibc.sleep(1)\n#expect(finished)\n",
            "darwin-usleep.swift": "Darwin.usleep(1)\n#expect(finished)\n",
            "glibc-nanosleep.swift": (
                "Glibc.nanosleep(nil, nil)\n"
                "#expect(finished)\n"
            ),
            "usleep.swift": "usleep(1)\n#expect(finished)\n",
            "nanosleep.swift": "nanosleep(nil, nil)\n#expect(finished)\n",
            "time.py": "time.sleep(0.01)\nassert finished\n",
            "module-annotation.py": (
                "marker: time.sleep(0.01)\n"
                "assert finished\n"
            ),
            "asyncio.py": "await asyncio.sleep(0.01)\nassert finished\n",
            "bun.ts": "await Bun.sleep(1)\nexpect(finished).toBe(true)\n",
            "timeout.ts": (
                "await new Promise(resolve => setTimeout(resolve, 1))\n"
                "expect(finished).toBe(true)\n"
            ),
            "window-timeout.ts": (
                "await new Promise(resolve => window.setTimeout(resolve, 1))\n"
                "expect(finished).toBe(true)\n"
            ),
            "global-this-timeout.ts": (
                "await new Promise(resolve => globalThis.setTimeout(resolve, 1))\n"
                "expect(finished).toBe(true)\n"
            ),
            "shell.sh": 'sleep 1\nassert "$actual" "$expected"\n',
            "shell-variable.sh": (
                'sleep "$STARTUP_DELAY"\n'
                'assert "$actual" "$expected"\n'
            ),
            "shell-shebang.sh": (
                "#!/bin/sh\n"
                "sleep 1\n"
                'assert "$actual" "$expected"\n'
            ),
            "shell-interpolation.sh": (
                'actual="$(start_job; sleep 1; read_state)"\n'
                'assert "$actual" "$expected"\n'
            ),
            "shell-direct-interpolation.sh": (
                'actual="$(sleep 1)"\n'
                'assert "$actual" "$expected"\n'
            ),
            "shell-backtick.sh": (
                "actual=`sleep 1`\n"
                'assert "$actual" "$expected"\n'
            ),
            "shell-if-then.sh": (
                "if ready; then sleep 1; fi\n"
                'assert "$actual" "$expected"\n'
            ),
            "shell-case.sh": (
                'case "$state" in ready) sleep 1 ;; esac\n'
                'assert "$actual" "$expected"\n'
            ),
            "shell-quoted-backtick.sh": (
                'actual="before `sleep 1` after"\n'
                'assert "$actual" "$expected"\n'
            ),
            "shell-multiline-substitution.sh": (
                'actual="$(sleep 1\n'
                ')"\n'
                'assert "$actual" "$expected"\n'
            ),
            "shell-multiline-backtick.sh": (
                'actual="`sleep 1\n'
                '`"\n'
                'assert "$actual" "$expected"\n'
            ),
            "template-interpolation.ts": (
                "const actual = `${await Bun.sleep(1)}`\n"
                "expect(actual).toBeTruthy()\n"
            ),
            "template-multiline-interpolation.ts": (
                "const actual = `${\n"
                "  await Bun.sleep(1)\n"
                "}`\n"
                "expect(actual).toBeTruthy()\n"
            ),
        }

        result = self.run_checker(fixtures)

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for relative_path in fixtures:
            line = (
                2
                if relative_path
                in (
                    "shell-shebang.sh",
                    "template-multiline-interpolation.ts",
                )
                else 1
            )
            self.assertIn(
                f"fixtures/{relative_path}:{line}: sleep-then-assert:",
                result.stdout,
            )

    def test_virtual_and_unknown_sleep_receivers_remain_silent(self) -> None:
        result = self.run_checker(
            {
                "virtual.swift": (
                    "#expect(await clockEvents.next() == .sleep(initialRefresh))\n"
                    "clock.advance(to: initialRefresh)\n"
                    "#expect(await clockEvents.next() == .sleep(replacementRefresh))\n"
                    "#expect(await endpoint.updateCount == 2)\n"
                    "try await clock.sleep(until: deadline)\n"
                    "#expect(await completed)\n"
                    "try await fixture.clock.sleep(until: deadline)\n"
                    "#expect(await completed)\n"
                    "try await environment.timing.clock.sleep(until: deadline)\n"
                    "#expect(await completed)\n"
                    "try await ContinuousClock().sleep(until: deadline)\n"
                    "#expect(await completed)\n"
                    "try await SystemUpdateClock().sleep(until: deadline)\n"
                    "#expect(await completed)\n"
                ),
                "virtual.py": (
                    "fake_clock.sleep(1)\n"
                    "assert completed\n"
                    "fixture.trio.sleep(1)\n"
                    "assert completed\n"
                    "fixture.time.sleep(1)\n"
                    "assert completed\n"
                ),
                "virtual.ts": (
                    "await fixture.Bun.sleep(1)\n"
                    "expect(completed).toBe(true)\n"
                ),
                "cross-language.swift": (
                    "Bun.sleep(1)\n"
                    "#expect(completed)\n"
                    "time.sleep(1)\n"
                    "#expect(completed)\n"
                ),
                "cross-language.py": (
                    "Bun.sleep(1)\n"
                    "assert completed\n"
                    "setTimeout(done, 1)\n"
                    "assert completed\n"
                ),
                "cross-language.ts": (
                    "time.sleep(1)\n"
                    "expect(completed).toBe(true)\n"
                    "Task.sleep(1)\n"
                    "expect(completed).toBe(true)\n"
                ),
            }
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("test-determinism: 0 active finding(s)", result.stdout)

    def test_python_import_aliases_are_tracked_until_shadowed(self) -> None:
        positive = self.run_checker(
            {
                "time-alias.py": (
                    "import time as clock_time\n"
                    "clock_time.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "from-time.py": (
                    "from time import sleep\n"
                    "sleep(0.01)\n"
                    "assert finished\n"
                ),
                "from-asyncio.py": (
                    "from asyncio import sleep as pause\n"
                    "await pause(0.01)\n"
                    "assert finished\n"
                ),
                "import-list.py": (
                    "import os, time as clock_time\n"
                    "clock_time.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "parenthesized-from-time.py": (
                    "from time import (\n"
                    "    sleep as pause,\n"
                    ")\n"
                    "pause(0.01)\n"
                    "assert finished\n"
                ),
                "from-trio.py": (
                    "from trio import sleep as pause\n"
                    "await pause(0.01)\n"
                    "assert finished\n"
                ),
                "from-anyio.py": (
                    "from anyio import sleep as pause\n"
                    "await pause(0.01)\n"
                    "assert finished\n"
                ),
                "from-gevent.py": (
                    "from gevent import sleep as pause\n"
                    "pause(0.01)\n"
                    "assert finished\n"
                ),
                "same-line-import.py": (
                    "import time; time.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "same-line-from-import.py": (
                    "from trio import sleep as pause; await pause(0.01)\n"
                    "assert finished\n"
                ),
            }
        )

        self.assertEqual(
            positive.returncode,
            1,
            positive.stdout + positive.stderr,
        )
        for relative_path in (
            "time-alias.py",
            "from-time.py",
            "from-asyncio.py",
            "import-list.py",
            "parenthesized-from-time.py",
            "from-trio.py",
            "from-anyio.py",
            "from-gevent.py",
            "same-line-import.py",
            "same-line-from-import.py",
        ):
            line = (
                4
                if relative_path == "parenthesized-from-time.py"
                else 1
                if relative_path.startswith("same-line-")
                else 2
            )
            self.assertIn(
                f"fixtures/{relative_path}:{line}: sleep-then-assert:",
                positive.stdout,
            )

        negative = self.run_checker(
            {
                "module-rebound.py": (
                    "time = fake_clock\n"
                    "time.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "alias-rebound.py": (
                    "import time as clock_time\n"
                    "clock_time = fake_clock\n"
                    "clock_time.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "parameter-shadow.py": (
                    "def wait(time):\n"
                    "    time.sleep(0.01)\n"
                    "    assert finished\n"
                ),
                "multiline-parameter-shadow.py": (
                    "def wait(\n"
                    "    time,\n"
                    "):\n"
                    "    time.sleep(0.01)\n"
                    "    assert finished\n"
                ),
                "nested-default-parameter-shadow.py": (
                    "def wait(factory=make(), time=fake_clock):\n"
                    "    time.sleep(0.01)\n"
                    "    assert finished\n"
                ),
                "walrus-shadow.py": (
                    "if (time := fake_clock):\n"
                    "    pass\n"
                    "time.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "tuple-shadow.py": (
                    "time, other = fake_clock, object()\n"
                    "time.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "deleted-module.py": (
                    "import asyncio\n"
                    "del asyncio\n"
                    "await asyncio.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "class-shadow.py": (
                    "class time: pass\n"
                    "time.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "unrelated-import-shadow.py": (
                    "import fake_clock as time\n"
                    "time.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "unrelated-from-import-shadow.py": (
                    "from fake_clock import clock as asyncio\n"
                    "await asyncio.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "parenthesized-from-import-shadow.py": (
                    "from fake_clock import (\n"
                    "    time,\n"
                    ")\n"
                    "time.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "star-import-shadow.py": (
                    "from fake_clock import *\n"
                    "time.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "same-line-import-shadow.py": (
                    "import fake_clock as time; time.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "lambda-parameter-shadow.py": (
                    "run(lambda time: time.sleep(0.01))\n"
                    "assert finished\n"
                ),
                "multiline-lambda-parameter-shadow.py": (
                    "run(lambda time: (\n"
                    "    time.sleep(0.01)\n"
                    "))\n"
                    "assert finished\n"
                ),
                "class-body-shadow.py": (
                    "class Tests:\n"
                    "    time = fake_clock\n"
                    "    time.sleep(0.01)\n"
                    "    assert finished\n"
                ),
            }
        )

        self.assertEqual(
            negative.returncode,
            0,
            negative.stdout + negative.stderr,
        )
        self.assertIn(
            "test-determinism: 0 active finding(s)",
            negative.stdout,
        )

    def test_python_local_shadows_do_not_leak_to_later_scopes(self) -> None:
        fixtures = {
            "function-shadow.py": (
                "def helper(time):\n"
                "    time.sleep(0.01)\n"
                "    assert helper_finished\n"
                "time.sleep(0.01)\n"
                "assert finished\n"
            ),
            "lambda-shadow.py": (
                "run(lambda time: time.sleep(0.01))\n"
                "time.sleep(0.01)\n"
                "assert finished\n"
            ),
            "local-import-shadow.py": (
                "def helper():\n"
                "    import fake_clock as time\n"
                "    time.sleep(0.01)\n"
                "    assert helper_finished\n"
                "time.sleep(0.01)\n"
                "assert finished\n"
            ),
            "local-trusted-import.py": (
                "def helper():\n"
                "    from trio import sleep as pause\n"
                "    await pause(0.01)\n"
                "    assert finished\n"
            ),
            "attribute-assignment.py": (
                "fixture.time = fake_clock\n"
                "time.sleep(0.01)\n"
                "assert finished\n"
            ),
            "nested-attribute-assignment.py": (
                "module.time.sleep = stub\n"
                "time.sleep(0.01)\n"
                "assert finished\n"
            ),
            "keyword-argument.py": (
                "configure(time=fake_clock)\n"
                "time.sleep(0.01)\n"
                "assert finished\n"
            ),
            "class-method-global.py": (
                "import time\n"
                "class Tests:\n"
                "    time = fake_clock\n"
                "    def test(self):\n"
                "        time.sleep(0.01)\n"
                "        assert finished\n"
            ),
            "lambda-and-real-sleep.py": (
                "values = [lambda time: None, time.sleep(0.01)]\n"
                "assert finished\n"
            ),
        }

        result = self.run_checker(fixtures)

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        expected_lines = {
            "function-shadow.py": 4,
            "lambda-shadow.py": 2,
            "local-import-shadow.py": 5,
            "local-trusted-import.py": 3,
            "attribute-assignment.py": 2,
            "nested-attribute-assignment.py": 2,
            "keyword-argument.py": 2,
            "class-method-global.py": 5,
            "lambda-and-real-sleep.py": 1,
        }
        findings = [
            line
            for line in result.stdout.splitlines()
            if "sleep-then-assert:" in line
        ]
        self.assertEqual(len(findings), len(fixtures), result.stdout)
        for relative_path, line in expected_lines.items():
            self.assertIn(
                f"fixtures/{relative_path}:{line}: sleep-then-assert:",
                result.stdout,
            )

    def test_python_executable_expressions_are_scanned(self) -> None:
        positive = self.run_checker(
            {
                "f-string.py": (
                    'rendered = f"{time.sleep(0.01)}"\n'
                    "assert finished\n"
                ),
                "default-argument.py": (
                    "def helper(value=time.sleep(0.01)):\n"
                    "    return value\n"
                    "assert finished\n"
                ),
                "default-before-annotation.py": (
                    "def helper(value=time.sleep(0.01), "
                    "marker: (time := fake)=None): pass\n"
                    "assert finished\n"
                ),
            }
        )

        self.assertEqual(
            positive.returncode,
            1,
            positive.stdout + positive.stderr,
        )
        expected_lines = {
            "f-string.py": 1,
            "default-argument.py": 1,
            "default-before-annotation.py": 1,
        }
        for relative_path, line in expected_lines.items():
            self.assertIn(
                f"fixtures/{relative_path}:{line}: sleep-then-assert:",
                positive.stdout,
            )

    def test_python_statements_rebind_aliases_in_order(self) -> None:
        negative = self.run_checker(
            {
                "module-alias-rebound.py": (
                    "import time as clock; clock = fake; clock.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "function-alias-rebound.py": (
                    "from time import sleep as pause; pause = fake; pause(0.01)\n"
                    "assert finished\n"
                ),
            }
        )

        self.assertEqual(
            negative.returncode,
            0,
            negative.stdout + negative.stderr,
        )
        self.assertIn(
            "test-determinism: 0 active finding(s)",
            negative.stdout,
        )

    def test_python_same_line_sleep_assert_order_is_preserved(self) -> None:
        positive = self.run_checker(
            {
                "sleep-before-assert.py": (
                    "time.sleep(0.01); assert finished\n"
                ),
            }
        )

        self.assertEqual(
            positive.returncode,
            1,
            positive.stdout + positive.stderr,
        )
        self.assertIn(
            "fixtures/sleep-before-assert.py:1: sleep-then-assert:",
            positive.stdout,
        )

        negative = self.run_checker(
            {
                "assert-before-sleep.py": (
                    "assert finished; time.sleep(0.01)\n"
                ),
            }
        )

        self.assertEqual(
            negative.returncode,
            0,
            negative.stdout + negative.stderr,
        )
        self.assertIn(
            "test-determinism: 0 active finding(s)",
            negative.stdout,
        )

    def test_python_comprehension_walrus_shadows_parent_name(self) -> None:
        result = self.run_checker(
            {
                "comprehension-walrus.py": (
                    "[(time := fake_clock) for _ in clocks]\n"
                    "time.sleep(0.01)\n"
                    "assert finished\n"
                ),
            }
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "test-determinism: 0 active finding(s)",
            result.stdout,
        )

    def test_python_dotted_import_keeps_trusted_root(self) -> None:
        result = self.run_checker(
            {
                "dotted-import.py": (
                    "import asyncio.tasks\n"
                    "await asyncio.sleep(0.01)\n"
                    "assert finished\n"
                ),
            }
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(
            "fixtures/dotted-import.py:2: sleep-then-assert:",
            result.stdout,
        )

    def test_python_non_executable_annotations_remain_silent(self) -> None:
        result = self.run_checker(
            {
                "local-annotation.py": (
                    "def test_case():\n"
                    "    marker: time.sleep(0.01)\n"
                    "    assert finished\n"
                ),
                "future-module-annotation.py": (
                    "from __future__ import annotations\n"
                    "marker: time.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "future-class-annotation.py": (
                    "from __future__ import annotations\n"
                    "class TestCase:\n"
                    "    marker: time.sleep(0.01)\n"
                    "    assert finished\n"
                ),
                "future-signature-annotation.py": (
                    "from __future__ import annotations\n"
                    "def test_case(marker: time.sleep(0.01)): pass\n"
                    "assert finished\n"
                ),
            }
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "test-determinism: 0 active finding(s)",
            result.stdout,
        )

    def test_python_try_prefix_shadow_reaches_handler(self) -> None:
        result = self.run_checker(
            {
                "try-prefix-shadow.py": (
                    "import time\n"
                    "try:\n"
                    "    time = fake_clock\n"
                    "    raise RuntimeError\n"
                    "except RuntimeError:\n"
                    "    time.sleep(0.01)\n"
                    "    assert finished\n"
                ),
            }
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "test-determinism: 0 active finding(s)",
            result.stdout,
        )

    def test_python_annotated_assignment_binding_order(self) -> None:
        positive = self.run_checker(
            {
                "annotation-only.py": (
                    "from time import sleep\n"
                    "sleep: Callable\n"
                    "sleep(0.01); assert finished\n"
                ),
            }
        )

        self.assertEqual(
            positive.returncode,
            1,
            positive.stdout + positive.stderr,
        )
        self.assertIn(
            "fixtures/annotation-only.py:3: sleep-then-assert:",
            positive.stdout,
        )

        negative = self.run_checker(
            {
                "valued-annotation.py": (
                    "time: time.sleep(0.01) = fake_clock\n"
                    "assert finished\n"
                ),
            }
        )

        self.assertEqual(
            negative.returncode,
            0,
            negative.stdout + negative.stderr,
        )
        self.assertIn(
            "test-determinism: 0 active finding(s)",
            negative.stdout,
        )

    def test_shell_heredoc_bodies_remain_silent(self) -> None:
        result = self.run_checker(
            {
                "quoted-heredoc.sh": (
                    "cat <<'EOF'\n"
                    "sleep 1\n"
                    "EOF\n"
                    'assert "$actual" "$expected"\n'
                ),
                "tab-heredoc.sh": (
                    "cat <<-EOF\n"
                    "\tsleep 1\n"
                    "\tEOF\n"
                    'assert "$actual" "$expected"\n'
                ),
                "backslash-heredoc.sh": (
                    "cat <<\\EOF\n"
                    "$(sleep 1)\n"
                    "EOF\n"
                    'assert "$actual" "$expected"\n'
                ),
            }
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "test-determinism: 0 active finding(s)",
            result.stdout,
        )

    def test_unquoted_heredoc_substitutions_are_executable(self) -> None:
        result = self.run_checker(
            {
                "heredoc-substitution.sh": (
                    "cat <<EOF\n"
                    "$(sleep 1)\n"
                    "EOF\n"
                    'assert "$actual" "$expected"\n'
                ),
                "heredoc-backtick.sh": (
                    "cat <<EOF\n"
                    "`sleep 1`\n"
                    "EOF\n"
                    'assert "$actual" "$expected"\n'
                ),
            }
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for relative_path in (
            "heredoc-substitution.sh",
            "heredoc-backtick.sh",
        ):
            self.assertIn(
                f"fixtures/{relative_path}:2: sleep-then-assert:",
            result.stdout,
        )

    def test_multiline_javascript_sleep_calls_are_reported(self) -> None:
        result = self.run_checker(
            {
                "multiline-bun.ts": (
                    "await Bun.sleep\n"
                    "(1)\n"
                    "expect(finished).toBe(true)\n"
                ),
                "multiline-timeout.ts": (
                    "setTimeout\n"
                    "(resolve, 1)\n"
                    "expect(finished).toBe(true)\n"
                ),
            }
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for relative_path in ("multiline-bun.ts", "multiline-timeout.ts"):
            self.assertIn(
                f"fixtures/{relative_path}:1: sleep-then-assert:",
                result.stdout,
            )

    def test_multiline_specialized_task_sleep_is_reported(self) -> None:
        result = self.run_checker(
            {
                "multiline-specialized-task.swift": (
                    "try await Task<\n"
                    "    Never,\n"
                    "    Never\n"
                    ">.sleep(nanoseconds: 1)\n"
                    "#expect(finished)\n"
                ),
            }
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(
            "fixtures/multiline-specialized-task.swift:4: "
            "sleep-then-assert:",
            result.stdout,
        )

    def test_sleep_text_inside_strings_and_comments_remains_silent(self) -> None:
        result = self.run_checker(
            {
                "strings.swift": (
                    'let command = "Task.sleep(nanoseconds: 1)"\n'
                    "#expect(command.isEmpty == false)\n"
                    "// Thread.sleep(forTimeInterval: 1)\n"
                    "#expect(finished)\n"
                ),
                "assertion-fixture.swift": (
                    "try await Task.sleep(nanoseconds: 1)\n"
                    'let source = "#expect(finished)"\n'
                    "let finished = true\n"
                ),
                "assertion-block-comment.swift": (
                    "try await Task.sleep(nanoseconds: 1)\n"
                    "/* #expect(finished) */\n"
                    "let finished = true\n"
                ),
                "strings.py": (
                    'command = "time.sleep(1)"\n'
                    "assert command\n"
                    "# asyncio.sleep(1)\n"
                    "assert finished\n"
                ),
                "strings.ts": (
                    "const source = `setTimeout(resolve, 1)`\n"
                    "expect(source).toBeTruthy()\n"
                    "// Bun.sleep(1)\n"
                    "expect(finished).toBe(true)\n"
                    'const nested = `${"Bun.sleep(1)"}`\n'
                    "expect(nested).toBeTruthy()\n"
                    "const escaped = `\\${Bun.sleep(1)}`\n"
                    "expect(escaped).toBeTruthy()\n"
                ),
                "strings.sh": (
                    "actual=\"$(printf 'sleep 1')\"\n"
                    'assert "$actual" "$expected"\n'
                    'escaped="\\$(sleep 1)"\n'
                    'assert "$escaped" "$expected"\n'
                    'escaped_backtick="\\`sleep 1\\`"\n'
                    'assert "$escaped_backtick" "$expected"\n'
                    "fixture='$(sleep 1)'\n"
                    'assert "$fixture" "$expected"\n'
                    "operator_fixture='before ; sleep 1'\n"
                    'assert "$operator_fixture" "$expected"\n'
                ),
            }
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("test-determinism: 0 active finding(s)", result.stdout)

    def test_mixed_virtual_and_real_sleep_reports_only_real_delay(self) -> None:
        result = self.run_checker(
            {
                "mixed.swift": (
                    "#expect(await events.next() == .sleep(deadline))\n"
                    "clock.advance(to: deadline)\n"
                    "try await Task.sleep(nanoseconds: 1)\n"
                    "#expect(finished)\n"
                )
            }
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        findings = [
            line
            for line in result.stdout.splitlines()
            if "sleep-then-assert:" in line
        ]
        self.assertEqual(len(findings), 1, result.stdout)
        self.assertIn("fixtures/mixed.swift:3:", findings[0])

    def test_non_strict_mode_reports_without_failing(self) -> None:
        result = self.run_checker(
            {"delay.py": "time.sleep(0.01)\nassert finished\n"},
            strict=False,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("fixtures/delay.py:1: sleep-then-assert:", result.stdout)
        self.assertIn("(non-strict mode: not failing.", result.stdout)

    def test_allowlisted_finding_is_suppressed(self) -> None:
        result = self.run_checker(
            {"delay.py": "time.sleep(0.01)\nassert finished\n"},
            allowlist=(
                "fixtures/delay.py\tsleep-then-assert\t"
                "behavioral suppression fixture\n"
            ),
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "test-determinism: 0 active finding(s), 1 allowlisted, 1 total",
            result.stdout,
        )

    def test_other_determinism_rules_remain_enforced(self) -> None:
        result = self.run_checker(
            {
                "duration.py": (
                    "elapsed_ms = time.perf_counter() - started\n"
                    "ass" "ert elapsed_" "ms < 50\n"
                ),
                "network.ts": (
                    "await fet" "ch('https://" "api.example.net/items')\n"
                ),
                "port.py": "server.bind(('127.0.0.1', 80" "80))\n",
            }
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("fixtures/duration.py:2: assert-on-duration:", result.stdout)
        self.assertIn("fixtures/network.ts:1: live-network-host:", result.stdout)
        self.assertIn("fixtures/port.py:1: fixed-port-bind:", result.stdout)

    def test_self_test_passes_through_cli(self) -> None:
        result = subprocess.run(
            [sys.executable, str(CHECKER), "--self-test"],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"self-test OK: \d+ positive \+ \d+ negative")


if __name__ == "__main__":
    unittest.main()
