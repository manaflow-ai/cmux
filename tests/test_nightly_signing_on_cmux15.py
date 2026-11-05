#!/usr/bin/env python3
"""nightly-next's signing and publishing jobs sign on cmux15 first.

Lawrence, 2026-11-04: "reserve cmux15". A signing job takes the whole mini (glaeda's exclusive
class). On a shared PR mini's nightly slot it had to drain every running PR and DEV job first, for
up to an hour, and was then refused. cmux15 is already nightly-only and runs no PR or DEV build, and
glaeda's runner.trustedNextSigning gives its trusted main runners the label
glaeda-trusted-next-signing and admits exactly nightly.yml's signing jobs on the nightly-next push
there (teamleaderleo/glaeda scripts/glaeda-cmux-runner-hook TRUSTED_NEXT_SIGNING).

1. On a nightly-next push, every nightly.yml job glaeda gives the exclusive class (SIGNING_JOBS)
   routes to vars.CI_NIGHTLY_SIGN_RUNNER when it is set (glaeda-trusted-next-signing once cmux15
   carries the label), whatever the pickers say. Unset, the job keeps its earlier route, so this
   lands before the glaeda hook reaches cmux15 and the variable is the switch and the rollback.
2. Any other event or ref (a dispatch, main's schedule) keeps the job's earlier route: glaeda admits
   only the nightly-next push there, so the route never sends it a job it would refuse.
3. One-mini mode (vars.CI_NIGHTLY_MINI set, tests/test_nightly_one_mini.py) overrides 2: Lawrence,
   2026-11-04, the whole nightly builds on one Mac mini, so every event signs on CI_NIGHTLY_SIGN_RUNNER.
"""

from __future__ import annotations

import random
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_ci_fork_runner_routing import parse_expression  # noqa: E402
from test_nightly_trusted_routing import evaluate  # noqa: E402
import test_nightly_never_blacksmith as never_blacksmith  # noqa: E402
from test_nightly_never_blacksmith import manaflow_route  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
from signing_runner import SIGNING_JOBS  # noqa: E402

LABEL = "glaeda-trusted-next-signing"
# signing_runner.SIGNING_JOBS names the keychain jobs; promote-nightly-next holds a release key too (glaeda SIGNING_JOBS)
JOBS = ("promote-nightly-next", *SIGNING_JOBS["nightly.yml"])
PREFIX = "github.event_name == 'push' && github.ref == 'refs/heads/nightly-next' && vars.CI_NIGHTLY_SIGN_RUNNER || "


def route(name: str, context: dict) -> object:
    source = manaflow_route(name).strip()
    return evaluate(parse_expression(source.removeprefix("${{").removesuffix("}}").strip()), context)


class SigningOnCmux15Test(unittest.TestCase):
    def test_a_nightly_next_push_signs_on_cmux15_first(self) -> None:
        self.assertEqual(len(JOBS), 8)
        rng = random.Random(15)
        for name in JOBS:
            source = manaflow_route(name)
            self.assertIn(PREFIX, source, name)
            for _ in range(200):
                context = never_blacksmith.sample(source, rng)
                context.update({"github.event_name": "push", "github.ref": "refs/heads/nightly-next",
                                "github.ref_name": "nightly-next"})
                context["vars.CI_NIGHTLY_SIGN_RUNNER"] = LABEL
                with self.subTest(job=name, context=context):
                    self.assertEqual(route(name, context), LABEL)
                # unset: the earlier route, so the switch is off until cmux15 has the label
                context["vars.CI_NIGHTLY_SIGN_RUNNER"] = ""
                earlier = source.replace(PREFIX, "").strip().removeprefix("${{").removesuffix("}}").strip()
                self.assertEqual(route(name, context), evaluate(parse_expression(earlier), context))

    def test_other_events_keep_their_earlier_route(self) -> None:
        rng = random.Random(16)
        for name in JOBS:
            source = manaflow_route(name)
            earlier = source.replace(PREFIX, "")
            for event, ref in (("workflow_dispatch", "refs/heads/nightly-next"), ("schedule", "refs/heads/main"),
                               ("push", "refs/heads/main")):
                for _ in range(50):
                    context = never_blacksmith.sample(source, rng)
                    context.update({"github.event_name": event, "github.ref": ref,
                                    "github.ref_name": ref.removeprefix("refs/heads/"),
                                    "vars.CI_NIGHTLY_SIGN_RUNNER": rng.choice(("", LABEL)),
                                    "vars.CI_NIGHTLY_MINI": ""})
                    expected = evaluate(parse_expression(
                        earlier.strip().removeprefix("${{").removesuffix("}}").strip()), context)
                    with self.subTest(job=name, event=event, ref=ref):
                        self.assertEqual(route(name, context), expected)
                        self.assertNotEqual(route(name, context), LABEL)
                    # One-mini mode: every event signs on the one nightly mini.
                    context.update({"vars.CI_NIGHTLY_SIGN_RUNNER": LABEL, "vars.CI_NIGHTLY_MINI": "glaeda-nightly-mini"})
                    with self.subTest(job=name, event=event, ref=ref, mode="one-mini"):
                        self.assertEqual(route(name, context), LABEL)


if __name__ == "__main__":
    unittest.main()
