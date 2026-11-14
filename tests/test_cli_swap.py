#!/usr/bin/env python3
"""cli-swap.py puts a published cmux CLI where a cmux terminal finds it. A `cmux` inside an app bundle
(the app's own, which also runs its daemon) is never written: the copy goes beside it as cmux-NAME.
A link outside any app is repointed. `undo` takes both back. Downloads are file:// URLs here."""
import hashlib
import importlib.util
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cli_swap", ROOT / "scripts/cmux-next/cli-swap.py")
cli_swap = importlib.util.module_from_spec(spec)
sys.modules["cli_swap"] = cli_swap
spec.loader.exec_module(cli_swap)

KEY = "63c1ff05aa18b2349901d0eca2c5b03b2ed9d9ec"
TRIPLE = "aarch64-apple-darwin"


class CliSwapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.home = self.tmp / "home"
        self.home.mkdir()
        published = self.tmp / "published" / KEY
        published.mkdir(parents=True)
        self.build = b"#!/bin/sh\necho merged build\n"
        (published / f"cmux-tui-{TRIPLE}").write_bytes(self.build)
        (published / f"cmux-tui-{TRIPLE}.sha256").write_text(hashlib.sha256(self.build).hexdigest() + "  cmux\n")
        self.app = self.tmp / "cmux NIGHTLY.app"
        self.bundled = self.app / "Contents/Resources/bin/cmux"
        self.bundled.parent.mkdir(parents=True)
        self.bundled.write_text("app's own build\n")
        self.bundled.chmod(0o755)
        self.env = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(self.env)))
        os.environ.update(HOME=str(self.home), CMUX_CLI_SWAP_STATE_DIR=str(self.tmp / "state"))
        self.addCleanup(setattr, cli_swap, "BASE", cli_swap.BASE)
        cli_swap.BASE = (self.tmp / "published").as_uri()

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = cli_swap.main(list(argv))
        return code, out.getvalue() + err.getvalue()

    def apply(self, *extra):
        return self.run_cli("apply", "--tree-key", KEY, "--target", TRIPLE, *extra)

    def test_a_terminal_whose_cmux_is_the_apps_gets_the_build_beside_it(self):
        # A cmux terminal's PATH starts with the app's bin, so `cmux` is the bundle's file.
        os.environ["PATH"] = f"{self.bundled.parent}:{self.home / '.local/bin'}:/usr/bin:/bin"
        code, out = self.apply("--name", "37024")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.bundled.read_text(), "app's own build\n")
        alias = self.home / ".local/bin/cmux-37024"
        self.assertEqual(alias.read_bytes(), self.build)
        self.assertIn("run `cmux-37024`", out)
        self.assertIn("inside an app bundle", out)
        self.assertEqual(self.run_cli("undo")[0], 0)
        self.assertFalse(alias.exists() or alias.is_symlink())
        self.assertEqual(self.bundled.read_text(), "app's own build\n")

    def test_app_names_the_bundle_a_terminal_runs_from_any_shell(self):
        os.environ["PATH"] = "/usr/bin:/bin"
        code, out = self.apply("--app", str(self.app))
        self.assertEqual(code, 0, out)
        self.assertIn("inside an app bundle", out)
        self.assertEqual((self.home / ".local/bin" / f"cmux-{KEY[:12]}").read_bytes(), self.build)
        self.assertIn("not on PATH here", out)

    def test_a_link_outside_any_app_is_repointed_and_put_back(self):
        links = self.tmp / "usr-local-bin"
        links.mkdir()
        link = links / "cmux"
        link.symlink_to(self.bundled)
        os.environ["PATH"] = f"{links}:/usr/bin:/bin"
        # The link resolves into the app: still the app's file, so it is left alone.
        self.assertEqual(self.apply()[0], 0)
        self.assertEqual(os.readlink(link), str(self.bundled))
        self.run_cli("undo")
        other = self.tmp / "installed" / "cmux"
        other.parent.mkdir()
        other.write_text("install script's build\n")
        other.chmod(0o755)
        link.unlink()
        link.symlink_to(other)
        code, out = self.apply()
        self.assertEqual(code, 0, out)
        self.assertEqual(link.read_bytes(), self.build)
        self.run_cli("undo")
        self.assertEqual(os.readlink(link), str(other))

    def test_a_name_someone_else_has_is_never_replaced_or_removed(self):
        os.environ["PATH"] = f"{self.bundled.parent}:/usr/bin:/bin"
        theirs = self.home / ".local/bin/cmux-37024"
        theirs.parent.mkdir(parents=True)
        theirs.write_text("a person's own script\n")
        code, out = self.apply("--name", "37024")
        self.assertEqual(code, 1)
        self.assertIn("not from cli-swap", out)
        self.run_cli("undo")
        self.assertEqual(theirs.read_text(), "a person's own script\n")
        # Its own name, applied twice, is replaced and then removed.
        self.assertEqual(self.apply("--name", "mine")[0], 0)
        self.assertEqual(self.apply("--name", "mine")[0], 0)
        self.run_cli("undo")
        self.assertFalse((self.home / ".local/bin/cmux-mine").is_symlink())

    def test_a_link_applied_twice_goes_back_to_what_it_was_first(self):
        links = self.tmp / "usr-local-bin"
        links.mkdir()
        other = self.tmp / "installed" / "cmux"
        other.parent.mkdir()
        other.write_text("install script's build\n")
        other.chmod(0o755)
        link = links / "cmux"
        link.symlink_to(other)
        os.environ["PATH"] = f"{links}:/usr/bin:/bin"
        self.assertEqual(self.apply()[0], 0)
        self.assertEqual(self.apply()[0], 0)
        self.run_cli("undo")
        self.assertEqual(os.readlink(link), str(other))

    def test_undo_leaves_a_link_something_else_changed_since(self):
        links = self.tmp / "usr-local-bin"
        links.mkdir()
        other = self.tmp / "installed" / "cmux"
        other.parent.mkdir()
        other.write_text("install script's build\n")
        other.chmod(0o755)
        link = links / "cmux"
        link.symlink_to(other)
        os.environ["PATH"] = f"{links}:/usr/bin:/bin"
        self.assertEqual(self.apply()[0], 0)
        upgraded = self.tmp / "installed" / "cmux-upgraded"
        upgraded.write_text("a package manager's upgrade\n")
        link.unlink()
        link.symlink_to(upgraded)
        code, out = self.run_cli("undo")
        self.assertEqual(code, 1)
        self.assertIn("changed since the swap", out)
        self.assertEqual(os.readlink(link), str(upgraded))

    def test_a_second_apply_never_takes_what_was_replaced_since_the_first(self):
        os.environ["PATH"] = f"{self.bundled.parent}:/usr/bin:/bin"
        self.assertEqual(self.apply("--name", "mine")[0], 0)
        alias = self.home / ".local/bin/cmux-mine"
        alias.unlink()
        alias.write_text("a person's own script\n")
        code, out = self.apply("--name", "mine")
        self.assertEqual(code, 1, out)
        self.assertIn("not from cli-swap", out)
        self.run_cli("undo")
        self.assertEqual(alias.read_text(), "a person's own script\n")

    def test_a_link_replaced_since_the_first_apply_goes_back_to_the_replacement(self):
        links = self.tmp / "usr-local-bin"
        links.mkdir()
        installed = self.tmp / "installed"
        installed.mkdir()
        (installed / "cmux").write_text("install script's build\n")
        (installed / "cmux-upgraded").write_text("a package manager's upgrade\n")
        for name in ("cmux", "cmux-upgraded"):
            (installed / name).chmod(0o755)
        link = links / "cmux"
        link.symlink_to(installed / "cmux")
        os.environ["PATH"] = f"{links}:/usr/bin:/bin"
        self.assertEqual(self.apply()[0], 0)
        link.unlink()
        link.symlink_to(installed / "cmux-upgraded")
        self.assertEqual(self.apply()[0], 0)
        self.assertEqual(link.read_bytes(), self.build)
        self.assertEqual(self.run_cli("undo")[0], 0)
        self.assertEqual(os.readlink(link), str(installed / "cmux-upgraded"))

    def test_a_file_beside_the_link_is_never_touched(self):
        os.environ["PATH"] = f"{self.bundled.parent}:/usr/bin:/bin"
        bin_dir = self.home / ".local/bin"
        bin_dir.mkdir(parents=True)
        theirs = bin_dir / ".cmux-mine.cli-swap"
        theirs.write_text("a person's own file\n")
        self.assertEqual(self.apply("--name", "mine")[0], 0)
        self.assertEqual(self.run_cli("undo")[0], 0)
        self.assertEqual(theirs.read_text(), "a person's own file\n")
        self.assertEqual(sorted(p.name for p in bin_dir.iterdir()), [".cmux-mine.cli-swap"])

    def test_a_build_not_published_changes_nothing(self):
        os.environ["PATH"] = f"{self.bundled.parent}:/usr/bin:/bin"
        code, out = self.run_cli("apply", "--tree-key", "0" * 40, "--target", TRIPLE)
        self.assertEqual(code, 1, out)
        self.assertIn("could not read", out)
        self.assertNotIn("Traceback", out)
        self.assertFalse((self.home / ".local/bin").exists())

    def test_a_link_found_through_a_relative_path_entry_is_undone_from_anywhere(self):
        links = self.tmp / "usr-local-bin"
        links.mkdir()
        other = self.tmp / "installed" / "cmux"
        other.parent.mkdir()
        other.write_text("install script's build\n")
        other.chmod(0o755)
        link = links / "cmux"
        link.symlink_to(other)
        cwd = os.getcwd()
        self.addCleanup(os.chdir, cwd)
        os.chdir(self.tmp)
        os.environ["PATH"] = "usr-local-bin:/usr/bin:/bin"
        self.assertEqual(self.apply()[0], 0)
        os.chdir(self.home)
        self.assertEqual(self.run_cli("undo")[0], 0)
        self.assertEqual(os.readlink(link), str(other))

    def test_it_loads_on_python_3_9(self):
        # The system python3 of macOS: no `X | None` at runtime.
        source = (ROOT / "scripts/cmux-next/cli-swap.py").read_text()
        self.assertIn("from __future__ import annotations", source)

    def test_a_key_or_name_that_leads_out_of_its_directory_changes_nothing(self):
        os.environ["PATH"] = f"{self.bundled.parent}:/usr/bin:/bin"
        for argv in (["apply", "--tree-key", "../../x", "--target", TRIPLE],
                     ["apply", "--tree-key", "/tmp/x", "--target", TRIPLE],
                     ["apply", "--tree-key", KEY, "--target", TRIPLE, "--name", "../../bin/cmux"],
                     ["apply", "--tree-key", KEY, "--target", TRIPLE, "--name", ".."]):
            code, out = self.run_cli(*argv)
            self.assertEqual(code, 2, out)
            self.assertIn("nothing changed", out)
        self.assertFalse((self.tmp / "state").exists())
        self.assertFalse((self.home / ".local/bin").exists())

    def test_a_link_inside_the_bundle_is_never_repointed(self):
        # The bundle's own bin/cmux as a link to a file outside: still the signed bundle's, never written.
        outside = self.tmp / "outside-cmux"
        outside.write_text("outside build\n")
        outside.chmod(0o755)
        self.bundled.unlink()
        self.bundled.symlink_to(outside)
        os.environ["PATH"] = "/usr/bin:/bin"
        code, out = self.apply("--app", str(self.app))
        self.assertEqual(code, 0, out)
        self.assertEqual(os.readlink(self.bundled), str(outside))
        self.assertIn("inside an app bundle", out)

    def test_a_wrong_sha256_changes_nothing(self):
        os.environ["PATH"] = f"{self.bundled.parent}:/usr/bin:/bin"
        code, out = self.apply("--sha", "0" * 64)
        self.assertEqual(code, 1)
        self.assertIn("nothing changed", out)
        self.assertFalse((self.home / ".local/bin").exists())
        self.assertEqual(self.bundled.read_text(), "app's own build\n")


if __name__ == "__main__":
    unittest.main()
