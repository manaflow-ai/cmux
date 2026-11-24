#!/usr/bin/env python3
"""Jobs that need ancestry fetch one branch's history, not checkout's fetch-depth 0 of every ref.

On 2026-11-23 actions/checkout's fetch-depth 0 (+refs/heads/* and +refs/tags/*, 80,000+ refs) stalled under
1000 B/s and failed on all three tries in browser-host release (job 137965629300), the Cloudflare relay plan
(137746568589) and the web bundle publish (137969522125). These jobs check out the tip and run
scripts/ci/fetch_branch_history.sh instead.
"""
import pathlib
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"
JOBS = {
    "cmux-browser-host-release.yml": ["version"],
    "cloudflare-relay.yml": ["plan", "deploy-staging", "deploy-production"],
    "cmux-next-web-bundle-publish.yml": ["build"],
    # The same failure in the backend deploy on 2026-11-23 and 24: deploy-staging (jobs 138123838319, 138095039278)
    # and deploy-dashboard-staging (137939866003), so a merged console fix did not reach staging.
    "backend.yml": ["deploy-staging", "deploy-dashboard-staging", "deploy-development"],
}


class BranchHistoryFetch(unittest.TestCase):
    def test_jobs_fetch_one_branch_after_a_tip_checkout(self):
        for name, jobs in JOBS.items():
            wf = yaml.safe_load((WORKFLOWS / name).read_text())
            for job in jobs:
                steps = wf["jobs"][job]["steps"]
                for s in steps:
                    if str(s.get("uses", "")).startswith("actions/checkout@"):
                        self.assertNotIn("fetch-depth", s.get("with") or {}, f"{name}:{job}")
                fetches = [i for i, s in enumerate(steps) if "scripts/ci/fetch_branch_history.sh feat-cmux-next" in (s.get("run") or "")]
                self.assertTrue(fetches, f"{name}:{job} does not fetch feat-cmux-next's history")
                checkouts = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("actions/checkout@")]
                self.assertGreater(fetches[0], checkouts[0], f"{name}:{job}")

    def test_script_fetches_one_branch_blobless_with_retries(self):
        lines = (ROOT / "scripts" / "ci" / "fetch_branch_history.sh").read_text().splitlines()
        text = "\n".join(line for line in lines if not line.lstrip().startswith("#"))
        self.assertIn("--no-tags", text)
        self.assertIn("--filter=blob:none", text)
        self.assertIn("for try in 1 2 3", text)
        self.assertIn('"+refs/heads/$branch:refs/remotes/origin/$branch"', text)
        self.assertNotIn("refs/heads/*", text)


if __name__ == "__main__":
    unittest.main()
