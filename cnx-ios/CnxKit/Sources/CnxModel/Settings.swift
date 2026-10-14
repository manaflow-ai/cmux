import Foundation
import Observation

/// The link transport (PROTOCOL.md "Transport switch").
public enum TransportKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case webrtc
    case wireguard

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .webrtc: "WebRTC"
        case .wireguard: "WireGuard"
        }
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

/// Live Activities policy.
public enum LiveActivityMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case perAgent, onlyWaiting, off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .perAgent: "One per agent"
        case .onlyWaiting: "Only when waiting"
        case .off: "Off"
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
    public var showConnectionDetails: Bool { didSet { save(showConnectionDetails, "showConnectionDetails") } }
    public var terminalFontSize: Int { didSet { save(terminalFontSize, "terminalFontSize") } }
    public var terminalTheme: String { didSet { save(terminalTheme, "terminalTheme") } }
    public var dismissKeyboardAfterSend: Bool { didSet { save(dismissKeyboardAfterSend, "dismissKeyboardAfterSend") } }
    public var followUp: FollowUpBehavior { didSet { save(followUp.rawValue, "followUp") } }
    public var wrapCode: Bool { didSet { save(wrapCode, "wrapCode") } }
    public var keyClicks: Bool { didSet { save(keyClicks, "keyClicks") } }
    public var notifyQuestions: Bool { didSet { save(notifyQuestions, "notifyQuestions") } }
    public var notifyFinished: Bool { didSet { save(notifyFinished, "notifyFinished") } }
    public var notifyErrors: Bool { didSet { save(notifyErrors, "notifyErrors") } }
    public var liveActivities: LiveActivityMode { didSet { save(liveActivities.rawValue, "liveActivities") } }
    public var requireFaceID: Bool { didSet { save(requireFaceID, "requireFaceID") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func string(_ key: String) -> String? { defaults.string(forKey: "cnx.settings.\(key)") }
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: "cnx.settings.\(key)") as? Bool ?? fallback }
        transport = string("transport").flatMap(TransportKind.init(rawValue:)) ?? .webrtc
        appearance = string("appearance").flatMap(AppearanceMode.init(rawValue:)) ?? .system
        hapticsEnabled = bool("hapticsEnabled", true)
        showConnectionDetails = bool("showConnectionDetails", false)
        terminalFontSize = defaults.object(forKey: "cnx.settings.terminalFontSize") as? Int ?? 13
        terminalTheme = string("terminalTheme") ?? "Follow Mac"
        dismissKeyboardAfterSend = bool("dismissKeyboardAfterSend", true)
        followUp = string("followUp").flatMap(FollowUpBehavior.init(rawValue:)) ?? .queue
        wrapCode = bool("wrapCode", false)
        keyClicks = bool("keyClicks", true)
        notifyQuestions = bool("notifyQuestions", true)
        notifyFinished = bool("notifyFinished", true)
        notifyErrors = bool("notifyErrors", true)
        liveActivities = string("liveActivities").flatMap(LiveActivityMode.init(rawValue:)) ?? .onlyWaiting
        requireFaceID = bool("requireFaceID", false)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: "cnx.settings.\(key)")
    }
}
