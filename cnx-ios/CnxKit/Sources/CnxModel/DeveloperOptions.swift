import Foundation

/// Developer toggles for DEBUG and Demo builds, set in Settings → Developer
/// and read at launch, so a demo on a phone needs no launch arguments.
/// Release builds never read them.
public enum DeveloperOptions {
    /// `UserDefaults` key: sign in as the local mock user with sample data.
    public static let mockDataKey = "cnx.dev.mockData"
    /// `UserDefaults` key: a scripted demo to run once at the next launch.
    public static let launchDemoKey = "cnx.dev.launchDemo"

    /// Scripted demos a developer can pick for the next launch.
    public static let demos: [(id: String, title: String)] = [
        ("live", "Live tour"),
        ("workspaces", "Workspaces"),
        ("chief", "Chief"),
        ("chat-feed", "Feed and agent chat"),
        ("terminal", "Terminal"),
        ("drawer", "Team sidebar"),
    ]

    /// Whether mock sign-in with sample data is on (takes effect at launch).
    public static var mockData: Bool {
        UserDefaults.standard.bool(forKey: mockDataKey)
    }

    /// The demo picked for this launch, read and cleared once per process.
    public static let launchDemo: String? = {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: launchDemoKey), !name.isEmpty else { return nil }
        defaults.removeObject(forKey: launchDemoKey)
        return name
    }()
}
