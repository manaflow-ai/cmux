#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""scripts/cmux-next/check-app-asks-no-grant.py over fixture trees: the NEXT app and its bundled
binaries ask macOS for no privacy grant (only the Screen Sharing helper does)."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("check_app_asks_no_grant", ROOT / "scripts/cmux-next/check-app-asks-no-grant.py")
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class CheckAppAsksNoGrantTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def swift(self, rel: str, text: str) -> None:
        self.write(f"Packages/macOS/CmuxNext/Sources/{rel}", text)

    def calls(self) -> list[str]:
        hits, _ = check.check_swift(self.root)
        return [hit.call for hit in hits + check.check_rust(self.root) + check.check_cargo(self.root)]

    def test_every_grant_call_in_the_app_fails(self) -> None:
        self.swift("CmuxNextAgentPane/Handoff.swift", "\n".join([
            "_ = CGRequestPostEventAccess()",
            "if CGPreflightScreenCaptureAccess() { }",
            "_ = AXIsProcessTrustedWithOptions(options)",
            "let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)",
            "let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,",
            "_ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)",
        ]))
        self.assertEqual(self.calls(), ["CGRequestPostEventAccess", "CGPreflightScreenCaptureAccess",
                                        "AXIsProcessTrustedWithOptions", "SCShareableContent", "CGEvent.tapCreate",
                                        "IOHIDRequestAccess"])
        self.assertEqual(check.main(["--root", str(self.root)]), 1)

    def test_debug_and_bench_code_and_comments_pass(self) -> None:
        self.swift("CmuxNextApp/DebugAX.swift", "#if DEBUG || CMUX_BENCH_HOOKS\nlet t = AXIsProcessTrusted()\n#endif\n")
        self.swift("CmuxNextApp/Inline.swift", "\n".join([
            "/// Never calls CGRequestScreenCaptureAccess: the helper does.",
            "let a = 1 // not SCShareableContent",
            "/* CGEventTapCreate */",
            "#if DEBUG",
            "let b = CGPreflightScreenCaptureAccess()",
            "#endif",
        ]))
        self.assertEqual(self.calls(), [])
        self.assertEqual(check.main(["--root", str(self.root)]), 0)

    def test_the_else_of_a_debug_branch_ships(self) -> None:
        self.swift("CmuxNextApp/Else.swift", "#if DEBUG\nlet a = 1\n#else\nlet b = CGRequestScreenCaptureAccess()\n#endif\n")
        self.swift("CmuxNextApp/NotDebug.swift", "#if !DEBUG\nlet c = AXIsProcessTrusted()\n#endif\n")
        self.assertEqual(self.calls(), ["CGRequestScreenCaptureAccess", "AXIsProcessTrusted"])

    def test_the_apps_own_windows_need_no_consent(self) -> None:
        self.swift("CmuxNextDesign/Shot.swift", "guard let content = try? await SCShareableContent.currentProcess else { return nil }\n")
        self.assertEqual(self.calls(), [])

    def test_a_pending_row_suppresses_its_file_and_a_landed_one_is_reported_stale(self) -> None:
        self.swift("CmuxNextMacScreen/MacScreenShareHost.swift", "return CGRequestScreenCaptureAccess()\n")
        hits, stale = check.check_swift(self.root)
        self.assertEqual(hits, [])
        self.assertIn("CmuxNextMacScreen/MacScreenSystemShortcuts.swift", "\n".join(stale))
        self.assertNotIn("MacScreenShareHost.swift", "\n".join(stale))

    def test_a_bundled_rust_crate_fails_and_the_helper_passes(self) -> None:
        self.write("cmux-tui/crates/cmux-tui/src/grab.rs", "fn CGRequestScreenCaptureAccess() -> bool;\n")
        self.write("cmux-tui/crates/cmux-rd-host/src/permissions.rs", "fn CGRequestScreenCaptureAccess() -> bool;\n")
        self.write("cmux-tui/crates/cmux-computer-use/src/platform/macos/sys.rs", "fn AXIsProcessTrustedWithOptions();\n")
        self.write("cmux-tui/crates/acpmux/src/thing_tests.rs", "fn CGEventTapCreate();\n")
        self.assertEqual([h.path for h in check.check_rust(self.root)], ["cmux-tui/crates/cmux-tui/src/grab.rs"])

    def test_a_bundled_crate_may_not_build_the_helpers_desktop_on_a_mac(self) -> None:
        self.write("cmux-tui/crates/cmux-tui/Cargo.toml", "\n".join([
            "[target.'cfg(not(target_os = \"macos\"))'.dependencies]",
            'cmux-computer-use = { workspace = true, features = ["desktop", "server"] }',
            "[target.'cfg(unix)'.dependencies]",
            'cmux-rd-host = { path = "../cmux-rd-host", default-features = false, features = ["link"] }',
        ]))
        self.assertEqual(check.check_cargo(self.root), [])
        self.write("cmux-tui/crates/acpmux/Cargo.toml", '[dependencies]\ncmux-rd-host = { path = "../cmux-rd-host", features = ["computer-use"] }\n')
        self.assertEqual([h.call for h in check.check_cargo(self.root)], ['cmux-rd-host "computer-use"'])

    def test_this_tree_is_clean(self) -> None:
        self.assertEqual(check.main(["--root", str(ROOT)]), 0)


if __name__ == "__main__":
    unittest.main()
