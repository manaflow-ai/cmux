import Foundation

/// Host-issued identities survive renames and window reindexing. Neither a
/// session name nor a user-entered command can be used as a control target.
public struct SSHTmuxWindow: Hashable, Sendable {
    public let sessionID: String
    public let windowID: String
    public let serverPID: UInt32
    public let serverStart: UInt64
    /// Host-issued active pane identity, when discovery reported it. Keeping
    /// this separate from the window identity lets control mode target one
    /// pane in a split window without selecting an unrelated pane by order.
    public let paneID: String?

    public init?(sessionID: String, windowID: String, serverPID: UInt32, serverStart: UInt64, paneID: String? = nil) {
        guard serverPID > 0, serverStart > 0, Self.isValidID(sessionID, prefix: "$"), Self.isValidID(windowID, prefix: "@"),
              paneID.map { Self.isValidID($0, prefix: "%") } ?? true else { return nil }
        self.sessionID = sessionID
        self.windowID = windowID
        self.serverPID = serverPID
        self.serverStart = serverStart
        self.paneID = paneID
    }

    /// Returns the same window epoch with a validated host-issued pane id.
    /// Pane ids are deliberately excluded from the public surface id: the
    /// workspace still represents one terminal per tmux window, while the
    /// active pane target is refreshed by discovery.
    public func targetingPane(_ paneID: String) -> SSHTmuxWindow? {
        Self.isValidID(paneID, prefix: "%")
            ? SSHTmuxWindow(sessionID: sessionID, windowID: windowID, serverPID: serverPID, serverStart: serverStart, paneID: paneID)
            : nil
    }

    static func validID(_ value: String, prefix: UInt8) -> Bool {
        let bytes = Array(value.utf8)
        return (2...21).contains(bytes.count) && bytes.first == prefix
            && bytes.dropFirst().allSatisfy { (48...57).contains($0) }
    }

    public static func isValidID(_ value: String, prefix: Character) -> Bool {
        guard let byte = prefix.asciiValue else { return false }
        return validID(value, prefix: byte)
    }
}
