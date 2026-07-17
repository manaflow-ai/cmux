import Foundation

/// Represents either UTF-8 text or a terminal-mode-aware named key.
public enum CmuxTerminalKeyAction: Sendable, Equatable {
    /// Text sent through the protocol `send` command.
    case text(String)

    /// A chord sent through the protocol `send-key` command.
    case key(String)
}
