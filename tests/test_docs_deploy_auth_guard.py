import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
DEPLOY_WORKFLOW = ROOT / ".github/workflows/docs-deploy-reusable.yml"
DOCS_VERCEL_CONFIG = ROOT / "web/vercel.docs-channel.json"
PRODUCTION_VERCEL_CONFIG = ROOT / "web/vercel.json"
HEALTH_WORKFLOW = ROOT / ".github/workflows/vercel-auth-health.yml"


class DocsDeployAuthGuardTests(unittest.TestCase):
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
