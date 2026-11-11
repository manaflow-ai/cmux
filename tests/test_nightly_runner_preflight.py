#!/usr/bin/env python3
"""scripts/ci/nightly_runner_preflight.py: a nightly fails in minutes when a label it would wait on has no online
runner, and only on proof (a fresh, complete census).

2026-11-10: CI_NIGHTLY_MINI=cmux-lawrence-2-light, CI_NIGHTLY_MINI_BUILDER=cmux-lawrence-2 and
CI_NIGHTLY_SIGN_RUNNER=cmux-lawrence-2 (set about 21:31Z); that host's runners went offline at 00:45Z and the nightly
sat queued for 3+ h while the dedicated nightly Macs were idle. The census rows below are that night's, trimmed.
"""
from __future__ import annotations

import base64
import datetime as dt
import gzip
import json
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import nightly_runner_preflight as preflight  # noqa: E402

sys.path.insert(0, str(ROOT / "tests"))
from nightly_workflow_text import expand  # noqa: E402

NOW = dt.datetime(2026, 11, 11, 1, 40, tzinfo=dt.timezone.utc)


def runner(name: str, status: str, *labels: str) -> dict:
    return {"name": name, "status": status, "busy": False, "labels": [{"name": l} for l in labels]}


ROWS = [
    runner("cmux15-glaeda-nightly-only-3", "online", "glaeda-nightly-only-m4pro", "glaeda-nightly-mini"),
    runner("cmux7s-mac-mini-glaeda-nightly-only-3", "online", "glaeda-nightly-only-m4pro", "glaeda-nightly-mini"),
    runner("cmux15-glaeda-nightly-only-1", "online", "glaeda-nightly-only-m4pro-builder"),
    runner("cmux15-glaeda", "online", "glaeda-trusted-next-signing"),
    runner("cmux-lawrence-2", "offline", "glaeda-trusted-next-signing", "glaeda-nightly-mini-builder", "cmux-lawrence-2"),
    runner("cmux-lawrence-2-light-1", "offline", "cmux-lawrence-2-light"),
    runner("cmux-lawrence-2-light-2", "offline", "cmux-lawrence-2-light"),
]


def census(rows=ROWS, *, at: dt.datetime = NOW - dt.timedelta(minutes=3), complete: bool = True,
           repository: str = "manaflow-ai/cmux") -> str:
    doc = {"schema": "runner-state/v1", "repository": repository, "complete": complete,
           "generated_at": at.strftime("%Y-%m-%dT%H:%M:%S.%fZ"), "repository_runners": rows[:4],
           "runner_groups": {"glaeda-minis": rows[4:]}, "scale_sets": {}}
    return base64.b64encode(gzip.compress(json.dumps(doc).encode())).decode()


def env(**overrides) -> dict:
    out = {"CI_RUNNER_STATE": census(), "CI_NIGHTLY_ONLY_RUNNER": "glaeda-nightly-only-m4pro",
           "GITHUB_REF": "refs/heads/nightly-next", "GITHUB_EVENT_NAME": "push"}
    out.update(overrides)
    return out


class Preflight(unittest.TestCase):
    def test_the_2026_11_10_variables_fail_with_each_var_and_its_fix(self) -> None:
        ok, lines = preflight.judge(env(CI_NIGHTLY_MINI="cmux-lawrence-2-light", CI_NIGHTLY_MINI_BUILDER="cmux-lawrence-2",
                                        CI_NIGHTLY_SIGN_RUNNER="cmux-lawrence-2"), NOW)
        self.assertFalse(ok)
        errors = [l for l in lines if l.startswith("::error")]
        self.assertEqual(len(errors), 2, lines)
        for name in ("CI_NIGHTLY_MINI=cmux-lawrence-2-light", "CI_NIGHTLY_MINI_BUILDER=cmux-lawrence-2"):
            self.assertTrue(any(name in l for l in errors), name)
        self.assertIn("gh variable delete CI_NIGHTLY_MINI -R manaflow-ai/cmux", errors[0])
        self.assertIn("glaeda-nightly-only-m4pro", errors[0])
        self.assertIn("all 2 runners that carry it are offline", errors[0])

    def test_the_default_route_on_the_dedicated_macs_passes(self) -> None:
        ok, lines = preflight.judge(env(CI_NIGHTLY_SIGN_RUNNER="glaeda-trusted-next-signing"), NOW)
        self.assertTrue(ok, lines)
        self.assertIn("CI_NIGHTLY_ONLY_RUNNER=glaeda-nightly-only-m4pro: 2 of 2 runners online", lines)
        ok, lines = preflight.judge(env(CI_NIGHTLY_ONLY_RUNNER=""), NOW)
        self.assertTrue(ok, lines)
        self.assertIn("the default label glaeda-nightly-only-m4pro: 2 of 2 runners online", lines)

    def test_a_label_no_runner_carries_fails(self) -> None:
        ok, lines = preflight.judge(env(CI_NIGHTLY_MINI="cmux-nowhere"), NOW)
        self.assertFalse(ok)
        self.assertIn("no runner registered with manaflow-ai/cmux carries it", lines[0])

    def test_the_dedicated_macs_all_offline_fails(self) -> None:
        rows = [runner(r["name"], "offline", *[l["name"] for l in r["labels"]]) for r in ROWS]
        ok, lines = preflight.judge(env(CI_RUNNER_STATE=census(rows)), NOW)
        self.assertFalse(ok)
        self.assertIn("bring the runners of glaeda-nightly-only-m4pro back", lines[0])

    def test_the_builder_counts_only_on_its_route_and_the_signer_never(self) -> None:
        # Without CI_NIGHTLY_MINI build-nightly-app never reads CI_NIGHTLY_MINI_BUILDER; the cache-seed schedule builds
        # no app; CI_NIGHTLY_SIGN_RUNNER routes only the promote dispatch, which this preflight skips.
        quiet = env(CI_NIGHTLY_MINI_BUILDER="cmux-lawrence-2", CI_NIGHTLY_SIGN_RUNNER="cmux-lawrence-2")
        self.assertTrue(preflight.judge(quiet, NOW)[0])
        mini = {**quiet, "CI_NIGHTLY_MINI": "glaeda-nightly-only-m4pro"}
        ok, lines = preflight.judge(mini, NOW)
        self.assertFalse(ok)
        self.assertTrue(any("CI_NIGHTLY_MINI_BUILDER=cmux-lawrence-2" in l for l in lines))
        self.assertFalse(any("CI_NIGHTLY_SIGN_RUNNER" in l for l in lines))
        seed = {**mini, "GITHUB_EVENT_NAME": "schedule", "NIGHTLY_SCHEDULE": "17 */6 * * *"}
        self.assertTrue(preflight.judge(seed, NOW)[0])
        self.assertFalse(preflight.judge({**seed, "NIGHTLY_SCHEDULE": "47 8 * * *"}, NOW)[0])

    def test_no_proof_never_fails(self) -> None:
        bad = env(CI_NIGHTLY_MINI="cmux-lawrence-2-light")
        for raw, why in ((census(at=NOW - dt.timedelta(minutes=45)), "min old"), ("", "is empty"),
                         ("not base64!", "does not decode"), (census(complete=False), "incomplete"),
                         (census(repository="manaflow-ai/other"), "not a runner-state/v1 census")):
            with self.subTest(why=why):
                ok, lines = preflight.judge({**bad, "CI_RUNNER_STATE": raw}, NOW)
                self.assertTrue(ok)
                self.assertTrue(lines[0].startswith("::warning") and why in lines[0], lines)

    def test_hosted_and_blacksmith_labels_are_not_judged(self) -> None:
        for label in ("macos-26", "ubuntu-24.04", "blacksmith-6vcpu-macos-26"):
            with self.subTest(label=label):
                ok, lines = preflight.judge(env(CI_NIGHTLY_MINI=label, CI_RUNNER_STATE=""), NOW)
                self.assertTrue(ok)
                self.assertNotIn("::warning", "".join(lines))


class Wiring(unittest.TestCase):
    JOBS = yaml.safe_load(expand((ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")))["jobs"]

    def test_decide_waits_for_the_preflight_which_never_runs_on_what_it_judges(self) -> None:
        job = self.JOBS["runner-preflight"]
        self.assertEqual(self.JOBS["decide"]["needs"], "runner-preflight")
        self.assertEqual(job["if"], self.JOBS["decide"]["if"], "the preflight runs exactly when decide would")
        self.assertEqual(job["runs-on"], "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'ubuntu-24.04' }}")
        self.assertNotIn("vars.", job["runs-on"])
        self.assertEqual(job["permissions"], {})
        self.assertLessEqual(job["timeout-minutes"], 5)
        text = json.dumps(job)
        self.assertNotIn("secrets.", text)
        self.assertNotRegex(text, r"cancel|gh run|actions/runs")
        step_env = job["steps"][-1]["env"]
        for name in ("CI_RUNNER_STATE", "CI_NIGHTLY_MINI", "CI_NIGHTLY_MINI_BUILDER", "CI_NIGHTLY_ONLY_RUNNER"):
            self.assertEqual(step_env[name], "${{ vars.%s }}" % name)
        self.assertEqual(step_env["NIGHTLY_SCHEDULE"], "${{ github.event.schedule }}")

    def test_the_judged_labels_match_decides_route(self) -> None:
        self.assertIn("vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY_MINI || vars.CI_NIGHTLY_ONLY_RUNNER || "
                      f"'{preflight.DEDICATED}'", self.JOBS["decide"]["runs-on"])
        self.assertIn("vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY_MINI_BUILDER", self.JOBS["build-nightly-app"]["runs-on"])


if __name__ == "__main__":
    unittest.main()
