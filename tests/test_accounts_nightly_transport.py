#!/usr/bin/env python3
"""Exercise the shared Nightly probe's real stdio transport with fake cmux children."""
from __future__ import annotations

import importlib.util
import json
import plistlib
import shutil
import subprocess
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "accounts_probe", ROOT / "scripts/measure/accounts-nightly-probe.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class TransportTests(unittest.TestCase):
    def fake_cmux(self, source):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        path = Path(folder.name) / "cmux"
        path.write_text(f"#!{sys.executable}\n" + source)
        path.chmod(0o700)
        patch = mock.patch.object(PROBE.shutil, "which", return_value=str(path))
        patch.start()
        self.addCleanup(patch.stop)
        return path

    def host_cmux(self, *, doctor=0, status=None):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        log = Path(folder.name) / "calls.jsonl"
        identity = status if status is not None else {
            "status": "running", "session": "cmux-app-nightly", "pid": 123,
            "socket": "/tmp/verified-nightly.sock"}
        path = self.fake_cmux(
            "import json, os, sys\n"
            f"with open({str(log)!r}, 'a') as f:\n"
            " f.write(json.dumps({'argv': sys.argv[1:], 'socket': os.environ.get('CMUX_TUI_SOCKET'), "
            "'mux': os.environ.get('CMUX_MUX_SOCKET'), 'tag': os.environ.get('CMUX_TAG'), "
            "'bundle': os.environ.get('CMUX_BUNDLE_ID'), 'app': os.environ.get('CMUX_SOCKET_PATH')}) + '\\n')\n"
            "if sys.argv[-2:] == ['server', 'status']:\n"
            f" print(json.dumps({identity!r})); sys.exit(0)\n"
            "if 'doctor' in sys.argv:\n"
            f" sys.exit({doctor})\n"
            "for line in sys.stdin:\n"
            " req = json.loads(line)\n"
            " if 'id' not in req: continue\n"
            " result = {} if req['method'] == 'initialize' else {'isError': True}\n"
            " print(json.dumps({'id': req['id'], 'result': result}), flush=True)\n")
        patch = mock.patch.object(PROBE, "NIGHTLY_HOST_CLI", str(path))
        patch.start()
        self.addCleanup(patch.stop)
        return log

    def test_nightly_uses_verified_host_for_doctor_and_mcp_without_fallback(self):
        log = self.host_cmux()
        with mock.patch.dict(os.environ, {"CMUX_TUI_SOCKET": "/tmp/probe.sock",
                                         "CMUX_MUX_SOCKET": "/tmp/other.sock", "CMUX_TAG": "probe",
                                         "CMUX_BUNDLE_ID": "com.example.probe", "CMUX_SOCKET_PATH": "/tmp/app.sock"}), \
                mock.patch.object(PROBE.shutil, "which", side_effect=AssertionError("PATH fallback")):
            client = PROBE.ComputerUse(host="nightly")
            try:
                with self.assertRaisesRegex(PROBE.ProbeError, "refused or failed"):
                    client.call("list_windows")
                self.assertEqual(client.sequence, 2)
            finally:
                client.close()
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual([call["argv"] for call in calls], [
            ["--session", "cmux-app-nightly", "--json", "server", "status"],
            ["--socket", "/tmp/verified-nightly.sock", "computer-use", "doctor", "--json"],
            ["computer-use", "mcp"]])
        self.assertIsNone(calls[0]["socket"])
        self.assertTrue(all(call[key] is None for call in calls for key in ("mux", "tag", "bundle", "app")))
        self.assertEqual([call["socket"] for call in calls[1:]], ["/tmp/verified-nightly.sock"] * 2)
        self.assertEqual(client.host_receipt["pid"], 123)

    def test_failed_doctor_never_starts_mcp(self):
        log = self.host_cmux(doctor=3)
        with self.assertRaisesRegex(PROBE.ProbeError, "doctor failed.*exit=3"):
            PROBE.ComputerUse(host="nightly")
        self.assertEqual(len(log.read_text().splitlines()), 2)

    def test_wrong_session_never_runs_doctor(self):
        log = self.host_cmux(status={"status": "running", "session": "probe", "pid": 1,
                                     "socket": "/tmp/probe.sock"})
        with self.assertRaisesRegex(PROBE.ProbeError, "no verified identity"):
            PROBE.ComputerUse(host="nightly")
        self.assertEqual(len(log.read_text().splitlines()), 1)

    def test_failed_doctor_prevents_accounts_action(self):
        log = self.host_cmux(doctor=3)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "Contents").mkdir()
            (root / "Contents/Info.plist").write_bytes(plistlib.dumps({}))
            probe = PROBE.Probe(SimpleNamespace(app=root, out=root / "out", cu_host="nightly"))
            with mock.patch.object(probe, "action") as action:
                with self.assertRaises(PROBE.ProbeError):
                    probe.run()
            action.assert_not_called()
        self.assertEqual(len(log.read_text().splitlines()), 2)

    def test_failed_doctor_prevents_agent_prompts_install_or_workspace(self):
        self.host_cmux(doctor=3)
        spec = importlib.util.spec_from_file_location(
            "agent_prompts", ROOT / "scripts/measure/ext-rows-agent-prompts.py")
        prompts = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(prompts)
        with tempfile.TemporaryDirectory() as folder:
            ctx = SimpleNamespace(app=Path(folder), control="private", pid_file=Path(folder) / "pid",
                                  work=Path(folder), token="fixture", cu_host="nightly", rpc=mock.Mock())
            core = SimpleNamespace(ROOT=ROOT, load=mock.Mock(return_value=PROBE), install_customize=mock.Mock())
            result = prompts.run(ctx, core)
            self.assertFalse(result["checks"]["gui_flow"])
            self.assertIn("doctor failed", result["error"])
            ctx.rpc.assert_not_called()
            core.install_customize.assert_not_called()

    def test_accounts_launcher_arguments_are_accepted_by_probe(self):
        spec = importlib.util.spec_from_file_location(
            "accounts_launch", ROOT / "scripts/measure/accounts-nightly-launch.py")
        launch = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(launch)
        for host in (None, "nightly"):
            with self.subTest(host=host), tempfile.TemporaryDirectory() as folder:
                command = launch.probe_command(Path(folder), 123, "/tmp/private.sock", folder, host)
                with mock.patch.object(PROBE.Probe, "run", return_value=None), mock.patch("builtins.print"):
                    self.assertEqual(PROBE.main(command[2:]), 0)
                self.assertEqual("--cu-host" in command, host is not None)

    def test_shell_launcher_preserves_optional_host_arguments(self):
        # Run the real shell launcher in a disposable tree, replacing only its
        # external app/download commands. CMUX_TEST_BASH selects macOS Bash 3.2.
        shell = os.environ.get("CMUX_TEST_BASH") or shutil.which("bash")
        for option in (None, "cu_host=nightly"):
            with self.subTest(option=option), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                measure = root / "scripts/measure"
                measure.mkdir(parents=True)
                script = measure / "ext-rows-nightly.sh"
                shutil.copyfile(ROOT / "scripts/measure/ext-rows-nightly.sh", script)
                bin_dir = root / "bin"
                bin_dir.mkdir()
                log = root / "probe-argv.json"
                for name in ("curl", "hdiutil", "ditto", "sw_vers", "python3"):
                    stub = bin_dir / name
                    stub.write_text(f"#!{sys.executable}\n" +
                        "import json, os, sys\nfrom pathlib import Path\n" +
                        "if Path(sys.argv[0]).name == 'python3':\n" +
                        f" Path({str(log)!r}).write_text(json.dumps(sys.argv[1:]))\n")
                    stub.chmod(0o700)
                side = root / "scripts/cmux-next/side-instance.sh"
                side.parent.mkdir()
                side.write_text(f"#!{sys.executable}\n" +
                    "import os, sys\nfrom pathlib import Path\n" +
                    "root = Path(os.environ['CMUX_SIDE_ROOT']) / 'extrows'\n" +
                    "if sys.argv[1] == 'make': (root / 'config').mkdir(parents=True)\n" +
                    "if sys.argv[1] == 'path': print(root / 'app with spaces.app')\n" +
                    "if sys.argv[1] == 'socket': print(root / 'control.sock')\n")
                side.chmod(0o700)
                env = {**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                       "TMPDIR": str(root)}
                command = [shell, str(script), "dmg=https://example.invalid/nightly.dmg", "rows=agent_prompts"]
                if option:
                    command.append(option)
                result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                args = json.loads(log.read_text())
                self.assertEqual(args[-2:], ["--rows", "agent_prompts"])
                self.assertEqual(args.count("--cu-host"), int(option is not None))
                if option:
                    self.assertEqual(args[args.index("--cu-host") + 1], "nightly")
                self.assertTrue(args[args.index("--app") + 1].endswith("app with spaces.app"))

    def test_startup_failure_names_executable_exit_and_redacts_secret(self):
        path = self.fake_cmux(
            "import os, sys\n"
            "sys.stdin.readline()\n"
            "sys.stderr.write('worker unavailable ' + os.environ['CMUX_GITHUB_TEST_PASSWORD']"
            " + ' Bearer abc123\\n' + os.environ['CMUX_GITHUB_TEST_TOTP_SEED']"
            " + ' ' + os.environ['CMUX_GITHUB_TEST_LOGIN'] + '\\n')\n"
            "sys.exit(23)\n")
        with mock.patch.dict(os.environ, {"CMUX_GITHUB_TEST_PASSWORD": "private-password",
                                         "CMUX_GITHUB_TEST_TOTP_SEED": "private-seed",
                                         "CMUX_GITHUB_TEST_LOGIN": "private-login"}):
            with self.assertRaises(PROBE.ProbeError) as caught:
                PROBE.ComputerUse()
        message = str(caught.exception)
        self.assertIn(str(path), message)
        self.assertIn("exit=23", message)
        self.assertIn("worker unavailable", message)
        self.assertNotIn("private-password", message)
        self.assertNotIn("abc123", message)
        self.assertNotIn("private-seed", message)
        self.assertNotIn("private-login", message)

    def test_large_stderr_does_not_deadlock_and_retention_is_bounded(self):
        self.fake_cmux("import sys\nsys.stdin.readline()\n"
                       "sys.stderr.write('x' * 262144 + '\\nstartup-tail\\n')\n"
                       "sys.exit(17)\n")
        with self.assertRaises(PROBE.ProbeError) as caught:
            PROBE.ComputerUse()
        self.assertIn("startup-tail", str(caught.exception))
        self.assertLess(len(str(caught.exception)), 4600)

    def test_overlapping_credentials_are_redacted_longest_first(self):
        self.fake_cmux("import os, sys\nsys.stdin.readline()\n"
                       "sys.stderr.write(os.environ['CMUX_GITHUB_TEST_PASSWORD'] + '\\n')\n"
                       "sys.exit(21)\n")
        with mock.patch.dict(os.environ, {"CMUX_GITHUB_TEST_LOGIN": "alice",
                                         "CMUX_GITHUB_TEST_PASSWORD": "alice-private-suffix"}):
            with self.assertRaises(PROBE.ProbeError) as caught:
                PROBE.ComputerUse()
        self.assertNotIn("alice", str(caught.exception))
        self.assertNotIn("private-suffix", str(caught.exception))

    def test_truncation_drops_partial_secret_and_redacts_multiline_remainder(self):
        self.fake_cmux("import os, sys\nsys.stdin.readline()\n"
                       "sys.stderr.write(os.environ['TEST_PASSWORD'] + '\\nworker unavailable\\n')\n"
                       "sys.exit(19)\n")
        with mock.patch.dict(os.environ, {"TEST_PASSWORD": "s" * 5000 + "leaked-tail\nsecond-secret"}):
            with self.assertRaises(PROBE.ProbeError) as caught:
                PROBE.ComputerUse()
        self.assertNotIn("leaked-tail", str(caught.exception))
        self.assertNotIn("second-secret", str(caught.exception))
        self.assertIn("worker unavailable", str(caught.exception))

    def test_after_initialize_stderr_is_discarded_and_refusal_is_terminal(self):
        self.fake_cmux(
            "import json, sys\n"
            "for line in sys.stdin:\n"
            " req = json.loads(line)\n"
            " if 'id' not in req: continue\n"
            " if req['method'] == 'initialize':\n"
            "  sys.stderr.write('startup-only\\n'); sys.stderr.flush()\n"
            "  result = {}\n"
            " else:\n"
            "  sys.stderr.write('later-sensitive' * 20000); sys.stderr.flush()\n"
            "  result = {'isError': True, 'content': []}\n"
            " print(json.dumps({'id': req['id'], 'result': result}), flush=True)\n")
        client = PROBE.ComputerUse()
        self.addCleanup(client.close)
        self.assertEqual(client.startup_stderr, b"")
        with self.assertRaisesRegex(PROBE.ProbeError, "refused or failed"):
            client.call("click", window_id="fixture", element_id="fixture")
        self.assertEqual(client.startup_stderr, b"")
        self.assertEqual(client.sequence, 2, "a refusal must not trigger a retry")


if __name__ == "__main__":
    unittest.main()
