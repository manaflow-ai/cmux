#!/usr/bin/env python3
"""Tests for validate.py: good fixtures pass, each bad fixture fails for its reason.

  python3 scripts/whats-new/test_validate.py
"""
import copy, io, json, os, struct, sys, tempfile, unittest, zlib
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import validate  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")


def all_languages(text):
    return {language: text for language in validate.LANGUAGES}


def tiny_png():
    raw = b"\x00\x00\x00\x00"
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def nightly_document():
    with open(os.path.join(FIXTURES, "good/1.0.0-nightly.42.json"), encoding="utf-8") as f:
        return json.load(f)


def stable_document():
    return {
        "schemaVersion": 1, "version": "0.66.0", "channel": "stable", "date": "2026-10-07",
        "headline": all_languages("Agents in every pane"),
        "entries": [{
            "id": "agent-pane", "category": "new",
            "title": all_languages("Run an agent beside any terminal"),
            "summary": all_languages("Open an agent chat next to your work and keep both in view."),
            "media": {"kind": "image", "light": "media/0.66.0/agent-pane-light.png",
                      "dark": "media/0.66.0/agent-pane-dark.png", "alt": all_languages("An agent chat beside a terminal")},
            "tryIt": {"action": "palette.newAgentChat"},
            "platforms": ["macos"], "audience": "all",
        }],
    }


class ValidateTests(unittest.TestCase):
    def problems(self, name):
        return validate.validate_file(os.path.join(FIXTURES, name))

    def assertMentions(self, problems, *fragments):
        text = "\n".join(problems)
        for fragment in fragments:
            self.assertIn(fragment, text)

    def test_good_nightly_fixture_passes(self):
        self.assertEqual(self.problems("good/1.0.0-nightly.42.json"), [])

    def test_internal_names_are_refused(self):
        problems = self.problems("bad/internal-names.json")
        self.assertMentions(problems, "a beads issue id", "an issue or PR number", "a commit SHA",
                            "a branch name", "a decision codename", "an internal repo or lane name")

    def test_entry_needs_try_it_or_docs(self):
        self.assertMentions(self.problems("bad/no-try-it-or-docs.json"), "needs a tryIt action/deeplink or a docs link")

    def test_stable_needs_every_language_and_media_for_new(self):
        problems = self.problems("bad/stable-missing-languages-and-media.json")
        self.assertMentions(problems, "missing languages", "'zh-Hant'", "a new feature needs media")

    def test_a_draft_skips_language_and_media_completeness_only(self):
        problems = validate.validate_file(os.path.join(FIXTURES, "bad/stable-missing-languages-and-media.json"), draft=True)
        self.assertNotIn("missing languages", "\n".join(problems))
        self.assertNotIn("needs media", "\n".join(problems))
        self.assertMentions(validate.validate_file(os.path.join(FIXTURES, "bad/internal-names.json"), draft=True), "a beads issue id")

    def test_shape_errors(self):
        problems = self.problems("bad/shape-errors.json")
        self.assertMentions(problems, "schemaVersion: must be 1", "version: must be X.Y.Z", "channel: must be one of",
                            "date: must be YYYY-MM-DD", "unknown keys ['extra']", "id must be lowercase",
                            "category must be one of", "tryIt must have exactly one", "docs must be an https URL",
                            "platforms must be", "audience must be one of", "id is used twice", "ends with a period")

    def test_summary_over_two_sentences(self):
        document = nightly_document()
        document["entries"][0]["summary"]["en"] = "One. Two. Three."
        self.assertMentions(validate.validate_document("1.0.0-nightly.42.json", document), "more than 2 sentences")

    def test_length_limits(self):
        document = nightly_document()
        document["entries"][0]["title"]["en"] = "x" * 61
        self.assertMentions(validate.validate_document("1.0.0-nightly.42.json", document), "61 characters (limit 60)")

    def test_channel_must_match_version(self):
        document = nightly_document()
        document["channel"] = "stable"
        self.assertMentions(validate.validate_document("1.0.0-nightly.42.json", document), "is 'stable' but version")

    def test_stable_with_every_language_and_media_passes(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "media/0.66.0"))
            for appearance in ("light", "dark"):
                with open(os.path.join(root, f"media/0.66.0/agent-pane-{appearance}.png"), "wb") as f:
                    f.write(tiny_png())
            path = os.path.join(root, "0.66.0.json")
            with open(path, "w") as f:
                json.dump(stable_document(), f)
            self.assertEqual(validate.validate_file(path), [])

    def test_missing_media_file_fails(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "0.66.0.json")
            with open(path, "w") as f:
                json.dump(stable_document(), f)
            self.assertMentions(validate.validate_file(path), "agent-pane-light.png does not exist")

    def test_media_path_cannot_escape(self):
        document = stable_document()
        document["entries"][0]["media"]["light"] = "media/../../secret.png"
        self.assertMentions(validate.validate_document("0.66.0.json", document), "must be a path under media/")

    def test_require_version_fails_without_the_file(self):
        with tempfile.TemporaryDirectory() as root, redirect_stdout(io.StringIO()) as out:
            code = validate.main(["--root", root, "--require-version", "0.66.0"])
        self.assertEqual(code, 1)
        self.assertIn("0.66.0.json: missing", out.getvalue())

    def test_require_version_passes_with_a_valid_file(self):
        with tempfile.TemporaryDirectory() as root:
            document = copy.deepcopy(stable_document())
            document["entries"][0].pop("media")
            document["entries"][0]["category"] = "improved"
            with open(os.path.join(root, "0.66.0.json"), "w") as f:
                json.dump(document, f)
            with redirect_stdout(io.StringIO()):
                self.assertEqual(validate.main(["--root", root, "--require-version", "0.66.0"]), 0)


if __name__ == "__main__":
    unittest.main()
