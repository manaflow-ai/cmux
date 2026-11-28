import CmuxHomeUI
import CmuxiOSDesign
import Foundation

/// Prototype switches (DEV builds): Home list density and compose/invite flow.
/// Read from launch env first (`CMUX_IOS_HOME_DENSITY`, `CMUX_IOS_COMPOSE_FLOW`),
/// then the device's defaults; the shake menu writes the defaults. Client view
/// state only: never synced.
@MainActor
final class DevOptions {
    private static let densityKey = "cmux.ios.dev.homeDensity"
    private static let composeKey = "cmux.ios.dev.composeFlow"
    private let defaults: UserDefaults
    var onChange: ((HomeUIOptions) -> Void)?

    private(set) var options: HomeUIOptions

    init(environment: [String: String], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let density = environment["CMUX_IOS_HOME_DENSITY"].flatMap(HomeListDensity.init(rawValue:))
            ?? defaults.string(forKey: Self.densityKey).flatMap(HomeListDensity.init(rawValue:))
            ?? .comfortable
        let compose = environment["CMUX_IOS_COMPOSE_FLOW"].flatMap(HomeComposeFlow.init(rawValue:))
            ?? defaults.string(forKey: Self.composeKey).flatMap(HomeComposeFlow.init(rawValue:))
            ?? .inlineTo
        options = HomeUIOptions(density: density, composeFlow: compose)
    }

    func set(density: HomeListDensity) {
        options.density = density
        defaults.set(density.rawValue, forKey: Self.densityKey)
        onChange?(options)
    }

    func set(composeFlow: HomeComposeFlow) {
        options.composeFlow = composeFlow
        defaults.set(composeFlow.rawValue, forKey: Self.composeKey)
        onChange?(options)
    }
}
