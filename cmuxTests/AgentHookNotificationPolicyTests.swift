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

        let permissionWithUserWording = AgentHookNotificationClassifier.classify(
            displayName: "Grok",
            signal: "Notification",
            message: "Approve the command the user requested",
            isFallback: false
        )
        #expect(permissionWithUserWording.status == .needsInput)
        #expect(permissionWithUserWording.notifyCategory == .needsPermission)

        let error = classify("Build failed: exit 1")
        #expect(error.status == .error)
        #expect(error.notifyCategory == .other)

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

    @Test(arguments: [
        ("Claude Code", "API Error: 529 overloaded_error: Overloaded", "Model at capacity"),
        ("Claude Code", "You've hit your usage limit. Please try again later.", "Quota exhausted"),
        ("Claude Code", "429 rate_limit_error: Rate limit exceeded", "Rate limited"),
        ("Codex", "Selected model is at capacity. Please try a different model.", "Model at capacity"),
        ("Codex", "server overloaded", "Model at capacity"),
        ("Codex", "quota exceeded", "Quota exhausted"),
        ("Codex", "429 Too Many Requests: rate limit exceeded", "Rate limited"),
        ("Codex", "■ request timed out", "Request timed out"),
        ("Claude Code", "■ request timed out", "Request timed out"),
        ("Codex", "Your authentication token has expired", "Authentication error"),
        ("Codex", "network error: connection reset", "Network error"),
    ])
    func providerAbnormalStopBannersAreUngatedErrors(
        displayName: String,
        banner: String,
        expectedSubtitle: String
    ) {
        let summary = AgentHookNotificationClassifier.classify(
            displayName: displayName,
            signal: "Stop",
            message: banner,
            isFallback: false
        )

        #expect(summary.status == .error)
        #expect(summary.notifyCategory == .other)
        #expect(summary.subtitle == expectedSubtitle)
        #expect(summary.body.contains("Try again"))
        #expect(!summary.body.contains(banner))
        #expect(agentNotificationShouldDeliver(
            category: .other,
            pending: false,
            permissionEnabled: false,
            turnMode: .never,
            idleEnabled: false
        ))
    }

    @Test func genericStopRejectsHistoricalFailureProse() {
        let classifier = AgentHookAbnormalStopClassifier()
        let messages = [
            "No error was reported; the task completed successfully.",
            "The previous attempt failed, but this retry succeeded.",
            "The operation finished error-free.",
        ]

        for message in messages {
            #expect(
                classifier.summary(
                    displayName: "Grok",
                    signal: "Stop",
                    message: message,
                    isFallback: false
                ) == nil,
                "Historical or negated failure prose must not become a generic provider error: \(message)"
            )
        }
    }

    @Test func localCapacityProseIsNotAnUngatedProviderError() {
        let message = "The local job queue is at capacity"
        let classifier = AgentHookAbnormalStopClassifier()

        #expect(classifier.abnormalStopClass(signal: "Stop", message: message) == nil)
        #expect(
            AgentHookNotificationClassifier.classify(
                displayName: "Grok",
                signal: "Stop",
                message: message,
                isFallback: false
            ).notifyCategory != .other
        )
    }

    @Test func providerErrorBodyRedactsDiagnostics() throws {
        let raw = #"API Error: request_id=abc123 Authorization: Bearer secret-value stack trace at Provider.call() payload={"token":"secret"}"#
        let summary = try #require(
            AgentHookAbnormalStopClassifier().summary(
                displayName: "Agent",
                signal: "Stop",
                message: raw,
                isFallback: false
            )
        )

        #expect(summary.status == .error)
        #expect(summary.body != raw)
        #expect(!summary.body.contains("request_id"))
        #expect(!summary.body.contains("Authorization"))
        #expect(!summary.body.contains("secret-value"))
        #expect(summary.body.contains("Try again"))
    }

    @Test func userInterruptAndNormalCompletionDoNotBecomeAbnormalErrors() {
        let interrupted = AgentHookNotificationClassifier.classify(
            displayName: "Codex",
            signal: "Stop",
            message: "Interrupted by user (Ctrl+C)",
            isFallback: false
        )
        #expect(interrupted.status != .error)
        #expect(interrupted.notifyCategory != .other)

        let staleErrorOnInterrupt = AgentHookNotificationClassifier.classify(
            displayName: "Codex",
            signal: "Stop user_interrupt",
            message: "Selected model is at capacity, but the user pressed Ctrl+C",
            isFallback: false
        )
        #expect(staleErrorOnInterrupt.status != .error)
        #expect(staleErrorOnInterrupt.notifyCategory != .other)

        let completed = AgentHookNotificationClassifier.classify(
            displayName: "Claude Code",
            signal: "Stop",
            message: "Done",
            isFallback: false
        )
        #expect(completed.status == .idle)
        #expect(completed.notifyCategory == .turnComplete)

        let ambiguous = AgentHookNotificationClassifier.classify(
            displayName: "Codex",
            signal: "Notification",
            message: "The server is overloaded with work",
            isFallback: false
        )
        #expect(ambiguous.status != .error)
        #expect(ambiguous.notifyCategory != .other)

        let completedAfterRetry = AgentHookNotificationClassifier.classify(
            displayName: "Codex",
            signal: "Stop",
            message: "The first request timed out, but the retry completed successfully.",
            isFallback: false
        )
        #expect(completedAfterRetry.status == .idle)
        #expect(completedAfterRetry.notifyCategory == .turnComplete)

        let ordinaryOverloadProse = AgentHookNotificationClassifier.classify(
            displayName: "Codex",
            signal: "Stop",
            message: "The queue was overloaded earlier; the requested work is done.",
            isFallback: false
        )
        #expect(ordinaryOverloadProse.status == .idle)
        #expect(ordinaryOverloadProse.notifyCategory == .turnComplete)

        let localTimeoutProse = AgentHookNotificationClassifier.classify(
            displayName: "Codex",
            signal: "Stop",
            message: "The integration test timed out, so I raised the limit.",
            isFallback: false
        )
        #expect(localTimeoutProse.status != .error)
        #expect(localTimeoutProse.notifyCategory != .other)

        let localThrottleProse = AgentHookNotificationClassifier.classify(
            displayName: "Codex",
            signal: "Stop",
            message: "The local command was throttled by the test harness.",
            isFallback: false
        )
        #expect(localThrottleProse.status != .error)
        #expect(localThrottleProse.notifyCategory != .other)
    }

    @Test func codexBannerClassifierRejectsSiblingUserInterrupt() {
        let classifier = AgentHookAbnormalStopClassifier()
        let providerBanner = "Selected model is at capacity. Please try a different model."
        let siblingInterrupt = "Interrupted by user (Ctrl+C)"

        #expect(
            classifier.abnormalStopClass(signal: "Stop", message: providerBanner) == .capacity,
            "The provider banner remains recognizable on its own"
        )
        #expect(
            classifier.isUserInitiatedStop(
                signal: "Stop",
                message: "\(providerBanner) \(siblingInterrupt)"
            ),
            "A user interrupt in a sibling payload field must suppress a stale Codex provider banner"
        )
        #expect(
            classifier.summary(
                displayName: "Codex",
                signal: "Stop",
                message: "\(providerBanner) \(siblingInterrupt)",
                isFallback: false
            ) == nil,
            "The aggregate stop classifier must fail closed when any sibling field records a user abort"
        )
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
                isSubagent: true,
                correlationKey: "11111111-1111-1111-1111-111111111111"
            ))
            #expect(extended == "c=\(category.rawValue);p=1;a=claude;n=1;k=11111111-1111-1111-1111-111111111111")
            let parsed = try #require(AgentNotificationMeta(meta: extended))
            #expect(parsed.category.rawValue == category.rawValue)
            #expect(parsed.pending == true)
            #expect(parsed.agentKind == "claude")
            #expect(parsed.isSubagent == true)
            #expect(parsed.correlationKey == "11111111-1111-1111-1111-111111111111")
        }

        // Nil context degrades to the legacy two-field form; an invalid slug
        // is dropped rather than poisoning the whole segment.
        #expect(AgentHookNotifyCategory.turnComplete.metaSegment(
            pending: false, agentKind: nil, isSubagent: nil
        ) == "c=turn-complete;p=0")
        #expect(AgentHookNotifyCategory.turnComplete.metaSegment(
            pending: false, agentKind: "Not A Slug", isSubagent: false
        ) == "c=turn-complete;p=0;n=0")
        #expect(AgentHookNotifyCategory.turnComplete.metaSegment(
            pending: false,
            agentKind: nil,
            isSubagent: nil,
            correlationKey: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        ) == "c=turn-complete;p=0;k=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
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

    @Test func cursorNativeApprovalCandidateHonorsKnownLocalModes() {
        let payload: [String: Any] = [
            "command": "git status --short",
            "sandbox": false,
        ]
        #expect(
            AgentHookNotificationPolicy.shouldRequestCursorNativeApproval(
                payload: payload,
                approvalMode: "unrestricted"
            ) == false
        )
        #expect(
            AgentHookNotificationPolicy.shouldRequestCursorNativeApproval(
                payload: payload,
                approvalMode: "auto-review"
            ) == false
        )
        #expect(
            AgentHookNotificationPolicy.shouldRequestCursorNativeApproval(
                payload: payload
            ) == false
        )
        #expect(
            AgentHookNotificationPolicy.shouldRequestCursorNativeApproval(
                payload: payload,
                approvalMode: "allowlist",
                allowedShellCommands: ["Shell(git *)"]
            ) == false
        )
        #expect(
            AgentHookNotificationPolicy.shouldRequestCursorNativeApproval(
                payload: payload,
                approvalMode: "allowlist",
                allowedShellCommands: ["Shell(git)"]
            ) == false
        )
        #expect(
            AgentHookNotificationPolicy.shouldRequestCursorNativeApproval(
                payload: [
                    "command": "/tmp/git status --short",
                    "sandbox": false,
                ],
                approvalMode: "allowlist",
                allowedShellCommands: ["Shell(git)"]
            ) == true
        )
        #expect(
            AgentHookNotificationPolicy.shouldRequestCursorNativeApproval(
                payload: payload,
                approvalMode: "allowlist",
                allowedShellCommands: ["Shell(git status)"]
            ) == false
        )
        #expect(
            AgentHookNotificationPolicy.shouldRequestCursorNativeApproval(
                payload: [
                    "command": "curl https://example.com",
                    "sandbox": false,
                ],
                approvalMode: "allowlist",
                allowedShellCommands: ["Shell(curl:*)"]
            ) == false
        )
        #expect(
            AgentHookNotificationPolicy.shouldRequestCursorNativeApproval(
                payload: payload,
                approvalMode: "allowlist",
                deniedShellCommands: ["Shell(git)"]
            ) == false
        )
        #expect(
            AgentHookNotificationPolicy.shouldRequestCursorNativeApproval(
                payload: payload,
                approvalMode: "allowlist",
                allowedShellCommands: ["Shell(ls)"]
            ) == true
        )
        #expect(
            AgentHookNotificationPolicy.shouldRequestCursorNativeApproval(
                payload: ["command": "git status --short", "sandbox": false],
                approvalMode: "allowlist",
                allowedShellCommands: ["Shell(g*:status)"]
            ) == false
        )
        #expect(
            AgentHookNotificationPolicy.shouldRequestCursorNativeApproval(
                payload: ["command": "printf 'a  b'", "sandbox": false],
                approvalMode: "allowlist",
                allowedShellCommands: ["Shell(printf:'a b')"]
            ) == true
        )
        #expect(
            AgentHookNotificationPolicy.shouldRequestCursorNativeApproval(
                payload: ["command": "git status --short", "sandbox": true]
            ) == false
        )
        #expect(
            AgentHookNotificationPolicy.shouldRequestCursorNativeApproval(
                payload: ["command": "git status --short", "sandbox": "false"],
                approvalMode: "allowlist"
            ) == false
        )
    }

    @Test func cursorApprovalModeOverrideParsesFlagForms() {
        #expect(
            AgentHookNotificationPolicy.cursorApprovalModeOverride(
                arguments: ["cursor-agent", "--mode", "unrestricted"]
            ) == "unrestricted"
        )
        #expect(
            AgentHookNotificationPolicy.cursorApprovalModeOverride(
                arguments: ["cursor-agent", "--mode=auto-review"]
            ) == "auto-review"
        )
        #expect(
            AgentHookNotificationPolicy.cursorApprovalModeOverride(
                arguments: ["cursor-agent", "--mode", "unknown"]
            ) == nil
        )
        #expect(
            AgentHookNotificationPolicy.cursorApprovalModeOverride(
                arguments: ["cursor-agent", "--", "--mode=unrestricted"]
            ) == nil
        )
    }

    @Test func cursorCommandPreviewRedactsHeaderAndFlagCredentials() {
        let command = "curl -H 'X-Api-Key: shortsecret' -H 'Authorization: Basic hunter2' --api-key shortsecret --secret-access-key shortsecret --token shorttoken AWS_SECRET_ACCESS_KEY=abc123 -u alice:s3cr3t redis-cli -a s3cr3t mysql -psecret openssl -pass pass:hunter2 gpg --passphrase hunter2"
        let redacted = AgentHookNotificationPolicy.redactSensitiveCommand(command)

        #expect(!redacted.contains("shortsecret"))
        #expect(!redacted.contains("shorttoken"))
        #expect(!redacted.contains("abc123"))
        #expect(!redacted.contains("alice:s3cr3t"))
        #expect(!redacted.contains("s3cr3t"))
        #expect(!redacted.contains("hunter2"))
        #expect(redacted.contains("<credential>:<token>"))
        #expect(redacted.contains("<credential>=<token>"))
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
