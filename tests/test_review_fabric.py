import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / ".github/scripts/review_fabric.py"
POLICY = ROOT / ".github/review-fabric-policy.json"

sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import workflow_guard_groups  # noqa: E402

spec = importlib.util.spec_from_file_location("review_fabric", SCRIPT)
review_fabric = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = review_fabric
spec.loader.exec_module(review_fabric)

HEAD = "a" * 40
OLD_HEAD = "b" * 40


def policy():
    return json.loads(POLICY.read_text(encoding="utf-8"))


def _guard_router():
    """The Linux guard router, imported the way CI invokes it.

    It lives next to its own imports under scripts/ci, so that directory has to
    be on sys.path for `from workflow_guard_groups import ...` to resolve.
    """
    guard_dir = str(ROOT / "scripts/ci")
    if guard_dir not in sys.path:
        sys.path.insert(0, guard_dir)
    router_path = ROOT / "scripts/ci/detect_linux_guard_changes.py"
    router_spec = importlib.util.spec_from_file_location(
        "detect_linux_guard_changes", router_path
    )
    router = importlib.util.module_from_spec(router_spec)
    router_spec.loader.exec_module(router)
    return router


def _groups_for_path(path):
    """Which workflow-guard-tests groups own `path`, or None if unowned."""
    guard_dir = str(ROOT / "scripts/ci")
    if guard_dir not in sys.path:
        sys.path.insert(0, guard_dir)
    from workflow_guard_groups import groups_for_path

    return groups_for_path(path)


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

    def test_capability_quorum_is_independent_of_run_order_within_session(self):
        first = document([
            run("local-a", "session-a", capability="local"),
            run("frontier-a", "session-a", capability="frontier"),
            run("local-b", "session-b", capability="local"),
        ])
        second = document([
            run("frontier-a", "session-a", capability="frontier"),
            run("local-a", "session-a", capability="local"),
            run("local-b", "session-b", capability="local"),
        ])

        first_report = review_fabric.evaluate(first, policy())
        second_report = review_fabric.evaluate(second, policy())
        self.assertTrue(first_report["passed"])
        self.assertTrue(second_report["passed"])
        self.assertEqual(first_report["counts"]["independent_sessions"], 2)
        self.assertEqual(second_report["counts"]["independent_sessions"], 2)
        self.assertEqual(first_report["capability_counts"], {"frontier": 1, "local": 2})
        self.assertEqual(second_report["capability_counts"], {"frontier": 1, "local": 2})

    def test_unavailable_completed_run_does_not_count_toward_quorum(self):
        report = review_fabric.evaluate(
            document([
                run(
                    "unavailable",
                    "session-unavailable",
                    capability="frontier",
                    disposition="unavailable",
                ),
                run("local", "session-local", capability="local"),
            ]),
            policy(),
        )
        self.assertFalse(report["passed"])
        self.assertEqual(report["counts"]["independent_sessions"], 1)
        self.assertEqual(report["counts"]["eligible_runs"], 1)
        self.assertEqual(report["capability_counts"], {"local": 1})
        self.assertTrue(any("1/2" in reason for reason in report["reasons"]))
        self.assertIn("capability quorum frontier is 0/1", report["reasons"])

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

    def test_commit_identities_must_be_lowercase_40_hex(self):
        cases = []

        bad_receipt = document([
            run("opus", "session-opus"),
            run("sol", "session-sol"),
        ], head="g" * 40)
        for item in bad_receipt["runs"]:
            item["head_sha"] = "g" * 40
        cases.append(bad_receipt)

        bad_run = document([
            run("opus", "session-opus", head="z" * 40),
            run("sol", "session-sol"),
        ])
        cases.append(bad_run)

        bad_finding = document(
            [
                run("opus", "session-opus"),
                run("sol", "session-sol"),
            ],
            [finding("f1", "opus", head="A" * 40)],
        )
        cases.append(bad_finding)

        for index, receipt in enumerate(cases):
            with self.subTest(index=index):
                report = review_fabric.evaluate(receipt, policy())
                self.assertFalse(report["passed"])
                self.assertTrue(
                    any("40-hex commit SHA" in reason for reason in report["reasons"]),
                    report["reasons"],
                )

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
        self.assertIn("python3 tests/test_review_fabric.py", workflow)

        # The group that actually runs the contracts, read out of
        # ci-guards.yml. Deriving it keeps this test correct if the step ever
        # moves to another group; naming a group here would fail that refactor.
        owners = workflow_guard_groups.direct_path_owners(workflow)
        contract_groups = owners.get("tests/test_review_fabric.py")
        self.assertTrue(
            contract_groups,
            "no group-conditioned step in ci-guards.yml runs tests/test_review_fabric.py",
        )

        # #13775 made the guard routes derived rather than literal: a path now
        # reaches this suite through PATH_OWNERS or through ci-guards.yml's own
        # `run:` lines, so grepping the router for the path text says nothing
        # about whether the path is routed. Ask the router instead.
        routes = _guard_router()
        for path in (
            ".github/review-fabric-policy.json",
            ".github/review-fabric.md",
            ".github/scripts/review_fabric.py",
            "tests/test_review_fabric.py",
        ):
            with self.subTest(path=path):
                decision = routes.classify(
                    [path], event="pull_request", macos="false"
                )
                self.assertTrue(
                    decision["linux_guard_tests"],
                    f"editing {path} must run the workflow-guard-tests lane",
                )
                # classify_test_groups falls open to every group for a path the
                # manifest does not know, so asserting on its output alone would
                # pass even if ownership were dropped. Assert the ownership
                # itself, against the group ci-guards.yml says runs the
                # contracts rather than a group name pinned here.
                routed = _groups_for_path(path)
                self.assertIsNotNone(
                    routed, f"{path} has no guard-group owner; routing fell open"
                )
                self.assertTrue(
                    contract_groups & set(routed),
                    f"{path} does not route the group that runs the review fabric "
                    f"contracts: routed={sorted(routed)} contracts={sorted(contract_groups)}",
                )


if __name__ == "__main__":
    unittest.main()
