public import Foundation
public import Observation

/// Feature flag values for this device. Precedence: launch environment,
/// then the device's DEV override, then the build default. Client view
/// state only; never synced.
@MainActor
@Observable
public final class FeatureFlagStore {
    private static let defaultsPrefix = "cmux.ios.flag."
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let isDebug: Bool
    @ObservationIgnored public var onChange: (() -> Void)?
    private var values: [ShellFeatureFlag: Bool] = [:]

    public init(environment: [String: String], defaults: UserDefaults = .standard, isDebug: Bool) {
        self.defaults = defaults
        self.environment = environment
        self.isDebug = isDebug
        for flag in ShellFeatureFlag.allCases { values[flag] = resolve(flag) }
    }

    public func isEnabled(_ flag: ShellFeatureFlag) -> Bool { values[flag] ?? false }

    /// True when the launch environment fixes the value (DEV toggles are inert).
    public func isPinnedByEnvironment(_ flag: ShellFeatureFlag) -> Bool {
        Self.parse(environment[flag.environmentKey]) != nil
    }

    public func set(_ flag: ShellFeatureFlag, enabled: Bool) {
        defaults.set(enabled, forKey: Self.defaultsPrefix + flag.rawValue)
        update(flag)
    }

    /// Drops the DEV override so the build default applies again.
    public func reset(_ flag: ShellFeatureFlag) {
        defaults.removeObject(forKey: Self.defaultsPrefix + flag.rawValue)
        update(flag)
    }

    /// The root tabs these flags show, in order.
    public var visibleTabs: [ShellTab] {
        ShellTab.allCases.filter { tab in tab.flag.map(isEnabled) ?? true }
    }

    private func update(_ flag: ShellFeatureFlag) {
        let value = resolve(flag)
        guard values[flag] != value else { return }
        values[flag] = value
        onChange?()
    }

    private func resolve(_ flag: ShellFeatureFlag) -> Bool {
        if let pinned = Self.parse(environment[flag.environmentKey]) { return pinned }
        if let stored = defaults.object(forKey: Self.defaultsPrefix + flag.rawValue) as? Bool { return stored }
        return flag.defaultValue(isDebug: isDebug)
    }

    private static func parse(_ raw: String?) -> Bool? {
        switch raw?.lowercased() {
        case "1", "true", "yes", "on": true
        case "0", "false", "no", "off": false
        default: nil
        }
    }
}
