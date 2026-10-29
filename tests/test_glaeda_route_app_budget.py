"""The glaeda-route App's installation budget is spent only where a job needs it (no network).

About 30 workflows read GitHub on one manaflow-glaeda-route App installation, CLA
policy guard (a required check on main) among them. On 2026-10-28 from 06:44Z that
installation's hourly budget ran out ("API rate limit exceeded for installation ID
164690637") and the guard rejected every pull request into main until the reset.

Every mint of an installation token costs that budget a call even when nothing
reads with it: actions/create-github-app-token's post step revokes the token with
DELETE /installation/token, authenticated as the installation. So:

- a glaeda-route token minted read-only on contents, pull requests, actions or issues
  (data a public repository shows anyway) is not revoked; it expires within the hour on
  an ephemeral runner: skip-token-revoke: true. Any other scope (administration, the
  org's runners) or any write permission keeps the revoke;
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


# Scopes a leftover token may hold: data a public repository shows anyway.
UNREVOKED_SCOPES = {"permission-contents", "permission-pull-requests", "permission-actions", "permission-issues"}


def leftover_ok(mint: dict) -> bool:
    permissions = {k: v for k, v in mint["with"].items() if k.startswith("permission-")}
    return bool(permissions) and set(permissions) <= UNREVOKED_SCOPES and all(v == "read" for v in permissions.values())


class OnlyNarrowReadTokensAreLeftUnrevoked(unittest.TestCase):
    def test_every_narrow_read_mint_skips_the_revoke_call(self) -> None:
        checked = 0
        for name, job, mint in glaeda_mints():
            if name in EXEMPT or name.startswith(EXEMPT_PREFIXES) or not leftover_ok(mint):
                continue
            checked += 1
            with self.subTest(workflow=name, job=job, step=mint.get("id")):
                self.assertIs(mint["with"].get("skip-token-revoke"), True)
        # backend-migrations, pr-media (plan and tour), CI's admitted-build read, the rescues, UI tests,
        # risk tier, the freeze check, and the failure, compile and guard attribution readers.
        self.assertGreaterEqual(checked, 13)
        for name, job in (("risk-tier.yml", "evidence"), ("merge-freeze.yml", "check")):
            with self.subTest(workflow=name, job=job):
                _, mint = step(load(name), job, "glaeda-token")
                self.assertEqual(mint["with"]["permission-issues"], "read")
                self.assertIs(mint["with"]["skip-token-revoke"], True)

    def test_the_bound_itself(self) -> None:
        def mint(**permissions: str) -> dict:
            return {"with": {f"permission-{k.replace('_', '-')}": v for k, v in permissions.items()}}
        self.assertTrue(leftover_ok(mint(issues="read")))
        self.assertTrue(leftover_ok(mint(issues="read", pull_requests="read", contents="read")))
        # issues:read beside any write, or beside administration or the org's runners, keeps the revoke.
        self.assertFalse(leftover_ok(mint(issues="read", pull_requests="write")))
        self.assertFalse(leftover_ok(mint(issues="read", actions="write")))
        self.assertFalse(leftover_ok(mint(issues="write")))
        self.assertFalse(leftover_ok(mint(issues="read", administration="read")))
        self.assertFalse(leftover_ok(mint(administration="read", organization_self_hosted_runners="read")))
        self.assertFalse(leftover_ok(mint()))

    def test_write_and_routing_tokens_keep_the_revoke(self) -> None:
        # The freeze expire job writes issues; CI and ci-macos route with administration read.
        _, expire = step(load("merge-freeze.yml"), "expire", "glaeda-token")
        self.assertEqual(expire["with"]["permission-issues"], "write")
        self.assertNotIn("skip-token-revoke", expire["with"])
        for name, job in (("ci.yml", "changes"), ("ci-macos.yml", "admission-placement")):
            for step_id in ("route-token", "route-token-repo"):
                with self.subTest(workflow=name, step=step_id):
                    _, routing = step(load(name), job, step_id)
                    self.assertNotIn("skip-token-revoke", routing["with"])

    def test_every_other_mint_is_still_revoked(self) -> None:
        for name, job, mint in glaeda_mints():
            if not leftover_ok(mint):
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

    # (workflow, job, probe label, first step bracketed, last step bracketed)
    PROBED = [
        ("pr-media.yml", "plan", "plan", "Pick the tours for the changed files", None),
        ("pr-media.yml", "tour", "tour", "Run the tour on the pull request's build", None),
        ("risk-tier.yml", "evidence", "evidence", "Grade the pull request", "Set the risk label"),
        ("ci.yml", "changes", "changes-route", "Choose the pull request macOS pool", None),
        ("ci.yml", "changes", "changes-admitted", "Look for an earlier run that compiled these inputs", None),
        ("merge-freeze.yml", "check", "check", "Check the pull request against open freezes", None),
        ("ci-hosted-queue-rescue.yml", "rescue", "rescue", "Rerun only a no-runner hosted queue timeout", None),
        ("ci-failure-attribution.yml", "attribute", "attribute",
         "Attribute failures and re-run machine failures", None),
        ("ci-guard-attribution.yml", "analyze", "analyze", "Analyze", None),
        ("ci-guard-attribution.yml", "report", "report",
         "Comment, and open, update or close the tracking issue", None),
        ("ci-compile-attribution.yml", "analyze", "analyze", "Analyze", None),
    ]

    def test_the_top_app_readers_log_the_budget_before_and_after(self) -> None:
        # The probes read only the free rate_limit endpoint (it does not count against the
        # budget), never fail their job, and never change a token or a permission.
        for workflow, job, label, first, last in self.PROBED:
            with self.subTest(workflow=workflow, probe=label):
                steps = load(workflow)["jobs"][job]["steps"]
                names = [s.get("name") for s in steps]
                begin, end = names.index(first), names.index(last or first)
                before, after = steps[begin - 1], steps[end + 1]
                for probe, when in ((before, "before"), (after, "after")):
                    self.assertEqual(probe["name"], f"Log the glaeda-route App budget {when}")
                    self.assertEqual(probe["env"]["PROBE"], f"${{{{ github.workflow }}}}/{label}/{when}")
                    self.assertIs(probe["continue-on-error"], True)
                    self.assertEqual(probe["timeout-minutes"], 1)
                    self.assertEqual(set(probe), {"name", "if", "continue-on-error", "timeout-minutes", "env", "run"})
                    self.assertTrue(probe["run"].startswith("gh api rate_limit --jq "), probe["run"])
                    self.assertNotIn("\n", probe["run"])
                    token = probe["env"]["GH_TOKEN"].removeprefix("${{ ").removesuffix(" }}")
                    self.assertIn(f"({token}) != ''", probe["if"])
                self.assertIn("!cancelled()", after["if"])


if __name__ == "__main__":
    unittest.main()
