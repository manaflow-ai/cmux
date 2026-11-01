#!/usr/bin/env python3
"""Exercise managed CAS settings and the nightly's emitted Xcode command."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = ROOT / "scripts/ci/fleet-compilation-cache.sh"


class FleetCacheTests(unittest.TestCase):
    def setUp(self):
        # Runner TMPDIR may exceed sockaddr_un's ~100-byte pathname limit.
        self.scratch = tempfile.TemporaryDirectory(prefix="fleet-cas-", dir="/tmp")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.cache = self.root / "cache with spaces"
        self.cache.mkdir()
        self.sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(self.sock.close)
        self.sock.bind(str(self.cache / "fleet-cas.sock"))
        self.helper = self.cache / "settings.sh"
        self.env = {**os.environ, "CMUX_FLEET_CAS_ROOT": str(self.cache),
                    "CMUX_FLEET_CAS_SETTINGS": str(self.helper),
                    "CMUX_FLEET_CAS_SOCKET": str(self.cache / "fleet-cas.sock"),
                    "CMUX_CI_DISABLE_COMPILATION_CACHE": ""}
        self.helper.write_text('#!/bin/bash\nprintf "%s\\n" COMPILATION_CACHE_ENABLE_PLUGIN=YES '
                               '"COMPILATION_CACHE_REMOTE_SERVICE_PATH=$1" '
                               'COMPILATION_CACHE_CAS_PATH=/untrusted '
                               'OTHER_SWIFT_FLAGS=-unsafe\n')
        self.helper.chmod(0o755)

    def settings(self):
        return subprocess.check_output(["bash", str(SETTINGS)], env=self.env, text=True).splitlines()

    def assert_local(self):
        settings = self.settings()
        self.assertIn("SWIFT_ENABLE_PREFIX_MAPPING=YES", settings)
        self.assertIn("CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES", settings)
        self.assertFalse(any("REMOTE_SERVICE" in s or "CAS_PATH=" in s or "ENABLE_PLUGIN" in s for s in settings))

    def test_healthy_node_uses_fixed_cas_and_filters_helper_settings(self):
        settings = self.settings()
        self.assertIn(f"COMPILATION_CACHE_CAS_PATH={self.cache}/cas", settings)
        self.assertIn(f"COMPILATION_CACHE_REMOTE_SERVICE_PATH={self.cache}/fleet-cas.sock", settings)
        self.assertNotIn("COMPILATION_CACHE_CAS_PATH=/untrusted", settings)
        self.assertNotIn("OTHER_SWIFT_FLAGS=-unsafe", settings)

    def test_missing_socket_keeps_local_cache(self):
        self.env["CMUX_FLEET_CAS_SOCKET"] = str(self.root / "absent.sock")
        self.assert_local()

    def test_failed_helper_keeps_local_cache(self):
        self.helper.write_text("#!/bin/bash\nexit 1\n")
        self.assert_local()

    def test_partial_response_keeps_local_cache(self):
        self.helper.write_text("#!/bin/bash\necho COMPILATION_CACHE_ENABLE_PLUGIN=YES\n")
        self.assert_local()

    def test_disabled_cache_never_probes_node(self):
        self.env["CMUX_CI_DISABLE_COMPILATION_CACHE"] = "1"
        marker = self.root / "probed"
        self.helper.write_text(f"#!/bin/bash\ntouch '{marker}'\n")
        self.assert_local()
        self.assertFalse(marker.exists())

    def test_nightly_xcode_command_receives_shared_settings(self):
        # Execute the workflow's actual compile command through tiny pass-through
        # wrappers. No Xcode or compiler runs; the last executable records argv.
        workflow = (ROOT / ".github/workflows/nightly.yml").read_text()
        step = workflow.split("      - name: Build nightly app (Release)\n", 1)[1].split("      - name:", 1)[0]
        command = step[step.index("          fleet_cache_settings=()") :]
        command = "\n".join(line[10:] for line in command.splitlines() if line.startswith("          "))
        command = command.replace("${{ needs.decide.outputs.cold_cache == 'true' && '1' || '' }}", "")
        scripts = self.root / "scripts/ci"
        scripts.mkdir(parents=True)
        shutil.copyfile(SETTINGS, scripts / SETTINGS.name)
        cache_lib = self.root / "scripts/cmux-next/lib"
        cache_lib.mkdir(parents=True)
        shutil.copyfile(ROOT / "scripts/cmux-next/lib/compilation-cache.sh",
                        cache_lib / "compilation-cache.sh")
        (scripts / "run-with-helper-prebuild.py").write_text(
            "import os,sys\na=sys.argv[sys.argv.index('--')+1:]\nos.execvp(a[0],a)\n")
        wrapper = scripts / "run-xcodebuild-with-diagnostics.sh"
        wrapper.write_text('#!/bin/bash\nshift\nexec "$@"\n')
        wrapper.chmod(0o755)
        xcode = self.root / "xcodebuild"
        xcode.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
        xcode.chmod(0o755)
        env = {**self.env, "PATH": str(self.root) + os.pathsep + self.env["PATH"],
               "RUNNER_TEMP": str(self.root), "CHANNEL_ICON_NAME": "AppIcon-Nightly"}
        result = subprocess.run(["bash", "-euc", 'archs=arm64; only_active=YES; notary_test_flags=(build)\n' + command],
                                cwd=self.root, env=env, text=True, capture_output=True, check=True)
        args = json.loads(result.stdout)
        self.assertIn(f"COMPILATION_CACHE_CAS_PATH={self.cache}/cas", args)
        self.assertIn("COMPILATION_CACHE_ENABLE_PLUGIN=YES", args)
        self.assertIn("SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES", args)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", args)
        self.assertEqual(args[-1], "build")

    def test_warmer_and_pr_release_use_the_same_cache_settings(self):
        nightly = (ROOT / ".github/workflows/nightly.yml").read_text()
        ci_macos = (ROOT / ".github/workflows/ci-macos.yml").read_text()
        warmer = nightly.split("      - name: Refresh universal nightly compilation cache\n", 1)[1].split("      - name:", 1)[0]
        release = ci_macos.split("      - name: Build app (Release)\n", 1)[1].split("      - name:", 1)[0]
        for step in (warmer, release):
            self.assertIn("bash scripts/ci/fleet-compilation-cache.sh", step)
            self.assertIn('"${fleet_cache_settings[@]}"', step)

    def _nightly_release_command(self):
        workflow = (ROOT / ".github/workflows/nightly.yml").read_text()
        step = workflow.split("      - name: Build nightly app (Release)\n", 1)[1].split("      - name:", 1)[0]
        command = step[step.index("          fleet_cache_settings=()") :]
        command = "\n".join(line[10:] for line in command.splitlines() if line.startswith("          "))
        return command.replace("${{ needs.decide.outputs.cold_cache == 'true' && '1' || '' }}", "")

    def _run_nightly_release_stub(self, diagnostic):
        scripts = self.root / "scripts/ci"
        scripts.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SETTINGS, scripts / SETTINGS.name)
        cache_lib = self.root / "scripts/cmux-next/lib"
        cache_lib.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "scripts/cmux-next/lib/compilation-cache.sh",
                        cache_lib / "compilation-cache.sh")
        (scripts / "run-with-helper-prebuild.py").write_text(
            "import os,sys\na=sys.argv[sys.argv.index('--')+1:]\nos.execvp(a[0],a)\n")
        wrapper = scripts / "run-xcodebuild-with-diagnostics.sh"
        wrapper.write_text('#!/bin/bash\nshift\nexec "$@"\n')
        wrapper.chmod(0o755)
        count = self.root / "build-count"
        count.unlink(missing_ok=True)
        args_log = self.root / "xcode-args"
        args_log.unlink(missing_ok=True)
        xcode = self.root / "xcodebuild"
        xcode.write_text(
            "#!/bin/bash\n"
            f"count=0; [[ -f '{count}' ]] && count=$(cat '{count}'); count=$((count + 1)); echo $count > '{count}'\n"
            f"printf '%s\\n' --- >> '{args_log}'; printf '%s\\n' \"$@\" >> '{args_log}'\n"
            f"if [[ $count -eq 1 ]]; then echo {diagnostic!r}; exit 65; fi\n"
        )
        xcode.chmod(0o755)
        env = {**self.env, "PATH": str(self.root) + os.pathsep + self.env["PATH"],
               "RUNNER_TEMP": str(self.root), "CHANNEL_ICON_NAME": "AppIcon-Nightly"}
        command = self._nightly_release_command()
        result = subprocess.run(
            ["bash", "-euc", 'archs=arm64; only_active=YES; notary_test_flags=(build)\n' + command],
            cwd=self.root, env=env, text=True, capture_output=True, check=False,
        )
        return result, count, args_log

    def test_nightly_release_retries_only_on_runtime_cas_diagnostic(self):
        for diagnostic in (
            "error: CAS error encountered during compilation",
            "error: CAS error: No such file or directory",
            "error: remote service unavailable",
            "error: cache plugin failed",
        ):
            result, count, args_log = self._run_nightly_release_stub(diagnostic)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(count.read_text().strip(), "2")
            attempts = args_log.read_text().split("---\n")[1:]
            self.assertIn("SWIFT_ENABLE_PREFIX_MAPPING=YES\n", attempts[0])
            self.assertIn("COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES\n", attempts[0])
            self.assertIn("COMPILATION_CACHE_CAS_PATH=", attempts[0])
            self.assertIn("SWIFT_ENABLE_PREFIX_MAPPING=YES\n", attempts[1])
            self.assertIn("COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES\n", attempts[1])
            self.assertNotIn("COMPILATION_CACHE_CAS_PATH=", attempts[1])
            self.assertNotIn("COMPILATION_CACHE_ENABLE_PLUGIN=YES", attempts[1])
            self.assertNotIn("COMPILATION_CACHE_REMOTE_SERVICE_PATH=", attempts[1])

        result, count, _ = self._run_nightly_release_stub("error: use of unresolved identifier 'cas'")
        self.assertEqual(result.returncode, 65)
        self.assertEqual(count.read_text().strip(), "1")

    def test_nightly_release_retries_local_cache_after_runtime_cas_failure(self):
        workflow = (ROOT / ".github/workflows/nightly.yml").read_text()
        step = workflow.split("      - name: Build nightly app (Release)\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("run_release_build()", step)
        self.assertIn("release_status=${PIPESTATUS[0]}", step)
        self.assertIn("cmux_next_runtime_cas_failed \"$RUNNER_TEMP/nightly-release-build.log\"", step)
        self.assertIn("local_cache_settings=()", step)
        self.assertIn("local_cache_settings+=(\"$setting\")", step)
        self.assertIn('settings=("${local_cache_settings[@]}")', step)
        self.assertIn('${settings[@]+"${settings[@]}"}', step)
        self.assertIn('run_release_build 1', step)
        self.assertIn("retrying the Release build with the local cache", step)
        self.assertIn('exit "$release_status"', step)


if __name__ == "__main__":
    unittest.main()
