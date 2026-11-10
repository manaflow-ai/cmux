#!/usr/bin/env python3
"""The daemon's warm login copy runs the start's own machine scripts, byte for byte.

The warm's copy moved into Rust (cmux-tui `link/start_chat_cli/spare_warm/scripts.rs`) while the
start's copy is still Swift (`CloudCredentialInstaller`, `CloudMachineLogin`). Until the start moves
too, the two must not drift: a fix to the guest check, the installer or the login probe lands in both.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWIFT = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextCloudCredentials"
RUST = ROOT / "cmux-tui/crates/cmux-tui/src/link/start_chat_cli/spare_warm/scripts.rs"

PAIRS = [
    ("CloudCredentialInstaller.swift", "preflight", "PREFLIGHT"),
    ("CloudCredentialInstaller.swift", "script", "INSTALL_SCRIPT"),
    ("CloudMachineLogin.swift", "workHome", "WORK_HOME"),
    ("CloudMachineLogin.swift", "script", "PROBE_SCRIPT"),
]


def swift_raw(path: Path, name: str) -> str:
    """A `static let NAME = #\"\"\"...\"\"\"#` literal as Swift reads it (the closing delimiter's indent
    stripped), or a one-line `#"..."#`."""
    text = path.read_text()
    multi = re.search(r'static let ' + re.escape(name) + r'\s*=\s*#"""\n(.*?)\n([ \t]*)"""#', text, re.S)
    if multi:
        indent = multi.group(2)
        return "\n".join(line[len(indent):] if line.startswith(indent) else line.lstrip() for line in multi.group(1).split("\n"))
    one = re.search(r'static let ' + re.escape(name) + r'\s*=\s*#"(.*?)"#', text)
    assert one, f"{path.name}: no static let {name}"
    return one.group(1)


def rust_raw(name: str) -> str:
    found = re.search(r'const ' + re.escape(name) + r': &str = r##"(.*?)"##;', RUST.read_text(), re.S)
    assert found, f"scripts.rs: no const {name}"
    return found.group(1)


class LoginCopyScriptsTests(unittest.TestCase):
    def test_every_script_matches_the_swift_start(self):
        for swift_file, swift_name, rust_name in PAIRS:
            with self.subTest(rust_name):
                self.assertEqual(rust_raw(rust_name), swift_raw(SWIFT / swift_file, swift_name),
                                 f"{rust_name} drifted from {swift_file} {swift_name}: change both")

    def test_the_probe_endpoint_matches(self):
        swift = re.search(r'static let endpoint = "([^"]+)"', (SWIFT / "CloudMachineLogin.swift").read_text()).group(1)
        rust = re.search(r'const PROBE_ENDPOINT: &str = "([^"]+)"', RUST.read_text()).group(1)
        self.assertEqual(rust, swift)


if __name__ == "__main__":
    unittest.main()
