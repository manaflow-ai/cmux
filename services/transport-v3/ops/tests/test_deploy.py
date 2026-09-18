import importlib.util
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch
from pathlib import Path

path=Path(__file__).resolve().parents[1]/'azure'/'deploy.py'
spec=importlib.util.spec_from_file_location('deploy',path)
deploy=importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)
deploy.ARGS=types.SimpleNamespace(registry='testregistry',subscription='test-subscription')

class DeployTests(unittest.TestCase):
    def test_control_entrypoint_requires_a_32_byte_base64_signer_seed(self):
        script = (Path(__file__).resolve().parents[2] / 'control-entrypoint.sh').read_text()
        self.assertIn('${CMUX_V3_SIGNER_SEED_B64:?CMUX_V3_SIGNER_SEED_B64 is required}', script)
        self.assertIn('test "$(wc -c < /run/cmux-v3/signer-seed', script)
        self.assertIn('CMUX_V3_SIGNER_SEED_FILE=/run/cmux-v3/signer-seed', script)
        self.assertIn('exec /usr/local/bin/cmux-v3-control-server', script)

    def test_successful_azure_action_can_return_no_json_body(self):
        with patch.object(deploy,'run',return_value=''):
            self.assertIsNone(deploy.az('acr','import'))
    def test_install_script_is_fail_closed_and_preserves_old_generation(self):
        script=deploy.install_script('registry.azurecr.io/relay@sha256:123','registry.azurecr.io/caddy@sha256:456','node.eastus.cloudapp.azure.com','203.0.113.1',{'test':'aa'*32},'test-identity','bb'*32,None)
        with tempfile.NamedTemporaryFile('w') as f:
            f.write(script);f.flush()
            subprocess.run(['bash','-n',f.name],check=True)
        self.assertIn('Existing node must not be replaced',script)
        self.assertNotIn('docker stop',script)
        self.assertNotIn('docker rm',script)
        self.assertIn('--restart on-failure',script)
        self.assertIn('--read-only --cap-drop ALL',script)
        self.assertIn('/etc/cmux-v3:/run/cmux-v3:ro',script)
        self.assertIn('--client-id test-identity',script)
        self.assertIn('packages.microsoft.com/repos/azure-cli/',script)
        self.assertIn('exit 1',script)
        self.assertNotIn('SIGNER_SEED',script)
    def test_remote_script_values_cannot_inject_shell(self):
        with self.assertRaises(ValueError):
            deploy.install_script('image;bad','proxy','host','ip',{},'identity','bb'*32,None)
    def test_labels_reject_shell_and_resource_scope_injection(self):
        for value in ['foo/bar','x;bad','../old','A','x'*26]:
            with self.assertRaises(Exception): deploy.label(value)

if __name__=='__main__': unittest.main()
