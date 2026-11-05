"""The whole nightly runs on one Mac mini while vars.CI_NIGHTLY_MINI is set.

Lawrence, 2026-11-04: "we need to just make nightlies build on a single mac mini", and no one cancels nightlies.
Before this, nightly-next run 41900945757 ran on cmux15, cmux7s and GitHub-hosted Ubuntu, and build-nightly-app
sometimes on ultra1. The whole-Mac signing claim on cmux15 then held jobs sent elsewhere (a verify waited 35 min).

With vars.CI_NIGHTLY_MINI (cmux15's light nightly-only runners, `glaeda-nightly-mini`), every job of nightly.yml,
on every attempt, event and picker output, takes one of three labels that only that mini carries
(cmuxterm-hq build-fleet/nightly_mini_policy_test.py):
  - glaeda's signing jobs (the hook's SIGNING_JOBS for nightly.yml, the whole-Mac claim):
    vars.CI_NIGHTLY_SIGN_RUNNER (`glaeda-trusted-next-signing`);
  - build-nightly-app: vars.CI_NIGHTLY_MINI_BUILDER (`glaeda-nightly-mini-builder`, the two warm builders);
  - every other job: vars.CI_NIGHTLY_MINI.
The nightly visual gate needs a GUI session runner, which the mini has not, so it skips in this mode.
"""
from __future__ import annotations

import random
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_nightly_never_blacksmith import JOBS, evaluate, parse_expression, sample  # noqa: E402

MINI, BUILDER, SIGN = "glaeda-nightly-mini", "glaeda-nightly-mini-builder", "glaeda-trusted-next-signing"
MODE = {"vars.CI_NIGHTLY_MINI": MINI, "vars.CI_NIGHTLY_MINI_BUILDER": BUILDER, "vars.CI_NIGHTLY_SIGN_RUNNER": SIGN}
# glaeda scripts/glaeda-cmux-runner-hook SIGNING_JOBS, nightly.yml entries: the jobs that take the whole Mac.
SIGNING = {"promote-nightly-next", "build-sign-notarize-nightly", "recover-nightly-next-notarization",
           "publish-nightly", "publish-nightly-next-github", "publish-nightly-next-github-names",
           "sign-nightly-identity-legacy", "generate-nightly-deltas"}
VISUAL_GATE = {"route-visual-gate-nightly"}
WORKFLOWS = Path(__file__).resolve().parents[1] / ".github/workflows"


def want(name: str) -> str:
    return SIGN if name in SIGNING else BUILDER if name == "build-nightly-app" else MINI


def resolve(source: str, rng: random.Random, extra: dict | None = None) -> tuple[object, dict]:
    if not source.startswith("${{"):
        return source, {}  # a plain label
    expression = source.removeprefix("${{").removesuffix("}}")
    context = {**sample(expression, rng), **MODE, **(extra or {})}
    return evaluate(parse_expression(expression), context), context


class NightlyOneMini(unittest.TestCase):
    def test_every_job_takes_the_nightly_mini(self) -> None:
        rng = random.Random(41900945757)
        failures = {}
        for name, job in JOBS.items():
            if job.get("uses") or name in VISUAL_GATE or name.startswith("visual-gate-") or name == "report-visual-gate-nightly":
                continue
            runs_on = str(job.get("runs-on", ""))
            sources = job["strategy"]["matrix"]["pool"] if runs_on == "${{ matrix.pool }}" else [runs_on]
            for source in sources:
                for _ in range(200):
                    value, context = resolve(source, rng)
                    if value != want(name):
                        failures[name] = (value, {k: v for k, v in context.items() if v and k.startswith(("github", "vars"))})
                        break
        self.assertEqual(sorted(failures), [], "\n".join(f"{k}: {v}" for k, v in sorted(failures.items())))

    def test_the_mode_is_off_without_the_variable(self) -> None:
        # Unset, every job keeps its route: build-nightly-app never asks for the mini's builder label.
        rng = random.Random(7)
        source = str(JOBS["build-nightly-app"]["runs-on"])
        for _ in range(200):
            value, _ = resolve(source, rng, {"vars.CI_NIGHTLY_MINI": "", "vars.CI_NIGHTLY_MINI_BUILDER": ""})
            self.assertNotEqual(value, BUILDER)

    def test_the_visual_gate_skips_on_the_mini(self) -> None:
        # The gate runs on an idle GUI session runner of another Mac; on one mini it does not run.
        condition = str(JOBS["route-visual-gate-nightly"]["if"])
        self.assertIn("vars.CI_NIGHTLY_MINI == ''", condition)

    def test_the_tag_permission_probe_runs_on_the_mini(self) -> None:
        text = (WORKFLOWS / "nightly-tag-permission-probe.yml").read_text(encoding="utf-8")
        runs_on = re.findall(r"^\s+runs-on: (.+)$", text, re.M)
        self.assertTrue(runs_on)
        rng = random.Random(3)
        for source in runs_on:
            value, _ = resolve(source.strip(), rng)
            self.assertEqual(value, MINI, source)


if __name__ == "__main__":
    unittest.main()
