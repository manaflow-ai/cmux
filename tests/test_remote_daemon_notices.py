#!/usr/bin/env python3
"""cmuxd-remote ships beside its binaries a THIRD_PARTY file with the Go
standard library texts and the license texts of every Go module it links
(scripts/remote_daemon_notices.py). A module or text that nobody reviewed
fails the release build."""

from __future__ import annotations

import copy
import dataclasses
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import remote_daemon_notices as rdn  # noqa: E402


class RemoteDaemonNoticesTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.review = rdn.load_review()
        self.modules = []
        for module, entry in sorted(self.review["modules"].items()):
            path, version = module.split("@")
            directory = self.tmp / module.replace("/", "_")
            directory.mkdir()
            for name, digest in entry["files"].items():
                text = FIXTURE_TEXTS[digest]
                (directory / name).write_bytes(text)
            self.modules.append(rdn.Module(path, version, directory))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_the_notice_names_go_and_every_linked_module(self) -> None:
        text = rdn.compose(self.modules, "go1.26.8", self.review)
        self.assertIn("Go standard library and runtime (go1.26.8)", text)
        self.assertIn((rdn.TEXTS / "go/LICENSE").read_text(), text)
        for module in ("github.com/creack/pty v1.1.24", "golang.org/x/sys v0.44.0", "nhooyr.io/websocket v1.8.17"):
            self.assertIn(module, text)
        self.assertIn("Anmol Sethi", text)
        self.assertIn("Keith Rarick", text)

    def bumped(self, path: str, version: str) -> list:
        return [dataclasses.replace(m, version=version) if m.path == path else m for m in self.modules]

    def test_a_version_bump_with_the_reviewed_texts_is_approved(self) -> None:
        # 1c7138a0583 moved x/sys from v0.30.0 to v0.44.0 with byte-identical
        # LICENSE and PATENTS, and every nightly-next build failed until
        # review.json named the new version by hand.
        modules = self.bumped("golang.org/x/sys", "v0.99.0")
        text = rdn.compose(modules, "go1.26.8", self.review)
        self.assertIn("golang.org/x/sys v0.99.0", text)

    def test_a_version_bump_with_a_new_license_text_fails(self) -> None:
        modules = self.bumped("golang.org/x/sys", "v0.99.0")
        sys_module = next(m for m in modules if m.path == "golang.org/x/sys")
        (sys_module.directory / "LICENSE").write_text("relicensed\n")
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose(modules, "go1.26.8", self.review)
        self.assertIn("golang.org/x/sys@v0.99.0", str(raised.exception))

    def test_the_review_can_be_rewritten_for_the_linked_versions(self) -> None:
        modules = self.bumped("golang.org/x/sys", "v0.99.0")
        updated = rdn.updated_review(modules, self.review)
        self.assertIn("golang.org/x/sys@v0.99.0", updated["modules"])
        self.assertFalse([key for key in updated["modules"] if key.startswith("golang.org/x/sys@") and key != "golang.org/x/sys@v0.99.0"])
        self.assertEqual(updated["modules"]["golang.org/x/sys@v0.99.0"],
                         next(e for k, e in self.review["modules"].items() if k.startswith("golang.org/x/sys@")))
        rdn.compose(modules, "go1.26.8", updated)

    def go_root(self, **texts: bytes) -> Path:
        root = self.tmp / "goroot"
        root.mkdir(exist_ok=True)
        for name in self.review["go"]["files"]:
            (root / name).write_bytes(texts.get(name, (rdn.TEXTS / "go" / name).read_bytes()))
        return root

    def test_a_go_minor_bump_with_the_reviewed_texts_is_approved(self) -> None:
        text = rdn.compose(self.modules, "go1.27.3", self.review, go_root=self.go_root())
        self.assertIn("Go standard library and runtime (go1.27.3)", text)

    def test_a_go_minor_bump_with_a_new_license_text_fails(self) -> None:
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose(self.modules, "go1.27.3", self.review, go_root=self.go_root(LICENSE=b"other\n"))
        self.assertIn("go1.27.3", str(raised.exception))

    def test_an_unreviewed_module_fails(self) -> None:
        extra = self.tmp / "extra"
        extra.mkdir()
        (extra / "LICENSE").write_text("MIT\n")
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose([*self.modules, rdn.Module("example.com/new", "v1.0.0", extra)], "go1.26.8", self.review)
        self.assertIn("example.com/new@v1.0.0", str(raised.exception))

    def test_a_changed_module_text_fails(self) -> None:
        (self.modules[0].directory / next(iter(self.review["modules"][f"{self.modules[0].path}@{self.modules[0].version}"]["files"]))).write_text("edited\n")
        with self.assertRaises(rdn.NoticeError):
            rdn.compose(self.modules, "go1.26.8", self.review)

    def test_another_go_minor_version_fails(self) -> None:
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose(self.modules, "go1.27.0", self.review)
        self.assertIn("go1.27.0", str(raised.exception))

    def test_a_go_minor_bump_with_an_unrecognised_notice_fails(self) -> None:
        # An unrecognised notice may carry terms: a person reads it (Codex review of #24198).
        root = self.go_root()
        (root / "NOTICE").write_text("an added Go notice\n")
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose(self.modules, "go1.27.3", self.review, go_root=root)
        self.assertIn("NOTICE", str(raised.exception))

    def test_a_go_minor_bump_under_a_disallowed_license_fails(self) -> None:
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose(self.modules, "go1.27.3", self.review, go_root=self.go_root(LICENSE=GPL.encode()))
        self.assertIn("go1.27.3", str(raised.exception))
        self.assertIn("GPL-3.0", str(raised.exception))

    def test_a_failed_review_write_leaves_the_review_whole(self) -> None:
        review = self.tmp / "review.json"
        review.write_text("reviewed\n")
        saved = rdn.os.replace

        def fail(*_args):
            raise OSError("disk full")
        rdn.os.replace = fail
        try:
            with self.assertRaises(OSError):
                rdn.write_atomically(review, "rewritten\n")
        finally:
            rdn.os.replace = saved
        self.assertEqual(review.read_text(), "reviewed\n")
        self.assertEqual(sorted(p.name for p in self.tmp.iterdir() if p.name.startswith("review")), ["review.json"])
        rdn.write_atomically(review, "rewritten\n")
        self.assertEqual(review.read_text(), "rewritten\n")

    def module(self, path: str, **files: str) -> "rdn.Module":
        directory = self.tmp / path.replace("/", "_")
        directory.mkdir()
        for name, text in files.items():
            (directory / name).write_text(text)
        return rdn.Module(path, "v1.0.0", directory)

    def test_a_new_module_under_an_allowed_license_is_approved_and_recorded(self) -> None:
        # Leo: "why would you just fail "without a review" instead of fixing it". A module
        # whose license is on the allowlist needs no person: the check approves it, says so,
        # and --update-review writes its entry.
        new = self.module("example.com/mit", LICENSE=MIT)
        notes: list = []
        text = rdn.compose([*self.modules, new], "go1.26.8", self.review, notes=notes)
        self.assertIn("== example.com/mit v1.0.0 ==\nLicense: MIT.", text)
        self.assertTrue(any("example.com/mit@v1.0.0" in note and "MIT" in note for note in notes), notes)
        entry = rdn.updated_review([*self.modules, new], self.review)["modules"]["example.com/mit@v1.0.0"]
        self.assertEqual(entry, {"license": "MIT", "files": {"LICENSE": hashlib.sha256(MIT.encode()).hexdigest()}})

    def test_a_new_module_under_a_disallowed_license_fails_naming_it(self) -> None:
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose([*self.modules, self.module("example.com/gpl", LICENSE=GPL)], "go1.26.8", self.review)
        self.assertIn("example.com/gpl@v1.0.0", str(raised.exception))
        self.assertIn("GPL-3.0", str(raised.exception))

    def test_a_new_module_with_an_unknown_license_fails_naming_it(self) -> None:
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose([*self.modules, self.module("example.com/odd", LICENSE="All rights reserved.\n")], "go1.26.8", self.review)
        self.assertIn("example.com/odd@v1.0.0", str(raised.exception))
        self.assertIn("LICENSE", str(raised.exception))

    def test_a_bump_to_another_allowed_license_is_approved_and_recorded(self) -> None:
        modules = self.bumped("golang.org/x/sys", "v0.99.0")
        sys_module = next(m for m in modules if m.path == "golang.org/x/sys")
        (sys_module.directory / "LICENSE").write_text(MIT)
        (sys_module.directory / "PATENTS").unlink()
        text = rdn.compose(modules, "go1.26.8", self.review)
        self.assertIn("== golang.org/x/sys v0.99.0 ==\nLicense: MIT.", text)
        updated = rdn.updated_review(modules, self.review)["modules"]
        self.assertEqual(updated["golang.org/x/sys@v0.99.0"]["license"], "MIT")
        self.assertFalse([key for key in updated if key.startswith("golang.org/x/sys@") and key != "golang.org/x/sys@v0.99.0"])

    def test_a_module_the_build_no_longer_links_is_a_note_and_dropped(self) -> None:
        dropped = self.modules[0]
        notes: list = []
        rdn.compose(self.modules[1:], "go1.26.8", self.review, notes=notes)
        self.assertTrue(any(f"{dropped.path}@{dropped.version}" in note for note in notes), notes)
        self.assertNotIn(f"{dropped.path}@{dropped.version}", rdn.updated_review(self.modules[1:], self.review)["modules"])

    # Codex review of #24198 at 3699099a0f5: a license signature only shows an allowed license is
    # there, not that nothing else is. Approval now needs every license file to be wholly an allowed
    # license (its SPDX template), and anything unrecognised goes to a person.

    def test_a_license_file_named_after_its_license_is_read(self) -> None:
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose([*self.modules, self.module("example.com/split", **{"LICENSE-GPL": GPL, "LICENSE.docs": MIT})], "go1.26.8", self.review)
        self.assertIn("LICENSE-GPL", str(raised.exception))
        self.assertIn("GPL-3.0", str(raised.exception))
        text = rdn.compose([*self.modules, self.module("example.com/named", **{"LICENSE-MIT": MIT})], "go1.26.8", self.review)
        self.assertIn("== example.com/named v1.0.0 ==\nLicense: MIT.", text)

    def test_an_unrecognised_notice_beside_an_allowed_license_fails(self) -> None:
        notice = "This product includes software licensed under the GNU GPL version 2.\n"
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose([*self.modules, self.module("example.com/notice", LICENSE=MIT, NOTICE=notice)], "go1.26.8", self.review)
        self.assertIn("example.com/notice@v1.0.0", str(raised.exception))
        self.assertIn("NOTICE", str(raised.exception))

    def test_a_recorded_notice_beside_an_allowed_license_is_approved(self) -> None:
        text = rdn.compose([*self.modules, self.module("golang.org/x/other", LICENSE=BSD3, PATENTS=GO_PATENTS)], "go1.26.8", self.review)
        self.assertIn("== golang.org/x/other v1.0.0 ==\nLicense: BSD-3-Clause.", text)

    def test_an_allowed_license_with_an_added_restriction_fails(self) -> None:
        for name, text in {
            "appended": MIT + "\nThe Software may not be used for commercial purposes.\n",
            "in the preamble": "Non-commercial use only.\n" + MIT,
        }.items():
            with self.subTest(name), self.assertRaises(rdn.NoticeError) as raised:
                rdn.compose([*self.modules, self.module(f"example.com/{name.replace(' ', '-')}", LICENSE=text)], "go1.26.8", self.review)
            self.assertIn("LICENSE", str(raised.exception))

    def test_apache_2_0_is_approved_whole_and_refused_with_a_clause_in_seconds(self) -> None:
        # A regex of Apache-2.0's SPDX template backtracked for minutes on the added clause.
        for name, text, approved in (("as is", APACHE, True), ("with a clause", APACHE + "\nNo commercial use.\n", False)):
            with self.subTest(name):
                start = time.monotonic()
                self.assertEqual(rdn.allowed_license(text), "Apache-2.0" if approved else None)
                self.assertLess(time.monotonic() - start, 5)

    def test_a_template_variable_holds_only_its_part_never_added_terms(self) -> None:
        # Codex review of d869d36: an 18-character restriction fit Apache's bullet, a sentence
        # fit BSD's holder names, and a line under a copyright line passed as copyright.
        for name, text in {
            "a bullet": APACHE.replace("   1. Definitions.", "   No commercial use. Definitions.", 1),
            "the warranty holder": BSD3.replace("BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS", "BY THE COPYRIGHT HOLDERS, WHO FORBID RESALE,", 1),
            "the organization": BSD3.replace("Neither the name of Google LLC nor", "Neither the name of Google LLC, nor any fork sold for money, nor", 1),
            "a line under the copyright": MIT.replace("Copyright (c) 2011 Keith Rarick\n", "Copyright (c) 2011 Keith Rarick\nRedistribution forbidden.\n", 1),
            "a comment under the copyright": MIT.replace("Copyright (c) 2011 Keith Rarick\n", "Copyright (c) 2011 Keith Rarick\n# Redistribution forbidden.\n", 1),
            "a sentence after the holder": MIT.replace("Keith Rarick", "Keith Rarick. Redistribution forbidden", 1),
            "a restriction posing as a title": "Commercial use prohibited. License\n\n" + MIT,
            "terms after a dash": MIT.replace("Keith Rarick", "Example - Publication requires payment", 1),
        }.items():
            with self.subTest(name):
                self.assertIsNone(rdn.allowed_license(text))

    def test_titles_copyright_lines_and_whitespace_variants_still_match(self) -> None:
        for name, text, spdx in (
            ("a title", "The MIT License (MIT)\n\n" + MIT, "MIT"),
            ("two copyright lines", MIT.replace("Keith Rarick\n", "Keith Rarick\nCopyright (c) 2020 Example Inc. All rights reserved.\n", 1), "MIT"),
            ("a (c) line", MIT.replace("Copyright (c) 2011 Keith Rarick", "(c) 2026 Example", 1), "MIT"),
            ("a \u00a9 line", MIT.replace("Copyright (c) 2011 Keith Rarick", "\u00a9 2026 Example", 1), "MIT"),
            ("of the theme", BSD3.replace("source and binary forms,", "source and binary forms of the theme,", 1), "BSD-3-Clause"),
        ):
            with self.subTest(name):
                self.assertEqual(rdn.allowed_license(text), spdx)

    def test_a_recorded_text_approves_only_a_notice_of_an_allowed_entry(self) -> None:
        saved = rdn.ALLOWED
        rdn.ALLOWED = frozenset(saved) - {"MIT"}
        try:
            unlinked = [m for m in self.modules if m.path != "github.com/creack/pty"]
            with self.assertRaises(rdn.NoticeError) as raised:
                rdn.compose([*unlinked, self.module("example.com/dual", LICENSE=BSD3, **{"LICENSE-MIT": MIT})], "go1.26.8", self.review)
            self.assertIn("LICENSE-MIT", str(raised.exception))
        finally:
            rdn.ALLOWED = saved

    def test_a_recorded_license_off_the_allowlist_fails_unless_a_person_approved_it(self) -> None:
        saved = rdn.ALLOWED
        rdn.ALLOWED = frozenset(saved) - {"MIT"}
        try:
            with self.assertRaises(rdn.NoticeError) as raised:
                rdn.compose(self.modules, "go1.26.8", self.review)
            self.assertIn("github.com/creack/pty@v1.1.24", str(raised.exception))
            approved = copy.deepcopy(self.review)
            approved["modules"]["github.com/creack/pty@v1.1.24"]["approved"] = "a person, for the test"
            rdn.compose(self.modules, "go1.26.8", approved)
        finally:
            rdn.ALLOWED = saved

    def test_a_person_approval_stays_with_the_go_texts_it_approved(self) -> None:
        review = copy.deepcopy(self.review)
        review["go"]["approved"] = "a person, for the old texts"
        _, entry, _ = rdn.go_entry("go1.27.3", review, self.go_root(LICENSE=BSD3.replace("Google LLC", "Example Inc").encode()))
        self.assertNotIn("approved", entry)
        _, same, _ = rdn.go_entry("go1.27.3", review, self.go_root())
        self.assertEqual(same["approved"], "a person, for the old texts")

    def test_an_automatic_approval_shows_the_free_text_it_let_through(self) -> None:
        # Codex review of 6c03d61: a name-shaped phrase in a free part is accepted, so every
        # automatic approval shows the spans its template left free, wherever they sit.
        inline = "MIT License Copyright (c) 2026 Example Academic Projects Exclusively\n" + MIT.split("\n", 1)[1]
        for name, files, shown in (
            ("a copyright line", {"LICENSE": MIT}, "copyright (c) 2011 keith rarick"),
            ("a title and copyright on one line", {"LICENSE": inline}, "example academic projects exclusively"),
            ("BSD's organization", {"LICENSE": BSD3}, "google llc"),
        ):
            with self.subTest(name):
                notes: list = []
                module = self.module(f"example.com/{name.replace(' ', '-').replace(chr(39), '')}", **files)
                rdn.compose([*self.modules, module], "go1.26.8", self.review, notes=notes)
                self.assertIn(shown, "\n".join(notes))

    def test_a_go_patch_release_under_another_license_fails(self) -> None:
        with self.assertRaises(rdn.NoticeError) as raised:
            rdn.compose(self.modules, "go1.26.9", self.review, go_root=self.go_root(LICENSE=GPL.encode()))
        self.assertIn("GPL-3.0", str(raised.exception))

    def test_a_failed_review_write_keeps_the_go_texts_and_the_review_together(self) -> None:
        texts = self.tmp / "third-party"
        (texts / "go").mkdir(parents=True)
        (texts / "go" / "LICENSE").write_text("old license\n")
        review = texts / "review.json"
        review.write_text("old review\n")
        new_root = self.tmp / "goroot-new"
        new_root.mkdir()
        (new_root / "LICENSE").write_text("new license\n")
        saved = rdn.TEXTS, rdn.REVIEW, rdn.os.replace
        rdn.TEXTS, rdn.REVIEW = texts, review

        def fail(*_args):
            raise OSError("disk full")
        rdn.os.replace = fail
        try:
            with self.assertRaises(OSError):
                rdn.write_review_bundle("new review\n", {"LICENSE": "x"}, new_root)
        finally:
            rdn.TEXTS, rdn.REVIEW, rdn.os.replace = saved
        self.assertEqual(review.read_text(), "old review\n")
        self.assertEqual((texts / "go" / "LICENSE").read_text(), "old license\n")
        self.assertEqual(sorted(p.name for p in texts.iterdir()), ["go", "review.json"])

    def test_a_failed_swap_keeps_the_old_go_texts(self) -> None:
        texts = self.tmp / "third-party"
        (texts / "go").mkdir(parents=True)
        (texts / "go" / "LICENSE").write_text("old license\n")
        review = texts / "review.json"
        review.write_text("old review\n")
        new_root = self.tmp / "goroot-new"
        new_root.mkdir()
        (new_root / "LICENSE").write_text("new license\n")
        saved = rdn.TEXTS, rdn.REVIEW, rdn.os.rename
        rdn.TEXTS, rdn.REVIEW = texts, review
        rename = rdn.os.rename

        def fail_staged(source, target):
            if Path(source).name.startswith(".go.new-"):
                raise OSError("disk full")
            rename(source, target)
        rdn.os.rename = fail_staged
        try:
            with self.assertRaises(OSError):
                rdn.write_review_bundle("new review\n", {"LICENSE": "x"}, new_root)
        finally:
            rdn.TEXTS, rdn.REVIEW, rdn.os.rename = saved
        self.assertEqual(review.read_text(), "old review\n")
        self.assertEqual((texts / "go" / "LICENSE").read_text(), "old license\n")
        self.assertEqual(sorted(p.name for p in texts.iterdir()), ["go", "review.json"])

    def test_compose_is_deterministic(self) -> None:
        self.assertEqual(rdn.compose(self.modules, "go1.26.8", self.review),
                         rdn.compose(list(reversed(self.modules)), "go1.26.8", self.review))


FIXTURES = ROOT / "tests/fixtures/remote-daemon-notices"
MIT = (FIXTURES / "creack-pty-LICENSE").read_text()
BSD3 = (FIXTURES / "x-sys-LICENSE").read_text()
GO_PATENTS = (FIXTURES / "x-sys-PATENTS").read_text()
APACHE = (FIXTURES / "apache-2.0-LICENSE").read_text()  # apache.org/licenses/LICENSE-2.0.txt
GPL = "GNU GENERAL PUBLIC LICENSE\nVersion 3, 29 June 2007\n"

# The reviewed texts, keyed by sha256, from the module cache (go mod download).
FIXTURE_TEXTS: dict[str, bytes] = {}


def _load_fixture_texts() -> None:
    for path in (ROOT / "tests/fixtures/remote-daemon-notices").glob("*"):
        data = path.read_bytes()
        FIXTURE_TEXTS[hashlib.sha256(data).hexdigest()] = data


_load_fixture_texts()

if __name__ == "__main__":
    unittest.main()
