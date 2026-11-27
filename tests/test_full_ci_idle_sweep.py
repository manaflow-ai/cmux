#!/usr/bin/env python3
"""scripts/ci/full_ci_idle_sweep.py: which pull requests lose a stale full-ci, and the removal calls it makes."""
import importlib.util
import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("full_ci_idle_sweep", ROOT / "scripts/ci/full_ci_idle_sweep.py")
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)

NOW = sweep.parse_time("2026-11-26T18:00:00Z")


def commit(at, headline="fix a thing", parents=1):
    return {"committedDate": at, "messageHeadline": headline, "parents": {"totalCount": parents}}


def pr(number, head="lane/x", labels=("full-ci",), commits=None, adds=(), base="feat-cmux-next", cross=False):
    return {"number": number, "baseRefName": base, "headRefName": head, "isCrossRepository": cross,
            "labels": list(labels),
            "commits": commits if commits is not None else [commit("2026-11-26T08:00:00Z")],
            "labelAdds": [{"createdAt": at, "label": "full-ci"} for at in adds]}


class SelectTest(unittest.TestCase):
    def picked(self, *prs):
        return [p["number"] for p in sweep.select(list(prs), NOW, 6.0)]

    def test_idle_lane_pr_is_cleared(self):
        self.assertEqual(self.picked(pr(1)), [1])

    def test_recent_commit_or_label_add_keeps_it(self):
        self.assertEqual(self.picked(pr(1, commits=[commit("2026-11-26T15:00:00Z")]),
                                     pr(2, adds=["2026-11-26T14:00:00Z"])), [])

    def test_commit_after_the_add_clears_a_busy_pr(self):
        busy = [commit("2026-11-26T14:00:00Z"), commit("2026-11-26T17:00:00Z")]
        self.assertEqual(self.picked(pr(1, commits=busy, adds=["2026-11-26T15:00:00Z"])), [1])

    def test_base_merge_after_the_add_is_a_stale_head(self):
        heads = [commit("2026-11-26T14:00:00Z"),
                 commit("2026-11-26T17:00:00Z", "Merge branch 'feat-cmux-next' into lane/x", 2)]
        self.assertEqual(self.picked(pr(1, commits=heads, adds=["2026-11-26T15:00:00Z"])), [1])

    def test_add_at_the_current_head_keeps_it(self):
        self.assertEqual(self.picked(pr(1, commits=[commit("2026-11-26T15:00:00Z")], adds=["2026-11-26T15:30:00Z"]),
                                     pr(2, commits=[commit("2026-11-26T15:00:00Z")])), [])

    def test_stale_head_still_spares_people_and_land(self):
        heads = [commit("2026-11-26T17:00:00Z")]
        adds = ["2026-11-26T15:00:00Z"]
        self.assertEqual(self.picked(pr(1, head="austin/x", commits=heads, adds=adds),
                                     pr(2, labels=("full-ci", "ready-to-land"), commits=heads, adds=adds)), [])

    def test_base_merges_are_not_activity(self):
        merges = [commit("2026-11-26T08:00:00Z"),
                  commit("2026-11-26T16:00:00Z", "Merge remote-tracking branch 'origin/feat-cmux-next' into lane/x", 2),
                  commit("2026-11-26T17:00:00Z", "Merge branch 'feat-cmux-next' into lane/x", 2)]
        self.assertEqual(self.picked(pr(1, commits=merges)), [1])
        # A merge of another branch is the pull request's own work.
        own = merges + [commit("2026-11-26T17:30:00Z", "Merge branch 'lane/y' into lane/x", 2)]
        self.assertEqual(self.picked(pr(2, commits=own)), [])

    def test_people_land_and_other_bases_keep_it(self):
        self.assertEqual(self.picked(pr(1, head="leo/try"), pr(2, labels=("full-ci", "ready-to-land")),
                                     pr(3, base="main"), pr(4, cross=True), pr(5, labels=("risk:normal",)),
                                     pr(6, commits=[])), [])


class Done:
    def __init__(self, stdout="", returncode=0, stderr=""):
        self.stdout, self.returncode, self.stderr = stdout, returncode, stderr


class MainTest(unittest.TestCase):
    def fake(self, removal=None):
        calls = []
        node = {"number": 7, "baseRefName": "feat-cmux-next", "headRefName": "lane/x", "isCrossRepository": False,
                "labels": {"nodes": [{"name": "full-ci"}]},
                "commits": {"nodes": [{"commit": commit("2026-11-26T08:00:00Z")}]},
                "timelineItems": {"nodes": [{"createdAt": "2026-11-26T07:00:00Z", "label": {"name": "full-ci"}}]}}
        page = {"data": {"search": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": [node, {}]}}}

        def run(argv):
            calls.append(argv)
            if argv[:2] == ["api", "graphql"]:
                return Done(json.dumps(page))
            return removal or Done()
        return run, calls

    def test_dry_run_removes_nothing(self):
        run, calls = self.fake()
        self.assertEqual(sweep.main(["--repo", "o/r"], run=run, now=NOW, sleep=lambda s: None), 0)
        self.assertEqual([c[:2] for c in calls], [["api", "graphql"]])

    def test_apply_deletes_the_label(self):
        run, calls = self.fake()
        self.assertEqual(sweep.main(["--repo", "o/r", "--apply"], run=run, now=NOW, sleep=lambda s: None), 0)
        self.assertEqual(calls[-1], ["api", "-X", "DELETE", "repos/o/r/issues/7/labels/full-ci"])

    def test_a_refused_removal_stops(self):
        run, _ = self.fake(Done(returncode=1, stderr="HTTP 403: Resource not accessible"))
        self.assertEqual(sweep.main(["--repo", "o/r", "--apply"], run=run, now=NOW, sleep=lambda s: None), 1)
        run, _ = self.fake(Done(returncode=1, stderr="HTTP 404: Label does not exist"))
        self.assertEqual(sweep.main(["--repo", "o/r", "--apply"], run=run, now=NOW, sleep=lambda s: None), 0)


if __name__ == "__main__":
    unittest.main()
