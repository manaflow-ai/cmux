#!/usr/bin/env python3
"""Execute the production hook emitter without compiling the app/CLI target."""
import concurrent.futures
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CodexToolHookSpoolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='cmux-hook-emitter-')
        root = Path(cls.build.name)
        # Compile the actual shell emitter and its value helper, with only the
        # enclosing CLI's constants stubbed. Assertions execute the emitted shell.
        source = (ROOT / 'CLI/CMUXCLI+AgentHookAdmission.swift').read_text()
        start = source.index('    static func queuedAgentHookShellCommand(')
        end = source.index('    /// Captures the identity', start)
        helper = ROOT / 'Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/CodexToolHookProducer.swift'
        harness = 'import Foundation\n'
        if helper.exists():
            harness += helper.read_text() + '\n'
        harness += '''struct CMUXCLI {
static let agentHookAdmissionResponseTimeoutSeconds = 0.5
static func agentHookPIDEnvironmentVariable(agentName: String) -> String {
    "CMUX_" + agentName.uppercased() + "_PID"
}
'''
        harness += source[start:end] + '\n}\n'
        harness += '''print(CMUXCLI.queuedAgentHookShellCommand(
agent: "codex", subcommand: CommandLine.arguments[1],
disableEnvironmentVariable: "CMUX_CODEX_HOOKS_DISABLED", identityMarker: "cmux-codex-hook"))
'''
        (root / 'main.swift').write_text(harness)
        cls.emitter = root / 'emitter'
        subprocess.run(['swiftc', str(root / 'main.swift'), '-o', str(cls.emitter)], check=True, timeout=120)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cmux-hook-spool-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.spool = self.root / 'spool'
        self.spool.mkdir(mode=0o700)
        self.log = self.root / 'cli-launches'
        cli = self.root / 'cmux'
        cli.write_text('#!/bin/sh\nprintf "launch\\n" >> "$HOOK_TEST_LOG"\ncat >/dev/null\nprintf "{}\\n"\n')
        cli.chmod(0o755)
        self.env = {
            'PATH': '/usr/bin:/bin', 'HOME': str(self.root),
            'CMUX_CODEX_HOOK_CMUX_BIN': str(cli), 'HOOK_TEST_LOG': str(self.log),
            'CMUX_SOCKET_PATH': str(self.root / 'unreachable.sock'),
            'CMUX_SURFACE_ID': '22222222-2222-2222-2222-222222222222',
            'CMUX_CODEX_PID': str(os.getpid()), 'CMUX_CODEX_FEED_DIR': str(self.spool),
        }

    def command(self, event='pre-tool-use'):
        return subprocess.check_output([str(self.emitter), event], text=True).strip()

    def run_hook(self, command, payload, env=None):
        result = subprocess.run(['/bin/sh', '-c', command], input=payload, text=True,
                                capture_output=True, env=env or self.env, timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '{}\n')

    def test_tool_burst_never_launches_cli_or_waits_for_socket(self):
        command = self.command()
        payload = '{\n  "session_id":"storm",\n  "tool_input":{"command":"echo 日本語"}\n}'
        for _ in range(8):
            self.run_hook(command, payload)
        self.assertFalse(self.log.exists(), 'tool hooks must not spawn a CLI per event')
        records = [p for p in self.spool.iterdir() if not p.name.endswith(".ready")]
        self.assertGreater(len(records), 0, 'telemetry must still be delivered')
        for record in records:
            self.assertEqual(record.read_bytes(), b'pre-tool-use\n' + payload.encode() + b'\0')

    def test_full_spool_is_bounded_and_fails_open(self):
        command = self.command('post-tool-use')
        for _ in range(70):
            self.run_hook(command, '{"tool_name":"Read"}')
        self.assertFalse(self.log.exists())
        self.assertLessEqual(len([p for p in self.spool.iterdir() if not p.name.endswith(".ready")]), 32)

    def test_parallel_writers_never_mix_records(self):
        command = self.command()
        payloads = ['{"tool_input":"' + str(i) * 12000 + '"}' for i in range(4)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda p: self.run_hook(command, p), payloads))
        expected = {b'pre-tool-use\n' + p.encode() + b'\0' for p in payloads}
        records = [p for p in self.spool.iterdir() if not p.name.endswith(".ready")]
        self.assertGreater(len(records), 0)
        self.assertTrue(all(p.read_bytes() in expected for p in records))
        self.assertFalse(self.log.exists())

    def test_oversized_payload_is_dropped_without_process_fallback(self):
        self.run_hook(self.command(), '{"output":"' + 'x' * 100000 + '"}')
        self.assertEqual([p for p in self.spool.iterdir() if not p.name.endswith(".ready")], [])
        self.assertFalse(self.log.exists())

    def test_disabled_hook_does_not_publish(self):
        env = dict(self.env, CMUX_CODEX_HOOKS_DISABLED='1')
        self.run_hook(self.command(), '{}', env)
        self.assertEqual([p for p in self.spool.iterdir() if not p.name.endswith(".ready")], [])
        self.assertFalse(self.log.exists())

    def test_missing_spool_does_not_fall_back_to_process_storm(self):
        self.spool.rmdir()
        self.run_hook(self.command(), '{}')
        self.assertFalse(self.log.exists())


if __name__ == '__main__':
    unittest.main()
