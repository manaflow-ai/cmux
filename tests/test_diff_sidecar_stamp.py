"""Exercise the real publication script without compiling Rust."""
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/build-diff-sidecar.sh'

class StampTest(unittest.TestCase):
    def test_architecture_roundtrip_retires_prior_certificate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scripts = root/'scripts'; scripts.mkdir()
            shutil.copy2(SCRIPT, scripts/SCRIPT.name)
            crate = root/'Native/DiffSidecar'; crate.mkdir(parents=True)
            (crate/'rust-toolchain.toml').write_text('channel = "1.88.0"\n')
            cargo = root/'cargo/bin'; cargo.mkdir(parents=True)
            def executable(path, text):
                path.write_text('#!/bin/bash\nset -eu\n'+text); path.chmod(0o755)
            executable(cargo/'codesign', 'printf "signed:%s\\n" "$3" >> "$4"\n')
            executable(cargo/'rustup', 'printf "aarch64-apple-darwin\\nx86_64-apple-darwin\\n"\n')
            executable(scripts/'run-diff-sidecar-cargo.sh', '''
while (( $# )); do
 if [[ "$1" == --target ]]; then target="$2"; shift 2; else shift; fi
done
mkdir -p "$CARGO_TARGET_DIR/$target/release"
printf '%s\\n' "$target" > "$CARGO_TARGET_DIR/$target/release/cmux-diff-sidecar"
chmod +x "$CARGO_TARGET_DIR/$target/release/cmux-diff-sidecar"
''')
            executable(scripts/'verify-diff-sidecar-artifact.sh', 'test -s "$1"\n')
            build = root/'build'; work = root/'work'; work.mkdir()
            destination=build/'Resources/bin/cmux-diff-sidecar'
            project = (SCRIPT.parents[1]/'cmux.xcodeproj/project.pbxproj').read_text()
            stamp_template = re.search(r'"(\$\(TARGET_TEMP_DIR\)/cmux-diff-sidecar.arch-[^"]+\.stamp)"', project).group(1)
            for arch,allowed,identity in [('arm64','NO',''),('arm64','YES','identity-a'),('arm64','YES','identity-b'),('arm64','NO',''),('x86_64','NO',''),('arm64','NO','')]:
                target = 'aarch64-apple-darwin' if arch == 'arm64' else 'x86_64-apple-darwin'
                settings = dict(TARGET_TEMP_DIR=str(work), ARCHS=arch, MACOSX_DEPLOYMENT_TARGET='14.0', CODE_SIGNING_ALLOWED=allowed, EXPANDED_CODE_SIGN_IDENTITY=identity)
                stamp = Path(re.sub(r'\$\(([^)]+)\)', lambda match: settings[match[1]], stamp_template))
                self.assertFalse(stamp.exists(), 'changed configuration must invalidate the Xcode output certificate')
                env={k:v for k,v in os.environ.items() if not k.startswith(('CMUX_DIFF_SIDECAR_','CARGO_'))}; env.update(CARGO_HOME=str(cargo.parent), TARGET_BUILD_DIR=str(build),
                         TARGET_TEMP_DIR=str(work), UNLOCALIZED_RESOURCES_FOLDER_PATH='Resources',
                         CODE_SIGNING_ALLOWED=allowed, EXPANDED_CODE_SIGN_IDENTITY=identity, CMUX_DIFF_SIDECAR_ARCHS=arch, CMUX_DIFF_SIDECAR_MIN_MACOS='14.0',
                         CMUX_DIFF_SIDECAR_STAMP=str(stamp))
                subprocess.run(['/bin/bash',str(scripts/SCRIPT.name)],env=env,check=True,capture_output=True)
                self.assertEqual(list(work.glob('cmux-diff-sidecar.arch-*.stamp')),[stamp])
                self.assertEqual(destination.read_text().splitlines(), [target] + (['signed:'+identity] if allowed == 'YES' else []))
                self.assertIn('requested_archs='+arch,stamp.read_text())

            # Signing settings are part of the certificate, so the stamp must
            # retain them for Xcode's dependency analysis and diagnostics.
            self.assertIn('code_signing_allowed=NO', stamp.read_text())
            self.assertIn('expanded_code_sign_identity=', stamp.read_text())

if __name__=='__main__': unittest.main()
