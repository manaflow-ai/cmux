#!/usr/bin/env python3
"""Behavioral coverage for published-range nightly notes and Sparkle feeds."""

import importlib.util
from pathlib import Path
import re
import sys
import tempfile
import unittest
import unittest.mock
from unittest.mock import Mock
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "nightly_release_notes", ROOT / "scripts/ci/nightly_release_notes.py"
)
assert SPEC and SPEC.loader
NOTES = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = NOTES
SPEC.loader.exec_module(NOTES)

REPO = "manaflow-ai/cmux"
BASE = "a" * 40
HEAD = "b" * 40
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
APPCASTS = ("appcast-arm64.xml", "appcast-x86_64.xml", "appcast-universal.xml", "appcast.xml")


def pull_request(number, title, *, day=1, labels=(), paths=("Sources/ContentView.swift",), total=None):
    return {
        "number": number,
        "title": title,
        "mergedAt": f"2026-10-{day:02d}T12:00:00Z",
        "url": f"https://github.com/{REPO}/pull/{number}",
        "labels": {"nodes": [{"name": label} for label in labels]},
        "files": {"totalCount": len(paths) if total is None else total,
                  "nodes": [{"path": path} for path in paths]},
    }


class PublishedShaTests(unittest.TestCase):
    def test_reads_full_publication_marker_case_insensitively(self):
        self.assertEqual(
            NOTES.published_sha(f"Nightly notes\n<!-- cmux-published-sha: {BASE.upper()} -->\n"), BASE
        )

    def test_missing_or_invalid_marker_is_not_a_published_baseline(self):
        for body in (
            "", f"Published commit: `{BASE}`", f"<!-- cmux-published-sha: {BASE[:-1]} -->",
            f"<!-- cmux-published-sha: {BASE}a -->", "<!-- cmux-published-sha: " + "z" * 40 + " -->",
        ):
            with self.subTest(body=body):
                self.assertIsNone(NOTES.published_sha(body))


class SummaryTests(unittest.TestCase):
    def summarize(self, prs, **kwargs):
        return NOTES.summarize(prs, REPO, BASE, HEAD, **kwargs)

    def test_groups_changes_and_sorts_each_group_newest_first(self):
        prs = [
            pull_request(10, "fix: older terminal repair", day=1),
            pull_request(11, "feat: add browser tabs", day=2),
            pull_request(12, "change tab defaults", day=3),
            pull_request(13, "fix: newer terminal repair", day=4),
        ]
        markdown, plain = self.summarize(prs)
        self.assertIn("Fixes", markdown)
        self.assertIn("New", markdown)
        self.assertIn("Changed defaults", markdown)
        self.assertLess(markdown.index("newer terminal repair"), markdown.index("older terminal repair"))
        self.assertIn("add browser tabs", markdown)
        self.assertIn("change tab defaults", markdown)
        self.assertLess(plain.index("newer terminal repair"), plain.index("change tab defaults"))
        for pr in prs:
            self.assertIn(pr["url"], markdown)

    def test_labels_override_feature_group_without_implying_refactors_change_defaults(self):
        markdown, _ = self.summarize([
            pull_request(10, "feat: browser policy", labels=("default call",)),
            pull_request(11, "feat: terminal policy", labels=("needs a call",)),
            pull_request(12, "refactor: simplify tab routing"),
        ])
        fixes, defaults = markdown.split("### Changed defaults", 1)
        self.assertIn("simplify tab routing", fixes)
        self.assertNotIn("browser policy", fixes)
        self.assertIn("browser policy", defaults)
        self.assertIn("terminal policy", defaults)

    def test_infrastructure_prefixes_and_file_only_changes_are_counted_once(self):
        prs = [
            pull_request(10, "ci: repair the runner", paths=(".github/workflows/ci.yml",)),
            pull_request(11, "docs: update guide", paths=("docs/contributing.md",)),
            pull_request(12, "test: cover the updater", paths=("tests/test_updater.py",)),
            pull_request(13, "repair guard timeout", paths=("scripts/ci/guard.py",)),
            pull_request(14, "fix: restore terminal selection", paths=("Sources/ContentView.swift",)),
        ]
        markdown, plain = self.summarize(prs)
        self.assertIn("Infrastructure: 4", markdown)
        for result in (markdown, plain):
            self.assertIn("restore terminal selection", result)
            self.assertNotIn("repair the runner", result)
            self.assertNotIn("update guide", result)
            self.assertNotIn("cover the updater", result)
            self.assertNotIn("repair guard timeout", result)

    def test_mixed_files_and_truncated_file_list_are_not_hidden_as_infrastructure(self):
        markdown, plain = self.summarize([
            pull_request(10, "restore remote tabs", paths=("scripts/ci/check.py", "Sources/RemoteTab.swift")),
            pull_request(11, "restore session behavior", paths=("tests/test_session.py",), total=200),
        ])
        for result in (markdown, plain):
            self.assertIn("restore remote tabs", result)
            self.assertIn("restore session behavior", result)

    def test_title_is_a_single_escaped_markdown_line(self):
        title = "fix: render [tabs](https://evil.invalid) *safely* `now`\n## injected heading"
        markdown, plain = self.summarize([pull_request(10, title)])
        self.assertNotIn("\n## injected heading", markdown)
        self.assertIn(r"\[tabs\]", markdown)
        self.assertIn(r"\*safely\*", markdown)
        self.assertNotIn("[tabs](https://evil.invalid)", markdown)
        self.assertIn("render [tabs](https://evil.invalid) *safely* `now`", plain)
        self.assertIn("injected heading", plain)

    def test_total_limit_keeps_newest_user_changes_and_counts_all_infrastructure(self):
        prs = [pull_request(number, f"fix: user change {number:03d}", day=number % 28 + 1)
               for number in range(1, 44)]
        prs += [pull_request(100, "ci: old guard", day=1), pull_request(101, "docs: new guide", day=28)]
        markdown, plain = self.summarize(prs)
        ordered = sorted(prs[:43], key=lambda pr: (pr["mergedAt"], pr["number"]), reverse=True)
        for pr in ordered[:40]:
            self.assertIn(pr["title"], markdown)
        for pr in ordered[40:]:
            self.assertNotIn(pr["title"], markdown)
        self.assertIn("and 3 more", markdown)
        self.assertIn("Infrastructure: 2", markdown)
        for pr in ordered[:5]:
            self.assertIn(pr["title"], plain)
        self.assertNotIn(ordered[5]["title"], plain)
        self.assertIn(f"https://github.com/{REPO}/compare/{BASE}...{HEAD}", markdown)

    def test_limit_is_shared_across_sections(self):
        markdown, plain = self.summarize([
            pull_request(1, "fix: old repair", day=1),
            pull_request(2, "feat: new feature", day=3),
            pull_request(3, "refactor: recent behavior", day=2),
        ], limit=2)
        self.assertNotIn("old repair", markdown)
        self.assertIn("new feature", markdown)
        self.assertIn("recent behavior", markdown)
        self.assertIn("and 1 more", markdown)

    def test_missing_baseline_reports_unavailable_range_without_inventing_changes(self):
        markdown, plain = NOTES.summarize([], REPO, None, HEAD)
        self.assertIn("not recorded", markdown)
        self.assertNotIn("/compare/", markdown)
        self.assertTrue(plain)


class CollectionTests(unittest.TestCase):
    # The merged PRs of a published range are the PRs merged into the branch
    # whose merge commit is in the range. They are read from the branch's merged
    # PR list (newest update first, stopping a day before the base commit), not
    # per commit: per-commit association queries timed out (HTTP 504) on the
    # 1669-commit nightly-next range of run 37593192286, and run 37611677848 spent
    # 29 of its 30 publish minutes on them before the job was cancelled.
    BASE_DATE = "2026-10-05T12:00:00Z"

    def compare(self, *shas, total=None, status="ahead"):
        return {"status": status, "total_commits": len(shas) if total is None else total,
                "commits": [{"sha": sha} for sha in shas],
                "base_commit": {"commit": {"committer": {"date": self.BASE_DATE}}}}

    def github(self, responses, pages):
        github = Mock(repo=REPO)
        github.rest.side_effect = responses
        calls = []

        def graphql(query):
            calls.append(query)
            after = re.search(r'after: "([^"]+)"', query)
            index = int(after.group(1)) if after else 0
            nodes, more = pages[index]
            return {"pullRequests": {"pageInfo": {"hasNextPage": more, "endCursor": str(index + 1)},
                                     "nodes": nodes}}

        github.graphql.side_effect = graphql
        github.calls = calls
        return github

    def merged(self, number, sha, branch="main", updated="2026-10-06T12:00:00Z", **kwargs):
        return {**pull_request(number, f"fix: change {number}", **kwargs),
                "baseRefName": branch, "mergeCommit": {"oid": sha}, "updatedAt": updated}

    def test_collects_only_prs_merged_into_the_branch_inside_the_range(self):
        first, second, outside = "c" * 40, "d" * 40, "e" * 40
        expected = self.merged(10, second)
        unmerged = {**self.merged(13, first), "mergedAt": None, "mergeCommit": None}
        github = self.github([self.compare(first, second)],
                             [([expected, self.merged(11, outside), unmerged,
                                self.merged(12, first, branch="release")], False)])
        self.assertEqual(NOTES.collect_prs(github, BASE, HEAD, "main"), [expected])
        github.rest.assert_called_once_with(f"compare/{BASE}...{HEAD}?per_page=100&page=1")
        self.assertIn('baseRefName: "main"', github.calls[0])
        self.assertIn("states: MERGED", github.calls[0])
        self.assertNotIn("associatedPullRequests", github.calls[0])

    def test_compare_pagination_does_not_lose_later_merged_prs(self):
        first, second = "c" * 40, "d" * 40
        expected = self.merged(10, second)
        github = self.github([self.compare(first, total=2), self.compare(second, total=2)],
                             [([expected], False)])
        self.assertEqual(NOTES.collect_prs(github, BASE, HEAD, "main"), [expected])
        self.assertEqual([call.args[0] for call in github.rest.call_args_list],
                         [f"compare/{BASE}...{HEAD}?per_page=100&page={page}" for page in (1, 2)])

    def test_pages_while_prs_were_updated_after_the_base_commit(self):
        sha = "c" * 40
        expected = self.merged(10, sha, updated="2026-10-05T00:00:00Z")
        github = self.github([self.compare(sha)],
                             [([self.merged(20, "f" * 40, updated="2026-10-07T00:00:00Z")], True),
                              ([expected], False)])
        self.assertEqual(NOTES.collect_prs(github, BASE, HEAD, "main"), [expected])
        self.assertEqual(len(github.calls), 2)

    def test_stops_paging_a_day_before_the_base_commit(self):
        sha = "c" * 40
        github = self.github([self.compare(sha)],
                             [([self.merged(20, "f" * 40, updated="2026-10-04T00:00:00Z")], True),
                              ([self.merged(10, sha)], False)])
        self.assertEqual(NOTES.collect_prs(github, BASE, HEAD, "main"), [])
        self.assertEqual(len(github.calls), 1)

    def test_a_branch_without_merged_prs_costs_one_query(self):
        github = self.github([self.compare(*[f"{n:040x}" for n in range(1, 1700)], total=1699)], [([], False)])
        github.rest.side_effect = [self.compare(*[f"{n:040x}" for n in range(1 + 100 * p, 101 + 100 * p)], total=1699)
                                   for p in range(17)]
        self.assertEqual(NOTES.collect_prs(github, BASE, HEAD, "nightly-next"), [])
        self.assertEqual(len(github.calls), 1)

    def test_endless_pages_fail_instead_of_looping(self):
        sha = "c" * 40
        github = Mock(repo=REPO)
        github.rest.side_effect = [self.compare(sha)]
        github.graphql.return_value = {"pullRequests": {"pageInfo": {"hasNextPage": True, "endCursor": "x"},
                                                        "nodes": [self.merged(1, "f" * 40, updated="2026-10-07T00:00:00Z")]}}
        with self.assertRaisesRegex(RuntimeError, "merged PRs"):
            NOTES.collect_prs(github, BASE, HEAD, "main")

    def test_identical_publication_needs_no_metadata_requests(self):
        github = Mock(repo=REPO)
        self.assertEqual(NOTES.collect_prs(github, HEAD, HEAD, "main"), [])
        github.rest.assert_not_called()
        github.graphql.assert_not_called()

    def test_diverged_baseline_fails_instead_of_claiming_a_release_range(self):
        github = self.github([self.compare("c" * 40, status="diverged")], [])
        with self.assertRaisesRegex(RuntimeError, "ancestor"):
            NOTES.collect_prs(github, BASE, HEAD, "main")
        github.graphql.assert_not_called()

    def test_incomplete_compare_metadata_fails_instead_of_silently_omitting_prs(self):
        github = self.github([self.compare(total=1)], [])
        with self.assertRaisesRegex(RuntimeError, "pagination"):
            NOTES.collect_prs(github, BASE, HEAD, "main")

    def test_request_retries_a_transient_server_error(self):
        responses = iter([(1, "", "gh: HTTP 504"), (1, "", "unexpected end of JSON input"), (0, '{"ok": true}', "")])

        def run(*args, **kwargs):
            code, out, err = next(responses)
            return Mock(returncode=code, stdout=out, stderr=err)

        with unittest.mock.patch.object(NOTES.subprocess, "run", side_effect=run), \
                unittest.mock.patch.object(NOTES.time, "sleep"):
            self.assertEqual(NOTES.GitHub.request(["graphql"]), {"ok": True})

    def test_request_fails_at_once_on_a_client_error(self):
        with unittest.mock.patch.object(NOTES.subprocess, "run",
                                        return_value=Mock(returncode=1, stdout="", stderr="gh: HTTP 403")), \
                unittest.mock.patch.object(NOTES.time, "sleep") as sleep:
            with self.assertRaisesRegex(RuntimeError, "metadata request failed"):
                NOTES.GitHub.request(["graphql"])
            sleep.assert_not_called()


class AppcastTests(unittest.TestCase):
    def write_feeds(self, directory, build="102"):
        for name in APPCASTS:
            (directory / name).write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE}"><channel>
<title>cmux nightly</title>
<item><title>Current nightly</title><sparkle:version>{build}</sparkle:version>
<description><![CDATA[Previous current description]]></description>
<enclosure url="https://example.invalid/current.dmg" sparkle:version="{build}" sparkle:edSignature="current-signature" length="345" type="application/octet-stream" /></item>
<item><title>Old nightly</title><sparkle:version>101</sparkle:version>
<description><![CDATA[Old <b>description</b> & unchanged]]></description>
<enclosure url="https://example.invalid/old.dmg" sparkle:version="101" sparkle:edSignature="old-signature" length="123" type="application/octet-stream" /></item>
</channel></rss>
''', encoding="utf-8")

    def test_updates_only_current_description_and_preserves_signatures_and_old_item(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_feeds(directory)
            before = {name: ET.parse(directory / name).getroot() for name in APPCASTS}
            summary = 'Fixes\n- Restore tabs <views> & "selection"\n- Handle ]]> safely'
            NOTES.update_appcasts(directory, "102", summary)
            for name in APPCASTS:
                with self.subTest(feed=name):
                    root = ET.parse(directory / name).getroot()
                    old_items = before[name].findall("channel/item")
                    items = root.findall("channel/item")
                    self.assertEqual(len(items), 2)
                    self.assertEqual(items[0].findtext("description"), summary)
                    self.assertEqual(items[0].findtext("title"), old_items[0].findtext("title"))
                    self.assertEqual(items[0].find("enclosure").attrib, old_items[0].find("enclosure").attrib)
                    self.assertEqual(ET.tostring(items[1]), ET.tostring(old_items[1]))

    def test_the_arm64_only_track_updates_its_one_feed(self):
        """nightly-next publishes only the arm64 variant: one feed, and a missing one still fails."""
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_feeds(directory)
            for name in APPCASTS[1:]:
                (directory / name).unlink()
            NOTES.update_appcasts(directory, "102", "Fresh notes", feeds=("appcast-arm64.xml",))
            self.assertEqual(ET.parse(directory / "appcast-arm64.xml").findtext("channel/item/description"), "Fresh notes")
            with self.assertRaises(RuntimeError):
                NOTES.update_appcasts(directory, "102", "Fresh notes")
            (directory / "appcast-arm64.xml").unlink()
            with self.assertRaises(RuntimeError):
                NOTES.update_appcasts(directory, "102", "Fresh notes", feeds=("appcast-arm64.xml",))

    def test_missing_feeds_fail_instead_of_silently_publishing_without_updater_notes(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with self.assertRaises((RuntimeError, FileNotFoundError)):
                NOTES.update_appcasts(directory, "102", "Current notes")

    def test_missing_current_build_fails_instead_of_rewriting_old_item(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_feeds(directory, build="100")
            with self.assertRaises(RuntimeError):
                NOTES.update_appcasts(directory, "102", "Current notes")

    def test_enclosure_version_identifies_current_item_without_version_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_feeds(directory)
            for name in APPCASTS:
                feed = directory / name
                feed.write_text(feed.read_text().replace("<sparkle:version>102</sparkle:version>", ""))
            NOTES.update_appcasts(directory, "102", "Fresh notes")
            for name in APPCASTS:
                self.assertEqual(ET.parse(directory / name).findtext("channel/item/description"), "Fresh notes")

    def test_ambiguous_current_item_fails_before_any_feed_is_changed(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_feeds(directory)
            feed = directory / "appcast.xml"
            feed.write_text(feed.read_text().replace("101", "102"))
            before = {name: (directory / name).read_bytes() for name in APPCASTS}
            with self.assertRaises(RuntimeError):
                NOTES.update_appcasts(directory, "102", "Fresh notes")
            self.assertEqual(before, {name: (directory / name).read_bytes() for name in APPCASTS})

    def test_later_feed_without_current_build_does_not_partially_update_other_feeds(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_feeds(directory)
            feed = directory / "appcast.xml"
            feed.write_text(feed.read_text().replace("102", "100"))
            before = {name: (directory / name).read_bytes() for name in APPCASTS}
            with self.assertRaises(RuntimeError):
                NOTES.update_appcasts(directory, "102", "Fresh notes")
            self.assertEqual(before, {name: (directory / name).read_bytes() for name in APPCASTS})



class MetadataFallbackTests(unittest.TestCase):
    """A publish is never lost to GitHub metadata: the notes degrade, the marker stays."""

    def run_main(self, directory, collect):
        AppcastTests.write_feeds(None, directory)
        details = directory / "downloads.md"
        details.write_text("Download links\n")
        out = directory / "notes.md"
        github = Mock(repo=REPO)
        github.rest.return_value = {"body": f"<!-- cmux-published-sha: {BASE} -->\nOld notes"}
        argv = ["nightly_release_notes.py", "--repo", REPO, "--tag", "nightly-next", "--head", HEAD,
                "--branch", "nightly-next", "--details", str(details), "--out", str(out),
                "--appcasts", str(directory), "--build", "102"]
        with unittest.mock.patch.object(NOTES, "GitHub", return_value=github), \
                unittest.mock.patch.object(NOTES, "collect_prs", side_effect=collect), \
                unittest.mock.patch.object(sys, "argv", argv):
            return NOTES.main(), out

    def test_metadata_failure_publishes_minimal_notes_with_the_marker(self):
        failure = RuntimeError("GitHub metadata request failed; check Actions token")
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            status, out = self.run_main(directory, failure)
            self.assertEqual(status, 0)
            body = out.read_text()
            self.assertIn(f"https://github.com/{REPO}/compare/{BASE}...{HEAD}", body)
            self.assertIn("Download links", body)
            published = out.with_suffix(".published.md").read_text()
            self.assertTrue(published.startswith(f"<!-- cmux-published-sha: {HEAD} -->"))
            feed = ET.parse(directory / "appcast.xml").getroot()
            current = [item for item in feed.iter("item") if item.findtext(f"{{{SPARKLE}}}version") == "102"][0]
            self.assertIn("compare", current.findtext("description"))

    def test_a_transient_metadata_timeout_also_degrades(self):
        with tempfile.TemporaryDirectory() as temporary:
            status, out = self.run_main(Path(temporary), NOTES.TransientGitHubError("kept timing out"))
            self.assertEqual(status, 0)
            self.assertTrue(out.with_suffix(".published.md").read_text().startswith(f"<!-- cmux-published-sha: {HEAD} -->"))

    def test_a_broken_appcast_still_fails_the_publish(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            AppcastTests.write_feeds(None, directory)
            (directory / "appcast.xml").unlink()
            details = directory / "downloads.md"
            details.write_text("Download links\n")
            github = Mock(repo=REPO)
            github.rest.return_value = {"body": ""}
            argv = ["nightly_release_notes.py", "--repo", REPO, "--tag", "nightly-next", "--head", HEAD,
                    "--branch", "nightly-next", "--details", str(details), "--out", str(directory / "notes.md"),
                    "--appcasts", str(directory), "--build", "102"]
            with unittest.mock.patch.object(NOTES, "GitHub", return_value=github), \
                    unittest.mock.patch.object(sys, "argv", argv), self.assertRaises(RuntimeError):
                NOTES.main()


class WorkflowTests(unittest.TestCase):
    def test_nightly_next_notes_read_prs_merged_into_feat_cmux_next(self):
        # A nightly-next run is a push to the nightly-next branch, but its PRs
        # merge into feat-cmux-next: with github.ref_name every publish listed
        # 0 PRs (run 37611677848).
        workflow = (ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
        step = workflow[workflow.index("- name: Prepare nightly release notes and appcast summaries"):]
        step = step[:step.index("\n      - name:", 1)]
        branch = re.search(r"NOTES_BRANCH: (.+)", step).group(1)
        self.assertEqual(
            branch,
            "${{ needs.decide.outputs.track == 'nightly-next' && 'feat-cmux-next' || github.ref_name }}",
        )

    def test_notes_cannot_spend_the_publish_budget_before_the_upload(self):
        # Run 37611677848 spent 29 of publish-nightly's 30 minutes on the notes,
        # so the job was cancelled mid-upload and left partial release assets.
        # The notes step has its own bound, well inside the job's, so a slow
        # notes run fails before any asset is uploaded.
        workflow = (ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
        job = workflow[workflow.index("\n  publish-nightly:\n"):]
        job = job[:re.search(r"\n  [A-Za-z0-9_-]+:\n", job[1:]).start() + 1]
        job_timeout = int(re.search(r"^    timeout-minutes: (\d+)$", job, re.M).group(1))
        step = job[job.index("- name: Prepare nightly release notes and appcast summaries"):]
        step = step[:step.index("\n      - name:", 1)]
        bound = re.search(r"^        timeout-minutes: (\d+)$", step, re.M)
        self.assertIsNotNone(bound, "the notes step needs its own timeout-minutes")
        self.assertLessEqual(int(bound.group(1)) + 15, job_timeout,
                             "the job must keep 15 minutes for downloads and the asset upload after the notes")
        self.assertLess(job.index("Prepare nightly release notes"), job.index("- name: Publish nightly release assets"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
