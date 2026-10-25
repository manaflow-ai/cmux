#!/usr/bin/env python3
"""The cmux NEXT DEV Release compile builds the browser-data import out, as
every nightly-next build does, so the DEV app (the tip app, Leo 2026-10-24)
can be notarized.

cx-f58x: Apple notarizes cmux-next only with the import compiled out
(nightly.yml NIGHTLY_NEXT_BROWSER_DATA_IMPORT=compiled-out). Checks that:
- only the DEV Release compile step sets CMUX_NEXT_BROWSER_DATA_IMPORT, so the
  Debug and pull-request scheme compiles keep the import;
- that step proves the result with nightly's two verifiers before archiving;
- check-cmux-scheme-compile.sh uses nightly.yml's exact Swift flags and empty
  browser-sources.json, passes them to xcodebuild, and restores the file.
"""
from pathlib import Path
import re
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text())
NIGHTLY = (ROOT / ".github/workflows/nightly.yml").read_text()
SCRIPT = (ROOT / "scripts/cmux-next/check-cmux-scheme-compile.sh").read_text()
DEV_STEP = "Compile the cmux NEXT DEV Release app"
FLAGS = "-DCMUX_NO_PASSWORD_IMPORT -DCMUX_NO_BROWSER_DATA_IMPORT"
EMPTY_SOURCES = '{"schemaVersion": 1, "engines": {}, "browsers": []}'
SOURCES_PATH = "Packages/macOS/CmuxNext/Sources/CmuxNextBrowserImport/Resources/browser-sources.json"


def steps():
    for job_name, job in WORKFLOW["jobs"].items():
        for step in job.get("steps", []):
            yield job_name, step


class DevReleaseImportOutTests(unittest.TestCase):
    def dev_step(self):
        matches = [step for _, step in steps() if step.get("name") == DEV_STEP]
        self.assertEqual(len(matches), 1, f"want one '{DEV_STEP}' step")
        return matches[0]

    def test_only_the_dev_release_compile_compiles_the_import_out(self):
        step = self.dev_step()
        self.assertEqual(step["env"].get("CMUX_NEXT_BROWSER_DATA_IMPORT"), "compiled-out")
        self.assertEqual(step["env"].get("CMUX_NEXT_BUNDLE_ID"), "com.cmuxterm.app.debug.next",
                         "the DEV app keeps its identity")
        self.assertEqual(step["env"].get("CMUX_NEXT_CONFIGURATION"), "Release")
        others = [(job, s.get("name")) for job, s in steps()
                  if s.get("name") != DEV_STEP
                  and "CMUX_NEXT_BROWSER_DATA_IMPORT" in (s.get("env") or {})]
        self.assertEqual(others, [], "another step compiles the import out")
        job_envs = [name for name, job in WORKFLOW["jobs"].items()
                    if "CMUX_NEXT_BROWSER_DATA_IMPORT" in (job.get("env") or {})]
        self.assertEqual(job_envs, [], "a job-wide setting would reach the Debug compile")
        self.assertNotIn("CMUX_NEXT_BROWSER_DATA_IMPORT", WORKFLOW.get("env") or {})

    def test_the_dev_step_proves_the_import_is_out_before_archiving(self):
        run = self.dev_step()["run"]
        compile_at = run.index("scripts/cmux-next/check-cmux-scheme-compile.sh")
        readers_at = run.index("scripts/ci/check-password-import-readers.sh")
        absent_at = run.index('scripts/ci/check-browser-data-import-absent.sh "$app"')
        archive_at = run.index("/usr/bin/ditto")
        self.assertLess(compile_at, readers_at)
        self.assertLess(compile_at, absent_at)
        self.assertLess(max(readers_at, absent_at), archive_at, "an unproven app would be archived")
        self.assertIn("set -euo pipefail", run)
        for verifier in ("check-password-import-readers.sh", "check-browser-data-import-absent.sh"):
            self.assertTrue((ROOT / "scripts/ci" / verifier).exists(), verifier)

    def test_the_script_uses_nightlys_exact_mechanism(self):
        # nightly.yml's decide step and its compile step.
        self.assertIn(f"swiftImportFlags = '{FLAGS}';", NIGHTLY)
        self.assertIn(f"'{EMPTY_SOURCES}'", NIGHTLY)
        self.assertIn('"OTHER_SWIFT_FLAGS=\\$(inherited) $SWIFT_IMPORT_FLAGS"', NIGHTLY)
        self.assertIn("NIGHTLY_NEXT_BROWSER_DATA_IMPORT: compiled-out", NIGHTLY)
        # The script, keyed by the same value.
        self.assertIn('browser_data_import="${CMUX_NEXT_BROWSER_DATA_IMPORT:-built-in}"', SCRIPT)
        self.assertRegex(SCRIPT, r'if \[\[ "\$browser_data_import" == compiled-out \]\]; then\n'
                                 rf'  swift_import_flags="{re.escape(FLAGS)}"')
        self.assertIn(f"'{EMPTY_SOURCES}'", SCRIPT)
        self.assertIn(f'browser_sources="{SOURCES_PATH}"', SCRIPT)
        self.assertTrue((ROOT / SOURCES_PATH).exists())
        self.assertIn('xcode_args+=("OTHER_SWIFT_FLAGS=\\$(inherited) $swift_import_flags")', SCRIPT)
        # The emptied file goes back after the build, whatever the outcome.
        self.assertIn("trap on_exit EXIT", SCRIPT)
        self.assertIn('cp -f "$browser_sources_backup" "$repo_root/$browser_sources"', SCRIPT)


if __name__ == "__main__":
    unittest.main()
