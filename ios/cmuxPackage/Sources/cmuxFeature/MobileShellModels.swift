import CMUXMobileCore
import CmuxMobileAuth
import Foundation
import Observation
import OSLog

public struct MobileWorkspacePreview: Identifiable, Equatable, Sendable {
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    public var id: ID
    public var name: String
    public var terminals: [MobileTerminalPreview]

    public init(id: ID, name: String, terminals: [MobileTerminalPreview]) {
        self.id = id
        self.name = name
        self.terminals = terminals
    }
}

public struct MobileTerminalPreview: Identifiable, Equatable, Sendable {
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    public var id: ID
    public var name: String
    public var isReady: Bool
    public var isFocused: Bool
    public var viewportFit: MobileTerminalViewportFit?

    public init(
        id: ID,
        name: String,
        isReady: Bool = true,
        isFocused: Bool = false,
        viewportFit: MobileTerminalViewportFit? = nil
    ) {
        self.id = id
        self.name = name
        self.isReady = isReady
        self.isFocused = isFocused
        self.viewportFit = viewportFit
    }
}

public struct MobileTerminalViewportSize: Codable, Equatable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
}

public struct MobileTerminalViewportFit: Codable, Equatable, Sendable {
    public var effective: MobileTerminalViewportSize
    public var client: MobileTerminalViewportSize?
    public var isCurrentClientLimiting: Bool

    public init(
        effective: MobileTerminalViewportSize,
        client: MobileTerminalViewportSize?,
        isCurrentClientLimiting: Bool
    ) {
        self.effective = effective
        self.client = client
        self.isCurrentClientLimiting = isCurrentClientLimiting
    }

    public var shouldDrawVisibleAreaBorder: Bool {
        shouldDrawVisibleAreaRightBorder || shouldDrawVisibleAreaBottomBorder
    }

    public var shouldDrawVisibleAreaRightBorder: Bool {
        guard let client else { return false }
        return client.columns > effective.columns
    }

    public var shouldDrawVisibleAreaBottomBorder: Bool {
        guard let client else { return false }
        return client.rows > effective.rows
    }

    private enum CodingKeys: String, CodingKey {
        case effective
        case client
        case isCurrentClientLimiting = "is_current_client_limiting"
    }
}

enum MobileTerminalInputEnqueueResult: Equatable, Sendable {
    case startDraining
    case queued
    case rejected
}

struct MobileTerminalInputSendBuffer: Equatable, Sendable {
    static let maximumPendingByteCount = 64 * 1024

    struct Chunk: Equatable, Sendable {
        var workspaceID: MobileWorkspacePreview.ID
        var terminalID: MobileTerminalPreview.ID
        var text: String
    }

    private(set) var pendingChunks: [Chunk] = []
    private(set) var pendingByteCount = 0
    private(set) var isDraining = false

    mutating func enqueue(
        _ text: String,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) -> MobileTerminalInputEnqueueResult {
        guard !text.isEmpty else { return .queued }
        let byteCount = text.utf8.count
        guard pendingByteCount + byteCount <= Self.maximumPendingByteCount else {
            return .rejected
        }
        if var last = pendingChunks.last,
           last.workspaceID == workspaceID,
           last.terminalID == terminalID {
            last.text += text
            pendingChunks[pendingChunks.count - 1] = last
        } else {
            pendingChunks.append(
                Chunk(
                    workspaceID: workspaceID,
                    terminalID: terminalID,
                    text: text
                )
            )
        }
        pendingByteCount += byteCount
        guard !isDraining else { return .queued }
        isDraining = true
        return .startDraining
    }

    mutating func nextBatch() -> Chunk? {
        guard !pendingChunks.isEmpty else {
            isDraining = false
            return nil
        }
        let chunk = pendingChunks.removeFirst()
        pendingByteCount = max(0, pendingByteCount - chunk.text.utf8.count)
        return chunk
    }

    mutating func clear() {
        pendingChunks.removeAll()
        pendingByteCount = 0
        isDraining = false
    }
}

public enum MobileConnectionState: Equatable, Sendable {
    case disconnected
    case connected
}

public enum MobileMacConnectionStatus: Equatable, Sendable {
    case connected
    case reconnecting
    case unavailable
}

public enum MobilePairingURLConnectionResult: Equatable, Sendable {
    case connected
    case failed
    case superseded

    public var didConnect: Bool {
        self == .connected
    }
}

public enum MobileShellPhase: Equatable, Sendable {
    case signIn
    case pairing
    case workspaces
}
