import CmuxiOSComposerCore
import CmuxiOSFeatureKit
import Foundation
import Testing

/// A sink whose dispatch answers are scripted per call.
final class ScriptedSink: TaskComposerSink, @unchecked Sendable {
    let mock = MockTaskComposerSink()
    private let lock = NSLock()
    private var answers: [Result<TaskReceipt?, FeatureSourceError>] = []
    private(set) var keys: [IntentKey] = []

    func script(_ answer: Result<TaskReceipt?, FeatureSourceError>) { lock.withLock { answers.append(answer) } }

    func catalog() async -> AsyncStream<SourceSnapshot<ComposerCatalog>> { await mock.catalog() }

    func tasks(on host: HostID) async -> AsyncStream<SourceSnapshot<[TaskRecord]>> { await mock.tasks(on: host) }

    func dispatch(_ draft: TaskDraft, key: IntentKey) async throws -> TaskReceipt {
        let answer: Result<TaskReceipt?, FeatureSourceError>? = lock.withLock {
            keys.append(key)
            return answers.isEmpty ? nil : answers.removeFirst()
        }
        switch answer {
        case .success(let receipt?): return receipt
        case .failure(let error): throw error
        case .success(nil), nil: return try await mock.dispatch(draft, key: key)
        }
    }
}

@MainActor
@Suite("composer session")
struct SessionTests {
    func defaults() -> UserDefaults {
        let name = "composer-session-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func ready(_ session: ComposerSession) async {
        for _ in 0..<1000 where session.draft == nil { await Task.yield() }
    }

    func session(_ sink: ScriptedSink, target: ComposerTarget? = nil, defaults: UserDefaults? = nil) async -> ComposerSession {
        let defaults = defaults ?? self.defaults()
        let session = ComposerSession(sink: sink, store: ComposerDraftStore(defaults: defaults),
                                      preferences: ComposerPreferences(defaults: defaults), target: target)
        session.start()
        await ready(session)
        return session
    }

    @Test func opensOnTheFirstReachableMacWithItsDefaultAgent() async {
        let session = await session(ScriptedSink())
        #expect(session.draft?.target == ComposerTarget(hostID: MockFixtures.studio))
        #expect(session.selectedAgent?.id == "claude")
        #expect(session.draft?.effort == "medium")
        #expect(session.blocker == .emptyPrompt)
    }

    @Test func sendStartsTheTaskClearsTheDraftAndFollowsItsState() async {
        let session = await session(ScriptedSink(), target: ComposerTarget(hostID: MockFixtures.studio, workspaceID: "ws_studio1"))
        session.updatePrompt("Fix the sizing tests")
        await session.send()
        guard case .started(_, let workspace, let task, _)? = session.outcome else {
            Issue.record("expected a start, got \(String(describing: session.outcome))")
            return
        }
        #expect(workspace == "ws_studio1")
        #expect(task != nil)
        #expect(session.draft?.prompt == "")
        #expect(session.draft?.pendingKey == nil)
        for _ in 0..<1000 where session.task?.state != .running { await Task.yield() }
        #expect(session.task?.state == .running)
    }

    @Test func anUnknownOutcomeKeepsTheDraftAndRetriesWithTheSameKey() async {
        let sink = ScriptedSink()
        let session = await session(sink)
        session.updatePrompt("go")
        sink.script(.failure(.offline))
        await session.send()
        #expect(session.outcome == .notDelivered)
        #expect(session.draft?.prompt == "go")
        let kept = session.draft?.pendingKey
        #expect(kept != nil)
        await session.send()
        #expect(sink.keys.count == 2)
        #expect(sink.keys[0] == sink.keys[1])
        #expect(session.draft?.pendingKey == nil)
    }

    @Test func aRefusalKeepsThePromptAndDropsTheKey() async {
        let sink = ScriptedSink()
        let session = await session(sink)
        session.updatePrompt("go")
        sink.script(.success(.refused(key: IntentKey(), reason: "Codex: Not signed in")))
        await session.send()
        #expect(session.outcome == .refused(reason: "Codex: Not signed in"))
        #expect(session.draft?.prompt == "go")
        #expect(session.draft?.pendingKey == nil)
    }

    @Test func draftsFollowTheirTargetAndSelectionsArePerMac() async {
        let defaults = defaults()
        let session = await session(ScriptedSink(), defaults: defaults)
        session.updatePrompt("for the studio")
        session.selectAgent("codex")
        let other = ComposerTarget(hostID: MockFixtures.studio, workspaceID: "ws_studio1")
        session.setTarget(other)
        #expect(session.draft?.prompt == "")
        #expect(session.draft?.agentID == "codex")
        session.setTarget(ComposerTarget(hostID: MockFixtures.studio))
        #expect(session.draft?.prompt == "for the studio")
        session.stop()
        let reopened = await self.session(ScriptedSink(), defaults: defaults)
        #expect(reopened.draft?.target == ComposerTarget(hostID: MockFixtures.studio))
        #expect(reopened.draft?.prompt == "for the studio")
    }

    @Test func offlineDisablesSendWithAReasonAndKeepsTheDraft() async {
        let sink = ScriptedSink()
        let session = await session(sink)
        session.updatePrompt("go")
        await sink.mock.hub.setConnection(.offline(reason: "No network"))
        for _ in 0..<1000 where session.catalog?.connection.isLive == true { await Task.yield() }
        #expect(session.blocker == .offline(reason: "No network"))
        await session.send()
        #expect(sink.keys.isEmpty)
        #expect(session.draft?.prompt == "go")
    }
}
