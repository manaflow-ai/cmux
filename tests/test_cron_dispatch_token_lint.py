#!/usr/bin/env python3
"""scripts/ci/cron_dispatch_token_lint.py fails a scheduled workflow that dispatches on the job token."""
from contextlib import redirect_stdout
import io
from pathlib import Path
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import cron_dispatch_token_lint as lint  # noqa: E402

MINT = """
      - name: Mint the cmux bot App token
        id: app-token
        if: ${{ vars.CMUX_BOT_APP_ID != '' }}
        continue-on-error: true
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          app-id: ${{ vars.CMUX_BOT_APP_ID }}
          private-key: ${{ secrets.CMUX_BOT_APP_KEY }}
          permission-actions: write
"""


def workflow(on: str, steps: str, job_env: str = "") -> str:
    """A one-job workflow: `on` and `job_env` are YAML at column 0 and 4, `steps` at column 6."""
    return ("name: t\non:\n" + textwrap.indent(on, "  ") + "\njobs:\n  start:\n    runs-on: ubuntu-24.04\n"
            + job_env + "    steps:\n" + steps)


class LintTests(unittest.TestCase):
    def check(self, files: dict[str, str]) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".github/workflows").mkdir(parents=True)
            for name, text in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
            out = io.StringIO()
            with redirect_stdout(out):
                code = lint.main(["--workflows", str(root / ".github/workflows"), "--root", str(root)])
            return code, out.getvalue()

    def test_scheduled_dispatch_on_job_token_fails(self):
        steps = """
      - name: Dispatch
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh workflow run x.yml --ref feat-cmux-next
"""
        code, out = self.check({".github/workflows/a.yml": workflow("schedule:\n  - cron: '0 4 * * *'", steps)})
        self.assertEqual(code, 1)
        self.assertIn("a.yml: start: Dispatch", out)

    def test_job_level_token_and_rest_dispatch_fail(self):
        steps = """
      - name: Dispatch
        run: gh api -X POST repos/o/r/actions/workflows/x.yml/dispatches -f ref=main
"""
        env = "    env:\n      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n"
        code, _ = self.check({".github/workflows/a.yml": workflow("schedule:\n  - cron: '0 4 * * *'", steps, env)})
        self.assertEqual(code, 1)

    def test_dispatch_in_a_named_script_fails(self):
        steps = """
      - name: Wake
        env:
          GH_TOKEN: ${{ github.token }}
        run: python3 scripts/ci/wake.py
"""
        code, _ = self.check({
            ".github/workflows/a.yml": workflow("schedule:\n  - cron: '0 4 * * *'", steps),
            "scripts/ci/wake.py": "request('POST', '/actions/workflows/x.yml/dispatches')\n",
        })
        self.assertEqual(code, 1)

    def test_app_token_with_fallback_passes(self):
        steps = MINT + """
      - name: Dispatch
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token || github.token }}
        run: gh workflow run x.yml --ref feat-cmux-next
"""
        code, out = self.check({".github/workflows/a.yml": workflow("schedule:\n  - cron: '0 4 * * *'", steps)})
        self.assertEqual((code, out), (0, ""))

    def test_step_token_overrides_job_token(self):
        steps = MINT + """
      - name: Dispatch
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token || github.token }}
        run: gh workflow run x.yml
"""
        env = "    env:\n      GH_TOKEN: ${{ github.token }}\n"
        code, _ = self.check({".github/workflows/a.yml": workflow("schedule:\n  - cron: '0 4 * * *'", steps, env)})
        self.assertEqual(code, 0)

    def test_gh_app_token_router_passes_but_reads_only_does_not(self):
        router = """
      - name: Route gh through the App
        run: bash scripts/ci/gh_app_token.sh --install{flag}
      - name: Dispatch
        env:
          GH_TOKEN: ${{{{ github.token }}}}
        run: gh workflow run x.yml
"""
        on = "schedule:\n  - cron: '0 4 * * *'"
        self.assertEqual(self.check({".github/workflows/a.yml": workflow(on, router.format(flag=""))})[0], 0)
        self.assertEqual(self.check({".github/workflows/a.yml": workflow(on, router.format(flag=" --reads-only"))})[0], 1)

    def test_unscheduled_workflow_is_not_checked(self):
        steps = """
      - name: Dispatch
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh workflow run x.yml
"""
        code, _ = self.check({".github/workflows/a.yml": workflow("workflow_dispatch: {}", steps)})
        self.assertEqual(code, 0)

    def test_repository_is_clean(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = lint.main([])
        self.assertEqual(code, 0, out.getvalue())


if __name__ == "__main__":
    unittest.main()
