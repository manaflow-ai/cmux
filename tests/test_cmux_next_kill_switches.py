#!/usr/bin/env python3
"""scripts/cmux-next/check-kill-switches.py: per-PR kill switches stay declared, tied to a PR and short-lived.
A switch is declared once in release-notes/next/kill-switches.json with its PR number, owner, the
default (the PR's change ships) and an expiry date. The lint refuses an entry without a PR number or
expiry, fails once an entry is past its expiry, and checks every `killSwitch("pr-N")` call site and
every `pr-N` the signed flags document turns off against the registry.
"""
from __future__ import annotations
import json
import os
import subprocess
import sys
import tempfile
import unittest
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPT = os.path.join(ROOT, "scripts/cmux-next/check-kill-switches.py")
TODAY = "2026-10-22"
SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/NewTab.swift"
def entry(pr: int = 23456, **overrides) -> dict:
    value = {"pr": pr, "owner": "release-rings", "expires": "2026-11-20", "default": "new-path"}
    value.update(overrides)
    return {key: item for key, item in value.items() if item is not None}
class KillSwitchLintTest(unittest.TestCase):
    def run_lint(self, switches: dict, files: dict[str, str] | None = None, flags: dict | None = None,
                 today: str = TODAY, registry_version: object = 1) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as root:
            registry = os.path.join(root, "release-notes/next/kill-switches.json")
            os.makedirs(os.path.dirname(registry))
            with open(registry, "w", encoding="utf-8") as stream:
                json.dump({"version": registry_version, "switches": switches}, stream)
            if flags is not None:
                with open(os.path.join(root, "release-notes/next/flags.json"), "w", encoding="utf-8") as stream:
                    json.dump(flags, stream)
            for rel, text in (files or {}).items():
                path = os.path.join(root, rel)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as stream:
                    stream.write(text)
            return subprocess.run([sys.executable, "-I", SCRIPT, "--root", root, "--today", today],
                                  capture_output=True, text=True)
    def assert_fails(self, done: subprocess.CompletedProcess, needle: str) -> None:
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn(needle, done.stdout)
    def call(self, key: str = "pr-23456") -> dict[str, str]:
        return {SWIFT: f'if killSwitch("{key}") {{ oldPath() }} else {{ newPath() }}\n'}
    def test_a_declared_switch_with_one_call_site_passes(self):
        done = self.run_lint({"pr-23456": entry()}, self.call())
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
    def test_the_repository_registry_passes(self):
        done = subprocess.run([sys.executable, "-I", SCRIPT, "--root", ROOT], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
    def test_an_entry_without_a_pr_number_is_refused(self):
        self.assert_fails(self.run_lint({"pr-23456": entry(pr=None)}, self.call()), "pr-23456: no PR number")
    def test_registry_version_and_pr_number_are_strict_integers(self):
        for version in (True, 1.0, 1.5):
            with self.subTest(version=version):
                self.assert_fails(self.run_lint({"pr-23456": entry()}, self.call(), registry_version=version),
                                  "not a version 1 registry")
        for pr in (23456.0, 23456.5):
            with self.subTest(pr=pr):
                self.assert_fails(self.run_lint({"pr-23456": entry(pr=pr)}, self.call()),
                                  "pr-23456: no PR number")
    def test_an_entry_whose_number_is_not_its_key_is_refused(self):
        self.assert_fails(self.run_lint({"pr-23456": entry(pr=23457)}, self.call()), "pr-23456: no PR number")
    def test_a_key_that_is_not_pr_n_is_refused(self):
        self.assert_fails(self.run_lint({"new-tab": entry()}, self.call("new-tab")), "new-tab: a key is pr-<N>")
    def test_an_entry_without_an_expiry_is_refused(self):
        self.assert_fails(self.run_lint({"pr-23456": entry(expires=None)}, self.call()), "pr-23456: no expiry")
        self.assert_fails(self.run_lint({"pr-23456": entry(expires="soon")}, self.call()), "pr-23456: no expiry")
    def test_an_expiry_far_out_is_refused(self):
        self.assert_fails(self.run_lint({"pr-23456": entry(expires="2027-06-01")}, self.call()), "more than 90 days")
    def test_an_entry_past_its_expiry_fails(self):
        done = self.run_lint({"pr-23456": entry(expires="2026-10-21")}, self.call())
        self.assert_fails(done, "pr-23456: expired on 2026-10-21")
        done = self.run_lint({"pr-23456": entry(expires=TODAY)}, self.call())
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
    def test_a_default_that_turns_the_change_off_is_refused(self):
        self.assert_fails(self.run_lint({"pr-23456": entry(default="old-path")}, self.call()), "default")
    def test_an_owner_is_required(self):
        self.assert_fails(self.run_lint({"pr-23456": entry(owner="")}, self.call()), "pr-23456: no owner")
    def test_a_call_site_without_an_entry_is_refused(self):
        self.assert_fails(self.run_lint({}, self.call()), f"{SWIFT}:1: pr-23456 is not in")
    def test_an_entry_without_a_call_site_is_refused(self):
        self.assert_fails(self.run_lint({"pr-23456": entry()}), "pr-23456: no killSwitch")
    def test_a_key_that_is_not_a_literal_is_refused(self):
        files = {**self.call(), "webviews/src/tabs/newTab.ts": "if (killSwitch(key)) old();\n"}
        self.assert_fails(self.run_lint({"pr-23456": entry()}, files), "webviews/src/tabs/newTab.ts:1: not a literal")
    def test_one_evaluation_site_per_key_and_surface(self):
        files = {**self.call(), "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/Other.swift": 'killSwitch("pr-23456")\n'}
        self.assert_fails(self.run_lint({"pr-23456": entry()}, files), "pr-23456: 2 Swift call sites")
        files = {SWIFT: 'let a = killSwitch("pr-23456")\nlet b = killSwitch("pr-23456")\n'}
        self.assert_fails(self.run_lint({"pr-23456": entry()}, files), "pr-23456: 2 Swift call sites")
        files = {**self.call(), "webviews/src/tabs/newTab.ts": 'const off = killSwitch("pr-23456");\n'}
        done = self.run_lint({"pr-23456": entry()}, files)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
    def test_a_call_split_over_lines_is_a_call_site(self):
        files = {SWIFT: 'if killSwitch(\n    "pr-23456"\n) { old() }\n'}
        self.assert_fails(self.run_lint({}, files), f"{SWIFT}:1: pr-23456 is not in")
        done = self.run_lint({"pr-23456": entry()}, files)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
    def test_comments_and_strings_are_not_call_sites_and_qualified_calls_are(self):
        files = {SWIFT: 'let a = killSwitch("pr-23456") // killSwitch("pr-23456") again\n'
                        'let s = "killSwitch(\\"pr-23456\\")" /* killSwitch(x) */\n'}
        done = self.run_lint({"pr-23456": entry()}, files)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        files = {SWIFT: 'let a = 1 // killSwitch("pr-23456")\n'}
        self.assert_fails(self.run_lint({"pr-23456": entry()}, files), "pr-23456: no killSwitch")
        files = {SWIFT: 'if CmuxNextCompat.killSwitch("pr-23456") { old() }\n'}
        self.assert_fails(self.run_lint({}, files), f"{SWIFT}:1: pr-23456 is not in")
    def test_interpolations_are_code_and_swift_block_comments_nest(self):
        for rel, text in ((SWIFT, 'let t = "on: \\(killSwitch("pr-23456"))"\n'),
                          ("webviews/src/tabs/newTab.ts", 'const t = `on: ${killSwitch("pr-23456")}`;\n')):
            with self.subTest(rel=rel):
                self.assert_fails(self.run_lint({}, {rel: text}), f"{rel}:1: pr-23456 is not in")
        files = {**self.call(), "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/Other.swift":
                 '/* outer /* inner */ killSwitch("pr-23456") */\n'}
        done = self.run_lint({"pr-23456": entry()}, files)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
    def test_a_call_after_the_definition_in_the_same_file_is_read(self):
        files = {SWIFT: 'public func killSwitch(_ key: StaticString) -> Bool { true }\nlet a = killSwitch("pr-23456")\n'}
        done = self.run_lint({"pr-23456": entry()}, files)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
    def test_the_definition_comments_and_tests_are_not_call_sites(self):
        files = {
            "Packages/macOS/CmuxNext/Sources/CmuxNextCompat/KillSwitches.swift":
                'public func killSwitch(_ key: StaticString) -> Bool { true }\n/// `killSwitch("pr-1")`\n',
            "Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/KillSwitchesTests.swift": 'killSwitch("pr-9")\n',
        }
        done = self.run_lint({}, files)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
    def test_the_flags_document_turns_off_only_declared_switches(self):
        flags = {"version": 1, "default": {"DisabledFeatures": ["pr-23456", "cloud-vm"]},
                 "cohorts": {"dev": {"DisabledFeatures": ["pr-1"]}}}
        self.assert_fails(self.run_lint({"pr-23456": entry()}, self.call(), flags), "flags.json turns off pr-1")
        flags["cohorts"] = {}
        done = self.run_lint({"pr-23456": entry()}, self.call(), flags)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
    def test_flags_version_is_a_strict_integer_one(self):
        for version in (True, 1.0, 1.5):
            with self.subTest(version=version):
                flags = {"version": version, "default": {}, "cohorts": {}}
                self.assert_fails(self.run_lint({"pr-23456": entry()}, self.call(), flags),
                                  "flags.json: not a version 1 document")
    def test_a_reference_to_the_function_that_is_not_a_call_is_refused(self):
        for code in ('let check = killSwitch\nif check("pr-999") { oldPath() }\n',
                     'let check = KillSwitches.killSwitch\n', 'run(killSwitch)\n'):
            with self.subTest(code=code):
                self.assert_fails(self.run_lint({}, {SWIFT: code}), "killSwitch is only called")
    def test_a_flags_document_of_the_wrong_shape_is_an_error_not_a_crash(self):
        for flags in ([], "pr-1", {"version": 1, "default": "pr-1"}, {"version": 1, "cohorts": []},
                      {"version": 1, "default": {"DisabledFeatures": "pr-1"}},
                      {"version": 1, "default": {"DisabledFeatures": False}},
                      {"version": 1, "default": {"DisabledFeatures": 0}},
                      {"version": 1, "default": {"DisabledFeatures": ""}},
                      {"version": 1, "cohorts": {"dev": {"DisabledFeatures": {"pr-1": True}}}}):
            with self.subTest(flags=flags):
                done = self.run_lint({"pr-23456": entry()}, self.call(), flags)
                self.assert_fails(done, "flags.json:")
                self.assertNotIn("Traceback", done.stderr)
if __name__ == "__main__":
    unittest.main()
