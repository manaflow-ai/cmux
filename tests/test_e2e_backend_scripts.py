#!/usr/bin/env python3
"""Exercise the portable contracts of the per-run iOS E2E helpers."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BACKEND_ENV = ROOT / "scripts/e2e/backend-env.sh"
BACKEND_UP = ROOT / "scripts/e2e/backend-up.sh"
IOS_E2E_RUN = ROOT / "scripts/e2e/ios-e2e-run.sh"


class BackendScriptContractTests(unittest.TestCase):
    def run_script(self, script: Path, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        child_env = os.environ.copy()
        for name in (
            "CMUX_E2E_BACKEND_NAME",
            "CMUX_E2E_BACKEND_TAILNET_HOSTNAME",
            "CMUX_E2E_BACKEND_STATE_DIR",
            "CMUX_E2E_BACKEND_DONE_FILE",
            "CMUX_E2E_WAIT_TIMEOUT_SECONDS",
            "CMUX_E2E_STACK_PROJECT_ID",
            "CMUX_E2E_STACK_PUBLISHABLE_KEY",
            "CMUX_E2E_STACK_SERVER_KEY",
            "CMUX_E2E_IROH_RELAY_BIN",
            "CMUX_E2E_TLS_CERT",
            "CMUX_E2E_TLS_KEY",
        ):
            child_env.pop(name, None)
        child_env.update(env or {})
        return subprocess.run(
            ["bash", str(script), *args],
            cwd=ROOT,
            env=child_env,
            text=True,
            capture_output=True,
            check=False,
        )

    def run_backend_up_fixture(self, *args: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "repo"
            script = fixture / "scripts/e2e/backend-up.sh"
            script.parent.mkdir(parents=True)
            (fixture / "workers/iroh-v2").mkdir(parents=True)
            (fixture / "workers/presence").mkdir(parents=True)
            shutil.copy2(BACKEND_UP, script)
            script.chmod(0o755)

            fake_bin = Path(directory) / "bin"
            fake_bin.mkdir()
            for command in ("docker", "sudo"):
                fake = fake_bin / command
                fake.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                fake.chmod(0o755)

            env = os.environ.copy()
            env.update({
                "CMUX_E2E_BACKEND_STATE_DIR": str(Path(directory) / "state"),
                "PATH": f"{fake_bin}:{env['PATH']}",
            })
            return subprocess.run(
                ["bash", str(script), *args],
                cwd=fixture,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_backend_env_emits_the_four_origins_and_simulator_copies(self) -> None:
        result = self.run_script(BACKEND_ENV, "env", "--simctl", env={
            "CMUX_E2E_BACKEND_NAME": "cmux-e2e-backend.example.ts.net",
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(
            lines,
            [
                "CMUX_IROH_V2_BASE_URL=https://cmux-e2e-backend.example.ts.net:8443",
                "SIMCTL_CHILD_CMUX_IROH_V2_BASE_URL=https://cmux-e2e-backend.example.ts.net:8443",
                "CMUX_IROH_V2_ENVIRONMENT=development",
                "SIMCTL_CHILD_CMUX_IROH_V2_ENVIRONMENT=development",
                "CMUX_IROH_V2_FORCE_RELAY=1",
                "SIMCTL_CHILD_CMUX_IROH_V2_FORCE_RELAY=1",
                "CMUX_PRESENCE_BASE_URL=https://cmux-e2e-backend.example.ts.net:8444",
                "SIMCTL_CHILD_CMUX_PRESENCE_BASE_URL=https://cmux-e2e-backend.example.ts.net:8444",
            ],
        )

    def test_backend_env_wait_uses_bounded_health_probes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fake_curl = Path(directory) / "curl"
            fake_curl.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_curl.chmod(0o755)
            result = self.run_script(
                BACKEND_ENV,
                "wait",
                "1",
                env={
                    "CMUX_E2E_BACKEND_NAME": "cmux-e2e-backend.example.ts.net",
                    "PATH": f"{directory}:{os.environ['PATH']}",
                },
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("https://cmux-e2e-backend.example.ts.net:8443/v2/health", result.stdout)
        self.assertIn("https://cmux-e2e-backend.example.ts.net:8444/healthz", result.stdout)

    def test_backend_env_requires_the_fixed_certificate_name(self) -> None:
        result = self.run_script(BACKEND_ENV, "env")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CMUX_E2E_BACKEND_NAME is required", result.stderr)

    def test_backend_env_cleanup_does_not_require_the_backend_name(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fake_sudo = Path(directory) / "sudo"
            fake_sudo.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_sudo.chmod(0o755)
            result = self.run_script(
                BACKEND_ENV,
                "unhosts",
                env={"PATH": f"{directory}:{os.environ['PATH']}"},
            )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_backend_up_reports_missing_config_without_echoing_secret_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            secret = "server-key-must-not-appear-in-errors"
            result = self.run_script(
                BACKEND_UP,
                "up",
                env={
                    "CMUX_E2E_BACKEND_NAME": "cmux-e2e-backend.example.ts.net",
                    "CMUX_E2E_BACKEND_STATE_DIR": directory,
                    "CMUX_E2E_STACK_PROJECT_ID": "project",
                    "CMUX_E2E_STACK_PUBLISHABLE_KEY": "publishable",
                    "CMUX_E2E_STACK_SERVER_KEY": secret,
                    "CMUX_E2E_IROH_RELAY_BIN": "/bin/sh",
                    "CMUX_E2E_TLS_CERT": "certificate",
                },
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CMUX_E2E_TLS_KEY", result.stderr)
        self.assertNotIn(secret, result.stdout + result.stderr)

    def test_backend_up_hold_times_out_cleanly_and_accepts_completion(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            done_file = Path(directory) / "done"
            base_env = {
                "CMUX_E2E_BACKEND_NAME": "cmux-e2e-backend.example.ts.net",
                "CMUX_E2E_BACKEND_STATE_DIR": directory,
                "CMUX_E2E_BACKEND_DONE_FILE": str(done_file),
                "CMUX_E2E_WAIT_TIMEOUT_SECONDS": "0",
            }
            timed_out = self.run_script(BACKEND_UP, "hold", env=base_env)
            done_file.touch()
            completed = self.run_script(BACKEND_UP, "hold", env=base_env)

        self.assertEqual(timed_out.returncode, 0, timed_out.stderr)
        self.assertIn("wait-timeout", timed_out.stdout)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("completion signal received", completed.stdout)

    def test_backend_up_hold_empty_state_dir_has_no_crash_noise(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_script(
                BACKEND_UP,
                "hold",
                env={
                    "CMUX_E2E_BACKEND_NAME": "cmux-e2e-backend.example.ts.net",
                    "CMUX_E2E_BACKEND_STATE_DIR": directory,
                    "CMUX_E2E_BACKEND_DONE_FILE": str(Path(directory) / "done"),
                    "CMUX_E2E_WAIT_TIMEOUT_SECONDS": "1",
                },
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("cat:", result.stderr)
        self.assertNotIn("backend crash: *", result.stderr)

    def test_backend_up_rejects_unknown_commands(self) -> None:
        result = self.run_script(BACKEND_UP, "unknown", env={
            "CMUX_E2E_BACKEND_NAME": "cmux-e2e-backend.example.ts.net",
        })
        self.assertEqual(result.returncode, 2)
        self.assertRegex(result.stderr, r"usage: .*backend-up\.sh up\|hold\|down")

    def test_backend_up_cleanup_does_not_require_the_backend_name(self) -> None:
        result = self.run_backend_up_fixture("down")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("stopped processes", result.stdout)

    def test_ios_driver_failure_uses_the_documented_machine_marker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "repo"
            e2e_dir = fixture / "scripts/e2e"
            e2e_dir.mkdir(parents=True)
            shutil.copy2(IOS_E2E_RUN, e2e_dir / IOS_E2E_RUN.name)
            shutil.copy2(ROOT / "scripts/e2e/ocr.swift", e2e_dir / "ocr.swift")

            debug_cli = fixture / "scripts/cmux-debug-cli.sh"
            debug_cli.parent.mkdir(parents=True, exist_ok=True)
            debug_cli.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            debug_cli.chmod(0o755)

            fake_bin = Path(directory) / "bin"
            fake_bin.mkdir()
            swiftc = fake_bin / "swiftc"
            swiftc.write_text(
                "#!/bin/sh\nout=\"\"; for arg do out=\"$arg\"; done; "
                "printf '#!/bin/sh\\n' > \"$out\"; chmod +x \"$out\"\n",
                encoding="utf-8",
            )
            swiftc.chmod(0o755)
            xcrun = fake_bin / "xcrun"
            xcrun.write_text(
                "#!/bin/sh\n"
                "if [ \"$1 $2\" = \"simctl list\" ]; then echo 'SIM-UDID (Booted)'; fi\n"
                "exit 0\n",
                encoding="utf-8",
            )
            xcrun.chmod(0o755)
            axe = fake_bin / "axe"
            axe.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            axe.chmod(0o755)

            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:{env['PATH']}"
            result = subprocess.run(
                [
                    "bash",
                    str(e2e_dir / IOS_E2E_RUN.name),
                    "--tag",
                    "driver-contract",
                    "--sim-udid",
                    "SIM-UDID",
                    "--evidence-dir",
                    str(Path(directory) / "evidence"),
                ],
                cwd=fixture,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertNotEqual(result.returncode, 0)
        stderr_lines = result.stderr.rstrip().splitlines()
        self.assertTrue(stderr_lines, result.stdout)
        self.assertTrue(stderr_lines[-1].startswith("E2E FAIL step="), result.stderr)


if __name__ == "__main__":
    unittest.main()
