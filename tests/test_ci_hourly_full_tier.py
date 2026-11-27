#!/usr/bin/env python3
"""The hourly full tier (scripts/ci/hourly_full_tier.py, .github/workflows/cmux-next-hourly-full-tier.yml,
.github/hourly-full-tier.json) and its kick in scripts/ci/post_merge_batch.py tick."""

from __future__ import annotations

import sys
import unittest
import unittest.mock
from argparse import Namespace
from datetime import datetime, timezone
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import hourly_full_tier as hft  # noqa: E402
import post_merge_batch as pmb  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-hourly-full-tier.yml"
MANIFEST = ROOT / ".github" / "hourly-full-tier.json"
NOW = datetime(2026, 11, 26, 12, 0, tzinfo=timezone.utc)
A, B, C, D = ("a" * 40, "b" * 40, "c" * 40, "d" * 40)


def run(run_id: int, sha: str, conclusion: str | None = "success", created: str = "2026-11-26T10:00:00Z") -> dict:
    return {"id": run_id, "head_sha": sha, "status": "completed" if conclusion else "in_progress",
            "conclusion": conclusion, "created_at": created, "html_url": f"https://x/runs/{run_id}"}


def commit(sha: str, parent: str, subject: str, second: str = "") -> dict:
    parents = [{"sha": parent}] + ([{"sha": second}] if second else [])
    return {"sha": sha, "parents": parents, "commit": {"message": subject + "\n\nbody"}}


class ManifestTests(unittest.TestCase):
    def test_every_listed_workflow_is_dispatchable_with_no_inputs_and_its_paths_match(self) -> None:
        manifest = hft.load_manifest(MANIFEST)
        self.assertIn("ci.yml", manifest)
        for name, paths in manifest.items():
            with self.subTest(workflow=name):
                workflow = yaml.safe_load((ROOT / ".github" / "workflows" / name).read_text())
                on = workflow.get("on", workflow.get(True))
                dispatch = on.get("workflow_dispatch") or {}
                required = [k for k, v in (dispatch.get("inputs") or {}).items() if (v or {}).get("required")]
                self.assertIn("workflow_dispatch", on)
                self.assertEqual(required, [])
                self.assertEqual(paths, list((on.get("pull_request") or {}).get("paths") or []))

    def test_no_listed_workflow_is_also_in_the_post_merge_batch_or_runs_on_a_feat_push(self) -> None:
        batch = {suite.workflow for suite in pmb.load_manifest().values()}
        for name in hft.load_manifest(MANIFEST):
            with self.subTest(workflow=name):
                self.assertNotIn(name, batch)
                workflow = yaml.safe_load((ROOT / ".github" / "workflows" / name).read_text())
                push = workflow.get("on", workflow.get(True)).get("push")
                self.assertFalse(push and "feat-cmux-next" in ((push or {}).get("branches") or []))


class PathsTests(unittest.TestCase):
    def test_github_paths_semantics(self) -> None:
        paths = ["**", "!**/*.md", "**/AGENTS.md"]
        self.assertTrue(hft.reached(["a/b.swift"], paths))
        self.assertFalse(hft.reached(["docs/x.md"], paths))
        self.assertTrue(hft.reached(["web/AGENTS.md"], paths))
        self.assertTrue(hft.reached(["AGENTS.md"], paths))
        self.assertTrue(hft.reached(["cmux-tui/Cargo.toml"], ["cmux-tui/Cargo.*"]))
        self.assertFalse(hft.reached(["cmux-tui/x/Cargo.toml"], ["cmux-tui/Cargo.*"]))
        self.assertTrue(hft.reached(["web/services/vms/drivers/a/b.ts"], ["web/services/vms/drivers/**"]))
        self.assertFalse(hft.reached(["web/x.ts"], ["workers/**"]))
        self.assertTrue(hft.reached(None, ["workers/**"]))  # unknown files reach every workflow
        self.assertTrue(hft.reached(["x"], []))


class VerdictTests(unittest.TestCase):
    def test_a_green_or_unfinished_newest_gives_no_verdict(self) -> None:
        self.assertIsNone(hft.verdict([]))
        self.assertIsNone(hft.verdict([run(2, B), run(1, A, "failure")]))
        self.assertIsNone(hft.verdict([run(3, C, None)]))

    def test_a_red_newest_names_the_newest_green_before_it(self) -> None:
        red, green = hft.verdict([run(4, D, None), run(3, C, "failure"), run(2, B, "cancelled"), run(1, A)])
        self.assertEqual((red["id"], green["id"]), (3, 1))
        red, green = hft.verdict([run(3, C, "failure"), run(2, B, "failure")])
        self.assertEqual((red["id"], green), (3, None))

    def test_the_first_parent_chain_and_its_prs(self) -> None:
        commits = [commit(B, A, "First (#10)"), commit("e" * 40, A, "side branch"),
                   commit(C, B, "Second (#11)", second="e" * 40), commit(D, C, "direct push")]
        chain = hft.first_parent_chain(commits, A, D)
        self.assertEqual([c["sha"] for c in chain], [D, C, B])
        self.assertEqual([n for n, _, _ in hft.merged_prs(chain)], ["", "11", "10"])
        self.assertEqual(hft.first_parent_chain(commits, A, "f" * 40), [])

    def test_one_issue_per_red_head_names_the_prs_and_never_reverts(self) -> None:
        calls = []

        def api(path, method="GET", fields=None, token=None):
            calls.append((method, path, fields, token))
            if path.startswith("repos/o/r/compare/"):
                return {"commits": [commit(B, A, "First (#10)"), commit(C, B, "Second (#11)")]}
            if path.startswith("search/issues"):
                return {"items": []}
            return None

        found = [("ci.yml", run(3, C, "failure"), run(1, A)), ("relay-tls.yml", run(9, C, "failure"), run(8, B,
                 created="2026-11-26T11:00:00Z"))]
        with unittest.mock.patch("sys.stdout"):
            titles = hft.report_reds("o/r", "feat-cmux-next", found, False, api, "job-token")
        self.assertEqual(titles, [f"Hourly full tier red at feat-cmux-next {C[:10]}"])
        posts = [c for c in calls if c[0] == "POST"]
        self.assertEqual([p[1] for p in posts], ["repos/o/r/issues"])
        self.assertEqual(posts[0][3], "job-token")
        body = posts[0][2]["body"]
        self.assertIn("#10 First (#10)", body)
        self.assertIn("#11 Second (#11)", body)
        self.assertIn("ci.yml", body)
        self.assertIn("relay-tls.yml", body)
        self.assertIn("reverts or fixes forward", body)
        self.assertIn(f"compare/{A}...{C}", " ".join(c[1] for c in calls))  # the older of the two last greens
        self.assertFalse([c for c in calls if "revert" in c[1] or "pulls" in c[1]])

    def test_an_already_reported_red_is_not_reported_again(self) -> None:
        title = f"Hourly full tier red at feat-cmux-next {C[:10]}"

        def api(path, method="GET", fields=None, token=None):
            self.assertEqual(method, "GET")
            return {"items": [{"title": title}]} if path.startswith("search/") else {"commits": []}

        with unittest.mock.patch("sys.stdout"):
            self.assertEqual(hft.report_reds("o/r", "feat-cmux-next", [("ci.yml", run(3, C, "failure"), None)],
                                             False, api), [])


class DispatchTests(unittest.TestCase):
    def test_due(self) -> None:
        never = lambda base: self.fail("no compare needed")  # noqa: E731
        self.assertEqual(hft.due(C, [], never, [])[0], True)
        self.assertEqual(hft.due(C, [run(1, C)], never, []), (False, "already ran at the tip"))
        self.assertEqual(hft.due(C, [run(2, B, None), run(1, A)], never, [])[0], False)
        self.assertEqual(hft.due(C, [run(1, A)], lambda base: ["docs/x.md"], ["**", "!**/*.md"])[0], False)
        self.assertEqual(hft.due(C, [run(1, A)], lambda base: ["a.swift"], ["**", "!**/*.md"])[0], True)
        self.assertEqual(hft.due(C, [run(1, A)], lambda base: None, ["workers/**"])[0], True)

    def test_run_dispatches_only_moved_and_touched_workflows_on_the_branch(self) -> None:
        calls = []
        manifest = {"ci.yml": ["**"], "relay-tls.yml": ["tests/relay_tls/**"], "cmux-vnc.yml": []}
        runs = {"ci.yml": [run(1, A)], "relay-tls.yml": [run(2, A)], "cmux-vnc.yml": [run(3, C)]}

        def api(path, method="GET", fields=None, token=None):
            calls.append((method, path, fields))
            if path.endswith("/commits/feat-cmux-next"):
                return {"sha": C}
            if "/runs?" in path:
                return {"workflow_runs": runs[path.split("/workflows/")[1].split("/")[0]]}
            if "/compare/" in path:
                return {"files": [{"filename": "web/x.ts"}]}
            return None

        args = Namespace(repo="o/r", branch="feat-cmux-next", manifest="", dry_run=False)
        with unittest.mock.patch.object(hft, "load_manifest", lambda path: manifest), \
                unittest.mock.patch("sys.stdout"):
            self.assertEqual(hft.run(args, api), 0)
        posts = [(c[1], c[2]) for c in calls if c[0] == "POST"]
        self.assertEqual(posts, [("repos/o/r/actions/workflows/ci.yml/dispatches", {"ref": "feat-cmux-next"})])
        self.assertEqual(len([c for c in calls if "/compare/" in c[1]]), 1)  # one compare per base


class WorkflowTests(unittest.TestCase):
    def test_the_workflow_is_dispatch_only_switchable_and_reverts_nothing(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text())
        self.assertEqual(list(workflow.get("on", workflow.get(True))), ["workflow_dispatch"])
        job = workflow["jobs"]["run"]
        self.assertIn("vars.CI_LAND_FULL_PER_PR != '1'", job["if"])
        self.assertEqual(job["permissions"], {"contents": "read", "issues": "write"})
        self.assertIn("hourly_full_tier.py run", job["steps"][-1]["run"])
        sparse = job["steps"][0]["with"]["sparse-checkout"]
        self.assertIn("scripts/ci/hourly_full_tier.py", sparse)
        self.assertIn(".github/hourly-full-tier.json", sparse)
        self.assertNotIn("revert", WORKFLOW.read_text().lower().replace("reverts or fixes forward", "")
                         .replace("nothing here reverts", ""))


class KickTests(unittest.TestCase):
    def test_hourly_decision(self) -> None:
        self.assertEqual(pmb.hourly_decision(C, [], NOW)[0], "dispatch")
        self.assertEqual(pmb.hourly_decision(C, [run(1, A, None)], NOW)[0], "skip")
        self.assertEqual(pmb.hourly_decision(C, [run(1, C, created="2026-11-26T09:00:00Z")], NOW)[0], "skip")
        self.assertEqual(pmb.hourly_decision(C, [run(1, A, created="2026-11-26T11:30:00Z")], NOW)[0], "skip")
        self.assertEqual(pmb.hourly_decision(C, [run(1, A, created="2026-11-26T11:04:00Z")], NOW)[0], "dispatch")

    def test_the_kick_dispatches_on_the_branch_and_an_error_never_breaks_the_tick(self) -> None:
        calls = []

        def api(path, method="GET", fields=None, **_):
            calls.append((method, path, fields))
            return {"workflow_runs": [run(1, A, created="2026-11-26T10:00:00Z")]}

        args = Namespace(repo="o/r", branch="feat-cmux-next", dry_run=False)
        with unittest.mock.patch("sys.stdout"):
            self.assertEqual(pmb.hourly_kick(args, C, NOW, api), "dispatch")
        self.assertIn(("POST", f"repos/o/r/actions/workflows/{pmb.HOURLY_WORKFLOW}/dispatches",
                       {"ref": "feat-cmux-next"}), calls)

        def broken(path, **_):
            raise RuntimeError("HTTP 404: workflow not found")

        with unittest.mock.patch("sys.stdout"):
            self.assertEqual(pmb.hourly_kick(args, C, NOW, broken), "error")

    def test_the_batch_tick_kicks_the_hourly_tier_and_still_runs_when_it_fails(self) -> None:
        calls = []

        def api(path, method="GET", fields=None, **_):
            calls.append((method, path))
            if path.endswith("/commits/feat-cmux-next"):
                return {"sha": C}
            if pmb.HOURLY_WORKFLOW in path:
                raise RuntimeError("HTTP 404")
            return None

        args = Namespace(repo="o/r", branch="feat-cmux-next", window_minutes="120", dry_run=True)
        with unittest.mock.patch.object(pmb, "gh_api", api), \
                unittest.mock.patch.object(pmb, "list_runs", lambda repo, branch: [run(1, C)]) as _, \
                unittest.mock.patch("sys.stdout"):
            self.assertEqual(pmb.cmd_tick(args), 0)
        self.assertTrue([c for c in calls if pmb.HOURLY_WORKFLOW in c[1]])


if __name__ == "__main__":
    unittest.main()
