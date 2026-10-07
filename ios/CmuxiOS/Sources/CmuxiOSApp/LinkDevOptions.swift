import Foundation

/// DEV switches of the phone's link layer (d1-terminal-ux.md section 5):
/// B3's WireGuard-over-WebRTC carrier (V2, until D2 picks V1 or V2) and C1's
/// local echo prediction. Launch env first (`CMUX_IOS_LINK_WG`,
/// `CMUX_IOS_TERMINAL_PREDICTION` = `1`/`0`), then the device's defaults
/// (the shake menu writes them). Release builds keep both off. Read when an
/// account's links start and when a terminal opens.
struct LinkDevOptions: Equatable {
    static let wireGuardKey = "cmux.ios.dev.linkWireGuard"
    static let predictionKey = "cmux.ios.dev.terminalPrediction"

    var wireGuardOverWebRTC: Bool
    var prediction: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard) {
        #if DEBUG
        wireGuardOverWebRTC = Self.flag(environment["CMUX_IOS_LINK_WG"]) ?? defaults.bool(forKey: Self.wireGuardKey)
        prediction = Self.flag(environment["CMUX_IOS_TERMINAL_PREDICTION"]) ?? defaults.bool(forKey: Self.predictionKey)
        #else
        wireGuardOverWebRTC = false
        prediction = false
        #endif
    }

    private static func flag(_ value: String?) -> Bool? {
        switch value {
        case "1", "true": true
        case "0", "false": false
        default: nil
        }
    }
}
