"""risk_tier.py grades a pull request by its riskiest path and asks for that tier's evidence."""
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
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

    def big(self, *files):
        """The files, each changed by more than RUNTIME_LINES lines."""
        return self.tier(*files, lines={path: risk.RUNTIME_LINES + 1 for path in files})

    def test_docs_tests_and_tooling_are_low(self):
        self.assertEqual(self.tier("docs/ci/merge-main.md", "skills/cmux-testing/SKILL.md"), "low")
        self.assertEqual(self.tier(NEXT.replace("Sources", "Tests") + "CmuxNextSidebarTests/RowTests.swift"), "low")
        self.assertEqual(self.big("cmux-tui/crates/acpmux/tests/hub_integration/offers.rs"), "low")
        self.assertEqual(self.tier("scripts/ci/health_report.py", ".github/labels.json"), "low")

    def test_app_ui_is_medium(self):
        self.assertEqual(self.tier(NEXT + "CmuxNextSidebar/SidebarRow.swift"), "medium")
        self.assertEqual(self.tier("webviews/src/agent-pane/Composer.tsx"), "medium")
        self.assertEqual(self.tier(NEXT + "CmuxNextSettings/SettingsPane.swift"), "medium")
        self.assertEqual(self.big("cmux-tui/bindings/go/client.go", "cmux-tui/crates/cmux-motion/src/lib.rs"), "medium")

    def test_unknown_paths_are_medium_not_low(self):
        self.assertEqual(self.tier("brand-new-dir/thing.swift"), "medium")

    def test_a_runtime_change_is_high_when_large_and_medium_when_small(self):
        for path in (
            "cmux-tui/crates/acpmux/src/deliver.rs",
            NEXT + "CmuxNextDaemon/DaemonClient.swift",
            NEXT + "CmuxNextRemote/Relay.swift",
            NEXT + "CmuxNextTerminal/TerminalInput.swift",
            NEXT + "CmuxNextHistory/HistoryStore.swift",
            NEXT + "CmuxNextBrowserImport/CookieImport.swift",
            "backend/apps/api/src/cloud-acpmux.ts",
            "schemas/control-plane/v1.json",
        ):
            with self.subTest(path=path):
                self.assertEqual(self.big(path), "high")
                self.assertEqual(self.tier(path, lines={path: risk.RUNTIME_LINES}), "medium")

    def test_runtime_lines_add_up_across_files_but_tests_do_not_count(self):
        a, b = "cmux-tui/crates/acpmux/src/a.rs", NEXT + "CmuxNextDaemon/B.swift"
        half = risk.RUNTIME_LINES // 2 + 1
        self.assertEqual(self.tier(a, b, lines={a: half, b: half}), "high")
        test = "cmux-tui/crates/acpmux/tests/big.rs"
        self.assertEqual(self.tier(a, test, lines={a: 5, test: 900}), "medium")

    def test_migrations_defaults_contracts_and_pins_are_high_at_any_size(self):
        for path in (
            "schemas/defaults/cmux-next.json",
            "web/convex/schema.ts",
            "backend/migrations/0042_add.sql",
            "cmux-tui/spec/resource-operations-v2.json",
            "plans/cmux-next/daemon-capabilities.json",
            "ghostty",
            "Packages/macOS/CmuxNext/Package.resolved",
        ):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path, lines={path: 1}), "high")

    def test_release_and_signing_scripts_are_high_but_design_is_not(self):
        self.assertEqual(self.tier("scripts/sign-cmux-bundle-helpers.sh"), "high")
        self.assertEqual(self.tier(".github/workflows/release.yml"), "high")
        self.assertEqual(self.tier("cmux.nightly.entitlements"), "high")
        self.assertEqual(self.tier("scripts/ci/check-design-tokens.sh"), "low")
        self.assertEqual(self.tier("scripts/cmux-next/sidebar-rows-perf-release.py"), "low")
        self.assertEqual(self.tier("scripts/ci/nightly_release_notes.py"), "low")
        self.assertEqual(self.tier("scripts/ci/notarize-nightly-dmg.sh"), "high")
        self.assertEqual(self.tier(".github/workflows/sdk-publish-crates.yml"), "high")

    def test_merge_gates_and_check_routing_are_high_at_any_size(self):
        for path in (".github/CODEOWNERS", ".github/workflows/risk-tier.yml", "scripts/ci/risk_tier.py",
                     "scripts/gh-merge-green", ".github/workflows/cmux-next.yml", ".github/workflows/ci.yml",
                     "scripts/ci/cmux_next_route.py", "scripts/ci/select_package_tests.py"):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path, lines={path: 1}), "high")

    def test_other_workflows_and_actions_are_medium(self):
        self.assertEqual(self.tier(".github/workflows/cmux-next-pr-merge-tree.yml"), "medium")
        self.assertEqual(self.tier(".github/actions/setup-cmux-tui-rust/action.yml"), "medium")

    def test_data_files_inside_runtime_trees_are_not_low(self):
        for path in ("cmux-tui/crates/cmux-pty/CMakeLists.txt",
                     "cmux-tui/crates/cmux-tui-core/src/fs_ops/fixtures/answers.jsonl",
                     NEXT + "CmuxNextServer/Resources/pairing-words.txt"):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path), "medium")
                self.assertEqual(self.big(path), "high")

    def test_highest_path_wins(self):
        rust = "cmux-tui/crates/cmux-pty/src/lib.rs"
        self.assertEqual(self.tier("docs/x.md", NEXT + "CmuxNextSidebar/A.swift", rust, lines={rust: 200}), "high")

    def test_audit_rust_test_modules_and_tests_v2_are_tests(self):
        # #21888 graded high on agent_tools_tests.rs; 265 such files sit under cmux-tui/.
        self.assertEqual(self.big("cmux-tui/crates/acpmux/src/agent_tools_tests.rs"), "low")
        self.assertEqual(self.big("cmux-tui/crates/acpmux/src/hub/tests.rs"), "low")
        self.assertEqual(self.tier("tests_v2/test_sidebar.py"), "low")
        self.assertEqual(self.tier("cmux-tui/scripts/test_check_release_delivery.py"), "low")
        self.assertEqual(self.tier("scripts/whats-new/fixtures/good/1.0.0-nightly.42.json"), "low")

    def test_audit_merge_gate_helpers_are_high_at_any_size(self):
        for path in (
            "scripts/ci/merge_freeze.py", "scripts/ci/main_fix_evidence.py",
            "scripts/ci/vercel_merge_gate.py", "scripts/merge-main.sh",
            "scripts/cmux-next/check-no-godfiles.sh",
        ):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path), "high")

    def test_audit_nested_release_and_signing_scripts_are_high(self):
        for path in (
            "backend/scripts/deploy-worker.sh", "scripts/ci/signing-keychain.sh",
            "scripts/ci/lib/notary-auth.sh", "scripts/cmux-next/promote-nightly-next.mjs",
            "scripts/ci/nightly_next_feed_rollback.py", ".github/workflows/cmux-tui-nightly.yml",
            ".github/workflows/signing-keychain-macos.yml",
        ):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path), "high")
        self.assertEqual(self.tier("scripts/ci/release-notes-draft.py"), "low")

    def test_audit_optchat_backend_is_runtime(self):
        path = "Native/OptChat/optchat-chief/src/brain/control.rs"
        self.assertEqual(self.big(path), "high")
        self.assertEqual(self.tier(path), "medium")

    def test_audit_more_vendored_pins_are_high(self):
        for path in ("homebrew-cmux", "ghostty.h", ".xcode-version"):
            with self.subTest(path=path):
                self.assertEqual(self.tier(path), "high")

    def test_audit_spec_prose_is_docs_but_spec_data_is_a_contract(self):
        # #21950 changed 8 lines of cmux-tui/spec/commands.md and graded high.
        self.assertEqual(self.tier("cmux-tui/spec/commands.md"), "low")
        self.assertEqual(self.tier("cmux-tui/spec/commands.json"), "high")

    def test_large_medium_change_becomes_high_but_tests_and_generated_do_not_count(self):
        ui = NEXT + "CmuxNextSidebar/A.swift"
        grade = risk.classify([ui], {ui: 1500})
        self.assertEqual((grade.tier, grade.bumped), ("high", True))
        files = [ui, "Packages/macOS/CmuxNext/Tests/X/BigTests.swift", NEXT + "CmuxNextApp/Localizable.xcstrings"]
        lines = {ui: 200, files[1]: 5000, files[2]: 5000}
        self.assertEqual(risk.classify(files, lines).tier, "medium")


class RecentRevertTests(unittest.TestCase):
    """A pull request that takes back another pull request's change from the last week is high."""

    def git(self, repo, *args, when=None):
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                   GIT_COMMITTER_EMAIL="t@t")
        if when is not None:
            env["GIT_COMMITTER_DATE"] = env["GIT_AUTHOR_DATE"] = f"{int(when)} +0000"
        return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True, env=env).stdout

    def test_deleted_ranges_follow_the_base_side_line_numbers(self):
        patch = "@@ -3,4 +3,3 @@\n ctx\n-gone a\n-gone b\n ctx\n@@ -20,2 +19,2 @@\n-old\n+new\n ctx"
        self.assertEqual(risk.deleted_ranges(patch), [(4, 5), (20, 20)])

    def test_undoes_needs_the_added_lines_gone_and_the_replaced_lines_back(self):
        commit = "@@ -1,2 +1,2 @@\n-old effect\n+keyed effect\n ctx"
        self.assertTrue(risk.undoes("@@ -1,2 +1,2 @@\n-keyed effect\n+old effect\n ctx", commit))
        # Rewriting the new line into something else is ordinary editing.
        self.assertFalse(risk.undoes("@@ -1,2 +1,2 @@\n-keyed effect\n+keyed effect v2\n ctx", commit))
        # Moving the new lines elsewhere in the file is not taking them back.
        self.assertFalse(risk.undoes("@@ -1,3 +1,1 @@\n-.a{}\n-.b{}\n ctx\n@@ -40 +38,3 @@\n+.a{}\n+.b{}\n ctx",
                                     "@@ -1 +1,3 @@\n+.a{}\n+.b{}\n ctx"))
        # Moving them to another file is not taking them back either.
        self.assertFalse(risk.undoes("@@ -1,3 +1,1 @@\n-.a{}\n-.b{}\n ctx", "@@ -1 +1,3 @@\n+.a{}\n+.b{}\n ctx",
                                     frozenset({".a{}", ".b{}"})))
        # A pure addition taken out again is a revert.
        self.assertTrue(risk.undoes("@@ -1,3 +1,1 @@\n-.a{}\n-.b{}\n ctx", "@@ -1 +1,3 @@\n+.a{}\n+.b{}\n ctx"))

    def test_a_revert_of_last_weeks_change_names_its_pull_request(self):
        now = time.time()
        with tempfile.TemporaryDirectory() as repo:
            self.git(repo, "init", "-q")
            path = os.path.join(repo, "App.tsx")
            open(path, "w").write("one\ntwo\nthree\n")
            self.git(repo, "add", ".")
            self.git(repo, "commit", "-qm", "feat: old work (#100)", when=now - 30 * 86400)
            open(path, "w").write("one\ntwo\nfix from yesterday\nthree\n")
            self.git(repo, "commit", "-qam", "perf: avoid duplicate loads (#21369)", when=now - 86400)
            base = self.git(repo, "rev-parse", "HEAD").strip()
            stale = {"filename": "App.tsx", "status": "modified",
                     "patch": "@@ -1,4 +1,3 @@\n one\n two\n-fix from yesterday\n three"}
            self.assertEqual(risk.recent_reverts([stale], repo, base, own=21194, now=now), {21369: ["App.tsx"]})
            # Deleting only month-old lines, or the pull request's own lines, is not flagged.
            old = {"filename": "App.tsx", "status": "modified", "patch": "@@ -1,4 +1,3 @@\n-one\n two"}
            self.assertEqual(risk.recent_reverts([old], repo, base, own=21194, now=now), {})
            self.assertEqual(risk.recent_reverts([stale], repo, base, own=21369, now=now), {})
            # Out of time: nothing is checked, and the file is reported as unread rather than clear.
            unread = []
            self.assertEqual(risk.recent_reverts([stale], repo, base, own=21194, now=now, unread=unread, budget=0), {})
            self.assertEqual(unread, ["App.tsx"])


class RenderTests(unittest.TestCase):
    def test_a_file_name_cannot_start_a_workflow_command(self):
        name = "docs/a\n::add-mask::x`b.md"
        report = risk.render(risk.classify([name]), [], False)
        self.assertFalse(any(line.startswith("::") for line in report.splitlines()))
        self.assertIn("docs/a?::add-mask::x?b.md", report)
        self.assertEqual(risk.printable("a\u0085b\u2028c\u2029d"), "a?b?c?d")


class EvidenceTests(unittest.TestCase):
    def test_low_needs_nothing(self):
        self.assertEqual(risk.missing_evidence("low", ""), [])

    def test_medium_needs_a_proof_link_or_not_ui_reason(self):
        self.assertEqual(len(risk.missing_evidence("medium", "## Summary\nfix\n## Proof\n<!-- clip -->\n")), 1)
        body = "## Proof\n![after](https://github.com/user-attachments/assets/1)\n"
        self.assertEqual(risk.missing_evidence("medium", body), [])
        body = "## Proof\nNot UI: only the store's queue ordering changes, nothing renders differently\n"
        self.assertEqual(risk.missing_evidence("medium", body), [])

    def test_a_demo_or_video_heading_holds_proof(self):
        for heading in ("Demo", "Video", "Recording"):
            body = f"## {heading}\n![after](https://github.com/user-attachments/assets/1)\n"
            with self.subTest(heading=heading):
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
