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

        let completion = classify("Turn complete in 1.2s.")
        #expect(completion.status == .idle)
        #expect(completion.notifyCategory == .turnComplete)

        let arbitrary = classify("Reviewing project files")
        #expect(arbitrary.status == nil)
        #expect(arbitrary.notifyCategory == .idleReminder)

        let emptyFallback = agentHookClassifyNotification(
            displayName: "Grok",
            signal: "",
            message: "",
            isFallback: true
        )
        #expect(emptyFallback.status == .needsInput)
        #expect(emptyFallback.notifyCategory == .idleReminder)
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
        let permissionFingerprint = agentHookNotificationDedupeFingerprint(
            agentName: "grok",
            sessionId: "session-1",
            status: .needsInput,
            category: .needsPermission,
            body: "permission"
        )
        #expect(permissionFingerprint == fingerprint(status: .needsInput, body: "permission"))
        #expect(permissionFingerprint?.hasPrefix("needsInput:") == true)
        #expect(agentHookNotificationDedupeFingerprint(
            agentName: "codex",
            sessionId: "session-1",
            status: .needsInput,
            category: .idleReminder,
            body: "waiting"
        ) == nil)
        #expect(agentHookNotificationDedupeFingerprint(
            agentName: "grok",
            sessionId: "",
            status: .needsInput,
            category: .idleReminder,
            body: "waiting"
        ) == nil)
        #expect(first == "needsInput:5ed8d1309a36515b")
    }

    @Test func needsInputBannerSuppressionTable() {
        #expect(agentHookNotificationSuppressesNeedsInputBanner(agentName: "grok") == true)
        #expect(agentHookNotificationSuppressesNeedsInputBanner(agentName: "antigravity") == false)
        #expect(agentHookNotificationSuppressesNeedsInputBanner(agentName: "codex") == false)
        #expect(agentHookNotificationSuppressesNeedsInputBanner(agentName: "claude") == false)
    }

    @Test func storedStatusCategoryTable() {
        #expect(agentHookNotifyCategory(forStoredStatus: .idle) == .turnComplete)
        #expect(agentHookNotifyCategory(forStoredStatus: .needsInput) == .idleReminder)
        #expect(agentHookNotifyCategory(forStoredStatus: .error) == .other)
        #expect(agentHookNotifyCategory(forStoredStatus: nil) == .idleReminder)
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

    private func classify(_ message: String) -> AgentHookNotificationSummary {
        agentHookClassifyNotification(
            displayName: "Grok",
            signal: "",
            message: message,
            isFallback: false
        )
    }

    private func fingerprint(status: AgentHookNotificationStatus?, body: String) -> String? {
        agentHookNotificationDedupeFingerprint(
            agentName: "grok",
            sessionId: "session-1",
            status: status,
            category: .idleReminder,
            body: body
        )
    }
}
