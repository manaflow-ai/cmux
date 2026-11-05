#!/usr/bin/env python3
"""nightly-next's signing and publishing jobs sign on cmux15 first.

Lawrence, 2026-11-04: "reserve cmux15". A signing job takes the whole mini (glaeda's exclusive
class). On a shared PR mini's nightly slot it had to drain every running PR and DEV job first, for
up to an hour, and was then refused. cmux15 is already nightly-only and runs no PR or DEV build, and
glaeda's runner.trustedNextSigning gives its trusted main runners the label
glaeda-trusted-next-signing and admits exactly nightly.yml's signing jobs on the nightly-next push
there (teamleaderleo/glaeda scripts/glaeda-cmux-runner-hook TRUSTED_NEXT_SIGNING).

1. On a nightly-next push, every nightly.yml signing job (signing_runner.SIGNING_JOBS) takes its pick's pin on
   the pick's attempt, which names only the signer's runners, and otherwise the signer's label,
   glaeda-trusted-next-signing. The label is a literal: no repository variable chooses where signing secrets go,
   so a stale or drifted CI_NIGHTLY_SIGN_RUNNER cannot move them.
2. Any other event or ref (a dispatch, main's schedule) takes the same route: glaeda admits only the exact
   nightly-next push on the signer, so such a job is refused and fails closed rather than reaching a shared mini.
3. One-mini mode (vars.CI_NIGHTLY_MINI set, tests/test_nightly_one_mini.py) overrides 2: Lawrence,
   2026-11-04, the whole nightly builds on one Mac mini, so every event signs on the signer's label.
4. No signing job, the GitHub-release uploads (publish-nightly-next-github and its -names twin) included, ever
   resolves to a shared label (a nightly slot, side, root or std pool, the nightly-only pool) on any event or
   attempt: those run on minis whose other runners take pull request jobs as the same user. The uploads hold the
   release App key, so they stay on the signer (run 41900945757's upload held cmux15 whole while the next signs
   waited; that contention remains). promote-nightly-next keeps its earlier route: it runs only on a dispatch of
   main, which the signer's hook refuses, and main's own nightly.yml routes it there.
"""

from __future__ import annotations

import json
import random
import re
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

DRIFTED = ("glaeda-nightly-std-xcode-26.6", "glaeda-side-std-xcode-26.6")
LABEL = "glaeda-trusted-next-signing"
# Upload-only exclusive publishers: they hold the release App key and sign nothing, so they stay off the signer.
UPLOADS = ("publish-nightly-next-github", "publish-nightly-next-github-names")
# signing_runner.SIGNING_JOBS names the keychain jobs; promote-nightly-next keeps its earlier route
# (test_promote_keeps_its_earlier_route)
JOBS = tuple(name for name in SIGNING_JOBS["nightly.yml"] if name not in UPLOADS)
# The push branch these routes had: it came before the pick, so a push never used the pick's pin.
PREFIX = "github.event_name == 'push' && github.ref == 'refs/heads/nightly-next' && "
PIN = '["glaeda-trusted-next-signing","glaeda-runner-cmux15-glaeda-2"]'


def route(name: str, context: dict) -> object:
    source = manaflow_route(name).strip()
    return evaluate(parse_expression(source.removeprefix("${{").removesuffix("}}").strip()), context)


class SigningOnCmux15Test(unittest.TestCase):
    def test_a_nightly_next_push_takes_the_pick_then_the_signer(self) -> None:
        self.assertEqual(len(JOBS), 5)
        rng = random.Random(15)
        for name in JOBS:
            source = manaflow_route(name)
            self.assertNotIn(PREFIX, source, name)
            for _ in range(200):
                context = never_blacksmith.sample(source, rng)
                context.update({"github.event_name": "push", "github.ref": "refs/heads/nightly-next",
                                "github.ref_name": "nightly-next", "vars.CI_NIGHTLY_MINI": "",
                                "vars.CI_NIGHTLY_SIGN_RUNNER": rng.choice((LABEL, "", *DRIFTED)), "github.run_attempt": 1})
                outputs = [ref for ref in context if ref.endswith((".outputs.sign_owned", ".outputs.sign_owned_pool"))]
                for ref in context:
                    if ref.endswith(".outputs.attempt"):
                        context[ref] = 1
                # The pick's pin wins: it names only the signer's runners.
                for ref in outputs:
                    context[ref] = PIN if ref.endswith(".outputs.sign_owned") else LABEL
                expected = json.loads(PIN) if any(ref.endswith(".outputs.sign_owned") for ref in outputs) else LABEL
                with self.subTest(job=name, picked=True):
                    self.assertEqual(route(name, context), expected)
                # No pick: the signer's label.
                for ref in outputs:
                    context[ref] = ""
                with self.subTest(job=name, picked=False):
                    self.assertEqual(route(name, context), LABEL)

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
                                    "vars.CI_NIGHTLY_SIGN_RUNNER": rng.choice(("", LABEL, *DRIFTED)),
                                    "vars.CI_NIGHTLY_MINI": ""})
                    expected = evaluate(parse_expression(
                        earlier.strip().removeprefix("${{").removesuffix("}}").strip()), context)
                    with self.subTest(job=name, event=event, ref=ref):
                        self.assertEqual(route(name, context), expected)
                    # One-mini mode: every event signs on the one nightly mini.
                    context.update({"vars.CI_NIGHTLY_SIGN_RUNNER": rng.choice((LABEL, "", *DRIFTED)),
                                    "vars.CI_NIGHTLY_MINI": "glaeda-nightly-mini"})
                    with self.subTest(job=name, event=event, ref=ref, mode="one-mini"):
                        self.assertEqual(route(name, context), LABEL)

    def test_the_release_uploads_stay_on_the_signer(self) -> None:
        for name in UPLOADS:
            source = manaflow_route(name)
            with self.subTest(job=name):
                self.assertTrue(source.rstrip(" }").endswith(
                    "needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && "
                    "needs.pick-nightly-sign-runner.outputs.sign_owned_pool || "
                    "'glaeda-trusted-next-signing'"), source)

    def test_no_signing_job_ever_resolves_to_a_shared_label(self) -> None:
        # The pickers offer only the signer's label (test_ci_signing_owned_mac), so their outputs are a signer pin or
        # empty; every shared variable holds a shared label, and CI_NIGHTLY_SIGN_RUNNER and CI_NIGHTLY_SIGNING_POOL may
        # have drifted to one. Every event, ref and attempt still ends on the signer.
        shared = re.compile(r"glaeda-(?:aws-)?(?:nightly|side|root|gui|session|fast|dev)-|glaeda-(?:xl|std|light)-xcode-")
        rng = random.Random(20261104)
        for name in SIGNING_JOBS["nightly.yml"]:
            with self.subTest(job=name):
                self.assertNotRegex(manaflow_route(name), r"vars\.CI_NIGHTLY_SIGN(?:ING_POOL|_RUNNER)\b")
        # promote-nightly-next is left out: it runs only on a workflow_dispatch of main, which the signer's hook
        # refuses (trusted_refusal admits push and schedule), and main's own nightly.yml routes it; this file keeps
        # its earlier route (test_promote_keeps_its_earlier_route).
        for name in SIGNING_JOBS["nightly.yml"]:
            source = manaflow_route(name)
            for _ in range(400):
                context = never_blacksmith.sample(source, rng)
                for ref in context:
                    if ref.endswith(".outputs.sign_owned"):
                        context[ref] = rng.choice((PIN, ""))
                    elif ref.endswith(".outputs.sign_owned_pool"):
                        context[ref] = rng.choice((LABEL, ""))
                # A stale or drifted variable must not choose the label: both may hold a shared one.
                context.update({"vars.CI_NIGHTLY_SIGN_RUNNER": rng.choice((LABEL, "", *DRIFTED)),
                                "vars.CI_NIGHTLY_MINI": rng.choice(("glaeda-nightly-mini", "")),
                                "vars.CI_NIGHTLY_SIGNING_POOL": rng.choice((LABEL, "", *DRIFTED)),
                                "vars.CI_NIGHTLY_NEXT_BUILD_RUNNER": "glaeda-nightly-std-xcode-26.6",
                                "vars.CI_SIDE_LANE_RUNNER": "glaeda-side-std-xcode-26.6",
                                "vars.CI_NIGHTLY_ONLY_RUNNER": "glaeda-nightly-only-m4pro"})
                value = route(name, context)
                labels = value if isinstance(value, list) else [value]
                with self.subTest(job=name, context=context):
                    self.assertTrue(labels)
                    for label in labels:
                        self.assertFalse(shared.match(str(label)), label)
                        self.assertTrue(label == LABEL or str(label).startswith("glaeda-runner-cmux15-"), label)

    def test_promote_keeps_its_earlier_route(self) -> None:
        self.assertEqual(manaflow_route("promote-nightly-next").strip(),
                         "${{  vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY_SIGN_RUNNER || "
                         "github.event_name == 'push' && github.ref == 'refs/heads/nightly-next' && "
                         "vars.CI_NIGHTLY_SIGN_RUNNER || vars.CI_NIGHTLY_NEXT_BUILD_RUNNER || "
                         "'glaeda-nightly-std-xcode-26.6' }}")


if __name__ == "__main__":
    unittest.main()
