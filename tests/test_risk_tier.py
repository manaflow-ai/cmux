"""risk_tier.py grades a pull request by its riskiest path and asks for that tier's evidence."""
import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("risk_tier", ROOT / "scripts/ci/risk_tier.py")
risk = importlib.util.module_from_spec(spec)
sys.modules["risk_tier"] = risk  # dataclasses looks the module up by name
spec.loader.exec_module(risk)

NEXT = "Packages/macOS/CmuxNext/Sources/"
HEAD = "0123456789abcdef0123456789abcdef01234567"


class ClassifyTests(unittest.TestCase):
    def tier(self, *files, lines=None):
        return risk.classify(list(files), lines).tier

    def test_docs_tests_and_tooling_are_low(self):
        self.assertEqual(self.tier("docs/ci/merge-main.md", "skills/cmux-testing/SKILL.md"), "low")
        self.assertEqual(self.tier(NEXT.replace("Sources", "Tests") + "CmuxNextSidebarTests/RowTests.swift"), "low")
        self.assertEqual(self.tier("cmux-tui/crates/acpmux/tests/hub_integration/offers.rs"), "low")
        self.assertEqual(self.tier(".github/workflows/cmux-next.yml", "scripts/ci/cmux_next_route.py"), "low")

    def test_app_ui_is_medium(self):
        self.assertEqual(self.tier(NEXT + "CmuxNextSidebar/SidebarRow.swift"), "medium")
        self.assertEqual(self.tier("webviews/src/agent-pane/Composer.tsx"), "medium")
        self.assertEqual(self.tier(NEXT + "CmuxNextSettings/SettingsPane.swift"), "medium")
        self.assertEqual(self.tier("cmux-tui/bindings/go/client.go", "cmux-tui/crates/cmux-motion/src/lib.rs"), "medium")

    def test_unknown_paths_are_medium_not_low(self):
        self.assertEqual(self.tier("brand-new-dir/thing.swift"), "medium")

    def test_daemon_protocol_persistence_and_typing_are_high(self):
        for path in (
            "cmux-tui/crates/acpmux/src/deliver.rs",
            NEXT + "CmuxNextDaemon/DaemonClient.swift",
            NEXT + "CmuxNextRemote/Relay.swift",
            NEXT + "CmuxNextTerminal/TerminalInput.swift",
            NEXT + "CmuxNextHistory/HistoryStore.swift",
            "backend/apps/api/src/cloud-acpmux.ts",
            "schemas/defaults/cmux-next.json",
            "web/convex/schema.ts",
            "plans/cmux-next/daemon-capabilities.json",
            "ghostty",
            "Packages/macOS/CmuxNext/Package.resolved",
        ):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path), "high")

    def test_release_and_signing_scripts_are_high_but_design_is_not(self):
        self.assertEqual(self.tier("scripts/sign-cmux-bundle-helpers.sh"), "high")
        self.assertEqual(self.tier(".github/workflows/release.yml"), "high")
        self.assertEqual(self.tier("cmux.nightly.entitlements"), "high")
        self.assertEqual(self.tier("scripts/ci/check-design-tokens.sh"), "low")
        self.assertEqual(self.tier("scripts/cmux-next/sidebar-rows-perf-release.py"), "low")
        self.assertEqual(self.tier("scripts/ci/nightly_release_notes.py"), "low")
        self.assertEqual(self.tier("scripts/ci/notarize-nightly-dmg.sh"), "high")
        self.assertEqual(self.tier(".github/workflows/sdk-publish-crates.yml"), "high")

    def test_merge_gates_and_ownership_are_high(self):
        for path in (".github/CODEOWNERS", ".github/workflows/risk-tier.yml", "scripts/ci/risk_tier.py",
                     "scripts/gh-merge-green"):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path), "high")

    def test_data_files_inside_risky_trees_are_not_low(self):
        self.assertEqual(self.tier("cmux-tui/crates/cmux-pty/CMakeLists.txt"), "high")
        self.assertEqual(self.tier("cmux-tui/crates/cmux-tui-core/src/fs_ops/fixtures/answers.jsonl"), "high")
        self.assertEqual(self.tier(NEXT + "CmuxNextServer/Resources/pairing-words.txt"), "high")
        self.assertEqual(self.tier("schemas/control-plane/v1.json"), "high")
        self.assertEqual(self.tier(NEXT + "CmuxNextBrowserImport/CookieImport.swift"), "high")

    def test_highest_path_wins(self):
        self.assertEqual(self.tier("docs/x.md", NEXT + "CmuxNextSidebar/A.swift", "cmux-tui/crates/cmux-pty/src/lib.rs"), "high")

    def test_large_medium_change_becomes_high_but_tests_and_generated_do_not_count(self):
        ui = NEXT + "CmuxNextSidebar/A.swift"
        grade = risk.classify([ui], {ui: 1500})
        self.assertEqual((grade.tier, grade.bumped), ("high", True))
        files = [ui, "Packages/macOS/CmuxNext/Tests/X/BigTests.swift", NEXT + "CmuxNextApp/Localizable.xcstrings"]
        lines = {ui: 200, files[1]: 5000, files[2]: 5000}
        self.assertEqual(risk.classify(files, lines).tier, "medium")


class EvidenceTests(unittest.TestCase):
    def test_low_needs_nothing(self):
        self.assertEqual(risk.missing_evidence("low", ""), [])

    def test_medium_needs_a_proof_link_or_not_ui_reason(self):
        self.assertEqual(len(risk.missing_evidence("medium", "## Summary\nfix\n## Proof\n<!-- clip -->\n")), 1)
        body = "## Proof\n![after](https://github.com/user-attachments/assets/1)\n"
        self.assertEqual(risk.missing_evidence("medium", body), [])
        body = "## Proof\nNot UI: only the store's queue ordering changes, nothing renders differently\n"
        self.assertEqual(risk.missing_evidence("medium", body), [])

    def test_a_bare_link_is_not_proof(self):
        body = "## Proof\nCI only, see https://example.com/runs/1\n"
        self.assertEqual(len(risk.missing_evidence("medium", body)), 1)
        body = "## Proof\nhttps://github.com/user-attachments/assets/0d1e\n"
        self.assertEqual(risk.missing_evidence("medium", body), [])

    def test_a_field_name_with_its_value_on_the_next_line_does_not_count(self):
        body = "## Proof\n![x](https://example.com/a.png)\r\nReview:\r\n0123456789ab\r\nRuntime test:\r\n" \
            "https://github.com/manaflow-ai/cmux/actions/runs/1\r\n"
        self.assertEqual(len(risk.missing_evidence("high", body, [HEAD])), 2)

    def test_a_runtime_sha_must_be_a_commit_on_the_pull_request(self):
        body = "## Proof\n![x](https://example.com/a.png)\nReview: SHIP at 0123456789AB\n" \
            "Runtime test: tagged build at fedcba987654\n"
        missing = risk.missing_evidence("high", body, [HEAD])
        self.assertEqual(len(missing), 1)
        self.assertIn("Runtime test", missing[0])

    def test_the_last_labeler_counts_and_a_removal_clears_it(self):
        added = {"event": "labeled", "label": {"name": "risk:waived"}, "actor": {"login": "leo"}}
        removed = {"event": "unlabeled", "label": {"name": "risk:waived"}, "actor": {"login": "leo"}}
        self.assertEqual(risk.last_labeler([added], "risk:waived"), "leo")
        self.assertIsNone(risk.last_labeler([added, removed], "risk:waived"))

    def test_template_comment_is_not_proof(self):
        body = "## Proof\n<!-- Before/after screenshots https://example.com -->\n## Checklist\n"
        self.assertEqual(len(risk.missing_evidence("medium", body)), 1)

    def test_high_needs_review_on_a_pr_commit_and_a_runtime_run(self):
        proof = "## Proof\n![x](https://example.com/a.png)\n"
        missing = risk.missing_evidence("high", proof, [HEAD])
        self.assertEqual(len(missing), 2)
        body = proof + "## Testing\n- Review: SHIP at 0123456789ab (cmux-review subagent)\n" \
            "- Runtime test: DeliverTests/queuedWhileBusy() https://github.com/manaflow-ai/cmux/actions/runs/123\n"
        self.assertEqual(risk.missing_evidence("high", body, [HEAD]), [])
        stale = body.replace("0123456789ab", "fedcba987654")
        self.assertIn("not a commit", risk.missing_evidence("high", stale, [HEAD])[0])


if __name__ == "__main__":
    unittest.main()
