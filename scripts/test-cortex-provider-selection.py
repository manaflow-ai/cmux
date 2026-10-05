#!/usr/bin/env python3
"""Typecheck actual provider mutations in Swift 6 and execute isolated round trips.

The native build first diagnosed the actor violation. This focused verifier
retains that compile diagnostic and checks synchronous mutation behavior after
it compiles; compilation failure is not described as a runtime behavioral red.
"""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation

enum CmuxSidebarProviderDescriptor {
    static let defaultWorkspacesID = "fixture.classic"
}
@MainActor final class Diagnostics {
    var transitions = 0
    func providerChanged(previous: String, current: String, source: String) {
        if previous != current { transitions += 1 }
    }
}
@MainActor final class TerminalController {
    static let shared = TerminalController()
    let sidebarRecoveryDiagnostics = Diagnostics()
}
enum ActualSelection {
__CONSTANTS__
__SET_PROVIDER__
__CORTEX_SELECTION__
}
@main struct Proof {
    @MainActor static func main() throws {
        let suite = "CortexSelectionProof." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = ActualSelection.self
        let identity = "fr.yoyaku.cortex.sessions"
        let enabled: Set<String> = [identity]
        selection.setProviderId(selection.defaultProviderId, defaults: defaults)
        let unavailable = selection.toggleCortexSidebar(enabledBundleIDs: [], extensionsEnabled: true, defaults: defaults)
        let disabled = selection.selectCortexSidebar(enabledBundleIDs: enabled, extensionsEnabled: false, defaults: defaults)
        let activated = selection.toggleCortexSidebar(enabledBundleIDs: enabled, extensionsEnabled: true, defaults: defaults)
        let activeImmediately = selection.isCortexActive(defaults: defaults)
        let classic = selection.toggleCortexSidebar(enabledBundleIDs: [], extensionsEnabled: false, defaults: defaults)
        let classicImmediately = defaults.string(forKey: selection.defaultsKey) == selection.defaultProviderId
        let retained = defaults.string(forKey: selection.selectedExtensionBundleIDDefaultsKey) == identity
        let explicit = selection.selectCortexSidebar(enabledBundleIDs: enabled, extensionsEnabled: true, defaults: defaults)
        let repeated = selection.selectCortexSidebar(enabledBundleIDs: enabled, extensionsEnabled: true, defaults: defaults)
        let result: [String: Any] = ["unavailable": unavailable, "disabled": disabled,
            "activated": activated, "activeImmediately": activeImmediately,
            "classic": classic, "classicImmediately": classicImmediately,
            "retained": retained, "explicit": explicit, "repeated": repeated,
            "transitions": TerminalController.shared.sidebarRecoveryDiagnostics.transitions]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }
}
'''


class CortexProviderSelectionTests(unittest.TestCase):
    def test_swift6_actor_contract_and_synchronous_provider_round_trip(self):
        source = (ROOT / "Sources/CmuxExtensionSidebarSelection.swift").read_text()
        constants = source[source.index('    static let defaultsKey = '):
            source.index('\n    /// Synchronous read of the experimental Extensions flag')]
        setter_start = source.index('    @MainActor\n    static func setProviderId(')
        setter = source[setter_start:source.index('    static func clearStaleTemplatePreviewSelection(', setter_start)]
        cortex_start = source.index('    static func isCortexBundle(')
        cortex = source[cortex_start:source.index('    @MainActor\n    static func showMenu(', cortex_start)]
        with tempfile.TemporaryDirectory(prefix='cortex-provider-selection-') as directory:
            scratch = Path(directory)
            harness = scratch / 'Proof.swift'
            harness.write_text(HARNESS.replace('__CONSTANTS__', constants)
                .replace('__SET_PROVIDER__', setter).replace('__CORTEX_SELECTION__', cortex))
            binary = scratch / 'selection'
            compile_result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6',
                str(harness), '-o', str(binary)], capture_output=True, text=True, timeout=120)
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = json.loads(subprocess.run([str(binary)], check=True,
                capture_output=True, text=True, timeout=10).stdout)
        self.assertFalse(result['unavailable'])
        self.assertFalse(result['disabled'])
        for key in ['activated', 'activeImmediately', 'classic', 'classicImmediately',
                    'retained', 'explicit', 'repeated']:
            self.assertTrue(result[key], key)
        self.assertEqual(result['transitions'], 4)


if __name__ == '__main__':
    unittest.main()
