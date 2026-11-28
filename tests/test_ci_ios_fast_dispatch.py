#!/usr/bin/env python3
"""The supported recovery for a stale `cmux/ios-fast` pending (ios-fast-verdict-dispatch.yml and
scripts/ci/ios_fast_dispatch.py): it judges only an open same-repo PR at the given head, on GitHub's merge commit of
that head, runs only pr-pipeline.yml's ios fast verdict at that commit, and posts exactly what pr-router.yml's
ios-fast-status would.

    python3 tests/test_ci_ios_fast_dispatch.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import ios_fast_dispatch as fd  # noqa: E402
sys.path.insert(0, str(ROOT / "tests"))
import test_ci_edit_events_start_no_runner as gh_expr  # noqa: E402  (its GitHub expression evaluator)

REPO = "manaflow-ai/cmux"
SHA = "54128e3509207e710815575c49eba4ac5e3e2d8d"
MERGE = "a" * 40
BASE = "b" * 40
WORKFLOWS = ROOT / ".github" / "workflows"


def pr(**over) -> dict:
    p = {"state": "open", "head": {"sha": SHA, "repo": {"full_name": REPO}}, "base": {"ref": "feat-cmux-next"},
         "merge_commit_sha": MERGE, "mergeable": True}
    p.update(over)
    return p


def load(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text())


class ResolveTest(unittest.TestCase):
    def test_an_open_same_repo_head_resolves_to_its_merge_commit(self) -> None:
        self.assertEqual(fd.check_pr(pr(), REPO, SHA), MERGE)
        self.assertEqual(fd.check_merge({"parents": [{"sha": BASE}, {"sha": SHA}]}, MERGE, SHA), BASE)

    def test_it_refuses_anything_it_cannot_judge_honestly(self) -> None:
        cases = {
            "short sha": (pr(), SHA[:12]),
            "closed": (pr(state="closed"), SHA),
            "fork": (pr(head={"sha": SHA, "repo": {"full_name": "someone/cmux"}}), SHA),
            "other base": (pr(base={"ref": "main"}), SHA),
            "head moved": (pr(head={"sha": "c" * 40, "repo": {"full_name": REPO}}), SHA),
            "conflict": (pr(mergeable=False), SHA),
            "no merge commit yet": (pr(merge_commit_sha=None, mergeable=None), SHA),
        }
        for why, (p, sha) in cases.items():
            with self.subTest(why=why), self.assertRaises(fd.Refused):
                fd.check_pr(p, REPO, sha)

    def test_a_merge_commit_of_another_head_is_refused(self) -> None:
        for parents in ([{"sha": BASE}, {"sha": "c" * 40}], [{"sha": SHA}], []):
            with self.subTest(parents=parents), self.assertRaises(fd.Refused):
                fd.check_merge({"parents": parents}, MERGE, SHA)

    def test_missing_inputs_fail_without_a_call(self) -> None:
        env = {k: v for k, v in os.environ.items() if k not in ("REPO", "PR", "SHA", "GH_TOKEN", "GITHUB_OUTPUT")}
        out = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/ios_fast_dispatch.py"), "resolve"],
                             env=env, capture_output=True, text=True)
        self.assertEqual(out.returncode, 1)
        self.assertIn("::error", out.stdout)


class WorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.wf = load("ios-fast-verdict-dispatch.yml")
        cls.on = cls.wf.get("on", cls.wf.get(True))
        cls.jobs = cls.wf["jobs"]
        cls.pipeline = load("pr-pipeline.yml")
        cls.router = load("pr-router.yml")["jobs"]

    def test_it_is_dispatched_with_a_pr_and_its_head(self) -> None:
        self.assertEqual(set(self.on), {"workflow_dispatch", "push"})
        # The push only registers the workflow (tests/test_ci_workflows_registered.py): its own path, and no job runs.
        self.assertEqual(self.on["push"], {"branches": ["feat-cmux-next"],
                                           "paths": [".github/workflows/ios-fast-verdict-dispatch.yml"]})
        self.assertEqual(self.jobs["resolve"]["if"], "${{ github.event_name == 'workflow_dispatch' }}")
        inputs = self.on["workflow_dispatch"]["inputs"]
        self.assertTrue(inputs["pr"]["required"])
        self.assertTrue(inputs["sha"]["required"])
        self.assertEqual(self.wf["permissions"], {})
        # A per-target title: a sweep over many PRs is not one run fanned out.
        self.assertIn("${{ inputs.pr }}", self.wf["run-name"])
        self.assertIn("${{ inputs.sha }}", self.wf["run-name"])

    def test_the_pipeline_runs_only_the_ios_fast_verdict_at_the_merge_commit(self) -> None:
        call = self.jobs["pipeline"]
        self.assertEqual(call["uses"], "./.github/workflows/pr-pipeline.yml")
        self.assertEqual(call["needs"], ["resolve"])
        self.assertEqual(call["with"]["ref"], "${{ needs.resolve.outputs.merge }}")
        routed = json.loads(call["with"]["jobs"])
        table_jobs = {"linux", "web-browser", "ios", "mac"}
        self.assertFalse(set(routed) & table_jobs)
        # Every table job of the pipeline gates on inputs.jobs, so this list skips them all.
        for name, job in self.pipeline["jobs"].items():
            if name.startswith("ios-fast") or name == "mac-fallback":
                continue
            with self.subTest(job=name):
                self.assertIn("inputs.jobs", job.get("if", ""))
        self.assertEqual(call["permissions"], self.router["pipeline"]["permissions"])

    def test_both_ios_fast_checkouts_take_the_ref_input(self) -> None:
        ins = self.pipeline.get("on", self.pipeline.get(True))["workflow_call"]["inputs"]
        self.assertEqual(ins["ref"]["default"], "")
        for job in ("ios-fast-runner", "ios-fast"):
            checkout = next(s for s in self.pipeline["jobs"][job]["steps"] if "actions/checkout" in s.get("uses", ""))
            with self.subTest(job=job):
                self.assertEqual(checkout["with"]["ref"], "${{ inputs.ref }}")

    def test_the_post_is_the_routers_post_at_the_dispatched_head(self) -> None:
        mine = next(s for s in self.jobs["ios-fast-status"]["steps"] if s.get("name") == "Post the verdict")
        theirs = next(s for s in self.router["ios-fast-status"]["steps"] if s.get("name") == "Post the verdict")
        self.assertEqual(mine["run"], theirs["run"], "keep the dispatch's post identical to pr-router.yml's")
        self.assertEqual(set(mine["env"]), set(theirs["env"]))
        self.assertEqual(mine["env"]["SHA"], "${{ inputs.sha }}")
        self.assertEqual(mine["env"]["PR"], "${{ inputs.pr }}")
        for key in ("PIPELINE", "RUN", "VERDICT", "SUMMARY", "TOKENS", "NEED_PROOF"):
            with self.subTest(env=key):
                self.assertEqual(mine["env"][key], theirs["env"][key])
        self.assertEqual(self.jobs["ios-fast-status"]["permissions"], self.router["ios-fast-status"]["permissions"])
        mine_co = self.jobs["ios-fast-status"]["steps"][0]["with"]["sparse-checkout"].split()
        theirs_co = self.router["ios-fast-status"]["steps"][0]["with"]["sparse-checkout"].split()
        self.assertEqual(mine_co, theirs_co)

    def test_a_resolved_head_always_gets_a_post(self) -> None:
        cond = gh_expr.condition(self.jobs["ios-fast-status"]["if"])
        for resolve, posts in (("success", True), ("failure", False)):
            with self.subTest(resolve=resolve):
                ctx = {"needs": {"resolve": {"result": resolve}, "pipeline": {"result": "failure"}}}
                self.assertIs(gh_expr.truthy(gh_expr.evaluate(cond, ctx, {"cancelled": False})), posts)

    def test_a_rate_limit_past_the_job_bound_is_refused_naming_its_end_not_slept(self) -> None:
        # cmux run 46109204066: this resolve slept toward a 405 s named limit and its 5-min job was cancelled.
        import functools
        import time
        from unittest import mock
        import deadline_http
        import gh_http
        headers = {"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(time.time()) + 405)}
        slept: list[float] = []
        answer = (403, b'{"message":"API rate limit exceeded"}', headers)
        with mock.patch.dict(os.environ, {gh_http.DEADLINE_ENV: "240"}), \
                mock.patch.object(gh_http, "STARTED", time.monotonic()), \
                mock.patch.object(deadline_http, "request", lambda *a, **k: answer), \
                mock.patch.object(gh_http, "request", functools.partial(gh_http.request, sleep=slept.append)):
            os.environ.pop(gh_http.DEADLINE_AT_ENV, None)
            with self.assertRaisesRegex(fd.Refused, "rate-limited until"):
                fd.get(f"repos/{REPO}/pulls/1", "t")
        self.assertEqual(slept, [])

    def test_a_refused_run_token_falls_to_the_pool_without_waiting(self) -> None:
        # cmux run 46112802526 (cmux#62219): resolve read `pulls/62219` with the run token alone, got HTTP 403, slept
        # toward 900 s and was cancelled at its 5-min timeout. The pool token reads it at once.
        import time
        from unittest import mock
        import gh_http
        headers = {"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(time.time()) + 900)}
        seen: list[tuple[str, object]] = []

        def request(req, seconds, **kw):
            token = req.get_header("Authorization")
            seen.append((token, kw.get("rate_budget_s")))
            if token == "Bearer run":
                return 403, b'{"message":"API rate limit exceeded"}', headers
            return 200, json.dumps(pr()).encode(), {}
        with mock.patch.object(gh_http, "request", request):
            self.assertEqual(fd.get(f"repos/{REPO}/pulls/1", ["run", "pool1", "pool2"])["merge_commit_sha"], MERGE)
        self.assertEqual(seen, [("Bearer run", 0), ("Bearer pool1", 0)])
        self.assertEqual(fd.read_tokens({"GH_TOKEN": "run", "TOKENS": "pool1  pool2 run"}), ["run", "pool1", "pool2"])
        step = next(s for s in self.jobs["resolve"]["steps"] if s.get("id") == "resolve")
        self.assertIn("CI_POOL_TOKEN_1", step["env"]["TOKENS"])

    def test_the_resolver_parses(self) -> None:
        step = next(s for s in self.jobs["resolve"]["steps"] if s.get("id") == "resolve")
        self.assertIn("scripts/ci/ios_fast_dispatch.py resolve", step["run"])
        for path in self.jobs["resolve"]["steps"][0]["with"]["sparse-checkout"].split():
            with self.subTest(path=path):
                self.assertTrue((ROOT / path).is_file())


if __name__ == "__main__":
    unittest.main()
