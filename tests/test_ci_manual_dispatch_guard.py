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


class ManualDispatchGuard(unittest.TestCase):
    def test_changes_check_blocks_stale_run_without_cancelling(self):
        env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GH_TOKEN": "test",
               "GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_REF_NAME": "topic",
               "GITHUB_SHA": "old", "GITHUB_RUN_ID": "42"}
        with patch.object(module, "GitHub") as constructor:
            api = constructor.return_value
            api.open_pull_requests.return_value = [pr("topic", "new")]
            self.assertEqual(module.main(env, check_only=True), 1)
            api.cancel.assert_not_called()
            api.normal_ci_runs.assert_not_called()
            self.assertEqual(module.main(env), 0)
            api.cancel.assert_called_once_with("42")

    def test_changes_check_fails_open_on_api_error(self):
        env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GH_TOKEN": "test",
               "GITHUB_REPOSITORY": "manaflow-ai/cmux"}
        with patch.object(module, "GitHub") as constructor:
            constructor.return_value.open_pull_requests.side_effect = OSError("offline")
            self.assertEqual(module.main(env, check_only=True), 0)
            constructor.return_value.cancel.assert_not_called()

    def test_duplicate_dispatch_is_cancelled(self):
        result = module.decide(event="workflow_dispatch", repository="manaflow-ai/cmux",
                               ref_name="feat/custom-sidebar-templates", sha="6611c69",
                               pull_requests=[pr()], normal_ci_runs=[
                                   {"id": 42, "event": "pull_request", "head_sha": "6611c69", "status": "in_progress"}
                               ])
        self.assertEqual(result, module.Decision(True, "pull request run covers this head"))

    def test_matching_head_without_normal_ci_run_is_kept(self):
        result = module.decide(event="workflow_dispatch", repository="manaflow-ai/cmux",
                               ref_name="feat/custom-sidebar-templates", sha="6611c69",
                               pull_requests=[pr()])
        self.assertEqual(result, module.Decision(False, "pull request head matches but its CI run is not present"))

    def test_cancelled_or_skipped_ci_run_does_not_cover_head(self):
        runs = [
            {"event": "pull_request", "head_sha": "6611c69", "status": "completed", "conclusion": "cancelled"},
            {"event": "pull_request", "head_sha": "6611c69", "status": "completed", "conclusion": "skipped"},
        ]
        self.assertFalse(module.has_covering_ci_run(runs, "6611c69"))

    def test_other_sha_or_event_does_not_cover_head(self):
        runs = [{"event": "workflow_dispatch", "head_sha": "6611c69", "status": "in_progress"}]
        self.assertFalse(module.has_covering_ci_run(runs, "6611c69"))

    def test_stale_dispatch_is_cancelled(self):
        result = module.decide(event="workflow_dispatch", repository="manaflow-ai/cmux",
                               ref_name="feat/custom-sidebar-templates", sha="7814d8f",
                               pull_requests=[pr()])
        self.assertEqual(result, module.Decision(True, "branch moved past the pull request head"))

    def test_current_branch_without_pr_is_kept(self):
        result = module.decide(event="workflow_dispatch", repository="manaflow-ai/cmux",
                               ref_name="topic", sha="123", pull_requests=[])
        self.assertFalse(result.cancel)

    def test_non_dispatch_is_never_cancelled(self):
        result = module.decide(event="pull_request", repository="manaflow-ai/cmux",
                               ref_name="feat", sha="123", pull_requests=[pr("feat", "123")])
        self.assertFalse(result.cancel)

    def test_closed_or_other_repository_pr_is_ignored(self):
        closed = pr(state="closed")
        other = pr()
        other["head"]["repo"]["full_name"] = "teamleaderleo/cmux"
        result = module.decide(event="workflow_dispatch", repository="manaflow-ai/cmux",
                               ref_name="feat/custom-sidebar-templates", sha="7814d8f",
                               pull_requests=[closed, other])
        self.assertFalse(result.cancel)


if __name__ == "__main__":
    unittest.main()
