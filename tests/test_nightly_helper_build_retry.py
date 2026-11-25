"""nightly-steps/helper-build.sh retries the Ghostty CLI helper build only on a Zig package-fetch network failure.

nightly-next run 45594076083 (2026-11-25) ended on one "unable to connect to server: TlsInitializationFailed" from
Zig's own fetch of glslang. Runs the real step script against a stub build script and stub lipo.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

STEP = Path(__file__).parents[1] / "scripts/ci/nightly-steps/helper-build.sh"


class HelperBuildRetry(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / "scripts/ci/nightly-steps").mkdir(parents=True)
        shutil.copy(STEP, self.root / "scripts/ci/nightly-steps/helper-build.sh")
        self.count = self.root / "count"
        self.count.write_text("0")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        lipo = bin_dir / "lipo"
        lipo.write_text("#!/bin/sh\nexit 0\n")
        lipo.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", NIGHTLY_COMPILE_ARCHS="arm64",
                        HELPER_CACHE_HIT="true", GITHUB_STEP_SUMMARY=str(self.root / "summary"),
                        CMUX_HELPER_FETCH_RETRY_DELAY="0", RUNNER_TEMP=str(self.root))
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "t"],
                       cwd=self.root, check=True)

    def build_script(self, failures: int, message: str):
        script = self.root / "scripts/build-ghostty-cli-helper.sh"
        script.write_text(f"""#!/bin/bash
n=$(( $(cat {self.count}) + 1 )); echo $n > {self.count}
if (( n <= {failures} )); then echo '{message}' >&2; exit 1; fi
mkdir -p nightly-helper && echo helper > nightly-helper/ghostty
""")
        script.chmod(0o755)

    def run_step(self):
        return subprocess.run(["bash", "scripts/ci/nightly-steps/helper-build.sh"], cwd=self.root, env=self.env,
                              capture_output=True, text=True)

    def test_a_tls_failure_is_retried_and_succeeds(self):
        self.build_script(2, "build.zig.zon:9:20: error: unable to connect to server: TlsInitializationFailed")
        done = self.run_step()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.count.read_text().strip(), "3")
        self.assertIn("retrying", done.stdout)

    def test_retries_are_bounded(self):
        self.build_script(9, "error: unable to connect to server: ConnectionResetByPeer")
        done = self.run_step()
        self.assertNotEqual(done.returncode, 0)
        self.assertEqual(self.count.read_text().strip(), "3")

    def test_a_compile_error_fails_at_once(self):
        self.build_script(9, "src/main.zig:1:1: error: expected type 'u8'")
        done = self.run_step()
        self.assertNotEqual(done.returncode, 0)
        self.assertEqual(self.count.read_text().strip(), "1")


if __name__ == "__main__":
    unittest.main()
