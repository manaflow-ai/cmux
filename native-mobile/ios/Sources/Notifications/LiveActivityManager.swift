import ActivityKit
import Foundation
import os

/// Live Activities for agent runs. The Worker starts them with push-to-start
/// when an agent on the Mac goes to work and updates or ends them through
/// each activity's push token; this reports both tokens.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private(set) var pushToStartToken: String?
    private var observed: Set<String> = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task {
            for await data in Activity<AgentActivityAttributes>.pushToStartTokenUpdates {
                let token = data.hexString
                guard token != pushToStartToken else { continue }
                pushToStartToken = token
                PushManager.log.info("live activity push-to-start token \(token.prefix(8), privacy: .public)…")
                await PushManager.shared.uploadRegistration()
            }
        }
        for activity in Activity<AgentActivityAttributes>.activities { observe(activity) }
        Task {
            for await activity in Activity<AgentActivityAttributes>.activityUpdates { observe(activity) }
        }
        if ProcessInfo.processInfo.environment["CMUX_NATIVE_DEMO_LIVE_ACTIVITY"] != nil { startDemo() }
    }

    private func observe(_ activity: Activity<AgentActivityAttributes>) {
        guard observed.insert(activity.id).inserted else { return }
        let attributes = activity.attributes
        let id = activity.id
        Task {
            for await data in activity.pushTokenUpdates {
                await report(attributes, activityID: id, pushToken: data.hexString, startedAt: activity.content.state.startedAt, ended: false)
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                await report(attributes, activityID: id, pushToken: nil, startedAt: nil, ended: true)
                self.observed.remove(id)
            }
        }
    }

    private func report(_ attributes: AgentActivityAttributes, activityID: String, pushToken: String?, startedAt: Double?, ended: Bool) async {
        let push = PushManager.shared
        guard let device = push.deviceToken else { return }
        do {
            try await push.api.liveActivity(deviceToken: device, hostID: attributes.hostID, surface: attributes.surface,
                                            activityID: activityID, pushToken: pushToken, startedAt: startedAt, ended: ended)
        } catch {
            PushManager.log.error("live activity report failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Local preview for screenshots and simulator checks:
    /// `CMUX_NATIVE_DEMO_LIVE_ACTIVITY=working|needs_input|done`.
    func startDemo() {
        let raw = ProcessInfo.processInfo.environment["CMUX_NATIVE_DEMO_LIVE_ACTIVITY"] ?? "working"
        let state = AgentActivityAttributes.ContentState.State(rawValue: raw) ?? .working
        let attributes = AgentActivityAttributes(hostID: "demo", surface: 1, agent: "Claude", workspace: "cmux · feat-push")
        let content = AgentActivityAttributes.ContentState(
            state: state, startedAt: Date().addingTimeInterval(-754).timeIntervalSince1970,
            detail: state == .needsInput ? String(localized: "Allow edit to push.ts?") : "")
        do {
            _ = try Activity.request(attributes: attributes, content: ActivityContent(state: content, staleDate: nil), pushType: nil)
        } catch {
            PushManager.log.error("demo live activity failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
