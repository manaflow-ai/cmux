import Foundation

/// Reports transport, protocol-negotiation, and payload failures.
public enum CmuxProtocolError: Error, Sendable, CustomStringConvertible {
    /// A command-line connection option was invalid.
    case invalidArgument(String)

    /// The transport was used in an invalid state.
    case transportState(String)

    /// The server sent an unsupported transport message.
    case unsupportedMessage(String)

    /// The server rejected a command.
    case command(String)

    /// The server identity or protocol version is incompatible.
    case incompatibleServer(String)

    /// No attachable PTY surface exists in the selected tree.
    case noActivePTYSurface

    /// A protocol payload was missing or malformed.
    case malformedPayload(String)

    /// A bounded operation reached its deadline.
    case timedOut(String)

    /// A stable, diagnostic description of the failure.
    public var description: String {
        switch self {
        case let .invalidArgument(message): "invalid argument: \(message)"
        case let .transportState(message): "transport state: \(message)"
        case let .unsupportedMessage(message): "unsupported message: \(message)"
        case let .command(message): "command failed: \(message)"
        case let .incompatibleServer(message): message
        case .noActivePTYSurface: "no active PTY surface"
        case let .malformedPayload(message): "malformed payload: \(message)"
        case let .timedOut(message): "timed out: \(message)"
        }
    }
}
