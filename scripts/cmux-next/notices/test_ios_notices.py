#!/usr/bin/env python3
"""The iOS app's Settings.bundle Acknowledgements pane and the Apple libintl rule (D1/D2)."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SPEC = importlib.util.spec_from_file_location("ios_notices", HERE / "ios_notices.py")
assert SPEC and SPEC.loader
ios = importlib.util.module_from_spec(SPEC)
sys.modules["ios_notices"] = ios
SPEC.loader.exec_module(ios)

PIN = "134477ce13b2c34d408e3e0dffafa4e8b78140635aa7d9d794ad2818e64883aa"
MACHO = b"\xcf\xfa\xed\xfe" + b"\0" * 60
JOB = "9bd58301641521918a3561ba"
ARTIFACT = "cbbad2368077ac5bf9d67957baf0aec8f9c4f24fe93e109a2ec1682ed5249f27"
MUSL_TEXT = (ROOT / "cmux-tui/dist/notices/texts/musl-1.2.5/COPYRIGHT").read_text()


class RepositoryTests(unittest.TestCase):
    def test_pane_link_set_and_exceptions_match_the_ghosttykit_pin(self) -> None:
        self.assertEqual(ios.check_repo(), [])

    def test_the_pane_omits_only_what_the_real_link_proves_absent(self) -> None:
        record = json.loads(ios.LINK_SET.read_text())["app_link"]
        self.assertEqual(record["evidence"]["cmux_ci_job"], JOB)
        self.assertEqual(record["evidence"]["artifact_sha256"], ARTIFACT)
        self.assertIn("zig-package:gettext", record["absent_owners"])
        self.assertIn("vendored:pkg/libintl", record["absent_owners"])
        self.assertEqual(sorted(record["absent_zig_packages"]), ["iterm2_themes", "zig_js"])
        pane = plistlib.loads(ios.PANE.read_bytes())["PreferenceSpecifiers"]
        titles = {group["Title"] for group in pane}
        for gone in ("gettext (in Ghostty)", "zig_js (in Ghostty)", "iterm2_themes (in Ghostty)"):
            self.assertNotIn(gone, titles)
        # Zig code keeps no symbol names: no evidence either way, so these stay listed.
        for kept in ("vaxis (in Ghostty)", "zf (in Ghostty)", "zigimg (in Ghostty)", "freetype (in Ghostty)", "z2d (in Ghostty)"):
            self.assertIn(kept, titles)
        self.assertIn(JOB, pane[-1]["FooterText"])
        self.assertIn(ARTIFACT, pane[-1]["FooterText"])

    def test_the_pane_credits_the_freetype_project(self) -> None:
        pane = plistlib.loads(ios.PANE.read_bytes())["PreferenceSpecifiers"]
        freetype = next(group for group in pane if group["Title"] == "freetype (in Ghostty)")
        self.assertIn(FTL_CREDIT, freetype["FooterText"])

    def test_the_pane_carries_musl_for_the_zig_std_math(self) -> None:
        # GhosttyNextKit's Termio inlines std.math.cbrt (ported from musl) into LAB.fromRgb:
        # found in the device app of cmux-ci job a9f238cb599baeb9b17f8ff4 (machine-code match).
        pane = plistlib.loads(ios.PANE.read_bytes())["PreferenceSpecifiers"]
        musl = next(group for group in pane if group["Title"] == ios.MUSL_TITLE)
        self.assertIn(MUSL_TEXT.strip(), musl["FooterText"])
        self.assertIn("std.math.cbrt", musl["FooterText"])

    def test_the_mac_notices_carry_musl_for_the_app_binary(self) -> None:
        # The published nightly-next app (3728109721001) has the same code in Contents/MacOS/cmux.
        self.assertEqual(ios.mac_notice_errors(), [])
        notices = (ROOT / "THIRD_PARTY_LICENSES.md").read_text()
        self.assertIn("<!-- notices-section: manual-musl-in-the-zig-standard-library -->", notices)
        self.assertIn(MUSL_TEXT.strip(), notices)
        entries = json.loads((HERE / "bundle-map.json").read_text())["entries"]
        app = next(entry for entry in entries if entry["path"] == "Contents/MacOS/cmux")
        self.assertIn("section:manual-musl-in-the-zig-standard-library", app["notices"])

    def test_the_mac_notices_credit_the_freetype_project(self) -> None:
        # FTL section 3: the macos slice links FreeType (ghosttykit-macos-link-set.json), so the
        # app's documentation cites the FreeType Project, as the iOS pane does.
        notices = (ROOT / "THIRD_PARTY_LICENSES.md").read_text()
        self.assertIn("<!-- notices-section: manual-freetype -->", notices)
        self.assertIn(FTL_CREDIT, notices)
        entries = json.loads((HERE / "bundle-map.json").read_text())["entries"]
        app = next(entry for entry in entries if entry["path"] == "Contents/MacOS/cmux")
        self.assertIn("section:manual-freetype", app["notices"])

    def test_mac_notices_refuse_a_missing_freetype_credit(self) -> None:
        hand = ios.HAND_WRITTEN.read_text().replace(FTL_CREDIT, "FreeType credit removed", 1)
        self.assertTrue(any("FreeType" in error for error in ios.mac_notice_errors(hand)))

    def test_mac_notices_refuse_a_changed_musl_text(self) -> None:
        hand = ios.HAND_WRITTEN.read_text().replace("Rich Felker", "R. Felker", 1)
        self.assertTrue(any("musl" in error for error in ios.mac_notice_errors(hand)))

    def test_settings_bundle_root_links_the_pane(self) -> None:
        root = plistlib.loads((ios.SETTINGS / "Root.plist").read_bytes())
        panes = [item for item in root["PreferenceSpecifiers"] if item.get("Type") == "PSChildPaneSpecifier"]
        self.assertEqual([pane["File"] for pane in panes], ["Acknowledgements"])


class LibintlRuleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.exceptions = self.tmp / "exceptions.json"
        self.exceptions.write_text(json.dumps({"pins": {PIN: "D1 pending"}}))
        self.with_intl = self.tmp / "with.a"
        self.with_intl.write_bytes(b"x" * 10 + b"libintl_dcigettext" + b"y")
        self.without = self.tmp / "without.a"
        self.without.write_bytes(b"clean")

    def test_libintl_fails_for_any_pin_without_an_exception(self) -> None:
        self.assertTrue(ios.libintl_errors("0" * 64, [self.with_intl], self.exceptions))

    def test_the_excepted_pin_passes_while_it_still_has_libintl(self) -> None:
        self.assertEqual(ios.libintl_errors(PIN, [self.with_intl, self.without], self.exceptions), [])

    def test_an_exception_whose_xcframework_lost_libintl_must_be_removed(self) -> None:
        self.assertTrue(ios.libintl_errors(PIN, [self.without], self.exceptions, ratchet=True))

    def test_a_clean_app_under_an_excepted_pin_passes(self) -> None:
        # The linker drops unused libintl from the app even when the xcframework has it.
        self.assertEqual(ios.libintl_errors(PIN, [self.without], self.exceptions), [])

    def test_an_entry_for_a_pin_not_in_use_is_not_checked(self) -> None:
        # A second entry (a pin that may land next) never fails while another pin is current.
        self.exceptions.write_text(json.dumps({"pins": {PIN: "D1 pending", "2" * 64: "temporary until D1"}}))
        self.assertEqual(ios.libintl_errors("3" * 64, [self.without], self.exceptions, ratchet=True), [])
        self.assertEqual(ios.libintl_errors("2" * 64, [self.with_intl], self.exceptions, ratchet=True), [])

    def test_a_stripped_binary_is_still_found(self) -> None:
        # `strip` removes libintl's symbol names from a linked binary; its string literal stays.
        stripped = self.tmp / "stripped"
        stripped.write_bytes(MACHO + b"\0GETTEXT_LOG_UNTRANSLATED\0")
        self.assertTrue(ios.libintl_errors("0" * 64, [stripped], self.exceptions))

    def test_the_repository_lists_the_current_and_the_next_pre_d1_pins(self) -> None:
        pins = json.loads(ios.EXCEPTIONS.read_text())["pins"]
        self.assertIn(PIN, pins)
        self.assertIn("736e8f05256b6453ef2dd05c58eff3088cfc1eda7ae748c041e877c8a66741ba", pins)

    def test_clean_binaries_pass_for_a_new_pin(self) -> None:
        self.assertEqual(ios.libintl_errors("1" * 64, [self.without], self.exceptions), [])


class BuiltAppTests(unittest.TestCase):
    def setUp(self) -> None:
        record = json.loads(ios.LINK_SET.read_text())["app_link"]
        self.symbols = set(record["witness_symbols"])
        original = ios.defined_symbols
        ios.defined_symbols = lambda path: set(self.symbols)  # the fake binaries have no symbol table
        self.addCleanup(setattr, ios, "defined_symbols", original)

    def app(self) -> Path:
        app = Path(tempfile.mkdtemp()) / "cmux.app"
        shutil.copytree(ios.SETTINGS, app / "Settings.bundle")
        (app / "cmux").write_bytes(MACHO)  # the linker drops libintl: nothing references it
        return app

    def test_refuses_an_app_that_links_a_package_the_pane_omits(self) -> None:
        self.symbols.add("_libintl_dcigettext")
        errors = ios.check_app(self.app())
        self.assertTrue(any("zig-package:gettext is omitted" in error for error in errors), errors)

    def test_refuses_libintl_strings_when_the_pane_omits_gettext(self) -> None:
        app = self.app()
        (app / "cmux").write_bytes(MACHO + b"\0GETTEXT_LOG_UNTRANSLATED\0")
        self.assertTrue(any("gettext (libintl) is omitted" in error for error in ios.check_app(app)))

    def test_refuses_an_app_without_symbols(self) -> None:
        # Absence of a symbol proves nothing in a stripped binary: fail closed.
        self.symbols.clear()
        self.assertTrue(any("witness" in error for error in ios.check_app(self.app())))

    def test_refuses_a_themes_file_when_the_pane_omits_iterm2_themes(self) -> None:
        app = self.app()
        (app / "share/ghostty/themes").mkdir(parents=True)
        (app / "share/ghostty/themes/Dracula").write_text("palette = 0=#000000\n")
        self.assertTrue(any("iterm2_themes" in error for error in ios.check_app(app)))

    def test_accepts_the_committed_pane(self) -> None:
        self.assertEqual(ios.check_app(self.app()), [])

    def test_accepts_a_binary_plist_copy(self) -> None:
        app = self.app()
        pane = app / "Settings.bundle/Acknowledgements.plist"
        pane.write_bytes(plistlib.dumps(plistlib.loads(pane.read_bytes()), fmt=plistlib.FMT_BINARY))
        self.assertEqual(ios.check_app(app), [])

    def test_refuses_a_missing_pane(self) -> None:
        app = self.app()
        (app / "Settings.bundle/Acknowledgements.plist").unlink()
        self.assertTrue(ios.check_app(app))

    def test_refuses_an_old_pane(self) -> None:
        app = self.app()
        pane = app / "Settings.bundle/Acknowledgements.plist"
        data = plistlib.loads(pane.read_bytes())
        data["PreferenceSpecifiers"].pop(1)
        pane.write_bytes(plistlib.dumps(data))
        self.assertTrue(any("old pane" in error for error in ios.check_app(app)))


    def test_refuses_missing_japanese_strings(self) -> None:
        app = self.app()
        shutil.rmtree(app / "Settings.bundle/ja.lproj")
        self.assertTrue(any("ja.lproj" in error for error in ios.check_app(app)))


FTL_CREDIT = "Portions of this software are copyright \u00a9 2023 The FreeType Project (www.freetype.org).  All rights reserved."


class PaneTests(unittest.TestCase):
    def setUp(self) -> None:
        # The fake tree's FreeType LICENSE.TXT counts as reviewed FreeType 2.13.2 (2023).
        years = getattr(ios, "FREETYPE_YEARS", {})
        saved = dict(years)
        years[hashlib.sha256(b"FreeType text\n").hexdigest()] = ("2.13.2", 2023)
        ios.FREETYPE_YEARS = years
        self.addCleanup(lambda: (years.clear(), years.update(saved)))

    def test_pane_credits_the_freetype_project(self) -> None:
        # FTL section 3: binary redistributions cite the FreeType Project in their documentation.
        pin = {"url": "u", "sha256": PIN, "ghostty_revision": "a" * 40}
        links = {"dwarf_owners": ["zig-package:freetype"], "zig_source_packages": [], "zig_version": "0.16.0"}
        pane = ios.build_pane(self.tree("a" * 40), links, pin)
        freetype = next(group for group in pane["PreferenceSpecifiers"] if group["Title"] == "freetype (in Ghostty)")
        self.assertIn(FTL_CREDIT, freetype["FooterText"])
        self.assertIn("based in part on the work of the FreeType Team", freetype["FooterText"])

    def test_refuses_an_unreviewed_freetype_version(self) -> None:
        # A new FreeType LICENSE.TXT needs its version's year reviewed before the credit is written.
        ios.FREETYPE_YEARS.clear()
        pin = {"url": "u", "sha256": PIN, "ghostty_revision": "a" * 40}
        links = {"dwarf_owners": ["zig-package:freetype"], "zig_source_packages": [], "zig_version": "0.16.0"}
        with self.assertRaises(ios.NoticeError):
            ios.build_pane(self.tree("a" * 40), links, pin)

    def tree(self, revision: str) -> Path:
        tree = Path(tempfile.mkdtemp())
        files = {"zig-pkg/HZ/LICENSE": b"z2d MPL text\n", "zig-pkg/HF/LICENSE.TXT": b"FreeType text\n", "src/font/res/OFL.txt": b"OFL text\n"}
        entries = []
        for index, (source, data) in enumerate(files.items()):
            destination = f"ghostty-source/{index}"
            (tree / "ghostty-source").mkdir(exist_ok=True)
            (tree / destination).write_bytes(data)
            entries.append({"source": source, "package": "ghostty-next", "destination": destination, "sha256": hashlib.sha256(data).hexdigest()})
        manifest = {
            "ghostty_revision": revision,
            "unresolved_packages": 0,
            "zig_packages": {"HZ": {"dependency": "z2d", "url": "https://example.test/z2d.tar.gz"}, "HF": {"dependency": "freetype", "url": "u"}},
            "license_files": entries,
        }
        (tree / "SOURCE-MANIFEST.json").write_text(json.dumps(manifest))
        return tree

    def test_pane_has_the_linked_texts_and_the_z2d_source_offer(self) -> None:
        pin = {"url": "u", "sha256": PIN, "ghostty_revision": "a" * 40}
        links = {"dwarf_owners": ["zig-package:freetype", "zig-lib:std"], "zig_source_packages": ["z2d"], "zig_version": "0.16.0"}
        pane = ios.build_pane(self.tree("a" * 40), links, pin)
        titles = [group["Title"] for group in pane["PreferenceSpecifiers"]]
        self.assertIn("freetype (in Ghostty)", titles)
        self.assertIn("Ghostty (license, embedded fonts)", titles)
        z2d = next(group for group in pane["PreferenceSpecifiers"] if group["Title"] == "z2d (in Ghostty)")
        self.assertIn("z2d MPL text", z2d["FooterText"])
        self.assertIn("https://example.test/z2d.tar.gz", z2d["FooterText"])
        self.assertIn("Source Code Form", z2d["FooterText"])

    def test_pane_omits_owners_and_zig_packages_proven_absent(self) -> None:
        pin = {"url": "u", "sha256": PIN, "ghostty_revision": "a" * 40}
        links = {
            "dwarf_owners": ["zig-package:freetype", "zig-package:gettext", "zig-lib:std"],
            "zig_source_packages": ["z2d", "zig_js"],
            "zig_version": "0.16.0",
            "app_link": {
                "absent_owners": {"zig-package:gettext": {"members": ["dcigettext.o"], "symbols": ["_libintl_dcigettext"]}},
                "absent_zig_packages": {"zig_js": "wasm32 only"},
                "evidence": {"cmux_ci_job": "job1", "artifact_sha256": "f" * 64},
            },
        }
        # The tree has no gettext or zig_js text: the pane must not need them.
        pane = ios.build_pane(self.tree("a" * 40), links, pin)
        titles = [group["Title"] for group in pane["PreferenceSpecifiers"]]
        self.assertIn("freetype (in Ghostty)", titles)
        self.assertIn("z2d (in Ghostty)", titles)
        self.assertNotIn("gettext (in Ghostty)", titles)
        self.assertNotIn("zig_js (in Ghostty)", titles)
        record = pane["PreferenceSpecifiers"][-1]["FooterText"]
        self.assertIn("cmux-ci job job1", record)
        self.assertIn("gettext, zig_js", record)

    def test_pane_has_the_musl_text_after_zig(self) -> None:
        pin = {"url": "u", "sha256": PIN, "ghostty_revision": "a" * 40}
        links = {"dwarf_owners": ["zig-lib:std"], "zig_source_packages": [], "zig_version": "0.16.0"}
        titles = [group["Title"] for group in ios.build_pane(self.tree("a" * 40), links, pin)["PreferenceSpecifiers"]]
        self.assertEqual(titles[titles.index("Zig 0.16.0 (compiler_rt and standard library)") + 1], ios.MUSL_TITLE)

    def test_refuses_a_tree_for_another_ghostty_revision(self) -> None:
        pin = {"url": "u", "sha256": PIN, "ghostty_revision": "a" * 40}
        with self.assertRaises(ios.NoticeError):
            ios.build_pane(self.tree("b" * 40), {"dwarf_owners": [], "zig_source_packages": [], "zig_version": "0.16.0"}, pin)

    def test_refuses_a_linked_package_without_a_collected_license(self) -> None:
        pin = {"url": "u", "sha256": PIN, "ghostty_revision": "a" * 40}
        links = {"dwarf_owners": ["zig-package:harfbuzz"], "zig_source_packages": [], "zig_version": "0.16.0"}
        with self.assertRaises(ios.NoticeError):
            ios.build_pane(self.tree("a" * 40), links, pin)


class MacLinkSetTests(unittest.TestCase):
    """The macOS app links GhosttyNextKit's macos slice and ships the ghostty-next license tree."""

    def setUp(self) -> None:
        PaneTests.setUp(self)  # the fake tree's FreeType LICENSE.TXT is reviewed FreeType 2.13.2 (2023)

    def test_the_macos_link_set_names_the_current_pin(self) -> None:
        links = json.loads(ios.MACOS_LINK_SET.read_text())
        self.assertEqual(links["pin"], ios.ghostty_kit_pin())
        self.assertEqual(links["slice"], "macos-arm64_x86_64")
        self.assertIn("zig-package:freetype", links["dwarf_owners"])

    def test_a_new_pin_without_a_macos_link_set_fails_check_repo(self) -> None:
        links = json.loads(ios.MACOS_LINK_SET.read_text())
        links["pin"] = dict(links["pin"], sha256="0" * 64)
        self.assertTrue(any("macos" in error.lower() for error in ios.macos_link_errors(links)))

    def tree(self) -> Path:
        return PaneTests.tree(self, "a" * 40)

    def test_covered_owners_pass(self) -> None:
        pin = {"url": "u", "sha256": PIN, "ghostty_revision": "a" * 40}
        links = {"pin": pin, "dwarf_owners": ["zig-package:freetype", "zig-lib:std"], "zig_source_packages": ["z2d"]}
        self.assertEqual(ios.check_macos(self.tree(), links, pin), [])

    def test_a_linked_package_without_a_collected_license_fails(self) -> None:
        pin = {"url": "u", "sha256": PIN, "ghostty_revision": "a" * 40}
        links = {"pin": pin, "dwarf_owners": ["zig-package:harfbuzz"], "zig_source_packages": []}
        self.assertTrue(ios.check_macos(self.tree(), links, pin))

    def test_the_credit_must_name_the_linked_freetype_version(self) -> None:
        pin = {"url": "u", "sha256": PIN, "ghostty_revision": "a" * 40}
        links = {"pin": pin, "dwarf_owners": ["zig-package:freetype"], "zig_source_packages": []}
        self.assertEqual(ios.check_macos(self.tree(), links, pin), [])
        ios.FREETYPE_YEARS[hashlib.sha256(b"FreeType text\n").hexdigest()] = ("2.14.1", 2025)
        errors = ios.check_macos(self.tree(), links, pin)
        self.assertTrue(any("2.14.1" in error and "hand-written" in error for error in errors), errors)

    def test_an_unreviewed_freetype_fails(self) -> None:
        ios.FREETYPE_YEARS.clear()
        pin = {"url": "u", "sha256": PIN, "ghostty_revision": "a" * 40}
        links = {"pin": pin, "dwarf_owners": ["zig-package:freetype"], "zig_source_packages": []}
        self.assertTrue(any("FREETYPE_YEARS" in error for error in ios.check_macos(self.tree(), links, pin)))

    def test_a_tree_for_another_revision_fails(self) -> None:
        pin = {"url": "u", "sha256": PIN, "ghostty_revision": "b" * 40}
        links = {"pin": pin, "dwarf_owners": ["zig-package:freetype"], "zig_source_packages": []}
        self.assertTrue(ios.check_macos(self.tree(), links, pin))


class LinkSetCheckTests(unittest.TestCase):
    """CI regenerates the link sets from the pinned xcframework and compares them (no Mac needed)."""

    def committed(self) -> dict:
        return json.loads(ios.LINK_SET.read_text())

    def generated(self) -> dict:
        # What link-set computes: the DWARF facts, without the hand-kept fields.
        return {key: value for key, value in self.committed().items() if key not in ("app_link", "zig_source_packages", "pin")}

    def test_the_same_facts_pass_and_keep_the_hand_kept_fields(self) -> None:
        committed = self.committed()
        merged = ios.merge_link_set(self.generated(), committed, ios.ghostty_kit_pin())
        self.assertEqual(merged, committed)
        self.assertEqual(ios.link_set_differences(merged, committed), [])

    def test_a_changed_owner_list_fails(self) -> None:
        committed = self.committed()
        generated = self.generated()
        generated["dwarf_owners"] = generated["dwarf_owners"] + ["zig-package:harfbuzz"]
        merged = ios.merge_link_set(generated, committed, ios.ghostty_kit_pin())
        self.assertEqual(ios.link_set_differences(merged, committed), ["dwarf_owners"])

    def test_a_new_pin_drops_the_old_app_link(self) -> None:
        committed = self.committed()
        pin = dict(ios.ghostty_kit_pin(), sha256="0" * 64)
        merged = ios.merge_link_set(self.generated(), committed, pin)
        self.assertNotIn("app_link", merged)
        self.assertEqual(sorted(ios.link_set_differences(merged, committed)), ["app_link", "pin"])


def ar_archive(members: list[tuple[str, bytes]]) -> bytes:
    out = b"!<arch>\n"
    for name, body in members:
        if len(name) > 15:  # BSD long name: "#1/<length>", the name (NUL-padded) starts the body
            length = (len(name) + 8) // 8 * 8
            body = name.encode().ljust(length, b"\0") + body
            name = f"#1/{length}"
        out += f"{name:<16}{0:<12}{0:<6}{0:<6}{644:<8}{len(body):<10}`\n".encode() + body + (b"\n" if len(body) % 2 else b"")
    return out


class RealLinkTests(unittest.TestCase):
    def test_archive_members_keep_order_and_repeated_names(self) -> None:
        path = Path(tempfile.mkdtemp()) / "lib.a"
        path.write_bytes(ar_archive([("__.SYMDEF", b"x"), ("ext.o", b"one"), ("a-very-long-member-name.o", b"two"), ("ext.o", b"three")]))
        self.assertEqual(list(ios.archive_members(path)), [("ext.o", b"one"), ("a-very-long-member-name.o", b"two"), ("ext.o", b"three")])

    def test_an_owner_is_absent_only_when_none_of_its_symbols_is_in_the_app(self) -> None:
        members = [
            {"name": "dcigettext.o", "owners": ["zig-package:gettext"], "symbols": {"_libintl_dcigettext"}},
            {"name": "png.o", "owners": ["zig-package:libpng", "zig-package:zlib"], "symbols": {"_png_create_read_struct"}},
            {"name": "inflate.o", "owners": ["zig-package:zlib"], "symbols": {"_inflate"}},
        ]
        absent, present = ios.decide_owners(members, {"_png_create_read_struct"})
        self.assertEqual(sorted(absent), ["zig-package:gettext"])
        self.assertEqual(absent["zig-package:gettext"]["symbols"], ["_libintl_dcigettext"])
        # zlib's own member is gone, but libpng's member (which inlines zlib.h) is in the app.
        self.assertEqual(present, {"zig-package:libpng": 1, "zig-package:zlib": 1})

    def test_an_owner_with_a_member_that_defines_nothing_stays_listed(self) -> None:
        members = [{"name": "data.o", "owners": ["zig-package:gettext"], "symbols": set()}]
        absent, present = ios.decide_owners(members, {"_other"})
        self.assertEqual(absent, {})
        self.assertIn("zig-package:gettext", present)

    def source(self, files: dict[str, str]) -> Path:
        root = Path(tempfile.mkdtemp())
        for name, text in files.items():
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text(text)
        return root

    WASM = """    if (step.rootModuleTarget().cpu.arch == .wasm32) {
        if (b.lazyDependency("zig_js", .{})) |js_dep| {
            _ = js_dep;
        }
        return static_libs;
    }
"""

    def test_a_wasm_only_import_is_absent(self) -> None:
        source = self.source({"src/build/SharedDeps.zig": self.WASM})
        self.assertTrue(ios.zig_absent_reason(source, "zig_js", "src/build/SharedDeps.zig", "cpu.arch == .wasm32", False, []))

    def test_an_import_outside_the_wasm_block_is_kept(self) -> None:
        text = """    if (step.rootModuleTarget().cpu.arch == .wasm32) {
        return static_libs;
    }
    if (b.lazyDependency("zig_js", .{})) |js_dep| {
        _ = js_dep;
    }
"""
        source = self.source({"src/build/SharedDeps.zig": text})
        self.assertIsNone(ios.zig_absent_reason(source, "zig_js", "src/build/SharedDeps.zig", "cpu.arch == .wasm32", False, []))

    def test_a_use_in_another_file_keeps_the_package(self) -> None:
        source = self.source({"src/build/SharedDeps.zig": self.WASM, "src/build/Other.zig": '_ = b.lazyDependency("zig_js", .{});\n'})
        self.assertIsNone(ios.zig_absent_reason(source, "zig_js", "src/build/SharedDeps.zig", "cpu.arch == .wasm32", False, []))

    def test_a_resource_package_is_absent_only_without_its_files_in_the_app(self) -> None:
        source = self.source({"src/build/GhosttyResources.zig": '        if (b.lazyDependency("iterm2_themes", .{})) |upstream| {}\n'})
        rule = (source, "iterm2_themes", "src/build/GhosttyResources.zig", None, True)
        self.assertTrue(ios.zig_absent_reason(*rule, ["cmux", "Info.plist"]))
        self.assertIsNone(ios.zig_absent_reason(*rule, ["share/ghostty/themes/Dracula"]))


if __name__ == "__main__":
    unittest.main()
