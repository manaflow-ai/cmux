"""Exercise the real publication script without compiling Rust."""
import os
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
            for arch,target in [('arm64','aarch64-apple-darwin'),('x86_64','x86_64-apple-darwin'),('arm64','aarch64-apple-darwin')]:
                stamp=work/f'cmux-diff-sidecar.arch-{arch}.min-14.0.stamp'
                env={k:v for k,v in os.environ.items() if not k.startswith(('CMUX_DIFF_SIDECAR_','CARGO_'))}; env.update(CARGO_HOME=str(cargo.parent), TARGET_BUILD_DIR=str(build),
                         TARGET_TEMP_DIR=str(work), UNLOCALIZED_RESOURCES_FOLDER_PATH='Resources',
                         CODE_SIGNING_ALLOWED='NO', CMUX_DIFF_SIDECAR_ARCHS=arch, CMUX_DIFF_SIDECAR_MIN_MACOS='14.0',
                         CMUX_DIFF_SIDECAR_STAMP=str(stamp))
                subprocess.run(['/bin/bash',str(scripts/SCRIPT.name)],env=env,check=True,capture_output=True)
                self.assertEqual(list(work.glob('cmux-diff-sidecar.arch-*.stamp')),[stamp])
                self.assertEqual(destination.read_text().strip(),target)
                self.assertIn('requested_archs='+arch,stamp.read_text())

if __name__=='__main__': unittest.main()
