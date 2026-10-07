public import CmuxiOSFeatureKit
public import Foundation
public import Observation

/// Mock or real per feature seam (DEV switch). Precedence: per-seam launch
/// environment (`CMUX_IOS_SOURCE_FEED=real`), global launch environment
/// (`CMUX_IOS_SOURCES=mock`), the device's DEV choice, then the build
/// default (mock in DEBUG, real in Release).
@MainActor
@Observable
public final class FeatureSourceModeStore {
    private static let defaultsPrefix = "cmux.ios.source."
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let isDebug: Bool
    @ObservationIgnored public var onChange: (() -> Void)?
    public private(set) var modes: [FeatureSeam: FeatureSourceMode] = [:]

    public init(environment: [String: String], defaults: UserDefaults = .standard, isDebug: Bool) {
        self.defaults = defaults
        self.environment = environment
        self.isDebug = isDebug
        for seam in FeatureSeam.allCases { modes[seam] = resolve(seam) }
    }

    public func mode(_ seam: FeatureSeam) -> FeatureSourceMode { modes[seam] ?? .mock }

    public func isPinnedByEnvironment(_ seam: FeatureSeam) -> Bool {
        Self.environmentMode(for: seam, in: environment) != nil
    }

    public func set(_ seam: FeatureSeam, to mode: FeatureSourceMode) {
        defaults.set(mode.rawValue, forKey: Self.defaultsPrefix + seam.rawValue)
        let value = resolve(seam)
        guard modes[seam] != value else { return }
        modes[seam] = value
        onChange?()
    }

    public static func environmentKey(for seam: FeatureSeam) -> String {
        "CMUX_IOS_SOURCE_" + seam.rawValue.uppercased()
    }

    private func resolve(_ seam: FeatureSeam) -> FeatureSourceMode {
        if let pinned = Self.environmentMode(for: seam, in: environment) { return pinned }
        if let stored = defaults.string(forKey: Self.defaultsPrefix + seam.rawValue).flatMap(FeatureSourceMode.init(rawValue:)) {
            return stored
        }
        return isDebug ? .mock : .real
    }

    private static func environmentMode(for seam: FeatureSeam, in environment: [String: String]) -> FeatureSourceMode? {
        environment[environmentKey(for: seam)].flatMap(FeatureSourceMode.init(rawValue:))
            ?? environment["CMUX_IOS_SOURCES"].flatMap(FeatureSourceMode.init(rawValue:))
    }
}
