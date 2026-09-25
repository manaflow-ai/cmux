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
        resolved["XDG_CONFIG_HOME"] = URL(fileURLWithPath: rawHome, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true).path
        return resolved
    }
}
