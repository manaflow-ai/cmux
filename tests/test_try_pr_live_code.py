#!/usr/bin/env python3
"""try-pr.sh --live-code: a function-body PR compiles against the live code build and loads, no build.

A scratch repo holds the scripts and one CmuxNextApp file; the "build" is a reload log naming a
stand-in swift-frontend and swiftc, and the "app" is a thread that answers each patch in the live
folder the way CmuxNextLiveCode does. So this checks the script's path (the PR's diff onto the
build's commit, the re-sort, patch.py --tree, the app's answer, the fallbacks), not a real compile.
"""

import os
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP_FILE = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Greeting.swift"
SCRIPTS = ["scripts/cmux-next/try-pr.sh", "scripts/cmux-next/side-instance.sh", "scripts/cmux-next/live_apply.py",
           "scripts/live-code/patch.py"]
BASE_SWIFT = 'struct Greeting {\n    func text() -> String {\n        return "hello"\n    }\n}\n'

# Records the compile (its primaries and their text) and writes each object it was asked for.
FRONTEND = '''#!/usr/bin/env python3
import sys
args = sys.argv[1:]
prim = args[args.index("-primary-filelist") + 1]
with open(sys.argv[0] + ".record", "a") as rec:
    for path in open(prim).read().split():
        rec.write(path + "\\n" + open(path).read() + "\\n--\\n")
for i, a in enumerate(args):
    if a == "-o":
        open(args[i + 1], "w").write("obj")
'''
SWIFTC = '''#!/usr/bin/env python3
import sys
args = sys.argv[1:]
open(args[args.index("-o") + 1], "w").write("dylib")
'''
BUDDY = '''#!/usr/bin/env python3
import plistlib, sys
key = sys.argv[2].split(":", 1)[1]
data = plistlib.load(open(sys.argv[3], "rb"))
if key not in data: sys.exit(1)
value = data[key]
print(str(value).lower() if isinstance(value, bool) else value)
'''


def git(cwd, *args):
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True).stdout.strip()


class TryPrLiveCodeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="try-pr-live-code-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        ident = ["-c", "user.name=t", "-c", "user.email=t@localhost"]
        origin = self.tmp / "origin"
        work = self.tmp / "work"
        work.mkdir()
        git(work, "init", "-q", "-b", "feat-cmux-next")
        for rel in SCRIPTS:
            (work / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, work / rel)
        (work / APP_FILE).parent.mkdir(parents=True)
        (work / APP_FILE).write_text(BASE_SWIFT)
        git(work, "add", "-A")
        git(work, *ident, "commit", "-q", "-m", "base")
        self.base = git(work, "rev-parse", "HEAD")
        subprocess.run(["git", "clone", "-q", "--bare", str(work), str(origin)], check=True)
        self.work, self.origin, self.ident = work, origin, ident
        self.checkout = self.tmp / "checkout"
        subprocess.run(["git", "clone", "-q", str(origin), str(self.checkout)], check=True)

        bin_dir = self.tmp / "bin"
        tc = self.tmp / "toolchain"
        bin_dir.mkdir(); tc.mkdir()
        for path, body in {bin_dir / "PlistBuddy": BUDDY, bin_dir / "codesign": "#!/bin/sh\nexit 0\n",
                           tc / "swift-frontend": FRONTEND, tc / "swiftc": SWIFTC}.items():
            path.write_text(body); path.chmod(0o755)
        self.record = tc / "swift-frontend.record"
        # The build's own checkout, as reload.sh's log names it.
        build = self.tmp / "build"
        (build / APP_FILE).parent.mkdir(parents=True)
        (build / APP_FILE).write_text(BASE_SWIFT)
        filelist = self.tmp / "CmuxNextApp.SwiftFileList"
        filelist.write_text(f"{build / APP_FILE}\n{self.tmp}/DerivedData/resource_bundle_accessor.swift\n")
        self.log = self.tmp / "reload.log"
        self.log.write_text(
            f"builtin-SwiftDriver -- swiftc -module-name CmuxNextApp -Onone @{filelist}\n"
            f"{tc}/swift-frontend -frontend -c -primary-file {build / APP_FILE} -module-name CmuxNextApp "
            f"-target arm64-apple-macos14 -Onone -enable-testing -o {self.tmp}/x.o\n")
        self.app = self.tmp / "cmux DEV live.app"
        (self.app / "Contents").mkdir(parents=True)
        with open(self.app / "Contents/Info.plist", "wb") as f:
            plistlib.dump({"CFBundleIdentifier": "com.cmuxterm.app.debug.live", "CFBundleVersion": "1",
                           "CMUXCommit": self.base}, f)
        self.live = self.tmp / "live"
        self.live.mkdir()
        self.env = {**os.environ, "HOME": str(self.tmp / "home"), "CMUX_SIDE_ROOT": str(self.tmp / "side"),
                    "SIDE_INSTANCE_PLISTBUDDY": str(bin_dir / "PlistBuddy"), "CMUX_LIVE_CODE_DIR": str(self.live),
                    "PATH": f"{bin_dir}:{os.environ['PATH']}"}

    def push_pr(self, edit):
        git(self.work, "checkout", "-q", "-b", "pr", self.base)
        edit(self.work)
        git(self.work, "add", "-A")
        git(self.work, *self.ident, "commit", "-q", "-m", "pr")
        subprocess.run(["git", "-C", str(self.work), "push", "-q", str(self.origin), "HEAD:refs/pull/1/head"],
                       check=True, capture_output=True)

    def answer_patches(self, word="applied"):
        """The app's side: each new patch in the live folder is answered once in live-code.log."""
        stop = threading.Event()

        def run():
            seen = set()
            while not stop.is_set():
                for p in self.live.glob("patch-*.dylib"):
                    if p.name not in seen:
                        seen.add(p.name)
                        line = f"applied {p.name} functions=1" if word == "applied" else f"{p.name} refused: size"
                        with open(self.live / "live-code.log", "a") as log:
                            log.write(f"live code: {line}\n")
                time.sleep(0.05)
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        self.addCleanup(stop.set)

    def try_pr(self, *extra):
        return subprocess.run(["bash", str(self.checkout / "scripts/cmux-next/try-pr.sh"), "1", "--here", "--from",
                               str(self.app), "--live-code", str(self.log), *extra],
                              env=self.env, capture_output=True, text=True, timeout=120)

    def worktrees(self):
        return git(self.checkout, "worktree", "list").splitlines()

    def test_a_body_change_loads_with_no_build(self):
        self.push_pr(lambda w: (w / APP_FILE).write_text(BASE_SWIFT.replace('"hello"', '"hello from the PR"')))
        self.answer_patches()
        out = self.try_pr()
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("swift-live", out.stdout)
        self.assertRegex(out.stdout, r"live code: applied patch-\d+-\d+\.dylib")
        self.assertNotIn("dev build\n", out.stdout.split("swift-live", 1)[1].split("\n", 2)[-1])
        recorded = self.record.read_text()
        self.assertIn(APP_FILE, recorded)
        self.assertIn("hello from the PR", recorded)
        self.assertNotIn(str(self.tmp / "build"), recorded.split("\n")[0])
        self.assertEqual(len(list(self.live.glob("patch-*.dylib"))), 1)
        self.assertEqual(len(self.worktrees()), 1, "the scratch worktree is removed")

    def test_a_refused_patch_falls_back_to_the_dev_build(self):
        self.push_pr(lambda w: (w / APP_FILE).write_text(BASE_SWIFT.replace('"hello"', '"hi"')))
        self.answer_patches(word="refused")
        out = self.try_pr("--no-build")
        self.assertIn("refused", out.stdout)
        self.assertIn("so a dev build", out.stdout)
        self.assertIn("run again without --no-build", out.stdout)

    def test_no_answer_removes_the_patch_and_takes_the_dev_build(self):
        self.push_pr(lambda w: (w / APP_FILE).write_text(BASE_SWIFT.replace('"hello"', '"hi"')))
        self.env["CMUX_TRY_PR_LIVE_WAIT"] = "1"
        out = self.try_pr("--no-build")
        self.assertIn("so it was removed", out.stdout)
        self.assertIn("so a dev build", out.stdout)
        self.assertEqual(list(self.live.glob("patch-*.dylib")), [], "no patch is left for a late watcher")

    def test_a_new_file_takes_the_dev_build(self):
        def edit(w):
            (w / APP_FILE).write_text(BASE_SWIFT.replace('"hello"', '"hi"'))
            (w / APP_FILE).with_name("Extra.swift").write_text('func extra() -> Int {\n    return 1\n}\n')
        self.push_pr(edit)
        out = self.try_pr("--no-build")
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("only edits to CmuxNextApp's existing Swift files; not: Packages/macOS/CmuxNext/Sources/CmuxNextApp/Extra.swift", out.stdout)
        self.assertIn("so a dev build", out.stdout)
        self.assertFalse(self.record.exists(), "nothing was compiled")
        self.assertEqual(len(self.worktrees()), 1)

    def test_a_build_of_a_commit_this_checkout_lacks_takes_the_dev_build(self):
        with open(self.app / "Contents/Info.plist", "wb") as f:
            plistlib.dump({"CFBundleIdentifier": "com.cmuxterm.app.debug.live", "CFBundleVersion": "1",
                           "CMUXCommit": "0123456789abcdef0123456789abcdef01234567"}, f)
        self.push_pr(lambda w: (w / APP_FILE).write_text(BASE_SWIFT.replace('"hello"', '"hi"')))
        out = self.try_pr("--no-build")
        self.assertIn("is not in this checkout", out.stdout)
        self.assertIn("so a dev build", out.stdout)


class TryPrWebAgainstTheAppTests(TryPrLiveCodeTests):
    """A web-only PR is sorted again from the app's own commit (CMUXCommit) when the app is older
    than the PR's base: the PR's web UI must not load into an app that lacks its Swift side."""

    WEB_FILE = "webviews/src/greeting.ts"

    # The base's tests run once, in TryPrLiveCodeTests.
    test_a_body_change_loads_with_no_build = None
    test_a_refused_patch_falls_back_to_the_dev_build = None
    test_no_answer_removes_the_patch_and_takes_the_dev_build = None
    test_a_new_file_takes_the_dev_build = None
    test_a_build_of_a_commit_this_checkout_lacks_takes_the_dev_build = None

    def advance_base(self, edit):
        """A commit on the base after the app was built; returns it."""
        git(self.work, "checkout", "-q", "feat-cmux-next")
        edit(self.work)
        git(self.work, "add", "-A")
        git(self.work, *self.ident, "commit", "-q", "-m", "base moves on")
        subprocess.run(["git", "-C", str(self.work), "push", "-q", str(self.origin), "HEAD:feat-cmux-next"],
                       check=True, capture_output=True)
        return git(self.work, "rev-parse", "HEAD")

    def push_web_pr(self, start):
        git(self.work, "checkout", "-q", "-b", "pr", start)
        (self.work / self.WEB_FILE).parent.mkdir(parents=True, exist_ok=True)
        (self.work / self.WEB_FILE).write_text("export const greeting = 'hi'\n")
        git(self.work, "add", "-A")
        git(self.work, *self.ident, "commit", "-q", "-m", "pr")
        subprocess.run(["git", "-C", str(self.work), "push", "-q", str(self.origin), "HEAD:refs/pull/1/head"],
                       check=True, capture_output=True)

    def set_app_commit(self, commit, **more):
        with open(self.app / "Contents/Info.plist", "wb") as f:
            plistlib.dump({"CFBundleIdentifier": "com.cmuxterm.app.nightly", "CFBundleVersion": "1",
                           "CMUXCommit": commit[:7], **more}, f)

    def test_a_web_pr_on_the_apps_own_commit_stays_live(self):
        self.push_web_pr(self.base)
        out = self.try_pr("--dry-run")
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("web only: no build", out.stdout)
        self.assertNotIn("Swift side", out.stdout)

    def test_swift_the_base_gained_after_the_build_refuses_the_live_apply(self):
        moved = self.advance_base(lambda w: (w / APP_FILE).write_text(BASE_SWIFT.replace('"hello"', '"hey"')))
        self.push_web_pr(moved)
        out = self.try_pr("--dry-run")
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("#1 at", out.stdout)
        self.assertIn("web-live", out.stdout.splitlines()[0])
        self.assertIn(f"built at {self.base[:12]}, before it: from there the change is swift-live", out.stdout)
        self.assertIn("the PR's Swift side is not in that build", out.stdout)
        self.assertIn(APP_FILE, out.stdout)
        self.assertNotIn("web only: no build", out.stdout)

    def test_an_app_newer_than_the_prs_base_stays_live(self):
        self.push_web_pr(self.base)
        newer = self.advance_base(lambda w: (w / APP_FILE).write_text(BASE_SWIFT.replace('"hello"', '"hey"')))
        self.checkout_fetch()
        self.set_app_commit(newer)
        out = self.try_pr("--dry-run")
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("web only: no build", out.stdout)

    def test_an_app_commit_this_checkout_lacks_refuses_the_live_apply(self):
        self.push_web_pr(self.base)
        self.set_app_commit("0123456789abcdef0123456789abcdef01234567")
        out = self.try_pr("--dry-run")
        self.assertIn("is not in this checkout, so whether it has the PR's Swift side is unknown", out.stdout)
        self.assertNotIn("web only: no build", out.stdout)

    def test_a_reload_build_with_local_edits_says_so_and_sorts_from_its_commit(self):
        # reload.sh stamps the full commit and CMUXCommitDirty.
        self.push_web_pr(self.base)
        self.set_app_commit(self.base, CMUXCommit=self.base, CMUXCommitDirty=True)
        out = self.try_pr("--dry-run")
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn(f"built at {self.base[:12]} with local edits; sorting from that commit", out.stdout)
        self.assertIn("web only: no build", out.stdout)

    def checkout_fetch(self):
        git(self.checkout, "fetch", "-q", "origin", "feat-cmux-next:refs/remotes/origin/feat-cmux-next")


if __name__ == "__main__":
    unittest.main()
