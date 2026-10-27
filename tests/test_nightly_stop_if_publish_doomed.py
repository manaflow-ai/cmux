#!/usr/bin/env python3
"""build-nightly-app stops once a job publish-nightly needs has failed beside it.

NIGHTLY_PUBLISH_PEERS (nightly.yml, build-nightly-app) must be exactly the jobs
on the new-build path to publish-nightly (ancestors of build-sign-notarize-nightly)
that run beside build-nightly-app (neither its ancestor nor its descendant). A
failed peer must leave both prepare jobs skipped, so the run cannot publish:
no job between a peer and build-sign-notarize-nightly may tolerate a peer's
failure. The check (scripts/ci/stop_if_publish_doomed.py) runs before the
Release compile and before the unsigned-app upload, and fails open.
"""
from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import unittest
import urllib.request
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())
JOBS = WORKFLOW["jobs"]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import stop_if_publish_doomed  # noqa: E402


def needs(job: str) -> list[str]:
    value = JOBS[job].get("needs", [])
    return [value] if isinstance(value, str) else list(value)


def ancestors(job: str) -> set[str]:
    seen, stack = set(), [job]
    while stack:
        for parent in needs(stack.pop()):
            if parent not in seen:
                seen.add(parent)
                stack.append(parent)
    return seen


def descendants(job: str) -> set[str]:
    return {j for j in JOBS if job in ancestors(j)}


def derived_peers() -> set[str]:
    app = "build-nightly-app"
    path = ancestors("build-sign-notarize-nightly") & ancestors("publish-nightly")
    return {j for j in path if j != app and j not in ancestors(app) and j not in descendants(app)}


class PeersAreDerived(unittest.TestCase):
    def test_peers_match_the_needs_graph(self):
        listed = set(JOBS["build-nightly-app"]["env"]["NIGHTLY_PUBLISH_PEERS"].split())
        self.assertEqual(listed, derived_peers())
        self.assertTrue(listed, "build-nightly-app has peers on the publish path")

    def test_a_failed_peer_leaves_no_way_to_publish(self):
        # Every job between a peer and build-sign-notarize-nightly runs only when
        # its needs succeeded, or reads a peer-free result: no `result` test on a peer.
        for peer in derived_peers():
            between = descendants(peer) & ancestors("build-sign-notarize-nightly")
            for job in between:
                condition = str(JOBS[job].get("if", ""))
                for other in derived_peers():
                    self.assertNotIn(f"needs.{other}.result", condition, f"{job} tolerates {other} failing")
                if "always()" in condition or "!cancelled()" in condition:
                    # Such a job may still run only on its own needs' success.
                    self.assertTrue(all(f"needs.{n}.result == 'success'" in condition or n not in between | derived_peers()
                                        for n in needs(job) if n in between) or "== 'failure'" in condition,
                                    f"{job} may run after a peer failed")
            self.assertTrue(any(peer in needs(j) or ancestors(j) & {peer} for j in
                                ("prepare-nightly-variant-primary", "prepare-nightly-variant-fallback")))


class StepsAreWired(unittest.TestCase):
    steps = JOBS["build-nightly-app"]["steps"]

    def index(self, name: str) -> int:
        return next(i for i, s in enumerate(self.steps) if s.get("name") == name)

    def test_checks_precede_the_compile_and_the_upload(self):
        for check, target in (("Stop when the run can no longer publish (before the compile)", "Build nightly app (Release)"),
                              ("Stop when the run can no longer publish (before the upload)", "Upload unsigned nightly app")):
            i, j = self.index(check), self.index(target)
            self.assertEqual(i + 1, j, f"{check} runs right before {target}")
            step = self.steps[i]
            self.assertEqual(step["if"], self.steps[j]["if"])
            self.assertIn('python3 scripts/ci/stop_if_publish_doomed.py "${peers[@]}"', step["run"])
            self.assertEqual(step["env"], {"GH_TOKEN": "${{ github.token }}"})
            self.assertNotIn("continue-on-error", step)

    def test_upload_is_bounded_and_retried_once(self):
        first = self.steps[self.index("Upload unsigned nightly app")]
        retry = self.steps[self.index("Upload unsigned nightly app (retry)")]
        self.assertEqual((first["timeout-minutes"], first["continue-on-error"], first["id"]), (10, True, "upload-unsigned"))
        self.assertEqual(retry["if"], "steps.upload-unsigned.outcome == 'failure'")
        self.assertEqual(retry["timeout-minutes"], 10)
        self.assertEqual(retry["with"]["overwrite"], True)
        self.assertEqual({k: v for k, v in retry["with"].items() if k != "overwrite"},
                         {k: v for k, v in first["with"].items()})
        self.assertEqual(retry["uses"], first["uses"])


class CheckBehaviour(unittest.TestCase):
    env = {"GITHUB_REPOSITORY": "o/r", "GITHUB_RUN_ID": "7", "GITHUB_RUN_ATTEMPT": "2", "GH_TOKEN": "t",
           "GITHUB_API_URL": "https://api.example"}

    def run_with(self, jobs=None, error=None):
        seen = []

        def fake(request, timeout):
            seen.append(request.full_url)
            if error:
                raise error
            return io.BytesIO(json.dumps({"jobs": jobs}).encode())

        out = io.StringIO()
        with mock.patch.dict(os.environ, self.env), mock.patch.object(urllib.request, "urlopen", fake), redirect_stdout(out):
            rc = stop_if_publish_doomed.main(["helper", "resolver"])
        return rc, out.getvalue(), seen

    def test_a_failed_or_cancelled_peer_stops(self):
        for conclusion in ("failure", "cancelled"):
            rc, out, seen = self.run_with([{"name": "helper", "conclusion": conclusion, "html_url": "u"}])
            self.assertEqual(rc, 1)
            self.assertIn("::error title=Run cannot publish::helper", out)
            self.assertEqual(seen, ["https://api.example/repos/o/r/actions/runs/7/attempts/2/jobs?per_page=100"])

    def test_other_states_and_other_jobs_carry_on(self):
        for jobs in ([{"name": "helper", "conclusion": None, "status": "in_progress"}],
                     [{"name": "helper", "conclusion": "success"}, {"name": "resolver", "conclusion": "skipped"}],
                     [{"name": "unrelated", "conclusion": "failure"}], []):
            self.assertEqual(self.run_with(jobs)[0], 0)

    def test_a_read_error_carries_on(self):
        rc, out, _ = self.run_with(error=OSError("rate limited"))
        self.assertEqual(rc, 0)
        self.assertIn("::warning", out)

    def test_no_jobs_named_is_a_usage_error(self):
        self.assertEqual(subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/stop_if_publish_doomed.py")],
                                        capture_output=True).returncode, 2)


if __name__ == "__main__":
    unittest.main()
