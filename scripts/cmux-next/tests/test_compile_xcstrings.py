#!/usr/bin/env python3
"""compile-xcstrings.py (p15-oracle-228): each target's .xcstrings become <lang>.lproj/<table>.strings
under .build-linux/lproj, linked into the folder the manifest gives the target as LinuxStringTables, with
no change on a second run. The real CmuxNextActions ActionCatalog table resolves a palette title to English."""

import importlib.util
import io
import json
import os
import plistlib
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SPEC = importlib.util.spec_from_file_location("compile_xcstrings", HERE.parent / "linux" / "compile-xcstrings.py")
assert SPEC and SPEC.loader
compile_xcstrings = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compile_xcstrings)


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def catalog(strings):
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


def target(name, kind="regular", path=None, tables=True):
    """One target of a `swift package dump-package` dump; tables: it takes the LinuxStringTables resource."""
    resources = [{"path": "LinuxStringTables", "rule": {"process": {}}}] if tables else []
    return {"name": name, "type": kind, "path": path, "resources": resources}


class Package:
    """A scratch package folder with <table>.xcstrings files and the manifest dump that names its targets."""

    def __init__(self, root):
        self.root = Path(root)
        self.targets = []

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(content), encoding="utf-8")

    def table(self, target, language, table):
        path = self.root / ".build-linux" / "lproj" / target / f"{language}.lproj" / f"{table}.strings"
        return plistlib.loads(path.read_bytes())

    def run(self, *args):
        manifest = self.root / "manifest.json"
        manifest.write_text(json.dumps({"name": "P", "targets": self.targets}), encoding="utf-8")
        out = io.StringIO()
        with mock.patch.object(sys, "platform", "linux"), redirect_stdout(out), redirect_stderr(out):
            code = compile_xcstrings.main(["--package", str(self.root), "--manifest", str(manifest), *args])
        return code, out.getvalue()


class CompileXcstringsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.pkg = Package(self.tmp.name)
        self.pkg.targets = [target("Alpha")]

    def tearDown(self):
        self.tmp.cleanup()

    def test_tables_per_language_and_the_target_link(self):
        self.pkg.write("Sources/Alpha/Titles.xcstrings", catalog({
            "a.title": {"localizations": {"en": unit("Title"), "de": unit("Titel")}},
            "a.only": {"localizations": {"en": unit("Only English")}},
        }))
        self.pkg.write("Sources/Alpha/Resources/Localizable.xcstrings", catalog({
            "b": {"localizations": {"en": unit("Bee")}},
        }))
        self.pkg.write("Tests/AlphaTests/Fixture.xcstrings", catalog({"t": {"localizations": {"en": unit("Tee")}}}))
        (self.pkg.root / "Sources" / "Plain").mkdir(parents=True)
        self.pkg.targets = [target("Alpha"), target("AlphaTests", "test"), target("Plain", tables=False)]
        code, output = self.pkg.run()
        self.assertEqual(code, 0, output)
        self.assertEqual(self.pkg.table("Alpha", "en", "Titles"), {"a.title": "Title", "a.only": "Only English"})
        self.assertEqual(self.pkg.table("Alpha", "de", "Titles"), {"a.title": "Titel"})
        self.assertEqual(self.pkg.table("Alpha", "en", "Localizable"), {"b": "Bee"})
        self.assertEqual(self.pkg.table("AlphaTests", "en", "Fixture"), {"t": "Tee"})
        link = self.pkg.root / "Sources" / "Alpha" / "LinuxStringTables"
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), os.path.join("..", "..", ".build-linux", "lproj", "Alpha"))
        self.assertTrue((link / "en.lproj" / "Titles.strings").is_file())
        self.assertTrue((self.pkg.root / "Tests" / "AlphaTests" / "LinuxStringTables").is_symlink())
        self.assertFalse((self.pkg.root / "Sources" / "Plain" / "LinuxStringTables").exists())
        self.assertEqual((self.pkg.root / ".build-linux" / ".gitignore").read_text(), "*\n")

    def test_second_run_changes_nothing_and_check_sees_staleness(self):
        self.pkg.write("Sources/Alpha/T.xcstrings", catalog({"k": {"localizations": {"en": unit("One")}}}))
        self.assertEqual(self.pkg.run()[0], 0)
        strings = self.pkg.root / ".build-linux" / "lproj" / "Alpha" / "en.lproj" / "T.strings"
        before = strings.stat().st_mtime_ns
        code, output = self.pkg.run()
        self.assertEqual(code, 0)
        self.assertIn("0 files updated", output)
        self.assertEqual(strings.stat().st_mtime_ns, before)
        self.assertEqual(self.pkg.run("--check")[0], 0)
        self.pkg.write("Sources/Alpha/T.xcstrings", catalog({"k": {"localizations": {"en": unit("Two")}}}))
        self.assertEqual(self.pkg.run("--check")[0], 1)
        self.assertEqual(self.pkg.table("Alpha", "en", "T"), {"k": "One"}, "--check wrote a file")
        self.assertEqual(self.pkg.run()[0], 0)
        self.assertEqual(self.pkg.table("Alpha", "en", "T"), {"k": "Two"})

    def test_stale_tables_and_links_go(self):
        self.pkg.write("Sources/Alpha/T.xcstrings", catalog({"k": {"localizations": {"en": unit("x"), "fr": unit("y")}}}))
        self.pkg.write("Sources/Beta/U.xcstrings", catalog({"k": {"localizations": {"en": unit("z")}}}))
        self.pkg.targets = [target("Alpha"), target("Beta")]
        self.assertEqual(self.pkg.run()[0], 0)
        self.pkg.write("Sources/Alpha/T.xcstrings", catalog({"k": {"localizations": {"en": unit("x")}}}))
        (self.pkg.root / "Sources" / "Beta" / "U.xcstrings").unlink()
        self.pkg.targets = [target("Alpha"), target("Beta", tables=False)]
        self.assertEqual(self.pkg.run()[0], 0)
        lproj = self.pkg.root / ".build-linux" / "lproj"
        self.assertFalse((lproj / "Alpha" / "fr.lproj").exists())
        self.assertFalse((lproj / "Beta").exists())
        self.assertFalse(os.path.lexists(self.pkg.root / "Sources" / "Beta" / "LinuxStringTables"))

    def test_variations_take_their_other_form(self):
        plural = {"variations": {"plural": {"one": unit("%lld tab"), "other": unit("%lld tabs")}}}
        device = {"variations": {"device": {"mac": unit("Click"), "other": unit("Tap")}}}
        self.pkg.write("Sources/Alpha/T.xcstrings", catalog({
            "tabs %lld": {"localizations": {"en": plural}},
            "press": {"localizations": {"en": device}},
        }))
        self.assertEqual(self.pkg.run()[0], 0)
        self.assertEqual(self.pkg.table("Alpha", "en", "T"), {"tabs %lld": "%lld tabs", "press": "Tap"})

    def test_untranslatable_keys_keep_only_the_source_language(self):
        self.pkg.write("Sources/Alpha/T.xcstrings", catalog({
            "brand": {"shouldTranslate": False, "localizations": {"en": unit("cmux"), "de": unit("cmux!")}},
        }))
        self.assertEqual(self.pkg.run()[0], 0)
        self.assertEqual(self.pkg.table("Alpha", "en", "T"), {"brand": "cmux"})
        self.assertFalse((self.pkg.root / ".build-linux" / "lproj" / "Alpha" / "de.lproj").exists())

    def test_substitutions_are_refused_with_file_and_key(self):
        self.pkg.write("Sources/Alpha/T.xcstrings", catalog({
            "n": {"localizations": {"en": {"stringUnit": unit("%#@a@")["stringUnit"], "substitutions": {}}}},
        }))
        code, output = self.pkg.run()
        self.assertEqual(code, 2)
        self.assertIn("T.xcstrings: n (en): substitutions are not supported", output)

    def test_a_target_at_a_nested_path_gets_its_own_tables_and_link(self):
        # Two targets under one folder, as `path: "Tests/Support/CmuxNextTestExitTrace"` declares.
        self.pkg.write("Tests/Support/Exit/E.xcstrings", catalog({"e": {"localizations": {"en": unit("Exit")}}}))
        self.pkg.write("Tests/Support/Other/O.xcstrings", catalog({"o": {"localizations": {"en": unit("Other")}}}))
        self.pkg.targets = [
            target("Exit", path="Tests/Support/Exit"),
            target("Other", path="Tests/Support/Other"),
        ]
        code, output = self.pkg.run()
        self.assertEqual(code, 0, output)
        support = self.pkg.root / "Tests" / "Support"
        self.assertFalse(os.path.lexists(support / "LinuxStringTables"))
        self.assertEqual(os.readlink(support / "Exit" / "LinuxStringTables"),
                         os.path.join("..", "..", "..", ".build-linux", "lproj", "Exit"))
        self.assertEqual(self.pkg.table("Exit", "en", "E"), {"e": "Exit"})
        self.assertEqual(self.pkg.table("Other", "en", "O"), {"o": "Other"})
        self.assertFalse((self.pkg.root / ".build-linux" / "lproj" / "Exit" / "en.lproj" / "O.strings").exists())

    def test_a_link_where_the_manifest_takes_none_goes(self):
        self.pkg.write("Tests/Support/T.xcstrings", catalog({"k": {"localizations": {"en": unit("x")}}}))
        self.pkg.targets = [target("Support", "test")]
        self.assertEqual(self.pkg.run()[0], 0)
        self.assertTrue(os.path.islink(self.pkg.root / "Tests" / "Support" / "LinuxStringTables"))
        self.pkg.write("Tests/Support/Exit/T.xcstrings", catalog({"k": {"localizations": {"en": unit("x")}}}))
        (self.pkg.root / "Tests" / "Support" / "T.xcstrings").unlink()
        self.pkg.targets = [target("Exit", path="Tests/Support/Exit")]
        self.assertEqual(self.pkg.run()[0], 0)
        self.assertFalse(os.path.lexists(self.pkg.root / "Tests" / "Support" / "LinuxStringTables"))
        self.assertTrue(os.path.islink(self.pkg.root / "Tests" / "Support" / "Exit" / "LinuxStringTables"))
        self.assertFalse((self.pkg.root / ".build-linux" / "lproj" / "Support").exists())

    def test_a_target_path_outside_the_package_or_missing_is_refused(self):
        self.pkg.targets = [target("Away", path="../Away")]
        code, output = self.pkg.run()
        self.assertEqual(code, 2)
        self.assertIn("target Away: its path ../Away is outside the package", output)
        self.pkg.targets = [target("Gone")]
        code, output = self.pkg.run()
        self.assertEqual(code, 2)
        self.assertIn("target Gone: no folder at Sources/Gone", output)

    def test_without_manifest_it_dumps_the_linux_mode_manifest(self):
        self.pkg.write("Sources/Alpha/T.xcstrings", catalog({"k": {"localizations": {"en": unit("x")}}}))
        dump = json.dumps({"targets": [target("Alpha")]})
        swift = self.pkg.root / "fake-swift"
        # Prints the dump only for `swift package ... dump-package` in the Linux mode.
        swift.write_text(
            "#!/bin/sh\n"
            '[ "$1" = package ] && [ "$CMUX_SWIFTPM_TARGET_LINUX" = 1 ] || exit 3\n'
            'for a; do [ "$a" = dump-package ] && { cat <<"EOF"\n' + dump + "\nEOF\nexit 0; }; done\nexit 4\n",
            encoding="utf-8",
        )
        swift.chmod(0o755)
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"SWIFT": str(swift)}), mock.patch.object(sys, "platform", "linux"), \
                redirect_stdout(out), redirect_stderr(out):
            code = compile_xcstrings.main(["--package", str(self.pkg.root)])
        self.assertEqual(code, 0, out.getvalue())
        self.assertEqual(self.pkg.table("Alpha", "en", "T"), {"k": "x"})

    def test_named_target_without_tables_is_an_error(self):
        (self.pkg.root / "Sources" / "Plain").mkdir(parents=True)
        self.pkg.targets = [target("Plain", tables=False)]
        code, output = self.pkg.run("--target", "Plain")
        self.assertEqual(code, 2)
        self.assertIn("the manifest gives target Plain no LinuxStringTables resource", output)

    def test_refuses_to_write_off_linux(self):
        self.pkg.write("Sources/Alpha/T.xcstrings", catalog({"k": {"localizations": {"en": unit("x")}}}))
        with mock.patch.object(sys, "platform", "darwin"), redirect_stderr(io.StringIO()):
            self.assertEqual(compile_xcstrings.main(["--package", str(self.pkg.root)]), 2)
        self.assertFalse((self.pkg.root / ".build-linux").exists())


class ActionCatalogTableTests(unittest.TestCase):
    """The ActionCatalog table of the real CmuxNextActions target."""

    def test_palette_family_title_resolves_to_english(self):
        path = REPO / "Packages" / "macOS" / "CmuxNext" / "Sources" / "CmuxNextActions" / "ActionCatalog.xcstrings"
        languages, _ = compile_xcstrings.compile_catalog(str(path))
        english = languages["en"]
        # ActionDescriptor+PaletteRank.swift: familyTitle("palette.family.workspace.move", "Workspace: Move…").
        self.assertEqual(english["palette.family.workspace.move"], "Workspace: Move…")
        source = json.loads(path.read_text(encoding="utf-8"))["strings"]
        self.assertEqual(set(english), set(source), "every key has an English entry")


if __name__ == "__main__":
    unittest.main()
