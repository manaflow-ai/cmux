import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('fingerprint',Path(__file__).resolve().parents[1]/'scripts/build-resource-fingerprint.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class FingerprintTest(unittest.TestCase):
    def test_content_mode_links_and_ambiguous_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);file=root/'a\nfile';file.write_text('first');link=root/'link';link.symlink_to('missing')
            key=m.fingerprint('tree',root)
            file.write_text('other');self.assertNotEqual(key,m.fingerprint('tree',root))
            key=m.fingerprint('tree',root);file.chmod(0o755);self.assertNotEqual(key,m.fingerprint('tree',root))
            key=m.fingerprint('tree',root);link.unlink();link.symlink_to('different');self.assertNotEqual(key,m.fingerprint('tree',root))
            self.assertEqual(m.fingerprint('tree',root),m.fingerprint('tree',root))

    def test_git_inventory_isolated_from_caller_and_ignores_generated_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);subprocess.run(['git','init','-q',tmp],check=True)
            (root/'.gitignore').write_text('generated/\n');(root/'source').write_text('v1');subprocess.run(['git','-C',tmp,'add','.'],check=True)
            key=m.fingerprint('git',root)
            (root/'generated').mkdir();(root/'generated/output').write_text('generated')
            with patch.dict(os.environ,{'GIT_DIR':'/nonexistent','GIT_INDEX_FILE':'/nonexistent'}):self.assertEqual(key,m.fingerprint('git',root))
            (root/'untracked').write_text('new source');self.assertNotEqual(key,m.fingerprint('git',root))
            key=m.fingerprint('git',root);(root/'source').unlink();self.assertNotEqual(key,m.fingerprint('git',root))

if __name__=='__main__':unittest.main()
