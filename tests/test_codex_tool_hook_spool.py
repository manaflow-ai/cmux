#!/usr/bin/env python3
"""Execute the production hook emitter without compiling the app/CLI target."""
import concurrent.futures
import os
import select
import sys
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
        worker_source = root / 'WorkerMain.swift'
        worker_source.write_text('''import Foundation
import Darwin
@main struct WorkerMain {
    static func main() async {
        let spool = CodexToolFeedSpool(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
        let changes = await spool.changes(parentPID: Int32(CommandLine.arguments[2])!)
        print("ready"); fflush(stdout)
        for await _ in changes {
            for record in await spool.drain() {
                print(String(data: record.payload, encoding: .utf8)!); fflush(stdout)
            }
        }
        await spool.close()
    }
}
''')
        controller = (ROOT / 'Sources/TerminalController.swift').read_text()
        start = controller.index('ControlClientWorkerPool(', controller.index('let socketClientWorkerPool'))
        end = controller.index(')', start) + 1
        pool_source = root / 'PoolMain.swift'
        pool_source.write_text('''import Foundation
@main struct PoolMain {
    static func main() async {
        let pool = ''' + controller[start:end] + '''
        let (idle, finish) = AsyncStream<Void>.makeStream()
        var started = 0
        for _ in 0..<101 {
            let result = await pool.submit { for await _ in idle {} }
            if result == .started { started += 1 }
        }
        print(started)
        await pool.stop()
        finish.finish()
    }
}
''')
        cls.pool_probe = root / 'pool-probe'
        subprocess.run(['swiftc', str(ROOT / 'Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Server/ControlClientWorkerPool.swift'),
                        str(pool_source), '-o', str(cls.pool_probe)], check=True, timeout=120)
        cls.worker = root / 'worker'
        spool_source = ROOT / 'Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/CodexToolFeedSpool.swift'
        if spool_source.exists():
            subprocess.run(['swiftc', str(spool_source), str(worker_source), '-o', str(cls.worker)],
                           check=True, timeout=120)


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

    def test_hundred_persistent_feeds_leave_room_for_an_interactive_client(self):
        admitted = int(subprocess.check_output([str(self.pool_probe)], timeout=15))
        self.assertEqual(admitted, 101, 'idle feed connections must not starve an interactive client')

    def test_consumer_wakes_on_publication_and_cleans_up_after_parent_exit(self):
        owner_source = """import os,subprocess,sys
subprocess.Popen([sys.argv[1],sys.argv[2],str(os.getpid())],stdin=subprocess.DEVNULL)
sys.stdin.read()
"""
        owner = subprocess.Popen([sys.executable, '-c', owner_source, str(self.worker), str(self.spool)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(owner.stderr.close)
        self.addCleanup(owner.stdout.close)
        def stop_owner():
            if owner.poll() is None:
                owner.stdin.close()
                owner.wait(timeout=10)
        self.addCleanup(stop_owner)
        def read_line():
            self.assertTrue(select.select([owner.stdout], [], [], 15)[0], 'consumer did not signal')
            return owner.stdout.readline()
        self.assertEqual(read_line(), b'ready\n')
        self.run_hook(self.command(), '{"tool_name":"Read"}')
        self.assertEqual(read_line(), b'{"tool_name":"Read"}\n')
        stop_owner()
        self.assertEqual(read_line(), b'', 'consumer must exit when its parent exits')
        self.assertFalse(self.spool.exists(), 'consumer must remove its private spool')

    def test_missing_spool_does_not_fall_back_to_process_storm(self):
        self.spool.rmdir()
        self.run_hook(self.command(), '{}')
        self.assertFalse(self.log.exists())


if __name__ == '__main__':
    unittest.main()
