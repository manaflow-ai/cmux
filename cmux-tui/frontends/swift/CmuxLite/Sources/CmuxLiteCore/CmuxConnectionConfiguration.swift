import Foundation

/// Describes the WebSocket endpoint and optional transport token for one cmux-tui connection.
public struct CmuxConnectionConfiguration: Sendable, Equatable {
    /// The default local cmux-tui WebSocket endpoint.
    public static let defaultURL = URL(string: "ws://127.0.0.1:7682")!

    /// The WebSocket URL.
    public let url: URL

    /// The token sent in the WebSocket authentication preamble, when configured.
    public let token: String?

    /// Creates connection configuration from explicit values.
    /// - Parameters:
    ///   - url: A `ws` or `wss` URL.
    ///   - token: An optional transport token.
    public init(url: URL = Self.defaultURL, token: String? = nil) {
        self.url = url
        self.token = token
    }

    /// The config file consulted for the token when no token argument is
    /// given, so a Finder-launched app (which receives no arguments) can
    /// still authenticate: `~/.config/cmux-lite/token`.
    public static var defaultTokenFile: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/cmux-lite/token")
    }

    /// Parses `--url`, `--token`, and `--token-file` command-line arguments.
    /// Without a token argument, falls back to ``defaultTokenFile`` when that
    /// file exists.
    /// - Parameters:
    ///   - arguments: Arguments after the executable name.
    ///   - readFile: An injected UTF-8 text-file reader.
    /// - Returns: Parsed connection configuration.
    /// - Throws: ``CmuxProtocolError`` when an option is malformed.
    public static func parse(
        arguments: [String],
        readFile: (String) throws -> String
    ) throws -> CmuxConnectionConfiguration {
        var url = defaultURL
        var token: String?
        var index = 0

        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else {
                throw CmuxProtocolError.invalidArgument("missing value for \(option)")
            }
            let value = arguments[index + 1]

            switch option {
            case "--url":
                guard let parsed = URL(string: value),
                      parsed.scheme == "ws" || parsed.scheme == "wss"
                else {
                    throw CmuxProtocolError.invalidArgument("invalid WebSocket URL: \(value)")
                }
                url = parsed
            case "--token":
                token = value
            case "--token-file":
                token = try readFile(value)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                throw CmuxProtocolError.invalidArgument("unknown option: \(option)")
            }
            index += 2
        }

        if token == nil, let fallback = try? readFile(defaultTokenFile) {
            let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { token = trimmed }
        }

        return CmuxConnectionConfiguration(url: url, token: token)
    }
}
