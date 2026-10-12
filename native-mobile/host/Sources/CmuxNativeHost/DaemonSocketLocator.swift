import Foundation

/// Finds the cmux-tui daemon socket.
///
/// Order: an explicit path; `$CMUX_TUI_SOCKET`; for a named session,
/// `<root>/cmux-tui-<uid>/<session>.sock` where root is the first non-empty of
/// `$XDG_RUNTIME_DIR`, `$TMPDIR`, `/tmp`, then `/tmp/cmux-tui-<uid>/<session>.sock`;
/// with no session, the most recently modified `*.sock` in those directories.
public struct DaemonSocketLocator: Sendable {
    public var explicitPath: String?
    public var session: String?
    public var environment: [String: String]
    public var uid: uid_t

    public init(explicitPath: String? = nil, session: String? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment, uid: uid_t = getuid()) {
        self.explicitPath = explicitPath
        self.session = session
        self.environment = environment
        self.uid = uid
    }

    public var runtimeRoot: String {
        for key in ["XDG_RUNTIME_DIR", "TMPDIR"] {
            if let value = environment[key], !value.isEmpty { return value }
        }
        return "/tmp"
    }

    /// Directories that may hold session sockets, in priority order.
    public var socketDirectories: [String] {
        var dirs = [(runtimeRoot as NSString).appendingPathComponent("cmux-tui-\(uid)")]
        let fallback = "/tmp/cmux-tui-\(uid)"
        if !dirs.contains(where: { Self.samePath($0, fallback) }) { dirs.append(fallback) }
        return dirs
    }

    /// Candidate paths for `session`, in priority order.
    public func candidates(session: String) -> [String] {
        socketDirectories.map { ($0 as NSString).appendingPathComponent("\(session).sock") }
    }

    /// Resolves the socket path, or nil when none exists.
    public func resolve(fileManager: FileManager = .default) -> String? {
        if let explicitPath, !explicitPath.isEmpty { return explicitPath }
        if let env = environment["CMUX_TUI_SOCKET"], !env.isEmpty { return env }
        if let session, !session.isEmpty {
            return candidates(session: session).first { Self.isSocket($0) }
        }
        var best: (path: String, modified: Date)?
        for dir in socketDirectories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".sock") {
                let path = (dir as NSString).appendingPathComponent(name)
                guard Self.isSocket(path),
                      let modified = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                else { continue }
                if best == nil || modified > best!.modified { best = (path, modified) }
            }
        }
        return best?.path
    }

    static func isSocket(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        (a as NSString).standardizingPath == (b as NSString).standardizingPath
    }
}
