import CMUXMobileCore
import CmuxMobileAnalytics
import CmuxMobileTransport
import Foundation
import SwiftUI
import cmuxFeature

/// Holds the de-singletonized graph the `cmuxApp` builds once at launch.
///
/// Owns the mobile runtime, the auth composition (coordinator + push
/// registration), the process-wide reachability monitor, and the shared push
/// coordinator. Everything below the app shell receives these by injection
/// instead of reaching for a singleton.
@MainActor
final class AppCompositionRoot {
    let runtime: CMUXMobileRuntime
    let auth: MobileAuthComposition
    let reachability: any ReachabilityProviding
    let pushCoordinator: MobilePushCoordinator
    let analytics: MobileAnalyticsComposition

    init(
        runtime: CMUXMobileRuntime,
        auth: MobileAuthComposition,
        reachability: any ReachabilityProviding
    ) {
        self.runtime = runtime
        self.auth = auth
        self.reachability = reachability
        self.analytics = MobileAnalyticsComposition(
            apiBaseURL: auth.config.apiBaseURL,
            tokenProvider: auth.coordinator
        )
        self.pushCoordinator = MobilePushCoordinator(
            registration: auth.pushRegistration,
            analytics: analytics.emitter
        )
    }

    /// The most recent scene phase, so a `.active` transition is classified as a
    /// cold first foreground vs. a warm resume.
    private var hasForegrounded = false
    /// When the current session started, for the best-effort `ios_session_ended`
    /// duration emitted on background.
    private var currentSessionStartedAt: Date?
    /// The id of the session currently in progress, echoed onto `ios_session_ended`.
    private var currentSessionID: String?

    /// Drives the app-lifecycle + sessionization analytics on scene-phase changes.
    ///
    /// On `.active`: resolves the session (cold start or 30-min-gap resume) via
    /// the injected ``CmuxMobileAnalytics/AnalyticsSessionizer`` and persisted
    /// ``CmuxMobileAnalytics/AnalyticsSessionStore``, emitting `ios_session_started`
    /// only when a new session begins, plus an `ios_app_foregrounded` heartbeat.
    /// On `.background`: records the timestamp for the next gap calculation,
    /// emits `ios_app_backgrounded`, and force-flushes queued events before
    /// suspension.
    func handleScenePhase(_ phase: ScenePhase) {
        let emitter = analytics.emitter
        switch phase {
        case .active:
            let now = Date()
            let decision = analytics.sessionizer.resolveForeground(
                now: now,
                lastBackgroundedAt: analytics.sessionStore.lastBackgroundedAt,
                currentSessionID: analytics.sessionStore.currentSessionID
            )
            analytics.sessionStore.setCurrentSessionID(decision.sessionID)
            let launchType = hasForegrounded ? "warm" : "cold"
            currentSessionID = decision.sessionID.uuidString
            if decision.startedNewSession {
                currentSessionStartedAt = now
                emitter.capture("ios_session_started", [
                    "session_id": .string(decision.sessionID.uuidString),
                    "launch_type": .string(launchType),
                ])
            }
            var foregroundProps: [String: AnalyticsValue] = ["launch_type": .string(launchType)]
            if let gap = decision.secondsSinceBackgrounded {
                foregroundProps["seconds_since_backgrounded"] = .int(Int(gap))
            }
            emitter.capture("ios_app_foregrounded", foregroundProps)
            hasForegrounded = true
        case .background:
            let now = Date()
            analytics.sessionStore.recordBackgrounded(at: now)
            emitter.capture("ios_app_backgrounded", [:])
            // Best-effort session end on background. iOS may hard-kill the app
            // without a `.background` transition, so this is not guaranteed; the
            // 30-min gap on the next foreground still re-sessionizes correctly.
            if let sessionID = currentSessionID {
                var props: [String: AnalyticsValue] = ["session_id": .string(sessionID)]
                if let startedAt = currentSessionStartedAt {
                    props["session_duration_seconds"] = .int(max(0, Int(now.timeIntervalSince(startedAt))))
                }
                emitter.capture("ios_session_ended", props)
            }
            // Force a flush before the OS may suspend us, so queued events survive.
            Task { await emitter.flush() }
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}
