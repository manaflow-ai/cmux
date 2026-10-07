import Foundation

/// Host-issued identities survive renames and window reindexing. Neither a
/// session name nor a user-entered command can be used as a control target.
public struct SSHTmuxWindow: Hashable, Sendable {
    public let sessionID: String
    public let windowID: String
    public let serverPID: UInt32
    public let serverStart: UInt64

    public init?(sessionID: String, windowID: String, serverPID: UInt32, serverStart: UInt64) {
        guard serverPID > 0, serverStart > 0, Self.validID(sessionID, prefix: "$"), Self.validID(windowID, prefix: "@") else { return nil }
        self.sessionID = sessionID
        self.windowID = windowID
        self.serverPID = serverPID
        self.serverStart = serverStart
    }

    static func validID(_ value: String, prefix: UInt8) -> Bool {
        let bytes = Array(value.utf8)
        return (2...21).contains(bytes.count) && bytes.first == prefix
            && bytes.dropFirst().allSatisfy { (48...57).contains($0) }
    }

    static func validID(_ value: String, prefix: Character) -> Bool {
        guard let byte = prefix.asciiValue else { return false }
        return validID(value, prefix: byte)
    }
}
