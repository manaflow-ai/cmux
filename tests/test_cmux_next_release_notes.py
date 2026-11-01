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
    def test_pr_body_description_is_plain_and_deterministic(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("release_notes_descriptions", SCRIPT)
        notes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notes)
        body = """## Summary\n\nInternal implementation details.\n\n## Changelog\n\nFixed: [Tabs](https://cmux.com/tabs) keep their position after restart\n\n## Testing\n\n- not user copy\n"""
        self.assertEqual(notes.pr_description(body), "Tabs keep their position after restart.")
        self.assertEqual(
            notes.pr_description(
                "## Summary\n\nInternal implementation details that must stay hidden.\n"
                "\n## Changelog\n\nFixed: Tabs keep their position after a restart,\n"
                "across every workspace window."
            ),
            "Tabs keep their position after a restart, across every workspace window.",
        )
        self.assertEqual(notes.pr_description("## Changelog\n\nnone\n"), "")
        for placeholder in ("Fixed: none", "Fixed: N/A", "Fixed:", "N/A"):
            with self.subTest(placeholder=placeholder):
                self.assertEqual(notes.pr_description("## Summary\n" + placeholder, "Tabs stay put"), "Tabs stay put.")
        self.assertEqual(
            notes.pr_description("## Summary\n\nTabs stay put after restart. The next sentence is implementation detail."),
            "Tabs stay put after restart.",
        )
        for punctuation in (".", "!", "?", "。", "！", "？"):
            with self.subTest(punctuation=punctuation):
                self.assertEqual(notes.pr_description(
                    f"## Changelog\n\nFixed: Tabs stay put{punctuation} Another sentence. A third sentence."),
                    f"Tabs stay put{punctuation}")
        self.assertEqual(notes.pr_description("", "Tabs stay put. Extra detail."), "Tabs stay put.")
        self.assertEqual(notes.pr_description("## Summary\n\n\"Tabs stay put.\" More detail."), "\"Tabs stay put.\"")
        self.assertEqual(
            notes.pr_description("## Summary\n\nTabs restore e.g. pinned panes after restart."),
            "Tabs restore e.g. pinned panes after restart.",
        )
        self.assertEqual(
            notes.pr_description("## Summary\n\nChoose “Keep tabs.” after restart."),
            "Choose “Keep tabs.” after restart.",
        )
        self.assertEqual(
            notes.pr_description("## Summary\n\nSee https://cmux-platform.example/run/123 for details." , "Tabs stay put"),
            "Tabs stay put.",
        )
        self.assertEqual(
            notes.pr_description("## Summary\n\nThe run is on gcp-codex-lane-2.us-west1.c.example.internal." , "Tabs stay put"),
            "Tabs stay put.",
        )
        self.assertEqual(
            notes.pr_description("## Changelog\n\nFixed: The run is 0123456789abcdef0123 and uses cmux-platform." , "Tabs stay put"),
            "Tabs stay put.",
        )
        self.assertEqual(
            notes.pr_description("## Summary\n\nImplementation details.\n\n## Changelog\n\nnone", "Tabs stay put"),
            "Tabs stay put.",
        )
        self.assertEqual(
            notes.pr_description("## Summary\n\nTabs stay put after a restart,\nacross every workspace window."),
            "Tabs stay put after a restart, across every workspace window.",
        )
        self.assertEqual(
            notes.pr_description("## Changelog\n\nFixed: Tabs stay put after a restart,\nacross every workspace window."),
            "Tabs stay put after a restart, across every workspace window.",
        )

    def test_description_safety_and_sentence_boundaries(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("release_notes_descriptions", SCRIPT)
        notes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notes)
        unsafe = (
            "See https://private.example/changes for details.",
            "See private.example/changes for details.",
            "The run uses cosmic-gray.",
            "The session is 01234567-89ab-cdef-0123-456789abcdef.",
            "The session is aid-0123456789abcdef.",
            "Tabs stay put after work in cmux-platform.",
        )
        for text in unsafe:
            for heading in ("Summary\n", "Changelog\nFixed:"):
                with self.subTest(text=text, heading=heading):
                    description = notes.pr_description(f"## {heading} {text}", "Tabs stay put")
                    self.assertEqual(description, "Tabs stay put.")
            self.assertEqual(notes.pr_description("", text), "Fixes and improvements.")
        for text in (
            "Tabs restore e.g. pinned panes after restart.",
            "Tabs restore i.e. reopen after restart.",
            "Tabs restore e.g. pinned panes etc. after restart.",
            "Tabs restore e.g. pinned panes, i.e. saved panes, etc. after restart.",
            "'Tabs stay put.'",
            '"Tabs stay put."',
            "“Tabs stay put.”",
            "‘Tabs stay put.’",
            'Choose "Keep tabs." after restart.',
            "Choose “Keep tabs.” after restart.",
            "Choose 'Keep tabs.' after restart.",
            "Choose ‘Keep tabs.’ after restart.",
            "Don't close tabs after choosing 'Keep tabs.' on restart.",
            "Don't close tabs after choosing ‘Keep tabs.’ on restart.",
            "Zoom stays at 1.5 after restart.",
            "Tabs wait... then restore after restart.",
        ):
            with self.subTest(text=text):
                description = notes.pr_description(f"## Summary\n{text} More detail.")
                self.assertEqual(description, text)
                args = type("Args", (), {"short": "1.0.0-nightly.1", "date": "2026-10-30"})()
                digest = notes.summary_whats_new_digest(args, [
                    {"group": "fixed", "title": "Tabs stay put", "description": description}])
                self.assertIsNotNone(digest)
                self.assertEqual(digest["entries"][0]["summary"]["en"], text)

    def test_private_sources_are_rejected_before_markdown_normalization(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("release_notes_descriptions", SCRIPT)
        notes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notes)
        unsafe = (
            "The run is on cmux12s-mac-mini.",
            "See //10.0.0.1/private for details.",
            "See [the run](https://private.example/run) for details.",
            "The value is session_id_abcdefghij.",
            "See [the run](https://cmux.com.private.example/run) for details.",
            "See [the run](https://github.com/manaflow-ai-private/cmux) for details.",
        )
        for text in unsafe:
            for prefix in ("## Summary\n", "## Changelog\nFixed: "):
                with self.subTest(text=text, prefix=prefix):
                    self.assertEqual(notes.pr_description(prefix + text, "Tabs stay put"), "Tabs stay put.")

    def test_sentence_ending_no_and_etc_stop_description_extraction(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("release_notes_descriptions", SCRIPT)
        notes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notes)
        for text, first in (
            ("Choose yes or no. Tabs restore. Panes remain.", "Choose yes or no."),
            ("Restore tabs, panes, etc. Keep your layout. Resume work.", "Restore tabs, panes, etc."),
        ):
            with self.subTest(text=text):
                self.assertEqual(notes.pr_description("## Summary\n" + text), first)
                self.assertEqual(notes.pr_description("## Summary\n" + first), first)

    def test_complete_quoted_sentences_still_end_description_extraction(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("release_notes_descriptions", SCRIPT)
        notes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notes)
        for opening, closing in (("'", "'"), ('"', '"'), ("‘", "’"), ("“", "”")):
            with self.subTest(opening=opening):
                first = f"{opening}Tabs stay put.{closing}"
                self.assertEqual(notes.pr_description(
                    f"## Summary\n{first} {opening}Panes stay open.{closing} More detail."), first)
                self.assertEqual(notes.pr_description(
                    f"## Summary\nDon't close tabs. {opening}Keep tabs.{closing}"), "Don't close tabs.")

    def test_public_links_remain_allowed(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("release_notes_descriptions", SCRIPT)
        notes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notes)
        self.assertEqual(
            notes.pr_description("## Summary\nSee [the changelog](https://github.com/manaflow-ai/cmux/pull/12345) for details."),
            "See the changelog for details.",
        )

    def test_pr_body_timeout_returns_media_style_empty_fallback(self):
        import importlib.util
        from unittest import mock
        spec = importlib.util.spec_from_file_location("release_notes_descriptions", SCRIPT)
        notes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notes)
        with mock.patch.object(notes.subprocess, "run", side_effect=notes.subprocess.TimeoutExpired("gh", 10)):
            body = notes.pr_body(123, None)
        self.assertEqual(body, "")
        self.assertEqual(notes.pr_description(body, "Tabs stay put"), "Tabs stay put.")
        with mock.patch.object(notes.subprocess, "run", side_effect=FileNotFoundError("gh")):
            self.assertEqual(notes.pr_body(123, None), "")
        with mock.patch.object(notes.subprocess, "run") as run:
            self.assertEqual(notes.pr_body(123, None, deadline=0), "")
            run.assert_not_called()

    def test_pr_body_outage_obeys_shared_budget(self):
        import importlib.util
        from unittest import mock
        spec = importlib.util.spec_from_file_location("release_notes_descriptions", SCRIPT)
        notes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notes)
        elapsed = 0

        def timeout(*args, **kwargs):
            nonlocal elapsed
            elapsed += kwargs["timeout"]
            raise notes.subprocess.TimeoutExpired("gh", kwargs["timeout"])

        with mock.patch.object(notes.time, "monotonic", side_effect=lambda: elapsed), \
                mock.patch.object(notes.subprocess, "run", side_effect=timeout) as run:
            for number in range(200):
                body = notes.pr_body(number, None, deadline=25)
                self.assertEqual(notes.pr_description(body, "Tabs stay put"), "Tabs stay put.")
            self.assertEqual(elapsed, 25)
            self.assertEqual([call.kwargs["timeout"] for call in run.call_args_list], [10, 10, 5])

    def test_backend_descriptions_are_internal_and_summary_digest_uses_description(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("release_notes_descriptions", SCRIPT)
        notes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notes)
        self.assertTrue(notes.internal_change("fix: encode snapshot cutoff for Postgres"))
        self.assertFalse(notes.internal_change("fix: tabs keep their position"))
        args = type("Args", (), {"short": "1.0.0-nightly.1", "date": "2026-10-30"})()
        digest = notes.summary_whats_new_digest(args, [{"group": "fixed", "title": "Tabs keep their position", "description": "They stay put after restart."}])
        self.assertEqual(digest["entries"][0]["summary"]["en"], "They stay put after restart.")

    def test_build_pr_descriptions_are_embedded_and_backend_items_are_hidden(self):
        since = self.head
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "fix: tabs keep their position after restart (#123)")
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "fix: encode snapshot cutoff for Postgres (#124)")
        head = git(self.repo, "rev-parse", "HEAD")
        fixture = os.path.join(self.repo, "pr-fixture.json")
        with open(fixture, "w") as out:
            json.dump({"bodies": {
                "123": "<!-- generated -->\n## Changelog\n\nFixed: [Tabs](https://cmux.com/tabs) keep their position after restart. More detail. Even more detail.",
                "124": "## Summary\n\nInternal database cutoff plumbing.",
            }, "files": {}}, out)
        notes_dir = os.path.join(self.repo, "pr-notes")
        env = {**os.environ, "CMUX_RELEASE_NOTES_PR_FIXTURE": fixture}
        result = subprocess.run(
            [sys.executable, SCRIPT, "build", "--build", "9", "--short", "1.0.0-nightly.9", "--date", "2026-10-30",
             "--head", head, "--since", since, "--out", notes_dir, "--pr-descriptions"],
            cwd=self.repo, env=env, capture_output=True, text=True, check=True,
        )
        self.assertTrue(result.stdout.strip())
        with open(os.path.join(notes_dir, "9.json")) as source:
            notes = json.load(source)
        by_pr = {item["pr"]: item for item in notes["items"]}
        self.assertEqual(by_pr[123]["description"], "Tabs keep their position after restart.")
        self.assertTrue(by_pr[124]["internal"])
        self.assertEqual([line["title"] for line in notes["summary"]], ["Tabs keep their position after restart"])
        self.assertEqual(notes["whatsNew"]["entries"][0]["summary"]["en"], "Tabs keep their position after restart.")

    def test_invalid_descriptions_fall_back_without_dropping_the_change(self):
        since = self.head
        title = "Tabs keep their position after restart"
        git(self.repo, "commit", "-q", "--allow-empty", "-m", f"fix: {title} (#123)")
        head = git(self.repo, "rev-parse", "HEAD")
        fixture = os.path.join(self.repo, "invalid-description-fixture.json")
        notes_dir = os.path.join(self.repo, "invalid-description-notes")
        invalid = [f"Resolves {reference}." for reference in (
            "#12345", "issue 12345", "PR #12345", "pull request 12345", "cx-abc123")]
        invalid += [
            "- fix: keep tabs in place",  # Plain copy is still a commit subject after stripping the bullet.
            "- fix(tabs): keep tabs in place",
            "Fixed: none", "Fixed: N/A", "Fixed: n/a", "Fixed:", "N/A", "Summary: N/A",
            "The run is on cmux12s-mac-mini.",
            "See //10.0.0.1/private for details.",
            "See [the run](https://private.example/run) for details.",
            "The value is session_id_abcdefghij.",
        ]
        for description in invalid:
            for section in ("## Summary\n", "## Changelog\nFixed: "):
                with self.subTest(description=description, section=section):
                    with open(fixture, "w") as out:
                        json.dump({"bodies": {"123": f"{section}{description}"}}, out)
                    subprocess.run(
                        [sys.executable, SCRIPT, "build", "--build", "9", "--short", "1.0.0-nightly.9",
                         "--date", "2026-10-30", "--head", head, "--since", since, "--out", notes_dir,
                         "--pr-descriptions"], cwd=self.repo,
                        env={**os.environ, "CMUX_RELEASE_NOTES_PR_FIXTURE": fixture},
                        capture_output=True, text=True, check=True,
                    )
                    with open(os.path.join(notes_dir, "9.json")) as source:
                        notes = json.load(source)
                    expected = title + "."
                    self.assertEqual(notes["items"][0]["description"], expected)
                    self.assertEqual(notes["summary"][0]["description"], expected)
                    entries = notes["whatsNew"]["entries"]
                    self.assertEqual(len(entries), 1)
                    self.assertEqual(entries[0]["id"], "summary-0")
                    self.assertEqual(entries[0]["summary"]["en"], expected)

    def test_digest_rejects_invalid_description_without_dropping_valid_title(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("release_notes_descriptions", SCRIPT)
        notes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notes)
        args = type("Args", (), {"short": "1.0.0-nightly.1", "date": "2026-10-30"})()
        digest = notes.summary_whats_new_digest(args, [{
            "group": "fixed", "title": "Tabs stay put", "description": "fix: keep tabs in place."}])
        self.assertIsNotNone(digest)
        self.assertEqual(digest["entries"][0]["summary"]["en"], "Tabs stay put.")

    def test_long_digest_title_fallback_only_describes_what_the_title_leaves_out(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("release_notes_descriptions", SCRIPT)
        notes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notes)
        args = type("Args", (), {"short": "1.0.0-nightly.1", "date": "2026-10-30"})()
        title = "Sidebar rows keep their order, even when a workspace is renamed while another one is dragged"
        for description in (None, "", "fix: keep rows in place.", "See issue #12345."):
            with self.subTest(description=description):
                line = {"group": "fixed", "title": title}
                if description is not None:
                    line["description"] = description
                digest = notes.summary_whats_new_digest(args, [line])
                self.assertIsNotNone(digest)
                self.assertEqual(len(digest["entries"]), 1)
                entry = digest["entries"][0]
                self.assertEqual(entry["title"]["en"], "Sidebar rows keep their order")
                self.assertEqual(entry["summary"]["en"],
                                 "Even when a workspace is renamed while another one is dragged.")
        description = "Your layout stays stable as you rename workspaces."
        digest = notes.summary_whats_new_digest(args, [
            {"group": "fixed", "title": title, "description": description}])
        self.assertEqual(digest["entries"][0]["summary"]["en"], description)

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

    def test_added_then_reverted_highlight_is_absent_from_notes_and_digest(self):
        path = "release-notes/next/highlights/reverted-tray.md"
        with open(os.path.join(self.repo, path), "w") as f:
            f.write("title: Reverted tray\naction: palette.checkForUpdates | Try it\n\nA reverted feature.\n")
        git(self.repo, "add", path)
        git(self.repo, "commit", "-q", "-m", "feat: Add tray highlight")
        git(self.repo, "revert", "--no-edit", "HEAD")
        self.head = git(self.repo, "rev-parse", "HEAD")
        # The checkout can contain an untracked stale copy; the source tree wins.
        with open(os.path.join(self.repo, path), "w") as f:
            f.write("title: Stale tray\n\nDo not publish this.\n")
        for since in (self.base, ""):
            with self.subTest(since=since):
                notes = self.build(since)
                self.assertEqual([h["id"] for h in notes["highlights"]], ["update-card"])
                self.assertEqual([e["id"] for e in notes["whatsNew"]["entries"]], ["update-card"])
                self.assert_valid_digest(notes["whatsNew"])

    def test_a_long_summary_line_without_a_clause_stays_out_of_the_digest(self):
        since = self.head
        git(self.repo, "commit", "-q", "--allow-empty", "-m",
            "feat: Keep favorite destinations within easy reach across all of your open windows")
        self.head = git(self.repo, "rev-parse", "HEAD")
        notes = self.build(since, build="5")
        # The line stays out; with nothing else to say, the build carries the generic entry.
        self.assertEqual([e["id"] for e in notes["whatsNew"]["entries"]], ["fixes-and-improvements"])

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

    def test_empty_summary_gets_the_generic_digest_with_the_range_link(self):
        # claude-sr2, 2026-10-27: a span with nothing user-facing publishes "Fixes and improvements"
        # linking the span's commits, instead of failing publish-nightly (runs 40357660985, 40232558078).
        since = self.head
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "ci: Refresh build cache")
        self.head = git(self.repo, "rev-parse", "HEAD")

        notes = self.build(since, build="6")
        self.assertEqual(notes["summary"], [])
        self.assertEqual(notes["highlights"], [])
        document = notes["whatsNew"]
        self.assertEqual(document["headline"], {"en": "Fixes and improvements"})
        [entry] = document["entries"]
        self.assertEqual((entry["id"], entry["title"]["en"]), ("fixes-and-improvements", "Fixes and improvements"))
        self.assertEqual(entry["docs"], f"https://github.com/manaflow-ai/cmux/compare/{since}...{self.head}")
        self.assert_valid_digest(document)
        self.assertFalse(os.path.exists(os.path.join(self.repo, "out", "community-6.md")))

    def test_the_generic_digest_without_a_start_links_the_head_commits(self):
        import argparse, importlib.util
        spec = importlib.util.spec_from_file_location("release_notes_generic", SCRIPT)
        notes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notes)
        args = argparse.Namespace(short="1.0.0-nightly.13", date="2026-10-04", head="a" * 40, since="")
        [entry] = notes.generic_whats_new_digest(args)["entries"]
        self.assertEqual(entry["docs"], "https://github.com/manaflow-ai/cmux/commits/" + "a" * 40)

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

    def touch(self, subject, *paths):
        """A commit that changes `paths`, with `subject`."""
        for path in paths:
            full = os.path.join(self.repo, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "a") as f:
                f.write(subject + "\n")
        git(self.repo, "add", *paths)
        git(self.repo, "commit", "-q", "-m", subject)
        self.head = git(self.repo, "rev-parse", "HEAD")

    def test_release_tooling_never_reaches_the_summary(self):
        # Leo's update to nightly 4037632091801 (2026-10-26) read "Fixed: validate release headings
        # within their day": #25533 changed only the release-notes checker and its test.
        since = self.head
        self.touch("fix(changelog): validate release headings within their day (#25533)",
                   "webviews/src/pages/changelog/notesCheck.ts", "webviews/test/changelog-notes-check.test.ts")
        # Any subject: every file it touches is CI or tooling.
        self.touch("fix: headings of one day stay in order (#9001)",
                   "webviews/src/pages/changelog/notesCheck.ts", "webviews/test/changelog-notes-check.test.ts")
        self.touch("fix: feeds check twice as often (#9002)", ".github/workflows/next.yml", "scripts/ci/tests/feed.test.sh")
        self.touch("fix(sidebar): rows keep their order after a rename (#9003)",
                   "webviews/src/pages/sidebar/Rows.tsx", "webviews/test/sidebar-rows.test.ts")
        notes = self.build(since, build="10")
        self.assertEqual([line["title"] for line in notes["summary"]], ["Rows keep their order after a rename"])
        self.assertEqual([(i["pr"], i.get("internal", False)) for i in notes["items"]],
                         [(9003, False), (9002, True), (9001, True), (25533, True)])
        self.assertNotIn("internal", notes["items"][0])
        entries = (notes.get("whatsNew") or {}).get("entries", [])
        self.assertEqual([e["title"]["en"] for e in entries], ["Rows keep their order after a rename"])

    def test_odd_subjects_and_file_names_keep_their_own_paths(self):
        # A subject with separators in it, and file names with spaces, a newline and a tab: each
        # commit keeps its own files.
        since = self.head
        self.touch("fix: rows \x1e keep \x1f order (#9101)", "webviews/src/pages/sidebar/A B.tsx")
        self.touch("fix: tabs keep their names (#9102)", "scripts/ci/tests/odd\nname.py", "tests/odd\tname.py")
        # A file named like the next commit's hash cannot take that commit's files.
        self.touch("fix: panes keep their size (#9103)", "tests/" + self.head)
        notes = self.build(since, build="11")
        self.assertEqual([(i["pr"], i.get("internal", False)) for i in notes["items"]],
                         [(9103, True), (9102, True), (9101, False)])
        self.assertEqual(len(notes["changes"]), 3)

    def test_tooling_paths(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("release_notes_paths", SCRIPT)
        notes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notes)
        for paths in (["webviews/src/pages/changelog/notesCheck.ts", "webviews/test/changelog-notes-check.test.ts"],
                      [".github/workflows/ci.yml"], ["scripts/cmux-next/release-notes.py", "tests/test_x.py"],
                      ["docs/ci/runners.md", "AGENTS.md"], ["README.ja.md", "CONTRIBUTING.md", "PLAN.md"], ["scripts/cmux-next/perf-cron.py"],
                      ["scripts/install-git-hooks.sh"], ["scripts/cmux-next/guardrails.py"],
                      ["scripts/cmux-next/check-app-bundle.sh"], ["webviews/scripts/check-glass-never-opaque.ts"],
                      ["scripts/ci/tests/ensure-web-bundles.test.sh"], ["scripts/measure/split-spring.sh"],
                      ["Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/A.swift"],
                      ["release-notes/next/highlights/x.md"], ["webviews/src/pages/changelog/changelog.gallery.ts"]):
            self.assertTrue(notes.tooling_only(paths), paths)
        for paths in ([], ["webviews/src/pages/changelog/UpdateSurfaces.tsx", "webviews/test/updated-card-summary.test.tsx"],
                      ["Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/UpdateHighlights.swift"],
                      ["webviews/src/pages/changelog/Localizable.xcstrings"],
                      # #25001 fixed the agent pane by changing only the script that bundles it.
                      ["scripts/cmux-next/build-agent-pane-web.sh"], ["scripts/build-sign-upload.sh"],
                      # The Embed CEF phase builds the browser from these; CI builds and stages what ships with these.
                      ["scripts/cmux-next/fetch-ublock.sh"], ["scripts/cmux-next/merge-cef-universal.sh"],
                      ["scripts/cmux-next/cef-manifest.json"], ["scripts/ci/cmux-remote-browser-host-build.sh"],
                      ["scripts/ci/ensure-web-bundles.sh"], ["scripts/ci/macos-cross.sh"],
                      ["scripts/ci/stage-agent-detector.sh"], ["scripts/whats-new/sync-app-bundle.py"],
                      # The app bundles it: About opens Third-Party Licenses.
                      ["THIRD_PARTY_LICENSES.md"], ["CHANGELOG.md"]):
            self.assertFalse(notes.tooling_only(paths), paths)

    def test_a_move_counts_at_both_ends(self):
        # A shipping file moved into tests/ is not a tooling-only commit.
        self.touch("feat: tab rows (#9201)", "webviews/src/pages/sidebar/Rows.tsx")
        since = self.head
        os.makedirs(os.path.join(self.repo, "tests"), exist_ok=True)
        git(self.repo, "mv", "webviews/src/pages/sidebar/Rows.tsx", "tests/Rows.tsx")
        git(self.repo, "commit", "-q", "-m", "fix: rows move (#9202)")
        self.head = git(self.repo, "rev-parse", "HEAD")
        notes = self.build(since, build="12")
        self.assertEqual([(i["pr"], i.get("internal", False)) for i in notes["items"]], [(9202, False)])

    def check(self, notes_path):
        summary = os.path.join(self.repo, "step-summary.md")
        result = subprocess.run([sys.executable, SCRIPT, "check", "--notes", notes_path], cwd=self.repo,
                                capture_output=True, text=True, env={**os.environ, "GITHUB_STEP_SUMMARY": summary})
        result.summary = ""
        if os.path.exists(summary):
            with open(summary) as f:
                result.summary = f.read()
        return result

    def test_check_publishes_a_build_with_no_entries_with_the_generic_one_and_a_warning(self):
        since = self.commits("ci: tick the nightly", "test(next): a red test")
        self.build(since, build="8")
        result = self.check(os.path.join(self.repo, "out", "8.json"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        link = f"https://github.com/manaflow-ai/cmux/compare/{since}...{self.head}"
        self.assertIn("::warning title=Generic What's New entry::", result.stdout)
        self.assertIn(link, result.stdout)
        self.assertIn("### Generic What's New entry", result.summary)
        self.assertIn(link, result.summary)

    def test_check_still_fails_when_every_highlight_is_malformed(self):
        # A highlight with neither a try-it action nor a docs link fails validation and is dropped;
        # with no summary line to stand in, the build keeps no digest and the gate fails as before.
        since = self.head
        with open(os.path.join(self.repo, "release-notes/next/highlights/faster-tabs.md"), "w") as f:
            f.write("title: Faster tabs\n\nTabs open faster.\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "-m", "docs: the faster tabs highlight")
        self.head = git(self.repo, "rev-parse", "HEAD")
        notes = self.build(since, build="14")
        self.assertNotIn("whatsNew", notes)
        result = self.check(os.path.join(self.repo, "out", "14.json"))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no What's New entries", result.stderr)
        self.assertNotIn("::warning", result.stdout)

    def test_check_fails_a_malformed_digest(self):
        since = self.commits("ci: tick the nightly")
        notes = self.build(since, build="15")
        notes["whatsNew"]["entries"][0]["docs"] = "http://cmux.com/not-https"
        path = os.path.join(self.repo, "out", "15.json")
        with open(path, "w") as f:
            json.dump(notes, f)
        result = self.check(path)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("docs must be an https URL", result.stderr)

    def test_a_highlight_sharing_the_generic_id_is_not_taken_for_it(self):
        # Review of #25987: a real highlight named fixes-and-improvements.md gets the generic
        # entry's id; check treats it as a normal entry (no warning), even with tryIt and no docs.
        since = self.head
        with open(os.path.join(self.repo, "release-notes/next/highlights/fixes-and-improvements.md"), "w") as f:
            f.write("title: Fixes and improvements\naction: palette.checkForUpdates | Try it\n\nTabs open faster.\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "-m", "docs: a highlight")
        self.head = git(self.repo, "rev-parse", "HEAD")
        notes = self.build(since, build="16")
        [entry] = notes["whatsNew"]["entries"]
        self.assertEqual((entry["id"], entry.get("docs")), ("fixes-and-improvements", None))
        result = self.check(os.path.join(self.repo, "out", "16.json"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ok: 1 What's New entries: Fixes and improvements", result.stdout)
        self.assertNotIn("::warning", result.stdout)
        self.assertEqual(result.summary, "")

    def test_check_passes_a_build_with_entries(self):
        since = self.commits("feat(next): click a background task to see everything it ran")
        notes = self.build(since, build="9")
        self.assertNotIn("fixes-and-improvements", [e["id"] for e in notes["whatsNew"]["entries"]])
        result = self.check(os.path.join(self.repo, "out", "9.json"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ok: 1 What's New entries: Click a background task to see everything it ran", result.stdout)
        self.assertNotIn("::warning", result.stdout)
        self.assertEqual(result.summary, "")


if __name__ == "__main__":
    unittest.main()
