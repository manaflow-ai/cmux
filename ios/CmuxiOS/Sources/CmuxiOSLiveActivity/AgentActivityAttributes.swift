public import ActivityKit
public import CmuxFeedPushCore
import Foundation

/// A Live Activity for one running agent (c7-notify.md section 6). The
/// static part names what it follows; `ContentState` is what the feed owner
/// updates through the Activity's push token.
public struct AgentActivityAttributes: ActivityAttributes {
    public typealias ContentState = AgentActivityState

    /// The owner's activity id (`act_…`), the key of `notify.activity.*`.
    public var activityID: String
    public var subject: AgentActivitySubject
    /// The agent's display name ("Claude Code", "Codex").
    public var agent: String
    /// The workspace or host label shown under the agent name.
    public var place: String

    public init(activityID: String, subject: AgentActivitySubject, agent: String, place: String) {
        self.activityID = activityID
        self.subject = subject
        self.agent = agent
        self.place = place
    }

    /// The link a tap opens: the open request in needs-input, else the
    /// workspace (C16 router grammar, `cmux://`).
    public func link(for state: AgentActivityState) -> URL? {
        if state.phase == .needsInput, let item = state.item {
            return URL(string: "cmux://feed/\(item)")
        }
        return URL(string: "cmux://workspaces")
    }
}
