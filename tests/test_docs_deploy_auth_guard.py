import fnmatch
import json

import yaml
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
DEPLOY_WORKFLOW = ROOT / ".github/workflows/docs-deploy-reusable.yml"
DOCS_VERCEL_CONFIG = ROOT / "web/vercel.docs-channel.json"
PRODUCTION_VERCEL_CONFIG = ROOT / "web/vercel.json"
HEALTH_WORKFLOW = ROOT / ".github/workflows/vercel-auth-health.yml"


class DocsDeployAuthGuardTests(unittest.TestCase):
    def test_docs_push_scope_preserves_build_inputs_and_skips_complexity_policy(self) -> None:
        document = yaml.safe_load((ROOT / ".github/workflows/docs-channels.yml").read_text())
        push = document.get("on", document.get(True))["push"]
        self.assertEqual(push["branches"], ["main"])
        self.assertEqual(push["tags"], ["v*"])

        def matches(path):
            selected = False
            for pattern in push["paths"]:
                excluded = pattern.startswith("!")
                if fnmatch.fnmatchcase(path, pattern[1:] if excluded else pattern):
                    selected = not excluded
            return selected

        for path in ["web/scripts/check-complexity.mjs", "web/oxlint-complexity-baseline.txt", "web/.oxlintrc.json"]:
            with self.subTest(excluded=path):
                self.assertFalse(matches(path))
        for path in ["CHANGELOG.md", "web/package.json", "web/bun.lock", "web/app/docs/page.tsx",
                     "web/content/docs/example.mdx", "web/tools/build-docs-search.mjs",
                     "web/tools/sync-changelog.ts", "web/vercel.docs-channel.json",
                     "web/messages/en.json", "web/public/example.svg", "web/next.config.ts"]:
            with self.subTest(included=path):
                self.assertTrue(matches(path))
        self.assertTrue(any(matches(path) for path in ["web/scripts/check-complexity.mjs", "web/app/docs/page.tsx"]))

    def test_docs_deploy_uses_pinned_vercel_cli(self) -> None:
        workflow = DEPLOY_WORKFLOW.read_text()

        self.assertIn('bun-version: "1.3.14"', workflow)
        self.assertIn("bunx vercel@56.3.1 deploy", workflow)
        self.assertNotIn("bunx vercel deploy", workflow)
        self.assertNotIn("--token", workflow)

    def test_docs_deploy_excludes_production_crons(self) -> None:
        workflow = DEPLOY_WORKFLOW.read_text()
        config = json.loads(DOCS_VERCEL_CONFIG.read_text())
        production_config = json.loads(PRODUCTION_VERCEL_CONFIG.read_text())

        self.assertIn(
            "cp web/vercel.docs-channel.json web/vercel.json",
            workflow,
        )
        self.assertNotIn("--local-config", workflow)
        self.assertNotIn("crons", config)
        self.assertEqual(
            config,
            {key: value for key, value in production_config.items() if key != "crons"},
        )

    def test_vercel_auth_is_checked_daily(self) -> None:
        workflow = HEALTH_WORKFLOW.read_text()

        self.assertIn("schedule:", workflow)
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn('bun-version: "1.3.14"', workflow)
        self.assertIn("bunx vercel@56.3.1 whoami", workflow)
        self.assertIn("VERCEL_TOKEN: ${{ secrets.VERCEL_TOKEN }}", workflow)
        self.assertNotIn("--token", workflow)


if __name__ == "__main__":
    unittest.main()
