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

    def test_the_migrations_push_guard_fetches_two_commits_not_every_ref(self):
        # The guard compares the pushed tree with the previous head's and needs no ancestry. Its checkout's
        # fetch-depth 0 failed the same way (jobs 138141296796, 138140836520), and the production promote's G1
        # needs this job green. The commits come whole: its lints read the previous head's files with `git show`
        # and count an unreadable file as absent, so a blob filter could pass a changed migration.
        steps = yaml.safe_load((WORKFLOWS / "backend.yml").read_text())["jobs"]["migrations-push-guard"]["steps"]
        checkouts = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("actions/checkout@")]
        self.assertNotIn("fetch-depth", steps[checkouts[0]].get("with") or {})
        self.assertNotIn("filter", steps[checkouts[0]].get("with") or {})
        fetches = [i for i, s in enumerate(steps) if "--depth=1 origin" in (s.get("run") or "")]
        self.assertEqual(len(fetches), 1)
        run = steps[fetches[0]]["run"]
        self.assertEqual(steps[fetches[0]]["env"], {"BEFORE": "${{ github.event.before }}"})
        self.assertIn('fetch_one "+refs/heads/feat-cmux-next:refs/remotes/origin/feat-cmux-next"', run)
        self.assertIn('fetch_one "$BEFORE"', run)
        self.assertIn("--no-tags", run)
        # A reused workspace can carry a configured blob filter; --no-filter overrides it.
        self.assertIn("fetch --no-filter ", run)
        self.assertNotIn("--filter", run)
        self.assertNotIn("|| true", run)
        guards = [i for i, s in enumerate(steps) if "git diff --name-status" in (s.get("run") or "")]
        self.assertTrue(checkouts[0] < fetches[0] < guards[0])

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
