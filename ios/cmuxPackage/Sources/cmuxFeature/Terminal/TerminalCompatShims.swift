import Foundation

/// Minimal stubs covering the small surface area of the prior daemon
/// integration that the ported `GhosttySurfaceView` still references.
/// These names will be replaced as the renderer is integrated with the
/// MobileShellStore byte-stream pipeline; for now they exist to keep
/// the verbatim port compiling.

/// Grid size in cells + pixel dimensions, as the prior daemon reported.
struct TerminalGridSize: Equatable, Hashable, Sendable {
    var columns: Int
    var rows: Int
    var pixelWidth: Int
    var pixelHeight: Int
}

/// Remote-platform tag the prior daemon used to switch keyboard/IME
/// dialects. We default to macOS for paired-Mac sessions.
enum RemotePlatform: String, Sendable, Equatable {
    case macOS
    case linux
    case unknown

    /// Compatibility alias used by the ported renderer for choosing
    /// keyboard layouts. The cmux iOS app is always talking to a Mac
    /// surface so `goOS == "darwin"` is the only branch that matters.
    var goOS: String {
        switch self {
        case .macOS: return "darwin"
        case .linux: return "linux"
        case .unknown: return "unknown"
        }
    }
}

/// Debug-only no-op shim for the prior worktree's anchormux logging.
/// Keeps the verbatim port compiling without dragging in the
/// anchormux SDK.
@inline(__always)
func liveAnchormuxLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    // NSLog avoids pulling in cmuxDebugLog from the macOS target.
    NSLog("cmux.terminal.anchormux %@", message())
    #endif
}

/// Logging stub. The prior worktree had a singleton sidebar store that
/// also routed debug strings into the cmux debug log. Here we forward
/// to OSLog and the cmuxDebugLog file path used by other mobile
/// components.
enum TerminalSidebarStore {
    static func debugLog(_ message: String) {
        #if DEBUG
        // Avoid pulling cmuxDebugLog (which lives in the macOS target)
        // into the iOS package. NSLog is sufficient for early bring-up.
        NSLog("cmux.terminal %@", message)
        #endif
    }
}
