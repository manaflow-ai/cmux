import Foundation
import Observation

/// The link transport (PROTOCOL.md "Transport switch", verify/hybrid-link.md).
/// WireGuard (the default) carries the link and opens a WebRTC media session
/// beside it for browser video; WebRTC carries everything on one peer
/// connection. The picker lists WireGuard first.
public enum TransportKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case wireguard
    case webrtc

    public var id: String { rawValue }

    /// The short name (the Settings root's value, the status line).
    public var title: String {
        switch self {
        case .webrtc: "WebRTC only"
        case .wireguard: "WireGuard"
        }
    }

    /// The Transport page's row title.
    public var pickerTitle: String {
        switch self {
        case .webrtc: String(localized: "WebRTC only")
        case .wireguard: String(localized: "WireGuard (recommended)")
        }
    }

    /// The transport of an install with no saved choice.
    public static let fallback: TransportKind = .wireguard
}

/// The system notification permission as Settings shows it.
public enum NotificationPermission: Sendable, Equatable {
    case notDetermined, on, off

    /// "On", "Off" or "Not set" (the Notifications page's permission row).
    public var title: String {
        switch self {
        case .on: "On"
        case .off: "Off"
        case .notDetermined: "Not set"
        }
    }

    /// The Settings root's trailing value for Notifications. A build without
    /// push gets only Chief's local alerts, so "On" there reads "Chief only".
    public func rootValue(push: Bool) -> String {
        guard !push, self == .on else { return title }
        return "Chief only"
    }
}

/// App appearance override.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case light, dark, system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }
}

/// What to do with text sent while an agent is still working.
public enum FollowUpBehavior: String, CaseIterable, Identifiable, Sendable, Codable {
    case queue, steer

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .queue: "Queue"
        case .steer: "Steer"
        }
    }
}

/// Device-local preferences (SPEC section 9), persisted in `UserDefaults`.
@MainActor
@Observable
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    public var transport: TransportKind { didSet { save(transport.rawValue, "transport") } }
    public var appearance: AppearanceMode { didSet { save(appearance.rawValue, "appearance") } }
    /// Read by `CnxHaptics` through the same key.
    public var hapticsEnabled: Bool { didSet { save(hapticsEnabled, "hapticsEnabled") } }
    /// Read by the terminal (`CnxPreferences.terminalFontSize`) through the same key.
    public var terminalFontSize: Int { didSet { save(terminalFontSize, "terminalFontSize") } }
    /// Read by the agent composer (`CnxPreferences`) through the same key.
    public var dismissKeyboardAfterSend: Bool { didSet { save(dismissKeyboardAfterSend, "dismissKeyboardAfterSend") } }
    /// Read by the agent composer: Steer sends a message typed while the
    /// agent works as acpmux `steer`, Queue sends it after the turn.
    public var followUp: FollowUpBehavior { didSet { save(followUp.rawValue, "followUp") } }
    /// Read by code cards, edit previews and the diff viewer.
    public var wrapCode: Bool { didSet { save(wrapCode, "wrapCode") } }
    /// Read by the terminal key bar.
    public var keyClicks: Bool { didSet { save(keyClicks, "keyClicks") } }
    public var notifyQuestions: Bool { didSet { save(notifyQuestions, "notifyQuestions") } }
    public var notifyFinished: Bool { didSet { save(notifyFinished, "notifyFinished") } }
    public var notifyErrors: Bool { didSet { save(notifyErrors, "notifyErrors") } }
    public var requireFaceID: Bool { didSet { save(requireFaceID, "requireFaceID") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func string(_ key: String) -> String? { defaults.string(forKey: "cnx.settings.\(key)") }
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: "cnx.settings.\(key)") as? Bool ?? fallback }
        // A saved choice stays; an install that never chose gets WireGuard
        // (it used to get WebRTC; verify/hybrid-link.md).
        transport = string("transport").flatMap(TransportKind.init(rawValue:)) ?? .fallback
        appearance = string("appearance").flatMap(AppearanceMode.init(rawValue:)) ?? .system
        hapticsEnabled = bool("hapticsEnabled", true)
        terminalFontSize = defaults.object(forKey: "cnx.settings.terminalFontSize") as? Int ?? Self.defaultTerminalFontSize
        dismissKeyboardAfterSend = bool("dismissKeyboardAfterSend", true)
        followUp = string("followUp").flatMap(FollowUpBehavior.init(rawValue:)) ?? .queue
        wrapCode = bool("wrapCode", false)
        keyClicks = bool("keyClicks", true)
        notifyQuestions = bool("notifyQuestions", true)
        notifyFinished = bool("notifyFinished", true)
        notifyErrors = bool("notifyErrors", true)
        requireFaceID = bool("requireFaceID", false)
        // Retired settings that never took effect (a terminal theme the phone
        // cannot read from the Mac, and a connection-details switch).
        for key in Self.retiredKeys { defaults.removeObject(forKey: "cnx.settings.\(key)") }
    }

    static let retiredKeys = ["showConnectionDetails", "terminalTheme"]

    /// The terminal's built-in size (`CnxPreferences.defaultTerminalFontSize`).
    public static let defaultTerminalFontSize = 12

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: "cnx.settings.\(key)")
    }
}
