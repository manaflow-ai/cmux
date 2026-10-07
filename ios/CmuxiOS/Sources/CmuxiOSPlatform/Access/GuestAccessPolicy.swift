/// Decides at launch how a stored guest choice applies. Automated sign-in
/// launches (the dogfood readiness receipt, launcher credentials) ignore it
/// so the tagged launcher still lands signed in; DEBUG `CMUX_IOS_GUEST=1`
/// starts as guest for UI tests. Release builds honor the stored choice.
public struct GuestAccessPolicy: Hashable, Sendable {
    public enum Decision: Hashable, Sendable {
        case stored
        case ignored
        case forced
    }

    public var decision: Decision

    public init(environment: [String: String], isDebug: Bool) {
        let present: (String) -> Bool = { !(environment[$0] ?? "").isEmpty }
        if present("CMUX_DOGFOOD_READINESS_NONCE") || present("CMUX_UITEST_STACK_EMAIL") {
            decision = .ignored
        } else if isDebug, environment["CMUX_IOS_GUEST"] == "1" {
            decision = .forced
        } else {
            decision = .stored
        }
    }

    public func isGuest(stored: Bool) -> Bool {
        switch decision {
        case .stored: stored
        case .ignored: false
        case .forced: true
        }
    }
}
