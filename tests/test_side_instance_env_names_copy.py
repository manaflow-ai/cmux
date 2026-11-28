#!/usr/bin/env python3
"""side-instance.sh env NAME names the copy as web-overlay.sh's target app (CMUX_WEB_OVERLAY_APP).

Without it, web-overlay.sh checked the overlay's web ABI against the installed /Applications NIGHTLY,
not the copy the overlay goes into. On 2026-11-27, hot-verify's look of cmux#62321 (head ABI 9) on a
copy of NIGHTLY 4605751670101 (ABI 9) was refused: "/Applications/cmux NIGHTLY.app has web ABI 7".
That was the worker's stale install. The env is parsed as hot-verify.py's Side.env parses it
(shlex), from a copy whose path has a space in it.
"""

import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/side-instance.sh"


class SideEnvNamesCopy(unittest.TestCase):
    def test_env_names_the_copy_as_overlay_app(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve() / "side root"
            copy = root / "pr-1" / "cmux pr-1.app"
            copy.mkdir(parents=True)
            (root / "pr-1" / ".side-instance").write_text(f"app={copy}\n")
            done = subprocess.run(["bash", str(SCRIPT), "env", "pr-1"], capture_output=True, text=True,
                                  env={**os.environ, "CMUX_SIDE_ROOT": str(root)})
            self.assertEqual(done.returncode, 0, done.stderr)
            found = dict(word.partition("=")[::2] for word in shlex.split(done.stdout) if "=" in word)
            self.assertEqual(found.get("CMUX_WEB_OVERLAY_APP"), str(copy))
            self.assertEqual(found.get("CMUX_WEB_OVERLAY_DIR"), str(root / "pr-1" / "web-overlay"))

    def test_overlay_preflight_under_the_env_judges_the_copy(self):
        """web-overlay.sh install, under the copy's env, checks the bundles' ABI against the copy's (9): ABI 7
        bundles are refused naming the copy, and ABI 9 bundles are installed into the copy's overlay folder."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            copy = root / "pr-1" / "cmux pr-1.app"
            pages = copy / "Contents/Resources/CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages"
            pages.mkdir(parents=True)
            (pages / "web-abi.json").write_text('{"abi": 9}\n')
            (root / "pr-1" / ".side-instance").write_text(f"app={copy}\n")
            exports = subprocess.run(["bash", str(SCRIPT), "env", "pr-1"], capture_output=True, text=True,
                                     env={**os.environ, "CMUX_SIDE_ROOT": str(root)}, check=True).stdout

            def bundles(name, abi):
                out = root / name
                agent = out / "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
                built = out / "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
                agent.mkdir(parents=True)
                built.mkdir(parents=True)
                (agent / "index.html").write_text("<html></html>\n")
                (built / "web-abi.json").write_text(f'{{"abi": {abi}}}\n')
                return out

            overlay = ROOT / "scripts/cmux-next/web-overlay.sh"

            def install(source):
                return subprocess.run(["bash", "-c", exports + 'exec bash "$0" install "$1" --commit abc',
                                       str(overlay), str(source)], capture_output=True, text=True)

            old = install(bundles("old", 7))
            self.assertNotEqual(old.returncode, 0, old.stdout + old.stderr)
            self.assertIn(str(copy), old.stderr)
            self.assertIn("web ABI 7", old.stderr)
            same = install(bundles("same", 9))
            self.assertEqual(same.returncode, 0, same.stdout + same.stderr)
            self.assertTrue(any((root / "pr-1" / "web-overlay").iterdir()))


if __name__ == "__main__":
    unittest.main()
