#!/usr/bin/env python3
"""Every published NIGHTLY gets its PR list: notes, appcast, and one comment per PR.

Leo 2026-11-26: "hm do we display which prs go into which nightly maybe that'd be useful per thing?"
Three builds in a row had no signed notes and no PR comments (4569392993001, 4568071838801,
4567042650501) for three reasons, each covered here:
- run 45693929930's tail dispatch got "HTTP 500" and nothing retried it, so no tail ran;
- publish-release-notes' full checkout of the build stalled on the JIT VM (tails 45689720464,
  45679817194: "could not fetch <sha> from promisor remote"), though the job runs only scripts/ci;
- published-in's span fetch was anonymous and GitHub answered 403 four times (tail 45725593921).
"""
from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import workflow_jobs  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
JOBS = workflow_jobs.jobs(WORKFLOW)


def step(job: str, name: str) -> dict:
    return next(s for s in JOBS[job]["steps"] if s.get("name") == name)


class NotesCheckout(unittest.TestCase):
    def test_publish_release_notes_checks_out_only_scripts_ci(self):
        checkouts = [s for s in JOBS["publish-release-notes"]["steps"] if "actions/checkout" in str(s.get("uses", ""))]
        build = [s for s in checkouts if s.get("with", {}).get("path") != ".publish-tooling"]
        self.assertEqual(len(build), 1, build)
        self.assertEqual(str(build[0]["with"].get("sparse-checkout", "")).split(), ["scripts/ci"])


class SpanFetchAuth(unittest.TestCase):
    def test_published_in_fetches_the_span_with_the_job_token(self):
        fetch = step("published-in", "Fetch the published span")
        self.assertEqual(fetch.get("env", {}).get("GH_TOKEN"), "${{ github.token }}")
        self.assertIn("http.https://github.com/.extraheader", fetch["run"])
        self.assertIn("::add-mask::", fetch["run"])


class CommentArgs(unittest.TestCase):
    def test_the_comment_names_the_nightly_build_and_reads_the_feed(self):
        env = JOBS["published-in"]["env"]
        self.assertEqual(env.get("NIGHTLY_BUILD"), "${{ needs.published-build.outputs.publish_build }}")
        self.assertEqual(env.get("FEED_BASE"), "${{ needs.published-build.outputs.feed_base }}")
        script = (ROOT / "scripts/ci/nightly-steps/published-in-comment-prs.sh").read_text()
        self.assertIn('--name "NIGHTLY $NIGHTLY_BUILD"', script)
        self.assertIn('--build "$NIGHTLY_BUILD"', script)
        self.assertIn('--feed "$FEED_BASE/appcast-arm64.xml"', script)


class DispatchRetry(unittest.TestCase):
    """A 5xx may or may not have created the run: look once, and ask once more only if none started."""

    def run_dispatch(self, first_error: str, runs_started: int) -> tuple[int, list[str]]:
        script = step("dispatch-published-in", "Ask for this build's post-publication run")["run"]
        with tempfile.TemporaryDirectory() as temporary:
            tmp = Path(temporary)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log = tmp / "calls"
            (tmp / "dispatch-input.json").write_text("{}")
            gh = bin_dir / "gh"
            gh.write_text(f"""#!/usr/bin/env bash
echo "$1 $2" >> {log}
if [ "$1 $2" = "workflow run" ]; then
  n=$(grep -c '^workflow run' {log})
  if [ "$n" = 1 ] && [ -n "{first_error}" ]; then echo "{first_error}" >&2; exit 1; fi
  exit 0
fi
if [ "$1 $2" = "run list" ]; then echo {runs_started}; exit 0; fi
exit 2
""")
            sleeper = bin_dir / "sleep"
            sleeper.write_text("#!/bin/sh\nexit 0\n")
            for path in (gh, sleeper):
                path.chmod(path.stat().st_mode | stat.S_IEXEC)
            env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "RUNNER_TEMP": str(tmp),
                   "GITHUB_REPOSITORY": "o/r", "GITHUB_REF_NAME": "nightly-next"}
            result = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
            calls = log.read_text().splitlines() if log.exists() else []
            return result.returncode, calls

    def test_an_accepted_dispatch_is_asked_once(self):
        self.assertEqual(self.run_dispatch("", 0), (0, ["workflow run"]))

    def test_a_server_error_with_no_run_started_asks_once_more(self):
        error = "could not create workflow dispatch event: HTTP 500"
        self.assertEqual(self.run_dispatch(error, 0), (0, ["workflow run", "run list", "workflow run"]))

    def test_a_server_error_whose_run_started_asks_no_more(self):
        error = "could not create workflow dispatch event: HTTP 502"
        self.assertEqual(self.run_dispatch(error, 1), (0, ["workflow run", "run list"]))

    def test_a_client_error_fails_at_once(self):
        code, calls = self.run_dispatch("HTTP 422: Unexpected inputs provided", 0)
        self.assertNotEqual(code, 0)
        self.assertEqual(calls, ["workflow run"])


if __name__ == "__main__":
    unittest.main()
