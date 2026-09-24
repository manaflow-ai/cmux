"""Exercise the workflow's shell with fake packagers; never invoke Apple tools."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/ios-testflight.yml'


def archive_step():
    text = WORKFLOW.read_text()
    block = text.split('      - name: Archive, export, and upload to TestFlight\n')[1]
    return textwrap.dedent(block.split('        run: |\n')[1].split('\n      - name:')[0])


class PrepareCandidateTests(unittest.TestCase):
    def run_step(self, prepare, override):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            scripts = root / 'ios/scripts'
            scripts.mkdir(parents=True)
            for name in ('upload-testflight.sh', 'cloud-testflight.sh'):
                script = scripts / name
                script.write_text('#!/usr/bin/env python3\n' + textwrap.dedent('''\
                    import json, os, sys
                    from pathlib import Path
                    Path('called.json').write_text(json.dumps({
                        'script': Path(sys.argv[0]).name,
                        'args': sys.argv[1:],
                        'version': os.environ.get('BETA_MARKETING_VERSION'),
                    }))
                    Path(os.environ['CMUX_BUILD_NUMBER_OUT_FILE']).write_text('20260924180000')
                    '''))
                script.chmod(0o755)
            env = dict(os.environ, INPUT_PREPARE_ONLY=prepare,
                IOS_TESTFLIGHT_UPLOAD_MODE='marketing_version_override' if override else 'canonical',
                INPUT_MARKETING_VERSION_OVERRIDE='1.0.6' if override else '',
                INPUT_BUILD_NUMBER='', LAST_UPLOADED_SHA='',
                CMUX_BUILD_NUMBER_OUT_FILE=str(root / 'build-number'),
                GITHUB_OUTPUT=str(root / 'output'), ARCHIVE_LOG=str(root / 'archive.log'))
            subprocess.run(['bash', '-c', archive_step()], cwd=root, env=env,
                           check=True, capture_output=True, text=True)
            self.assertIn('final_build_number=20260924180000', (root / 'output').read_text())
            return json.loads((root / 'called.json').read_text())

    def test_beta_candidate_exports_without_upload(self):
        call = self.run_step('true', True)
        self.assertEqual(call['script'], 'upload-testflight.sh')
        self.assertEqual(call['version'], '1.0.6')
        self.assertIn('--export-only', call['args'])
        self.assertIn('--external', call['args'])

    def test_internal_candidate_exports_without_upload(self):
        call = self.run_step('true', False)
        self.assertIn('--export-only', call['args'])
        self.assertNotIn('--external', call['args'])

    def test_normal_beta_still_uses_existing_upload_path(self):
        call = self.run_step('false', True)
        self.assertEqual(call['script'], 'cloud-testflight.sh')
        self.assertIn('--external', call['args'])
        self.assertNotIn('--export-only', call['args'])

    def test_normal_internal_still_uploads(self):
        call = self.run_step('', False)
        self.assertEqual(call['script'], 'upload-testflight.sh')
        self.assertNotIn('--export-only', call['args'])

    def test_candidate_cannot_claim_uploaded_metadata(self):
        text = WORKFLOW.read_text()
        self.assertIn("uploaded: ${{ github.event.inputs.prepare_only != 'true' && steps.upload.outcome || 'skipped' }}", text)
        for name in ('Persist uploaded build metadata', 'Upload build metadata artifact', 'Save deferred TestFlight notes request'):
            step = text.split(f'      - name: {name}\n')[1].split('\n      - name:')[0]
            self.assertIn("github.event.inputs.prepare_only != 'true'", step)
        candidate = text.split('      - name: Package prepared candidate\n')[1].split('\n      - name:')[0]
        self.assertIn('/export/cmux-resigned.ipa', candidate)


if __name__ == '__main__':
    unittest.main()
