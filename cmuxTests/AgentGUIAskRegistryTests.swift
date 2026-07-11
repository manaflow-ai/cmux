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
struct AgentGUIAskRegistryTests {
    @Test func entryBeforeNeedsInputCreatesAskOnPhaseTransition() {
        let injector = FakeAskRegistryInjector()
        var published: [PendingAsk] = []
        let registry = AgentGUIAskRegistry(clock: { 1_000 }, injector: injector, publish: { published.append($0) })

        registry.handleSessionSnapshot(Self.snapshot(phase: .working))
        registry.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.questionEntry(seq: 1)]), sessionID: Self.sessionID)
        #expect(published.isEmpty)

        registry.handleSessionSnapshot(Self.snapshot(phase: .needsInput))

        #expect(published.count == 1)
        #expect(published.first?.id == AgentGUIAskRegistry.askID(journalID: Self.journalID, seq: EntrySeq(rawValue: 1)))
        #expect(published.first?.kind == .question)
        #expect(published.first?.state == .active)
    }

    @Test func createsQuestionAndPermissionAsksWhileNeedsInput() {
        let injector = FakeAskRegistryInjector()
        var published: [PendingAsk] = []
        let registry = AgentGUIAskRegistry(clock: { 1_000 }, injector: injector, publish: { published.append($0) })
        registry.handleSessionSnapshot(Self.snapshot(phase: .needsInput))

        registry.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.questionEntry(seq: 1)]), sessionID: Self.sessionID)
        registry.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.permissionEntry(seq: 2)]), sessionID: Self.sessionID)

        let activeAsks = published.filter { $0.state == .active }
        #expect(activeAsks.map(\.kind) == [.question, .permission])
        #expect(activeAsks.map(\.optionsCount) == [2, 2])
    }

    @Test func answerSendsOneBasedDigitAndIsIdempotent() throws {
        let injector = FakeAskRegistryInjector()
        var published: [PendingAsk] = []
        let registry = AgentGUIAskRegistry(clock: { 1_000 }, injector: injector, publish: { published.append($0) })
        registry.handleSessionSnapshot(Self.snapshot(phase: .needsInput))
        registry.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.questionEntry(seq: 1)]), sessionID: Self.sessionID)
        let askID = AgentGUIAskRegistry.askID(journalID: Self.journalID, seq: EntrySeq(rawValue: 1))

        let first = try registry.answer(params: GuiAnswerParams(sessionID: Self.sessionID, askID: askID, choiceIndex: 1))
        let second = try registry.answer(params: GuiAnswerParams(sessionID: Self.sessionID, askID: askID, choiceIndex: 1))

        #expect(first == GuiAnswerResult(answered: true))
        #expect(second == GuiAnswerResult(answered: true))
        #expect(injector.inputs == ["2"])
        #expect(published.last?.state == .answered(choice: 1))
    }

    @Test func newerEntrySupersedesActiveAsk() {
        let injector = FakeAskRegistryInjector()
        var published: [PendingAsk] = []
        let registry = AgentGUIAskRegistry(clock: { 1_000 }, injector: injector, publish: { published.append($0) })
        registry.handleSessionSnapshot(Self.snapshot(phase: .needsInput))
        registry.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.questionEntry(seq: 1)]), sessionID: Self.sessionID)
        registry.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.agentEntry(seq: 2)]), sessionID: Self.sessionID)

        #expect(published.last?.state == .superseded)
    }

    @Test func journalResetSupersedesActiveAskFromReplacedJournal() throws {
        let injector = FakeAskRegistryInjector()
        var published: [PendingAsk] = []
        let registry = AgentGUIAskRegistry(clock: { 1_000 }, injector: injector, publish: { published.append($0) })
        registry.handleSessionSnapshot(Self.snapshot(phase: .needsInput))
        registry.handleJournalEvent(
            .appended(journalID: Self.journalID, entries: [Self.questionEntry(seq: 1)]),
            sessionID: Self.sessionID
        )
        let askID = AgentGUIAskRegistry.askID(journalID: Self.journalID, seq: EntrySeq(rawValue: 1))

        registry.handleJournalEvent(
            .reset(journalID: JournalID(rawValue: "journal-2"), tailSeq: EntrySeq(rawValue: 0)),
            sessionID: Self.sessionID
        )

        #expect(published.map(\.state) == [.active, .superseded])
        let answer = try registry.answer(
            params: GuiAnswerParams(sessionID: Self.sessionID, askID: askID, choiceIndex: 0)
        )
        #expect(answer == GuiAnswerResult(answered: false))
        #expect(injector.inputs.isEmpty)
    }

    @Test func activeAskExpiresAfterTimeout() {
        var now = 1_000
        let injector = FakeAskRegistryInjector()
        var published: [PendingAsk] = []
        let registry = AgentGUIAskRegistry(clock: { now }, injector: injector, publish: { published.append($0) })
        registry.handleSessionSnapshot(Self.snapshot(phase: .needsInput))
        registry.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.questionEntry(seq: 1)]), sessionID: Self.sessionID)

        now += AgentGUIConstants.askTimeoutMS
        registry.expire()

        #expect(published.last?.state == .expired)
    }

    @Test func removingSessionPrunesAnswersAndPendingEntries() {
        let injector = FakeAskRegistryInjector()
        var published: [PendingAsk] = []
        let registry = AgentGUIAskRegistry(clock: { 1_000 }, injector: injector, publish: { published.append($0) })
        registry.handleSessionSnapshot(Self.snapshot(phase: .needsInput))
        registry.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.questionEntry(seq: 1)]), sessionID: Self.sessionID)
        let askID = AgentGUIAskRegistry.askID(journalID: Self.journalID, seq: EntrySeq(rawValue: 1))
        registry.handleSessionSnapshot(Self.snapshot(phase: .working))
        registry.handleJournalEvent(.appended(journalID: Self.journalID, entries: [Self.permissionEntry(seq: 2)]), sessionID: Self.sessionID)

        registry.removeSession(Self.sessionID)
        let publishedCountAtRemoval = published.count
        registry.handleSessionSnapshot(Self.snapshot(phase: .needsInput))

        do {
            _ = try registry.answer(params: GuiAnswerParams(sessionID: Self.sessionID, askID: askID, choiceIndex: 0))
            Issue.record("removed ask should not be answerable")
        } catch let error as AgentGUIRPCError {
            #expect(error.code == "not_found")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(!registry.hasPendingExpirations)
        #expect(published.count == publishedCountAtRemoval)
    }

    private static let sessionID = AgentSessionID(rawValue: "session-1")
    private static let journalID = JournalID(rawValue: "journal-1")
    private static let surfaceID = UUID().uuidString

    private static func snapshot(phase: SessionPhase) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: Self.sessionID,
            macDeviceID: MacDeviceID(rawValue: "mac-1"),
            kind: .codex,
            phase: phase,
            tier: .wrapped,
            surfaceID: Self.surfaceID,
            cwd: "/repo",
            title: "Session",
            workspaceName: "Workspace",
            version: EntityVersion(rawValue: 1),
            lastActivityHint: 1
        )
    }

    private static func questionEntry(seq: Int) -> EntrySnapshot {
        EntrySnapshot(
            journalID: Self.journalID,
            seq: EntrySeq(rawValue: seq),
            kind: .question,
            content: EntryContent(
                contentHash: seq,
                payload: .question(QuestionPayload(prompt: "Pick one", options: ["A", "B"]))
            ),
            version: EntityVersion(rawValue: 1)
        )
    }

    private static func permissionEntry(seq: Int) -> EntrySnapshot {
        EntrySnapshot(
            journalID: Self.journalID,
            seq: EntrySeq(rawValue: seq),
            kind: .permission,
            content: EntryContent(
                contentHash: seq,
                payload: .permission(PermissionPayload(toolName: "shell", detail: "Run command?", options: ["Deny", "Allow"]))
            ),
            version: EntityVersion(rawValue: 1)
        )
    }

    private static func agentEntry(seq: Int) -> EntrySnapshot {
        EntrySnapshot(
            journalID: Self.journalID,
            seq: EntrySeq(rawValue: seq),
            kind: .agentProse,
            content: EntryContent(
                contentHash: seq,
                payload: .agentProse(AgentProsePayload(markdown: "moving on"))
            ),
            version: EntityVersion(rawValue: 1)
        )
    }
}

@MainActor
private final class FakeAskRegistryInjector: AgentGUITerminalInjecting {
    var inputs: [String] = []
    var result: AgentGUITerminalInjectionResult = .accepted

    func submitPrompt(surfaceID: String, text: String) -> AgentGUITerminalInjectionResult {
        result
    }

    func sendKey(surfaceID: String, keyName: String) -> AgentGUITerminalInjectionResult {
        result
    }

    func sendInput(surfaceID: String, text: String) -> AgentGUITerminalInjectionResult {
        inputs.append(text)
        return result
    }
}
