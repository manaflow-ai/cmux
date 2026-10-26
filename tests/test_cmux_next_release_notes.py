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
    def test_digest_titles_are_unique_when_long_lines_share_a_first_clause(self):
        # Review of #22099: short_title cuts both lines to "Sidebar rows keep their order",
        # and the pre-publish check rejects a digest that shows one title twice.
        import argparse, importlib.util
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "cmux-next", "release-notes.py")
        spec = importlib.util.spec_from_file_location("release_notes_digest", script)
        notes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notes)
        lines = [
            {"group": "fixed", "title": "Sidebar rows keep their order, even when a workspace is renamed while another one is dragged"},
            {"group": "fixed", "title": "Sidebar rows keep their order, after a relaunch restores every window and each of its workspaces"},
        ]
        args = argparse.Namespace(short="1.0.0-nightly.1", date="2026-10-19")
        digest = notes.summary_whats_new_digest(args, lines)
        titles = [entry["title"]["en"].lower() for entry in digest["entries"]]
        self.assertEqual(len(titles), len(set(titles)), titles)

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

    def test_notes_name_their_commit_and_the_time_they_were_made(self):
        # The Updated card names the build by both (Leo 2026-10-26: "it just says updated to nightly").
        notes = self.build(self.base)
        self.assertEqual(notes["head"], self.head)
        self.assertRegex(notes["builtAt"], r"^2\d{3}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_a_later_build_has_no_highlight_only_changes(self):
        added = git(self.repo, "rev-parse", "HEAD~1")
        notes = self.build(added, build="3")
        self.assertEqual(notes["highlights"], [])
        self.assertEqual(notes["changes"], ["sidebar: tidy"])

    def test_a_long_summary_line_without_a_clause_stays_out_of_the_digest(self):
        since = self.head
        git(self.repo, "commit", "-q", "--allow-empty", "-m",
            "feat: Keep favorite destinations within easy reach across all of your open windows")
        self.head = git(self.repo, "rev-parse", "HEAD")
        notes = self.build(since, build="5")
        self.assertEqual(notes["whatsNew"]["entries"] if notes.get("whatsNew") else [], [])

    def test_summary_only_build_generates_a_valid_digest(self):
        since = self.head
        for subject in (
            # A digest title keeps a whole line of at most 60 characters (#21873).
            "feat: Keep favorite destinations within easy reach",
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

    def commits(self, *subjects):
        since = self.head
        for subject in subjects:
            git(self.repo, "commit", "-q", "--allow-empty", "-m", subject)
        self.head = git(self.repo, "rev-parse", "HEAD")
        return since

    def test_user_facing_commits_give_a_whats_new_digest(self):
        # 2026-10-20: the digest summary lost its period, the validator wants whole sentences, so
        # every summary-built entry was dropped and the update card read "What's new in this build".
        since = self.commits("fix(sidebar): pinned avatars match row avatars in the compact rail",
                             "feat(next): click a background task to see everything it ran")
        notes = self.build(since, build="6")
        entries = (notes.get("whatsNew") or {}).get("entries", [])
        self.assertEqual([e["title"]["en"] for e in entries],
                         ["Click a background task to see everything it ran",
                          "Pinned avatars match row avatars in the compact rail"])
        for entry in entries:
            self.assertTrue(entry["summary"]["en"].endswith("."), entry)

    def test_agent_and_prompt_ids_never_reach_the_summary(self):
        since = self.commits("feat(next): nested groups up to 3 levels with one machine per tree (a283)",
                             "Hover card: move the card's scroll view by the wheel delta directly (u3320)")
        notes = self.build(since, build="7")
        titles = [line["title"] for line in notes["summary"]]
        self.assertTrue(titles, notes["summary"])
        for title in titles:
            self.assertNotRegex(title, r"\((?:a|u)\d+\)")

    def check(self, notes_path):
        return subprocess.run([sys.executable, SCRIPT, "check", "--notes", notes_path],
                              cwd=self.repo, capture_output=True, text=True)

    def test_check_fails_a_build_with_no_whats_new_entries(self):
        since = self.commits("ci: tick the nightly", "test(next): a red test")
        self.build(since, build="8")
        result = self.check(os.path.join(self.repo, "out", "8.json"))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no What's New entries", result.stderr)

    def test_check_passes_a_build_with_entries(self):
        since = self.commits("feat(next): click a background task to see everything it ran")
        self.build(since, build="9")
        result = self.check(os.path.join(self.repo, "out", "9.json"))
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
