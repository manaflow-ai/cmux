#!/usr/bin/env python3
"""Behavior of the cmux-next INTERNAL iOS builder's TestFlight "What to Test" notes.

scripts/ci/ios_internal_notes.py turns the `## Changelog` lines of the PRs in
BASE..SHA into the note every upload carries, and finds BASE again when the
dispatch does not know it. Design: plans/cmux-next/ios-testflight-builder-DESIGN.md.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ios_internal_notes", ROOT / "scripts/ci/ios_internal_notes.py")
notes = importlib.util.module_from_spec(SPEC)
sys.modules["ios_internal_notes"] = notes
SPEC.loader.exec_module(notes)

E = notes.Entry
SHA = "80357c06808ae21e2296631f4476ce556f8a60a1"
BASE = "3e6a2b56eff57cf29c268d731df3a3f92a902c87"

TEMPLATE_BODY = """## Summary

Does a thing.

## Changelog

<!--
Keep this section. Write one line for the release notes, or `none` for internal-only changes.
Example: Fixed: Closing the last workspace no longer unfolds a collapsed sidebar group above it
-->

{changelog}

## Proof

CI only.
"""


def body(changelog: str) -> str:
    return TEMPLATE_BODY.format(changelog=changelog)


class ParseChangelogTests(unittest.TestCase):
    def test_missing_section_is_none(self):
        self.assertIsNone(notes.parse_changelog("## Summary\n\nFixed: not in a changelog\n"))
        self.assertIsNone(notes.parse_changelog(None))
        self.assertIsNone(notes.parse_changelog(""))

    def test_section_with_only_the_template_comment_is_none(self):
        self.assertIsNone(notes.parse_changelog(body("")))

    def test_none_variants_are_empty(self):
        for text in ("none", "`none`", "- none", "None.", "none (CI only)", "N/A", "**none**", "Changed: none"):
            with self.subTest(text=text):
                self.assertEqual(notes.parse_changelog(body(text)), [])

    def test_one_line(self):
        self.assertEqual(notes.parse_changelog(body("Fixed: The terminal keeps its scrollback after a redial")),
                         [E("Fixed", "The terminal keeps its scrollback after a redial")])

    def test_multiple_lines_and_markdown_noise(self):
        text = "\n".join([
            "- **Added:** A *Send to Chief* button on every message",
            "* Changed - The [sidebar](https://example.com/x) remembers its width",
            "- [x] fixed: `cmux ssh` reconnects after sleep",
            "Removed — The old pairing sheet",
            "---",
        ])
        self.assertEqual(notes.parse_changelog(body(text)), [
            E("Added", "A Send to Chief button on every message"),
            E("Changed", "The sidebar remembers its width"),
            E("Fixed", "cmux ssh reconnects after sleep"),
            E("Removed", "The old pairing sheet"),
        ])

    def test_category_headings_and_lines_introduce_bullets(self):
        text = "### Added\n- Voice notes\n- Emoji reactions\n\nFixed:\n- Crash on launch\n"
        self.assertEqual(notes.parse_changelog(body(text)), [
            E("Added", "Voice notes"), E("Added", "Emoji reactions"), E("Fixed", "Crash on launch")])

    def test_a_line_with_no_category_is_changed(self):
        self.assertEqual(notes.parse_changelog(body("The keyboard hides on scroll")),
                         [E("Changed", "The keyboard hides on scroll")])

    def test_section_ends_at_the_next_heading_and_skips_code_fences(self):
        text = "Fixed: one\n```\nAdded: not a line\n```\n## Testing\nAdded: not in the changelog"
        self.assertEqual(notes.parse_changelog("## Changelog\n" + text), [E("Fixed", "One")])

    def test_footer_after_the_section_is_not_a_line(self):
        text = ("## Changelog\n\nFixed: A dark theme reports dark\n\nThis also needs the Ghostty bump.\n\n"
                "\U0001F916 Generated with [Claude Code](https://claude.com/claude-code)\n"
                '<a href="https://x"><picture></picture></a>\n<sup>Need help?</sup>\n')
        self.assertEqual(notes.parse_changelog(text), [E("Fixed", "A dark theme reports dark")])
        self.assertEqual(notes.parse_changelog("## Changelog\nAdded: X\n\n---\nCo-Authored-By: someone\nmore prose"),
                         [E("Added", "X")])

    def test_every_plain_bullet_is_a_line(self):
        self.assertEqual(notes.parse_changelog(body("- Foo works\n- Bar works")),
                         [E("Changed", "Foo works"), E("Changed", "Bar works")])
        self.assertEqual(notes.parse_changelog(body("Fixed: A\n- B also")), [E("Fixed", "A"), E("Fixed", "B also")])

    def test_a_line_that_starts_with_the_word_none_is_kept(self):
        self.assertEqual(notes.parse_changelog(body("None of the tabs flicker now")),
                         [E("Changed", "None of the tabs flicker now")])
        self.assertEqual(notes.parse_changelog(body("Fixed: None of the tabs flicker now")),
                         [E("Fixed", "None of the tabs flicker now")])
        self.assertEqual(notes.parse_changelog(body("none - CI only")), [])

    def test_collapsed_details_are_skipped(self):
        text = "Added: Shown\n<details>\n<summary>more</summary>\n\nAdded: hidden\n</details>\n- Also shown"
        self.assertEqual(notes.parse_changelog(body(text)), [E("Added", "Shown"), E("Added", "Also shown")])

    def test_crlf_bodies(self):
        self.assertEqual(notes.parse_changelog("## Changelog\r\n\r\nAdded: Dark icons\r\n"), [E("Added", "Dark icons")])

    def test_a_very_long_line_ends_at_a_word(self):
        text = "Fixed: " + " ".join(["word"] * 200)
        [entry] = notes.parse_changelog(body(text))
        self.assertLessEqual(len(entry.text), notes.ITEM_MAX)
        self.assertTrue(entry.text.endswith("word…"))


class GroupTests(unittest.TestCase):
    def test_groups_in_order_and_dedupes(self):
        groups = notes.group([
            E("Fixed", "Crash on launch"), E("Added", "Voice notes"), E(notes.OTHER, "Tidy up"),
            E("Fixed", "crash on launch."), E("Changed", "Voice notes"), E("Removed", "Old sheet"),
        ])
        self.assertEqual(list(groups), ["Added", "Fixed", "Removed", notes.OTHER])
        self.assertEqual(groups["Fixed"], ["Crash on launch"])
        self.assertEqual(groups["Added"], ["Voice notes"])


class SubjectFallbackTests(unittest.TestCase):
    def test_subject_under_other_changes(self):
        self.assertEqual(notes.subject_entry("fix(cnx-ios): the voice note intent says this device (#22000)"),
                         E(notes.OTHER, "The voice note intent says this device"))
        self.assertEqual(notes.subject_entry("cnx-ios: Action Button Chief call"), E(notes.OTHER, "Action Button Chief call"))

    def test_engineering_references_are_dropped(self):
        self.assertEqual(notes.subject_entry("cmux NEXT perf-palette3: a font size change rebuilds once (GhosttyNextKit ced99dcde, cx-8w027.24)"),
                         E(notes.OTHER, "A font size change rebuilds once"))
        self.assertEqual(notes.subject_entry("cmux NEXT: the menu works (in dark mode)"), E(notes.OTHER, "The menu works (in dark mode)"))

    def test_internal_subjects_are_dropped(self):
        for s in ("fix(ci): retire the signer", "cmux-next iOS: failing tests for the Action Button flow", "test(home): a click opens it (red)", "ci: bump", "cnx-ios: failing test: a duplicate pong",
                  "Merge origin/feat-cmux-next into feat-cmux-next", "docs: x", "chore: y", "lint: z"):
            with self.subTest(s=s):
                self.assertIsNone(notes.subject_entry(s))

    def test_only_tests(self):
        self.assertTrue(notes.only_tests(["cnx-ios/CnxAppTests/PingTests.swift", "Packages/iOS/X/Tests/Y/Z.swift"]))
        self.assertFalse(notes.only_tests(["cnx-ios/CnxApp/Ping.swift", "cnx-ios/CnxAppTests/PingTests.swift"]))
        self.assertTrue(notes.only_tests(["cnx-ios/scripts/testflight-build.sh", "cnx-ios/verify/plan.md"]))
        self.assertFalse(notes.only_tests([]))


def commit(oid: str, subject: str, files=("cnx-ios/CnxApp/A.swift",)) -> dict:
    return {"oid": oid, "subject": subject, "files": list(files)}


def pr(number: int, changelog: str | None, title: str = "A PR title") -> dict:
    return {"number": number, "title": title, "body": None if changelog is None else body(changelog)}


class BuildNoteTests(unittest.TestCase):
    def test_full_note(self):
        commits = [commit("1" * 40, "cnx-ios: fix the ping (#2)"), commit("2" * 40, "squash of #1 (#1)"),
                   commit("3" * 40, "cnx-ios: second commit of #1"), commit("4" * 40, "fix(cnx-ios): direct push"),
                   commit("5" * 40, "cnx-ios: test-only push", files=["cnx-ios/CnxAppTests/X.swift"])]
        prs = {"1" * 40: pr(2, "Fixed: The Cloud Chief ping answers once"),
               "2" * 40: pr(1, "Added: Voice notes\nnone"), "3" * 40: pr(1, "Added: Voice notes"),
               "4" * 40: None, "5" * 40: None}
        text = notes.build_note(sha=SHA, version="1.2.1", base=BASE, base_source="", commits=commits, prs=prs)
        self.assertEqual(text, "\n".join([
            "cmux-next iPhone 1.2.1, feat-cmux-next 80357c06808a. Internal testers only.",
            "",
            "Changes since the last build (3e6a2b56eff5):",
            "",
            "Added",
            "- Voice notes",
            "",
            "Fixed",
            "- The Cloud Chief ping answers once",
            "",
            notes.OTHER,
            "- Direct push",
        ]))

    def test_pr_with_none_adds_nothing_and_pr_without_section_uses_its_title(self):
        commits = [commit("1" * 40, "a"), commit("2" * 40, "b")]
        prs = {"1" * 40: pr(1, "none"), "2" * 40: pr(2, None, title="cnx-ios: terminal keeps scrollback")}
        text = notes.build_note(sha=SHA, version="1.2.1", base=BASE, base_source="", commits=commits, prs=prs)
        self.assertIn(f"{notes.OTHER}\n- Terminal keeps scrollback", text)
        self.assertEqual(text.count("\n- "), 1)

    def test_no_app_changes(self):
        text = notes.build_note(sha=SHA, version="1.2.1", base=BASE, base_source="", commits=[], prs={})
        self.assertTrue(text.endswith("No app changes since the last build (3e6a2b56eff5)."))

    def test_unknown_base_is_first_continuous_build_with_the_last_20_lines(self):
        commits = [commit(f"{i:040x}", f"s{i}") for i in range(1, 31)]
        prs = {c["oid"]: pr(i, f"Fixed: Item {i}") for i, c in enumerate(commits, 1)}
        text = notes.build_note(sha=SHA, version="1.2.1", base=None, base_source="", commits=commits, prs=prs)
        lines = text.splitlines()
        self.assertEqual(lines[2], "First continuous build. Recent changes:")
        self.assertEqual([l for l in lines if l.startswith("- ")], [f"- Item {i}" for i in range(1, 21)])

    def test_unknown_base_and_nothing_found_still_says_so(self):
        text = notes.build_note(sha=SHA, version=None, base=None, base_source="", commits=[], prs={})
        self.assertEqual(text, "cmux-next iPhone, feat-cmux-next 80357c06808a. Internal testers only.\n\nFirst continuous build.")

    def test_lead_line_records_the_commit_the_next_build_reads(self):
        text = notes.build_note(sha=SHA, version="1.2.1", base=BASE, base_source="", commits=[], prs={})
        self.assertEqual(notes.recorded_sha(text), SHA[:12])
        self.assertEqual(notes.recorded_sha("cmux-next iPhone, continuous build of feat-cmux-next 9218b994f0. Internal"), "9218b994f0")
        self.assertIsNone(notes.recorded_sha("Uploaded by hand"))


class TruncationTests(unittest.TestCase):
    def test_stays_under_the_limit_and_counts_what_it_left_out(self):
        groups = {"Fixed": [f"Fixed thing number {i} " + "x" * 80 for i in range(100)]}
        text = notes.format_note("lead", "intro", groups)
        self.assertLessEqual(notes.ui_len(text), notes.LIMIT)
        shown = sum(1 for l in text.splitlines() if l.startswith("- "))
        self.assertTrue(text.endswith(f"…and {100 - shown} more"))
        for line in text.splitlines():  # every shown line is whole
            if line.startswith("- "):
                self.assertTrue(line.endswith("x" * 80))

    def test_fits_exactly_without_a_more_line(self):
        groups = {"Added": ["a", "b"]}
        text = notes.format_note("lead", None, groups, limit=len("lead\n\nAdded\n- a\n- b"))
        self.assertEqual(text, "lead\n\nAdded\n- a\n- b")

    def test_counts_utf16_units_like_app_store_connect(self):
        self.assertEqual(notes.ui_len("a…\U0001F600"), 4)
        groups = {"Added": ["\U0001F600" * 30] * 3}
        text = notes.format_note("lead", None, groups, limit=80)
        self.assertLessEqual(notes.ui_len(text), 80)
        self.assertIn("more", text)


class PreviousBuildTests(unittest.TestCase):
    ASC = {
        "data": [{"type": "builds", "id": "b1", "attributes": {"version": "20261020175526", "processingState": "VALID"},
                  "relationships": {"betaBuildLocalizations": {"data": [{"type": "betaBuildLocalizations", "id": "l1"},
                                                                        {"type": "betaBuildLocalizations", "id": "l2"}]}}}],
        "included": [
            {"type": "betaBuildLocalizations", "id": "l2", "attributes": {"locale": "de-DE", "whatsNew": "feat-cmux-next 111111111111"}},
            {"type": "betaBuildLocalizations", "id": "l1", "attributes": {"locale": "en-US",
             "whatsNew": "cmux-next iPhone, continuous build of feat-cmux-next 9218b994f0. Internal testers only."}},
        ],
    }

    def test_reads_the_en_us_note_of_the_newest_build(self):
        self.assertEqual(notes.newest_build_ref(self.ASC), "9218b994f0")

    def test_no_build_or_no_recorded_commit(self):
        self.assertIsNone(notes.newest_build_ref({"data": []}))
        bare = {"data": self.ASC["data"], "included": [{"type": "betaBuildLocalizations", "id": "l1",
                                                       "attributes": {"locale": "en-US", "whatsNew": "by hand"}}]}
        self.assertIsNone(notes.newest_build_ref(bare))

    def test_last_successful_run_other_than_this_build(self):
        runs = [
            {"id": 9, "sha": SHA, "conclusion": "success", "created_at": "2026-10-20T18:00:00Z"},
            {"id": 8, "sha": "a" * 40, "conclusion": "failure", "created_at": "2026-10-20T17:00:00Z"},
            {"id": 7, "sha": "b" * 40, "conclusion": "success", "created_at": "2026-10-20T16:00:00Z"},
            {"id": 3, "sha": BASE, "conclusion": "success", "created_at": "2026-10-20T00:25:25Z"},
        ]
        self.assertEqual(notes.pick_previous_run(runs, SHA, "10"), "b" * 40)
        self.assertEqual(notes.pick_previous_run(runs[:2], SHA, None), None)

    def test_pick_pr_prefers_the_merge_commit_then_the_branch(self):
        oid = "c" * 40
        other = {"number": 1, "merged": True, "baseRefName": "feat-cnx-ios", "mergeCommit": {"oid": "d" * 40}}
        into_next = {"number": 2, "merged": True, "baseRefName": "feat-cmux-next", "mergeCommit": {"oid": "e" * 40}}
        squash = {"number": 3, "merged": True, "baseRefName": "main", "mergeCommit": {"oid": oid}}
        open_pr = {"number": 4, "merged": False, "baseRefName": "feat-cmux-next", "mergeCommit": None}
        self.assertEqual(notes.pick_pr(oid, [other, into_next, squash], None)["number"], 3)
        self.assertEqual(notes.pick_pr(oid, [other, into_next], None)["number"], 2)
        self.assertEqual(notes.pick_pr(oid, [other], None)["number"], 1)
        self.assertIsNone(notes.pick_pr(oid, [open_pr], None))
        self.assertEqual(notes.pick_pr(oid, [], {"number": 5, "merged": True})["number"], 5)


class AscTokenTests(unittest.TestCase):
    def test_es256_signature_verifies(self):
        with tempfile.TemporaryDirectory() as tmp:
            key, pub = Path(tmp, "AuthKey_TEST.p8"), Path(tmp, "pub.pem")
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(key)],
                           check=True, capture_output=True)
            subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-out", str(pub)], check=True, capture_output=True)
            token = notes.asc_token("KEYID", "issuer-uuid", str(key), now=1_700_000_000)
            header, claims, sig = token.split(".")
            import base64, json
            pad = lambda s: base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
            self.assertEqual(json.loads(pad(header)), {"alg": "ES256", "kid": "KEYID", "typ": "JWT"})
            self.assertEqual(json.loads(pad(claims))["aud"], "appstoreconnect-v1")
            raw = pad(sig)
            self.assertEqual(len(raw), 64)

            def der_int(b: bytes) -> bytes:
                b = b.lstrip(b"\x00") or b"\x00"
                if b[0] & 0x80:
                    b = b"\x00" + b
                return b"\x02" + bytes([len(b)]) + b
            seq = der_int(raw[:32]) + der_int(raw[32:])
            der = b"\x30" + bytes([len(seq)]) + seq
            sig_path = Path(tmp, "sig.der")
            sig_path.write_bytes(der)
            verify = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(pub), "-signature", str(sig_path)],
                                    input=f"{header}.{claims}".encode(), capture_output=True)
            self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)


class GitRangeTests(unittest.TestCase):
    """app_commits and find_base on a scratch repository."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        self.git("init", "-q", "-b", "feat-cmux-next")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.base = self.commit("cmux-next-ios/project.yml", "settings:\n  MARKETING_VERSION: 1.2.1\n", "base")
        self.commit("web/x.ts", "x", "web only")
        # An app commit from before the cnx-ios -> cmux-next-ios rename still counts.
        self.commit("cnx-ios/CnxApp/A.swift", "a", "fix(cnx-ios): app change (#7)")
        self.commit("Packages/iOS/CmuxTabsKit/T.swift", "t", "tabs change")
        self.head = self.commit("cmux-next-ios/CmuxMobileKit/Package.swift", '.package(path: "../../Packages/iOS/CmuxTabsKit"),', "pkg")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", self.repo, *args], check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, path, content, message):
        p = Path(self.repo, path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
        self.git("add", path)
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def test_app_commits_follow_the_packages_at_the_head(self):
        prefixes = notes.app_prefixes(self.repo, self.head)
        self.assertIn("Packages/iOS/CmuxTabsKit/", prefixes)
        subjects = [c["subject"] for c in notes.app_commits(self.repo, [f"{self.base}..{self.head}"], prefixes)]
        self.assertEqual(subjects, ["pkg", "tabs change", "fix(cnx-ios): app change (#7)"])
        self.assertEqual(notes.app_version(self.repo, self.head), "1.2.1")

    def test_find_base_prefers_the_input_then_app_store_connect(self):
        self.assertEqual(notes.find_base(self.repo, self.head, self.base, None), (self.base, ""))
        self.assertEqual(notes.find_base(self.repo, self.head, None, self.base[:12]), (self.base, "from App Store Connect"))
        self.assertEqual(notes.find_base(self.repo, self.head, "not-a-sha", self.base[:10]), (self.base, "from App Store Connect"))

    def test_find_base_skips_a_candidate_equal_to_the_build(self):
        notes_builder_runs, notes.builder_runs = notes.builder_runs, lambda: []
        try:
            self.assertEqual(notes.find_base(self.repo, self.head, self.head, self.base[:12]), (self.base, "from App Store Connect"))
            self.assertEqual(notes.find_base(self.repo, self.head, None, self.head[:12]), (None, ""))
        finally:
            notes.builder_runs = notes_builder_runs


class BatchTests(unittest.TestCase):
    def test_a_refused_item_falls_back_alone(self):
        def read(batch):
            if any(c["oid"] == "bad" for c in batch):
                raise subprocess.CalledProcessError(1, "gh")
            return {c["oid"]: 1 for c in batch}
        items = [{"oid": o} for o in ("a", "b", "bad", "c", "d")]
        self.assertEqual(notes._batched(items, 4, read), {"a": 1, "b": 1, "bad": None, "c": 1, "d": 1})
        self.assertEqual(notes._batched([7, 8], 2, lambda b: (_ for _ in ()).throw(subprocess.CalledProcessError(1, "gh"))),
                         {7: None, 8: None})


class WorkflowTests(unittest.TestCase):
    """The note is written where no signing secret is, and the signer only reads it."""

    @staticmethod
    def jobs() -> dict[str, str]:
        text = (ROOT / ".github/workflows/ios-internal-nightly.yml").read_text()
        body = text.split("\njobs:\n", 1)[1]
        parts = re.split(r"(?m)^  ([A-Za-z][\w-]*):\n", body)
        return dict(zip(parts[1::2], parts[2::2]))

    def test_notes_job_has_no_secret_and_a_read_only_token(self):
        notes_job = self.jobs()["notes"]
        self.assertNotIn("secrets.", notes_job)
        self.assertNotIn("environment:", notes_job)
        self.assertNotIn("write", notes_job.split("permissions:", 1)[1].split("env:", 1)[0])
        self.assertIn("ios_internal_notes.py notes", notes_job)

    def test_previous_build_holds_only_the_app_store_connect_key(self):
        job = self.jobs()["previous-build"]
        self.assertEqual(set(re.findall(r"secrets\.(\w+)", job)), {"ASC_API_KEY_ID", "ASC_API_ISSUER_ID", "ASC_API_KEY_P8_BASE64"})
        self.assertIn("inputs.base == ''", job)
        self.assertIn("continue-on-error: true", job)

    def test_signer_reads_the_note_and_writes_none(self):
        upload = self.jobs()["upload"]
        self.assertIn("cnx-ios-internal-notes-${{ github.run_id }}", upload)
        self.assertIn("needs: [archive, notes]", upload)
        self.assertNotIn("git log", upload)
        self.assertNotIn("ios_internal_notes.py", upload)


if __name__ == "__main__":
    unittest.main()
