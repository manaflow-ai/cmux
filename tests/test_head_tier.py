"""scripts/ci/head_tier.py and its use in the pr router: a draft head runs the cheap tier only."""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import head_tier  # noqa: E402
import pr_router  # noqa: E402


def event(draft: bool, labels: tuple[str, ...] = (), action: str = "synchronize") -> dict:
    return {"action": action, "pull_request": {"draft": draft, "labels": [{"name": n} for n in labels]}}


class TierTests(unittest.TestCase):
    def test_draft_is_cheap(self) -> None:
        self.assertEqual(head_tier.tier("pull_request", event(True))[0], "cheap")

    def test_ready_is_full(self) -> None:
        self.assertEqual(head_tier.tier("pull_request", event(False))[0], "full")

    def test_full_ci_label_makes_a_draft_full(self) -> None:
        self.assertEqual(head_tier.tier("pull_request", event(True, ("full-ci",)))[0], "full")

    def test_switch_off_makes_a_draft_full(self) -> None:
        self.assertEqual(head_tier.tier("pull_request", event(True), "0")[0], "full")

    def test_other_events_and_unreadable_payloads_are_full(self) -> None:
        self.assertEqual(head_tier.tier("push", event(True))[0], "full")
        self.assertEqual(head_tier.tier("pull_request", {})[0], "full")


class RouterTests(unittest.TestCase):
    CALLEES = {
        "heavy.yml": {"types": ["opened", "synchronize", "ready_for_review"]},
        "cheap.yml": {"types": ["opened", "synchronize", "ready_for_review"], "draft": True},
    }

    def test_a_draft_starts_only_draft_callees(self) -> None:
        start, why = pr_router.route(event(True), self.CALLEES, ["a.py"])
        self.assertEqual(start, ["cheap.yml"])
        self.assertIn("ready for review", why["heavy.yml"])

    def test_marking_ready_starts_everything(self) -> None:
        start, _ = pr_router.route(event(False, action="ready_for_review"), self.CALLEES, ["a.py"])
        self.assertEqual(start, ["cheap.yml", "heavy.yml"])

    def test_full_ci_and_the_switch_start_everything_on_a_draft(self) -> None:
        self.assertEqual(pr_router.route(event(True, ("full-ci",)), self.CALLEES, ["a.py"])[0],
                         ["cheap.yml", "heavy.yml"])
        self.assertEqual(pr_router.route(event(True), self.CALLEES, ["a.py"], "0")[0], ["cheap.yml", "heavy.yml"])

    def test_every_real_callee_that_skips_drafts_listens_to_ready_for_review(self) -> None:
        for name, config in pr_router.load_manifest().items():
            if not config.get("draft"):
                self.assertIn("ready_for_review", config["types"], name)


# Workflows whose pull request runs skip a draft head (the tail of the draft tier, after ci.yml and cmux-next.yml).
# Every job of each carries DRAFT_TIER_CONDITION, because a job with `!cancelled()` or `always()` runs even when the
# job it needs was skipped, so gating only the root jobs would not gate those. A job that is skipped reports
# "skipped", which a required check accepts; marking the draft ready (`ready_for_review`) runs them on the same head.
# Value: the pull request event the workflow listens to. Anything else with a pull_request trigger is kept on drafts
# (cheap guards, deploys, closed-event cleanups): the list is in the pull request body.
GATED = {
    "auth-refresh-tests.yml": "pull_request",
    "backend-migrations.yml": "pull_request_target",
    "chief-evals.yml": "pull_request",
    "cmux-mobile-ffi.yml": "pull_request",
    "cmux-next-ios-kit.yml": "pull_request",
    "cmux-next-motion-golden.yml": "pull_request",
    "cmux-next-pr-autofix.yml": "pull_request",
    "cmux-next-react-doctor.yml": "pull_request",
    "cmux-next-shell-integration.yml": "pull_request",
    "cmux-next-terminal.yml": "pull_request",
    "cmux-rd-windows.yml": "pull_request",
    "cmux-tui-sdks.yml": "pull_request",
    "cmux-tui-spec.yml": "pull_request",
    "cmux-tui-windows-check.yml": "pull_request",
    "cmux-vnc.yml": "pull_request",
    "fleet-test-compile.yml": "pull_request",
    "ios-e2e.yml": "pull_request",
    "ios-reliability-matrix.yml": "pull_request",
    "ios-review-gate.yml": "pull_request",
    "iroh-v2.yml": "pull_request",
    "measure-swift-typecheck.yml": "pull_request",
    "relay-tls.yml": "pull_request",
    "rust-workspaces.yml": "pull_request",
    "signing-keychain-macos.yml": "pull_request",
    "swift-linux-packages.yml": "pull_request",
    "terminal-hang-diagnostics.yml": "pull_request",
    "test-ios.yml": "pull_request",
}
# backend-migrations applies a migration when a person adds the `backend:apply-migrations` label, draft or not.
KEEP_ON_LABELED = {"backend-migrations.yml"}
# Jobs whose own `if:` starts with `github.event_name != 'pull_request'`: they never run on a pull request, so a
# draft term would only change what tests/test_cmux_next_pr_autofix_push_gate.py evaluates.
NEVER_ON_PULL_REQUEST = {("cmux-next-pr-autofix.yml", "push")}


def draft_tier_condition(event_name: str, keep_labeled: bool = False) -> str:
    """The job-level expression equal to head_tier.tier(...) == "full" (the same four reasons, in the same order)."""
    parts = [
        f"github.event_name != '{event_name}'",
        "github.event.pull_request.draft != true",
        "contains(github.event.pull_request.labels.*.name, 'full-ci')",
        "(vars.CI_DRAFT_CHEAP_TIER || '1') == '0'",
    ]
    if keep_labeled:
        parts.insert(1, "github.event.action == 'labeled'")
    return "(" + " || ".join(parts) + ")"


def _job_ifs(text: str) -> dict:
    """job id -> the text of its job-level `if:` (None when it has none), by indentation, so comments survive."""
    out: dict = {}
    job = None
    in_jobs = False
    for line in text.splitlines():
        if line.startswith("jobs:"):
            in_jobs = True
            continue
        if not in_jobs:
            continue
        if line and not line.startswith((" ", "#")):
            break
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*(#.*)?$", line)
        if match:
            job = match.group(1)
            out[job] = None
        elif job and line.startswith("    if:"):
            out[job] = line[len("    if:"):].strip()
        elif job and out.get(job) in (">", ">-", "|", "|-") and line.startswith("      "):
            out[job] += " " + line.strip()  # the rest of a block-scalar if:
    return out


class GatedWorkflowTests(unittest.TestCase):
    """Regression test (run by hand, not a CI job): every gated workflow skips a draft head on every job."""

    WORKFLOWS = ROOT / ".github" / "workflows"

    def test_every_job_carries_the_condition_and_the_trigger_lists_ready_for_review(self) -> None:
        for name, event_name in GATED.items():
            text = (self.WORKFLOWS / name).read_text()
            expected = draft_tier_condition(event_name, name in KEEP_ON_LABELED)
            jobs = _job_ifs(text)
            self.assertTrue(jobs, name)
            for job, condition in jobs.items():
                if (name, job) in NEVER_ON_PULL_REQUEST:
                    self.assertIn("github.event_name != 'pull_request'", condition or "", f"{name}: job {job}")
                    continue
                self.assertIsNotNone(condition, f"{name}: job {job} has no if:")
                self.assertIn(expected, condition, f"{name}: job {job}")
            block = re.search(rf"^  {event_name}:\n((?:    .*\n|\s*\n)*)", text, re.M)
            self.assertIsNotNone(block, f"{name}: no {event_name} trigger")
            types = re.search(r"^    types:\s*(\[[^\]]*\]|(?:\n      - .*)+)", block.group(1), re.M)
            self.assertIsNotNone(types, f"{name}: the trigger lists no types")
            self.assertIn("ready_for_review", types.group(1), name)

    def test_the_condition_matches_head_tier_for_every_input(self) -> None:
        """Evaluate the expression's four terms against head_tier.tier over all combinations."""
        for event_name in ("pull_request", "pull_request_target"):
            for draft in (True, False):
                for labels in ((), ("full-ci",), ("other",)):
                    for switch in ("1", "0"):
                        ev = event(draft, labels)
                        full = head_tier.tier(event_name, ev, switch)[0] == "full"
                        runs = (
                            draft is not True
                            or "full-ci" in labels
                            or switch == "0"
                        )
                        self.assertEqual(full, runs, (event_name, draft, labels, switch))


if __name__ == "__main__":
    unittest.main()
