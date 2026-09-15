import CmuxAgentJournal
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
            // A resolution can release a delayed completion: render the event the
            // reconciler accepted, which is not always the input.
            let accepted = (decision.notificationEvent ?? event).draft
            guard decision.disposition == .accepted, let identity = decision.identity,
                  try store.claimNotification(identity: identity),
                  let rendered = Self.presentation(accepted) else { return [] }
            return [rendered]
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
