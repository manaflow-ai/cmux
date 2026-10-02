#if DEBUG
import CmuxiOSTerminal
import UIKit

/// The DEV terminal: ghostty-next fed by the mock session host, until the
/// transport engine's iOS build plugs into `TerminalSessionSource`.
@MainActor
enum DevTerminal {
    /// Writes the terminal's diagnostics next to the gallery (simulator checks).
    static func writeDiagnostics(_ controller: TerminalViewController) {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux-gallery/terminal.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try? JSONSerialization.data(withJSONObject: controller.diagnostics, options: [.sortedKeys])
        try? data?.write(to: url)
    }

    static func make() -> TerminalViewController {
        TerminalViewController(source: MockTerminalSessionSource(), terminal: MockTerminalSessionSource.demo)
    }
}
#endif
