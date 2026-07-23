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
            "asyncio.py": "await asyncio.sleep(0.01)\nassert finished\n",
            "bun.ts": "await Bun.sleep(1)\nexpect(finished).toBe(true)\n",
            "timeout.ts": (
                "await new Promise(resolve => setTimeout(resolve, 1))\n"
                "expect(finished).toBe(true)\n"
            ),
            "shell.sh": 'sleep 1\nassert "$actual" "$expected"\n',
        }

        result = self.run_checker(fixtures)

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for relative_path in fixtures:
            self.assertIn(
                f"fixtures/{relative_path}:1: sleep-then-assert:",
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
            }
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("test-determinism: 0 active finding(s)", result.stdout)

    def test_sleep_text_inside_strings_and_comments_remains_silent(self) -> None:
        result = self.run_checker(
            {
                "strings.swift": (
                    'let command = "Task.sleep(nanoseconds: 1)"\n'
                    "#expect(command.isEmpty == false)\n"
                    "// Thread.sleep(forTimeInterval: 1)\n"
                    "#expect(finished)\n"
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
