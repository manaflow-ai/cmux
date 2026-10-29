#!/usr/bin/env python3
"""The CLA policy guard's trusted approval: who may clear a control-plane update.

scripts/ci/validate-cla-policy.rb authorizes a change to the CLA policy or to
the guard itself only with an approving review of the exact pull-request head
from a trusted reviewer other than the author. Agent pull requests are opened
from Leo's account, so with only two teammates trusted they could never clear
it on their own. Leo, 2026-10-29: "STOP BLOCKING ON THIS BULLSHIT. IT
SHOULDN'T HAPPEN." An independent review at the head now clears it: the
cmux-bot App's approval (type Bot) or Leo's (on a pull request he did not open).
"""
from __future__ import annotations

import json
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts/ci/validate-cla-policy.rb"
HEAD = "a" * 40
OLDER = "b" * 40
BOT, LEO, AUSTIN, AUTHOR = 348531757, 13091533, 38676809, 99999

# Loads the validator's definitions (not its main block), runs its own trusted
# review matrix, then answers each case in ARGV's JSON: does this review list
# approve HEAD for this author?
RUBY_DRIVER = r"""
require "json"
path = ARGV.shift
src = File.read(path)
cut = src.rindex("\nbegin\n  run_yaml_regression_matrix!")
abort "validator main block not found" unless cut
eval(src[0...cut], TOPLEVEL_BINDING, path)
run_trusted_review_regression_matrix!
out = JSON.parse(ARGV.shift).map do |item|
  begin
    latest = {}
    seen = {}
    item.fetch("reviews").each { |review| collect_latest_trusted_review!(latest, seen, review) }
    latest.values.any? { |_order, review| trusted_review_approves_head?(review, item.fetch("head"), item.fetch("author")) }
  rescue PolicyError => error
    "refused: #{error.message}"
  end
end
puts JSON.generate(out)
"""


def review(rid: int, user: int, kind: str, commit: str = HEAD, state: str = "APPROVED",
           dismissed: str | None = None, at: str = "2026-10-29T03:30:00Z") -> dict:
    return {"id": rid, "user": {"id": user, "type": kind}, "state": state, "commit_id": commit,
            "submitted_at": at, "dismissed_at": dismissed}


@unittest.skipUnless(shutil.which("ruby"), "ruby is required for the guard validator")
class TrustedReviewerTests(unittest.TestCase):
    def verdicts(self, cases: list[tuple[list[dict], int]]) -> list:
        payload = json.dumps([{"reviews": reviews, "head": HEAD, "author": author} for reviews, author in cases])
        done = subprocess.run(["ruby", "-e", RUBY_DRIVER, str(VALIDATOR), payload],
                              capture_output=True, text=True, check=False)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("PASS: trusted review state regression matrix", done.stdout)
        return json.loads(done.stdout.strip().splitlines()[-1])

    def test_cmux_bot_approval_at_the_head_passes(self):
        self.assertEqual(self.verdicts([([review(1, BOT, "Bot")], LEO)]), [True])

    def test_cmux_bot_approval_of_an_older_head_fails(self):
        self.assertEqual(self.verdicts([([review(1, BOT, "Bot", commit=OLDER)], LEO)]), [False])

    def test_dismissed_cmux_bot_approval_fails(self):
        dismissed = review(1, BOT, "Bot", dismissed="2026-10-29T03:31:00Z")
        later = [review(2, BOT, "Bot"), review(3, BOT, "Bot", state="DISMISSED", at="2026-10-29T03:31:00Z")]
        self.assertEqual(self.verdicts([([dismissed], LEO), (later, LEO)]), [False, False])

    def test_author_self_approval_fails(self):
        self.assertEqual(self.verdicts([([review(1, LEO, "User")], LEO), ([review(2, AUSTIN, "User")], AUSTIN)]),
                         [False, False])

    def test_leo_approval_counts_on_a_pull_request_he_did_not_open(self):
        self.assertEqual(self.verdicts([([review(1, LEO, "User")], AUTHOR)]), [True])

    def test_existing_teammate_approval_still_passes(self):
        self.assertEqual(self.verdicts([([review(1, AUSTIN, "User")], LEO)]), [True])

    def test_an_id_is_trusted_only_as_its_listed_type(self):
        verdicts = self.verdicts([([review(1, BOT, "User")], AUTHOR), ([review(2, LEO, "Bot")], AUTHOR)])
        self.assertTrue(all(str(v).startswith("refused:") for v in verdicts), verdicts)

    def test_an_untrusted_bot_is_ignored(self):
        self.assertEqual(self.verdicts([([review(1, 41898282, "Bot")], LEO)]), [False])


if __name__ == "__main__":
    unittest.main()
