#if DEBUG
import CmuxiOSTerminal
import Foundation
import UIKit

/// The DEV terminal: ghostty-next fed by the mock session host, until the
/// transport engine's iOS build plugs into `TerminalSessionSource`.
@MainActor
enum DevTerminal {
    /// Seconds before the mock host changes the grid
    /// (`CMUX_IOS_TERMINAL_GRID_CHANGE_SECONDS`, default 4).
    static var gridChangeSeconds: Int {
        ProcessInfo.processInfo.environment["CMUX_IOS_TERMINAL_GRID_CHANGE_SECONDS"].flatMap(Int.init) ?? 4
    }

    static func make() -> TerminalViewController {
        let source = MockTerminalSessionSource(gridChangeDelay: .seconds(gridChangeSeconds))
        return TerminalViewController(source: source, terminal: MockTerminalSessionSource.demo)
    }

    /// Writes the terminal's diagnostics next to the gallery (simulator
    /// checks): `terminal.json` once the first snapshot had time to arrive,
    /// `terminal-grid.json` after the grid change (debug capture only).
    static func captureDiagnostics(_ controller: TerminalViewController) {
        Task { @MainActor [weak controller] in
            // wakeup-allow: DEBUG simulator capture, two one-shot delays
            try? await Task.sleep(for: .seconds(3))
            if let controller { write(controller, to: "terminal.json") }
            // wakeup-allow: DEBUG simulator capture, second one-shot delay
            try? await Task.sleep(for: .seconds(gridChangeSeconds + 1))
            if let controller { write(controller, to: "terminal-grid.json") }
        }
    }

    private static func write(_ controller: TerminalViewController, to name: String) {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux-gallery/" + name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try? JSONSerialization.data(withJSONObject: controller.diagnostics, options: [.sortedKeys])
        try? data?.write(to: url)
    }
}
#endif
