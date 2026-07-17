import AppKit
import Foundation

/// Verification hook: when CMUX_LITE_STATE_DUMP names a file, SIGUSR1 writes
/// one JSON line per render model (surface, grid, cursor, viewport text) so
/// external harnesses can compare the drawn model against server truth. Inert unless
/// the environment variable is set.
@MainActor
enum CmuxStateDump {
    private static let hosts = NSHashTable<CmuxTerminalHostViewController>.weakObjects()
    private static var signalSource: DispatchSourceSignal?

    static func register(_ host: CmuxTerminalHostViewController) {
        hosts.add(host)
    }

    static func installIfConfigured() {
        guard signalSource == nil,
              let path = ProcessInfo.processInfo.environment["CMUX_LITE_STATE_DUMP"],
              !path.isEmpty
        else { return }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { dump(to: path) }
        }
        source.resume()
        signalSource = source
    }

    private static func dump(to path: String) {
        var lines: [String] = []
        for host in hosts.allObjects {
            guard let state = host.verificationState() else { continue }
            if let data = try? JSONSerialization.data(withJSONObject: state),
               let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
    }
}
