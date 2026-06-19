import CmuxKanbanCore
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Unit tests for ``CmuxLiveBackend`` — the observer backend that maps a shared
/// agent process's events onto Kanban board progress WITHOUT the headless
/// one-turn auto-stop.
@MainActor
@Suite(.serialized)
struct CmuxLiveBackendTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func card() -> KanbanCard {
        KanbanCard(
            title: "Live task",
            detail: "do the thing",
            column: .building,
            backendKind: .cmux,
            agentProvider: "claude",
            createdAt: Self.now,
            updatedAt: Self.now
        )
    }

    @Test
    func observesEventsAndKeepsRunningAcrossTurnComplete() async throws {
        let backend = CmuxLiveBackend()
        let store = AgentSessionProcessStore()
        let card = card()
        backend.registerSharedStore(
            cardId: card.id,
            store: store,
            worktreePath: "/tmp/wt",
            branchName: "cmux/kanban/abc"
        )

        let session = try await backend.dispatch(card: card, workingDirectory: "/tmp/wt")

        // Feed the events the shared store would emit. turnComplete must NOT end
        // the run — only a real process exit does (the headless force-stop is
        // intentionally absent here).
        backend.handleAgentEvent(["type": "provider.started", "sessionId": "s1"], handle: session.handle)
        backend.handleAgentEvent(["type": "provider.output", "text": "hello"], handle: session.handle)
        backend.handleAgentEvent(["type": "provider.turnComplete"], handle: session.handle)
        backend.handleAgentEvent(["type": "provider.exit", "status": 0], handle: session.handle)

        var collected: [KanbanDispatchProgress] = []
        for await progress in session.progress {
            collected.append(progress)
        }

        #expect(collected == [
            .provisioned(worktreePath: "/tmp/wt", branchName: "cmux/kanban/abc"),
            .started(sessionId: "s1"),
            .output("hello"),
            .turnComplete,
            .exited(status: 0),
        ])
    }

    @Test
    func dispatchWithoutARegisteredStoreThrows() async throws {
        let backend = CmuxLiveBackend()
        let card = card()
        await #expect(throws: CmuxLiveBackendError.self) {
            _ = try await backend.dispatch(card: card, workingDirectory: nil)
        }
    }

    @Test
    func cancelDetachesWithoutEmittingExit() async throws {
        let backend = CmuxLiveBackend()
        let store = AgentSessionProcessStore()
        let card = card()
        backend.registerSharedStore(
            cardId: card.id,
            store: store,
            worktreePath: "/tmp/wt",
            branchName: nil
        )
        let session = try await backend.dispatch(card: card, workingDirectory: "/tmp/wt")

        await backend.cancel(session.handle)

        var collected: [KanbanDispatchProgress] = []
        for await progress in session.progress {
            collected.append(progress)
        }
        // Detach: the stream finishes after the initial provisioned event with no
        // synthetic exit — the live process and worktree are left untouched.
        #expect(collected == [.provisioned(worktreePath: "/tmp/wt", branchName: "")])
    }
}
