import CmuxAgentChat

/// Closure-backed recorder scoped to the app unit-test target.
struct AgentChatResumeIntentRecorder: AgentChatResumeIntentRecording {
    private let recordIntent: @MainActor (AgentChatResumeIntent) -> Void

    init(
        recordIntent: @escaping @MainActor (AgentChatResumeIntent) -> Void
    ) {
        self.recordIntent = recordIntent
    }

    @MainActor
    func record(_ intent: AgentChatResumeIntent) {
        recordIntent(intent)
    }
}
