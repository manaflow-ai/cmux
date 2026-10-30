#!/usr/bin/env python3
"""The rolling nightly-next build train (docs/ci/nightly-next-builder-pool.md).

- A nightly-next build that ends (on any builder) asks main's tick for the next
  head, so a free builder never sits idle while a buildable head waits.
- Every automatic promotion request asks main's guard to wait for a free
  builder (promote_nightly_next_debounce), and only through the guard.
- An older head that finishes after a newer build published is dropped, not
  reported as a failure: the reporter reads the cmux NEXT feed and compares
  this run's build number (run id plus attempt) with every build on it.
"""
from __future__ import annotations

import json
import re
import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())
JOBS = WORKFLOW["jobs"]
REQUESTER = (ROOT / "scripts/cmux-next/request-nightly-next.sh").read_text()


def reporter_script() -> str:
    steps = JOBS["report-nightly-failure"]["steps"]
    return next(step for step in steps if step.get("name") == "Open or update the nightly failure issue")["with"]["script"]


class RearmTrain(unittest.TestCase):
    def test_a_finished_build_dispatches_mains_tick(self):
        job = JOBS["rearm-train"]
        self.assertEqual(job["needs"], ["decide", "build-nightly-app"])
        self.assertEqual(job["runs-on"], "ubuntu-24.04")
        self.assertEqual(job["permissions"], {"actions": "write"})
        condition = job["if"]
        self.assertTrue(condition.startswith("always() &&"), condition)
        for clause in ("github.repository == 'manaflow-ai/cmux'", "github.event_name == 'push'",
                       "github.ref == 'refs/heads/nightly-next'", "needs.build-nightly-app.result != 'skipped'"):
            self.assertIn(clause, condition)
        run = "\n".join(step.get("run", "") for step in job["steps"])
        self.assertIn('gh workflow run nightly-next-tick.yml --repo "$GITHUB_REPOSITORY" --ref main', run)
        # It holds no secret: only the job token, which can dispatch but not move nightly-next.
        self.assertNotIn("secrets.", json.dumps(job))

    def test_the_tick_it_dispatches_exists_and_takes_a_dispatch(self):
        tick = yaml.safe_load((ROOT / ".github/workflows/nightly-next-tick.yml").read_text())
        triggers = tick.get(True) or tick.get("on")
        self.assertIn("workflow_dispatch", triggers)

    def test_builds_overlap_and_the_failure_reporter_waits_for_nothing_new(self):
        self.assertNotIn("rearm-train", JOBS["report-nightly-failure"]["needs"])
        self.assertIn("github.run_id", JOBS["build-nightly-app"]["concurrency"]["group"])


class AutomaticRequests(unittest.TestCase):
    def test_every_automatic_request_waits_for_a_free_builder(self):
        dispatches = re.findall(r"gh workflow run nightly\.yml[^\n]*", REQUESTER)
        self.assertTrue(dispatches)
        for dispatch in dispatches:
            self.assertIn("-f promote_nightly_next_debounce=true", dispatch)


class SupersededDrop(unittest.TestCase):
    def run_check(self, feed: str, run_id: str, attempt: str = "1") -> bool:
        # Run the reporter's own feed check against a feed body.
        script = reporter_script()
        start = script.index("let superseded = false;")
        end = script.index("if (superseded) {")
        body = script[start:end]
        harness = f"""
const process = {{ env: {{ TRACK: 'nightly-next', REFUSAL_REASON: '', TAG_STATUS: 'updated',
  NIGHTLY_NEXT_FEED_BASE: 'https://feed.invalid', GITHUB_RUN_ATTEMPT: {json.dumps(attempt)} }} }};
const context = {{ runId: {run_id} }};
const core = {{ warning: () => {{}} }};
const fetch = async () => ({{ ok: true, text: async () => {json.dumps(feed)} }});
(async () => {{ {body} console.log(JSON.stringify(superseded)); }})();
"""
        out = subprocess.run(["node", "-e", harness], capture_output=True, text=True, check=True)
        return json.loads(out.stdout)

    def test_an_older_build_than_the_feed_is_dropped(self):
        feed = "<item><sparkle:version>3951982493001</sparkle:version></item>"
        self.assertTrue(self.run_check(feed, "39509829525"))

    def test_the_newest_build_still_reports(self):
        feed = "<item><sparkle:version>3950982952501</sparkle:version></item>"
        self.assertFalse(self.run_check(feed, "39519824930"))

    def test_a_retry_of_the_published_build_is_not_superseded_by_itself(self):
        feed = "<item><sparkle:version>3951982493001</sparkle:version></item>"
        self.assertFalse(self.run_check(feed, "39519824930", attempt="1"))
        self.assertFalse(self.run_check(feed, "39519824930", attempt="2"))

    def test_attribute_versions_count_too(self):
        feed = '<enclosure sparkle:version="3951982493001" url="x"/>'
        self.assertTrue(self.run_check(feed, "39509829525"))

    def test_the_drop_never_hides_a_refusal_or_a_stale_tag(self):
        script = reporter_script()
        self.assertIn("!process.env.REFUSAL_REASON && process.env.TAG_STATUS !== 'stale'", script)
        self.assertLess(script.index("if (superseded) {"), script.index("const failed = Object.entries(results)"))


if __name__ == "__main__":
    unittest.main()
