"""Fleet exporters select the pool's compiler and SDK, without changing the host."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ExportToolchain(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.sdk = self.root / "selected-sdk"
        self.sdk.mkdir()
        for rel in ("scripts/cmux-next/lib/warm-swiftpm.sh", "scripts/ci/swift-test-debug-info.sh",
                    "scripts/ci/swiftpm-binary-module-guard.sh"):
            dest = self.root / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / rel, dest)
        self.selector = self.root / "scripts/select-ci-xcode.sh"
        self.selector.write_text(
            '#!/bin/sh\n'
            'test "$CMUX_CI_SKIP_XCODE_SELECT" = 1 || exit 91\n'
            'echo selected >> "$TOOLCHAIN_TRACE"\n'
            'echo "DEVELOPER_DIR=$CMUX_CI_XCODE_APP/Contents/Developer" >> "$GITHUB_ENV"\n')
        self.tool("uname", "echo Darwin")
        self.tool("xcrun", 'test -z "${SDKROOT:-}" || exit 92\n'
                  'echo "sdk:$DEVELOPER_DIR" >> "$TOOLCHAIN_TRACE"\necho "$TEST_SDK"')
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}",
                    "CMUX_CI_XCODE_APP": "/selected/Xcode_27.2.app", "TEST_SDK": str(self.sdk),
                    "TOOLCHAIN_TRACE": str(self.root / "trace"), "SDKROOT": "/stale/sdk"}
        self.env.pop("DEVELOPER_DIR", None)
        self.env.pop("CMUX_NEXT_JOB_BUILT", None)

    def tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def run_select(self):
        return subprocess.run(["bash", "-ec", 'source scripts/cmux-next/lib/warm-swiftpm.sh; '
                               'cmux_next_warm_select_xcode; '
                               'printf "RESULT=%s|%s\\n" "$DEVELOPER_DIR" "$SDKROOT"'],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def test_selects_pinned_compiler_and_replaces_inherited_sdk(self):
        result = self.run_select()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"RESULT=/selected/Xcode_27.2.app/Contents/Developer|{self.sdk}", result.stdout)
        self.assertEqual((self.root / "trace").read_text().splitlines(),
                         ["selected", "sdk:/selected/Xcode_27.2.app/Contents/Developer"])

    def test_existing_actions_selection_is_preserved_but_sdk_is_refreshed(self):
        self.env["DEVELOPER_DIR"] = "/actions/Xcode/Contents/Developer"
        result = self.run_select()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "trace").read_text().splitlines(),
                         ["sdk:/actions/Xcode/Contents/Developer"])

    def test_missing_pin_does_not_fall_back_to_host_compiler(self):
        self.selector.write_text("#!/bin/sh\nexit 17\n")
        result = self.run_select()
        self.assertEqual(result.returncode, 17)
        self.assertFalse((self.root / "trace").exists())


if __name__ == "__main__":
    unittest.main()
