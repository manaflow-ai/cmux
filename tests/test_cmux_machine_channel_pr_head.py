#!/usr/bin/env python3
"""scripts/ci/cmux_machine_channel_pr_head.py find: the merged PR head's build, or nothing (PR_HEAD_FAST_LANE)."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pr_head", ROOT / "scripts/ci/cmux_machine_channel_pr_head.py")
pr_head = importlib.util.module_from_spec(spec)
sys.modules["pr_head"] = pr_head
spec.loader.exec_module(pr_head)

REPO = "manaflow-ai/cmux"
MERGE = "m" * 40
HEAD = "h" * 40
PREFIX = "machine-channel-"
BOTH = [{"name": f"{PREFIX}cmux-tui-{t}"} for t in pr_head.TARGETS]


def pull(**over):
    pr = {"merge_commit_sha": MERGE, "base": {"ref": "feat-cmux-next"},
          "head": {"sha": HEAD, "repo": {"full_name": REPO}}}
    pr.update(over)
    return pr


class Fake:
    def __init__(self, pulls, runs, artifacts, jobs=None, tips=None, numbered=None):
        self.pulls, self.runs, self.artifacts, self.jobs = pulls, runs, artifacts, jobs or {}
        self.tips, self.numbered = tips or [], numbered or {}
        self.calls = []

    def __call__(self, path):
        self.calls.append(path)
        if path.startswith("commits/"):
            return self.pulls
        if path.startswith("pulls/"):
            return self.numbered.get(int(path.split("/")[1]), {})
        if "branch=lane%2Fmerge-train" in path:
            return {"workflow_runs": self.tips}
        if path.startswith("actions/workflows/"):
            return {"workflow_runs": self.runs() if callable(self.runs) else self.runs}
        run = int(path.split("/")[2])
        if path.endswith("artifacts?per_page=100"):
            a = self.artifacts(run) if callable(self.artifacts) else self.artifacts.get(run, [])
            return {"artifacts": a}
        return {"jobs": self.jobs.get(run, [])}


def run_find(api, keys=None, wait=0.0, tree="t" * 40, subject=""):
    keys = keys or {MERGE: "k1", HEAD: "k1"}
    clock = [0.0]
    return pr_head.find(api, REPO, MERGE, PREFIX, wait, key=lambda r: keys.get(r, ""),
                        sleep=lambda s: clock.__setitem__(0, clock[0] + s), now=lambda: clock[0],
                        tree=lambda r: tree if r == MERGE else "", subject=lambda r: subject if r == MERGE else "")


TIP = "p" * 40


def tip_run(id_, tree="t" * 40, sha=TIP):
    return {"id": id_, "head_sha": sha, "head_commit": {"tree_id": tree}}


class FindTest(unittest.TestCase):
    def test_a_head_that_skipped_its_build_takes_the_earlier_head_with_its_key(self):
        # The plan skipped HEAD's build: EARLIER, the branch's previous head with the merge's key, built both.
        earlier = "e" * 40
        own = [{"id": 30, "head_sha": HEAD, "head_branch": "lane/x", "status": "completed"}]
        branch = own + [{"id": 25, "head_sha": earlier, "head_branch": "lane/x"}]
        calls = []

        def api(path):
            calls.append(path)
            if path.startswith("commits/"):
                return [pull()]
            if "branch=lane%2Fx" in path:
                return {"workflow_runs": branch}
            if path.startswith("actions/workflows/"):
                return {"workflow_runs": own}
            return {"artifacts": BOTH if "/25/" in path else []}

        self.assertEqual(run_find(api, keys={MERGE: "k1", HEAD: "k1", earlier: "k1"}), 25)
        self.assertIsNone(run_find(api, keys={MERGE: "k1", HEAD: "k1", earlier: "k2"}))

    def test_same_tree_key_and_both_artifacts_take_the_run(self):
        api = Fake([pull()], [{"id": 7, "status": "completed"}], {7: BOTH})
        self.assertEqual(run_find(api), 7)
        self.assertIn(f"actions/workflows/pr-router.yml/runs?head_sha={HEAD}&event=pull_request&per_page=20", api.calls)

    def test_the_squash_subject_s_own_number_is_read_first(self):
        # 2026-11-26 run 45874893836: the merge's own PR was past the first 30 of commits/SHA/pulls.
        older = [pull(merge_commit_sha="x" * 40) for _ in range(30)]
        api = Fake(older, [{"id": 7, "status": "completed"}], {7: BOTH}, numbered={54329: pull()})
        self.assertEqual(run_find(api, subject="fix(mobile): per-phone mailbox paging (#54329)"), 7)
        self.assertIn("pulls/54329", api.calls)
        self.assertFalse([c for c in api.calls if c.startswith("commits/")])

    def test_a_number_that_is_not_this_merge_falls_back_to_the_full_list(self):
        api = Fake([pull()], [{"id": 7, "status": "completed"}], {7: BOTH},
                   numbered={12: pull(merge_commit_sha="x" * 40)})
        self.assertEqual(run_find(api, subject="revert something (#12)"), 7)
        self.assertIn(f"commits/{MERGE}/pulls?per_page=100", api.calls)

    def test_the_newest_run_with_both_wins(self):
        api = Fake([pull()], [{"id": 5, "status": "completed"}, {"id": 9, "status": "completed"}], {5: BOTH, 9: BOTH})
        self.assertEqual(run_find(api), 9)

    def test_keys_that_differ_build_here(self):
        api = Fake([pull()], [{"id": 7, "status": "completed"}], {7: BOTH})
        self.assertIsNone(run_find(api, keys={MERGE: "k1", HEAD: "k2"}))
        self.assertIsNone(run_find(api, keys={MERGE: "", HEAD: ""}))

    def test_a_stale_head_takes_the_train_tip_with_the_merges_tree(self):
        runs = lambda: [{"id": 11, "status": "completed"}] if api.calls[-1].find(TIP) > 0 else []
        api = Fake([pull()], runs, {11: BOTH},
                   tips=[tip_run(3, tree="x" * 40, sha="q" * 40), tip_run(5)])
        self.assertEqual(run_find(api, keys={MERGE: "k1", HEAD: "k2"}), 11)
        self.assertIn(f"actions/workflows/pr-router.yml/runs?head_sha={TIP}&event=pull_request&per_page=20", api.calls)

    def test_no_train_tip_with_the_merges_tree_builds_here(self):
        api = Fake([pull()], [{"id": 11, "status": "completed"}], {11: BOTH}, tips=[tip_run(5, tree="x" * 40)])
        self.assertIsNone(run_find(api, keys={MERGE: "k1", HEAD: "k2"}))
        self.assertIsNone(run_find(Fake([pull()], [], {}, tips=[tip_run(5)]), keys={MERGE: "k1", HEAD: "k2"}, tree=""))

    def test_a_fork_head_another_base_or_a_non_squash_build_here(self):
        for pr in (pull(head={"sha": HEAD, "repo": {"full_name": "someone/cmux"}}),
                   pull(base={"ref": "main"}), pull(merge_commit_sha="x" * 40)):
            with self.subTest(pr=pr):
                self.assertIsNone(run_find(Fake([pr], [{"id": 7, "status": "completed"}], {7: BOTH})))

    def test_one_target_or_expired_artifacts_build_here(self):
        expired = [dict(a, expired=True) for a in BOTH]
        for arts in (BOTH[:1], expired, []):
            with self.subTest(arts=arts):
                self.assertIsNone(run_find(Fake([pull()], [{"id": 7, "status": "completed"}], {7: arts})))

    def test_a_build_still_running_is_waited_for(self):
        polls = []

        def artifacts(run):
            polls.append(run)
            return BOTH if len(polls) >= 3 else []

        jobs = {7: [{"name": "machine channel PR head build / build-machine-channel / build x", "status": "in_progress"}]}
        api = Fake([pull()], [{"id": 7, "status": "in_progress"}], artifacts, jobs)
        self.assertEqual(run_find(api, wait=600), 7)
        self.assertEqual(len(polls), 3)

    def test_the_wait_is_bounded(self):
        jobs = {7: [{"name": "x / build-machine-channel / build y", "status": "in_progress"}]}
        api = Fake([pull()], [{"id": 7, "status": "in_progress"}], {}, jobs)
        self.assertIsNone(run_find(api, wait=90))

    def test_a_running_router_whose_channel_jobs_ended_is_not_waited_for(self):
        jobs = {7: [{"name": "x / does the machine channel need this commit", "status": "completed"}]}
        api = Fake([pull()], [{"id": 7, "status": "in_progress"}], {}, jobs)
        self.assertIsNone(run_find(api, wait=600))
        self.assertEqual(sum(c.startswith("actions/workflows/") for c in api.calls), 1)

    def test_main_prints_nothing_without_a_token(self):
        import io, contextlib, os
        out = io.StringIO()
        env = dict(os.environ)
        os.environ.pop("GH_TOKEN", None)
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(pr_head.main(["find", MERGE]), 0)
        finally:
            os.environ.clear(); os.environ.update(env)
        self.assertEqual(out.getvalue(), "")


    def test_fast_lane_reads_on_the_app_budget_not_github_token(self):
        # Run 45761272633 (5a2862fb, 2026-11-26): the lookup on the shared GITHUB_TOKEN quota got a 403 and
        # the merge rebuilt; run 45730730942: both points' cross-run downloads failed on that quota.
        import yaml
        wf = yaml.safe_load((ROOT / ".github/workflows/cmux-machine-channel.yml").read_text())
        steps = {n: {s.get("id") or s.get("name"): s for s in j["steps"]} for n, j in wf["jobs"].items()
                 if "steps" in j}
        self.assertEqual(steps["plan"]["plan"]["env"]["GH_TOKEN"], "${{ steps.app.outputs.token }}")
        self.assertIn("create-github-app-token", steps["plan"]["app"]["uses"])
        points = [n for n, by in steps.items()
                  if "Download the machine channel's Linux cmux-tui binaries" in by]
        self.assertEqual(len(points), 2)
        for n in points:
            self.assertIn("create-github-app-token", steps[n]["app"]["uses"])
            tok = steps[n]["Download the machine channel's Linux cmux-tui binaries"]["with"]["github-token"]
            self.assertIn("steps.app.outputs.token", tok)
            self.assertNotIn("github.token", tok)

    def test_a_refusal_names_its_reason(self):
        import io, urllib.error, urllib.request
        err = urllib.error.HTTPError("u", 403, "Forbidden", {}, io.BytesIO(b'{"message":"API rate limit exceeded for installation"}'))
        def boom(*a, **k):
            raise err
        real = urllib.request.urlopen
        urllib.request.urlopen = boom
        try:
            with self.assertRaisesRegex(RuntimeError, "HTTP 403: .*rate limit exceeded"):
                pr_head.github_api(REPO, "t")("commits/x/pulls")
        finally:
            urllib.request.urlopen = real


class LandTierTest(unittest.TestCase):
    """pr-router's machine channel PR head build runs only at a head handed to land (Leo, 2026-11-23: "de facto, im
    asking for 99% fewer minutes of ci time, period."): tests/test_head_tier.py land_tier_condition."""

    def test_the_job_carries_the_land_tier_condition(self):
        sys.path.insert(0, str(ROOT / "tests"))
        from test_head_tier import _job_ifs, land_tier_condition

        jobs = _job_ifs((ROOT / ".github/workflows/pr-router.yml").read_text())
        self.assertIn(land_tier_condition("pull_request"), jobs["machine-channel-pr-head"])


class TreeKeyCliTest(unittest.TestCase):
    """The real tree key CLI, not a fake key: a `key` subcommand it never took made every key empty, so every
    land-tier head built both thin targets and no merge ever took one (h94 sweep, 2026-11-26)."""

    def test_tree_key_reads_a_real_key(self):
        import re
        self.assertRegex(pr_head.tree_key("HEAD"), re.compile(r"^[0-9a-f]{40}$"))

    def test_the_workflow_calls_the_cli_as_it_parses(self):
        text = (ROOT / ".github/workflows/cmux-machine-channel.yml").read_text()
        self.assertNotIn('"$tk" key', text)
        self.assertIn('"$tk" --version v2', text)

    def test_a_head_behind_the_base_does_not_build(self):
        """find takes a build only when the head's key is the merge's, so a head behind the base (its key differs
        from its merge with the base) builds a pair no merge can take: 470 head builds, 16.8k runner-minutes, in
        04:30-07:11Z 2026-11-26 against 6 push builds (ci-min-per-pr-1500)."""
        text = (ROOT / ".github/workflows/cmux-machine-channel.yml").read_text()
        plan = text[text.index("if [[ \"$GITHUB_EVENT_NAME\" == pull_request ]]"):text.index("# The channel's commit")]
        self.assertIn('"$tk" --version v2 HEAD^2', plan)
        self.assertIn('"$head" != "$mine"', plan)
        self.assertLess(plan.index('"$mine" != "$base"'), plan.index('"$head" != "$mine"'))
        self.assertLess(plan.index('"$head" != "$mine"'), plan.index('echo "build=$build" >> "$GITHUB_OUTPUT"'))


if __name__ == "__main__":
    unittest.main()
