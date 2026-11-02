#!/usr/bin/env python3
"""scripts/cmux-next/check-toast-targets.py: a toast's button never opens Settings as a stand-in."""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/check-toast-targets.py"
spec = importlib.util.spec_from_file_location("check_toast_targets", SCRIPT)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class ToastTargetsTest(unittest.TestCase):
    def test_a_details_button_that_opens_settings_is_refused(self) -> None:
        source = """
        handle.onAction = { [weak services] in
            try? services?.settingsWindow.show(section: nil, focus: true, route: "#/settings/updates")
        }
        """
        self.assertEqual(len(check.scan_swift(source, "Toast.swift")), 1)

    def test_perform_open_settings_is_refused(self) -> None:
        source = """
        handle.onAction = {
            _ = registry.perform("openSettings", invocation: ActionInvocation(origin: .user))
        }
        """
        self.assertEqual(len(check.scan_swift(source, "Toast.swift")), 1)

    def test_an_action_that_opens_what_the_toast_names_passes(self) -> None:
        source = """
        handle.onAction = { [weak self] in self?.openPopover() }
        let other = { try? services.settingsWindow.show(section: .accounts) }
        """
        self.assertEqual(check.scan_swift(source, "Toast.swift"), [])

    def test_a_marked_toast_about_a_setting_passes(self) -> None:
        source = """
        handle.onAction = { // toast-target-allow: the toast names a refused setting
            _ = registry.perform("openSettings", invocation: ActionInvocation(origin: .user))
        }
        """
        self.assertEqual(check.scan_swift(source, "Toast.swift"), [])

    def test_the_tree_is_clean(self) -> None:
        result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
