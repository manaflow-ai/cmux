#!/usr/bin/env python3
"""scripts/ci/ci_receipt.py: a local test receipt counts only when GitHub's record of it holds up.

Each test builds the Actions API answers a receipt run gives (run, jobs, job log, compare) and checks the verifier
takes a real one and refuses a forged run, another tree, another command, a receipt replayed from another job, and
the rest. Run: python3 tests/test_ci_receipt.py
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import ci_receipt  # noqa: E402

sys.path.insert(0, str(ROOT / "tests"))
import git_fixture_env  # noqa: E402

REPO = "manaflow-ai/cmux"
CANONICAL = "python3 scripts/ci/ci_receipt.py produce fast-gates"
HEAD = "a" * 40
BASE = "b" * 40
OLD_BASE = "c" * 40
HEAD_TREE = "d" * 40
MERGE_TREE = "e" * 40
SOURCE = "f" * 40
RUN = "44321150132"
JOB_ID = 77


def log_text(command: str = "python3 scripts/ci/ci_receipt.py produce fast-gates", *, job: str = "fast-gates",
             head: str = HEAD, base: str = BASE, tree: str = MERGE_TREE, source_tree: str = HEAD_TREE,
             exit_code: int = 0, directory: str = ".", extra_output: str = "") -> str:
    stamp = "2026-11-19T08:00:00.1234567Z "
    receipt = json.dumps({"v": 1, "job": job, "head": head, "base": base, "tree": tree})
    fast = json.dumps({"source_sha": SOURCE, "source_tree": source_tree, "head_after": SOURCE, "exit_code": exit_code})
    # The shape of a real run's log (run 44321150132, job 135083977553): the script echoed in cyan, then shell:,
    # env: and the step's env, the workflow's own keys last. GitHub prints a value's further lines as lines of their own.
    lines = [
        "##[group]Run actions/checkout@v6", "with:", "##[endgroup]",
        "##[group]Run umask 022", "\x1b[36;1mumask 022\x1b[0m",
        "\x1b[36;1mcommand_text = os.environ['FAST_CHECKS_COMMAND']\x1b[0m",
        "shell: /usr/bin/bash -e {0}", "env:", "  CMUX_GHOSTTY_VT_ZIG_CPU: baseline",
        "  CARGO_HOME: /home/runner/_work/_temp/fast-checks-cache/cargo",
        *f"  FAST_CHECKS_COMMAND: {command}".split("\n"), f"  FAST_CHECKS_DIRECTORY: {directory}",
        "  FAST_CHECKS_TIMEOUT: 3600", f"  FAST_CHECKS_SOURCE: {SOURCE}",
        "  FAST_CHECKS_OUT: /home/runner/_work/_temp/fast-checks-out",
        "##[endgroup]",
        *extra_output.splitlines(),
        "fast-gates: crash ratchet passed",
        f"CMUX_CI_RECEIPT={receipt}",
        f"FAST_CHECKS_RECEIPT={fast}",
    ]
    return "\n".join(stamp + line for line in lines) + "\n"


def run_record(**overrides) -> dict:
    record = {
        "id": int(RUN), "html_url": f"https://github.com/{REPO}/actions/runs/{RUN}",
        "path": ".github/workflows/fast-checks.yml", "event": "workflow_dispatch", "head_branch": "main",
        "status": "completed", "conclusion": "success",
        "display_title": f"Fast checks {SOURCE} tests {REPO}@{HEAD}",
        "repository": {"full_name": REPO}, "head_repository": {"full_name": REPO},
        "actor": {"login": "teamleaderleo"}, "triggering_actor": {"login": "teamleaderleo"},
    }
    record.update(overrides)
    return record



# The verifier reads compares with git first (ci_receipt.git_compare); these tests answer them from FakeGitHub's
# REST compare, and GitCompareTest drives the git path against a local repository.
ci_receipt.git_compare = lambda *args, **kwargs: None

class FakeGitHub:
    def __init__(self, *, run: dict | None = None, log: str | None = None, compare: str = "ahead",
                 jobs: list | None = None, files: list[str] | None = None):
        self.run = run or run_record()
        self.log = log if log is not None else log_text()
        self.compare = compare
        self.files = files or []
        self.jobs = jobs if jobs is not None else [{"id": JOB_ID, "name": "checks", "conclusion": "success"}]
        self.calls: list[str] = []
        self.pr_commits: list[str] = [HEAD]
        self.listed: list[dict] = [run_record()]
        self.commit_dates: dict[str, str] = {}

    def __call__(self, path: str) -> bytes:
        self.calls.append(path)
        if path == f"repos/{REPO}/actions/runs/{RUN}":
            return json.dumps(self.run).encode()
        if path.startswith(f"repos/{REPO}/actions/runs/{RUN}/jobs"):
            return json.dumps({"jobs": self.jobs}).encode()
        if path == f"repos/{REPO}/actions/jobs/{JOB_ID}/logs":
            return self.log.encode()
        if path.startswith(f"repos/{REPO}/pulls/"):
            return json.dumps([{"sha": sha, "commit": {"committer": {"date": self.commit_dates.get(sha, "2026-11-19T07:00:00Z")}}}
                               for sha in self.pr_commits]).encode()
        if path.startswith(f"repos/{REPO}/actions/workflows/fast-checks.yml/runs?"):
            page = int(path.split("&page=", 1)[1].split("&", 1)[0])
            return json.dumps({"workflow_runs": self.listed[(page - 1) * 100:page * 100]}).encode()
        if path.startswith(f"repos/{REPO}/compare/"):
            return json.dumps({"status": self.compare, "files": [{"filename": f} for f in self.files]}).encode()
        raise ci_receipt.Rejected(f"GitHub answered 404 for {path}")


def verify(fake: FakeGitHub, *, job: str = "fast-gates", body: str | None = None, base: str = BASE,
           merge_tree: str = MERGE_TREE, audit_percent: int = 0, workspaces: Path | None = None,
           pr: int | None = None) -> dict:
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as handle:
        handle.write(body if body is not None else
                     f"Change.\n\nCI-Receipt: {job} https://github.com/{REPO}/actions/runs/{RUN}\n")
    args = SimpleNamespace(job=job, repo=REPO, head=HEAD, base=base, head_tree=HEAD_TREE, merge_tree=merge_tree,
                           body_file=handle.name, audit_percent=audit_percent, workspaces=workspaces, pr=pr)
    try:
        return ci_receipt.verify(args, fetch=fake)
    finally:
        Path(handle.name).unlink()


class Verify(unittest.TestCase):
    def assertRejected(self, result: dict, fragment: str) -> None:
        self.assertEqual(result["valid"], "false", result)
        self.assertIn(fragment, result["reason"])

    def test_a_real_receipt_on_the_same_base_counts(self):
        result = verify(FakeGitHub())
        self.assertEqual(result["valid"], "true", result["reason"])
        self.assertEqual(result["base"], BASE)
        self.assertEqual(result["producer"], "teamleaderleo")
        self.assertTrue(result["run_url"].endswith(RUN))
        self.assertEqual(result["audit"], "false")

    def test_no_pointer_reads_nothing(self):
        fake = FakeGitHub()
        result = verify(fake, body="No receipt here. CI-Receipt: rust-workspaces 123")
        self.assertRejected(result, "no CI-Receipt: fast-gates line")
        self.assertEqual(fake.calls, [])

    def test_discovery_finds_the_run_with_no_pointer(self):
        # A lane ran the canonical command with `cmux-ci test` and wrote no CI-Receipt line.
        fake = FakeGitHub()
        result = verify(fake, body="No pointer.", pr=7)
        self.assertEqual(result["valid"], "true", result["reason"])
        self.assertTrue(result["run_url"].endswith(RUN))

    def test_discovery_reads_a_run_of_an_earlier_commit_of_the_same_tree(self):
        # The run tested the PR's first commit; the head is a later commit (same tree: check_run holds the tree).
        earlier = "9" * 40
        title = f"Fast checks {SOURCE} tests {REPO}@{earlier}"
        fake = FakeGitHub(log=log_text(head=earlier), run=run_record(display_title=title))
        fake.pr_commits = [earlier, HEAD]
        fake.listed = [run_record(display_title=title)]
        result = verify(fake, body="", pr=7)
        self.assertEqual(result["valid"], "true", result["reason"])

    def test_discovery_still_holds_the_run_to_every_check(self):
        for fake, fragment in (
            (FakeGitHub(log=log_text(command="echo ok")), "not fast-gates's canonical"),
            (FakeGitHub(log=log_text(source_tree="1" * 40)), "FAST_CHECKS_RECEIPT"),
            (FakeGitHub(log=log_text(tree="2" * 40)), "merge tree"),
            (FakeGitHub(run=run_record(head_branch="other")), "dispatch on main"),
        ):
            with self.subTest(fragment=fragment):
                self.assertRejected(verify(fake, body="", pr=7), fragment)

    def test_discovery_ignores_runs_that_test_no_commit_of_the_pull_request(self):
        fake = FakeGitHub()
        fake.listed = [run_record(display_title=f"Fast checks {SOURCE} tests {REPO}@{'8' * 40}"),
                       run_record(display_title=f"Fast checks {SOURCE} tests other/repo@{HEAD}"),
                       run_record(display_title="Fast checks " + SOURCE)]
        self.assertRejected(verify(fake, body="", pr=7), "no passing Fast checks run")

    def test_discovery_reads_only_the_runs_since_the_oldest_commit(self):
        # On 2026-11-21 main held about 1,240 passing receipt dispatches from two days, so every search read all five
        # pages (about 240 GITHUB_TOKEN calls an hour from this job alone). A run cannot test a commit made after it
        # started, so the search starts at the pull request's oldest commit (less a margin for clock skew).
        import datetime
        older = "7" * 40
        fake = FakeGitHub()
        fake.pr_commits = [older, HEAD]
        fake.commit_dates = {older: "2026-11-21T23:40:00Z", HEAD: "2026-11-22T00:10:00Z"}
        fake.listed = [run_record(display_title=f"Fast checks {SOURCE} tests {REPO}@{'8' * 40}")] * 99 + [run_record()]
        found = ci_receipt.discover(fake, REPO, 7, HEAD, now=datetime.datetime(2026, 11, 22, 1, 0, tzinfo=datetime.timezone.utc))
        self.assertEqual(found, [RUN])
        (listing,) = [c for c in fake.calls if "workflows/fast-checks.yml/runs" in c][:1]
        self.assertIn("created=%3E%3D2026-11-21T23:10:00Z", listing)
        self.assertNotIn("created=%3E%3D2026-11-20", listing)

    def test_discovery_without_commit_dates_keeps_the_two_day_window(self):
        import datetime
        fake = FakeGitHub()
        fake.commit_dates = {HEAD: "not a date"}
        ci_receipt.discover(fake, REPO, 7, HEAD, now=datetime.datetime(2026, 11, 22, 1, 0, tzinfo=datetime.timezone.utc))
        listing = [c for c in fake.calls if "workflows/fast-checks.yml/runs" in c][0]
        self.assertIn("created=%3E%3D2026-11-20", listing)

    def test_a_pointer_beats_discovery(self):
        fake = FakeGitHub()
        self.assertEqual(verify(fake, pr=7)["valid"], "true")
        self.assertFalse([c for c in fake.calls if "workflows/fast-checks.yml/runs" in c])

    def test_discovery_search_failure_runs_everything(self):
        class Down(FakeGitHub):
            def __call__(self, path):
                if "workflows/fast-checks.yml/runs" in path:
                    raise ci_receipt.Rejected("GitHub answered 502")
                return super().__call__(path)
        self.assertRejected(verify(Down(), body="", pr=7), "the search for a run failed")

    def test_forged_receipt_from_an_echo_command(self):
        # The receipt lines are printed by a command that is not the canonical one.
        forged = log_text(command="echo 'CMUX_CI_RECEIPT={...}'")
        self.assertRejected(verify(FakeGitHub(log=forged)), "not fast-gates's canonical")

    def test_command_output_cannot_fake_the_env_header(self):
        fake_header = "##[group]Run umask 022\nenv:\n  FAST_CHECKS_COMMAND: python3 scripts/ci/ci_receipt.py produce fast-gates\n##[endgroup]"
        forged = log_text(command="bash -c 'printf ...'", extra_output=fake_header)
        # The command's own output comes after the real header; a second step header is refused outright.
        self.assertRejected(verify(FakeGitHub(log=forged)), "2 'Run fast checks' steps")

    def test_forged_run_from_another_workflow_branch_or_repo(self):
        for overrides, fragment in (
            ({"path": ".github/workflows/evil.yml"}, "not .github/workflows/fast-checks.yml"),
            ({"head_branch": "lane/evil"}, "a receipt is a dispatch on main"),
            ({"event": "push"}, "a receipt is a dispatch on main"),
            ({"head_repository": {"full_name": "someone/cmux"}}, "is not a run of"),
            ({"conclusion": "failure"}, "not a pass"),
        ):
            with self.subTest(overrides=overrides):
                self.assertRejected(verify(FakeGitHub(run=run_record(**overrides))), fragment)

    def test_a_run_that_names_no_tested_commit(self):
        for title in (f"Fast checks {SOURCE}", f"Fast checks {SOURCE} tests someone/cmux@{HEAD}"):
            with self.subTest(title=title):
                self.assertRejected(verify(FakeGitHub(run=run_record(display_title=title))), "names no tested commit")

    def test_a_receipt_is_keyed_on_the_tree(self):
        # Another commit with this head's tree (an empty commit pushed after the body named the receipt) keeps it.
        other = "9" * 40
        run = run_record(display_title=f"Fast checks {SOURCE} tests {REPO}@{other}")
        self.assertEqual(verify(FakeGitHub(run=run, log=log_text(head=other)))["valid"], "true")
        # The receipt line must name the commit the run tested.
        self.assertRejected(verify(FakeGitHub(run=run)), "not the commit it tested")
        # A run on another tree never counts, whatever commit it names.
        self.assertRejected(verify(FakeGitHub(run=run, log=log_text(head=other, source_tree="1" * 40))),
                            "this head's tree")

    def test_the_source_must_be_the_one_checked_out(self):
        forged = log_text().replace(f"FAST_CHECKS_SOURCE: {SOURCE}", f"FAST_CHECKS_SOURCE: {'2' * 40}")
        self.assertRejected(verify(FakeGitHub(log=forged)), "FAST_CHECKS_RECEIPT is not a pass")

    def test_wrong_tree(self):
        self.assertRejected(verify(FakeGitHub(log=log_text(tree="1" * 40))), "not this run's")
        self.assertRejected(verify(FakeGitHub(log=log_text(source_tree="1" * 40))), "this head's tree")

    def test_wrong_command_arguments(self):
        for command in ("python3 scripts/ci/ci_receipt.py produce fast-gates --remote fork",
                        "python3 scripts/ci/ci_receipt.py produce rust-workspaces",
                        "python3 scripts/ci/cmux_next_fast_gates.py run --base HEAD"):
            with self.subTest(command=command):
                self.assertRejected(verify(FakeGitHub(log=log_text(command=command))), "canonical")
        self.assertRejected(verify(FakeGitHub(log=log_text(directory="cmux-tui"))), "not the checkout's root")

    def test_the_command_is_compared_character_for_character(self):
        quoted = log_text(command="python3 'scripts/ci/ci_receipt.py' produce \"fast-gates\"")
        self.assertRejected(verify(FakeGitHub(log=quoted)), "canonical")

    def test_a_second_command_line_is_refused(self):
        # bash -c runs every line: a canonical first line and an echo of a made-up receipt after it.
        fake = 'echo \'CMUX_CI_RECEIPT={"job": "fast-gates"}\''
        for command, fragment in (
            (CANONICAL + "\n" + fake, "not KEY: value"),
            # A second line shaped as a header line, which a shell also runs (`X:` fails, then the echo).
            (CANONICAL + "\n  X: ; " + fake, "once each"),
            (CANONICAL + "\n  FAST_CHECKS_COMMAND: " + CANONICAL, "once each"),
            (CANONICAL + "\n  FAST_CHECKS_DIRECTORY: ; " + fake, "once each"),
            (CANONICAL + "\r" + fake, "not KEY: value"),
        ):
            with self.subTest(command=command):
                self.assertRejected(verify(FakeGitHub(log=log_text(command=command))), fragment)

    def test_a_log_without_the_step_or_with_two(self):
        self.assertRejected(verify(FakeGitHub(log="nothing here\n")), "0 'Run fast checks' steps")
        twice = log_text().replace("##[group]Run actions/checkout@v6", "##[group]Run umask 022")
        self.assertRejected(verify(FakeGitHub(log=twice)), "2 'Run fast checks' steps")

    def test_receipt_replayed_from_another_job(self):
        # A rust-workspaces receipt named on the fast-gates line.
        rust = log_text(command="python3 scripts/ci/ci_receipt.py produce rust-workspaces", job="rust-workspaces")
        self.assertRejected(verify(FakeGitHub(log=rust)), "canonical")
        # The canonical fast-gates command whose receipt line claims another job.
        self.assertRejected(verify(FakeGitHub(log=log_text(job="rust-workspaces"))), "not fast-gates")
        # A fast-gates receipt named on the rust-workspaces line.
        self.assertRejected(verify(FakeGitHub(), job="rust-workspaces",
                                   body=f"CI-Receipt: rust-workspaces {RUN}"), "canonical")

    def test_failed_command_or_moved_head(self):
        self.assertRejected(verify(FakeGitHub(log=log_text(exit_code=1))), "FAST_CHECKS_RECEIPT is not a pass")
        self.assertRejected(verify(FakeGitHub(jobs=[{"id": JOB_ID, "name": "checks", "conclusion": "failure"}])),
                            "no passing 'checks' job")

    def test_older_base_counts_for_fast_gates_when_it_is_an_ancestor(self):
        result = verify(FakeGitHub(log=log_text(base=OLD_BASE, tree="1" * 40)))
        self.assertEqual(result["valid"], "true", result["reason"])
        self.assertEqual(result["base"], OLD_BASE)
        self.assertRejected(verify(FakeGitHub(log=log_text(base=OLD_BASE), compare="diverged")), "not an ancestor")

    def test_rust_workspaces_on_an_older_base_only_when_no_rust_input_changed_since(self):
        rust = log_text(command="python3 scripts/ci/ci_receipt.py produce rust-workspaces", job="rust-workspaces",
                        base=OLD_BASE, tree="1" * 40)
        body = f"CI-Receipt: rust-workspaces {RUN}"
        listing = ROOT / ".github/rust-workspaces.toml"

        def run(files, workspaces=listing, compare="ahead"):
            return verify(FakeGitHub(log=rust, files=files, compare=compare), job="rust-workspaces", body=body,
                          workspaces=workspaces)

        self.assertEqual(run(["webviews/src/App.tsx", "docs/x.md"])["valid"], "true")
        self.assertEqual(run(["webviews/src/App.tsx"])["base"], OLD_BASE)
        for changed in ("cmux-tui/crates/acpmux/src/lib.rs", "webviews/native/build.rs", "Cargo.lock",
                        "Native/DiffSidecar/README.md", "ghostty-next", ".github/rust-workspaces.toml",
                        "cmux-tui/rust-toolchain.toml", ".github/actions/setup-cmux-tui-rust/action.yml"):
            with self.subTest(changed=changed):
                self.assertRejected(run(["docs/x.md", changed]), "changed Rust inputs")
        self.assertRejected(run([f"docs/{n}.md" for n in range(300)]), "too many to clear")
        self.assertRejected(run(["docs/x.md"], workspaces=None), "workspace list is not here")
        self.assertRejected(run(["docs/x.md"], compare="diverged"), "not an ancestor")
        same = log_text(command="python3 scripts/ci/ci_receipt.py produce rust-workspaces", job="rust-workspaces")
        self.assertEqual(verify(FakeGitHub(log=same), job="rust-workspaces",
                                body=f"CI-Receipt: rust-workspaces {RUN}")["valid"], "true")

    def test_pointer_to_another_repository_is_ignored(self):
        fake = FakeGitHub()
        result = verify(fake, body=f"CI-Receipt: fast-gates https://github.com/someone/cmux/actions/runs/{RUN}")
        self.assertRejected(result, "no CI-Receipt")
        self.assertEqual(fake.calls, [])

    def test_api_failure_runs_everything(self):
        result = verify(FakeGitHub(), body="CI-Receipt: fast-gates 123")
        self.assertRejected(result, "404")

    def test_audit_is_a_seeded_sample(self):
        self.assertEqual(verify(FakeGitHub(), audit_percent=100)["audit"], "true")
        # Seeded by the receipt run and the head: a new CI run on the same head cannot re-roll it.
        self.assertEqual(verify(FakeGitHub(), audit_percent=50)["audit"], verify(FakeGitHub(), audit_percent=50)["audit"])
        self.assertEqual(verify(FakeGitHub(), audit_percent=0)["audit"], "false")
        picked = sum(ci_receipt.audited(str(seed), HEAD, 10) for seed in range(2000))
        self.assertTrue(120 < picked < 280, picked)
        self.assertEqual(ci_receipt.audited("42", HEAD, 10), ci_receipt.audited("42", HEAD, 10))


class Produce(unittest.TestCase):
    def repo(self, scratch: str) -> tuple[Path, "Callable[..., str]"]:
        repo = Path(scratch) / "repo"
        repo.mkdir()

        def git(*args: str) -> str:
            return subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", *args],
                                  check=True, capture_output=True, text=True, env=git_fixture_env.fixture_env()).stdout.strip()

        git("init", "-q", "-b", ci_receipt.BRANCH)
        (repo / "a").write_text("1")
        git("add", "a")
        git("commit", "-qm", "base")
        return repo, git

    def run_produce(self, repo: Path, runner) -> tuple[int, str]:
        """produce fast-gates in REPO with its own clone as origin, the gates replaced by RUNNER (really executed)."""
        import contextlib  # noqa: PLC0415
        import io  # noqa: PLC0415
        import os  # noqa: PLC0415

        out = io.StringIO()
        saved_cwd, saved = Path.cwd(), ci_receipt.produce_fast_gates
        ci_receipt.produce_fast_gates = runner
        try:
            os.chdir(repo)
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                code = ci_receipt.produce(SimpleNamespace(job="fast-gates", remote=str(repo)))
        finally:
            os.chdir(saved_cwd)
            ci_receipt.produce_fast_gates = saved
        return code, out.getvalue()

    def test_a_failed_execution_mints_no_receipt(self):
        # A real command that runs and fails in the merge worktree, not an argv mismatch refused before it runs.
        with tempfile.TemporaryDirectory() as scratch:
            repo, _ = self.repo(scratch)
            ran = []

            def failing(work: Path, head: str, base: str) -> int:
                ran.append(work)
                return subprocess.run([sys.executable, "-c", "import sys; sys.exit(3)"], cwd=work).returncode

            code, out = self.run_produce(repo, failing)
            self.assertEqual(code, 3)
            self.assertEqual(len(ran), 1, "the gate command was never executed")
            self.assertNotIn("CMUX_CI_RECEIPT=", out)

            def passing(work: Path, head: str, base: str) -> int:
                return subprocess.run([sys.executable, "-c", "pass"], cwd=work).returncode

            code, out = self.run_produce(repo, passing)
            self.assertEqual(code, 0)
            receipt = json.loads(next(line for line in out.splitlines() if line.startswith("CMUX_CI_RECEIPT="))
                                 .split("=", 1)[1])
            self.assertEqual(receipt["job"], "fast-gates")

    def test_a_dirty_tracked_tree_mints_no_receipt(self):
        with tempfile.TemporaryDirectory() as scratch:
            repo, _ = self.repo(scratch)
            (repo / "a").write_text("edited, not committed")
            code, out = self.run_produce(repo, lambda work, head, base: 0)
            self.assertEqual(code, 2)
            self.assertNotIn("CMUX_CI_RECEIPT=", out)

    def test_tested_head_is_the_snapshot_parent_with_the_same_tree(self):
        with tempfile.TemporaryDirectory() as scratch:
            repo = Path(scratch)

            def git(*args: str) -> str:
                return subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", *args],
                                      check=True, capture_output=True, text=True).stdout.strip()

            git("init", "-q")
            (repo / "a").write_text("1")
            git("add", "a")
            git("commit", "-qm", "head")
            head = git("rev-parse", "HEAD")
            git("commit", "-q", "--allow-empty", "-m", "snapshot")
            self.assertEqual(ci_receipt.tested_head(repo), head)
            (repo / "a").write_text("2")
            git("commit", "-qam", "edit")
            self.assertEqual(ci_receipt.tested_head(repo), git("rev-parse", "HEAD"))


class RustSummary(unittest.TestCase):
    """rust-workspaces.yml's summary step, really run: a receipt skip is never shown as a plain skip."""

    RUN_URL = "https://github.com/manaflow-ai/cmux/actions/runs/123"

    def run_step(self, **env: str) -> tuple[int, str, str]:
        import os  # noqa: PLC0415

        import yaml  # noqa: PLC0415

        workflow = yaml.safe_load((ROOT / ".github/workflows/rust-workspaces.yml").read_text())
        (step,) = [s for s in workflow["jobs"]["summary"]["steps"] if s.get("name") == "Every planned workspace passed"]
        with tempfile.TemporaryDirectory() as scratch:
            summary = Path(scratch) / "summary"
            summary.write_text("")
            full = {"PATH": os.environ["PATH"], "GITHUB_STEP_SUMMARY": str(summary), "RECEIPT_AUDIT": "false",
                    "RECEIPT_RUN": "", "RECEIPT_PRODUCER": "", **env}
            done = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", step["run"]], env=full,
                                  capture_output=True, text=True)
            return done.returncode, done.stdout, summary.read_text()

    def test_a_receipt_skip_says_verified_reuse_with_the_run_url(self):
        code, out, summary = self.run_step(PLAN="skipped", WORKSPACES="skipped", RECEIPT_VALID="true",
                                           RECEIPT_RUN=self.RUN_URL, RECEIPT_PRODUCER="octo")
        self.assertEqual(code, 0)
        self.assertIn(f"verified reuse of receipt {self.RUN_URL}", out)
        self.assertIn(f"::notice title=CI receipt::rust workspaces: verified reuse of receipt {self.RUN_URL}", out)
        self.assertIn(f"verified reuse of receipt {self.RUN_URL}", summary)

    def test_no_receipt_never_claims_reuse(self):
        for plan, workspaces in (("success", "success"), ("success", "skipped"), ("skipped", "skipped")):
            with self.subTest(plan=plan, workspaces=workspaces):
                _, out, summary = self.run_step(PLAN=plan, WORKSPACES=workspaces, RECEIPT_VALID="false",
                                                RECEIPT_RUN=self.RUN_URL)
                self.assertNotIn("verified reuse", out + summary)

    def test_an_audited_receipt_runs_the_verdict_not_the_reuse_line(self):
        _, out, summary = self.run_step(PLAN="success", WORKSPACES="failure", RECEIPT_VALID="true",
                                        RECEIPT_AUDIT="true", RECEIPT_RUN=self.RUN_URL, RECEIPT_PRODUCER="octo")
        self.assertNotIn("verified reuse", out + summary)
        self.assertIn("CI receipt audit", out)


def lane_receipt(**overrides) -> dict:
    receipt = {"schema": "ci-receipt/v1", "check": "fast-gates", "repo": REPO, "head": HEAD, "head_tree": HEAD_TREE,
               "base": BASE, "tree": MERGE_TREE, "tree_kind": "lane-merge", "producer": "lane:fs-agent-lane-9",
               "command_sha256": __import__("hashlib").sha256(CANONICAL.encode()).hexdigest(), "exit": 0,
               "sig": "c2ln", "shadow": False}
    receipt.update(overrides)
    return receipt


def lane_verify(receipts, *, fake: FakeGitHub | None = None, base: str = BASE, audit_percent: int = 0,
                body: str = "Change.\n", pr: int | None = None,
                merge_tree: str = MERGE_TREE) -> tuple[dict, list[dict]]:
    asked: list[dict] = []

    def ask(payload):
        asked.append(payload)
        if isinstance(receipts, Exception):
            raise receipts
        return {"receipts": receipts}
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as handle:
        handle.write(body)
    args = SimpleNamespace(job="fast-gates", repo=REPO, head=HEAD, base=base, head_tree=HEAD_TREE,
                           merge_tree=merge_tree, body_file=handle.name, audit_percent=audit_percent, workspaces=None,
                           pr=pr, lane=True)
    try:
        return ci_receipt.verify(args, fetch=fake or FakeGitHub(), lane_ask_fn=ask), asked
    finally:
        Path(handle.name).unlink()


class LaneReceipts(unittest.TestCase):
    """A lane's own pass, signed by the controller and asked for by head tree (Leo, 2026-11-25: "what other
    fundamental cuts can we make? let's do them")."""

    def test_a_lane_receipt_on_the_same_base_counts_with_no_pointer(self):
        result, asked = lane_verify([lane_receipt()])
        self.assertEqual(result["valid"], "true", result["reason"])
        self.assertEqual(result["producer"], "lane:fs-agent-lane-9")
        self.assertEqual(result["base"], BASE)
        self.assertEqual(asked, [{"op": "lookup", "check": "fast-gates", "head_tree": HEAD_TREE}])

    def test_same_base_needs_the_same_merge_tree(self):
        result, _ = lane_verify([lane_receipt(tree="9" * 40)])
        self.assertEqual(result["valid"], "false")
        self.assertIn("not this run's", result["reason"])

    def test_an_older_base_counts_only_as_an_ancestor(self):
        self.assertEqual(lane_verify([lane_receipt(base=OLD_BASE)])[0]["valid"], "true")
        result, _ = lane_verify([lane_receipt(base=OLD_BASE)], fake=FakeGitHub(compare="diverged"))
        self.assertEqual(result["valid"], "false")
        self.assertIn("not an ancestor", result["reason"])

    def test_another_command_repo_tree_or_producer_is_refused(self):
        for bad in ({"command_sha256": "0" * 64}, {"repo": "x/y"}, {"head_tree": "1" * 40},
                    {"producer": "actions:x"}, {"check": "rust-workspaces"}, {"base": "short"}):
            result, _ = lane_verify([lane_receipt(**bad)])
            self.assertEqual(result["valid"], "false", bad)

    def test_a_dispatch_with_no_merge_tree_takes_a_receipt_on_an_older_base(self):
        # The merger's land-time dispatch (78 of 100 fast-gates runs, 2026-11-26) has no merge ref to read a tree from.
        result, _ = lane_verify([lane_receipt(base=OLD_BASE)], merge_tree="")
        self.assertEqual(result["valid"], "true", result["reason"])
        self.assertEqual(result["producer"], "lane:fs-agent-lane-9")

    def test_a_dispatch_on_the_receipts_own_base_takes_it_only_for_the_same_head_commit(self):
        # Lanes test on the newest base, so most land dispatches share the receipt's base: the same head commit on the
        # same base is the merge the lane tested; another commit with the same tree may merge differently.
        result, _ = lane_verify([lane_receipt()], merge_tree="")
        self.assertEqual(result["valid"], "true", result["reason"])
        result, _ = lane_verify([lane_receipt(head="9" * 40)], merge_tree="")
        self.assertEqual(result["valid"], "false")
        self.assertIn("no merge tree", result["reason"])

    def test_a_malformed_merge_tree_is_still_refused(self):
        result, _ = lane_verify([lane_receipt(base=OLD_BASE)], merge_tree="nope")
        self.assertEqual(result["valid"], "false")
        self.assertIn("unresolved", result["reason"])

    def test_the_first_covering_receipt_wins(self):
        result, _ = lane_verify([lane_receipt(tree="9" * 40, producer="lane:a"), lane_receipt(producer="lane:b")])
        self.assertEqual((result["valid"], result["producer"]), ("true", "lane:b"))

    def test_a_producer_in_shadow_is_always_audited(self):
        result, _ = lane_verify([lane_receipt(shadow=True)])
        self.assertEqual((result["valid"], result["audit"]), ("true", "true"))
        self.assertIn("shadow", result["reason"])

    def test_audit_samples_lane_receipts_too(self):
        self.assertEqual(lane_verify([lane_receipt()], audit_percent=100)[0]["audit"], "true")
        self.assertEqual(lane_verify([lane_receipt()], audit_percent=0)[0]["audit"], "false")

    def test_no_lane_receipt_or_a_down_controller_runs_the_gates(self):
        result, _ = lane_verify([])
        self.assertEqual(result["valid"], "false")
        self.assertIn("no lane receipt", result["reason"])
        result, _ = lane_verify(ci_receipt.Rejected("the controller did not answer: timeout"))
        self.assertEqual(result["valid"], "false")
        self.assertIn("did not answer", result["reason"])

    def test_without_a_lane_receipt_discovery_still_runs(self):
        result, _ = lane_verify([], pr=5)
        self.assertEqual(result["valid"], "true", result["reason"])  # FakeGitHub's run is a real receipt
        self.assertFalse(result["producer"].startswith("lane:"))


class LaneRecord(unittest.TestCase):
    def test_records_on_a_lane_and_never_inside_actions(self):
        args = SimpleNamespace(job="fast-gates", record=True)
        self.assertTrue(ci_receipt.lane_records(args, env={}))
        self.assertFalse(ci_receipt.lane_records(args, env={"GITHUB_ACTIONS": "true"}))
        self.assertFalse(ci_receipt.lane_records(SimpleNamespace(job="fast-gates", record=False), env={}))
        self.assertFalse(ci_receipt.lane_records(SimpleNamespace(job="rust-workspaces", record=True), env={}))

    def test_record_posts_the_pass_and_a_refusal_is_exit_zero(self):
        import json as j  # noqa: PLC0415
        sent = []

        def post(url, data):
            sent.append((url, j.loads(data)))
            return 200, j.dumps({"recorded": True, "receipt": {"producer": "lane:x"}}).encode()
        code = ci_receipt.record_lane("fast-gates", head=HEAD, head_tree=HEAD_TREE, base=BASE, merge_tree=MERGE_TREE,
                                      seconds=12.0, post=post, env={"CMUX_CI_CONTROLLER": "http://c:1/"})
        self.assertEqual(code, 0)
        url, body = sent[0]
        self.assertEqual(url, "http://c:1/v1/ci/lane-receipt")
        self.assertEqual((body["command"], body["exit"], body["head_tree"], body["merge_tree"]),
                         (CANONICAL, 0, HEAD_TREE, MERGE_TREE))
        self.assertNotIn("producer", body)  # the controller names it from the tailnet
        self.assertEqual(ci_receipt.record_lane("fast-gates", head=HEAD, head_tree=HEAD_TREE, base=BASE,
                                                merge_tree=MERGE_TREE, seconds=1, post=lambda u, d: (403, b"no"),
                                                env={}), 0)

    def test_a_record_with_no_answer_is_spooled_and_flushed_until_recorded(self):
        """2026-11-27 08:16Z-08:40Z: 7 green lane passes ran past the controller's deadline and were thrown away."""
        import json as j  # noqa: PLC0415
        with tempfile.TemporaryDirectory() as folder:
            env = {"CI_RECEIPT_SPOOL": folder}
            spawned = []

            def down(u, d):
                raise OSError("unreachable")
            self.assertEqual(ci_receipt.record_lane("fast-gates", head=HEAD, head_tree=HEAD_TREE, base=BASE,
                                                    merge_tree=MERGE_TREE, seconds=1, post=down, env=env,
                                                    spawn=lambda: spawned.append(1)), 0)
            self.assertEqual(spawned, [1])
            entries = list(Path(folder).glob("*.json"))
            self.assertEqual(len(entries), 1)
            self.assertEqual(j.loads(entries[0].read_text())["payload"]["head_tree"], HEAD_TREE)
            # a 5xx keeps it; the next round records it and empties the spool
            answers = [(503, b"busy"), (200, j.dumps({"receipt": {"producer": "lane:x"}}).encode())]
            sleeps = []
            self.assertEqual(ci_receipt.flush(env=env, post=lambda u, d: answers.pop(0), sleep=sleeps.append), 0)
            self.assertEqual((answers, sleeps, list(Path(folder).glob("*.json"))), ([], [ci_receipt.RETRY_EVERY_S], []))

    def test_a_refusal_is_not_spooled_and_an_expired_entry_is_dropped(self):
        with tempfile.TemporaryDirectory() as folder:
            env = {"CI_RECEIPT_SPOOL": folder}
            spawned = []
            ci_receipt.record_lane("fast-gates", head=HEAD, head_tree=HEAD_TREE, base=BASE, merge_tree=MERGE_TREE,
                                   seconds=1, post=lambda u, d: (403, b"no"), env=env, spawn=lambda: spawned.append(1))
            self.assertEqual((spawned, list(Path(folder).glob("*.json"))), ([], []))
            ci_receipt.record_lane("fast-gates", head=HEAD, head_tree=HEAD_TREE, base=BASE, merge_tree=MERGE_TREE,
                                   seconds=1, post=lambda u, d: (502, b""), env=env, spawn=lambda: None)
            later = time.time() + ci_receipt.SPOOL_FOR_S + 1
            self.assertEqual(ci_receipt.flush(env=env, post=lambda u, d: (502, b""), sleep=lambda s: None,
                                              now=lambda: later), 0)
            self.assertEqual(list(Path(folder).glob("*.json")), [])



class GitCompareTest(unittest.TestCase):
    """base_covers reads OLDER...BASE with git, so a REST budget spent elsewhere does not drop a receipt."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.repo = Path(self.dir.name) / "src"
        self.repo.mkdir()
        run = lambda *argv: subprocess.run(["git", "-C", str(self.repo), *argv], check=True, capture_output=True,
                                           text=True).stdout.strip()
        self.run = run
        run("init", "-q", "-b", "main")
        run("config", "user.email", "t@example.com")
        run("config", "user.name", "t")
        run("config", "uploadpack.allowFilter", "true")
        run("config", "uploadpack.allowAnySHA1InWant", "true")
        (self.repo / "a.txt").write_text("a\n")
        run("add", ".")
        run("commit", "-qm", "one")
        self.older = run("rev-parse", "HEAD")
        (self.repo / "crates").mkdir()
        (self.repo / "crates" / "lib.rs").write_text("fn x() {}\n")
        run("add", ".")
        run("commit", "-qm", "two")
        self.base = run("rev-parse", "HEAD")
        self.token = {"GH_TOKEN": "t"}

    def tearDown(self):
        self.dir.cleanup()

    def compare(self, older, base, files=False):
        from unittest import mock
        with mock.patch.dict("os.environ", self.token):
            return ci_receipt._git_compare(REPO, older, base, files=files, remote=f"file://{self.repo}")

    def test_an_ancestor_is_ahead_without_rest(self):
        self.assertEqual(self.compare(self.older, self.base), {"status": "ahead", "files": []})

    def test_files_come_from_the_trees(self):
        self.assertEqual(self.compare(self.older, self.base, files=True),
                         {"status": "ahead", "files": [{"filename": "crates/lib.rs"}]})

    def test_off_history_falls_back_to_rest(self):
        self.run("checkout", "-q", "-b", "side", self.older)
        (self.repo / "b.txt").write_text("b\n")
        self.run("add", ".")
        self.run("commit", "-qm", "side")
        side = self.run("rev-parse", "HEAD")
        self.assertIsNone(self.compare(side, self.base))

    def test_no_token_falls_back_to_rest(self):
        self.token = {"GH_TOKEN": ""}
        self.assertIsNone(self.compare(self.older, self.base))

    def test_base_covers_takes_the_git_answer(self):
        def no_rest(path):
            raise ci_receipt.Rejected(f"GitHub answered 403 for {path}")
        saved = ci_receipt.git_compare
        ci_receipt.git_compare = lambda *args, **kwargs: {"status": "ahead", "files": []}
        try:
            ci_receipt.base_covers(no_rest, repo=REPO, job="fast-gates", where="w", receipt_base=self.older,
                                   receipt_tree="0" * 40, base=self.base, merge_tree="", rust_roots=None)
        finally:
            ci_receipt.git_compare = saved


class LaneAskDeadlineTest(unittest.TestCase):
    def test_lookup_waits_as_long_as_a_record(self):
        seen = []
        original = ci_receipt.deadline_http.request
        ci_receipt.deadline_http.request = lambda request, deadline: (seen.append(deadline), (200, b"{}", {}))[1]
        try:
            ci_receipt.lane_ask({"tree": "t"}, "token", "https://example.invalid/lane-receipt")
        finally:
            ci_receipt.deadline_http.request = original
        self.assertEqual(len(seen), 1)
        self.assertAlmostEqual(seen[0], ci_receipt.LOOKUP_DEADLINE_S, delta=1)
        self.assertGreaterEqual(ci_receipt.LOOKUP_DEADLINE_S, ci_receipt.RECORD_DEADLINE_S)

    def _ask(self, answers):
        now = [0.0]
        slept = []
        def sleep(seconds):
            slept.append(seconds)
            now[0] += seconds
        original = ci_receipt.deadline_http.request
        ci_receipt.deadline_http.request = lambda request, deadline: answers.pop(0)
        try:
            return ci_receipt.lane_ask({"tree": "t"}, "token", "https://example.invalid/lane-receipt",
                                       clock=lambda: now[0], sleep=sleep), slept
        finally:
            ci_receipt.deadline_http.request = original

    def test_a_starting_controller_is_asked_again(self):
        starting = (503, b'{"error": "the controller is starting; retry"}', {})
        answer, slept = self._ask([starting, starting, (200, b'{"receipt": null}', {})])
        self.assertEqual(answer, {"receipt": None})
        self.assertEqual(len(slept), 2)

    def test_a_controller_down_past_the_deadline_is_no_receipt(self):
        starting = (503, b'{"error": "the controller is starting; retry"}', {})
        with self.assertRaisesRegex(ci_receipt.Rejected, "503"):
            self._ask([starting] * 100)

    def test_a_refusal_is_not_asked_again(self):
        with self.assertRaisesRegex(ci_receipt.Rejected, "403"):
            self._ask([(403, b'{"error": "no"}', {}), (200, b"{}", {})])



if __name__ == "__main__":
    unittest.main()
