public import CNCore
import Foundation
import Observation

/// Which agent sessions the user has seen. The protocol has no `agent.read`,
/// so the phone keeps this itself: a session is unread only when the host
/// reports unread turns, nobody is looking at it, and it changed after the
/// user last saw it. The chat screen marks its session while visible; list
/// UIs (the Agents list, the drawer) ask `isUnread(_:)`.
@MainActor
@Observable
public final class AgentReadState {
    public static let shared = AgentReadState()

    /// Sessions currently on screen (a chat can be shown in two places).
    private var viewing: [String: Int] = [:]
    /// `updatedAt` of each session when the user last saw it.
    private var seen: [String: EpochMillis]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "cn.agent.seenAt"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seen = (defaults.dictionary(forKey: key) as? [String: EpochMillis]) ?? [:]
    }

    /// True when the session has unread turns the user has not seen.
    public func isUnread(_ session: AgentSession) -> Bool {
        guard session.unread > 0, viewing[session.id] == nil else { return false }
        return session.updatedAt > (seen[session.id] ?? 0)
    }

    /// The chat for `sessionId` appeared.
    public func beginViewing(_ sessionId: String) {
        viewing[sessionId, default: 0] += 1
    }

    /// The chat for `sessionId` disappeared.
    public func endViewing(_ sessionId: String) {
        guard let n = viewing[sessionId] else { return }
        viewing[sessionId] = n > 1 ? n - 1 : nil
    }

    /// Marks the session seen up to `updatedAt`.
    public func markSeen(_ sessionId: String, at updatedAt: EpochMillis) {
        guard updatedAt > (seen[sessionId] ?? 0) else { return }
        seen[sessionId] = updatedAt
        defaults.set(seen, forKey: key)
    }
}
