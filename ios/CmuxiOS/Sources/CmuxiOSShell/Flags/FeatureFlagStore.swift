public import CmuxiOSPlatform
public import Foundation
public import Observation

/// Feature flag values for this device. Precedence: launch environment,
/// then the device's DEV override, then the remote config (B1), then the
/// build default (`FlagResolution`). The device layers are client view
/// state; the remote layer is a projection of the account's config.
@MainActor
@Observable
public final class FeatureFlagStore {
    private static let defaultsPrefix = "cmux.ios.flag."
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let isDebug: Bool
    @ObservationIgnored public var onChange: (() -> Void)?
    private var values: [ShellFeatureFlag: FlagResolution] = [:]
    @ObservationIgnored private var remote: [String: RemoteFlagValue] = [:]

    public init(environment: [String: String], defaults: UserDefaults = .standard, isDebug: Bool) {
        self.defaults = defaults
        self.environment = environment
        self.isDebug = isDebug
        for flag in ShellFeatureFlag.allCases { values[flag] = resolve(flag) }
    }

    public func isEnabled(_ flag: ShellFeatureFlag) -> Bool { values[flag]?.value ?? false }

    /// The layer that decided the flag (DEV screen).
    public func layer(_ flag: ShellFeatureFlag) -> FlagLayer { values[flag]?.layer ?? .buildDefault }

    /// Applies the remote layer; fires `onChange` once if any value changed.
    public func applyRemote(_ config: RemoteConfig) {
        remote = config.flags
        var changed = false
        for flag in ShellFeatureFlag.allCases {
            let next = resolve(flag)
            if values[flag] != next {
                changed = changed || values[flag]?.value != next.value
                values[flag] = next
            }
        }
        if changed { onChange?() }
    }

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
        let next = resolve(flag)
        guard values[flag] != next else { return }
        let valueChanged = values[flag]?.value != next.value
        values[flag] = next
        if valueChanged { onChange?() }
    }

    private func resolve(_ flag: ShellFeatureFlag) -> FlagResolution {
        FlagResolution(
            environment: Self.parse(environment[flag.environmentKey]),
            deviceOverride: defaults.object(forKey: Self.defaultsPrefix + flag.rawValue) as? Bool,
            remote: remote[flag.rawValue],
            buildDefault: flag.defaultValue(isDebug: isDebug)
        )
    }

    private static func parse(_ raw: String?) -> Bool? {
        switch raw?.lowercased() {
        case "1", "true", "yes", "on": true
        case "0", "false", "no", "off": false
        default: nil
        }
    }
}
