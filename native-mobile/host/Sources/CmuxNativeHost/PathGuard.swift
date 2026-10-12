import Foundation

/// Resolves phone-supplied paths and refuses anything outside the user's home,
/// `/tmp` and `/private/tmp`. Symlinks are resolved before the check, so a
/// link inside home that points elsewhere is refused.
public struct PathGuard: Sendable {
    public struct Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        public var path: String
        public var description: String { "\(path) is outside the allowed directories" }
    }

    public let home: String
    /// Resolved allowed roots.
    public let roots: [String]

    public init(home: String = NSHomeDirectory(), extraRoots: [String] = ["/tmp", "/private/tmp"]) {
        let resolvedHome = Self.realpath(home) ?? (home as NSString).standardizingPath
        self.home = resolvedHome
        var roots = [resolvedHome]
        for root in extraRoots {
            let resolved = Self.realpath(root) ?? (root as NSString).standardizingPath
            if !roots.contains(resolved) { roots.append(resolved) }
        }
        self.roots = roots
    }

    /// Expands `~`, joins relative paths onto `cwd` (or home), resolves
    /// symlinks (for a missing path, those of its deepest existing ancestor)
    /// and checks the result.
    public func resolve(_ input: String, relativeTo cwd: String? = nil) throws -> String {
        let resolved = absolute(input, relativeTo: cwd)
        guard isAllowed(resolved) else { throw Refusal(path: input) }
        return resolved
    }

    /// Resolution without the check.
    public func absolute(_ input: String, relativeTo cwd: String? = nil) -> String {
        var path = input.isEmpty ? "~" : input
        if path == "~" || path.hasPrefix("~/") {
            path = home + path.dropFirst()
        } else if !path.hasPrefix("/") {
            let base = cwd.map { absolute($0) } ?? home
            path = (base as NSString).appendingPathComponent(path)
        }
        let standardized = (path as NSString).standardizingPath
        if let real = Self.realpath(standardized) { return real }
        // Missing leaf: resolve the deepest existing ancestor, then re-append.
        var existing = standardized
        var tail: [String] = []
        while existing != "/", Self.realpath(existing) == nil {
            tail.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        let base = Self.realpath(existing) ?? existing
        return tail.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }

    public func isAllowed(_ resolved: String) -> Bool {
        roots.contains { resolved == $0 || resolved.hasPrefix($0 == "/" ? "/" : $0 + "/") }
    }

    static func realpath(_ path: String) -> String? {
        guard let p = Darwin.realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}
