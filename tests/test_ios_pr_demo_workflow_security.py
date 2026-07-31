from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILD = (ROOT / ".github/workflows/ios-pr-demo-build.yml").read_text()
PUBLISH = (ROOT / ".github/workflows/ios-pr-demo-publish.yml").read_text()


class IOSPRDemoWorkflowSecurityTests(unittest.TestCase):
    def test_build_is_manual_main_only_and_has_no_secrets(self) -> None:
        self.assertIn("workflow_dispatch:", BUILD)
        self.assertNotIn("pull_request_target:", BUILD)
        self.assertNotIn("pull_request:", BUILD)
        self.assertIn("if: github.ref == 'refs/heads/main'", BUILD)
        self.assertIn("contents: read", BUILD)
        self.assertIn("pull-requests: read", BUILD)
        self.assertNotIn("secrets.", BUILD)
        self.assertNotIn("environment:", BUILD)

    def test_build_authorizes_same_repository_open_main_pr_at_immutable_sha(self) -> None:
        for guard in (
            "allowedPermissions = new Set(['write', 'maintain', 'admin'])",
            "await requirePublisherPermission(context.actor, 'actor')",
            "await requirePublisherPermission(process.env.TRIGGERING_ACTOR, 'triggering actor')",
            "pr.state !== 'open' || pr.merged",
            "pr.base.ref !== 'main'",
            "pr.head.repo?.full_name !== repository",
            "ref: ${{ needs.resolve.outputs.head_sha }}",
            "persist-credentials: false",
        ):
            self.assertIn(guard, BUILD)

    def test_build_forces_dev_identity_and_unsigned_archive(self) -> None:
        for setting in (
            "PRODUCT_NAME=cmux",
            "PRODUCT_BUNDLE_IDENTIFIER=dev.cmux.app.dev",
            "'PRODUCT_DISPLAY_NAME=cmux DEV'",
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGN_IDENTITY=",
        ):
            self.assertIn(setting, BUILD)
        self.assertIn("ios-pr-demo-request-${{ github.run_id }}", BUILD)
        self.assertIn("ios-pr-demo-archive-${{ github.run_id }}", BUILD)
        self.assertIn("cmux-pr-demo.xcarchive.tar", BUILD)

    def test_publisher_uses_trusted_workflow_run_boundary(self) -> None:
        for guard in (
            "workflow_run:",
            "workflows: [iOS PR Demo Build]",
            "branches: [main]",
            "github.event.workflow_run.conclusion == 'success'",
            "github.event.workflow_run.event == 'workflow_dispatch'",
            "github.event.workflow_run.head_branch == 'main'",
            "ref: ${{ github.workflow_sha }}",
            "persist-credentials: false",
            "name: ios-pr-demo",
        ):
            self.assertIn(guard, PUBLISH)
        self.assertNotIn("pull_request_target:", PUBLISH)
        self.assertEqual(PUBLISH.count("actions/checkout@"), 1)

    def test_publisher_queues_and_revalidates_every_request(self) -> None:
        self.assertIn("group: ios-pr-demo-publisher", PUBLISH)
        self.assertIn("queue: max", PUBLISH)
        self.assertNotIn("cancel-in-progress:", PUBLISH)
        for guard in (
            "expected exactly two artifacts",
            "request artifact must contain only request.json",
            "PR is no longer open and unmerged",
            "PR head changed after the demo request",
            "PR metadata changed after the demo request",
            "trusted marketing version changed after the demo request",
            "manifest.actor !== process.env.RUN_ACTOR",
            "manifest.triggering_actor !== process.env.RUN_TRIGGERING_ACTOR",
        ):
            self.assertIn(guard, PUBLISH)

    def test_publisher_treats_archive_as_data_before_secrets_are_used(self) -> None:
        validation = PUBLISH.index("Validate triggering run and artifact set")
        manifest = PUBLISH.index("Revalidate manifest and live PR")
        archive = PUBLISH.index("Validate untrusted archive before loading secrets")
        key = PUBLISH.index("Materialize App Store Connect API key")
        restamp = PUBLISH.index("restamp-testflight-archive.py", key)
        upload = PUBLISH.index("Sign and upload cmux DEV")
        self.assertLess(validation, manifest)
        self.assertLess(manifest, archive)
        self.assertLess(archive, key)
        self.assertLess(key, restamp)
        self.assertLess(restamp, upload)
        self.assertIn("--validate-only", PUBLISH)
        self.assertIn("--archive-tar \"$ARCHIVE_TAR\"", PUBLISH)
        self.assertIn("--expected-bundle-id \"$IOS_BETA_BUNDLE_ID\"", PUBLISH)
        self.assertIn("--expected-display-name \"$IOS_BETA_DISPLAY_NAME\"", PUBLISH)
        self.assertIn("--expected-marketing-version \"$MARKETING_VERSION\"", PUBLISH)
        self.assertIn("com.apple.developer.usernotifications.time-sensitive", PUBLISH)

    def test_publisher_sets_provenance_notes_and_internal_group(self) -> None:
        for value in (
            "cmux DEV | PR ${manifest.pr_number} | ${shortSha}",
            "Author: @${clean(manifest.author, 100)}",
            "Commit: ${manifest.head_sha}",
            "PR: ${manifest.pr_url}",
            "Demo: ${demoNotes}",
            "--notes \"$notes\"",
            "CMUX_TESTFLIGHT_INTERNAL_GROUP_NAME: cmux DEV",
        ):
            self.assertIn(value, PUBLISH)

    def test_official_actions_are_pinned_to_full_commits(self) -> None:
        for workflow in (BUILD, PUBLISH):
            actions = re.findall(r"uses: (actions/[A-Za-z0-9_-]+)@([^\s]+)", workflow)
            self.assertTrue(actions)
            for action, revision in actions:
                self.assertRegex(revision, r"^[0-9a-f]{40}$", action)


if __name__ == "__main__":
    unittest.main()
