// CmxClient — Swift client for cmx servers.
//
// The intended consumption path is the macOS cmux app: a new
// `CmxTerminalPanel` type sits alongside the existing `TerminalPanel`,
// talks the Unix socket at `$XDG_RUNTIME_DIR/cmux-cli/server.sock`
// directly (not via shelling out to `cmx attach`), and pumps bytes into a
// libghostty-vt instance loaded via Ghostty's XCFramework.
//
// This file only stubs the public surface. The encoder/decoder for the
// MessagePack wire types lives next to `CmxProtocol.swift`; the socket
// loop lives in `CmxSession.swift`; both are TODO.

import Foundation

public enum CmxAttachMode: String, Codable, Sendable {
    case ansi
    case grid
}

public struct CmxViewport: Codable, Sendable, Equatable {
    public var cols: UInt16
    public var rows: UInt16
    public init(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }
}

public struct CmxAttachOptions: Sendable {
    public var socketPath: String
    public var mode: CmxAttachMode
    public var viewport: CmxViewport
    public var token: String?

    public init(
        socketPath: String,
        mode: CmxAttachMode = .grid,
        viewport: CmxViewport,
        token: String? = nil
    ) {
        self.socketPath = socketPath
        self.mode = mode
        self.viewport = viewport
        self.token = token
    }
}

public enum CmxClientError: Error, Equatable, Sendable {
    case unimplemented(String)
}

/// Handle to an attached cmx session. Real implementation will own a
/// URLSession/NWConnection over AF_UNIX, a MessagePack encoder/decoder,
/// and the per-tab libghostty-vt instances.
public final class CmxSession: @unchecked Sendable {
    private let options: CmxAttachOptions

    public init(options: CmxAttachOptions) {
        self.options = options
    }

    deinit {}

    /// Connect, Hello, and start streaming frames.
    public func attach() async throws {
        throw CmxClientError.unimplemented(
            "CmxSession.attach() not implemented; see clients/swift/README.md for the wire contract"
        )
    }
}
