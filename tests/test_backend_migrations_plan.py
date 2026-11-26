"""backend-migrations.yml plan: a PR that does not touch backend/db/migrations
passes without the GitHub API. The installation's API quota ran out under load
and failed the plan on cmux-next UI PRs (#17602, #17609) that change no SQL."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/backend-migrations.yml"


def step_script() -> str:
    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    step = next(s for s in doc["jobs"]["plan"]["steps"] if s.get("name") == "Changed files and head migrations")
    return step["run"]


def git(cwd: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@e", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@e"}
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True, env=env).stdout.strip()


class PlanWithoutTheApi(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        src = self.tmp / "src"
        src.mkdir()
        git(src, "init", "-q", "-b", "main")
        git(src, "config", "uploadpack.allowAnySHA1InWant", "true")
        (src / "backend/db/migrations").mkdir(parents=True)
        (src / "backend/db/migrations/0001_init.sql").write_text("create table t (id int);\n")
        (src / "webviews").mkdir()
        (src / "webviews/App.tsx").write_text("base\n")
        git(src, "add", "-A")
        git(src, "commit", "-qm", "base")
        self.base = git(src, "rev-parse", "HEAD")
        git(src, "checkout", "-q", "-b", "pr")
        self.src = src
        # A gh that answers like the exhausted installation quota.
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text("#!/bin/sh\necho 'gh: API rate limit exceeded for installation. (HTTP 403)' >&2\nexit 1\n")
        (bin_dir / "gh").chmod(0o755)
        self.path = f"{bin_dir}:{os.environ['PATH']}"

    def run_plan(self, head: str, **extra: str) -> tuple[int, str, str]:
        work = self.tmp / "work"
        if work.exists():
            subprocess.run(["rm", "-rf", str(work)], check=True)
        work.mkdir()
        subprocess.run(["git", "clone", "-q", "--depth=1", f"file://{self.src}", str(work / "trusted"), "--branch", "main"], check=True)
        output = self.tmp / "output"
        output.write_text("")
        env = {**os.environ, "PATH": self.path, "GH_TOKEN": "t", "EVENT": "pull_request_target", "PR": "1",
               "BASE_SHA": self.base, "HEAD_SHA": head, "REPO": "o/r", "BASE_REF": "main",
               "GITHUB_OUTPUT": str(output), **extra}
        result = subprocess.run(["bash", "-e", "-c", step_script()], cwd=work, env=env, capture_output=True, text=True)
        return result.returncode, output.read_text(), result.stdout + result.stderr

    def test_a_pr_without_migration_changes_needs_no_api(self):
        (self.src / "webviews/App.tsx").write_text("ui change\n")
        git(self.src, "commit", "-qam", "ui")
        code, output, log = self.run_plan(git(self.src, "rev-parse", "HEAD"))
        self.assertEqual(code, 0, log)
        self.assertIn("migrations=false", output)

    def test_a_pr_that_adds_a_migration_still_lists_its_files(self):
        (self.src / "backend/db/migrations/0002_more.sql").write_text("create table u (id int);\n")
        git(self.src, "add", "-A")
        git(self.src, "commit", "-qm", "migration")
        code, output, log = self.run_plan(git(self.src, "rev-parse", "HEAD"))
        # The listing goes through the API, which this gh refuses: the plan fails
        # closed rather than pass a migration it could not inspect.
        self.assertNotEqual(code, 0, log)
        self.assertNotIn("migrations=false", output)


    def test_a_refused_app_token_falls_back_to_the_workflow_token(self):
        # READ_TOKEN is the manaflow-glaeda-route App's (its own budget). A refusal of it
        # (no budget left, say) lists the files on GITHUB_TOKEN instead.
        log = self.tmp / "tokens"
        (self.tmp / "bin/gh").write_text(
            "#!/bin/sh\n"
            f"echo \"$GH_TOKEN\" >> '{log}'\n"
            "if [ \"$GH_TOKEN\" = app ]; then echo 'gh: API rate limit exceeded (HTTP 403)' >&2; exit 1; fi\n"
            "printf 'added\\tbackend/db/migrations/0002_more.sql\\t\\n'\n")
        (self.src / "backend/db/migrations/0002_more.sql").write_text("create table u (id int);\n")
        git(self.src, "add", "-A")
        git(self.src, "commit", "-qm", "migration")
        code, output, out = self.run_plan(git(self.src, "rev-parse", "HEAD"), READ_TOKEN="app")
        self.assertEqual(code, 0, out)
        self.assertIn("migrations=true", output)
        self.assertEqual(log.read_text().split(), ["app", "t"])


class TreelessProbe(unittest.TestCase):
    """The plan's first step answers "no migration change" from a treeless fetch, so a head that
    touches no SQL skips the full base checkout (184 s at p50 on the gate pool)."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        src = self.tmp / "src"
        src.mkdir()
        git(src, "init", "-q", "-b", "main")
        git(src, "config", "uploadpack.allowAnySHA1InWant", "true")
        git(src, "config", "uploadpack.allowFilter", "true")
        (src / "backend/db/migrations").mkdir(parents=True)
        (src / "backend/db/migrations/0001_init.sql").write_text("create table t (id int);\n")
        (src / "App.tsx").write_text("base\n")
        git(src, "add", "-A")
        git(src, "commit", "-qm", "base")
        self.base = git(src, "rev-parse", "HEAD")
        self.src = src

    def probe(self, head: str) -> tuple[int, str, str]:
        doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        step = next(s for s in doc["jobs"]["plan"]["steps"] if s.get("id") == "same-tree")
        work = Path(tempfile.mkdtemp(dir=self.tmp))
        output = self.tmp / "output"
        output.write_text("")
        # The step fetches from https://github.com/$REPO.git; point that URL at the local repo.
        redirect = {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": f"url.file://{self.src}.insteadOf",
                    "GIT_CONFIG_VALUE_0": "https://github.com/o/r.git"}
        env = {**os.environ, "BASE_SHA": self.base, "HEAD_SHA": head, "REPO": "o/r",
               "GITHUB_OUTPUT": str(output), **redirect}
        result = subprocess.run(["bash", "-e", "-c", step["run"]], cwd=work, env=env, capture_output=True, text=True)
        return result.returncode, output.read_text(), result.stdout + result.stderr

    def test_the_probe_runs_first_and_skips_the_checkout(self):
        plan = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["plan"]
        self.assertEqual(plan["steps"][0].get("id"), "same-tree")
        checkout = next(s for s in plan["steps"] if s.get("name") == "Checkout base (trusted tooling)")
        self.assertIn("steps.same-tree.outputs.same != 'true'", checkout["if"])
        self.assertIn("steps.same-tree.outputs.same == 'true' && 'false'", plan["outputs"]["migrations"])

    def test_a_head_without_migration_changes_is_the_same_tree(self):
        (self.src / "App.tsx").write_text("ui change\n")
        git(self.src, "commit", "-qam", "ui")
        code, output, log = self.probe(git(self.src, "rev-parse", "HEAD"))
        self.assertEqual(code, 0, log)
        self.assertIn("same=true", output, log)

    def test_a_head_that_adds_a_migration_runs_the_full_plan(self):
        (self.src / "backend/db/migrations/0002_more.sql").write_text("create table u (id int);\n")
        git(self.src, "add", "-A")
        git(self.src, "commit", "-qm", "migration")
        code, output, log = self.probe(git(self.src, "rev-parse", "HEAD"))
        self.assertEqual(code, 0, log)
        self.assertNotIn("same=true", output)

    def test_a_failed_fetch_runs_the_full_plan(self):
        code, output, log = self.probe("0" * 40)
        self.assertEqual(code, 0, log)
        self.assertNotIn("same=true", output)

    def without_migrations(self) -> None:
        # main's shape: no backend/db/migrations at the base.
        git(self.src, "rm", "-rq", "backend")
        git(self.src, "commit", "-qm", "no migrations")
        self.base = git(self.src, "rev-parse", "HEAD")

    def test_no_migrations_on_either_side_is_the_same_tree(self):
        # Both rev-parses come back empty here; the plan used to fall through to a full checkout of
        # main, which hung on the gate pool until the 10-minute cancel (run 45091304441).
        self.without_migrations()
        (self.src / "App.tsx").write_text("ui change\n")
        git(self.src, "commit", "-qam", "ui")
        code, output, log = self.probe(git(self.src, "rev-parse", "HEAD"))
        self.assertEqual(code, 0, log)
        self.assertIn("same=true", output, log)
        self.assertIn("no backend/db/migrations at the base or the head", log)

    def test_a_head_that_adds_the_first_migration_runs_the_full_plan(self):
        self.without_migrations()
        (self.src / "backend/db/migrations").mkdir(parents=True)
        (self.src / "backend/db/migrations/0001_init.sql").write_text("create table t (id int);\n")
        git(self.src, "add", "-A")
        git(self.src, "commit", "-qm", "first migration")
        code, output, log = self.probe(git(self.src, "rev-parse", "HEAD"))
        self.assertEqual(code, 0, log)
        self.assertNotIn("same=true", output)

    def test_a_head_that_deletes_the_migrations_runs_the_full_plan(self):
        git(self.src, "rm", "-rq", "backend")
        git(self.src, "commit", "-qm", "delete")
        code, output, log = self.probe(git(self.src, "rev-parse", "HEAD"))
        self.assertEqual(code, 0, log)
        self.assertNotIn("same=true", output)

    def test_the_base_checkout_is_bounded_and_retried(self):
        steps = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["plan"]["steps"]
        by_id = {s.get("id"): s for s in steps}
        for sid in ("checkout", "checkout-retry"):
            self.assertEqual(by_id[sid]["timeout-minutes"], 1)
            self.assertTrue(by_id[sid]["continue-on-error"])
            self.assertEqual(by_id[sid]["with"]["sparse-checkout"], "backend")
            self.assertEqual(by_id[sid]["with"]["filter"], "blob:none")
        self.assertIn("steps.checkout.outcome == 'failure'", by_id["checkout-retry"]["if"])
        failed = next(s for s in steps if s.get("name") == "Base checkout did not finish")
        self.assertIn("steps.checkout-retry.outcome == 'failure'", failed["if"])
        self.assertIn("exit 1", failed["run"])



class RunnerMirror(unittest.TestCase):
    """On the gate JIT VMs every fetch from github.com stalled (run 45767986647: both 60 s base checkout attempts
    timed out, then "Base checkout did not finish"). The plan reads the base and the head from the VM's git mirror
    first, with no network; a runner without the mirror, or a commit it lacks, takes the fetch it took before."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        src = self.tmp / "src"
        src.mkdir()
        git(src, "init", "-q", "-b", "main")
        (src / "backend/db/migrations").mkdir(parents=True)
        (src / "backend/db/migrations/0001_init.sql").write_text("create table t (id int);\n")
        (src / "backend/package.json").write_text("{}\n")
        (src / "webviews").mkdir()
        (src / "webviews/App.tsx").write_text("base\n")
        git(src, "add", "-A")
        git(src, "commit", "-qm", "base")
        self.base = git(src, "rev-parse", "HEAD")
        (src / "webviews/App.tsx").write_text("ui change\n")
        git(src, "commit", "-qam", "ui")
        self.head = git(src, "rev-parse", "HEAD")
        self.src = src
        self.mirror = self.tmp / "cmux.git"
        subprocess.run(["git", "clone", "-q", "--bare", str(src), str(self.mirror)], check=True)
        (self.mirror / "cmux-ready").write_text("")
        # github.com is unreachable in these tests: any fetch fails at once instead of hanging.
        self.offline = {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": f"url.file://{self.tmp}/nowhere.insteadOf",
                        "GIT_CONFIG_VALUE_0": "https://github.com/"}

    def steps(self) -> list[dict]:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["plan"]["steps"]

    def run_step(self, step_id: str, work: Path, mirror: Path | None, **extra: str) -> tuple[int, str, str]:
        step = next(s for s in self.steps() if s.get("id") == step_id)
        output = self.tmp / "output"
        output.write_text("")
        env = {**os.environ, "BASE_SHA": self.base, "HEAD_SHA": self.head, "REPO": "o/r",
               "GITHUB_OUTPUT": str(output), **self.offline, **extra}
        env.pop("CMUX_GIT_MIRROR", None)
        if mirror is not None:
            env["CMUX_GIT_MIRROR"] = str(mirror)
        result = subprocess.run(["bash", "-e", "-c", step["run"]], cwd=work, env=env, capture_output=True, text=True)
        return result.returncode, output.read_text(), result.stdout + result.stderr

    def test_the_job_names_the_fleet_mirror(self):
        plan = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["plan"]
        self.assertEqual(plan["env"]["CMUX_GIT_MIRROR"], "/var/lib/cmux-git/cmux.git")

    def test_the_probe_reads_both_commits_from_the_mirror_offline(self):
        work = Path(tempfile.mkdtemp(dir=self.tmp))
        code, output, log = self.run_step("same-tree", work, self.mirror)
        self.assertEqual(code, 0, log)
        self.assertIn("read from the runner's mirror", log)
        self.assertIn("same=true", output, log)

    def test_the_probe_without_a_mirror_still_fetches(self):
        work = Path(tempfile.mkdtemp(dir=self.tmp))
        code, output, log = self.run_step("same-tree", work, None)
        self.assertEqual(code, 0, log)
        self.assertIn("treeless fetch failed: full plan", log)
        self.assertNotIn("same=true", output)

    def test_the_base_is_checked_out_from_the_mirror_offline(self):
        work = Path(tempfile.mkdtemp(dir=self.tmp))
        code, output, log = self.run_step("mirror-base", work, self.mirror)
        self.assertEqual(code, 0, log)
        self.assertIn("ok=true", output, log)
        trusted = work / "trusted"
        self.assertEqual(git(trusted, "rev-parse", "HEAD"), self.base)
        self.assertTrue((trusted / "backend/db/migrations/0001_init.sql").is_file())
        self.assertFalse((trusted / "webviews").exists(), "sparse: only backend/ is checked out")
        self.assertEqual(git(trusted, "config", "remote.origin.url"), "https://github.com/o/r")

    def test_a_base_the_mirror_lacks_falls_through_to_actions_checkout(self):
        work = Path(tempfile.mkdtemp(dir=self.tmp))
        code, output, log = self.run_step("mirror-base", work, self.mirror, BASE_SHA="1" * 40)
        self.assertEqual(code, 0, log)
        self.assertNotIn("ok=true", output)
        self.assertFalse((work / "trusted").exists(), "the step removes the repository it made")

    def test_no_mirror_falls_through_to_actions_checkout(self):
        work = Path(tempfile.mkdtemp(dir=self.tmp))
        code, output, log = self.run_step("mirror-base", work, self.tmp / "absent.git")
        self.assertEqual(code, 0, log)
        self.assertNotIn("ok=true", output)
        self.assertFalse((work / "trusted").exists())

    def test_the_checkout_steps_run_only_when_the_mirror_did_not(self):
        by_id = {s.get("id"): s for s in self.steps()}
        ids = [s.get("id") for s in self.steps()]
        self.assertLess(ids.index("mirror-base"), ids.index("checkout"))
        for sid in ("checkout", "checkout-retry"):
            self.assertIn("steps.mirror-base.outputs.ok != 'true'", by_id[sid]["if"])
        self.assertEqual(by_id["checkout"]["name"], "Checkout base (trusted tooling)")

    def test_a_head_the_mirror_holds_needs_no_fetch(self):
        work = Path(tempfile.mkdtemp(dir=self.tmp))
        code, _, log = self.run_step("mirror-base", work, self.mirror)
        self.assertEqual(code, 0, log)
        code, output, log = self.run_step("trees", work, self.mirror)
        self.assertEqual(code, 0, log)
        self.assertIn("same=true", output, log)
        code, output, log = self.run_step("files", work, self.mirror, EVENT="pull_request_target", PR="1",
                                          BASE_REF="main", GH_TOKEN="t")
        self.assertEqual(code, 0, log)
        self.assertIn("migrations=false", output, log)

if __name__ == "__main__":
    unittest.main()
