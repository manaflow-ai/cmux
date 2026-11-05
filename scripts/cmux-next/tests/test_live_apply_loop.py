#!/usr/bin/env python3
"""live-apply.py: the agent's edit, apply, probe and rollback loop, with web-overlay.sh stubbed.

Runs on any host (Linux included): no app, no fleet. A scratch repository stands in for the
checkout; its web-overlay.sh `build` installs a generation the way the real one does (a
generation folder, the surface links renamed over, manifest.json last).

    python3 -m unittest scripts/cmux-next/tests/test_live_apply_loop.py
"""
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "live-apply.py"

STUB = textwrap.dedent("""\
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "$1" == build ]]
    stamp="$(date +%s%N)"
    gen="$CMUX_WEB_OVERLAY_DIR/.gen-$stamp"
    mkdir -p "$gen/pages"
    cp "$(dirname "$0")/../../webviews/page.txt" "$gen/pages/page.txt"
    ln -sfn ".gen-$stamp/pages" "$CMUX_WEB_OVERLAY_DIR/.pages.next"
    mv -fT "$CMUX_WEB_OVERLAY_DIR/.pages.next" "$CMUX_WEB_OVERLAY_DIR/pages"
    printf '{"stamp": "%s"}\\n' "$stamp" > "$CMUX_WEB_OVERLAY_DIR/manifest.json"
    printf '{"overlay": "%s", "enabled": true}\\n' "$CMUX_WEB_OVERLAY_DIR" > "$(dirname "$CMUX_NEXT_CONFIG_FILE")/web-dev.json"
""")


class LiveApplyLoopTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="live-apply-test."))
        self.repo = self.tmp / "repo"
        (self.repo / "scripts/cmux-next").mkdir(parents=True)
        (self.repo / "webviews").mkdir()
        (self.repo / "webviews/page.txt").write_text("old\n")
        stub = self.repo / "scripts/cmux-next/web-overlay.sh"
        stub.write_text(STUB)
        stub.chmod(0o755)
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD")
        self.overlay = self.tmp / "overlay"
        self.overlay.mkdir()
        self.config = self.tmp / "config" / "cmux-next.json"
        self.config.parent.mkdir()
        self.env = dict(os.environ, CMUX_WEB_OVERLAY_DIR=str(self.overlay), CMUX_NEXT_CONFIG_FILE=str(self.config))

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.tmp)], check=False)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True,
                              text=True).stdout.strip()

    def run_loop(self, *args):
        done = subprocess.run([sys.executable, str(SCRIPT), "--repo", str(self.repo), "--base", self.base, *args],
                              env=self.env, capture_output=True, text=True)
        return done.returncode, json.loads(done.stdout.strip().splitlines()[-1])

    def served(self):
        return (self.overlay / "pages" / "page.txt").read_text().strip()

    def test_untracked_web_edit_is_applied_and_probed(self):
        (self.repo / "webviews/new.txt").write_text("untracked counts\n")
        (self.repo / "webviews/page.txt").write_text("new\n")
        code, verdict = self.run_loop("--probe", f"grep -q new {self.overlay}/pages/page.txt")
        self.assertEqual(code, 0)
        self.assertEqual((verdict["rung"], verdict["applied"], verdict["probe"], verdict["rolled_back"]),
                         ("R0", True, "pass", False))
        self.assertIn("webviews/new.txt", verdict["files"]["web-live"])
        self.assertEqual(verdict["generation"], json.loads((self.overlay / "manifest.json").read_text())["stamp"])
        self.assertEqual(self.served(), "new")

    def test_failed_probe_rolls_back_to_the_previous_generation(self):
        (self.repo / "webviews/page.txt").write_text("first\n")
        self.assertEqual(self.run_loop("--probe", "true")[0], 0)
        first_link = os.readlink(self.overlay / "pages")
        (self.repo / "webviews/page.txt").write_text("second\n")
        code, verdict = self.run_loop("--probe", "exit 1", "--probe-seconds", "1")
        self.assertEqual(code, 1)
        self.assertEqual((verdict["applied"], verdict["probe"], verdict["rolled_back"]), (True, "fail", True))
        self.assertEqual(os.readlink(self.overlay / "pages"), first_link)
        self.assertEqual(self.served(), "first")
        self.assertIn("rolled_back_at", json.loads((self.overlay / "manifest.json").read_text()))

    def test_rollback_with_no_earlier_overlay_restores_the_bundled_pages(self):
        (self.repo / "webviews/page.txt").write_text("new\n")
        code, verdict = self.run_loop("--probe", "exit 1", "--probe-seconds", "1")
        self.assertEqual((code, verdict["rolled_back"]), (1, True))
        self.assertFalse((self.overlay / "pages").is_symlink())
        self.assertFalse((self.overlay / "manifest.json").exists())
        self.assertFalse((self.config.parent / "web-dev.json").exists())

    def test_probe_that_never_answers_is_an_error(self):
        (self.repo / "webviews/page.txt").write_text("new\n")
        code, verdict = self.run_loop("--probe", "exit 7", "--probe-seconds", "1", "--no-rollback")
        self.assertEqual((code, verdict["probe"], verdict["rolled_back"]), (1, "error", False))
        self.assertEqual(self.served(), "new")

    def test_probe_is_asked_again_until_it_passes(self):
        (self.repo / "webviews/page.txt").write_text("new\n")
        flag = self.tmp / "tries"
        probe = f"echo x >> {flag}; [ $(wc -l < {flag}) -ge 3 ]"
        code, verdict = self.run_loop("--probe", probe)
        self.assertEqual((code, verdict["probe"]), (0, "pass"))
        self.assertEqual(verdict["probe_detail"]["tries"], 3)

    def test_swift_change_names_what_it_needs_and_applies_nothing(self):
        swift = self.repo / "Packages/macOS/CmuxNext/Sources/X/View.swift"
        swift.parent.mkdir(parents=True)
        swift.write_text("struct View {}\n")
        code, verdict = self.run_loop("--probe", "true")
        self.assertEqual(code, 3)
        self.assertEqual((verdict["rung"], verdict["applied"]), (None, False))
        self.assertTrue(verdict["needs"])
        self.assertFalse((self.overlay / "manifest.json").exists())

    def test_no_app_change_is_nothing_to_apply(self):
        (self.repo / "docs").mkdir()
        (self.repo / "docs/a.md").write_text("x\n")
        code, verdict = self.run_loop()
        self.assertEqual((code, verdict["verdict"], verdict["applied"]), (0, "no-app", False))

    def test_checkout_index_is_untouched(self):
        (self.repo / "webviews/page.txt").write_text("new\n")
        self.run_loop("--dry-run")
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "")
        self.assertEqual(self.git("status", "--porcelain"), "M webviews/page.txt")


if __name__ == "__main__":
    unittest.main()
