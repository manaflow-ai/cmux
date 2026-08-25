import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent hook notification policy")
struct AgentHookNotificationPolicyTests {
    @Test func classificationTable() {
        let waiting = classify("waiting for input")
        #expect(waiting.status == .needsInput)
        #expect(waiting.notifyCategory == .idleReminder)

        let permission = classify("Grok needs permission to run rm")
        #expect(permission.status == .needsInput)
        #expect(permission.notifyCategory == .needsPermission)

        let error = classify("Build failed: exit 1")
        #expect(error.status == .error)
        #expect(error.notifyCategory == .other)

        // Quota exhaustion is the same red state as an error: the agent cannot
        // continue until the user does something about it.
        for quotaMessage in [
            "Grok usage limit reached",
            "You have hit the rate limit",
            "Monthly quota exhausted",
            "Out of credits",
        ] {
            let quota = classify(quotaMessage)
            #expect(quota.status == .error, "\(quotaMessage) must classify as error")
            #expect(quota.notifyCategory == .other, "\(quotaMessage) must stay ungated")
        }

        // A plain limit word without a usage/rate/quota qualifier is ordinary
        // prose, not a quota alert.
        let notQuota = classify("Reviewing the rate of change")
        #expect(notQuota.status != .error)

        let completion = classify("Turn complete in 1.2s.")
        #expect(completion.status == .idle)
        #expect(completion.notifyCategory == .turnComplete)

        let arbitrary = classify("Reviewing project files")
        #expect(arbitrary.status == nil)
        #expect(arbitrary.notifyCategory == .idleReminder)

        // An empty, cue-less message fabricates nothing: no needs-input
        // claim and no body (callers reuse a stored summary or skip the
        // banner). The old "%@ needs your attention" fallback is gone.
        let emptyFallback = AgentHookNotificationClassifier.classify(
            displayName: "Grok",
            signal: "",
            message: "",
            isFallback: true
        )
        #expect(emptyFallback.status == nil)
        #expect(emptyFallback.body.isEmpty)
        #expect(emptyFallback.isFallback == true)
    }

    @Test func dedupeFingerprintTable() {
        let first = fingerprint(status: .needsInput, body: "waiting for input")
        let same = fingerprint(status: .needsInput, body: "waiting for input")
        let different = fingerprint(status: .needsInput, body: "waiting for input again")

        #expect(first == same)
        #expect(first != different)
        #expect(fingerprint(status: .idle, body: "a") == "idle-turn")
        #expect(fingerprint(status: .idle, body: "b") == "idle-turn")
        let permissionFingerprint = AgentHookNotificationPolicy.dedupeFingerprint(
            agentName: "grok",
            sessionId: "session-1",
            status: .needsInput,
            category: .needsPermission,
            body: "permission"
        )
        #expect(permissionFingerprint == fingerprint(status: .needsInput, body: "permission"))
        #expect(permissionFingerprint?.hasPrefix("needsInput:") == true)
        #expect(AgentHookNotificationPolicy.dedupeFingerprint(
            agentName: "codex",
            sessionId: "session-1",
            status: .needsInput,
            category: .idleReminder,
            body: "waiting"
        ) == nil)
        #expect(AgentHookNotificationPolicy.dedupeFingerprint(
            agentName: "grok",
            sessionId: "",
            status: .needsInput,
            category: .idleReminder,
            body: "waiting"
        ) == nil)
        #expect(first == "needsInput:5ed8d1309a36515b")
    }

    @Test func metaRoundTripsWithAppGate() throws {
        let taggedCategories: [AgentHookNotifyCategory] = [.turnComplete, .needsPermission, .idleReminder]
        for category in taggedCategories {
            let metaSegment = try #require(category.metaSegment(pending: false))
            let parsed = try #require(AgentNotificationMeta(meta: metaSegment))
            #expect(parsed.category.rawValue == category.rawValue)
            #expect(parsed.pending == false)
        }
        #expect(AgentHookNotifyCategory.other.metaSegment(pending: false) == nil)

        // Extended meta with agent-event context round-trips through the
        // app-side parser field by field.
        for category in taggedCategories {
            let extended = try #require(category.metaSegment(
                pending: true,
                agentKind: "claude",
                isSubagent: true
            ))
            #expect(extended == "c=\(category.rawValue);p=1;a=claude;n=1")
            let parsed = try #require(AgentNotificationMeta(meta: extended))
            #expect(parsed.category.rawValue == category.rawValue)
            #expect(parsed.pending == true)
            #expect(parsed.agentKind == "claude")
            #expect(parsed.isSubagent == true)
        }

        // Nil context degrades to the legacy two-field form; an invalid slug
        // is dropped rather than poisoning the whole segment.
        #expect(AgentHookNotifyCategory.turnComplete.metaSegment(
            pending: false, agentKind: nil, isSubagent: nil
        ) == "c=turn-complete;p=0")
        #expect(AgentHookNotifyCategory.turnComplete.metaSegment(
            pending: false, agentKind: "Not A Slug", isSubagent: false
        ) == "c=turn-complete;p=0;n=0")
        #expect(AgentHookNotifyCategory.other.metaSegment(
            pending: false, agentKind: "claude", isSubagent: true
        ) == nil)

        #expect(agentNotificationShouldDeliver(
            category: .idleReminder,
            pending: false,
            permissionEnabled: true,
            turnMode: .always,
            idleEnabled: false
        ) == false)
        #expect(agentNotificationShouldDeliver(
            category: .needsPermission,
            pending: false,
            permissionEnabled: false,
            turnMode: .always,
            idleEnabled: true
        ) == false)
        #expect(agentNotificationShouldDeliver(
            category: .turnComplete,
            pending: false,
            permissionEnabled: true,
            turnMode: .never,
            idleEnabled: true
        ) == false)
    }

    @Test func piNotificationTitleIncludesSurfaceTitle() {
        #expect(
            AgentHookNotificationPolicy.notificationTitle(
                agentName: "pi",
                displayName: "Pi",
                surfaceTitle: "Pi Notification Session Titles"
            ) == "Pi · Pi Notification Session Titles"
        )
        #expect(
            AgentHookNotificationPolicy.notificationTitle(
                agentName: "pi",
                displayName: "Pi",
                surfaceTitle: nil
            ) == "Pi"
        )
        #expect(
            AgentHookNotificationPolicy.notificationTitle(
                agentName: "pi",
                displayName: "Pi",
                surfaceTitle: "pi · Build"
            ) == "pi · Build"
        )
        #expect(
            AgentHookNotificationPolicy.notificationTitle(
                agentName: "codex",
                displayName: "Codex",
                surfaceTitle: "Unrelated surface title"
            ) == "Codex"
        )
    }

    private func classify(_ message: String) -> AgentHookNotificationSummary {
        AgentHookNotificationClassifier.classify(
            displayName: "Grok",
            signal: "",
            message: message,
            isFallback: false
        )
    }

    private func fingerprint(status: AgentHookNotificationStatus?, body: String) -> String? {
        AgentHookNotificationPolicy.dedupeFingerprint(
            agentName: "grok",
            sessionId: "session-1",
            status: status,
            category: .idleReminder,
            body: body
        )
    }
}
