import CmuxAgentJournal
import CmuxAgentHooks
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The hook socket fixtures run production reconciliation and durable admission.
/// Their command trace includes the accepted notification effect in the historical
/// presentation format, so routing/content assertions cover either wire transport.
final class AgentHookTestNotificationPipeline {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var store: AgentJournalStore?
    private var reconciler = AgentNotificationReconciler()
    private(set) var admittedCorrelationKeys: [String] = []

    deinit {
        store?.close()
        try? FileManager.default.removeItem(at: root)
    }

    func effects(for command: String) -> [String] {
        guard let draft = Self.draft(command) else { return [] }
        do {
            if store == nil { store = try AgentJournalStore(databaseURL: root.appendingPathComponent("journal.sqlite")) }
            guard let store else { return [] }
            let outcome = try store.append(draft)
            let event = AgentJournalEvent(sequence: outcome.sequence, committedAtMs: outcome.committedAtMs, draft: draft)
            let decision = reconciler.apply(event)
            let invalidations: [String]
            if let workspace = draft.workspaceId, let surface = draft.surfaceId {
                invalidations = decision.invalidatedCorrelationKeys.map {
                    "clear_notifications --tab=\(workspace) --panel=\(surface) --correlation-key=\($0)"
                }
            } else {
                invalidations = []
            }
            // A resolution can release a delayed completion: render the event the
            // reconciler accepted, which is not always the input.
            let accepted = (decision.notificationEvent ?? event).draft
            guard decision.disposition == .accepted, let identity = decision.identity,
                  try store.claimNotification(identity: identity),
                  let rendered = Self.presentation(accepted) else { return invalidations }
            admittedCorrelationKeys.append(accepted.attention?.notification?.correlationKey ?? identity)
            return invalidations + [rendered]
        } catch {
            Issue.record("Hook fixture journal failed: \(error)")
            return []
        }
    }

    /// Candidate inspection remains separate from delivery assertions for tests
    /// that verify pending-work metadata sent by the real CLI.
    static func candidatePresentation(_ command: String) -> String? {
        draft(command).flatMap(presentation)
    }

    private static func draft(_ command: String) -> AgentJournalEventDraft? {
        let prefix = "agent_journal_append "
        guard command.hasPrefix(prefix) else { return nil }
        return try? JSONDecoder().decode(AgentJournalEventDraft.self, from: Data(command.dropFirst(prefix.count).utf8))
    }

    private static func presentation(_ draft: AgentJournalEventDraft) -> String? {
        guard let candidate = draft.attention?.notification,
              let workspace = draft.workspaceId, let surface = draft.surfaceId else { return nil }
        let fields = [candidate.title, candidate.subtitle, candidate.body].map {
            $0.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "|", with: "¦")
        }
        let base = "notify_target_async \(workspace) \(surface) " + fields.joined(separator: "|")
        if draft.kind == .messagePublished { return base }
        var meta = "c=\(candidate.category);p=\(draft.pendingWork ? 1 : 0);a=\(draft.source);n=\(draft.isSubagent ? 1 : 0)"
        let sound: NotificationSoundAlertType? = draft.kind == .errorReported ? .errorStalled
            : AgentNotifyCategory(rawValue: candidate.category)?.soundAlertType
        if let sound { meta += ";s=\(sound.rawValue)" }
        if let key = candidate.correlationKey { meta += ";k=\(key)" }
        return base + "|" + meta
    }
}

#if canImport(cmux_DEV) || canImport(cmux)
struct AgentHookNotificationClassifierRegressionTests {
    @Test(arguments: [
        ("Claude Code", "API Error: 529 overloaded_error: Overloaded", "Model at capacity"),
        ("Claude Code", "overloaded", "Model at capacity"),
        ("Claude Code", "529", "Model at capacity"),
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

    @Test func embeddedHTTPStatusCodesDoNotClassifyAsProviderFailures() {
        let classifier = AgentHookAbnormalStopClassifier()
        let cases = [
            "request_id=req-429-attempt",
            "correlation_id=abc529xyz error details omitted",
        ]

        for message in cases {
            #expect(
                classifier.abnormalStopClass(signal: "Stop", message: message) == nil,
                "A status-looking substring inside an identifier must not classify: \(message)"
            )
        }
    }

    @Test func ordinaryQuotaProseIsNotClassifiedAsAProviderFailure() {
        let classifier = AgentHookAbnormalStopClassifier()
        let message = "The report says quota exceeded for a previous run."

        #expect(
            classifier.abnormalStopClass(signal: "Stop", message: message) == nil,
            "Ordinary prose mentioning quota exceeded must fail closed"
        )
    }

    @Test func exactStopReasonBannersRemainClassifiedAfterStopPrefixing() {
        let classifier = AgentHookAbnormalStopClassifier()

        #expect(
            classifier.abnormalStopClass(signal: "Stop quota exceeded", message: "Stop quota exceeded") == .quota,
            "A structured quota reason must remain classifiable when the adapter prefixes Stop"
        )
        #expect(
            classifier.abnormalStopClass(signal: "Stop 429", message: "Stop 429") == .rateLimit,
            "A structured 429 reason must remain classifiable when the adapter prefixes Stop"
        )
        #expect(
            classifier.abnormalStopClass(signal: "Stop 529", message: "Stop 529") == .capacity,
            "A structured 529 reason must remain classifiable when the adapter prefixes Stop"
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

}
#endif
