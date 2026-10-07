public import CmuxiOSFeatureKit
import Foundation

/// C4's `TerminalPathPaster` over the open workspace terminals: the path is
/// typed, shell-quoted and followed by a space, into the named terminal (or
/// the newest open one of that Mac), never run.
public struct LinkTerminalPathPaster: TerminalPathPaster {
    private let terminals: OpenLinkTerminals

    public init(terminals: OpenLinkTerminals) {
        self.terminals = terminals
    }

    public func paste(path: String, terminal: String?, host: HostID) async {
        guard let source = await terminals.source(host: host, terminal: terminal) else { return }
        try? await source.send(Data((Self.shellQuoted(path) + " ").utf8))
    }

    /// Single-quoted for POSIX shells; a quote inside becomes `'\''`.
    public static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+:@%~"))
        if !path.isEmpty, path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
