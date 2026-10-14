import Foundation

/// Developer toggles for DEBUG and Demo builds, set in Settings → Developer
/// and read at launch, so a demo on a phone needs no launch arguments.
/// Non-DEBUG builds (Release, Production) never read them, and Production
/// removes any stored value at launch (``removeStoredValues(from:)``).
public enum DeveloperOptions {
    /// `UserDefaults` key: sign in as the local mock user with sample data.
    public static let mockDataKey = "cnx.dev.mockData"
    /// `UserDefaults` key: a scripted demo to run once at the next launch.
    public static let launchDemoKey = "cnx.dev.launchDemo"
    /// `UserDefaults` key: relay only, to simulate a distant network. Links
    /// skip every direct path (WebRTC over TURN, WireGuard over the relay).
    /// Applies live: changing it redials.
    public static let relayOnlyKey = "cnx.dev.relayOnly"
    /// `UserDefaults` key: the terminal demo's phases (`-CnxTerminalDemoPhases`).
    public static let terminalDemoPhasesKey = "CnxTerminalDemoPhases"

    /// Every stored developer setting. A build without the Developer page
    /// removes them so a value set by an earlier Debug or Demo install in the
    /// same container can never apply.
    public static let storedKeys = [mockDataKey, launchDemoKey, relayOnlyKey, terminalDemoPhasesKey]

    /// Removes every stored developer setting (Production launch).
    public static func removeStoredValues(from defaults: UserDefaults = .standard) {
        for key in storedKeys { defaults.removeObject(forKey: key) }
    }

    /// Whether mock sign-in with sample data is on (takes effect at launch).
    /// Always off in non-DEBUG builds, whatever is stored.
    public static var mockData: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: mockDataKey)
        #else
        false
        #endif
    }

    /// Whether relay-only links are on. Always off in Release builds.
    public static var relayOnly: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: relayOnlyKey)
        #else
        false
        #endif
    }

    #if DEBUG
    /// Mock content (sample Feed, mock agent chats, mock Chief, mock
    /// terminals) is allowed only when the developer asked for it: Mock data
    /// in Settings → Developer or `CNX_MOCK_AUTH=1`, the same switches that
    /// sign in the local mock user. A live signed-in session never has it.
    public static var mockContentEnabled: Bool {
        mockContentEnabled(mockData: mockData, environment: ProcessInfo.processInfo.environment)
    }

    static func mockContentEnabled(mockData: Bool, environment: [String: String]) -> Bool {
        mockData || environment["CNX_MOCK_AUTH"] == "1"
    }

    /// Scripted demos a developer can pick for the next launch.
    public static let demos: [(id: String, title: String)] = [
        ("live", "Live tour"),
        ("workspaces", "Workspaces"),
        ("chief", "Chief"),
        ("chat-feed", "Feed and agent chat"),
        ("terminal", "Terminal"),
        ("drawer", "Team sidebar"),
    ]

    /// The demo picked for this launch, read and cleared once per process.
    public static let launchDemo: String? = {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: launchDemoKey), !name.isEmpty else { return nil }
        defaults.removeObject(forKey: launchDemoKey)
        return name
    }()
    #else
    /// Non-DEBUG builds have no mock content to enable.
    public static var mockContentEnabled: Bool { false }
    #endif
}
