import CmuxiOSFeatureKit
public import Foundation

/// Parses cmux links into `ShellRoute`s (c16-platform.md section 4).
///
/// Accepted: `cmux://<path>`, the app's exact-bundle scheme
/// (`cmux-ios-<bundle id>://<path>`) and `https://cmux.com/app/<path>`.
/// Ids are 1 to 128 characters of `[A-Za-z0-9._:-]`.
public struct ShellRouteParser: Sendable {
    public static let universalHosts: Set<String> = ["cmux.com", "www.cmux.com"]
    public static let universalPrefix = "app"
    private let schemes: Set<String>

    /// - Parameter bundleScheme: the exact-bundle scheme from Info.plist.
    public init(bundleScheme: String? = nil) {
        var schemes: Set<String> = ["cmux"]
        if let bundleScheme, !bundleScheme.isEmpty { schemes.insert(bundleScheme.lowercased()) }
        self.schemes = schemes
    }

    public func route(for url: URL) -> ShellRoute? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let components = pathComponents(parts) else { return nil }
        guard let head = components.first?.lowercased() else { return .home }
        let rest = Array(components.dropFirst())
        let query = Dictionary(
            (parts.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        switch head {
        case "home": return rest.isEmpty ? .home : nil
        case "feed":
            guard rest.count <= 1 else { return nil }
            guard let item = rest.first else { return .feed(item: nil) }
            return Self.isValidID(item) ? .feed(item: item) : nil
        case "workspaces": return rest.isEmpty ? .workspaces : nil
        case "workspace":
            guard (2...3).contains(rest.count), rest.allSatisfy(Self.isValidID) else { return nil }
            return .workspace(host: HostID(rest[0]), workspace: rest[1], surface: rest.count == 3 ? rest[2] : nil)
        case "compose":
            guard rest.isEmpty else { return nil }
            let host = query["host"]
            let workspace = query["workspace"]
            guard host.map(Self.isValidID) ?? true, workspace.map(Self.isValidID) ?? true else { return nil }
            return .compose(host: host.map { HostID($0) }, workspace: workspace)
        case "hosts": return rest.isEmpty ? .hosts : nil
        case "settings": return rest.isEmpty ? .settings : nil
        case "diagnostics": return rest.isEmpty ? .diagnostics : nil
        case "whats-new": return rest.isEmpty ? .whatsNew : nil
        case "pair", "attach": return .pairing(url)
        default: return nil
        }
    }

    /// The route path as components, or nil when the URL is not a cmux link.
    private func pathComponents(_ parts: URLComponents) -> [String]? {
        guard let scheme = parts.scheme?.lowercased() else { return nil }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if scheme == "https" {
            guard let host = parts.host?.lowercased(), Self.universalHosts.contains(host),
                  path.first == Self.universalPrefix else { return nil }
            return Array(path.dropFirst())
        }
        guard schemes.contains(scheme) else { return nil }
        // `cmux://feed/x` puts "feed" in the host; `cmux:feed/x` in the path.
        if let host = parts.host, !host.isEmpty { return [host] + path }
        return path
    }

    public static func isValidID(_ id: String) -> Bool {
        guard (1...128).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", ":", "-": true
            default: false
            }
        }
    }
}
