#!/usr/bin/env python3
"""Behavioral coverage for the release notes' "Thank you" line (scripts/ci/release_thanks.py)."""

import importlib.util
import io
import json
import re
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release_thanks", ROOT / "scripts/ci/release_thanks.py")
assert SPEC and SPEC.loader
THANKS = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = THANKS
SPEC.loader.exec_module(THANKS)

CONFIG = THANKS.load_config(ROOT / ".github/release-thanks.json")


def author(login, company="", bot=False):
    return {"login": login, "company": company, "bot": bot}


class ThanksTextTests(unittest.TestCase):
    def test_names_outside_contributors_sorted_and_credits_companies(self):
        text = THANKS.thanks([author("zed"), author("Alice", "@acme"), author("bob", "Initech"),
                              author("carol", "ACME")], CONFIG)
        self.assertEqual(text, "### Thank you\n\n"
                               "Huge thanks to @Alice, @bob, @carol and @zed for helping with this release!\n"
                               "Thanks also to the folks at ACME and Initech.\n")

    def test_one_contributor_and_no_company(self):
        self.assertEqual(THANKS.thanks([author("solo")], CONFIG),
                         "### Thank you\n\nHuge thanks to @solo for helping with this release!\n")

    def test_leaves_out_maintainers_bots_and_their_companies(self):
        authors = [author("lawrencecchen", "Manaflow"), author("TeamLeaderLeo"), author("dependabot"),
                   author("renovate[bot]"), author("some-app", bot=True), author("cmux-bot"),
                   author("intern", "@manaflow-ai")]
        self.assertEqual(THANKS.thanks(authors, CONFIG),
                         "### Thank you\n\nHuge thanks to @intern for helping with this release!\n")

    def test_zero_outside_contributors_prints_nothing(self):
        self.assertEqual(THANKS.thanks([], CONFIG), "")
        self.assertEqual(THANKS.thanks([author("austinywang"), author("github-actions", bot=True)], CONFIG), "")

    def test_idempotent_and_order_independent(self):
        authors = [author("b", "Y"), author("a", "X"), author("b", "Y"), author("A")]
        first = THANKS.thanks(authors, CONFIG)
        self.assertEqual(first, THANKS.thanks(list(reversed(authors)), CONFIG))
        self.assertEqual(first.lower().count("@a"), 1)
        self.assertIn("@A and @b", first)

    def test_company_text_cannot_inject_markup_or_mentions(self):
        text = THANKS.thanks([author("eve", "<img src=x> [click](http://x) @org"), author("long", "x" * 200)], CONFIG)
        self.assertNotIn("<", text)
        self.assertNotIn("](", text)
        self.assertNotIn("@org", text)
        self.assertNotIn("x" * 61, text)

    def test_url_like_companies_are_left_out(self):
        for company in ("https://example.com", "www.example.org", "example.io", "acme.dev/team"):
            self.assertEqual(THANKS.clean_company(company), "", company)
        self.assertEqual(THANKS.clean_company("Acme Inc."), "Acme Inc")

    def test_fetch_authors_times_out_into_an_error(self):
        with unittest.mock.patch.object(THANKS.subprocess, "run", side_effect=subprocess.TimeoutExpired("gh", 1)):
            with self.assertRaises(RuntimeError):
                THANKS.fetch_authors("manaflow-ai/cmux", [1])

    def test_odd_logins_are_skipped(self):
        self.assertEqual(THANKS.thanks([author("bad login<"), author("")], CONFIG), "")


class RangeTests(unittest.TestCase):
    def test_pr_numbers_from_squash_and_merge_subjects(self):
        subjects = ["Fix a thing (#12)", "Merge pull request #34 from someone/branch", "No PR here",
                    "Again (#12)", "Mentions #56 in the middle"]
        self.assertEqual(THANKS.pr_numbers(subjects), [12, 34])

    def test_fetch_authors_batches_and_skips_unmerged_and_missing(self):
        calls = []

        def run(cmd, **kwargs):
            query = cmd[-1]
            calls.append(query)
            numbers = [int(n) for n in re.findall(r"\bp(\d+): pullRequest", query)]
            repo = {f"p{n}": ({"merged": n != 2, "author": {"__typename": "User", "login": f"u{n}", "company": "C"}}
                              if n != 3 else None) for n in numbers}
            return subprocess.CompletedProcess(cmd, 0, json.dumps({"data": {"repository": repo}}), "")

        with unittest.mock.patch.object(THANKS.subprocess, "run", side_effect=run):
            authors = THANKS.fetch_authors("manaflow-ai/cmux", list(range(1, 61)))
        self.assertEqual(len(calls), 2)
        logins = {entry["login"] for entry in authors}
        self.assertNotIn("u2", logins)
        self.assertNotIn("u3", logins)
        self.assertEqual(len(logins), 58)

    def test_fetch_authors_fails_loudly_when_gh_fails(self):
        failed = subprocess.CompletedProcess([], 1, "", "HTTP 401")
        with unittest.mock.patch.object(THANKS.subprocess, "run", return_value=failed):
            with self.assertRaises(RuntimeError):
                THANKS.fetch_authors("manaflow-ai/cmux", [1])

    def test_git_range_end_to_end_with_stubbed_github(self):
        with tempfile.TemporaryDirectory() as tmp:
            git = lambda *args: subprocess.run(["git", "-C", tmp, *args], check=True, capture_output=True, text=True)
            git("init", "-q")
            git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base")
            base = git("rev-parse", "HEAD").stdout.strip()
            for subject in ("Add a feature (#7)", "Fix a bug (#8)"):
                git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", subject)
            subjects = subprocess.run(["git", "-C", tmp, "log", "--first-parent", "-z", "--format=%s", f"{base}..HEAD"],
                                      capture_output=True, text=True, check=True).stdout
        self.assertEqual(THANKS.pr_numbers(subjects.split("\0")), [8, 7])

    def test_cli_with_authors_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "authors.json"
            path.write_text(json.dumps([author("alice", "Acme"), author("lucasr1b")]))
            out = io.StringIO()
            with unittest.mock.patch.object(sys, "stdout", out):
                self.assertEqual(THANKS.main(["--authors", str(path)]), 0)
        self.assertEqual(out.getvalue(), "### Thank you\n\nHuge thanks to @alice for helping with this release!\n"
                                         "Thanks also to the folks at Acme.\n")


if __name__ == "__main__":
    unittest.main()
