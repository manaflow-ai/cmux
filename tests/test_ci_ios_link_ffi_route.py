"""The Linux FFI binding check starts on a landing head that touches the FFI crate or its binding.

cmux#62170 changed a doc comment in cmux-mobile-link-ffi/src/pane_filter.rs (uniffi folds doc comments into
its checksums) and hand-edited CmuxMobileLinkFFI.swift instead of regenerating it. Its router run 46093023059
skipped ios-link-ffi-linux.yml ("landing on the affected tier: the full tier runs once an hour"), so the stale
binding merged (be9db84d) and "Swift to Rust FFI on Linux" stayed red on feat-cmux-next until cmux#64446.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import pr_router  # noqa: E402

NAME = "ios-link-ffi-linux.yml"
CRATE_DOC = "cmux-next-ios/rust/crates/cmux-mobile-link-ffi/src/pane_filter.rs"
BINDING = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift"


class IosLinkFfiRoute(unittest.TestCase):
    def setUp(self) -> None:
        self.callees = pr_router.load_manifest()
        repo = {"full_name": "manaflow-ai/cmux"}
        self.pr = {"draft": False, "head": {"repo": repo}, "base": {"ref": "feat-cmux-next", "repo": repo},
                   "labels": [{"name": "ready-to-land"}]}

    def route(self, action: str, path: str) -> tuple[bool, str]:
        event = {"action": action, "label": {"name": "ready-to-land"}, "pull_request": self.pr}
        tier = pr_router.head_tier.tier("pull_request", event, land_switch="1", land_full_switch="0")
        self.assertTrue(pr_router.head_tier.land_affected(tier))
        start, why = pr_router.route(event, self.callees, [path], decided=tier)
        return NAME in start, why[NAME]

    def test_a_landing_head_that_touches_the_ffi_crate_or_binding_starts_it(self) -> None:
        for action in ("labeled", "synchronize"):
            for path in (CRATE_DOC, BINDING):
                with self.subTest(action=action, path=path):
                    starts, why = self.route(action, path)
                    self.assertTrue(starts, why)

    def test_a_landing_head_that_touches_no_ffi_input_skips_it(self) -> None:
        starts, why = self.route("synchronize", "docs/readme.md")
        self.assertFalse(starts, why)
        starts, why = self.route("synchronize", "cmux-next-ios/rust/crates/cmux-mobile-link/src/lib.rs")
        self.assertFalse(starts, why)


if __name__ == "__main__":
    unittest.main()
