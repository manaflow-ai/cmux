import ActivityKit
public import CmuxFeedPushCore
import CmuxiOSLiveActivity
public import Foundation
import OSLog

/// Starts Live Activities for running agents and keeps the owner's copy of
/// their push tokens current (c7-notify.md section 6): every token iOS hands
/// out is registered with `notify.activity.register`; an Activity that ends
/// or is dismissed sends `notify.activity.end`. Updates arrive by push from
/// the feed owner; this never polls.
@MainActor
public final class AgentActivityCenter {
    private let ops: any CloudOpsSending
    private var watchers: [String: Task<Void, Never>] = [:]
    private let log = Logger(subsystem: "dev.cmux.ios", category: "live-activity")

    public init(ops: any CloudOpsSending) {
        self.ops = ops
    }

    /// Whether the user allows Live Activities for the app.
    public var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Starts an Activity for an agent that runs on `subject`. Returns its
    /// owner id, or nil when Live Activities are off or iOS refused it.
    @discardableResult
    public func start(subject: AgentActivitySubject, agent: String, place: String, title: String,
                      startedAt: Date = Date()) -> String? {
        guard isEnabled else { return nil }
        let id = AgentActivityState.makeID()
        let attributes = AgentActivityAttributes(activityID: id, subject: subject, agent: agent, place: place)
        let state = AgentActivityState(phase: .running, title: title, started: startedAt)
        do {
            let activity = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil),
                                                pushType: .token)
            watch(activity, title: title)
            return id
        } catch {
            log.error("activity request refused: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Ends an Activity from the phone (the agent finished or the user
    /// stopped following it) with its final phase.
    public func end(_ id: String, phase: AgentActivityPhase) async {
        for activity in Activity<AgentActivityAttributes>.activities where activity.attributes.activityID == id {
            var state = activity.content.state
            state.phase = phase
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .default)
        }
    }

    /// Re-attaches to Activities that outlived the last launch.
    public func resume() {
        for activity in Activity<AgentActivityAttributes>.activities where watchers[activity.attributes.activityID] == nil {
            watch(activity, title: activity.content.state.title)
        }
    }

    private func watch(_ activity: Activity<AgentActivityAttributes>, title: String) {
        let id = activity.attributes.activityID
        let subject = activity.attributes.subject
        let started = activity.content.state.startedAt
        let ops = self.ops
        let log = self.log
        watchers[id]?.cancel()
        // Both loops run on the main actor (Activity is not Sendable).
        let tokens = Task {
            for await token in activity.pushTokenUpdates {
                let op = CloudOp.registerActivity(id: id, pushToken: token, subject: subject, title: title, startedAt: started,
                                                  idempotencyKey: "activity-register-\(id)-\(token.hexString.prefix(16))")
                do { try await ops.send(op) } catch { log.error("activity token not registered: \(String(describing: error), privacy: .public)") }
            }
        }
        watchers[id] = Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                try? await ops.send(.endActivity(id: id, idempotencyKey: "activity-end-\(id)"))
                break
            }
            // The Activity's life is over (or this watch was replaced): stop following tokens.
            tokens.cancel()
            self?.forget(id)
        }
    }

    private func forget(_ id: String) {
        watchers[id] = nil
    }
}
