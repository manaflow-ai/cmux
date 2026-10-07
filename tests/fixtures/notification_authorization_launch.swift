import Foundation
import CoreFoundation
import UserNotifications
func pumpRunLoop() { CFRunLoopRunInMode(.defaultMode, 0.01, false) }

// TYPES

public enum UserNotificationCenterFailure: Error { case timedOut }
struct Options: OptionSet, Sendable {
    let rawValue: Int
    static let alert = Options(rawValue: 1)
    static let sound = Options(rawValue: 2)
    static let badge = Options(rawValue: 4)
}
@MainActor final class Service {
    var status: Result<UserNotificationAuthorizationStatus, UserNotificationCenterFailure> = .success(.denied)
    var grant: Result<Bool, UserNotificationCenterFailure> = .success(true)
    func authorizationStatus() async -> Result<UserNotificationAuthorizationStatus, UserNotificationCenterFailure> { status }
    func requestAuthorization(options: Options) async -> Result<Bool, UserNotificationCenterFailure> { grant }
}
@MainActor enum AppFocusState { static func isAppActive() -> Bool { true } }
@MainActor final class TerminalNotificationStore {
    static let shared = TerminalNotificationStore()
    enum AuthorizationRequestOrigin: String { case notificationDelivery, settingsButton }
    var authorizationState: NotificationAuthorizationState = .unknown {
        didSet { changes += 1; if authorizationState != oldValue { posts += 1 } }
    }
    var changes = 0
    var posts = 0
    let userNotificationCenter = Service()
    lazy var authorizationStatusProvider: @MainActor () async -> Result<UserNotificationAuthorizationStatus, UserNotificationCenterFailure> = { [self] in userNotificationCenter.status }
    // GATE
    var hasRequestedAutomaticAuthorization = false
    var hasDeferredAuthorizationRequest = false
    var hasUpgradedBadgeAuthorization = true
    func logAuthorization(_ message: String) {}
    func promptToEnableNotifications() { preconditionFailure("unexpected UI") }
    static func authorizationStatusLabel(_ status: UserNotificationAuthorizationStatus) -> String { "stub" }
    static func cachedDeliveryAuthorizationDecision(for state: NotificationAuthorizationState, isAppActive: Bool) -> Bool? {
        state == .unknown ? nil : state.allowsDelivery
    }
    // BODIES
    func deliver(_ completion: @escaping @MainActor @Sendable (Bool, NotificationAuthorizationState) -> Void) {
        ensureAuthorization(origin: .notificationDelivery, completion)
    }
}
@MainActor class FakeWindow {
    var isVisible = false
    var contentView: Bool? = true
    var events: [String] = []
    func layoutIfNeeded() { events.append("layout") }
    func displayIfNeeded() { events.append("display") }
    func display() { events.append("display") }
}
// LIFECYCLE
@MainActor final class Decision { var finished = false; var state: NotificationAuthorizationState = .unknown; var allowed = false }
@main struct Runner {
    @MainActor static func main() async {
        let mode = CommandLine.arguments[1]
        if mode.hasPrefix("window") {
            var signal = 0
            // WINDOW TEST
            return
        }
        let store = TerminalNotificationStore()
        if mode == "post" { await store.markWindowSetupComplete()?.value }
        if mode == "grant" || mode.hasPrefix("request-") { store.userNotificationCenter.status = .success(.notDetermined) }
        if mode == "request-denied" { store.userNotificationCenter.grant = .success(false) }
        if mode == "request-error" { store.userNotificationCenter.grant = .failure(.timedOut) }
        if mode == "failure" { store.userNotificationCenter.status = .failure(.timedOut) }
        if mode == "status" { store.userNotificationCenter.status = .success(.provisional) }
        let decision = Decision()
        store.deliver { allowed, state in decision.allowed = allowed; decision.state = state; decision.finished = true }
        for _ in 0..<100 { if decision.finished { break }; await Task.yield() }
        precondition(decision.finished, "delivery completion lost")
        if mode == "post" {
            precondition(store.authorizationState == .denied)
            let changes = store.changes
            await store.refreshAuthorizationStatus().value
            precondition(store.changes == changes, "unchanged status published")
            return
        }
        precondition(store.authorizationState == .unknown, "authorization escaped setup gate")
        precondition(store.changes == 0 && store.posts == 0, "early publication")
        if mode == "status" { precondition(decision.allowed && decision.state == .provisional, "delivery used gated stale state") }
        if mode == "grant" { precondition(decision.allowed && decision.state == .authorized) }
        if mode == "request-denied" { precondition(!decision.allowed && decision.state == .denied) }
        if mode == "request-error" { precondition(!decision.allowed && decision.state == .unknown) }
        await store.markWindowSetupComplete()?.value
        let changes = store.changes
        precondition(store.markWindowSetupComplete() == nil)
        precondition(store.changes == changes)
    }
}
