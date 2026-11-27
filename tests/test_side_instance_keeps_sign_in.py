#!/usr/bin/env python3
"""side-instance.sh remove --keep-sign-in keeps a copy's own session for its next make of the same identity.

`cmux app try .` remakes its copy on every run (hot-verify.py removes it first), and remove cleared the copy's
credentials.json with the rest of its state, so every try started signed out. --keep-sign-in keeps only the copy's
own credentials.json files and puts them back only into the same bundle id; never another build's session.
"""

import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("remake", HERE / "test_side_instance_remake_clears_old_identity.py")
remake = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(remake)


class SideInstanceKeepsSignInTests(remake.SideInstanceRemakeTests):
    def run_side(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", str(remake.SCRIPT), *args], env=self.env, check=True, capture_output=True,
                              text=True)

    def sign_in(self, ident: dict) -> list[Path]:
        support = self.home / "Library/Application Support"
        files = [support / "cmux-next" / ident["bundle"] / "prod-project" / "credentials.json",
                 support / "cmux" / ident["bundle"] / "credentials.json"]
        for f in files:
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text('{"accessToken":"a","refreshToken":"r-%s"}' % f.parent.name)
            f.chmod(0o600)
        # Other state of the copy that a remake still clears.
        (support / "cmux-next" / ident["bundle"] / "prod-project" / "settings.json").write_text("{}")
        return files

    def test_remake_after_keep_sign_in_restores_the_copys_own_session(self):
        nightly = self.app("nightly", "com.cmuxterm.app.nightly", "cmux-next")
        ident = self.make(nightly)
        files = self.sign_in(ident)
        before = [f.read_text() for f in files]
        self.run_side("remove", "pr-1", "--keep-sign-in")
        self.assertEqual([f for f in files if f.exists()], [])
        self.assertEqual(self.make(nightly), ident)
        self.assertEqual([f.read_text() for f in files], before)
        self.assertEqual([oct(f.stat().st_mode & 0o777) for f in files], ["0o600", "0o600"])
        self.assertFalse((files[0].parent / "settings.json").exists())
        self.assertFalse((self.tmp / "side/.kept-sign-in/pr-1").exists())

    def test_a_different_identity_gets_nothing(self):
        ident = self.make(self.app("nightly", "com.cmuxterm.app.nightly", "cmux-next"))
        files = self.sign_in(ident)
        self.run_side("remove", "pr-1", "--keep-sign-in")
        other = self.make(self.app("dev", "com.cmuxterm.app.debug.next", "next"))
        self.assertNotEqual(other["bundle"], ident["bundle"])
        self.assertEqual([f for f in files if f.exists()], [])
        support = self.home / "Library/Application Support"
        self.assertEqual(list(support.rglob("credentials.json")), [])
        self.assertFalse((self.tmp / "side/.kept-sign-in/pr-1").exists())

    def test_plain_remove_drops_a_kept_session(self):
        nightly = self.app("nightly", "com.cmuxterm.app.nightly", "cmux-next")
        ident = self.make(nightly)
        files = self.sign_in(ident)
        self.run_side("remove", "pr-1", "--keep-sign-in")
        self.make(nightly)
        self.run_side("remove", "pr-1")
        self.assertEqual([f for f in files if f.exists()], [])
        self.assertFalse((self.tmp / "side/.kept-sign-in/pr-1").exists())
        self.make(nightly)
        self.assertEqual([f for f in files if f.exists()], [])

    def test_list_does_not_show_the_kept_folder(self):
        nightly = self.app("nightly", "com.cmuxterm.app.nightly", "cmux-next")
        self.sign_in(self.make(nightly))
        self.run_side("remove", "pr-1", "--keep-sign-in")
        self.assertNotIn("kept", self.run_side("list").stdout)


# The inherited tests run once, in their own file.
for _name in [n for n in dir(remake.SideInstanceRemakeTests) if n.startswith("test_")]:
    setattr(SideInstanceKeepsSignInTests, _name, None)

if __name__ == "__main__":
    unittest.main()
