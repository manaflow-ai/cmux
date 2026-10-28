"""The glaeda-route App's installation budget is spent only where a job needs it (no network).

About 30 workflows read GitHub on one manaflow-glaeda-route App installation, CLA
policy guard (a required check on main) among them. On 2026-10-28 from 06:44Z that
installation's hourly budget ran out ("API rate limit exceeded for installation ID
164690637") and the guard rejected every pull request into main until the reset.

Every mint of an installation token costs that budget a call even when nothing
reads with it: actions/create-github-app-token's post step revokes the token with
DELETE /installation/token, authenticated as the installation. So:

- a read-only glaeda-route token is not revoked (it expires within the hour on an
  ephemeral runner): skip-token-revoke: true;
- a job mints the token only when it will read with it: backend-migrations after
  git shows the migration tree changed, CI failure attribution only when the
  cmux-bot mint (its preferred read token) gave nothing;
- pr-media starts no plan for a CI re-run or a cancelled CI run, which it never
  tours.

cla-policy-guard.yml is pinned byte for byte by scripts/ci/validate-cla-policy.rb
and is left as it is. The nightly and NEXT dev workflows are sequenced separately.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
APP_KEY = "${{ secrets.GLAEDA_ROUTE_APP_KEY }}"
# The guard is validated as exact bytes by the trusted validator; the nightly and NEXT dev
# workflows change only through their own sequenced pull requests.
EXEMPT = {"cla-policy-guard.yml"}
EXEMPT_PREFIXES = ("nightly", "cmux-next-dev-daily")


def load(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))


def glaeda_mints():
    for path in sorted(WORKFLOWS.glob("*.yml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        for job_name, job in (document.get("jobs") or {}).items():
            for step in job.get("steps") or []:
                if ("actions/create-github-app-token@" in str(step.get("uses", ""))
                        and (step.get("with") or {}).get("private-key") == APP_KEY):
                    yield path.name, job_name, step


def step(document: dict, job: str, step_id: str) -> tuple[int, dict]:
    steps = document["jobs"][job]["steps"]
    index = next(i for i, s in enumerate(steps) if s.get("id") == step_id)
    return index, steps[index]


class ReadOnlyMintsAreNotRevoked(unittest.TestCase):
    def test_every_read_only_glaeda_route_mint_skips_the_revoke_call(self) -> None:
        checked = 0
        for name, job, mint in glaeda_mints():
            if name in EXEMPT or name.startswith(EXEMPT_PREFIXES):
                continue
            permissions = {k: v for k, v in mint["with"].items() if k.startswith("permission-")}
            if not permissions or any(v != "read" for v in permissions.values()):
                continue  # a write token is still revoked when its job ends
            checked += 1
            with self.subTest(workflow=name, job=job, step=mint.get("id")):
                self.assertIs(mint["with"].get("skip-token-revoke"), True)
        # The high-volume readers (CI, risk tier, merge freeze, pr-media, ...) are all covered.
        self.assertGreaterEqual(checked, 20)

    def test_write_tokens_are_still_revoked(self) -> None:
        for name, job, mint in glaeda_mints():
            permissions = {k: v for k, v in mint["with"].items() if k.startswith("permission-")}
            if not permissions or any(v != "read" for v in permissions.values()):
                with self.subTest(workflow=name, job=job, step=mint.get("id")):
                    self.assertNotIn("skip-token-revoke", mint["with"])


class MintsOnlyWhenRead(unittest.TestCase):
    def test_failure_attribution_mints_the_glaeda_route_token_only_without_cmux_bot(self) -> None:
        document = load("ci-failure-attribution.yml")
        bot_index, _ = step(document, "attribute", "cmux-bot-token")
        index, mint = step(document, "attribute", "glaeda-token")
        self.assertLess(bot_index, index)
        self.assertIn("steps.cmux-bot-token.outputs.token == ''", mint["if"])

    def test_backend_migrations_mints_only_for_a_changed_migration_tree(self) -> None:
        document = load("backend-migrations.yml")
        trees_index, trees = step(document, "plan", "trees")
        index, mint = step(document, "plan", "glaeda-token")
        self.assertLess(trees_index, index)
        self.assertIn("steps.trees.outputs.same == 'false'", mint["if"])
        # The file listing still falls back to GITHUB_TOKEN when no App token was minted.
        files = next(s for s in document["jobs"]["plan"]["steps"] if s.get("id") == "files")
        self.assertEqual(files["env"]["READ_TOKEN"], "${{ steps.glaeda-token.outputs.token }}")
        self.assertIn('[ -z "${READ_TOKEN:-}" ]', files["run"])
        self.assertTrue(trees["run"])

    def test_the_tree_comparison_tells_a_migration_change_from_any_other(self) -> None:
        _, trees = step(load("backend-migrations.yml"), "plan", "trees")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@e",
                   "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@e"}

            def git(*args: str, cwd: Path = root / "src") -> str:
                return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True,
                                      text=True, env=env).stdout.strip()

            (root / "src/backend/db/migrations").mkdir(parents=True)
            git("init", "-q", "-b", "main")
            git("config", "uploadpack.allowAnySHA1InWant", "true")
            (root / "src/backend/db/migrations/0001_init.sql").write_text("create table t (id int);\n")
            (root / "src/App.tsx").write_text("base\n")
            git("add", "-A")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            git("branch", "base")
            (root / "src/App.tsx").write_text("ui\n")
            git("commit", "-qam", "ui")
            ui_head = git("rev-parse", "HEAD")
            (root / "src/backend/db/migrations/0002_more.sql").write_text("create table u (id int);\n")
            git("add", "-A")
            git("commit", "-qm", "migration")
            migration_head = git("rev-parse", "HEAD")

            def same(head: str) -> str:
                work = Path(tempfile.mkdtemp(dir=tmp))
                # The job's checkout: the base commit alone, as actions/checkout leaves it.
                subprocess.run(["git", "clone", "-q", "--depth=1", "--branch", "base", f"file://{root / 'src'}",
                                str(work / "trusted")], check=True, capture_output=True)
                output = work / "output"
                output.touch()
                subprocess.run(["bash", "-e", "-c", trees["run"]], cwd=work, check=True, capture_output=True,
                               env={**env, "BASE_SHA": base, "HEAD_SHA": head, "GITHUB_OUTPUT": str(output)})
                return output.read_text().strip()

            self.assertEqual(same(ui_head), "same=true")
            self.assertEqual(same(migration_head), "same=false")


class PrMediaPlansOnlyFirstFinishedRuns(unittest.TestCase):
    def test_plan_skips_ci_reruns_and_cancelled_ci_runs_but_not_dispatches(self) -> None:
        condition = load("pr-media.yml")["jobs"]["plan"]["if"]
        self.assertIn("github.event.workflow_run.run_attempt == 1", condition)
        self.assertIn("github.event.workflow_run.conclusion != 'cancelled'", condition)
        # A manual dispatch is the escape hatch for any head the filters passed over.
        self.assertIn("github.event_name == 'workflow_dispatch' ||", condition)


class TheBudgetIsMeasured(unittest.TestCase):
    def test_the_cla_janitor_logs_the_installation_budget_every_pass(self) -> None:
        steps = load("ci-cla-quota-rerun.yml")["jobs"]["cla-quota-rerun"]["steps"]
        ids = [s.get("id") for s in steps]
        log = next(s for s in steps if s.get("name") == "Log the glaeda-route App's budget")
        self.assertLess(ids.index("glaeda-token"), steps.index(log))
        self.assertEqual(log["env"]["GH_TOKEN"], "${{ steps.glaeda-token.outputs.token }}")
        self.assertIs(log["continue-on-error"], True)
        self.assertIn("gh api rate_limit", log["run"])


if __name__ == "__main__":
    unittest.main()
