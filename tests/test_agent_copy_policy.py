#!/usr/bin/env python3
"""Exercise the shipping clipboard policy without building the native app."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = ROOT / "Packages/macOS/CmuxTerminalCore/Sources/CmuxTerminalCore"


class AgentCopyPolicyTests(unittest.TestCase):
    def run_swift(self, sources, body):
        compiler = shutil.which("swiftc")
        self.assertIsNotNone(compiler, "Swift compiler is required")
        with tempfile.TemporaryDirectory(prefix="agent-copy-") as directory:
            directory = pathlib.Path(directory)
            main = directory / "main.swift"
            main.write_text(body)
            binary = directory / "policy"
            subprocess.run([compiler, "-swift-version", "6", "-module-cache-path",
                            str(directory / "cache"), *map(str, sources), str(main),
                            "-o", str(binary)], check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_program_clipboard_reads_are_denied(self):
        self.run_swift([CORE / "Clipboard/TerminalUnsafePasteConfirmationPolicy.swift"], """
import Foundation
for enabled in [true, false] {
    let policy = TerminalUnsafePasteConfirmationPolicy(confirmationEnabled: enabled)
    for window in [true, false] {
        guard policy.decision(isPasteRequest: false, hasWindow: window) == .reject else {
            print("program clipboard read was not denied")
            exit(1)
        }
    }
    assert(policy.decision(isPasteRequest: true, hasWindow: true)
        == (enabled ? .askInWindowSheet : .approve))
}
""")


if __name__ == "__main__":
    unittest.main()
