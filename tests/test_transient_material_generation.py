#!/usr/bin/env python3
"""Web-only generation stays independent of native source; native drift still fails."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GENERATOR = "webviews/scripts/pages/gen-design-scale.mjs"
GUARD = "scripts/cmux-next/check-surface-roles.py"
NATIVE = "Packages/Shared/CmuxTheme/Sources/CmuxTheme/TransientMaterial.swift"
SCALE = "schemas/design-scale/design-scale.json"
CSS = "webviews/src/pages/shared/desktop.css"


class TransientMaterialGenerationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="transient-generation-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def copy(self, *files):
        for name in files:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)

    def run_script(self, executable, script, *args):
        return subprocess.run(
            [executable, str(self.root / script), *args], cwd=self.root,
            capture_output=True, text=True, timeout=30,
        )

    def test_web_only_checkout_generates_complete_tokens_without_native_source(self):
        self.copy(GENERATOR, SCALE, CSS, "schemas/type-scale/type-scale.json",
                  "schemas/motion-scale/motion-scale.json")
        (self.root / "webviews/src/ui").mkdir(parents=True)
        result = self.run_script("node", GENERATOR, "--check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name in ("theme.generated.css", "designTokens.generated.ts"):
            self.assertTrue((self.root / "webviews/src/ui" / name).stat().st_size)
        self.assertFalse((self.root / "Packages").exists())

    def test_native_guard_rejects_drift_and_missing_native_copy(self):
        self.copy(GUARD, NATIVE, SCALE, "schemas/surface-roles/surface-roles.json",
                  "webviews/src/ui/glass/glass.css",
                  "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/FloatingGlass/SurfaceRole.swift")
        result = self.run_script(sys.executable, GUARD)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        native = self.root / NATIVE
        original = native.read_text()
        scale = json.loads((self.root / SCALE).read_text())
        fields = dict(scale["transientMaterial"])
        fields.update({key: scale["glassMaterial"][key] for key in ("neutralDark", "neutralLight")})
        for key, value in fields.items():
            if not isinstance(value, (int, float)):
                continue
            with self.subTest(token=key):
                declaration = f"public let {key}: Double = {value}"
                self.assertIn(declaration, original)
                native.write_text(original.replace(declaration, f"public let {key}: Double = 0.98765"))
                result = self.run_script(sys.executable, GUARD)
                self.assertNotEqual(result.returncode, 0, key)
                self.assertIn(key, result.stdout + result.stderr)
        native.unlink()
        result = self.run_script(sys.executable, GUARD)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TransientMaterial.swift", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
