from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
DEPLOY_WORKFLOW = ROOT / ".github/workflows/docs-deploy-reusable.yml"
HEALTH_WORKFLOW = ROOT / ".github/workflows/vercel-auth-health.yml"


class DocsDeployAuthGuardTests(unittest.TestCase):
    def test_docs_deploy_uses_pinned_vercel_cli(self) -> None:
        workflow = DEPLOY_WORKFLOW.read_text()

        self.assertIn('bun-version: "1.3.14"', workflow)
        self.assertIn("bunx vercel@56.3.1 deploy", workflow)
        self.assertNotIn("bunx vercel deploy", workflow)

    def test_vercel_auth_is_checked_daily(self) -> None:
        workflow = HEALTH_WORKFLOW.read_text()

        self.assertIn("schedule:", workflow)
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn('bun-version: "1.3.14"', workflow)
        self.assertIn("bunx vercel@56.3.1 whoami", workflow)
        self.assertIn("VERCEL_TOKEN: ${{ secrets.VERCEL_TOKEN }}", workflow)


if __name__ == "__main__":
    unittest.main()
