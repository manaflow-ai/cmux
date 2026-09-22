import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / ".github/scripts/review_fabric.py"
POLICY = ROOT / ".github/review-fabric-policy.json"

spec = importlib.util.spec_from_file_location("review_fabric", SCRIPT)
review_fabric = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = review_fabric
spec.loader.exec_module(review_fabric)

HEAD = "a" * 40
OLD_HEAD = "b" * 40


def policy():
    return json.loads(POLICY.read_text(encoding="utf-8"))


def run(
    run_id,
    session_id,
    *,
    head=HEAD,
    capability="frontier",
    role="reviewer",
    status="completed",
    disposition="accept",
):
    return {
        "id": run_id,
        "worker_id": f"worker-{session_id}",
        "session_id": session_id,
        "provider": "provider",
        "harness": "agent-harness",
        "model": "model",
        "role": role,
        "capability_class": capability,
        "head_sha": head,
        "status": status,
        "disposition": disposition,
        "rules_version": "rules-v1",
        "evidence_class": "model-executed",
    }


def finding(
    finding_id,
    run_id,
    *,
    head=HEAD,
    severity="P2",
    disposition="fixed",
    actionable=True,
    published=True,
    verified=True,
    reviewer_at="2026-09-21T12:00:00Z",
    reply_at="2026-09-21T12:01:00Z",
    rationale=None,
):
    item = {
        "id": finding_id,
        "run_id": run_id,
        "head_sha": head,
        "severity": severity,
        "disposition": disposition,
        "actionable": actionable,
        "published": published,
        "verified": verified,
        "latest_reviewer_at": reviewer_at,
        "latest_reply_at": reply_at,
    }
    if rationale is not None:
        item["rationale"] = rationale
    return item


def document(runs, findings=None, *, capture_complete=True, head=HEAD):
    return {
        "schema": review_fabric.RECEIPT_SCHEMA,
        "head_sha": head,
        "capture_complete": capture_complete,
        "runs": runs,
        "findings": findings or [],
    }


class ReviewFabricTests(unittest.TestCase):
    def test_two_independent_sessions_with_frontier_lane_pass(self):
        report = review_fabric.evaluate(
            document([
                run("opus", "session-opus", capability="frontier"),
                run("local", "session-local", capability="local"),
            ]),
            policy(),
        )
        self.assertTrue(report["passed"])
        self.assertEqual(report["counts"]["independent_sessions"], 2)
        self.assertEqual(report["capability_counts"], {"frontier": 1, "local": 1})

    def test_same_session_using_two_models_gets_one_vote(self):
        report = review_fabric.evaluate(
            document([
                run("opus", "same-session", capability="frontier"),
                run("sol", "same-session", capability="frontier"),
            ]),
            policy(),
        )
        self.assertFalse(report["passed"])
        self.assertEqual(report["counts"]["independent_sessions"], 1)
        self.assertTrue(any("1/2" in reason for reason in report["reasons"]))

    def test_frontier_requirement_is_independent_of_total_quorum(self):
        report = review_fabric.evaluate(
            document([
                run("local-a", "session-a", capability="local"),
                run("local-b", "session-b", capability="local"),
            ]),
            policy(),
        )
        self.assertFalse(report["passed"])
        self.assertIn("capability quorum frontier is 0/1", report["reasons"])

    def test_stale_head_receipts_never_count(self):
        report = review_fabric.evaluate(
            document([
                run("old", "session-old", head=OLD_HEAD),
                run("current", "session-current"),
            ]),
            policy(),
        )
        self.assertFalse(report["passed"])
        self.assertEqual(report["stale_run_ids"], ["old"])
        self.assertEqual(report["counts"]["independent_sessions"], 1)

    def test_hold_blocks_even_when_another_lane_accepts(self):
        report = review_fabric.evaluate(
            document([
                run("accept", "session-a"),
                run("hold", "session-b", capability="local", disposition="hold"),
            ]),
            policy(),
        )
        self.assertFalse(report["passed"])
        self.assertTrue(any("blocking disposition hold" in reason for reason in report["reasons"]))

    def test_pending_verified_p1_is_reported_as_blocker(self):
        report = review_fabric.evaluate(
            document(
                [
                    run("opus", "session-opus"),
                    run("sol", "session-sol"),
                ],
                [finding("f1", "opus", severity="P1", disposition="pending", reply_at=None)],
            ),
            policy(),
        )
        self.assertFalse(report["passed"])
        self.assertIn("verified blocker f1 remains pending", report["reasons"])
        self.assertIn("actionable finding f1 remains pending", report["reasons"])

    def test_fixed_finding_requires_reply_after_latest_reviewer_message(self):
        report = review_fabric.evaluate(
            document(
                [
                    run("opus", "session-opus"),
                    run("sol", "session-sol"),
                ],
                [
                    finding(
                        "f1",
                        "opus",
                        disposition="fixed",
                        reviewer_at="2026-09-21T12:02:00Z",
                        reply_at="2026-09-21T12:01:00Z",
                    )
                ],
            ),
            policy(),
        )
        self.assertFalse(report["passed"])
        self.assertTrue(any("lacks a reply after" in reason for reason in report["reasons"]))

    def test_declined_finding_requires_rationale(self):
        report = review_fabric.evaluate(
            document(
                [
                    run("opus", "session-opus"),
                    run("sol", "session-sol"),
                ],
                [finding("f1", "opus", disposition="declined_with_rationale", rationale="")],
            ),
            policy(),
        )
        self.assertFalse(report["passed"])
        self.assertIn("declined finding f1 requires a rationale", report["reasons"])

    def test_non_actionable_or_unpublished_findings_do_not_block(self):
        report = review_fabric.evaluate(
            document(
                [
                    run("opus", "session-opus"),
                    run("sol", "session-sol"),
                ],
                [
                    finding("internal", "opus", disposition="pending", published=False),
                    finding("info", "sol", disposition="pending", actionable=False),
                ],
            ),
            policy(),
        )
        self.assertTrue(report["passed"])

    def test_incomplete_capture_fails_closed(self):
        report = review_fabric.evaluate(
            document(
                [
                    run("opus", "session-opus"),
                    run("sol", "session-sol"),
                ],
                capture_complete=False,
            ),
            policy(),
        )
        self.assertFalse(report["passed"])
        self.assertIn("review receipt capture is incomplete", report["reasons"])

    def test_unknown_finding_run_fails_closed(self):
        report = review_fabric.evaluate(
            document(
                [
                    run("opus", "session-opus"),
                    run("sol", "session-sol"),
                ],
                [finding("f1", "missing")],
            ),
            policy(),
        )
        self.assertFalse(report["passed"])
        self.assertTrue(any("unknown run missing" in reason for reason in report["reasons"]))

    def test_repository_policy_is_provider_neutral(self):
        raw = POLICY.read_text(encoding="utf-8").lower()
        for provider_name in ("greptile", "coderabbit", "anthropic", "openai", "claude", "codex"):
            self.assertNotIn(provider_name, raw)
        configured = policy()
        self.assertEqual(configured["minimum_independent_runs"], 2)
        self.assertEqual(configured["required_capability_classes"], {"frontier": 1})

    def test_ci_executes_review_fabric_contracts(self):
        workflow = (ROOT / ".github/workflows/ci-guards.yml").read_text(encoding="utf-8")
        detector = (ROOT / "scripts/ci/detect_linux_guard_changes.py").read_text(encoding="utf-8")
        self.assertIn("python3 tests/test_review_fabric.py", workflow)
        for path in (
            ".github/review-fabric-policy.json",
            ".github/review-fabric.md",
            ".github/scripts/review_fabric.py",
            "tests/test_review_fabric.py",
        ):
            self.assertIn(f'"{path}"', detector)


if __name__ == "__main__":
    unittest.main()
