"""backend-migrations.yml plan: a PR that does not touch backend/db/migrations
passes without the GitHub API. The installation's API quota ran out under load
and failed the plan on cmux-next UI PRs (#17602, #17609) that change no SQL."""

from __future__ import annotations

import os
import re
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

    def test_the_probe_reads_the_runners_mirror_without_the_network(self):
        # The pool's mirror holds both commits: no fetch, so an unreachable github.com does not matter.
        (self.src / "App.tsx").write_text("ui change\n")
        git(self.src, "commit", "-qam", "ui")
        head = git(self.src, "rev-parse", "HEAD")
        mirror = self.tmp / "mirror.git"
        subprocess.run(["git", "clone", "-q", "--mirror", str(self.src), str(mirror)], check=True)
        (mirror / "cmux-ready").write_text("")
        doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        step = next(s for s in doc["jobs"]["plan"]["steps"] if s.get("id") == "same-tree")
        work = Path(tempfile.mkdtemp(dir=self.tmp))
        output = self.tmp / "output"
        output.write_text("")
        env = {**os.environ, "BASE_SHA": self.base, "HEAD_SHA": head, "REPO": "o/r", "GITHUB_OUTPUT": str(output),
               "CMUX_GIT_MIRROR": str(mirror), **NO_NETWORK}
        result = subprocess.run(["bash", "-e", "-c", step["run"]], cwd=work, env=env, capture_output=True, text=True)
        log = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, log)
        self.assertIn("same=true", output.read_text(), log)
        self.assertIn("runner's git mirror", log)


# github.com rewritten to a path that does not exist: any network fetch fails at once.
NO_NETWORK = {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "url.file:///nonexistent/r.git.insteadOf",
              "GIT_CONFIG_VALUE_0": "https://github.com/o/r.git"}


class BaseCheckout(unittest.TestCase):
    """The base's backend/ comes from the pool runner's git mirror when it holds the commit, else a bounded,
    retried blobless fetch. A 60 s actions/checkout timed out twice on PRs 56905, 53402 and 57565 (2026-11-26)
    while the runner's mirror already held the base."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        src = self.tmp / "src"
        src.mkdir()
        git(src, "init", "-q", "-b", "main")
        git(src, "config", "uploadpack.allowAnySHA1InWant", "true")
        git(src, "config", "uploadpack.allowFilter", "true")
        (src / "backend/db/migrations").mkdir(parents=True)
        (src / "backend/db/migrations/0001_init.sql").write_text("create table t (id int);\n")
        (src / "webviews").mkdir()
        (src / "webviews/App.tsx").write_text("base\n")
        git(src, "add", "-A")
        git(src, "commit", "-qm", "base")
        self.base = git(src, "rev-parse", "HEAD")
        self.src = src

    def step(self) -> dict:
        steps = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["plan"]["steps"]
        return next(s for s in steps if s.get("id") == "checkout")

    def checkout(self, network: dict, mirror: Path | None = None, pause_free: bool = True) -> tuple[int, Path, str]:
        work = Path(tempfile.mkdtemp(dir=self.tmp))
        run = self.step()["run"]
        if pause_free:
            run = run.replace("sleep $((try == 1 ? 5 : 15))", ":")
        env = {**os.environ, "BASE_SHA": self.base, "REPO": "o/r", "RUNNER_NAME": "r-test",
               "CMUX_GIT_MIRROR": str(mirror or self.tmp / "no-mirror"), **network}
        result = subprocess.run(["bash", "-e", "-c", run], cwd=work, env=env, capture_output=True, text=True)
        return result.returncode, work / "trusted", result.stdout + result.stderr

    def test_the_mirror_serves_the_base_with_no_network(self):
        mirror = self.tmp / "mirror.git"
        subprocess.run(["git", "clone", "-q", "--mirror", str(self.src), str(mirror)], check=True)
        (mirror / "cmux-ready").write_text("")
        code, trusted, log = self.checkout(NO_NETWORK, mirror)
        self.assertEqual(code, 0, log)
        self.assertIn("from the runner's git mirror", log)
        self.assertTrue((trusted / "backend/db/migrations/0001_init.sql").is_file(), log)
        self.assertFalse((trusted / "webviews").exists(), "sparse: backend/ only")
        self.assertEqual(git(trusted, "rev-parse", "HEAD"), self.base)

    def test_a_head_the_mirror_holds_needs_no_head_fetch(self):
        # The base came from the mirror, so trusted/ borrows its objects; a head the mirror holds is read with no
        # network instead of a 90 s fetch from github.com (the fetch that stalled on the gate VMs, run 45767986647).
        (self.src / "backend/db/migrations/0002_more.sql").write_text("create table u (id int);\n")
        git(self.src, "add", "-A")
        git(self.src, "commit", "-qm", "head")
        head = git(self.src, "rev-parse", "HEAD")
        mirror = self.tmp / "mirror.git"
        subprocess.run(["git", "clone", "-q", "--mirror", str(self.src), str(mirror)], check=True)
        (mirror / "cmux-ready").write_text("")
        code, trusted, log = self.checkout(NO_NETWORK, mirror)
        self.assertEqual(code, 0, log)
        trees = next(s for s in plan_steps() if s.get("id") == "trees")["run"]
        out = self.tmp / "out"
        env = {**os.environ, **NO_NETWORK, "BASE_SHA": self.base, "HEAD_SHA": head, "GITHUB_OUTPUT": str(out)}
        result = subprocess.run(["bash", "-e", "-c", trees], cwd=trusted.parent, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("fetch of the head", result.stdout + result.stderr)
        self.assertEqual(out.read_text().strip(), "same=false")

    def test_a_mirror_not_ready_or_without_the_commit_fetches_from_github(self):
        mirror = self.tmp / "mirror.git"
        subprocess.run(["git", "init", "-q", "--bare", str(mirror)], check=True)
        (mirror / "cmux-ready").write_text("")
        redirect = {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": f"url.file://{self.src}.insteadOf",
                    "GIT_CONFIG_VALUE_0": "https://github.com/o/r.git"}
        code, trusted, log = self.checkout(redirect, mirror)
        self.assertEqual(code, 0, log)
        self.assertIn("from github.com", log)
        self.assertTrue((trusted / "backend/db/migrations/0001_init.sql").is_file(), log)
        self.assertFalse((trusted / "webviews").exists(), "sparse: backend/ only")

    def test_a_failed_fetch_is_retried_and_names_its_cause(self):
        code, _, log = self.checkout(NO_NETWORK)
        self.assertNotEqual(code, 0, log)
        self.assertIn("failed on all 3 tries (240 s each)", log)
        self.assertEqual(log.count("failed on try"), 2, log)
        self.assertIn("runner r-test", log)
        self.assertIn("not the PR", log)

    def test_the_base_checkout_is_bounded_and_retried(self):
        step = self.step()
        self.assertNotIn("continue-on-error", step)
        self.assertLessEqual(step["timeout-minutes"], 17)
        self.assertGreaterEqual(step["timeout-minutes"] * 60, 3 * 240 + 5 + 15 + 180)
        run = step["run"]
        for bound in ('git_retry "base fetch of $BASE_SHA from github.com" 240 ', "http.lowSpeedTime=60", "timeout 180 git",
                      "--filter=blob:none --depth=1", "sparse-checkout set --cone backend"):
            self.assertIn(bound, run)
        steps = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["plan"]["steps"]
        self.assertFalse([s for s in steps if s.get("id") == "checkout-retry"])

    def test_head_fetches_use_a_refspec_the_mirror_shim_can_serve(self):
        # The pool's git shim answers a fetch from the mirror only when every refspec is "<sha>:refs/...".
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn('origin "$HEAD_SHA" ', text)
        self.assertIn('origin "+$HEAD_SHA:refs/remotes/origin/head"', text)


def plan_steps() -> list[dict]:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["plan"]["steps"]


def retry_function(script: str) -> str:
    start = script.index("git_retry() {")
    return script[start:script.index("\n}\n", start) + 3]


class TransportRetry(unittest.TestCase):
    """A dropped github.com transfer ("Operation too slow", job 139712437101 on cmux#55995) is
    tried again, bounded; a refusal stops on its first try; the error names the tries."""

    RETRIED = ("same-tree", "checkout", "trees", "files")

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.calls = self.tmp / "calls"
        # sleep is a no-op here so the backoff costs the test nothing.
        (self.bin / "sleep").write_text("#!/bin/sh\necho \"sleep $*\" >> \"$CALLS\"\n")
        (self.bin / "sleep").chmod(0o755)

    def fake_git(self, *answers: tuple[int, str]) -> None:
        # Each call takes the next answer (exit code, stderr); the last one repeats.
        lines = ["#!/bin/sh", 'n=$(grep -c "^git" "$CALLS" 2>/dev/null || echo 0)', 'echo "git $*" >> "$CALLS"']
        for index, (code, err) in enumerate(answers[:-1]):
            lines.append(f'if [ "$n" -eq {index} ]; then echo "{err}" >&2; exit {code}; fi')
        code, err = answers[-1]
        lines.append(f'echo "{err}" >&2; exit {code}')
        (self.bin / "git").write_text("\n".join(lines) + "\n")
        (self.bin / "git").chmod(0o755)

    def run_retry(self) -> tuple[int, str, list[str]]:
        script = retry_function(next(s for s in plan_steps() if s.get("id") == "trees")["run"])
        env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "CALLS": str(self.calls),
               "RUNNER_NAME": "e1c-0251"}
        result = subprocess.run(["bash", "-euo", "pipefail", "-c", script + 'git_retry "fetch of the head abc" 5 fetch origin abc'],
                                env=env, capture_output=True, text=True)
        calls = self.calls.read_text().splitlines() if self.calls.exists() else []
        return result.returncode, result.stdout + result.stderr, calls

    def test_a_slow_transfer_is_tried_again_and_then_passes(self):
        self.fake_git((128, "error: RPC failed; curl 28 Operation too slow. Less than 1000 bytes/sec transferred the last 30 seconds"), (0, ""))
        code, log, calls = self.run_retry()
        self.assertEqual(code, 0, log)
        self.assertEqual([c for c in calls if c.startswith("git")].__len__(), 2, calls)
        self.assertIn("failed on try 1 of 3, trying again", log)
        self.assertIn("http.lowSpeedLimit=1 ", calls[0])

    def test_transport_failures_stop_after_three_tries_and_name_them(self):
        for err in ("error: RPC failed; curl 28 Operation too slow.",
                    "fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com",
                    "fatal: unable to access 'https://github.com/o/r.git/': The requested URL returned error: 502",
                    "error: RPC failed; curl 56 Recv failure: Connection reset by peer"):
            with self.subTest(err=err):
                self.calls.unlink(missing_ok=True)
                self.fake_git((128, err))
                code, log, calls = self.run_retry()
                self.assertNotEqual(code, 0, log)
                self.assertEqual([c for c in calls if c.startswith("git")].__len__(), 3, calls)
                self.assertEqual([c for c in calls if c.startswith("sleep")], ["sleep 5", "sleep 15"])
                self.assertIn("::error::fetch of the head abc failed on all 3 tries (5 s each) on runner e1c-0251", log)

    def test_a_refusal_is_not_tried_again(self):
        for err in ("fatal: remote error: upload-pack: not our ref 0000000000000000000000000000000000000000",
                    "remote: Repository not found.",
                    "fatal: unable to access 'https://github.com/o/r.git/': The requested URL returned error: 403",
                    "fatal: couldn't find remote ref refs/heads/gone"):
            with self.subTest(err=err):
                self.calls.unlink(missing_ok=True)
                self.fake_git((128, err))
                code, log, calls = self.run_retry()
                self.assertNotEqual(code, 0, log)
                self.assertEqual(len(calls), 1, calls)
                self.assertIn("refused on try 1 of 3, not tried again", log)

    def test_a_hang_is_cut_at_the_bound_and_tried_again(self):
        self.fake_git((124, ""))
        code, log, calls = self.run_retry()
        self.assertNotEqual(code, 0, log)
        self.assertIn("failed on all 3 tries", log)
        self.assertIn("hung past 5 s", log)

    def test_every_step_that_reads_github_uses_the_same_retry(self):
        steps = {s.get("id"): s["run"] for s in plan_steps() if s.get("id") in self.RETRIED}
        self.assertEqual(set(steps), set(self.RETRIED))
        bodies = {retry_function(run) for run in steps.values()}
        self.assertEqual(len(bodies), 1, "the git_retry copies drifted apart")
        for sid, run in steps.items():
            for line in run.splitlines():
                # A git command line (not a comment or a message) that talks to the remote.
                if re.search(r"\b(fetch|archive) (-|origin)", line) and not line.lstrip().startswith(("#", "echo")):
                    with self.subTest(step=sid, line=line.strip()):
                        self.assertIn("git_retry ", line)

    def test_the_job_deadline_fits_the_retried_path(self):
        plan = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["plan"]
        # probe 3 x 60, checkout 3 x 240 plus its 180 s blob read, head fetch 3 x 90, blob read 3 x 90, backoff 4 x 20.
        worst = 3 * 60 + (3 * 240 + 180) + 3 * 90 + 3 * 90 + 4 * 20
        self.assertGreaterEqual(plan["timeout-minutes"] * 60, worst)


    def test_no_low_speed_abort_above_one_byte_a_second(self):
        # GitHub sends next to nothing while it builds a shallow, filtered pack of this repository, so a low-speed abort
        # above 1 B/s cuts a healthy fetch mid-build. Jobs 139897638176, 139897631159, 139898168920, 139897472857 and
        # 139898135049 (fsr, 2026-11-26) timed out on the base read; the wall clock is what bounds a real hang.
        text = WORKFLOW.read_text(encoding="utf-8")
        limits = re.findall(r"http\.lowSpeedLimit[= ](\d+)", text)
        self.assertTrue(limits, "every github.com read keeps a low-speed abort")
        self.assertEqual({int(n) for n in limits}, {1}, limits)
        for n in re.findall(r"http\.lowSpeedTime[= ](\d+)", text):
            self.assertGreaterEqual(int(n), 60)

if __name__ == "__main__":
    unittest.main()
