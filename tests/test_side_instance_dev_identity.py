#!/usr/bin/env python3
"""side-instance.sh make turns every copy into a DEV build: id, tag, name and icon (#48637).

`cmux app try .`, try-pr.sh and hot-verify.py all copy an installed app with side-instance.sh. A copy of
NIGHTLY (or cmux NEXT, `com.cmuxterm.app.nightly.cmux-next`) kept the nightly's id prefix
(`com.cmuxterm.app.nightly[.cmux-next].side-NAME-...`), its `AppIcon-Nightly` icon and its `cmux-next` tag, so
the app read itself as NIGHTLY (BuildIdentity.kind), shared NIGHTLY's cloud data space (CMUXBuildSpaceState: no
dev tag) and showed up as a nightly in the Dock. Each copy is now `com.cmuxterm.app.debug.side-NAME-<hash>`
with that tag, named "cmux DEV ...", with DEV's icon.
PlistBuddy, codesign, xattr, defaults and iconutil are stand-ins, so this runs anywhere with bash and python3.
"""

import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/side-instance.sh"
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_side_instance_remake_clears_old_identity import BUDDY  # noqa: E402

# iconutil -c icns -o OUT ICONSET: records the iconset's files in OUT.
ICONUTIL = "#!/bin/sh\nls \"$5\" > \"$4\"\n"


class SideInstanceDevIdentityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="side-instance-dev-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for tool, body in {"PlistBuddy": BUDDY, "codesign": "#!/bin/sh\nexit 0\n", "xattr": "#!/bin/sh\nexit 0\n",
                           "defaults": "#!/bin/sh\nexit 0\n", "iconutil": ICONUTIL}.items():
            (bin_dir / tool).write_text(body)
            (bin_dir / tool).chmod(0o755)
        self.env = {**os.environ, "HOME": str(self.tmp / "home"), "CMUX_SIDE_ROOT": str(self.tmp / "side"),
                    "SIDE_INSTANCE_PLISTBUDDY": str(bin_dir / "PlistBuddy"),
                    "SIDE_INSTANCE_ICONUTIL": str(bin_dir / "iconutil"),
                    "PATH": f"{bin_dir}:{os.environ['PATH']}"}

    def app(self, name: str, bundle_id: str, tag: str) -> Path:
        app = self.tmp / f"{name}.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Resources").mkdir()
        (app / "Contents/Resources/AppIcon-Nightly.icns").write_bytes(b"nightly")
        with open(app / "Contents/Info.plist", "wb") as f:
            plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "cmux", "CFBundleVersion": "1",
                           "CFBundleName": name, "CFBundleIconFile": "AppIcon-Nightly",
                           "CFBundleIconName": "AppIcon-Nightly", "LSEnvironment": {"CMUX_TAG": tag}}, f)
        return app

    def make(self, app: Path, name: str = "try-x", *extra: str) -> tuple[dict, dict, subprocess.CompletedProcess]:
        run = subprocess.run(["bash", str(SCRIPT), "make", name, "--from", str(app), *extra], env=self.env,
                             check=True, capture_output=True, text=True)
        marker = Path(self.env["CMUX_SIDE_ROOT"]) / name / ".side-instance"
        ident = dict(line.split("=", 1) for line in marker.read_text().splitlines())
        with open(Path(ident["app"]) / "Contents/Info.plist", "rb") as f:
            return ident, plistlib.load(f), run

    def test_a_copy_of_cmux_next_nightly_is_a_dev_build(self):
        ident, info, _ = self.make(self.app("cmux NEXT", "com.cmuxterm.app.nightly.cmux-next", "cmux-next"))
        bundle = info["CFBundleIdentifier"]
        self.assertRegex(bundle, r"^com\.cmuxterm\.app\.debug\.side-try-x-[0-9a-f]{6}$")
        self.assertNotIn("nightly", bundle)
        tag = info["LSEnvironment"]["CMUX_TAG"]
        # The tag is the id's suffix: BuildIdentity's dev tag, the cloud data space dev:<tag>, and the build key
        # is the bare id (no --cmux-next).
        self.assertEqual(f"com.cmuxterm.app.debug.{tag}", bundle)
        self.assertEqual(ident["key"], bundle)
        self.assertEqual(info["CFBundleName"], "cmux DEV try-x")
        self.assertEqual(info["CFBundleDisplayName"], "cmux DEV try-x")
        self.assertEqual(Path(ident["app"]).name, "cmux DEV try-x.app")
        # DEV's icon, made from the checkout's AppIcon-Debug set; the asset-catalog name that would pick
        # NIGHTLY's icon out of Assets.car is gone.
        self.assertEqual(info["CFBundleIconFile"], "AppIcon-Debug")
        self.assertNotIn("CFBundleIconName", info)
        icns = Path(ident["app"]) / "Contents/Resources/AppIcon-Debug.icns"
        self.assertEqual(icns.read_text().split(), sorted(
            f"icon_{s}x{s}{x}.png" for s in (16, 32, 128, 256, 512) for x in ("", "@2x")))
        self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLName"], bundle)

    def test_a_copy_of_classic_nightly_and_of_a_dev_build_are_dev_builds_of_their_own(self):
        nightly, _, _ = self.make(self.app("cmux NIGHTLY", "com.cmuxterm.app.nightly", ""), "pr-1")
        dev, _, _ = self.make(self.app("cmux DEV next", "com.cmuxterm.app.debug.next", "next"), "pr-2")
        for ident in (nightly, dev):
            self.assertTrue(ident["bundle"].startswith("com.cmuxterm.app.debug.side-"), ident)
        self.assertNotEqual(nightly["bundle"], dev["bundle"])

    def test_the_label_always_says_dev(self):
        app = self.app("cmux NEXT", "com.cmuxterm.app.nightly.cmux-next", "cmux-next")
        for label, shown in (("cmux PR #35", "cmux DEV PR #35"), ("cmux hot-verify", "cmux DEV hot-verify"),
                             ("cmux DEV probe", "cmux DEV probe"), ("look", "cmux DEV look")):
            with self.subTest(label=label):
                ident, info, _ = self.make(app, "pr-35", "--label", label)
                self.assertEqual(info["CFBundleName"], shown)
                self.assertEqual(Path(ident["app"]).name, f"{shown}.app")
                subprocess.run(["bash", str(SCRIPT), "remove", "pr-35"], env=self.env, check=True,
                               capture_output=True, text=True)

    def test_two_roots_and_two_originals_never_share_an_identity(self):
        app = self.app("cmux NEXT", "com.cmuxterm.app.nightly.cmux-next", "cmux-next")
        first, _, _ = self.make(app)
        self.assertEqual(self.make(app)[0]["bundle"], first["bundle"])  # a remake keeps its identity
        self.env["CMUX_SIDE_ROOT"] = str(self.tmp / "other-side")
        other = self.make(app)[0]["bundle"]
        self.assertNotEqual(other, first["bundle"])
        self.assertTrue(re.fullmatch(r"com\.cmuxterm\.app\.debug\.side-try-x-[0-9a-f]{6}", other))

    def test_without_the_icon_set_the_copy_keeps_its_icon_and_says_so(self):
        self.env["SIDE_INSTANCE_DEV_ICONSET"] = str(self.tmp / "missing")
        ident, info, run = self.make(self.app("cmux NEXT", "com.cmuxterm.app.nightly.cmux-next", "cmux-next"))
        self.assertEqual(info["CFBundleIconFile"], "AppIcon-Nightly")
        self.assertIn("keeps its original's icon", run.stderr)
        self.assertTrue(ident["bundle"].startswith("com.cmuxterm.app.debug.side-"))


if __name__ == "__main__":
    unittest.main()
