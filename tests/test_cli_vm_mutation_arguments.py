#!/usr/bin/env python3
"""Run the VM mutation argument paths up to their first RPC with a recording client.

When CMUX_CLI_BIN is set, run the built CLI against an isolated socket. Otherwise
the fixture compiles the production switch prefixes and option parsers, avoiding
the app/terminal dependencies needed by the full CLI. It checks both rejected
arguments and the requests produced by valid forms; it never contacts a VM.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_cli_vm_resize import ResizeSocket


ROOT = Path(__file__).resolve().parents[1]


def member(source: str, signature: str) -> str:
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


def fixture_source() -> str:
    source = (ROOT / "CLI/cmux.swift").read_text()
    cases = []
    for label in ('"snapshot", "checkpoint"', '"fork"', '"restore"', '"promote-template"'):
        start = source.index(f'            case {label}:')
        end = source.index("let response = try client.sendV2", start)
        end = source.index("\n", end)
        # Stop after the real send call: rendering/opening its result is outside
        # argument admission. The client records the request instead of sending.
        prefix = source[start:end].replace("let response = try client.sendV2", "_ = try client.sendV2")
        cases.append(prefix)
    helpers = [member(source, signature) for signature in (
        "    func parseOption(", "    func hasFlag(",
        "    func parseOpenFocusFlags(", "    static func openFocusFlag(",
        "    private static func normalizedVMProvider(",
    )]
    routing = (ROOT / "Sources/Surfaces/CmuxTuiRemoteRouting.swift").read_text()
    return r'''
import Foundation

enum CmuxTuiRemoteRouting {
''' + member(routing, "    static func focusFlagValue(") + r'''
}
final class SocketClient {
    var requests: [[String: Any]] = []
    func sendV2(method: String, params: [String: Any], responseTimeout: Double) throws -> [String: Any] {
        requests.append(["method": method, "params": params])
        return [:]
    }
}
struct Fixture {
    static let vmCreateResponseTimeoutSeconds = 300.0
    func validatedWindowHandle(_ window: String?, client: SocketClient) throws -> String? { window }
    func runVMSnapshotListCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {}
    func runVMSnapshotDeleteCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {}
''' + "\n".join(helpers) + r'''
    func run(_ sub: String, rest: [String], client: SocketClient) throws {
        let windowId: String? = nil
        let jsonOutput = true
        switch sub {
''' + "\n".join(cases) + r'''
        default: throw CLIError(message: "unknown fixture verb")
        }
    }
}
let args = Array(CommandLine.arguments.dropFirst())
let client = SocketClient()
var outcome: [String: Any] = [:]
do {
    try Fixture().run(args[0], rest: Array(args.dropFirst()), client: client)
} catch {
    outcome["error"] = String(describing: error)
}
outcome["requests"] = client.requests
let data = try JSONSerialization.data(withJSONObject: outcome, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
'''


class VMMutationArgumentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.cli = os.environ.get("CMUX_CLI_BIN")
        if cls.cli:
            if not os.access(cls.cli, os.X_OK):
                raise RuntimeError("CMUX_CLI_BIN must name an executable CLI")
            return
        cls.scratch = tempfile.TemporaryDirectory(prefix="vm-mutation-fixture-", dir=ROOT)
        cls.addClassCleanup(cls.scratch.cleanup)
        main = Path(cls.scratch.name, "main.swift")
        main.write_text(fixture_source())
        cls.binary = Path(cls.scratch.name, "fixture")
        compiled = subprocess.run([
            "swiftc", "-swift-version", "6", str(ROOT / "CLI/CLIError.swift"),
            str(main), "-o", str(cls.binary),
        ], capture_output=True, text=True, timeout=120)
        if compiled.returncode:
            raise RuntimeError(compiled.stderr)

    def run_command(self, verb: str, *arguments: str) -> dict:
        if self.cli:
            environment = {key: value for key, value in os.environ.items() if not key.startswith("CMUX")}
            environment.update({"CMUX_CLI_SENTRY_DISABLED": "1", "AppleLanguages": "(en)"})
            with ResizeSocket({"id": "result-vm", "snapshot_id": "result-snapshot"}) as server:
                result = subprocess.run(
                    [self.cli, "--socket", server.path, "--json", "vm", verb, *arguments],
                    env=environment, stdin=subprocess.DEVNULL,
                    capture_output=True, text=True, timeout=10,
                )
                outcome = {"requests": server.requests}
                if result.returncode:
                    outcome["error"] = result.stderr
                return outcome
        result = subprocess.run([str(self.binary), verb, *arguments], check=True,
                                capture_output=True, text=True, timeout=10)
        return json.loads(result.stdout)

    def test_invalid_arguments_do_not_send_a_mutating_request(self) -> None:
        for verb in ("snapshot", "checkpoint", "fork", "restore", "promote-template"):
            for arguments in ([], ["vm-1", "extra"], ["vm-1", "--typo"], ["--typo"]):
                with self.subTest(verb=verb, arguments=arguments):
                    outcome = self.run_command(verb, *arguments)
                    self.assertIn("error", outcome)
                    self.assertEqual(outcome["requests"], [])

    def test_valid_arguments_keep_the_documented_request(self) -> None:
        cases = (
            ("snapshot", ["vm-1", "--name", "Daily snapshot"], "vm.snapshot", "id", "vm-1"),
            ("checkpoint", ["vm-1", "--name=Daily snapshot"], "vm.snapshot", "id", "vm-1"),
            ("fork", ["vm-1", "--name", "Daily fork", "--detach", "--no-focus"], "vm.fork", "id", "vm-1"),
            ("restore", ["snap-1", "--provider", "freestyle", "-d", "--focus=false"], "vm.restore", "snapshot_id", "snap-1"),
            ("promote-template", ["vm-1"], "vm.snapshot", "id", "vm-1"),
        )
        for verb, arguments, method, key, identifier in cases:
            with self.subTest(verb=verb):
                outcome = self.run_command(verb, *arguments)
                self.assertNotIn("error", outcome)
                self.assertEqual(len(outcome["requests"]), 1)
                request = outcome["requests"][0]
                self.assertEqual(request["method"], method)
                self.assertEqual(request["params"][key], identifier)
                if verb in ("snapshot", "checkpoint", "fork", "promote-template"):
                    self.assertTrue(request["params"]["name"])
                if verb == "restore":
                    self.assertEqual(request["params"]["provider"], "freestyle")


if __name__ == "__main__":
    unittest.main(verbosity=2)
