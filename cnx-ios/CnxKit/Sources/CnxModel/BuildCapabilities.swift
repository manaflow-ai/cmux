import Foundation

/// What this build of the app can do, from its Info.plist (`project.yml`).
public struct BuildCapabilities: Sendable, Equatable {
    /// The build is signed for push (`aps-environment`). Only TestFlight builds
    /// are: hand-installed builds use the team wildcard profile, which cannot
    /// carry push.
    public let push: Bool

    public init(push: Bool) {
        self.push = push
    }

    public init(info: [String: Any]) {
        push = (info["CNXPush"] as? String) == "YES"
    }

    public static let current = BuildCapabilities(info: Bundle.main.infoDictionary ?? [:])
}
