#!/usr/bin/env python3
"""A transient GitHub or R2 hiccup never leaves a cmux-tui tree unpublished.

Nightly-next promotion needs a published cmux-tui tree (request-nightly-next.sh),
so a failed publish run holds the NEXT nightly back until a later commit's
tree publishes. On 2026-10-26 promotions stopped from 18:42 to 19:44 UTC:
- runs 40376958903 and 40380418761 failed in actions/attest-build-provenance
  with "API rate limit exceeded for installation" (the hourly budget other
  workflows had spent);
- run 40376958903's publish-tree timed out after 120 s on a 40 MB companion,
  with no retry.
Run 40422130372 (2026-10-27) then failed both tries of a single retry 4 s
apart: its core budget had calls left, so the refusal was GitHub's secondary
limit. The attestation is now tried four times, each failed try backing off
through scripts/ci/gh_budget_wait.sh --backoff (until the reset, else 60, 120,
240 s) within a 15 minute total, and the last try must pass. The job timeouts
leave room for that wait.
publish-tree's reads go straight to R2 (scripts/ci/upload-r2-object.py
--download-to), which retries a dropped, stalled or 5xx read and exits 22 on a
404: run 40670486094 lost the tree to one HTTP/2 reset from files.cmux.com
(curl exit 92), a transfer error curl's --retry never retries. The step's
verification reads the public URLs, and reads a transfer error again from a
fresh URL. (A short remote read during manifest verification is retried in
verify_published_manifest.py; its unit tests cover that.)
"""

import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-tui-artifacts.yml"
ATTEST = "actions/attest-build-provenance@"


def load() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


class PublishRetries(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = load()["jobs"]

    def test_attestation_retries_with_backoff(self) -> None:
        for job_name in ("publish", "publish-windows"):
            steps = self.jobs[job_name]["steps"]
            attests = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith(ATTEST)]
            self.assertEqual(len(attests), 4, f"{job_name}: expected four attestation tries")
            tries = [steps[i] for i in attests]
            first, last = tries[0], tries[-1]
            self.assertIsNone(first.get("if"), f"{job_name}: the first try always runs")
            for earlier, later, index in zip(tries, tries[1:], range(1, len(tries))):
                self.assertEqual(earlier.get("with"), later.get("with"), f"{job_name}: every try attests the same subjects")
                self.assertTrue(earlier.get("continue-on-error"), f"{job_name}: a try before the last must not fail the job")
                step_id = earlier.get("id")
                self.assertTrue(step_id, f"{job_name}: an attestation try before the last needs an id")
                gate = f"steps.{step_id}.outcome == 'failure'"
                self.assertEqual(later.get("if"), gate, f"{job_name}: a try runs only after the one before it failed")
                between = steps[attests[index - 1] + 1 : attests[index]]
                self.assertEqual(len(between), 1, f"{job_name}: exactly one backoff sits between two tries")
                backoff = between[0]
                self.assertEqual(backoff.get("if"), gate)
                self.assertRegex(str(backoff.get("run", "")), rf"gh_budget_wait\.sh --backoff {index}\b")
                env = backoff.get("env", {})
                # Without a token the backoff cannot read the reset and the next try hits the same limit.
                self.assertEqual(env.get("GH_TOKEN"), "${{ github.token }}", f"{job_name}: the backoff reads the budget with the job's token")
                self.assertLessEqual(int(env.get("GH_BUDGET_WAIT_MAX_SECONDS", "3600")), 900, f"{job_name}: the backoffs wait 15 minutes at most in all")
            self.assertFalse(last.get("continue-on-error"), f"{job_name}: the last try must pass; nothing ships without provenance")
            self.assertGreaterEqual(
                int(self.jobs[job_name]["timeout-minutes"]), 15 + 15 + 5,
                f"{job_name}: the timeout must leave room for the work plus the 15 minutes the backoffs may take",
            )

    def step(self, name: str) -> str:
        for step in self.jobs["publish-tree"]["steps"]:
            if step.get("name") == name:
                return str(step["run"])
        raise AssertionError(f"publish-tree has no step {name!r}")

    def test_publish_tree_reads_from_r2_with_retries(self) -> None:
        script = self.step("Publish the complete tree with the trusted helper")
        fetch = re.search(r"^\s*fetch\(\) \{\n(.*?)\n\s*\}$", script, re.M | re.S)
        self.assertIsNotNone(fetch, "publish-tree defines fetch()")
        body = fetch.group(1)
        self.assertIn("scripts/ci/upload-r2-object.py", body, "fetch reads through the R2 API, as the uploads go")
        self.assertIn("--download-to", body)
        self.assertNotIn("curl", body, "files.cmux.com resets and stalls reads (run 40670486094, #26752)")
        uploader = (ROOT / "scripts/ci/upload-r2-object.py").read_text(encoding="utf-8")
        attempts = int(re.search(r'"CMUX_R2_UPLOAD_ATTEMPTS", "(\d+)"', uploader).group(1))
        delay = float(re.search(r'"CMUX_R2_UPLOAD_RETRY_DELAY", "([\d.]+)"', uploader).group(1))
        self.assertNotIn("CMUX_R2_UPLOAD_ATTEMPTS=", body, "fetch keeps the downloader's retries")
        self.assertGreaterEqual(attempts, 3, "a dropped read is read again")
        deadline = int(re.search(r"CMUX_R2_DOWNLOAD_ATTEMPT_SECONDS=(\d+)", body).group(1))
        self.assertGreaterEqual(deadline, 60, "a 100 MB companion needs time to read")
        one_fetch = attempts * deadline + sum(delay * n for n in range(1, attempts))
        # publish-tree-windows runs publish-tree's steps; both must outlast one fetch's full retry budget.
        for job_name in ("publish-tree", "publish-tree-windows"):
            self.assertGreater(
                int(self.jobs[job_name]["timeout-minutes"]) * 60, one_fetch,
                f"{job_name}: its timeout cuts one fetch's retries ({one_fetch:g} s) short",
            )

    def test_publish_tree_takes_only_a_404_for_an_absent_object(self) -> None:
        script = self.step("Publish the complete tree with the trusted helper")
        optional = re.search(r"^\s*fetch_optional\(\) \{\n(.*?)\n\s*\}$", script, re.M | re.S)
        self.assertIsNotNone(optional, "publish-tree defines fetch_optional()")
        self.assertRegex(optional.group(1), r"22\) return 1 ;;", "a 404 (exit 22) reads as absent")
        self.assertRegex(optional.group(1), r'exit "\$status"', "any other failure fails the step")
        self.assertRegex(script, r'if fetch_optional "\$base/source\.json" tree/source\.json; then',
                         "source.json decides a first publication")
        self.assertNotRegex(script, r"\bfetch \"[^\n]*2>/dev/null",
                            "a failed read hidden behind 2>/dev/null passes for an absent object")

    def test_verification_reads_a_transfer_error_again_from_a_fresh_url(self) -> None:
        script = self.step("Verify the tree publication")
        code = [line for line in script.splitlines() if not line.lstrip().startswith("#")]
        self.assertEqual(sum(bool(re.search(r"\bcurl -", line)) for line in code), 1, "every read goes through get()")
        get = re.search(r"^get\(\) \{\n.*?^\}\n", script, re.M | re.S)
        self.assertIsNotNone(get, "the verification defines get()")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, body in {
                # Exits with the next code of FAKE_CURL_EXITS and logs the URL it read.
                "curl": '#!/bin/bash\nfor a; do [[ "$a" == https://* ]] && echo "$a" >> "$FAKE_LOG"; done\n'
                        'n=$(wc -l < "$FAKE_LOG"); IFS=, read -ra codes <<< "$FAKE_CURL_EXITS"\n'
                        'exit "${codes[$((n - 1))]:-0}"\n',
                "sleep": "#!/bin/sh\nexit 0\n",
            }.items():
                (root / name).write_text(body)
                (root / name).chmod(0o755)
            for exits, status, reads in (("92,0", 0, 2), ("22", 22, 1), ("56,92,18", 18, 3), ("28,0", 0, 2)):
                with self.subTest(exits=exits):
                    log = root / "log"
                    log.write_text("")
                    result = subprocess.run(
                        ["bash", "-c", f'set -euo pipefail\n{get.group(0)}\nstatus=0\nget https://files.example/x out || status=$?\nexit "$status"'],
                        env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}", "FAKE_LOG": str(log),
                             "FAKE_CURL_EXITS": exits, "GITHUB_RUN_ID": "7"},
                        capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, status, result.stderr)
                    urls = log.read_text().split()
                    self.assertEqual(len(urls), reads, urls)
                    self.assertEqual(len(set(urls)), len(urls), "every read again goes to a fresh URL")


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=2).result
    sys.exit(0 if result.wasSuccessful() else 1)
