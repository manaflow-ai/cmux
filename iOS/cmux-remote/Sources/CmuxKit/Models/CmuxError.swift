public import Foundation

public enum CmuxError: Error, Sendable {
    /// SSH layer failed (connection, auth, channel).
    case transport(String, underlying: (any Error)?)
    /// The CLI exited non-zero or the v1/v2 socket returned a recognisable error.
    case command(exitCode: Int32, stderr: String)
    /// Authentication failed on the cmux socket itself (e.g. bad keychain password).
    case unauthenticated(String)
    /// The remote cmux is too old to support a method this client uses.
    case unsupportedCapability(String)
    /// JSON decoding / parsing failed.
    case decoding(String, underlying: (any Error)?)
    /// Event stream went stale and the cursor predates the in-memory replay.
    case resumeGap(oldestSeq: Int?, latestSeq: Int?)
    /// The caller cancelled an in-flight operation.
    case cancelled
}

extension CmuxError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transport(let message, _):
            return String(
                format: String(localized: "error.transport", defaultValue: "Connection failed: %@"),
                locale: Locale.current,
                message
            )
        case .command(let exitCode, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? String(
                    format: String(
                        localized: "error.command_no_stderr",
                        defaultValue: "cmux command failed (exit %d)"
                    ),
                    locale: Locale.current,
                    exitCode
                )
                : String(
                    format: String(
                        localized: "error.command_with_stderr",
                        defaultValue: "cmux command failed (exit %d): %@"
                    ),
                    locale: Locale.current,
                    exitCode,
                    trimmed
                )
        case .unauthenticated(let message):
            return String(
                format: String(localized: "error.unauthenticated", defaultValue: "Not authenticated to cmux: %@"),
                locale: Locale.current,
                message
            )
        case .unsupportedCapability(let method):
            return String(
                format: String(localized: "error.unsupported_capability", defaultValue: "Server is too old to support %@"),
                locale: Locale.current,
                method
            )
        case .decoding(let message, _):
            return String(
                format: String(localized: "error.decoding", defaultValue: "Could not decode cmux response: %@"),
                locale: Locale.current,
                message
            )
        case .resumeGap(let oldest, let latest):
            return String(
                format: String(
                    localized: "error.resume_gap",
                    defaultValue: "Event stream resume gap (oldest=%@, latest=%@); refreshing state."
                ),
                locale: Locale.current,
                oldest.map(String.init) ?? "?",
                latest.map(String.init) ?? "?"
            )
        case .cancelled:
            return String(localized: "error.cancelled", defaultValue: "Cancelled")
        }
    }
}
