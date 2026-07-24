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
        timeout: float | None = None,
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
                timeout=timeout,
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
            "js-comment-close.ts": (
                "/* mention /* */\n"
                "await Bun.sleep(1)\n"
                "expect(finished).toBe(true)\n"
            ),
            "swift-interpolation.swift": (
                'let value = "\\(Thread.sleep(forTimeInterval: 1))"\n'
                "#expect(finished)\n"
            ),
            "swift-raw-interpolation.swift": (
                'let value = #"\\#(Task.sleep(nanoseconds: 1))"#\n'
                "#expect(finished)\n"
            ),
            "swift-multiline-interpolation.swift": (
                'let value = """\n'
                "\\(\n"
                "    Thread.sleep(forTimeInterval: 1)\n"
                ")\n"
                '"""\n'
                "#expect(finished)\n"
            ),
            "swift-raw-multiline-interpolation.swift": (
                'let value = ##"""\n'
                "\\##(\n"
                "    Task.sleep(nanoseconds: 1)\n"
                ")\n"
                '"""##\n'
                "#expect(finished)\n"
            ),
            "shell-time.sh": (
                "time sleep 1\n"
                'assert "$actual" "$expected"\n'
            ),
            "shell-arithmetic-before-sleep.sh": (
                "mask=$((1 << 3))\n"
                "sleep 1\n"
                'assert "$actual" "$expected"\n'
            ),
            "shell-multiline-arithmetic-before-sleep.sh": (
                "mask=$((\n"
                "    1 << 3\n"
                "))\n"
                "sleep 1\n"
                'assert "$actual" "$expected"\n'
            ),
            "shell-assert-substitution.sh": (
                'assert "$(prepare; sleep 1)"\n'
            ),
            "shell-assert-multiline-substitution.sh": (
                'assert "$(\n'
                "prepare\n"
                "sleep 1\n"
                ')"\n'
            ),
            "closing-line-timeout.ts": (
                "setTimeout(\n"
                "    resolve, 1\n"
                "); expect(done).toBe(true)\n"
            ),
            "closing-line-task.swift": (
                "try await Task.sleep(\n"
                "    nanoseconds: 1\n"
                "); #expect(done)\n"
            ),
            "closing-line-python.py": (
                "time.sleep(\n"
                "    0.1\n"
                "); assert done\n"
            ),
            "tsx-closing-tags.tsx": (
                "const view = <div><span></span>"
                "{setTimeout(done, 1)}</div>\n"
                "expect(done).toBe(true)\n"
            ),
            "shell-assignment-prefix.sh": (
                'DELAY=1 sleep "$DELAY"\n'
                'assert "$actual" "$expected"\n'
            ),
            "deferred-global-write.py": (
                "def poison():\n"
                "    global time\n"
                "    time = fake_time\n"
                "time.sleep(0.1)\n"
                "assert done\n"
            ),
            "deferred-nonlocal-write.py": (
                "def outer():\n"
                "    import time\n"
                "    def poison():\n"
                "        nonlocal time\n"
                "        time = fake_time\n"
                "    time.sleep(0.1)\n"
                "    assert done\n"
            ),
            "mixed-quoted-heredoc-then-sleep.sh": (
                'cat <<E"OF"\n'
                "sleep 99\n"
                "EOF\n"
                "sleep 1\n"
                'assert "$actual" "$expected"\n'
            ),
            "template-regex-brace.ts": (
                'const value = `${/}/.test(input) ? Bun.sleep(1) : ""}`\n'
                "expect(done).toBe(true)\n"
            ),
            "shell-substitution-assignment.sh": (
                "DELAY=$(compute_delay) sleep 1\n"
                'assert "$actual" "$expected"\n'
            ),
            "shell-quoted-substitution-assignment.sh": (
                'DELAY="$(compute_delay)" sleep 1\n'
                'assert "$actual" "$expected"\n'
            ),
            "shell-parameter-trim-before-sleep.sh": (
                "trimmed=${value#prefix}; sleep 1\n"
                'assert "$actual" "$expected"\n'
            ),
            "class-name-visible-during-body.py": (
                "import time\n"
                "class time:\n"
                "    time.sleep(0.1)\n"
                "    assert done\n"
            ),
            "shell-assert-arithmetic-substitution.sh": (
                'assert "$(echo $((1 + 2)); sleep 1)"\n'
            ),
            "shell-expansion-suffix-before-sleep.sh": (
                "value=$(printf ok)#suffix; sleep 1\n"
                'assert "$actual" "$expected"\n'
            ),
            "shell-quoted-closer-expansion-suffix.sh": (
                "value=$(printf ')')#suffix; sleep 1\n"
                'assert "$actual" "$expected"\n'
            ),
            "unicode-before-multiline-sleep.py": (
                "éééééééééééééééééééé = time.sleep(\n"
                "    0.1\n"
                ")\n"
                "marker = 1\n"
                "assert done\n"
            ),
            "quoted-backslash-heredoc-then-sleep.sh": (
                'cat <<"E\\OF"\n'
                "sleep 99\n"
                "E\\OF\n"
                "sleep 1\n"
                'assert "$actual" "$expected"\n'
            ),
            "case-assignment-prefix.sh": (
                'case "$state" in ready) DELAY=1 sleep "$DELAY" ;; esac\n'
                'assert "$actual" "$expected"\n'
            ),
            "later-case-arm.sh": (
                'case "$state" in ready) : ;; waiting) sleep 1 ;; esac\n'
                'assert "$actual" "$expected"\n'
            ),
            "continued-assert-substitution.sh": (
                "assert \\\n"
                '"$(sleep 1)"\n'
            ),
            "continued-assert-backtick.sh": (
                "assert \\\n"
                '"`sleep 1`"\n'
            ),
            "multiline-shell-sleep-argument.sh": (
                'sleep "$(\n'
                "prepare_one\n"
                "prepare_two\n"
                "prepare_three\n"
                "prepare_four\n"
                ')"\n'
                'assert "$ready"\n'
            ),
            "comment-separated-bun.ts": (
                "Bun/* runtime */.sleep(1)\n"
                "expect(done).toBe(true)\n"
            ),
            "comment-separated-global-timeout.ts": (
                "globalThis/* native */.setTimeout(resolve, 1)\n"
                "expect(done).toBe(true)\n"
            ),
            "regex-comment-marker-before-sleep.ts": (
                "const pattern = /[/*]/\n"
                "Bun.sleep(1)\n"
                "expect(done).toBe(true)\n"
            ),
            "asserted-case-substitution.sh": (
                'assert "$(case "$state" in '
                'ready) sleep 1; echo ready ;; esac)"\n'
            ),
            "multiline-case-assignment.sh": (
                'case "$state" in\n'
                'ready) DELAY=1 sleep "$DELAY" ;;\n'
                "esac\n"
                'assert "$ready"\n'
            ),
        }

        result = self.run_checker(fixtures)

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for relative_path in fixtures:
            line = (
                6
                if relative_path == "deferred-nonlocal-write.py"
                else
                4
                if relative_path
                in (
                    "shell-multiline-arithmetic-before-sleep.sh",
                    "deferred-global-write.py",
                    "mixed-quoted-heredoc-then-sleep.sh",
                    "quoted-backslash-heredoc-then-sleep.sh",
                )
                else
                3
                if relative_path
                in (
                    "swift-multiline-interpolation.swift",
                    "swift-raw-multiline-interpolation.swift",
                    "shell-assert-multiline-substitution.sh",
                    "class-name-visible-during-body.py",
                )
                else
                2
                if relative_path
                in (
                    "shell-shebang.sh",
                    "template-multiline-interpolation.ts",
                    "js-comment-close.ts",
                    "shell-arithmetic-before-sleep.sh",
                    "continued-assert-substitution.sh",
                    "continued-assert-backtick.sh",
                    "regex-comment-marker-before-sleep.ts",
                    "multiline-case-assignment.sh",
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
                "spaced-members.ts": (
                    "fixture. setTimeout(resolve, 1)\n"
                    "expect(completed).toBe(true)\n"
                    "fixture./* delegate */setTimeout(resolve, 1)\n"
                    "expect(completed).toBe(true)\n"
                ),
                "dollar-identifiers.ts": (
                    "$setTimeout(callback, 1)\n"
                    "expect(completed).toBe(true)\n"
                    "$Bun.sleep(1)\n"
                    "expect(completed).toBe(true)\n"
                    "$globalThis.setTimeout(callback, 1)\n"
                    "expect(completed).toBe(true)\n"
                ),
                "projected-identifiers.swift": (
                    "$sleep(1)\n"
                    "#expect(completed)\n"
                    "$Task.sleep(nanoseconds: 1)\n"
                    "#expect(completed)\n"
                    "$Thread.sleep(forTimeInterval: 1)\n"
                    "#expect(completed)\n"
                ),
                "raw-strings.swift": (
                    'let source = #"fixture " '
                    'Task.sleep(nanoseconds: 1) "#\n'
                    "#expect(source.isEmpty == false)\n"
                    'let source2 = ##"fixture "# '
                    'Thread.sleep(forTimeInterval: 1) "##\n'
                    "#expect(source2.isEmpty == false)\n"
                ),
                "closure-shadow.py": (
                    "def outer():\n"
                    "    def inner():\n"
                    "        time.sleep(0.1)\n"
                    "        assert done\n"
                    "    time = fake_time\n"
                    "    inner()\n"
                ),
                "class-global-shadow.py": (
                    "class Fixture:\n"
                    "    global time\n"
                    "    time = fake_time\n"
                    "time.sleep(0.1)\n"
                    "assert done\n"
                ),
                "class-nonlocal-shadow.py": (
                    "def outer():\n"
                    "    import time\n"
                    "    class Fixture:\n"
                    "        nonlocal time\n"
                    "        time = fake_time\n"
                    "    time.sleep(0.1)\n"
                    "    assert done\n"
                ),
                "class-name-visible-to-method.py": (
                    "import time\n"
                    "class time:\n"
                    "    def later(self):\n"
                    "        time.sleep(0.1)\n"
                    "        assert done\n"
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
                "deferred-trusted-alias.py": (
                    "import time as clock\n"
                    "def check():\n"
                    "    clock.sleep(0.01)\n"
                    "    assert finished\n"
                    "check()\n"
                ),
                "deferred-later-trusted-alias.py": (
                    "def check():\n"
                    "    clock.sleep(0.01)\n"
                    "    assert finished\n"
                    "import time as clock\n"
                    "check()\n"
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
            "deferred-trusted-alias.py",
            "deferred-later-trusted-alias.py",
        ):
            line = (
                4
                if relative_path == "parenthesized-from-time.py"
                else 3
                if relative_path == "deferred-trusted-alias.py"
                else 2
                if relative_path == "deferred-later-trusted-alias.py"
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
                "deferred-module-rebound.py": (
                    "import time as clock\n"
                    "def check():\n"
                    "    clock.sleep(0.01)\n"
                    "    assert finished\n"
                    "clock = fake_clock\n"
                    "check()\n"
                ),
                "loop-else-break-shadow.py": (
                    "import time\n"
                    "for item in items:\n"
                    "    time = fake_clock\n"
                    "    break\n"
                    "else:\n"
                    "    import time\n"
                    "time.sleep(0.01)\n"
                    "assert finished\n"
                ),
                "global-branch-order.py": (
                    "def check(flag):\n"
                    "    global clock\n"
                    "    if flag:\n"
                    "        import fake_clock as clock\n"
                    "    else:\n"
                    "        import time as clock\n"
                    "    clock.sleep(0.01)\n"
                    "    assert finished\n"
                ),
                "nonlocal-branch-order.py": (
                    "def outer(flag):\n"
                    "    import time as clock\n"
                    "    def check():\n"
                    "        nonlocal clock\n"
                    "        if flag:\n"
                    "            import fake_clock as clock\n"
                    "        else:\n"
                    "            import time as clock\n"
                    "        clock.sleep(0.01)\n"
                    "        assert finished\n"
                    "    check()\n"
                ),
                "nested-closure-rebound.py": (
                    "def outer():\n"
                    "    import time as clock\n"
                    "    def inner():\n"
                    "        clock.sleep(0.01)\n"
                    "        assert finished\n"
                    "    clock = fake_clock\n"
                    "    inner()\n"
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
            "loop-break-real.py": (
                "for item in items:\n"
                "    import time\n"
                "    if ready:\n"
                "        break\n"
                "    time = fake_clock\n"
                "else:\n"
                "    import time\n"
                "time.sleep(0.01)\n"
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
            "loop-break-real.py": 8,
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
                "same-f-string-assertion.py": (
                    'rendered = f"{time.sleep(0.01)}'
                    '{self.assertTrue(done)}"\n'
                ),
                "multiline-assert.py": (
                    "assert (\n"
                    "    time.sleep(0.1) or ready\n"
                    ")\n"
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
            "same-f-string-assertion.py": 1,
            "multiline-assert.py": 2,
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

    def test_same_line_sleep_assert_order_is_preserved(self) -> None:
        positive = self.run_checker(
            {
                "sleep-before-assert.py": (
                    "time.sleep(0.01); assert finished\n"
                ),
                "sleep-before-assert-and.sh": (
                    'sleep 1 && assert "$ready"\n'
                ),
                "sleep-before-assert-or.sh": (
                    'sleep 1 || assert "$ready"\n'
                ),
                "sleep-before-assert-pipe.sh": (
                    'sleep 1 | assert "$ready"\n'
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
        for operator in ("and", "or", "pipe"):
            self.assertIn(
                f"fixtures/sleep-before-assert-{operator}.sh:1: "
                "sleep-then-assert:",
                positive.stdout,
            )

        negative = self.run_checker(
            {
                "assert-before-sleep.py": (
                    "assert finished; time.sleep(0.01)\n"
                ),
                "assert-before-sleep-and.sh": (
                    'assert "$ready" && sleep 1\n'
                ),
                "assert-before-sleep-or.sh": (
                    'assert "$ready" || sleep 1\n'
                ),
                "assert-before-sleep-pipe.sh": (
                    'assert "$ready" | sleep 1\n'
                ),
                "assert-before-sleep-comma.ts": (
                    "(expect(done).toBe(true), setTimeout(resolve, 1))\n"
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

    def test_shell_lexing_and_heredoc_bodies_remain_silent(self) -> None:
        long_case_pattern = "|".join(f"choice{index}" for index in range(25))
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
                "numeric-heredoc.sh": (
                    "cat <<123\n"
                    "sleep 1\n"
                    "123\n"
                    'assert "$actual" "$expected"\n'
                ),
                "punctuated-heredoc.sh": (
                    "cat <<END-OF\n"
                    "sleep 1\n"
                    "END-OF\n"
                    'assert "$actual" "$expected"\n'
                ),
                "long-case-pattern.sh": (
                    f"case \"$state\" in {long_case_pattern}) sleepX 1 ;; esac\n"
                    'assert "$actual" "$expected"\n'
                ),
                "reserved-word-argument.sh": (
                    "printf '%s\\n' if sleep 1\n"
                    'assert "$actual" "$expected"\n'
                ),
                "escaped-semicolon-argument.sh": (
                    "printf '%s\\n' \\; sleep 1\n"
                    'assert "$actual" "$expected"\n'
                ),
                "escaped-pipe-argument.sh": (
                    "printf '%s\\n' \\| sleep 1\n"
                    'assert "$actual" "$expected"\n'
                ),
                "escaped-paren-argument.sh": (
                    "printf '%s\\n' \\( sleep 1\n"
                    'assert "$actual" "$expected"\n'
                ),
                "sleep-function-declaration.sh": (
                    'sleep () { assert "$ready"; }\n'
                ),
                "multiline-sleep-function-declaration.sh": (
                    "sleep ()\n"
                    "{\n"
                    '    assert "$ready"\n'
                    "}\n"
                ),
                "assert-case-pattern.sh": (
                    'case "$cmd" in assert) sleep 1 ;; esac\n'
                ),
                "assert-pattern-after-sleep.sh": (
                    'sleep 1; case "$cmd" in assert) : ;; esac\n'
                ),
                "assert-argument-after-sleep.sh": (
                    "sleep 1; echo assert\n"
                ),
                "substitution-closer-argument.sh": (
                    "echo $(prepare) sleep 1\n"
                    'assert "$ready"\n'
                ),
                "case-substitution-closer-argument.sh": (
                    'case "$state" in ready) echo $(prepare) sleep 1 ;; esac\n'
                    'assert "$ready"\n'
                ),
                "assertion-looking-argument.sh": (
                    'echo assert "$(sleep 1)"\n'
                ),
                "arithmetic-sleep-identifier.sh": (
                    "value=$((sleep + 1))\n"
                    'assert "$ready"\n'
                ),
                "heredoc-arithmetic-sleep-identifier.sh": (
                    "cat <<EOF\n"
                    "$((sleep + 1))\n"
                    "EOF\n"
                    'assert "$ready"\n'
                ),
            },
            timeout=2,
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
                "heredoc-multiline-substitution.sh": (
                    "cat <<EOF\n"
                    "$(\n"
                    "sleep 1\n"
                    ")\n"
                    "EOF\n"
                    'assert "$actual" "$expected"\n'
                ),
                "heredoc-multiline-backtick.sh": (
                    "cat <<EOF\n"
                    "`\n"
                    "sleep 1\n"
                    "`\n"
                    "EOF\n"
                    'assert "$actual" "$expected"\n'
                ),
                "punctuated-heredoc-then-sleep.sh": (
                    "cat <<END-OF\n"
                    "fixture data\n"
                    "END-OF\n"
                    "sleep 1\n"
                    'assert "$actual" "$expected"\n'
                ),
                "heredoc-embedded-hash.sh": (
                    "cat <<EOF\n"
                    "$(printf foo#bar; sleep 1)\n"
                    "EOF\n"
                    'assert "$actual" "$expected"\n'
                ),
            }
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        expected_lines = {
            "heredoc-substitution.sh": 2,
            "heredoc-backtick.sh": 2,
            "heredoc-multiline-substitution.sh": 3,
            "heredoc-multiline-backtick.sh": 3,
            "punctuated-heredoc-then-sleep.sh": 4,
            "heredoc-embedded-hash.sh": 2,
        }
        for relative_path, line in expected_lines.items():
            self.assertIn(
                f"fixtures/{relative_path}:{line}: sleep-then-assert:",
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
                "continued-timeout.ts": (
                    "setTimeout(\n"
                    "    () => {\n"
                    "        resolve()\n"
                    "    },\n"
                    "    1\n"
                    ")\n"
                    "expect(finished).toBe(true)\n"
                ),
                "regex-in-timeout.ts": (
                    "setTimeout(\n"
                    "    () => {\n"
                    "        const pattern = /\\)/\n"
                    "        doWork()\n"
                    "        finish()\n"
                    "    },\n"
                    "    1\n"
                    ")\n"
                    "expect(finished).toBe(true)\n"
                ),
                "control-regex-in-timeout.ts": (
                    "setTimeout(\n"
                    "    () => {\n"
                    "        if (ready) /[)]/.test(value)\n"
                    "        doWork()\n"
                    "        finish()\n"
                    "    },\n"
                    "    1\n"
                    ")\n"
                    "expect(finished).toBe(true)\n"
                ),
                "multiline-bun-member.ts": (
                    "await Bun\n"
                    "    .sleep(1)\n"
                    "expect(finished).toBe(true)\n"
                ),
                "multiline-global-timeout-member.ts": (
                    "globalThis\n"
                    "    .setTimeout(resolve, 1)\n"
                    "expect(finished).toBe(true)\n"
                ),
            }
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for relative_path in (
            "multiline-bun.ts",
            "multiline-timeout.ts",
            "continued-timeout.ts",
            "regex-in-timeout.ts",
            "control-regex-in-timeout.ts",
            "multiline-bun-member.ts",
            "multiline-global-timeout-member.ts",
        ):
            line = (
                2
                if relative_path
                in (
                    "multiline-bun-member.ts",
                    "multiline-global-timeout-member.ts",
                )
                else 1
            )
            self.assertIn(
                f"fixtures/{relative_path}:{line}: sleep-then-assert:",
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
                "continued-task.swift": (
                    "try await Task.sleep(\n"
                    "    nanoseconds: UInt64(\n"
                    "        1\n"
                    "    )\n"
                    ")\n"
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
        self.assertIn(
            "fixtures/continued-task.swift:1: sleep-then-assert:",
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
                "nested-block-comment.swift": (
                    "/* outer /* inner */\n"
                    "try await Task.sleep(nanoseconds: 1)\n"
                    "#expect(finished)\n"
                    "*/\n"
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
                "leading-comments.ts": (
                    "// Bun.sleep(1)\n"
                    "expect(finished).toBe(true)\n"
                    "doWork(); // setTimeout(resolve, 1)\n"
                    "expect(done).toBe(true)\n"
                ),
                "continued-string.ts": (
                    'const source = "prefix\\\n'
                    'setTimeout(resolve, 1)"\n'
                    "expect(source).toBeTruthy()\n"
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
