import CmuxAgentReplica
import CmuxAgentWire
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct AgentGUISendLedgerTests {
    @Test func resubmittingKnownTicketDoesNotInjectAgain() throws {
        var now = 1_000
        let injector = FakeAgentGUITerminalInjector()
        var published: [SendTicket] = []
        let ledger = AgentGUISendLedger(
            sessionID: Self.sessionID,
            clock: { now },
            injector: injector,
            publish: { published.append($0) }
        )
        let ticketID = UUID()

        let first = try ledger.submit(ticketID: ticketID, text: "hello", attachmentCount: 0, snapshot: Self.snapshot())
        now += 1
        let second = try ledger.submit(ticketID: ticketID, text: "hello again", attachmentCount: 0, snapshot: Self.snapshot())

        #expect(first == GuiSendResult(accepted: true, queuedOnMac: false))
        #expect(second == GuiSendResult(accepted: true, queuedOnMac: false))
        #expect(injector.prompts == ["hello"])
        #expect(published.map(\.state) == [.acceptedByMac, .injected])
    }

    @Test func queuedTicketsInjectOnePerIdleTransitionInFIFOOrder() throws {
        let injector = FakeAgentGUITerminalInjector()
        var published: [SendTicket] = []
        let ledger = AgentGUISendLedger(
            sessionID: Self.sessionID,
            clock: { 1_000 },
            injector: injector,
            publish: { published.append($0) }
        )
        let firstID = UUID()
        let secondID = UUID()

        let first = try ledger.submit(ticketID: firstID, text: "first", attachmentCount: 0, snapshot: Self.snapshot(phase: .working))
        let second = try ledger.submit(ticketID: secondID, text: "second", attachmentCount: 0, snapshot: Self.snapshot(phase: .working))
        ledger.handleSessionSnapshot(Self.snapshot(phase: .idle))
        ledger.handleSessionSnapshot(Self.snapshot(phase: .idle))
        ledger.handleSessionSnapshot(Self.snapshot(phase: .working))
        ledger.handleSessionSnapshot(Self.snapshot(phase: .idle))

        #expect(first == GuiSendResult(accepted: true, queuedOnMac: true))
        #expect(second == GuiSendResult(accepted: true, queuedOnMac: true))
        #expect(injector.prompts == ["first", "second"])
        #expect(published.filter { $0.state == .injected }.map(\.text) == ["first", "second"])
    }

    @Test func idleSubmitQueuesBehindOlderAcceptedTicket() throws {
        let injector = FakeAgentGUITerminalInjector()
        let ledger = AgentGUISendLedger(
            sessionID: Self.sessionID,
            clock: { 1_000 },
            injector: injector,
            publish: { _ in }
        )
        _ = try ledger.submit(ticketID: UUID(), text: "first", attachmentCount: 0, snapshot: Self.snapshot(phase: .working))
        _ = try ledger.submit(ticketID: UUID(), text: "second", attachmentCount: 0, snapshot: Self.snapshot(phase: .working))
        ledger.handleSessionSnapshot(Self.snapshot(phase: .idle))

        let third = try ledger.submit(ticketID: UUID(), text: "third", attachmentCount: 0, snapshot: Self.snapshot(phase: .idle))

        #expect(third == GuiSendResult(accepted: true, queuedOnMac: true))
        #expect(injector.prompts == ["first"])
        ledger.handleSessionSnapshot(Self.snapshot(phase: .working))
        ledger.handleSessionSnapshot(Self.snapshot(phase: .idle))
        ledger.handleSessionSnapshot(Self.snapshot(phase: .working))
        ledger.handleSessionSnapshot(Self.snapshot(phase: .idle))
        #expect(injector.prompts == ["first", "second", "third"])
    }

    @Test func needsInputSubmitInjectsImmediately() throws {
        let injector = FakeAgentGUITerminalInjector()
        let ledger = AgentGUISendLedger(
            sessionID: Self.sessionID,
            clock: { 1_000 },
            injector: injector,
            publish: { _ in }
        )

        let result = try ledger.submit(
            ticketID: UUID(),
            text: "the awaited answer",
            attachmentCount: 0,
            snapshot: Self.snapshot(phase: .needsInput)
        )

        #expect(result == GuiSendResult(accepted: true, queuedOnMac: false))
        #expect(injector.prompts == ["the awaited answer"])
    }

    @Test func workingQueueDrainsBeforeNeedsInputReplyInjects() throws {
        let injector = FakeAgentGUITerminalInjector()
        let ledger = AgentGUISendLedger(
            sessionID: Self.sessionID,
            clock: { 1_000 },
            injector: injector,
            publish: { _ in }
        )

        let queued = try ledger.submit(
            ticketID: UUID(),
            text: "queued while working",
            attachmentCount: 0,
            snapshot: Self.snapshot(phase: .working)
        )
        ledger.handleSessionSnapshot(Self.snapshot(phase: .needsInput))
        let reply = try ledger.submit(
            ticketID: UUID(),
            text: "the awaited answer",
            attachmentCount: 0,
            snapshot: Self.snapshot(phase: .needsInput)
        )

        #expect(queued == GuiSendResult(accepted: true, queuedOnMac: true))
        #expect(reply == GuiSendResult(accepted: true, queuedOnMac: false))
        #expect(injector.prompts == ["queued while working", "the awaited answer"])
    }

    @Test func echoMatchingUsesOldestInjectedTicketAndWhitespaceFallback() throws {
        let injector = FakeAgentGUITerminalInjector()
        var published: [SendTicket] = []
        let ledger = AgentGUISendLedger(
            sessionID: Self.sessionID,
            clock: { 1_000 },
            injector: injector,
            publish: { published.append($0) }
        )
        let firstID = UUID()
        let secondID = UUID()
        _ = try ledger.submit(ticketID: firstID, text: "first prompt", attachmentCount: 0, snapshot: Self.snapshot())
        _ = try ledger.submit(ticketID: secondID, text: "second   prompt", attachmentCount: 0, snapshot: Self.snapshot())

        ledger.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.userEntry(seq: 1, text: "second prompt")]))
        ledger.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.userEntry(seq: 2, text: "first prompt")]))
        ledger.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.userEntry(seq: 3, text: "second prompt")]))

        let echoed = published.compactMap { ticket -> (String, EntrySeq)? in
            if case .echoed(let seq) = ticket.state {
                return (ticket.text, seq)
            }
            return nil
        }
        #expect(echoed.map(\.0) == ["first prompt", "second   prompt"])
        #expect(echoed.map(\.1) == [EntrySeq(rawValue: 2), EntrySeq(rawValue: 3)])
    }

    @Test func duplicateJournalDeltaDoesNotEchoNextIdenticalTicket() throws {
        let injector = FakeAgentGUITerminalInjector()
        var published: [SendTicket] = []
        let ledger = AgentGUISendLedger(
            sessionID: Self.sessionID,
            clock: { 1_000 },
            injector: injector,
            publish: { published.append($0) }
        )
        _ = try ledger.submit(ticketID: UUID(), text: "same", attachmentCount: 0, snapshot: Self.snapshot())
        _ = try ledger.submit(ticketID: UUID(), text: "same", attachmentCount: 0, snapshot: Self.snapshot())
        let firstDelta = AgentGUIJournalPipelineEvent.appended(
            journalID: Self.journalID,
            entries: [Self.userEntry(seq: 1, text: "same")]
        )

        ledger.handleJournalEvent(firstDelta)
        ledger.handleJournalEvent(firstDelta)

        let echoedAfterDuplicate = published.filter {
            if case .echoed = $0.state { return true }
            return false
        }
        #expect(echoedAfterDuplicate.count == 1)
        ledger.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.userEntry(seq: 2, text: "same")]))
        let echoedSequences = published.compactMap { ticket -> EntrySeq? in
            if case .echoed(let seq) = ticket.state { return seq }
            return nil
        }
        #expect(echoedSequences == [EntrySeq(rawValue: 1), EntrySeq(rawValue: 2)])
    }

    @Test func duplicateForeignDeltaCountsOnceTowardUnconfirmed() throws {
        let injector = FakeAgentGUITerminalInjector()
        var published: [SendTicket] = []
        let ledger = AgentGUISendLedger(
            sessionID: Self.sessionID,
            clock: { 1_000 },
            injector: injector,
            publish: { published.append($0) }
        )
        _ = try ledger.submit(ticketID: UUID(), text: "pending", attachmentCount: 0, snapshot: Self.snapshot())
        let duplicate = AgentGUIJournalPipelineEvent.appended(
            journalID: Self.journalID,
            entries: [Self.userEntry(seq: 1, text: "foreign")]
        )

        ledger.handleJournalEvent(duplicate)
        ledger.handleJournalEvent(duplicate)
        ledger.handleJournalEvent(duplicate)
        ledger.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.userEntry(seq: 2, text: "foreign")]))
        #expect(published.last?.state == .injected)

        ledger.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.userEntry(seq: 3, text: "foreign")]))
        #expect(published.last?.state == .unconfirmed)
    }

    @Test func injectionExpiresToUnconfirmedAfterTimeoutAndForeignAppends() throws {
        var now = 10_000
        let injector = FakeAgentGUITerminalInjector()
        var published: [SendTicket] = []
        let ledger = AgentGUISendLedger(
            sessionID: Self.sessionID,
            clock: { now },
            injector: injector,
            publish: { published.append($0) }
        )
        _ = try ledger.submit(ticketID: UUID(), text: "timeout", attachmentCount: 0, snapshot: Self.snapshot())
        now += AgentGUIConstants.sendEchoTimeoutMS
        ledger.expire()
        #expect(published.last?.state == .unconfirmed)

        published.removeAll()
        now += 1
        _ = try ledger.submit(ticketID: UUID(), text: "foreign", attachmentCount: 0, snapshot: Self.snapshot())
        for seq in 1...3 {
            ledger.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.userEntry(seq: seq, text: "other \(seq)")]))
        }
        #expect(published.last?.state == .unconfirmed)
    }

    @Test func resolvedTicketsExpireWithoutBeingResubmitted() throws {
        var now = 1_000
        let injector = FakeAgentGUITerminalInjector()
        let ledger = AgentGUISendLedger(
            sessionID: Self.sessionID,
            clock: { now },
            injector: injector,
            publish: { _ in }
        )
        _ = try ledger.submit(ticketID: UUID(), text: "done", attachmentCount: 0, snapshot: Self.snapshot())
        ledger.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.userEntry(seq: 1, text: "done")]))
        #expect(ledger.retainedRecordCount == 1)

        now += AgentGUIConstants.sendTicketIdempotencyWindowMS
        ledger.expire()

        #expect(ledger.retainedRecordCount == 0)
    }

    @Test func resolvedTicketRetentionHasAHardBound() throws {
        var now = 1_000
        let injector = FakeAgentGUITerminalInjector()
        let ledger = AgentGUISendLedger(
            sessionID: Self.sessionID,
            clock: { now },
            injector: injector,
            publish: { _ in }
        )
        for index in 1...(AgentGUIConstants.resolvedSendTicketRetentionLimit + 20) {
            let text = "prompt \(index)"
            _ = try ledger.submit(ticketID: UUID(), text: text, attachmentCount: 0, snapshot: Self.snapshot())
            ledger.handleJournalEvent(.appended(
                journalID: Self.journalID,
                entries: [Self.userEntry(seq: index, text: text)]
            ))
            now += 1
        }

        #expect(ledger.retainedRecordCount == AgentGUIConstants.resolvedSendTicketRetentionLimit)
    }

    @Test func unboundSessionFailsWithBindingLostTicketState() {
        let injector = FakeAgentGUITerminalInjector()
        var published: [SendTicket] = []
        let ledger = AgentGUISendLedger(
            sessionID: Self.sessionID,
            clock: { 1_000 },
            injector: injector,
            publish: { published.append($0) }
        )

        do {
            _ = try ledger.submit(ticketID: UUID(), text: "hello", attachmentCount: 0, snapshot: Self.snapshot(surfaceID: nil))
            Issue.record("unbound session should throw")
        } catch let error as AgentGUIRPCError {
            #expect(error.code == "binding_lost")
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        guard case .failed(let code)? = published.last?.state else {
            Issue.record("last published ticket should be failed")
            return
        }
        #expect(code == "binding_lost")
        #expect(injector.prompts.isEmpty)
    }

    @Test func endedSessionFailsQueuedTicketsWithProcessExited() throws {
        let injector = FakeAgentGUITerminalInjector()
        var published: [SendTicket] = []
        let ledger = AgentGUISendLedger(
            sessionID: Self.sessionID,
            clock: { 1_000 },
            injector: injector,
            publish: { published.append($0) }
        )
        _ = try ledger.submit(ticketID: UUID(), text: "first", attachmentCount: 0, snapshot: Self.snapshot(phase: .working))
        _ = try ledger.submit(ticketID: UUID(), text: "second", attachmentCount: 0, snapshot: Self.snapshot(phase: .working))

        ledger.handleSessionSnapshot(Self.snapshot(phase: .ended))

        let failures = published.compactMap { ticket -> String? in
            if case .failed(let code) = ticket.state { return code }
            return nil
        }
        #expect(failures == ["process_exited", "process_exited"])
        #expect(injector.prompts.isEmpty)
    }

    private static let sessionID = AgentSessionID(rawValue: "session-1")
    private static let journalID = JournalID(rawValue: "journal-1")
    private static let surfaceID = UUID().uuidString

    private static func snapshot(phase: SessionPhase = .idle) -> AgentSessionSnapshot {
        snapshot(phase: phase, surfaceID: Self.surfaceID)
    }

    private static func snapshot(phase: SessionPhase = .idle, surfaceID: String?) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: Self.sessionID,
            macDeviceID: MacDeviceID(rawValue: "mac-1"),
            kind: .codex,
            phase: phase,
            tier: .wrapped,
            surfaceID: surfaceID,
            cwd: "/repo",
            title: "Session",
            workspaceName: "Workspace",
            version: EntityVersion(rawValue: 1),
            lastActivityHint: 1
        )
    }

    private static func userEntry(seq: Int, text: String) -> EntrySnapshot {
        EntrySnapshot(
            journalID: Self.journalID,
            seq: EntrySeq(rawValue: seq),
            kind: .userMessage,
            content: EntryContent(
                contentHash: seq,
                payload: .userMessage(UserMessagePayload(text: text, attachmentCount: 0, hasImage: false))
            ),
            version: EntityVersion(rawValue: 1)
        )
    }
}

@MainActor
private final class FakeAgentGUITerminalInjector: AgentGUITerminalInjecting {
    var prompts: [String] = []
    var keys: [String] = []
    var inputs: [String] = []
    var result: AgentGUITerminalInjectionResult = .accepted

    func submitPrompt(surfaceID: String, text: String) -> AgentGUITerminalInjectionResult {
        prompts.append(text)
        return result
    }

    func sendKey(surfaceID: String, keyName: String) -> AgentGUITerminalInjectionResult {
        keys.append(keyName)
        return result
    }

    func sendInput(surfaceID: String, text: String) -> AgentGUITerminalInjectionResult {
        inputs.append(text)
        return result
    }
}
