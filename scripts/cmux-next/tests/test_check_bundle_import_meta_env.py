#!/usr/bin/env python3
"""Behavior tests of scripts/cmux-next/check-bundle-import-meta-env.py on synthetic bundles."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOL = ROOT / "scripts/cmux-next/check-bundle-import-meta-env.py"


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(TOOL), *args], capture_output=True, text=True)


class CheckBundleImportMetaEnv(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, rel: str, text: str) -> Path:
        path = self.dir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def test_the_shipped_agent_pane_bug_fails(self) -> None:
        # What cmux#50616's pane.js held: esbuild left the read as written.
        self.write("agent-pane/pane.js", 'function s(e){if(n||!(import.meta.env.DEV||c(e)))return}\n')
        result = run(str(self.dir))
        self.assertEqual(result.returncode, 1)
        self.assertIn("agent-pane/pane.js:1:", result.stderr)
        self.assertIn("import.meta.env.DEV", result.stderr)

    def test_optional_reads_and_chunks_and_inline_scripts_fail(self) -> None:
        self.write("pane/chunks/a-123.js", "x=1;\ny=import.meta.env?.DEV;\n")
        self.write("activity/index.html", "<script type=module>if(import.meta.env.PROD)go()</script>")
        result = run(str(self.dir))
        self.assertEqual(result.returncode, 1)
        self.assertIn("a-123.js:2:", result.stderr)
        self.assertIn("index.html:1:", result.stderr)

    def test_substituted_bundles_and_other_import_meta_reads_pass(self) -> None:
        self.write("pane.js", 'var e={DEV:!1,PROD:!0,MODE:"production"};new URL("w.js",import.meta.url);e?.DEV;\n')
        self.write("environment.js", "const importMetaEnvironment = 1; import.meta.resolve('x');\n")
        # A source map holds the original source; only code that runs is checked.
        self.write("pane.js.map", '{"sourcesContent":["if (import.meta.env.DEV) {}"]}')
        self.write("styles.css", "/* import.meta.env */")
        result = run(str(self.dir))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_missing_path_is_an_error(self) -> None:
        result = run(str(self.dir / "nope"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no such file", result.stderr)


if __name__ == "__main__":
    unittest.main()
