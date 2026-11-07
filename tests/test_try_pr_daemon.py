#!/usr/bin/env python3
"""try-pr.sh: a daemon PR swaps its daemon into the app (hot-apply.py apply --branch), no dev build.

A scratch repo holds the scripts and one cmux-tui crate; hot-apply.py, web-overlay.sh and cmux-ci are
stand-ins that record how they were called, and hot-apply's plan is the one each test writes. So this
checks try-pr's path (the plan read, the refusals, the unpublished fallback, the web part), not a swap
itself: scripts/cmux-next/tests/test_hot_apply.py checks that.

    python3 tests/test_try_pr_daemon.py
"""

import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ["scripts/cmux-next/try-pr.sh", "scripts/cmux-next/side-instance.sh", "scripts/cmux-next/live_apply.py"]
RUST = "cmux-tui/crates/cmux-tui-core/src/lib.rs"
WEB = "webviews/src/agent-pane/Hello.tsx"

# hot-apply.py: `plan` prints $PLAN (exit 0, or 3 with no parts); `apply` records its argv.
HOT = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["CALLS"], "a") as calls:
    calls.write("hot-apply " + " ".join(sys.argv[1:]) + "\\n")
if sys.argv[1] == "plan":
    plan = json.load(open(os.environ["PLAN"]))
    print(json.dumps(plan))
    sys.exit(0 if plan["parts"] or not plan["left"] else 3)
sys.exit(int(os.environ.get("APPLY_EXIT", "0")))
'''
RECORD = '''#!/bin/sh
echo "$(basename "$0") $*" >> "$CALLS"
'''
BUDDY = '''#!/usr/bin/env python3
import plistlib, sys
key = sys.argv[2].split(":", 1)[1]
data = plistlib.load(open(sys.argv[3], "rb"))
if key not in data: sys.exit(1)
print(data[key])
'''


def git(cwd, *args):
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True).stdout.strip()


class TryPrDaemonTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="try-pr-daemon-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        ident = ["-c", "user.name=t", "-c", "user.email=t@localhost"]
        work, origin = self.tmp / "work", self.tmp / "origin"
        work.mkdir()
        git(work, "init", "-q", "-b", "feat-cmux-next")
        for rel in SCRIPTS:
            (work / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, work / rel)
        (work / "scripts/cmux-next/web-overlay.sh").write_text(RECORD)
        (work / "scripts/cmux-next/web-overlay.sh").chmod(0o755)
        for rel in (RUST, WEB):
            (work / rel).parent.mkdir(parents=True, exist_ok=True)
            (work / rel).write_text("// base\n")
        git(work, "add", "-A")
        git(work, *ident, "commit", "-q", "-m", "base")
        self.base = git(work, "rev-parse", "HEAD")
        subprocess.run(["git", "clone", "-q", "--bare", str(work), str(origin)], check=True)
        self.work, self.origin, self.ident = work, origin, ident
        self.checkout = self.tmp / "checkout"
        subprocess.run(["git", "clone", "-q", str(origin), str(self.checkout)], check=True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, body in {"hot-apply.py": HOT, "cmux-ci": RECORD, "PlistBuddy": BUDDY}.items():
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        self.app = self.tmp / "cmux NIGHTLY.app"
        (self.app / "Contents").mkdir(parents=True)
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "com.cmuxterm.app.nightly.next", "CFBundleVersion": "1",
                           "CMUXCommit": self.base}, handle)
        self.calls, self.plan = self.tmp / "calls", self.tmp / "plan.json"
        self.calls.write_text("")
        self.env = {**os.environ, "HOME": str(self.tmp / "home"), "CMUX_SIDE_ROOT": str(self.tmp / "side"),
                    "SIDE_INSTANCE_PLISTBUDDY": str(bin_dir / "PlistBuddy"), "CMUX_CI": str(bin_dir / "cmux-ci"),
                    "CMUX_TRY_PR_HOT_APPLY": str(bin_dir / "hot-apply.py"), "CALLS": str(self.calls),
                    "PLAN": str(self.plan)}

    def push_pr(self, *paths):
        git(self.work, "checkout", "-q", "-b", "pr", self.base)
        for rel in paths:
            (self.work / rel).write_text("// the PR\n")
        git(self.work, "add", "-A")
        git(self.work, *self.ident, "commit", "-q", "-m", "pr")
        subprocess.run(["git", "-C", str(self.work), "push", "-q", str(self.origin), "HEAD:refs/pull/1/head"],
                       check=True, capture_output=True)

    def write_plan(self, parts=("rust",), left=None, published=True):
        self.plan.write_text(json.dumps({"base": self.base, "parts": list(parts), "left": left or {},
                                         "published": published, "notes": []}))

    def try_pr(self, *extra):
        return subprocess.run(["bash", str(self.checkout / "scripts/cmux-next/try-pr.sh"), "1", "--from",
                               str(self.app), *extra], env=self.env, capture_output=True, text=True, timeout=120)

    def calls_of(self, tool):
        return [line for line in self.calls.read_text().splitlines() if line.startswith(tool + " ")]

    def test_a_published_daemon_pr_is_swapped_in_with_no_build(self):
        self.push_pr(RUST)
        self.write_plan()
        out = self.try_pr("--here")
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn(": daemon", out.stdout)
        self.assertIn("daemon swapped: your app runs #1's daemon", out.stdout)
        apply = [c for c in self.calls_of("hot-apply") if " apply " in f" {c} "]
        self.assertEqual(len(apply), 1)
        self.assertIn("--branch --parts rust --app " + str(self.app), apply[0])
        self.assertEqual(self.calls_of("cmux-ci"), [], "no fleet build")
        self.assertEqual(self.calls_of("web-overlay.sh"), [], "no web part")

    def test_its_web_part_is_served_from_the_branch(self):
        self.push_pr(RUST, WEB)
        self.write_plan(left={"web (not published for a branch)": [WEB]})
        out = self.try_pr("--here")
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("its web UI is patched in too", out.stdout)
        self.assertEqual(self.calls_of("web-overlay.sh"), ["web-overlay.sh follow 1"])

    def test_rust_the_app_links_is_refused_for_the_dev_build(self):
        self.push_pr(RUST)
        self.write_plan(parts=(), left={"Rust the app links (FFI)": [RUST]})
        out = self.try_pr("--here", "--no-build")
        self.assertIn("daemon swap refused", out.stdout)
        self.assertIn("Rust the app links (FFI): " + RUST, out.stdout)
        self.assertIn("so a dev build", out.stdout)
        self.assertIn("run again without --no-build", out.stdout)
        self.assertFalse([c for c in self.calls_of("hot-apply") if " apply " in f" {c} "])

    def test_an_app_with_rust_the_branch_lacks_is_refused(self):
        self.push_pr(RUST)
        self.write_plan(parts=(), left={"unrelated": ["the app's commit has Rust that the PR lacks"]})
        out = self.try_pr("--here", "--no-build")
        self.assertIn("unrelated: the app's commit has Rust", out.stdout)
        self.assertIn("so a dev build", out.stdout)

    def test_a_failed_swap_takes_the_dev_build(self):
        self.push_pr(RUST)
        self.write_plan()
        self.env["APPLY_EXIT"] = "1"
        out = self.try_pr("--here", "--no-build")
        self.assertIn("hot-apply did not apply or check it", out.stdout)
        self.assertIn("so a dev build", out.stdout)

    def test_an_unpublished_tree_swaps_in_the_fleet_build_s_daemon(self):
        self.push_pr(RUST)
        self.write_plan(published=False)
        out = self.try_pr("--here", "--dry-run")
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("not published yet", out.stdout)
        self.assertIn("so the fleet dev build, whose daemon is swapped in", out.stdout)
        self.assertIn("would wait for it and swap its bin/cmux into your app", out.stdout)

    def test_a_side_instance_gets_its_own_copy_swapped_before_it_opens(self):
        self.push_pr(RUST)
        self.write_plan()
        out = self.try_pr("--dry-run")
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        lines = out.stdout.splitlines()
        make = next(i for i, line in enumerate(lines) if "side-instance.sh make pr-1" in line)
        apply = next(i for i, line in enumerate(lines) if "hot-apply.py apply" in line)
        launch = next(i for i, line in enumerate(lines) if "side-instance.sh launch pr-1" in line)
        self.assertLess(make, apply)
        self.assertLess(apply, launch)
        self.assertIn("--app \\<cmux\\ PR\\ #1\\>", lines[apply])


if __name__ == "__main__":
    unittest.main()
