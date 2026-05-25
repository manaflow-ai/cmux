import Foundation

/// A handle to a cmux entity (window, workspace, pane, surface, notification).
///
/// cmux exposes UUIDs and short refs (`workspace:2`, `surface:7`) and indexes
/// interchangeably in most contexts. This type preserves the literal handle
/// the server returned so we can round-trip it on subsequent commands without
/// re-resolving — that resolution is the macOS-side cmux CLI's job.
public struct CmuxHandle: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public var description: String { raw }
}

public typealias WindowID = CmuxHandle
public typealias WorkspaceID = CmuxHandle
public typealias PaneID = CmuxHandle
public typealias SurfaceID = CmuxHandle
public typealias NotificationID = CmuxHandle

extension CmuxHandle: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.raw = value
    }
}
