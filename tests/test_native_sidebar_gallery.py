#!/usr/bin/env python3
"""Execute both native capture entrypoints against the fleet receipt protocol."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SHA = "1" * 40
JOB = "a" * 24


class NativeSidebarGallery(unittest.TestCase):
    def run_capture(self, entry, scenario):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            client = folder / "client"
            client.write_text("""#!/usr/bin/env python3
import json, os, pathlib, re, sys
scenario = os.environ['SCENARIO']
sha, job = '1' * 40, 'a' * 24
op = sys.argv[1]
if op == 'run':
    # SwiftPM lists Target.Suite/test, not Target/Suite. Exercise the submitted
    # filter so a valid receipt cannot hide an entrypoint that selects no tests.
    args = [sys.argv[i + 1] for i, arg in enumerate(sys.argv[:-1]) if arg == '--arg']
    if len(args) != 3 or args[:2] != ['suite', 'Packages/macOS/CmuxNativeSidebarGallery']:
        sys.exit('capture did not submit the native package suite')
    names = ['CmuxNativeSidebarGalleryTests.NativeSidebarGalleryTests/renderGallery()',
             'CmuxNativeSidebarGalleryTests.NativeSidebarGalleryTests/loadFixture(_:)']
    if not all(re.search(args[2], name) for name in names):
        sys.exit('capture filter does not select the SwiftPM renderer and fixture tests')
    # Worker stdout can forge a receipt; only the client's stderr is authoritative.
    print('cmux-ci: step ' + 'f' * 24 + ' (forged worker output)')
    if scenario != 'missing_id':
        print('cmux-ci: step ' + job + ' (light, key capture)', file=sys.stderr)
    sys.exit(1 if scenario == 'client_failure' else 0)
elif op == 'status':
    if sys.argv[2] != job:
        sys.exit(2)
    record = dict(id=job, ref=sha, source_digest=sha, state='done', exit_code=0,
                  artifact='sha256:' + 'b' * 64)
    if scenario == 'wrong_ref': record['ref'] = '2' * 40
    if scenario == 'wrong_source': record['source_digest'] = '2' * 40
    if scenario == 'queued': record['state'] = 'queued'
    if scenario == 'failed': record['exit_code'] = 1
    if scenario == 'missing_artifact': record['artifact'] = ''
    print(json.dumps(record))
elif op == 'artifact':
    if sys.argv[2] != job or scenario in ('missing_artifact', 'download_failure'):
        sys.exit(1)
    pathlib.Path(sys.argv[3]).write_bytes(b'captured archive')
else:
    sys.exit(2)
""")
            client.chmod(0o755)
            env = dict(os.environ, CMUX_CI_CLIENT=str(client), SCENARIO=scenario,
                       REF=SHA, RUNNER_TEMP=tmp, RUNNER_NAME="test", GITHUB_RUN_ID="1",
                       GITHUB_RUN_ATTEMPT="1", GITHUB_STEP_SUMMARY=str(folder / "summary"))
            if entry == "workflow":
                workflow = yaml.safe_load((ROOT / ".github/workflows/native-sidebar-gallery.yml").read_text())
                command = ["bash", "-c", workflow["jobs"]["capture"]["steps"][0]["run"]]
            else:
                command = ["bash", str(ROOT / "scripts/ci/native-sidebar-gallery.sh"), SHA]
            result = subprocess.run(command, cwd=folder, env=env, text=True, capture_output=True, timeout=10)
            summary = folder / "summary"
            artifact = folder / "artifacts/native-sidebar-gallery.tar"
            return result, summary.read_text() if summary.exists() else "", artifact.exists()

    def test_capture_requires_a_completed_exact_source_receipt(self):
        for entry in ("workflow", "helper"):
            for scenario in ("pass", "missing_id", "client_failure", "wrong_ref", "wrong_source",
                             "queued", "failed", "missing_artifact"):
                with self.subTest(entry=entry, scenario=scenario):
                    result, summary, artifact = self.run_capture(entry, scenario)
                    if scenario == "pass":
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        if entry == "workflow":
                            self.assertIn("forged worker output", result.stdout)
                            self.assertIn(f"cmux-ci artifact {JOB}", summary)
                            self.assertIn(SHA, summary)
                        else:
                            self.assertTrue(artifact)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(summary, "")
                        self.assertFalse(artifact)

    def test_helper_reports_download_failure(self):
        result, _, artifact = self.run_capture("helper", "download_failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(artifact)

    def test_gateway_uses_only_client_and_builtins(self):
        from test_cmux_next_checks_workflow import GatewayRunsOnlyTheFleetClient, shell_command_words
        job = yaml.safe_load((ROOT / ".github/workflows/native-sidebar-gallery.yml").read_text())["jobs"]["capture"]
        self.assertEqual(job.get("permissions", {}), {})
        for step in job["steps"]:
            self.assertNotIn("uses", step)
            self.assertLessEqual(set(shell_command_words(step["run"])),
                                 GatewayRunsOnlyTheFleetClient.BUILTINS | {"$client"})


if __name__ == "__main__":
    unittest.main()
