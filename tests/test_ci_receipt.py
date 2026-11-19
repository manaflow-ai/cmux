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
import unittest
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import ci_receipt  # noqa: E402

REPO = "manaflow-ai/cmux"
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
    lines = [
        "##[group]Run actions/checkout@v6", "with:", "##[endgroup]",
        "##[group]Run umask 022", "umask 022", "command_text = os.environ['FAST_CHECKS_COMMAND']",
        "shell: /usr/bin/bash -e {0}", "env:", "  CARGO_HOME: /home/runner/.cache/fast-checks/cargo",
        f"  FAST_CHECKS_COMMAND: {command}", f"  FAST_CHECKS_DIRECTORY: {directory}", "  FAST_CHECKS_TIMEOUT: 3600",
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


class FakeGitHub:
    def __init__(self, *, run: dict | None = None, log: str | None = None, compare: str = "ahead",
                 jobs: list | None = None):
        self.run = run or run_record()
        self.log = log if log is not None else log_text()
        self.compare = compare
        self.jobs = jobs if jobs is not None else [{"id": JOB_ID, "name": "checks", "conclusion": "success"}]
        self.calls: list[str] = []

    def __call__(self, path: str) -> bytes:
        self.calls.append(path)
        if path == f"repos/{REPO}/actions/runs/{RUN}":
            return json.dumps(self.run).encode()
        if path.startswith(f"repos/{REPO}/actions/runs/{RUN}/jobs"):
            return json.dumps({"jobs": self.jobs}).encode()
        if path == f"repos/{REPO}/actions/jobs/{JOB_ID}/logs":
            return self.log.encode()
        if path.startswith(f"repos/{REPO}/compare/"):
            return json.dumps({"status": self.compare}).encode()
        raise ci_receipt.Rejected(f"GitHub answered 404 for {path}")


def verify(fake: FakeGitHub, *, job: str = "fast-gates", body: str | None = None, base: str = BASE,
           merge_tree: str = MERGE_TREE, audit_percent: int = 0, seed: str = "1") -> dict:
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as handle:
        handle.write(body if body is not None else
                     f"Change.\n\nCI-Receipt: {job} https://github.com/{REPO}/actions/runs/{RUN}\n")
    args = SimpleNamespace(job=job, repo=REPO, head=HEAD, base=base, head_tree=HEAD_TREE, merge_tree=merge_tree,
                           body_file=handle.name, seed=seed, audit_percent=audit_percent)
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

    def test_forged_receipt_from_an_echo_command(self):
        # The receipt lines are printed by a command that is not the canonical one.
        forged = log_text(command="echo 'CMUX_CI_RECEIPT={...}'")
        self.assertRejected(verify(FakeGitHub(log=forged)), "not fast-gates's canonical")

    def test_command_output_cannot_fake_the_env_header(self):
        fake_header = "##[group]Run umask 022\nenv:\n  FAST_CHECKS_COMMAND: python3 scripts/ci/ci_receipt.py produce fast-gates\n##[endgroup]"
        forged = log_text(command="bash -c 'printf ...'", extra_output=fake_header)
        self.assertRejected(verify(FakeGitHub(log=forged)), "not fast-gates's canonical")

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

    def test_a_run_of_another_head(self):
        other = run_record(display_title=f"Fast checks {SOURCE} tests {REPO}@{'9' * 40}")
        self.assertRejected(verify(FakeGitHub(run=other)), "not this head")

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

    def test_quoting_does_not_matter(self):
        quoted = log_text(command="python3 'scripts/ci/ci_receipt.py' produce \"fast-gates\"")
        self.assertEqual(verify(FakeGitHub(log=quoted))["valid"], "true")

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

    def test_rust_workspaces_needs_the_same_base(self):
        rust = log_text(command="python3 scripts/ci/ci_receipt.py produce rust-workspaces", job="rust-workspaces",
                        base=OLD_BASE)
        self.assertRejected(verify(FakeGitHub(log=rust), job="rust-workspaces",
                                   body=f"CI-Receipt: rust-workspaces {RUN}"), "needs the same base")
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
        self.assertEqual(verify(FakeGitHub(), audit_percent=0)["audit"], "false")
        picked = sum(ci_receipt.audited(str(seed), HEAD, 10) for seed in range(2000))
        self.assertTrue(120 < picked < 280, picked)
        self.assertEqual(ci_receipt.audited("42", HEAD, 10), ci_receipt.audited("42", HEAD, 10))


class Produce(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
