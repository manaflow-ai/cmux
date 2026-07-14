import Foundation

/// Summarizes the selected workspace tree and byte attachment.
public struct CmuxFrontendStartup: Sendable, Equatable {
    /// Workspace names in server order.
    public let workspaceNames: [String]

    /// The attached PTY surface identifier.
    public let surface: UInt64

    /// The negotiated server protocol version.
    public let protocolVersion: UInt32

    /// Creates a startup summary.
    /// - Parameters:
    ///   - workspaceNames: Workspace names in server order.
    ///   - surface: The selected PTY surface.
    ///   - protocolVersion: The identified server protocol.
    public init(workspaceNames: [String], surface: UInt64, protocolVersion: UInt32) {
        self.workspaceNames = workspaceNames
        self.surface = surface
        self.protocolVersion = protocolVersion
    }
}
