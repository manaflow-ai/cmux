#!/usr/bin/env python3
"""scripts/cmux-next/arch-layers.py: every edge to a higher layer counts, and a core label must hold.

72673e48762 (B2) labeled CmuxNextDesignTokens "core" although it holds TunableStore (a shared
instance behind a lock that a file writer persists), RecoveryDraftStore (FileManager), LowPowerMode
(a NotificationCenter observation) and BackdropRevision (@Observable state). The report then dropped
CmuxNextWorkspaceNaming -> Design from its hard violations without the edge changing, and it never
reported a core target that depends on a service or domain target at all. Each test builds a small
package tree and a dump-package JSON, and reads the report.

Not on CI (Lawrence 2026-10-23: no new CI tests; arch-layers.py is a report, not a gate): run
python3 tests/test_cmux_next_arch_layers.py after changing arch-layers.py or architecture-layers.json.
"""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1]


def load():
    spec = importlib.util.spec_from_file_location("cmux_next_arch_layers", SOURCE / "scripts/cmux-next/arch-layers.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ArchLayersTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-arch-layers-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.module = load()
        self.module.ROOT = self.root
        self.module.PACKAGE = self.root / "Packages/macOS/CmuxNext"
        self.module.SOURCES = self.module.PACKAGE / "Sources"
        self.module.LAYERS = self.root / "plans/cmux-next/architecture-layers.json"

    def package(self, layers, deps, files):
        """LAYERS {target: layer}, DEPS {target: [targets]}, FILES {target/relative.swift: text}."""
        self.module.LAYERS.parent.mkdir(parents=True, exist_ok=True)
        self.module.LAYERS.write_text(json.dumps({
            "order": ["core", "service", "domain", "ui", "app"],
            "targets": {name: {"layer": layer} for name, layer in layers.items()},
        }))
        for relative, text in files.items():
            path = self.module.SOURCES / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        for name in layers:
            (self.module.SOURCES / name).mkdir(parents=True, exist_ok=True)
        dump = self.root / "dump.json"
        dump.write_text(json.dumps({"targets": [
            {"name": name, "type": "regular", "dependencies": [{"byName": [d, None]} for d in deps.get(name, [])]}
            for name in layers]}))
        return dump

    def report(self, dump, *flags):
        out = io.StringIO()
        saved = sys.argv
        sys.argv = ["arch-layers.py", "--dump", str(dump), *flags]
        try:
            with contextlib.redirect_stdout(out):
                self.assertEqual(self.module.main(), 0)
        finally:
            sys.argv = saved
        return out.getvalue()

    def test_a_core_target_that_depends_on_a_service_or_domain_target_is_an_upward_violation(self):
        dump = self.package(
            {"Naming": "core", "Daemon": "service", "Bridge": "domain", "Kit": "ui", "Values": "core"},
            {"Naming": ["Daemon", "Bridge", "Values"], "Daemon": ["Values"], "Bridge": ["Daemon"]},
            {"Naming/Naming.swift": "public struct Naming {}\n"})
        # arch_counts.edge_class (shared with the arch ratchet and the pre-push layer gate) calls these
        # `upward`: reported and counted, apart from the edges into ui/app.
        report = json.loads(self.report(dump, "--json"))
        self.assertEqual(report["upward_violations"], 2)
        self.assertEqual(report["hard_violations"], 0)
        self.assertEqual(report["soft_violations"], 0)
        text = self.report(dump)
        self.assertIn("Naming (core) -> Daemon (service)", text)
        self.assertIn("Naming (core) -> Bridge (domain)", text)

    def test_service_to_domain_stays_soft_and_downward_edges_are_clean(self):
        dump = self.package(
            {"Values": "core", "Daemon": "service", "Settings": "domain", "Kit": "ui", "App": "app"},
            {"Daemon": ["Settings", "Values"], "Settings": ["Values"], "Kit": ["Settings"], "App": ["Kit", "Daemon"]},
            {})
        report = json.loads(self.report(dump, "--json"))
        self.assertEqual((report["hard_violations"], report["soft_violations"]), (0, 1))

    def test_a_core_target_that_holds_state_or_io_is_reported_with_its_evidence(self):
        dump = self.package(
            {"Tokens": "core", "Pure": "core", "Store": "service"},
            {},
            {
                "Tokens/TunableStore.swift": "import Foundation\npublic final class TunableStore {\n"
                                             "    public static let shared = TunableStore()\n"
                                             "    private let state = OSAllocatedUnfairLock(initialState: 0)\n}\n",
                "Tokens/DraftStore.swift": "import Foundation\nstruct DraftStore {\n"
                                           "    func save() { FileManager.default.createFile(atPath: \"/x\", contents: nil) }\n}\n",
                "Tokens/Revision.swift": "import Observation\n@Observable final class Revision {\n    var value = 0\n}\n",
                "Tokens/LowPower.swift": "import Foundation\nstruct LowPower {\n"
                                         "    // NotificationCenter in a comment is no evidence.\n"
                                         "    static let name = \"NotificationCenter\"\n"
                                         "    func watch() { _ = NotificationCenter.default }\n}\n",
                "Pure/Values.swift": "import Foundation\npublic struct Values: Sendable {\n"
                                     "    public static let standard = Values()\n    public static var all: [Values] { [standard] }\n}\n",
                "Store/Store.swift": "import Foundation\npublic actor Store {\n    static let shared = Store()\n}\n",
            })
        report = json.loads(self.report(dump, "--json"))
        self.assertEqual(sorted(report["impure_core"]), ["Tokens"])
        self.assertEqual(report["impure_core"]["Tokens"], {
            "shared instance": "TunableStore.swift:3",
            "lock": "TunableStore.swift:4",
            "file or defaults I/O": "DraftStore.swift:3",
            "observable state": "Revision.swift:2",
            "notification observation": "LowPower.swift:5",
        })
        self.assertIn("core targets that hold state or I/O", self.report(dump))


if __name__ == "__main__":
    unittest.main()
