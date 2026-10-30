#!/usr/bin/env python3
"""arch-layers.py reads the same targets from `swift package dump-package` as arch_counts.py's static reader
(MAPPED_KINDS: regular, executable and binary targets), so its report shows every target and edge the ratchet
and the pre-push layer gate judge. Each case writes a dump and a layer map to a temp dir and runs the script.

  python3 scripts/cmux-next/tests/test_arch_layers.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Sequence
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "arch-layers.py"

# Two wrapper observers and a call whose `named:` is on the next line: both NotificationCenter observers.
OBSERVERS = """import Foundation
final class Watcher {
    var tokens: [MainActorObservation] = []
    func watch() async {
        tokens.append(MainActorObservation(.paneMoved) { })
        tokens.append(MainActorObservation(NSWindow.didBecomeKeyNotification, object: nil) { })
        let changes = NotificationCenter.default.notifications(
            named: .paneMoved
        )
        // NotificationCenter.default.addObserver(forName: .paneMoved, object: nil, queue: nil) { _ in }
        for await _ in changes { }
    }
}
"""

# The wrapper (CmuxNextCompat's shape): a use of it counts by what its init does; its own body does not.
WRAPPER = """import Foundation
public final class MainActorObservation {
    private let token: any NSObjectProtocol
    public init(_ name: Notification.Name, object: AnyObject? = nil, center: NotificationCenter = .default,
                _ handler: @escaping @MainActor () -> Void) {
        token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
"""


def load_script():
    spec = importlib.util.spec_from_file_location("cmux_next_arch_layers_for_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module

LAYERS = {
    "order": ["core", "service", "domain", "ui", "app"],
    "targets": {
        "ArchLayersTestCore": {"layer": "core"},
        "ArchLayersTestFFI": {"layer": "core"},
        "ArchLayersTestHelper": {"layer": "service"},
        "ArchLayersTestApp": {"layer": "app"},
    },
}


def target(name: str, kind: str, deps: Sequence[str] = ()) -> dict:
    return {"name": name, "type": kind, "dependencies": [{"byName": [dep, None]} for dep in deps]}


class ArchLayersTests(unittest.TestCase):
    def report(self, targets: list[dict]) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            dump = Path(tmp) / "dump.json"
            layers = Path(tmp) / "layers.json"
            dump.write_text(json.dumps({"targets": targets}))
            layers.write_text(json.dumps(LAYERS))
            out = subprocess.run([sys.executable, str(SCRIPT), "--dump", str(dump), "--layers", str(layers),
                                  "--json"], capture_output=True, text=True, check=True).stdout
        return json.loads(out)

    def test_unmapped_executable_target_is_unplaced(self):
        report = self.report([
            target("ArchLayersTestCore", "regular"),
            target("ArchLayersTestNewTool", "executable", ["ArchLayersTestCore"]),
            target("ArchLayersTestCoreTests", "test", ["ArchLayersTestCore"]),
        ])
        self.assertEqual(report["unplaced"], ["ArchLayersTestNewTool"])

    def test_edge_from_executable_target_is_classified(self):
        report = self.report([
            target("ArchLayersTestApp", "regular"),
            target("ArchLayersTestHelper", "executable", ["ArchLayersTestApp"]),
        ])
        self.assertEqual((report["hard_violations"], report["unplaced"]), (1, []))

    def test_regular_executable_and_binary_targets_are_counted_and_test_targets_are_not(self):
        report = self.report([
            target("ArchLayersTestCore", "regular", ["ArchLayersTestFFI"]),
            target("ArchLayersTestFFI", "binary"),
            target("ArchLayersTestHelper", "executable", ["ArchLayersTestCore"]),
            target("ArchLayersTestHelperTests", "test", ["ArchLayersTestHelper", "ArchLayersTestApp"]),
        ])
        self.assertEqual(report["targets"], 3)
        self.assertEqual(report["layers"]["service"]["targets"], 1)
        self.assertEqual(report["hard_violations"], 0)


    def test_counts_observers_are_the_arch_ratchets_observer_sites(self):
        # `--counts` nc_observers is arch_counts' observer_sites (the ratchet's row), not a third regex: each use of
        # the wrapper counts (its own body does not), a multi-line call counts, a commented-out one does not.
        script = load_script()
        with tempfile.TemporaryDirectory() as tmp:
            sources = Path(tmp)
            (sources / "CmuxNextKit").mkdir()
            (sources / "CmuxNextKit" / "Watcher.swift").write_text(OBSERVERS)
            (sources / "CmuxNextCompat").mkdir()
            (sources / "CmuxNextCompat" / "MainActorObservation.swift").write_text(WRAPPER)
            script.SOURCES = sources
            self.assertEqual(script.grep_counts()["nc_observers"], 3)

    def test_the_local_package_closure_is_in_the_report(self):
        # The arch ratchet counts CmuxNext and its local package closure (arch_counts method v5): this report reads
        # the same scope, so a Shared target is placed, its `.product` edge is classified and its observers count.
        manifest = ('import PackageDescription\nlet package = Package(name: "{}", products: [{}], '
                    'dependencies: [{}], targets: [{}])\n')
        files = {
            "Packages/macOS/CmuxNext/Package.swift": manifest.format(
                "CmuxNext", "", '.package(path: "../../Shared/Kit")',
                '.target(name: "ArchLayersTestCore", dependencies: [.product(name: "Kit", package: "Kit")])'),
            "Packages/Shared/Kit/Package.swift": manifest.format(
                "Kit", '.library(name: "Kit", targets: ["ArchLayersTestKit"])', "",
                '.target(name: "ArchLayersTestKit")'),
            "Packages/Shared/Kit/Sources/ArchLayersTestKit/Watcher.swift": OBSERVERS,
        }
        layers = {**LAYERS, "targets": {**LAYERS["targets"], "ArchLayersTestKit": {"layer": "service"}}}
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            for rel, text in files.items():
                (repo / rel).parent.mkdir(parents=True, exist_ok=True)
                (repo / rel).write_text(text)
            env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "HOME": tmp,
                   "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t",
                   "GIT_COMMITTER_EMAIL": "t@example.com"}
            for args in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "fixture"]):
                subprocess.run(["git", "-C", str(repo), *args], env=env, check=True, capture_output=True)
            dump = Path(tmp) / "dump.json"
            dump.write_text(json.dumps({"targets": [target("ArchLayersTestCore", "regular")]}))
            map_path = Path(tmp) / "layers.json"
            map_path.write_text(json.dumps(layers))
            out = subprocess.run([sys.executable, str(SCRIPT), "--dump", str(dump), "--repo", str(repo), "--layers",
                                  str(map_path), "--json", "--counts"], capture_output=True, text=True, check=True,
                                 env=env).stdout
        report = json.loads(out)
        self.assertEqual((report["targets"], report["unplaced"]), (2, []))
        self.assertEqual(report["upward_violations"], 1, "core -> service through the product")
        self.assertEqual(report["layers"]["service"]["targets"], 1)
        self.assertEqual(report["counts"]["nc_observers"], 1, "the Shared package's raw registration is counted")


if __name__ == "__main__":
    unittest.main()
