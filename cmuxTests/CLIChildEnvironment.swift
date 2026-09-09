import Foundation

/// Keeps a CLI fixture's configuration roots tied to its own home directory.
struct CLIChildEnvironment {
    let appHostEnvironment: [String: String]

    func normalizing(_ environment: [String: String]) -> [String: String] {
        guard environment["CMUX_APP_HOST_ISOLATION_REQUIRED"] == "1",
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
