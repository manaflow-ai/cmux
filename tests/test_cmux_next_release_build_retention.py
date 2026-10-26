#!/usr/bin/env python3
"""Execute the Release workflow build commands against stub compilers."""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text())


class ReleaseBuildRetentionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.workspace = self.root / "workspace"
        scripts = self.workspace / "scripts/cmux-next"
        scripts.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.write_executable(self.bin / "xcodebuild", '#!/bin/bash\nprintf "%s\\n" "$STUB_XCODE_VERSION"\n')
        self.write_executable(self.bin / "xcrun", '#!/bin/bash\nprintf "%s\\n" "$STUB_SDK_BUILD"\n')
        self.write_executable(self.bin / "du", '#!/bin/bash\nprintf "%s\\t%s\\n" "${STUB_DU_KIB:-1}" "$2"\n')
        self.write_executable(self.bin / "ditto", '#!/bin/bash\ntouch "${@: -1}"\n')
        build = '''#!/bin/bash
set -eu
printf '%s\\n' "$1" > "$TEST_PATH"
if [[ -f "$1/compiled.o" ]]; then echo incremental; else echo cold; fi > "$TEST_MODE"
mkdir -p "$1/Build/Products/Release/cmux NEXT DEV.app"
touch "$1/compiled.o"
'''
        for name in ("check-release-compile.sh", "check-cmux-scheme-compile.sh"):
            self.write_executable(scripts / name, build)
        self.write_executable(scripts / "check-app-personalities.sh", "#!/bin/bash\n")
        # The DEV step builds through compile-dev-release.sh; without the compilation cache (unset
        # here) it builds per runner instance, the path these tests pin.
        for name in ("release-derived-data-path.sh", "compile-dev-release.sh", "host_build_lock.py"):
            shutil.copy2(ROOT / "scripts/cmux-next" / name, scripts / name)
        self.job_number = 0

    @staticmethod
    def write_executable(path: Path, content: str):
        path.write_text(content)
        path.chmod(0o755)

    def run_build(self, lane="package", **overrides):
        job, step, build = {
            "package": ("release-compile", "Release compile", "check-release-compile.sh"),
            "dev": ("cmux-scheme-compile", "Compile the cmux NEXT DEV Release app", "compile-dev-release.sh"),
        }[lane]
        step = next(s for s in WORKFLOW["jobs"][job]["steps"] if s.get("name") == step)
        # Run through the compiler invocation; packaging has its own tests.
        lines = []
        for line in step["run"].splitlines():
            lines.append(line)
            if f"scripts/cmux-next/{build} " in line:
                break
        else:
            self.fail(f"no build command in {step['name']}")
        self.job_number += 1
        runner_temp = self.root / f"job-{self.job_number}"
        runner_temp.mkdir()
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.root / "home"),
            "RUNNER_TEMP": str(runner_temp),
            "RUNNER_NAME": "worker-1",
            "GITHUB_WORKSPACE": str(self.workspace),
            "CMUX_NEXT_RUNNER": "glaeda-side-std-xcode-26.6",
            "DEVELOPER_DIR": "/Applications/Xcode_26.6.app/Contents/Developer",
            "STUB_XCODE_VERSION": "Xcode 26.6\nBuild version 17F1",
            "STUB_SDK_BUILD": "26A1",
            "TEST_PATH": str(self.root / "path"),
            "TEST_MODE": str(self.root / "mode"),
            # The DEV step's env always defines this; it is empty when the
            # compiled-product lookup missed, which is the path compiled here.
            "REUSED_ARCHIVE": "",
            "DEV_DAILY_SHA": "a" * 40,
        }
        env.update(overrides)
        result = subprocess.run(["/bin/bash", "-eu", "-c", "\n".join(lines)], cwd=self.workspace,
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return Path((self.root / "path").read_text().strip()), (self.root / "mode").read_text().strip()

    def test_owned_release_jobs_reuse_compilation_between_job_temporaries(self):
        for lane in ("package", "dev"):
            with self.subTest(lane=lane):
                first, mode = self.run_build(lane)
                self.assertEqual(mode, "cold")
                second, mode = self.run_build(lane)
                self.assertEqual(first, second, "owned Release compilation moved to a new job temporary")
                self.assertEqual(mode, "incremental")

    def test_worker_workspace_and_release_lane_have_distinct_build_databases(self):
        original, _ = self.run_build()
        for lane, overrides in (("dev", {}), ("package", {"RUNNER_NAME": "worker-2"}),
                                ("package", {"GITHUB_WORKSPACE": "/another/workspace"})):
            with self.subTest(lane=lane, overrides=overrides):
                path, mode = self.run_build(lane, **overrides)
                self.assertNotEqual(path, original)
                self.assertEqual(mode, "cold")
        _, mode = self.run_build()
        self.assertEqual(mode, "incremental", "another worker/lane removed this worker's output")

    def test_changed_xcode_or_sdk_build_starts_cold_and_prunes_old_generation(self):
        for overrides in ({"STUB_XCODE_VERSION": "Xcode 26.6\nBuild version 17F2"},
                          {"STUB_SDK_BUILD": "26A2"},
                          {"DEVELOPER_DIR": "/Applications/OtherXcode.app/Contents/Developer"}):
            with self.subTest(overrides=overrides):
                original, _ = self.run_build()
                changed, mode = self.run_build(**overrides)
                self.assertNotEqual(changed, original)
                self.assertEqual(mode, "cold")
                self.assertFalse(original.exists(), "obsolete toolchain generation was retained")

    def test_owned_cache_size_cap_reclaims_only_the_selected_lane(self):
        dev, _ = self.run_build("dev")
        first, _ = self.run_build()
        second, mode = self.run_build(STUB_DU_KIB=str(12 * 1024 * 1024 + 1))
        self.assertEqual(first, second)
        self.assertEqual(mode, "cold")
        self.assertTrue((dev / "compiled.o").exists())

    def test_ephemeral_runners_keep_using_separate_job_temporaries(self):
        for lane in ("package", "dev"):
            first, _ = self.run_build(lane, CMUX_NEXT_RUNNER="blacksmith-6vcpu-macos-26")
            second, mode = self.run_build(lane, CMUX_NEXT_RUNNER="blacksmith-6vcpu-macos-26")
            self.assertNotEqual(first, second)
            self.assertEqual(mode, "cold")
            self.assertTrue(str(second).startswith(str(self.root / f"job-{self.job_number}")))


if __name__ == "__main__":
    unittest.main()
