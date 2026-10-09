import Foundation
import Observation
import SwiftUI

/// App-wide user preferences, persisted in the app's UserDefaults.
@MainActor
@Observable
public final class AppPreferences {
    public enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        /// Nil follows the system.
        public var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    public static let terminalFontRange: ClosedRange<Double> = 9...24
    public static let defaultTerminalFontSize: Double = 13

    public var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    public var terminalFontSize: Double { didSet { defaults.set(terminalFontSize, forKey: Keys.terminalFontSize) } }
    /// Debug: force the WebRTC link onto a TURN relay.
    public var forceRelay: Bool { didSet { defaults.set(forceRelay, forKey: Keys.forceRelay) } }
    /// The Mac the app connects to.
    public var selectedHostId: String? { didSet { defaults.set(selectedHostId, forKey: Keys.selectedHostId) } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?

    private enum Keys {
        static let appearance = "cmuxNext.appearance"
        static let terminalFontSize = "cmuxNext.terminalFontSize"
        static let forceRelay = "cmuxNext.forceRelay"
        static let selectedHostId = "cmuxNext.selectedHostId"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        let size = defaults.double(forKey: Keys.terminalFontSize)
        terminalFontSize = size == 0 ? Self.defaultTerminalFontSize : min(max(size, Self.terminalFontRange.lowerBound), Self.terminalFontRange.upperBound)
        forceRelay = defaults.bool(forKey: Keys.forceRelay)
        selectedHostId = defaults.string(forKey: Keys.selectedHostId)
        // The terminal writes the same key (pinch, Larger/Smaller Text): follow it.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadTerminalFontSize() }
        }
    }

    private func reloadTerminalFontSize() {
        let size = defaults.double(forKey: Keys.terminalFontSize)
        guard size > 0 else { return }
        let clamped = min(max(size, Self.terminalFontRange.lowerBound), Self.terminalFontRange.upperBound)
        if clamped != terminalFontSize { terminalFontSize = clamped }
    }
}
