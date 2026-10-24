#!/usr/bin/env python3
"""Exercise the actual build wrapper with fake tools; no native compilation."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/swiftpm_build_metrics.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("swiftpm_metrics", SCRIPT)
METRICS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METRICS)

FAKE_TOOL = """#!/usr/bin/env python3
import os, pathlib, signal, sys
tool = pathlib.Path(sys.argv[0]).name
if tool != 'swift' or sys.argv[1:] == ['--version']:
    if os.environ.get('FAKE_METADATA_FAIL'):
        sys.exit(8)
    print({'swift': 'Swift version 6.2', 'xcodebuild': 'Xcode 26.6', 'xcrun': '26.6'}[tool])
    sys.exit(0)
build = pathlib.Path('.build')
build.mkdir(exist_ok=True)
(build / 'build.db').write_text('built')
(build / 'workspace-state.json').write_text('{}')
sys.stdout.buffer.write(b'[1/2] Compiling Foo Foo.swift\\n[2/2] Emitting module Foo\\nraw \\xff\\n')
sys.stdout.flush()
print('stderr preserved', file=sys.stderr)
print('Build complete! (0.1s)')
if os.environ.get('FAKE_SIGNAL'):
    os.kill(os.getpid(), signal.SIGTERM)
sys.exit(int(os.environ.get('FAKE_EXIT', '0')))
"""


class SwiftPMBuildMetricsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repo"
        self.package = self.root / "Packages/macOS/CmuxNext"
        self.package.mkdir(parents=True)
        (self.package / "Package.swift").write_text("// fixture\n")
        (self.root / ".gitignore").write_text(".build/\n*.generated\n")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-qm", "fixture")
        self.bin = Path(self.temporary.name) / "bin"
        self.bin.mkdir()
        for name in ("swift", "xcodebuild", "xcrun"):
            path = self.bin / name
            path.write_text(FAKE_TOOL)
            path.chmod(0o755)
        self.output = Path(self.temporary.name) / "metrics"
        self.summary = Path(self.temporary.name) / "summary.md"

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.root), *arguments], stderr=subprocess.DEVNULL)

    def run_build(self, role="swift-test", command=None, **environment):
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", GITHUB_STEP_SUMMARY=str(self.summary), **environment)
        result = subprocess.run([
            sys.executable, str(SCRIPT), "--role", role, "--output-dir", str(self.output),
            "--", *(command or ["swift", "build", "--build-tests"]),
        ], cwd=self.package, env=env, capture_output=True)
        receipt = json.loads((self.output / f"{role}.json").read_text())
        return result, receipt

    def test_success_keeps_output_and_records_observed_work_without_cache_claim(self):
        result, receipt = self.run_build(CMUX_METRICS_WEB_CACHE_OUTCOME="success", CMUX_METRICS_WEB_CACHE_HIT="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"raw \xff", result.stdout)
        self.assertIn(b"stderr preserved", result.stdout)
        self.assertEqual((self.output / "swift-test.log").read_bytes(), result.stdout)
        self.assertFalse(receipt["scratch_before"]["warm_state_present"])
        self.assertTrue(receipt["scratch_after"]["warm_state_present"])
        self.assertIsNone(receipt["scratch_after"]["cache_hit"])
        self.assertEqual(receipt["compile_work"]["compiling"], 1)
        self.assertEqual(receipt["compile_work"]["emitting_module"], 1)
        self.assertEqual(receipt["web_bundle_restore"], {"outcome": "success", "cache_hit": "true"})
        self.assertGreaterEqual(receipt["build_step_seconds"], 0)
        self.assertIn("not redundant compiler CPU", self.summary.read_text())

    def test_failed_command_still_emits_receipt_log_and_summary(self):
        result, receipt = self.run_build("daemon-test", FAKE_EXIT="7")
        self.assertEqual(result.returncode, 7)
        self.assertEqual(receipt["exit_code"], 7)
        self.assertEqual(receipt["status"], "completed")
        self.assertIn("daemon-test", self.summary.read_text())
        self.assertTrue((self.output / "daemon-test.log").is_file())

    def test_unavailable_metadata_and_unwritable_output_do_not_mask_build_exit(self):
        result, receipt = self.run_build(FAKE_METADATA_FAIL="1", FAKE_EXIT="7")
        self.assertEqual(result.returncode, 7)
        self.assertIsNone(receipt["toolchain"]["swift"])
        self.assertIsNone(receipt["compatibility_sha256"])
        self.assertIsNone(receipt["build_identity_sha256"])
        self.assertIn("swift", receipt["compatibility_missing"])
        self.output = Path(self.temporary.name) / "not-a-directory"
        self.output.write_text("occupied")
        result = subprocess.run([
            sys.executable, str(SCRIPT), "--role", "swift-test", "--output-dir", str(self.output),
            "--", "swift", "build", "--build-tests",
        ], cwd=self.package, capture_output=True, env=dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", FAKE_EXIT="7"))
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn(b"stderr preserved", result.stdout)

    def test_unobserved_sources_cannot_look_equivalent(self):
        real_git = shutil.which("git")
        fake_git = self.bin / "git"
        fake_git.write_text(
            "#!/usr/bin/env python3\nimport os,sys\n"
            "if 'ls-files' in sys.argv: sys.exit(3)\n"
            f"os.execv({real_git!r}, sys.argv)\n"
        )
        fake_git.chmod(0o755)
        for source in ("first source", "different source"):
            (self.package / "Package.swift").write_text(source)
            result, receipt = self.run_build()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNone(receipt["build_inputs_sha256"])
            self.assertIsNone(receipt["build_identity_sha256"])
            self.assertIn("unknown", self.summary.read_text())

    def test_signal_and_missing_command_keep_shell_exit_conventions(self):
        result, receipt = self.run_build(FAKE_SIGNAL="1")
        self.assertEqual(result.returncode, 128 + signal.SIGTERM)
        self.assertEqual(receipt["process_return_code"], -signal.SIGTERM)
        result, receipt = self.run_build(command=["/no/such/swift"])
        self.assertEqual(result.returncode, 127)
        self.assertEqual(receipt["compile_work"]["assessment"], "unknown")

    def test_role_and_warm_state_do_not_split_candidate_input_identity(self):
        _, first = self.run_build("swift-test")
        _, second = self.run_build("generated-files")
        self.assertEqual(first["build_inputs_sha256"], second["build_inputs_sha256"])
        self.assertTrue(second["scratch_before"]["warm_state_present"])
        self.assertIsNone(second["scratch_before"]["cache_hit"])

    def test_dirty_recipe_generated_resources_and_dependency_pin_change_identity(self):
        previous = METRICS.source_identity(self.root)["working_inputs_sha256"]
        for path in (self.package / "Package.swift", self.package / "Resources/view.generated", self.package / "Package.resolved"):
            path.parent.mkdir(exist_ok=True)
            path.write_text("changed bytes")
            current = METRICS.source_identity(self.root)["working_inputs_sha256"]
            self.assertNotEqual(previous, current)
            previous = current
        build = self.package / ".build"
        build.mkdir()
        (build / "build.db").write_text("excluded compiler state")
        self.assertEqual(previous, METRICS.source_identity(self.root)["working_inputs_sha256"])

    def test_linked_scratch_key_is_observed_without_calling_it_a_hit(self):
        target = Path(self.temporary.name) / "spm-scratch/toolchain-key/Packages/macOS/CmuxNext"
        target.mkdir(parents=True)
        (target / "build.db").write_text("warm")
        (self.package / ".build").symlink_to(target, target_is_directory=True)
        state = METRICS.scratch_state(self.package)
        self.assertEqual(state["owned_scratch_key"], "toolchain-key")
        self.assertTrue(state["warm_state_present"])
        self.assertIsNone(state["cache_hit"])

    def test_actual_workflow_commands_leave_failed_build_receipts_in_upload_directory(self):
        jobs = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text())["jobs"]
        (self.root / "scripts").mkdir()
        (self.root / "scripts/ci").symlink_to(SCRIPT.parent, target_is_directory=True)
        runner_temp = Path(self.temporary.name) / "runner"
        for role in ("swift-test", "daemon-test", "generated-files"):
            steps = jobs[role]["steps"]
            build = next(step for step in steps if step.get("name") == "Build package and tests")
            upload = next(step for step in steps if step.get("name") == "Upload the test build measurement and log")
            result = subprocess.run(["bash", "-c", build["run"]], cwd=self.package, capture_output=True, env=dict(
                os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", RUNNER_TEMP=str(runner_temp), FAKE_EXIT="9",
            ))
            self.assertEqual(result.returncode, 9, result.stderr)
            directory = Path(upload["with"]["path"].replace("${{ runner.temp }}", str(runner_temp)))
            self.assertEqual(json.loads((directory / f"{role}.json").read_text())["role"], role)
            self.assertTrue((directory / f"{role}.log").is_file())
            # A failed build still uploads; the only skip is a run that reused an earlier pass
            # on the same inputs (#24018), which built nothing.
            self.assertIn(upload["if"], (
                "${{ always() }}",
                "${{ (always()) && steps.reuse.outputs.hit != 'true' }}",
            ))
            self.assertTrue(upload["continue-on-error"])


if __name__ == "__main__":
    unittest.main()
