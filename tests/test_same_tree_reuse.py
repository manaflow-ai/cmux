#!/usr/bin/env python3
"""scripts/ci/same_tree_reuse.py: a job that passed on a tree is not run again on that tree, and only a job whose
pass is a function of the tree may reuse one.

- the key changes with the tree, the job and the workflow file's blob, and only those;
- a restored receipt counts only when it names this key and job; the sampled audit re-rolls per run attempt;
- every job of every pull-request workflow is wired or on the deny list with a reason (the coverage detector),
  and a wired job is pure and carries its lookup, skip, audit and record steps.
Run: python3 tests/test_same_tree_reuse.py
"""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import same_tree_reuse as s  # noqa: E402


def _load_git_fixture_env():
    """tests/git_fixture_env.py by path, so `python3 -I` (no script folder on sys.path) runs this file too."""
    spec = importlib.util.spec_from_file_location("git_fixture_env", Path(__file__).resolve().parent / "git_fixture_env.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # importing it disables git auto maintenance
    return module


git_fixture_env = _load_git_fixture_env()

TREE = "a" * 40
BLOB = "b" * 40


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd, check=True,
                          capture_output=True, text=True, env=git_fixture_env.fixture_env()).stdout.strip()


class Keys(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.repo = Path(self.dir.name)
        git_fixture_env.init_repo(self.repo)
        (self.repo / ".github" / "workflows").mkdir(parents=True)
        (self.repo / ".github" / "workflows" / "w.yml").write_text("on: pull_request\n")
        (self.repo / "src.txt").write_text("one\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "one")

    def tearDown(self):
        self.dir.cleanup()

    def key(self, rev="HEAD", job="test"):
        return s.keys(".github/workflows/w.yml", [job], rev, cwd=str(self.repo))[job]

    def test_same_tree_on_another_commit_keeps_the_key(self):
        first = self.key()
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "re-push, same tree")
        self.assertEqual(self.key(), first)

    def test_a_changed_file_changes_the_key(self):
        first = self.key()
        (self.repo / "src.txt").write_text("two\n")
        git(self.repo, "commit", "-qam", "two")
        self.assertNotEqual(self.key(), first)

    def test_a_changed_workflow_changes_the_key(self):
        first = self.key()
        (self.repo / ".github" / "workflows" / "w.yml").write_text("on: [pull_request]\n")
        git(self.repo, "commit", "-qam", "workflow")
        self.assertNotEqual(self.key(), first)
        self.assertNotEqual(s.KEY.match(self.key())["blob"], s.KEY.match(first)["blob"])

    def test_another_job_has_another_key(self):
        self.assertNotEqual(self.key(job="a"), self.key(job="b"))

    def test_key_shape(self):
        key = s.make_key("kit-tests", BLOB, TREE)
        self.assertEqual(s.KEY.match(key)["job"], "kit-tests")
        self.assertEqual(s.KEY.match(key)["tree"], TREE)
        with self.assertRaises(ValueError):
            s.make_key("kit tests", BLOB, TREE)


class Decide(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.receipts = Path(self.dir.name)
        self.key = s.make_key("kit-tests", BLOB, TREE)

    def tearDown(self):
        self.dir.cleanup()

    def write(self, **fields):
        (self.receipts / "kit-tests").mkdir(exist_ok=True)
        (self.receipts / "kit-tests" / "receipt.json").write_text(json.dumps(fields))

    def decide(self, hit=True, percent=0, attempt="1"):
        return s.decide({"kit-tests": self.key}, {"kit-tests": hit}, self.receipts, percent, "99", attempt)["kit-tests"]

    def test_miss_runs_and_records(self):
        d = self.decide(hit=False)
        self.assertEqual((d["reuse"], d["audit"], d["record"]), (False, False, True))

    def test_hit_with_its_receipt_is_reused_and_named(self):
        self.write(job="kit-tests", key=self.key, run_url="https://github.com/o/r/actions/runs/1")
        d = self.decide()
        self.assertEqual((d["reuse"], d["record"]), (True, False))
        self.assertEqual(d["receipt"], "https://github.com/o/r/actions/runs/1")

    def test_hit_without_a_matching_receipt_runs(self):
        self.write(job="other", key=self.key)
        self.assertFalse(self.decide()["reuse"])
        self.write(job="kit-tests", key=s.make_key("kit-tests", BLOB, "c" * 40))
        self.assertFalse(self.decide()["reuse"])
        (self.receipts / "kit-tests" / "receipt.json").write_text("not json")
        self.assertFalse(self.decide()["reuse"])

    def test_audit_runs_a_hit_in_full_and_names_the_receipt(self):
        self.write(job="kit-tests", key=self.key, run_url="u")
        d = self.decide(percent=100)
        self.assertEqual((d["reuse"], d["audit"], d["record"], d["receipt"]), (False, True, False, "u"))

    def test_audit_sample_is_near_its_percent_and_rerolls_per_attempt(self):
        picks = sum(s.audit_pick(self.key, str(run), "1", 10) for run in range(4000))
        self.assertTrue(300 < picks < 500, picks)
        rolls = {s.audit_pick(self.key, "7", str(attempt), 50) for attempt in range(1, 20)}
        self.assertEqual(rolls, {True, False})

    def test_cli_decide_prints_one_output_line(self):
        self.write(job="kit-tests", key=self.key, run_url="u")
        out = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/same_tree_reuse.py"), "decide",
                              "--keys", json.dumps({"kit-tests": self.key}), "--hits", "kit-tests=true",
                              "--receipts", str(self.receipts), "--audit-percent", "0"],
                             capture_output=True, text=True, check=True, env=git_fixture_env.fixture_env({"PATH": "/usr/bin:/bin"})).stdout
        self.assertTrue(out.startswith("same_tree="), out)
        self.assertTrue(json.loads(out.split("=", 1)[1])["kit-tests"]["reuse"])

    def test_cli_receipt_refuses_another_jobs_key(self):
        result = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/same_tree_reuse.py"), "receipt",
                                 "--job", "other", "--key", self.key, "--out", str(self.receipts / "x")],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)


WORKFLOW = {
    "on": {"pull_request": {}},
    "jobs": {
        "host": {"outputs": {"same_tree": "x"}, "steps": [{"id": "same-tree-keys"}, {"id": "same-tree-pure"},
                                                         {"id": "same-tree"}]},
        "pure": {"needs": "host", "if": "${{ !fromJSON(needs.host.outputs.same_tree || '{}')['pure'].reuse }}",
                 "steps": [{"uses": "actions/checkout@x"}, {"run": "make test"}] +
                          [{"name": n} for n in s.JOB_STEP_NAMES]},
        "body": {"needs": "host", "steps": [{"run": "echo ${{ github.event.pull_request.body }}"}]},
        "deploy-staging": {"steps": [{"run": "deploy"}]},
        "secret": {"steps": [{"run": "x", "env": {"T": "${{ secrets.TOKEN }}"}}]},
        "base": {"steps": [{"uses": "actions/checkout@x", "with": {"ref": "${{ github.event.pull_request.base.sha }}"}}]},
        "legs": {"strategy": {"matrix": {"a": ["1"]}}, "steps": []},
        "summary": {"needs": ["pure"], "if": "${{ always() }}", "steps": []},
    },
}


class Rules(unittest.TestCase):
    def test_each_impurity_blocks(self):
        jobs = WORKFLOW["jobs"]
        self.assertTrue(any("metadata" in b for b in s.blockers(WORKFLOW, "body")))
        # A label read in the job's own if: (run unless labeled) decides only whether it runs, not its verdict.
        labeled = {"on": {"pull_request": {}}, "jobs": {"j": {
            "if": "${{ contains(github.event.pull_request.labels.*.name, 'full-ci') }}", "steps": []}}}
        self.assertFalse(any("metadata" in b for b in s.blockers(labeled, "j")))
        self.assertTrue(any("live" in b for b in s.blockers(WORKFLOW, "deploy-staging")))
        self.assertTrue(any("secrets" in b for b in s.blockers(WORKFLOW, "secret")))
        self.assertTrue(any("checks out" in b for b in s.blockers(WORKFLOW, "base")))
        self.assertTrue(any("matrix" in b for b in s.blockers(WORKFLOW, "legs")))
        self.assertTrue(any("judges" in b for b in s.blockers(WORKFLOW, "summary")))
        self.assertTrue(any("needed by summary" in b for b in s.blockers(WORKFLOW, "pure")))
        self.assertIn("host", jobs)
        target = {"on": {"pull_request_target": {}}, "jobs": {"j": {"steps": []}}}
        self.assertTrue(any("pull_request_target" in b for b in s.blockers(target, "j")))

    def test_wiring_is_checked(self):
        self.assertEqual(s.wiring_errors("w.yml", WORKFLOW, "host", "pure"), [])
        broken = json.loads(json.dumps(WORKFLOW))
        broken["jobs"]["pure"]["if"] = ""
        broken["jobs"]["pure"]["steps"] = broken["jobs"]["pure"]["steps"][:-1]
        errors = s.wiring_errors("w.yml", broken, "host", "pure")
        self.assertTrue(any("must skip" in e for e in errors), errors)
        self.assertTrue(any("must end with" in e for e in errors), errors)


class Measure(unittest.TestCase):
    def test_a_second_run_on_a_green_tree_counts_once(self):
        import same_tree_reuse_measure as m

        def job(run, conclusion, seconds, created, tree=TREE, sha="1" * 40, attempt=1, i=0):
            return {"run": run, "job": "test", "id": run * 10 + i, "attempt": attempt, "conclusion": conclusion,
                    "seconds": seconds, "path": "w.yml", "tree": tree, "sha": sha, "created": created}
        jobs = [job(1, "failure", 60, 1), job(2, "success", 60, 2), job(3, "success", 120, 3, sha="2" * 40),
                job(4, "success", 60, 4, tree="c" * 40), job(5, "skipped", 0, 5)]
        out = m.analyse(jobs, lambda j: (j["path"], j["job"], j["tree"]))
        self.assertEqual((out["job_runs"], out["dup_job_runs"], out["dup_minutes"]), (4, 1, 2))


class Repository(unittest.TestCase):
    """The detector: this repository's every pull-request job is wired or denied with a reason."""

    def test_every_pull_request_job_is_wired_or_denied(self):
        config = json.loads(s.CONFIG.read_text())
        self.assertEqual(s.check(ROOT, config), [])

    def test_the_deny_list_has_reasons_and_the_wired_list_is_not_empty(self):
        config = json.loads(s.CONFIG.read_text())
        self.assertTrue(config["wired"])
        for name, entries in config["deny"].items():
            for job, reason in entries.items():
                self.assertGreater(len(reason), 10, f"{name}: {job}")

    def test_an_unlisted_job_is_named(self):
        config = json.loads(s.CONFIG.read_text())
        name = next(iter(config["deny"]))
        job = next(iter(config["deny"][name]))
        del config["deny"][name][job]
        self.assertTrue(any(f"{name}: {job} is neither wired nor denied" in e for e in s.check(ROOT, config)))


if __name__ == "__main__":
    unittest.main()
