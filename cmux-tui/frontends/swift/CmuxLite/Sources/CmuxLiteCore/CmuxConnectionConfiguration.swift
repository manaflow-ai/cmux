import Foundation

/// Describes one resolved cmux-tui transport endpoint and its optional WebSocket token.
public struct CmuxConnectionConfiguration: Sendable, Equatable {
    /// The default local WebSocket parity endpoint.
    public static let defaultURL = URL(string: "ws://127.0.0.1:7682")!

    /// The selected Unix socket or WebSocket endpoint.
    public let endpoint: CmuxConnectionEndpoint

    /// The token sent only for WebSocket authentication, when configured.
    public let token: String?

    /// Creates connection configuration from a resolved endpoint.
    /// - Parameters:
    ///   - endpoint: The selected transport and address.
    ///   - token: An optional WebSocket transport token. Unix endpoints discard this value.
    public init(endpoint: CmuxConnectionEndpoint, token: String? = nil) {
        self.endpoint = endpoint
        switch endpoint {
        case .unixSocket:
            self.token = nil
        case .webSocket:
            self.token = token
        }
    }

    /// Creates WebSocket connection configuration from explicit values.
    /// - Parameters:
    ///   - url: A `ws` or `wss` URL.
    ///   - token: An optional transport token.
    public init(url: URL, token: String? = nil) {
        self.init(endpoint: .webSocket(url: url), token: token)
    }

    /// Creates Unix socket connection configuration from an explicit path.
    /// - Parameter socketPath: The filesystem path of the cmux-tui socket.
    public init(socketPath: String) {
        self.init(endpoint: .unixSocket(path: socketPath))
    }

    /// Returns the server-compatible runtime directory for one environment and user id.
    /// - Parameters:
    ///   - environment: Environment variables used to resolve `TMPDIR`.
    ///   - userID: The decimal Unix user id component.
    /// - Returns: `$TMPDIR/cmux-tui-<uid>`, falling back to `/tmp`.
    public static func socketDirectory(
        environment: [String: String],
        userID: UInt32
    ) -> String {
        // Mirror the server's runtime-base precedence exactly
        // (platform.rs): XDG_RUNTIME_DIR, then TMPDIR, then /tmp.
        let temporaryDirectory = environment["XDG_RUNTIME_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/tmp"
        return URL(fileURLWithPath: temporaryDirectory, isDirectory: true)
            .appendingPathComponent("cmux-tui-\(userID)", isDirectory: true)
            .path
    }

    /// Returns the server-compatible socket path for a named session.
    /// - Parameters:
    ///   - session: The cmux-tui session name.
    ///   - environment: Environment variables used to resolve `TMPDIR`.
    ///   - userID: The decimal Unix user id component.
    /// - Returns: `$TMPDIR/cmux-tui-<uid>/<session>.sock`.
    public static func socketPath(
        session: String,
        environment: [String: String],
        userID: UInt32
    ) -> String {
        URL(
            fileURLWithPath: socketDirectory(environment: environment, userID: userID),
            isDirectory: true
        )
        .appendingPathComponent("\(session).sock", isDirectory: false)
        .path
    }

    /// Returns the WebSocket token fallback path for a home directory.
    /// - Parameter homeDirectory: The current user's home directory.
    /// - Returns: `~/.config/cmux-lite/token`.
    public static func tokenFile(homeDirectory: String) -> String {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".config/cmux-lite/token", isDirectory: false)
            .path
    }

    /// Parses endpoint and authentication command-line arguments.
    ///
    /// `--socket` and `--session` select Unix transport. `--url` selects
    /// WebSocket transport. With no selector, exactly one socket in the
    /// runtime directory is adopted; zero or multiple sockets require an
    /// explicit flag.
    ///
    /// - Parameters:
    ///   - arguments: Arguments after the executable name.
    ///   - environment: Environment variables used for runtime and token paths.
    ///   - userID: The decimal Unix user id component.
    ///   - readFile: An injected UTF-8 text-file reader.
    ///   - listDirectory: An injected directory listing that returns child paths.
    /// - Returns: A fully resolved connection configuration.
    /// - Throws: ``CmuxProtocolError`` when options or default resolution are ambiguous.
    public static func parse(
        arguments: [String],
        environment: [String: String],
        userID: UInt32,
        readFile: (String) throws -> String,
        listDirectory: (String) throws -> [String],
        isSocketLive: (String) -> Bool = CmuxConnectionConfiguration.socketIsLive
    ) throws -> CmuxConnectionConfiguration {
        var endpoint: CmuxConnectionEndpoint?
        var token: String?
        var tokenWasExplicit = false
        var index = 0

        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else {
                throw CmuxProtocolError.invalidArgument(
                    String(
                        format: String(
                            localized: "connection.argument.missing_value",
                            defaultValue: "Missing value for %@",
                            bundle: .module
                        ),
                        option
                    )
                )
            }
            let value = arguments[index + 1]

            switch option {
            case "--url":
                try requireUnselected(endpoint, newOption: option)
                guard let parsed = URL(string: value),
                      parsed.scheme == "ws" || parsed.scheme == "wss"
                else {
                    throw CmuxProtocolError.invalidArgument(
                        String(
                            format: String(
                                localized: "connection.argument.invalid_url",
                                defaultValue: "Invalid WebSocket URL: %@",
                                bundle: .module
                            ),
                            value
                        )
                    )
                }
                endpoint = .webSocket(url: parsed)
            case "--socket":
                try requireUnselected(endpoint, newOption: option)
                guard !value.isEmpty else {
                    throw CmuxProtocolError.invalidArgument(
                        String(
                            localized: "connection.argument.socket_empty",
                            defaultValue: "Socket path must not be empty",
                            bundle: .module
                        )
                    )
                }
                endpoint = .unixSocket(path: value)
            case "--session":
                try requireUnselected(endpoint, newOption: option)
                guard !value.isEmpty else {
                    throw CmuxProtocolError.invalidArgument(
                        String(
                            localized: "connection.argument.session_empty",
                            defaultValue: "Session name must not be empty",
                            bundle: .module
                        )
                    )
                }
                endpoint = .unixSocket(
                    path: socketPath(session: value, environment: environment, userID: userID)
                )
            case "--token":
                token = value
                tokenWasExplicit = true
            case "--token-file":
                token = try readFile(value).trimmingCharacters(in: .whitespacesAndNewlines)
                tokenWasExplicit = true
            default:
                throw CmuxProtocolError.invalidArgument(
                    String(
                        format: String(
                            localized: "connection.argument.unknown_option",
                            defaultValue: "Unknown option: %@",
                            bundle: .module
                        ),
                        option
                    )
                )
            }
            index += 2
        }

        let resolvedEndpoint = try endpoint ?? discoverSocket(
            environment: environment,
            userID: userID,
            listDirectory: listDirectory,
            isLive: isSocketLive
        )

        switch resolvedEndpoint {
        case .unixSocket:
            if tokenWasExplicit {
                throw CmuxProtocolError.invalidArgument(
                    String(
                        localized: "connection.argument.token_requires_url",
                        defaultValue: "--token and --token-file require --url",
                        bundle: .module
                    )
                )
            }
            return CmuxConnectionConfiguration(endpoint: resolvedEndpoint)
        case .webSocket:
            if token == nil, let home = environment["HOME"], !home.isEmpty,
               let fallback = try? readFile(tokenFile(homeDirectory: home))
            {
                let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { token = trimmed }
            }
            return CmuxConnectionConfiguration(endpoint: resolvedEndpoint, token: token)
        }
    }

    private static func requireUnselected(
        _ endpoint: CmuxConnectionEndpoint?,
        newOption: String
    ) throws {
        guard endpoint == nil else {
            throw CmuxProtocolError.invalidArgument(
                String(
                    format: String(
                        localized: "connection.argument.selector_conflict",
                        defaultValue: "%@ cannot be combined with another transport selector",
                        bundle: .module
                    ),
                    newOption
                )
            )
        }
    }

    /// Whether something is actually listening on a unix socket path.
    /// Crashed servers and test binaries leave stale *.sock files behind;
    /// discovery must ignore them or a single dead file blocks auto-connect.
    public static func socketIsLive(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, size)
            }
        }
        return result == 0
    }

    private static func discoverSocket(
        environment: [String: String],
        userID: UInt32,
        listDirectory: (String) throws -> [String],
        isLive: (String) -> Bool = CmuxConnectionConfiguration.socketIsLive
    ) throws -> CmuxConnectionEndpoint {
        let directory = socketDirectory(environment: environment, userID: userID)
        let sockets = (try? listDirectory(directory))?
            .filter { URL(fileURLWithPath: $0).pathExtension == "sock" }
            .sorted() ?? []
        let live = sockets.filter(isLive)

        if live.count == 1, let socket = live.first {
            return .unixSocket(path: socket)
        }

        let found = sockets.isEmpty
            ? String(
                localized: "connection.argument.no_sockets",
                defaultValue: "none",
                bundle: .module
            )
            : sockets.joined(separator: ", ")
        throw CmuxProtocolError.invalidArgument(
            String(
                format: String(
                    localized: "connection.argument.socket_discovery",
                    defaultValue: "Expected exactly one live *.sock in %1$@, found %2$lld live of %3$@; pass --socket <path>, --session <name>, or --url <ws://...>",
                    bundle: .module
                ),
                directory,
                Int64(live.count),
                found
            )
        )
    }
}
