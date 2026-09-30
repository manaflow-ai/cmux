#!/usr/bin/env python3
"""Run the production binding store with independent concurrent writers."""

import fcntl
import json
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which("swiftc"), "Swift compiler unavailable")
class VMRunBindingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[1]
        cls.temporary = tempfile.TemporaryDirectory(
            prefix="vm-binding-test-", dir=cls.root / ".local"
        )
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.binary = Path(cls.temporary.name) / "bindings"
        production = (cls.root / "CLI/CMUXCLI+VMTransfer.swift").read_text()
        # Compile the actual store bodies, without the app or CLI entrypoint.
        binding = production[production.index("    struct VMRunBinding: Codable"):
                             production.index("    /// The home the router")]
        methods = production[production.index("    static func loadVMRunBindings("):
                             production.index("    /// Machines this router provisioned")]
        source = Path(cls.temporary.name) / "main.swift"
        source.write_text("""import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
enum CMUXCLI {
    static func vmRunBindingsStoreURL() -> URL { fatalError("Explicit test URL required") }
""" + binding + methods + """
}
let args = CommandLine.arguments
FileHandle.standardOutput.write(Data("ready\\n".utf8))
CMUXCLI.saveVMRunBinding(workKey: args[2], machine: args[3], to: URL(fileURLWithPath: args[1]))
""")
        subprocess.run(["swiftc", "-swift-version", "6", str(source), "-o", str(cls.binary)],
                       check=True, capture_output=True, text=True, timeout=60)

    def test_concurrent_writers_preserve_both_bindings(self):
        store = Path(self.temporary.name) / "concurrent.json"
        lock = open(str(store) + ".lock", "a+")
        self.addCleanup(lock.close)
        fcntl.flock(lock, fcntl.LOCK_EX)
        writers = [subprocess.Popen([str(self.binary), str(store), key, machine],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                   for key, machine in [("work-a", "machine-a"), ("work-b", "machine-b")]]
        for writer in writers:
            self.addCleanup(lambda child=writer: child.kill() if child.poll() is None else None)
            self.assertEqual(writer.stdout.readline(), "ready\n")
        try:
            # Both writers must wait for the same transaction lock. EOF means
            # a writer completed while another owner still held the store.
            with selectors.DefaultSelector() as selector:
                for writer in writers:
                    selector.register(writer.stdout, selectors.EVENT_READ)
                self.assertEqual(selector.select(timeout=0.25), [],
                                 "Binding writers ignored the shared transaction lock")
            self.assertFalse(store.exists(), "A writer modified the locked store")
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)
            for writer in writers:
                _, stderr = writer.communicate(timeout=10)
                self.assertEqual(writer.returncode, 0, stderr)
        bindings = json.loads(store.read_text())
        self.assertEqual({key: value["machine"] for key, value in bindings.items()},
                         {"work-a": "machine-a", "work-b": "machine-b"})


if __name__ == "__main__":
    unittest.main()
