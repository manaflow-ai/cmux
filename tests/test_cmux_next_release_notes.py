#!/usr/bin/env python3
"""scripts/cmux-next/release-notes.py: highlights attach to the first build that adds them,
commit subjects fill the history, the index keeps the newest builds, and signatures verify."""
import base64, json, os, subprocess, sys, tempfile, unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "cmux-next", "release-notes.py")
VALIDATOR = os.path.join(os.path.dirname(SCRIPT), "..", "whats-new", "validate.py")


def run(cwd, *args):
    return subprocess.run([sys.executable, SCRIPT, *args], cwd=cwd, capture_output=True, text=True, check=True).stdout


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.repo = tempfile.mkdtemp()
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "t@example.com")
        git(self.repo, "config", "user.name", "t")
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")
        os.makedirs(os.path.join(self.repo, "release-notes/next/highlights"))
        with open(os.path.join(self.repo, "release-notes/next/highlights/update-card.md"), "w") as f:
            f.write("title: Updates you barely notice\naction: palette.checkForUpdates | Try it\n\nRestart when you want.\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "-m", "updates: the R114 card")
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "sidebar: tidy")
        self.head = git(self.repo, "rev-parse", "HEAD")

    def build(self, since, build="2"):
        out = os.path.join(self.repo, "out")
        run(self.repo, "build", "--build", build, "--short", f"1.0.0-nightly.{build}", "--date", "2026-10-04",
            "--head", self.head, "--since", since, "--out", out)
        with open(os.path.join(out, f"{build}.json")) as f:
            return json.load(f)

    def test_a_highlight_attaches_to_the_build_that_adds_it(self):
        notes = self.build(self.base)
        self.assertEqual([h["title"] for h in notes["highlights"]], ["Updates you barely notice"])
        self.assertEqual(notes["highlights"][0]["action"], {"id": "palette.checkForUpdates", "title": "Try it"})
        self.assertEqual(notes["highlights"][0]["body"], "Restart when you want.")
        self.assertEqual(notes["changes"], ["sidebar: tidy", "updates: the R114 card"])

    def test_a_later_build_has_no_highlight_only_changes(self):
        added = git(self.repo, "rev-parse", "HEAD~1")
        notes = self.build(added, build="3")
        self.assertEqual(notes["highlights"], [])
        self.assertEqual(notes["changes"], ["sidebar: tidy"])

    def test_summary_only_build_generates_a_valid_digest(self):
        since = self.head
        for subject in (
            "feat: Keep favorite destinations within easy reach across all of your open windows",
            "fix: Preserve the selected tab when another window closes",
            "perf: Make switching between open windows smoother",
        ):
            git(self.repo, "commit", "-q", "--allow-empty", "-m", subject)
        self.head = git(self.repo, "rev-parse", "HEAD")

        notes = self.build(since, build="4")
        self.assertEqual(notes["highlights"], [])
        document = notes["whatsNew"]
        self.assertEqual([entry["category"] for entry in document["entries"]], ["new", "fixed", "improved"])
        self.assertTrue(all(len(entry["title"]["en"]) <= 60 for entry in document["entries"]))
        self.assertLessEqual(len(document["headline"]["en"]), 90)
        self.assertTrue(all(entry["docs"] == "https://cmux.com/docs/changelog" for entry in document["entries"]))
        self.assert_valid_digest(document)

    def test_highlight_digest_wins_over_summary_fallback(self):
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "fix: Preserve the selected tab when another window closes")
        self.head = git(self.repo, "rev-parse", "HEAD")

        notes = self.build(self.base, build="5")
        self.assertTrue(notes["summary"])
        self.assertEqual([entry["id"] for entry in notes["whatsNew"]["entries"]], ["update-card"])
        self.assertEqual(notes["whatsNew"]["entries"][0]["tryIt"], {"action": "palette.checkForUpdates"})
        self.assert_valid_digest(notes["whatsNew"])

    def test_empty_summary_does_not_generate_a_digest(self):
        since = self.head
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "ci: Refresh build cache")
        self.head = git(self.repo, "rev-parse", "HEAD")

        notes = self.build(since, build="6")
        self.assertEqual(notes["summary"], [])
        self.assertEqual(notes["highlights"], [])
        self.assertNotIn("whatsNew", notes)

    def assert_valid_digest(self, document):
        path = os.path.join(self.repo, document["version"] + ".json")
        with open(path, "w") as f:
            json.dump(document, f)
        result = subprocess.run([sys.executable, VALIDATOR, path], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_index_keeps_the_newest_builds_first(self):
        out = os.path.join(self.repo, "out")
        self.build(self.base, build="2")
        run(self.repo, "index", "--notes", os.path.join(out, "2.json"), "--out", os.path.join(out, "index.json"))
        self.build(self.base, build="3")
        run(self.repo, "index", "--notes", os.path.join(out, "3.json"), "--previous", os.path.join(out, "index.json"),
            "--keep", "1", "--out", os.path.join(out, "index.json"))
        with open(os.path.join(out, "index.json")) as f:
            self.assertEqual([b["build"] for b in json.load(f)["builds"]], ["3"])

    def test_prs_lists_each_pr_in_the_span_once_newest_first(self):
        since = self.head
        for subject in ("fix(sidebar): keep the row (#101)", "safe-push train: merge abc", "feat: a tab moves (#102)",
                        "fix(sidebar): keep the row, again (#101)"):
            git(self.repo, "commit", "-q", "--allow-empty", "-m", subject)
        self.head = git(self.repo, "rev-parse", "HEAD")
        self.assertEqual(run(self.repo, "prs", "--head", self.head, "--since", since, "--repo", "o/r"), (
            "### PRs in this build\n\n"
            "- [#101](https://github.com/o/r/pull/101) fix(sidebar): keep the row, again\n"
            "- [#102](https://github.com/o/r/pull/102) feat: a tab moves\n"
            "\n1 commit without a PR number not listed.\n"))

    def test_prs_caps_the_list_and_counts_the_rest(self):
        since = self.head
        for number in range(1, 6):
            git(self.repo, "commit", "-q", "--allow-empty", "-m", f"fix: change {number} (#{number})")
        self.head = git(self.repo, "rev-parse", "HEAD")
        lines = run(self.repo, "prs", "--head", self.head, "--since", since, "--limit", "2").splitlines()
        self.assertEqual(lines[2:], ["- [#5](https://github.com/manaflow-ai/cmux/pull/5) fix: change 5",
                                     "- [#4](https://github.com/manaflow-ai/cmux/pull/4) fix: change 4",
                                     "- and 3 more"])

    def test_prs_counts_past_the_change_cap_and_escapes_mentions(self):
        since = self.head
        for number in range(1, 206):
            git(self.repo, "commit", "-q", "--allow-empty", "-m", f"fix: thanks @someone <x> {number} (#{number})")
        self.head = git(self.repo, "rev-parse", "HEAD")
        lines = run(self.repo, "prs", "--head", self.head, "--since", since).splitlines()
        self.assertEqual(lines[2], "- [#205](https://github.com/manaflow-ai/cmux/pull/205) fix: thanks &#64;someone &lt;x> 205")
        self.assertEqual(lines[-1], "- and 165 more")

    def test_prs_is_empty_for_an_empty_span(self):
        self.assertEqual(run(self.repo, "prs", "--head", self.head, "--since", self.head), "")

    def test_signatures_verify_and_tampering_fails(self):
        out = os.path.join(self.repo, "out")
        self.build(self.base)
        key = os.path.join(self.repo, "k.pem")
        subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", key], check=True, capture_output=True)
        der = subprocess.run(["openssl", "pkey", "-in", key, "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout
        public = base64.b64encode(der[-32:]).decode()
        notes = os.path.join(out, "2.json")
        run(self.repo, "sign", "--key", key, notes)
        self.assertIn("verified", run(self.repo, "verify", "--public-key", public, notes))
        with open(notes, "a") as f:
            f.write(" ")
        result = subprocess.run([sys.executable, SCRIPT, "verify", "--public-key", public, notes], cwd=self.repo, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
