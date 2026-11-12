import importlib.util
import pathlib
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/triage-radar.py"
WORKFLOW = ROOT / ".github/workflows/triage-radar.yml"
SPEC = importlib.util.spec_from_file_location("triage_radar", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def issue(number, title, *, user="reporter", labels=None, body="", comments=0, reactions=0):
    return {
        "number": number,
        "title": title,
        "body": body,
        "labels": [{"name": value} for value in (["bug"] if labels is None else labels)],
        "user": {"login": user},
        "comments": comments,
        "reactions": {"total_count": reactions},
        "created_at": f"2026-09-21T{number % 20:02d}:00:00Z",
        "updated_at": f"2026-09-21T{number % 20:02d}:30:00Z",
    }


class ClusterTests(unittest.TestCase):
    def test_reorder_burst_collapses_into_one_cluster(self):
        reports = [
            issue(13499, "0.64.25 custom sidebar: Reorderable keeps drawing rejected drops; workspace.reorder silently no-ops"),
            issue(13505, "0.64.25 reorder-workspace --index ignores the requested index, always resolves to workspace count"),
            issue(13506, "0.64.25 reorder-workspace --before/--after rejected: CLI sends index alongside before_workspace_id"),
            issue(13507, "0.64.25 custom sidebar Reorderable keeps rejected drops on screen; host never re-syncs order"),
            issue(13508, "0.64.25 custom sidebars: expose in-flight drag state for drop-target affordance"),
        ]
        clusters = MODULE.build_clusters(reports)
        self.assertTrue(clusters)
        self.assertEqual({item["number"] for item in clusters[0]["members"]}, {13499, 13505, 13506, 13507, 13508})

    def test_broad_product_area_terms_do_not_chain_unrelated_reports(self):
        reports = [
            issue(20, "Cloud workspace welcome guide for daily use"),
            issue(21, "Cloud workspace first machine ownership"),
            issue(22, "Cloud workspace sidebar notification layout"),
            issue(23, "Cloud workspace file browsing"),
        ]
        self.assertEqual(MODULE.build_clusters(reports), [])

    def test_same_release_does_not_cluster_unrelated_reports(self):
        reports = [
            issue(1, "0.64.25 Touch Bar support"),
            issue(2, "0.64.25 phone terminal viewport re-arm loop under relay"),
            issue(3, "0.64.25 window re-zooms after Accessibility API resize"),
        ]
        self.assertEqual(MODULE.build_clusters(reports), [])


class RegressionTests(unittest.TestCase):
    def test_crash_and_confirmed_nightly_repro_surface(self):
        report = issue(
            7,
            "cmux crashes when restoring a session",
            body=(
                "### Can you reproduce this on cmux NIGHTLY?\n\n"
                "Yes, it still reproduces on NIGHTLY\n\nPreviously worked."
            ),
        )
        score, evidence = MODULE.regression_evidence(report)
        self.assertGreaterEqual(score, 10)
        self.assertIn("crash/panic", evidence)
        self.assertIn("reproduces on NIGHTLY", evidence)

    def test_meta_issue_body_does_not_create_false_regression(self):
        report = issue(
            9,
            "Backlog reconciliation and synthesis",
            labels=[],
            body="Collect older reports mentioning crashes, hangs, data loss, and auth failures.",
        )
        score, evidence = MODULE.regression_evidence(report)
        self.assertEqual(score, 0)
        self.assertEqual(evidence, [])

    def test_fixed_on_nightly_is_deweighted(self):
        report = issue(
            8,
            "Connection fails after sleep",
            body=(
                "### Can you reproduce this on cmux NIGHTLY?\n\n"
                "No, it does not reproduce on NIGHTLY"
            ),
        )
        score, _ = MODULE.regression_evidence(report)
        self.assertLess(score, 4)


class RenderTests(unittest.TestCase):
    def test_generated_section_preserves_human_notes(self):
        body = (
            "human note before\n\n"
            + MODULE.START_MARKER
            + "\nold\n"
            + MODULE.END_MARKER
            + "\n\nhuman note after\n"
        )
        updated = MODULE.replace_generated(body, "new")
        self.assertIn("human note before", updated)
        self.assertIn("human note after", updated)
        self.assertIn(f"{MODULE.START_MARKER}\nnew\n{MODULE.END_MARKER}", updated)

    def test_title_cannot_inject_radar_marker(self):
        item = issue(9, "oops <!-- triage-radar:end --> title")
        rendered = MODULE.render_issue(item)
        self.assertNotIn("<!--", rendered)
        self.assertIn("&lt;!--", rendered)

    def test_cluster_members_are_not_repeated_as_regressions(self):
        reports = [
            issue(10, "terminal input routed to wrong terminal"),
            issue(11, "terminal input routed to wrong pane"),
            issue(12, "unrelated enhancement", labels=["enhancement"]),
        ]
        clusters = MODULE.build_clusters(reports)
        excluded = {item["number"] for cluster in clusters for item in cluster["members"]}
        self.assertEqual(MODULE.select_regressions(reports, excluded), [])


class MainSafetyTests(unittest.TestCase):
    def test_wrong_issue_title_fails_closed_before_patch(self):
        api = mock.Mock()
        api.search.side_effect = [[], []]
        api.issue.return_value = {"title": "[RFC] Something else", "body": ""}
        environment = {
            "GH_TOKEN": "token",
            "GH_REPO": "manaflow-ai/cmux",
            "TRIAGE_RADAR_ISSUE": "13512",
        }
        with mock.patch.dict(MODULE.os.environ, environment, clear=True), mock.patch.object(
            MODULE, "GitHub", return_value=api
        ):
            self.assertEqual(MODULE.main(), 1)
        api.update_issue_body.assert_not_called()


class WorkflowSafetyTests(unittest.TestCase):
    def test_workflow_has_narrow_permissions_and_serializes_updates(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("contents: read", workflow)
        self.assertIn("issues: write", workflow)
        self.assertIn("pull-requests: read", workflow)
        self.assertIn("group: triage-radar", workflow)
        self.assertIn('TRIAGE_RADAR_ISSUE: "13512"', workflow)


if __name__ == "__main__":
    unittest.main()
