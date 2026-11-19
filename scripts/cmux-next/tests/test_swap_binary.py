#!/usr/bin/env python3
"""swap-binary.sh: what a swap carries, how it puts a build into a copy, and side-instance.sh make --swap.

plutil, PlistBuddy, codesign, xattr and defaults are stand-ins, so this runs anywhere with bash, git and python3:
    python3 scripts/cmux-next/tests/test_swap_binary.py
"""

import os
import plistlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOL = ROOT / "scripts/cmux-next/swap-binary.sh"
SIDE = ROOT / "scripts/cmux-next/side-instance.sh"

PLUTIL = textwrap.dedent('''\
    #!/usr/bin/env python3
    import plistlib, sys
    # plutil -extract KEY raw -o - FILE
    key, path = sys.argv[2], sys.argv[-1]
    v = plistlib.load(open(path, "rb"))
    for k in key.split("."):
        if not isinstance(v, dict) or k not in v: sys.exit(1)
        v = v[k]
    print(v)
''')
# Print, Set, Add and Delete on :a:b:0 paths (tests/test_side_instance_remake_clears_old_identity.py's stand-in).
BUDDY = (ROOT / "tests/test_side_instance_remake_clears_old_identity.py").read_text().split("BUDDY = textwrap.dedent('''\\\n")[1].split("''')")[0]


class SwapBinaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="swap-binary-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        self.codesign_log = self.tmp / "codesign.log"
        tools = {"plutil": PLUTIL, "PlistBuddy": textwrap.dedent(BUDDY),
                 "codesign": f"#!/bin/sh\necho \"$*\" >>'{self.codesign_log}'\nexit 0\n",
                 "xattr": "#!/bin/sh\nexit 0\n", "defaults": "#!/bin/sh\nexit 0\n"}
        for tool, body in tools.items():
            (bin_dir / tool).write_text(body)
            (bin_dir / tool).chmod(0o755)
        self.env = {**os.environ, "HOME": str(self.tmp / "home"), "CMUX_SIDE_ROOT": str(self.tmp / "side"),
                    "SWAP_BINARY_PLUTIL": str(bin_dir / "plutil"), "SIDE_INSTANCE_PLISTBUDDY": str(bin_dir / "PlistBuddy"),
                    "PATH": f"{bin_dir}:{os.environ['PATH']}"}

    def run_tool(self, *args, stdin=None, check=True):
        r = subprocess.run(["bash", str(TOOL), *map(str, args)], env=self.env, input=stdin, text=True, capture_output=True)
        if check:
            self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def nightly(self) -> Path:
        app = self.tmp / "cmux NIGHTLY.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/cmux").write_text("nightly exe")
        res = app / "Contents/Resources"
        (res / "CmuxNext_CmuxNextApp.bundle").mkdir(parents=True)
        (res / "CmuxNext_CmuxNextApp.bundle/old.txt").write_text("old")
        (res / "CmuxNext_Kept.bundle").mkdir()
        (res / "cmux-symbols.bin").write_text("old symbols")
        (app / "Contents/Frameworks/Sentry.framework").mkdir(parents=True)
        (app / "Contents/Frameworks/Sentry.framework/Sentry").write_text("nightly sentry")
        (res / "CmuxNext_CmuxNextApp.bundle/agent-pane").mkdir()
        (res / "CmuxNext_CmuxNextApp.bundle/agent-pane/index.html").write_text("built web")
        (res / "web").mkdir()
        (res / "web/index.html").write_text("web")
        with open(app / "Contents/Info.plist", "wb") as f:
            plistlib.dump({"CFBundleIdentifier": "com.cmuxterm.app.nightly", "CFBundleExecutable": "cmux",
                           "CFBundleVersion": "4424316677601", "CMUXCommit": "a" * 40}, f)
        return app

    def overlay(self) -> Path:
        out = self.tmp / "build"
        c = out / "app/Contents"
        (c / "MacOS").mkdir(parents=True)
        (c / "MacOS/cmux").write_text("head exe")
        (c / "Resources/CmuxNext_CmuxNextApp.bundle").mkdir(parents=True)
        (c / "Resources/CmuxNext_CmuxNextApp.bundle/new.txt").write_text("new")
        (c / "Resources/CmuxNext_Added.bundle").mkdir()
        (c / "Resources/cmux-symbols.bin").write_text("new symbols")
        (c / "Frameworks/Iroh.framework").mkdir(parents=True)
        (c / "Frameworks/Iroh.framework/Iroh").write_text("iroh")
        (c / "Frameworks/Sentry.framework").mkdir()
        (c / "Frameworks/Sentry.framework/Sentry").write_text("built sentry")
        return out

    def test_check_paths_names_what_a_swap_cannot_carry(self):
        paths = ["Packages/macOS/CmuxNext/Sources/CmuxNextApp/CmuxNextApp.swift",
                 "Packages/macOS/CmuxNext/app-ffi-pin.json", "Packages/Shared/CmuxTheme/Sources/CmuxTheme/AppTheme.swift",
                 "App/main.swift", "docs/cmux-next/live-code.md", "scripts/measure/launch-ready.sh", "tests/test_x.py",
                 "Packages/iOS/CmuxMobileRPC/Sources/X.swift", "cmux-next-ios/App.swift", "README.md",
                 # not carried
                 "Resources/Info.plist", "cmux.next-dev.entitlements", "cmux.xcodeproj/project.pbxproj",
                 "cmux-tui/src/main.rs", "webviews/src/app.tsx", "ghostty-next", "scripts/cmux-next/bundle-acpmux.sh",
                 "scripts/cmux-next/embed-cef.sh", "scripts/strip-release-bundle.sh", "Native/OptChat/x.rs",
                 "Packages/macOS/CmuxNext/Sources/CmuxNextServerHelper/Server.swift",
                 "Packages/macOS/CmuxNext/Sources/CmuxNextCompat/Mutex.swift", "Packages/macOS/CmuxNext/CEFShim/shim.cc",
                 "Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h",
                 "Packages/macOS/CmuxComputerUseHelper/Sources/main.swift", "Packages/macOS/CmuxRemote/Package.swift"]
        r = self.run_tool("check-paths", stdin="\n".join(paths) + "\n")
        self.assertEqual(r.stdout.split(), paths[10:])

    def test_wrapper_links_with_the_app_targets_release_flags(self):
        if not (ROOT / "cmux.xcodeproj/project.pbxproj").exists() or not (ROOT / "App/main.swift").exists():
            self.skipTest("a sparse checkout without the project")
        r = self.run_tool("wrapper", ROOT, self.tmp / "wrapper")
        manifest = (self.tmp / "wrapper/Package.swift").read_text()
        # -no_exported_symbols comes only from Release's LD_EXPORT_SYMBOLS = NO: the Release block, not Debug's.
        for flag in ('"-objc_stubs_small"', '"@executable_path/../Frameworks"', '"-no_exported_symbols"', '"Carbon"'):
            self.assertIn(flag, manifest)
        self.assertIn('.macOS("14.0")', manifest)
        self.assertIn("link flags", r.stderr)

    def test_check_refuses_a_diff_that_touches_the_project(self):
        repo = self.tmp / "repo"
        repo.mkdir()
        git = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True, text=True).stdout.strip()
        git("init", "-q")
        git("config", "user.email", "t@example.com"); git("config", "user.name", "t")
        (repo / "App").mkdir(); (repo / "App/main.swift").write_text("1")
        git("add", "-A"); git("commit", "-qm", "base")
        base = git("rev-parse", "HEAD")
        (repo / "App/main.swift").write_text("2")
        git("commit", "-qam", "swift"); swift = git("rev-parse", "HEAD")
        (repo / "cmux.xcodeproj").mkdir(); (repo / "cmux.xcodeproj/project.pbxproj").write_text("x")
        git("add", "-A"); git("commit", "-qm", "project"); project = git("rev-parse", "HEAD")
        # A file moved from what a swap cannot carry into a package: both paths count (no rename detection).
        (repo / "Resources").mkdir(); (repo / "Resources/Info.plist").write_text("plist " * 40)
        git("add", "-A"); git("commit", "-qm", "plist"); plist = git("rev-parse", "HEAD")
        (repo / "Packages").mkdir(); git("mv", "Resources/Info.plist", "Packages/Info.plist")
        git("commit", "-qm", "move"); moved = git("rev-parse", "HEAD")
        r = self.run_tool("check", plist, moved, "--repo", repo, check=False)
        self.assertEqual(r.returncode, 3)
        self.assertIn("not carried: Resources/Info.plist", r.stderr)
        self.run_tool("check", base, swift, "--repo", repo)
        r = self.run_tool("check", base, project, "--repo", repo, check=False)
        self.assertEqual(r.returncode, 3)
        self.assertIn("not carried: cmux.xcodeproj/project.pbxproj", r.stderr)

    def test_place_replaces_the_executable_and_merges_bundles(self):
        app = self.nightly()
        copy = self.tmp / "copy/cmux NIGHTLY.app"
        shutil.copytree(app, copy)
        r = self.run_tool("place", copy, self.overlay())
        self.assertEqual((copy / "Contents/MacOS/cmux").read_text(), "head exe")
        bundle = copy / "Contents/Resources/CmuxNext_CmuxNextApp.bundle"
        # Merged: the build's files over the nightly's, so the web output only the nightly's bundle has stays.
        self.assertEqual(sorted(p.name for p in bundle.iterdir()), ["agent-pane", "new.txt", "old.txt"])
        self.assertEqual((bundle / "agent-pane/index.html").read_text(), "built web")
        # A framework the nightly lacks is added; one it ships stays the nightly's.
        self.assertEqual((copy / "Contents/Frameworks/Iroh.framework/Iroh").read_text(), "iroh")
        self.assertEqual((copy / "Contents/Frameworks/Sentry.framework/Sentry").read_text(), "nightly sentry")
        self.assertTrue((copy / "Contents/Resources/CmuxNext_Kept.bundle").is_dir())
        self.assertTrue((copy / "Contents/Resources/CmuxNext_Added.bundle").is_dir())
        self.assertEqual((copy / "Contents/Resources/web/index.html").read_text(), "web")
        self.assertIn("replaced=MacOS/cmux,Resources/CmuxNext_CmuxNextApp.bundle,Resources/cmux-symbols.bin", r.stdout)
        self.assertIn("added=Resources/CmuxNext_Added.bundle,Frameworks/Iroh.framework", r.stdout)
        self.assertEqual((app / "Contents/MacOS/cmux").read_text(), "nightly exe")  # the original untouched
        diff = self.run_tool("diff", app, copy).stdout.splitlines()
        self.assertIn("changed Contents/MacOS/cmux", diff)
        self.assertIn("added Contents/Resources/CmuxNext_CmuxNextApp.bundle/new.txt", diff)
        self.assertIn("added Contents/Frameworks/Iroh.framework/Iroh", diff)
        self.assertNotIn("removed Contents/Resources/CmuxNext_CmuxNextApp.bundle/agent-pane/index.html", diff)
        self.assertFalse(any("web/" in line or "Info.plist" in line for line in diff))

    def test_place_refuses_an_installed_app_and_a_missing_overlay(self):
        r = self.run_tool("place", self.nightly(), self.tmp / "nothing", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no overlay", r.stderr)

    def test_side_instance_make_swap_places_before_the_seal(self):
        app = self.nightly()
        r = subprocess.run(["bash", str(SIDE), "make", "sb-head", "--from", str(app), "--swap", str(self.overlay())],
                           env=self.env, text=True, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        copy = Path(subprocess.run(["bash", str(SIDE), "path", "sb-head"], env=self.env, text=True,
                                   capture_output=True, check=True).stdout.strip())
        self.assertEqual((copy / "Contents/MacOS/cmux").read_text(), "head exe")
        with open(copy / "Contents/Info.plist", "rb") as f:
            self.assertTrue(plistlib.load(f)["CFBundleIdentifier"].startswith("com.cmuxterm.app.nightly.side-sb-head-"))
        signs = self.codesign_log.read_text().splitlines()
        self.assertTrue(any(line.startswith("--force --sign -") and line.endswith(str(copy)) for line in signs), signs)
        self.assertTrue(any(line.startswith("--verify --strict") for line in signs), signs)


if __name__ == "__main__":
    unittest.main()
