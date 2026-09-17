// Only display/tag metadata is stubbed. Identity resolution and UUID
// canonicalization are compiled unchanged from their production sources.
public struct SettingCatalog {
    public init() {}
    public var mobile: Mobile { Mobile() }

    public struct Mobile {
        public var iOSPairingDisplayName: DisplayName { DisplayName() }
    }

    public struct DisplayName {
        public var userDefaultsKey: String { "fixture.display-name" }
    }
}

public enum SocketControlSettings {
    public static func launchTag(environment: [String: String]) -> String? { nil }
}

public enum SocketPathMarkerFiles {
    public enum Variant {
        case stable
        case nightly(String?)
        case staging(String?)
        case dev(String?)
    }

    public static func sanitizeSocketSlug(_ value: String) -> String? { value }
    public static func variant(bundleIdentifier: String, environment: [String: String]) -> Variant {
        .stable
    }
}
