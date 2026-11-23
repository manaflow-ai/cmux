#!/usr/bin/env python3
"""check-keychain-no-prompt.py on throwaway repo roots.

A Keychain call guarded by withoutUI or kSecUseAuthenticationUIFail passes, a
call marked `// keychain-prompt: consent` passes, an unguarded call is counted,
and the baseline ratchet fails both above and below its row.

Not a CI job (Lawrence 2026-10-23: no new CI gates, since lifted): run it yourself after a
change to the check:
  python3 -I scripts/cmux-next/tests/test_check_keychain_no_prompt.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import tempfile
import unittest
from pathlib import Path

CHECK = Path(__file__).resolve().parents[1] / "check-keychain-no-prompt.py"
_spec = importlib.util.spec_from_file_location("check_keychain_no_prompt", CHECK)
check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check)

SWIFT = "Packages/macOS/CmuxNext/Sources/Fixture/Store.swift"
BASELINE = "scripts/cmux-next/keychain-no-prompt-baseline.tsv"

GUARDED_WITHOUT_UI = """
func read(_ query: [String: Any]) -> OSStatus {
    var out: CFTypeRef?
    return loginKeychain.withoutUI { SecItemCopyMatching(query as CFDictionary, &out) }
}
"""
GUARDED_UI_FAIL = """
func read() -> OSStatus {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
    ]
    var out: CFTypeRef?
    return SecItemCopyMatching(query as CFDictionary, &out)
}
"""
CONSENT = """
func importKey(_ query: [String: Any]) -> OSStatus {
    var out: CFTypeRef?
    // keychain-prompt: consent
    return SecItemCopyMatching(query as CFDictionary, &out)
}
"""
UNGUARDED = """
func write(_ query: [String: Any]) {
    // withoutUI in a comment does not count.
    SecItemDelete(query as CFDictionary)
    SecItemAdd(query as CFDictionary, nil)
}

func ask(_ context: LAContext) async throws -> Bool {
    try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "x")
}

func allowed() {
    SecKeychainSetUserInteractionAllowed(false)
}
"""


class CheckKeychainNoPrompt(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_check(self, source: str, baseline: str = "") -> tuple[int, str]:
        path = self.root / SWIFT
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")
        (self.root / BASELINE).parent.mkdir(parents=True, exist_ok=True)
        (self.root / BASELINE).write_text(baseline, encoding="utf-8")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = check.main([os.fspath(self.root)])
        return code, out.getvalue() + err.getvalue()

    def test_guarded_by_without_ui(self) -> None:
        self.assertEqual(check.unguarded_calls(GUARDED_WITHOUT_UI), [])
        self.assertEqual(self.run_check(GUARDED_WITHOUT_UI)[0], 0)

    def test_guarded_by_authentication_ui_fail(self) -> None:
        self.assertEqual(check.unguarded_calls(GUARDED_UI_FAIL), [])
        self.assertEqual(self.run_check(GUARDED_UI_FAIL)[0], 0)

    def test_consent_comment(self) -> None:
        self.assertEqual(check.unguarded_calls(CONSENT), [])
        same_line = "func f(q: [String: Any]) {\n    SecItemDelete(q as CFDictionary) // keychain-prompt: consent\n}\n"
        self.assertEqual(check.unguarded_calls(same_line), [])

    def test_unguarded_counted(self) -> None:
        lines = [number for number, _ in check.unguarded_calls(UNGUARDED)]
        self.assertEqual(lines, [4, 5, 9])
        code, text = self.run_check(UNGUARDED)
        self.assertEqual(code, 1)
        self.assertIn(SWIFT, text)
        self.assertIn("baseline 0", text)

    def test_baseline_admits_its_count(self) -> None:
        code, text = self.run_check(UNGUARDED, f"# header\n{SWIFT}\t3\tfix\treason\n")
        self.assertEqual(code, 0, text)

    def test_ratchet_up_fails(self) -> None:
        code, text = self.run_check(UNGUARDED, f"{SWIFT}\t2\tfix\treason\n")
        self.assertEqual(code, 1)
        self.assertIn("has 3 unguarded", text)

    def test_ratchet_down_fails_until_lowered(self) -> None:
        code, text = self.run_check(UNGUARDED, f"{SWIFT}\t4\tkeep\treason\n")
        self.assertEqual(code, 1)
        self.assertIn("Lower its row", text)
        code, text = self.run_check(GUARDED_WITHOUT_UI, f"{SWIFT}\t1\tfix\treason\n")
        self.assertEqual(code, 1)
        self.assertIn("delete the row", text)

    def test_tests_and_ios_are_not_scanned(self) -> None:
        for rel in ("Packages/macOS/CmuxNext/Tests/FixtureTests/Store.swift", "Packages/iOS/Fixture/Store.swift"):
            path = self.root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(UNGUARDED, encoding="utf-8")
        self.assertEqual(check.scan(os.fspath(self.root)), {})


if __name__ == "__main__":
    unittest.main()
