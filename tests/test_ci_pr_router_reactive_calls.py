"""Router manifest checks distinguish reactive workflow calls from routed PR callees."""
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("pr_router", ROOT / "scripts/ci/pr_router.py")
assert SPEC and SPEC.loader
pr_router = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pr_router)


class ReactiveWorkflowCalls(unittest.TestCase):
    def test_head_fail_fast_reaction_is_not_a_routed_pr_callee(self) -> None:
        problems = pr_router.check(
            pr_router.load_manifest(),
            pr_router.ENTRY.read_text(encoding="utf-8"),
            pr_router.ENTRY.parent,
        )
        self.assertNotIn(
            "head-fail-fast.yml: pr-router.yml calls it but pr_router.json does not route it",
            problems,
        )

    def test_unknown_reusable_call_still_fails_closed(self) -> None:
        entry = pr_router.ENTRY.read_text(encoding="utf-8") + (
            "\n  accidental-unrouted:\n"
            "    uses: ./.github/workflows/not-routed.yml\n"
        )
        problems = pr_router.check(pr_router.load_manifest(), entry, pr_router.ENTRY.parent)
        self.assertIn(
            "not-routed.yml: pr-router.yml calls it but pr_router.json does not route it",
            problems,
        )


if __name__ == "__main__":
    unittest.main()
