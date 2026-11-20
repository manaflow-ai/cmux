import Foundation

/// Keeps a CLI fixture's configuration roots tied to its own home directory.
struct CLIChildEnvironment {
    let appHostEnvironment: [String: String]

    func normalizing(_ environment: [String: String]) -> [String: String] {
        // Callers scrub CMUX_* from the child; isolation belongs to the host.
        // A host is isolated exactly when its own CFFIXED_USER_HOME is pinned
        // to its HOME -- what every CI lane sets, and what a developer's
        // machine never has. Reading that condition rather than a lane marker
        // lets the host-free CLI lane qualify without claiming an app host.
        guard let hostHome = appHostEnvironment["HOME"],
              !hostHome.isEmpty,
              appHostEnvironment["CFFIXED_USER_HOME"] == hostHome,
              let rawHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHome.isEmpty else {
            return environment
        }
        var resolved = environment
        resolved["CFFIXED_USER_HOME"] = rawHome
        // A root inside the fixture's own home is the fixture testing that
        // override. A root under an inherited CFFIXED_USER_HOME is the app
        // host's, even when that host root was nested in the fixture.
        let configRoot = environment["XDG_CONFIG_HOME"]
        let inheritedHome = environment["CFFIXED_USER_HOME"].flatMap { $0 == rawHome ? nil : $0 }
        let fixtureOwned = Self.isInside(configRoot, home: rawHome)
            && !(inheritedHome.map { Self.isInside(configRoot, home: $0) } ?? false)
        if !fixtureOwned {
            resolved["XDG_CONFIG_HOME"] = URL(fileURLWithPath: rawHome, isDirectory: true)
                .appendingPathComponent(".config", isDirectory: true).path
        }
        return resolved
    }

    private static func isInside(_ path: String?, home: String) -> Bool {
        guard let path, !path.isEmpty else { return false }
        // Compare real locations: an in-home symlink to a shared directory is
        // not inside the fixture.
        let root = resolvedPath(home)
        let candidate = resolvedPath(path)
        return candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Resolves symlinks through the deepest existing ancestor, then appends
    /// the components that do not exist yet.
    private static func resolvedPath(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missing { resolved.appendPathComponent(component, isDirectory: true) }
        return resolved.path
    }
}
