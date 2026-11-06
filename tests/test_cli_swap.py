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

    def test_a_wrong_sha256_changes_nothing(self):
        os.environ["PATH"] = f"{self.bundled.parent}:/usr/bin:/bin"
        code, out = self.apply("--sha", "0" * 64)
        self.assertEqual(code, 1)
        self.assertIn("nothing changed", out)
        self.assertFalse((self.home / ".local/bin").exists())
        self.assertEqual(self.bundled.read_text(), "app's own build\n")


if __name__ == "__main__":
    unittest.main()
