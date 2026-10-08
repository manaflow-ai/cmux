import importlib.util
from pathlib import Path
import unittest
import sys
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("manual_dispatch_guard", ROOT / "scripts/ci/manual_dispatch_guard.py")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def pr(ref="feat/custom-sidebar-templates", sha="6611c69", state="open"):
    return {"state": state, "head": {"ref": ref, "sha": sha, "repo": {"full_name": "manaflow-ai/cmux"}}}


FP = "v1;sha=6611c69;ref=feat/custom-sidebar-templates;cache=r2;release=universal;coverage=full"


class ManualDispatchGuard(unittest.TestCase):
    def test_changes_check_blocks_stale_run_without_cancelling(self):
        env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GH_TOKEN": "test", "GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_REF_NAME": "topic", "GITHUB_SHA": "old", "GITHUB_RUN_ID": "42"}
        with patch.object(module, "GitHub") as constructor:
            api = constructor.return_value
            api.open_pull_requests.return_value = [pr("topic", "new")]
            self.assertEqual(module.main(env, check_only=True), 1)
            api.cancel.assert_not_called()
            api.normal_ci_runs.assert_not_called()
            self.assertEqual(module.main(env), 0)
            api.cancel.assert_called_once_with("42")

    def test_watcher_uses_source_identity_and_full_suite_marker(self):
        fp = FP.replace("6611c69", "same").replace("feat/custom-sidebar-templates", "topic")
        env = {"SOURCE_EVENT_NAME": "workflow_dispatch", "GH_TOKEN": "test", "SOURCE_REPOSITORY": "manaflow-ai/cmux", "SOURCE_REF_NAME": "topic", "SOURCE_SHA": "same", "SOURCE_RUN_ID": "42", "SOURCE_COVERAGE_FINGERPRINT": fp, "GITHUB_EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "wrong"}
        with patch.object(module, "GitHub") as constructor:
            api = constructor.return_value
            api.open_pull_requests.return_value = [pr("topic", "same")]
            api.normal_ci_runs.return_value = [{"event": "pull_request", "head_sha": "same", "status": "in_progress", "full_suite": True, "coverage_fingerprint": fp}]
            self.assertEqual(module.main(env, check_only=True), 1)
            api.cancel.assert_not_called()

    def test_changes_check_fails_open_on_api_error(self):
        env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GH_TOKEN": "test", "GITHUB_REPOSITORY": "manaflow-ai/cmux"}
        with patch.object(module, "GitHub") as constructor:
            constructor.return_value.open_pull_requests.side_effect = OSError("offline")
            self.assertEqual(module.main(env, check_only=True), 0)
            constructor.return_value.cancel.assert_not_called()

    def test_duplicate_dispatch_is_cancelled(self):
        result = module.decide(event="workflow_dispatch", repository="manaflow-ai/cmux", ref_name="feat/custom-sidebar-templates", sha="6611c69", pull_requests=[pr()], normal_ci_runs=[{"id": 42, "event": "pull_request", "head_sha": "6611c69", "status": "in_progress", "full_suite": True, "coverage_fingerprint": FP}], coverage_fingerprint=FP)
        self.assertEqual(result, module.Decision(True, "pull request run covers this head"))

    def test_matching_head_without_normal_ci_run_is_kept(self):
        result = module.decide(event="workflow_dispatch", repository="manaflow-ai/cmux", ref_name="feat/custom-sidebar-templates", sha="6611c69", pull_requests=[pr()])
        self.assertEqual(result, module.Decision(False, "pull request head matches but equivalent CI coverage is not present"))

    def test_cancelled_or_skipped_ci_run_does_not_cover_head(self):
        runs = [{"event": "pull_request", "head_sha": "6611c69", "status": "completed", "conclusion": "cancelled", "full_suite": True, "coverage_fingerprint": FP}, {"event": "pull_request", "head_sha": "6611c69", "status": "completed", "conclusion": "skipped", "full_suite": True, "coverage_fingerprint": FP}]
        self.assertFalse(module.has_covering_ci_run(runs, "6611c69", FP))

    def test_compile_only_marker_does_not_cover_dispatch(self):
        self.assertFalse(module.has_covering_ci_run([{"event": "pull_request", "head_sha": "6611c69", "status": "in_progress", "full_suite": False}], "6611c69", FP))

    def test_compile_only_pr_stays_eligible_for_full_manual_dispatch(self):
        result = module.decide(event="workflow_dispatch", repository="manaflow-ai/cmux", ref_name="feat/custom-sidebar-templates", sha="6611c69", pull_requests=[pr()], coverage_fingerprint=FP, normal_ci_runs=[{"event": "pull_request", "head_sha": "6611c69", "status": "in_progress", "full_suite": False}])
        self.assertFalse(result.cancel)

    def test_unknown_coverage_stays_eligible(self):
        self.assertFalse(module.has_covering_ci_run([{"event": "pull_request", "head_sha": "6611c69", "status": "in_progress", "full_suite": True}], "6611c69", FP))

    def test_fuller_manual_configuration_stays_eligible(self):
        manual = FP.replace("cache=r2", "cache=warp")
        self.assertFalse(module.has_covering_ci_run([{"event": "pull_request", "head_sha": "6611c69", "status": "in_progress", "full_suite": True, "coverage_fingerprint": FP}], "6611c69", manual))

    def test_completed_full_suite_success_covers_head(self):
        self.assertTrue(module.has_covering_ci_run([{"event": "pull_request", "head_sha": "6611c69", "status": "completed", "conclusion": "success", "full_suite": True, "coverage_fingerprint": FP}], "6611c69", FP))

    def test_completed_failed_full_suite_does_not_cover_head(self):
        self.assertFalse(module.has_covering_ci_run([{"event": "pull_request", "head_sha": "6611c69", "status": "completed", "conclusion": "failure", "full_suite": True, "coverage_fingerprint": FP}], "6611c69", FP))

    def test_failed_coverage_marker_is_not_published_as_coverage(self):
        api = module.GitHub("test", "manaflow-ai/cmux")
        with patch.object(api, "_request", side_effect=[{"workflow_runs": [{"id": 7, "display_title": FP}]}, {"jobs": [{"name": "full-suite-coverage", "status": "completed", "conclusion": "failure"}]}]):
            self.assertEqual(api.normal_ci_runs("6611c69")[0]["full_suite"], False)

    def test_marker_reads_fingerprint_from_run_title(self):
        api = module.GitHub("test", "manaflow-ai/cmux")
        with patch.object(api, "_request", side_effect=[{"workflow_runs": [{"id": 7, "display_title": FP}]}, {"jobs": [{"name": "full-suite-coverage", "status": "in_progress"}]}]):
            run = api.normal_ci_runs("6611c69")[0]
        self.assertTrue(run["full_suite"])
        self.assertEqual(run["coverage_fingerprint"], FP)

    def test_changes_marker_requires_completed_successful_changes_job(self):
        api = module.GitHub("test", "manaflow-ai/cmux")
        jobs = [{
            "name": "changes",
            "status": "completed",
            "conclusion": "success",
            "steps": [{
                "name": "Mark full-suite coverage",
                "status": "completed",
                "conclusion": "success",
            }],
        }]
        with patch.object(api, "_request", side_effect=[{"workflow_runs": [{"id": 7, "display_title": FP}]}, {"jobs": jobs}]):
            run = api.normal_ci_runs("6611c69")[0]
        self.assertTrue(run["full_suite"])
        self.assertEqual(run["coverage_fingerprint"], FP)

    def test_changes_marker_does_not_cover_before_changes_succeeds(self):
        for status, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "cancelled")):
            api = module.GitHub("test", "manaflow-ai/cmux")
            jobs = [{
                "name": "changes",
                "status": status,
                "conclusion": conclusion,
                "steps": [{
                    "name": "Mark full-suite coverage",
                    "status": "completed",
                    "conclusion": "success",
                }],
            }]
            with patch.object(api, "_request", side_effect=[{"workflow_runs": [{"id": 7, "display_title": FP}]}, {"jobs": jobs}]):
                run = api.normal_ci_runs("6611c69")[0]
            self.assertFalse(run["full_suite"], (status, conclusion))

    def test_failed_changes_marker_step_does_not_cover(self):
        api = module.GitHub("test", "manaflow-ai/cmux")
        jobs = [{
            "name": "changes",
            "status": "completed",
            "conclusion": "success",
            "steps": [{
                "name": "Mark full-suite coverage",
                "status": "completed",
                "conclusion": "failure",
            }],
        }]
        with patch.object(api, "_request", side_effect=[{"workflow_runs": [{"id": 7, "display_title": FP}]}, {"jobs": jobs}]):
            run = api.normal_ci_runs("6611c69")[0]
        self.assertFalse(run["full_suite"])

    def test_other_sha_or_event_does_not_cover_head(self):
        self.assertFalse(module.has_covering_ci_run([{"event": "workflow_dispatch", "head_sha": "6611c69", "status": "in_progress"}], "6611c69", FP))

    def test_stale_dispatch_is_cancelled(self):
        result = module.decide(event="workflow_dispatch", repository="manaflow-ai/cmux", ref_name="feat/custom-sidebar-templates", sha="7814d8f", pull_requests=[pr()])
        self.assertEqual(result, module.Decision(True, "branch moved past the pull request head"))

    def test_current_branch_without_pr_is_kept(self):
        result = module.decide(event="workflow_dispatch", repository="manaflow-ai/cmux", ref_name="topic", sha="123", pull_requests=[])
        self.assertFalse(result.cancel)

    def test_non_dispatch_is_never_cancelled(self):
        result = module.decide(event="pull_request", repository="manaflow-ai/cmux", ref_name="feat", sha="123", pull_requests=[pr("feat", "123")])
        self.assertFalse(result.cancel)

    def test_closed_or_other_repository_pr_is_ignored(self):
        closed = pr(state="closed")
        other = pr()
        other["head"]["repo"]["full_name"] = "teamleaderleo/cmux"
        result = module.decide(event="workflow_dispatch", repository="manaflow-ai/cmux", ref_name="feat/custom-sidebar-templates", sha="7814d8f", pull_requests=[closed, other])
        self.assertFalse(result.cancel)


if __name__ == "__main__":
    unittest.main()
