import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The find-window panel model: reading pane text host by host, matching as it
/// arrives, and jumping to the chosen result.
@MainActor
@Suite struct RemoteTmuxFindWindowModelTests {
    @Test func contentMatchesFillInAsEachPaneIsRead() async throws {
        let first = RemoteTmuxFindWindowSearchTests.pane(window: 1, name: "editor", order: 0)
        let second = RemoteTmuxFindWindowSearchTests.pane(window: 2, name: "server", order: 1)
        let reads = ReadGate()
        let model = RemoteTmuxFindWindowModel(environment: .init(
            candidates: { [first, second] },
            readText: { candidate in await reads.wait(for: candidate.id) },
            jump: { _ in }
        ))

        model.open()
        model.query = "timeout"
        #expect(model.results.isEmpty)
        #expect(model.isReadingHistory)

        // Both panes are on one host, so they are read in tab order.
        try await waitUntil { reads.waiting == [first.id] }
        reads.release(first.id, lines: ["timeout in editor"])
        try await waitUntil { model.results.count == 1 }
        #expect(model.results.first?.candidate.id == first.id)
        #expect(model.isReadingHistory)

        try await waitUntil { reads.waiting == [second.id] }
        reads.release(second.id, lines: ["GET /health", "upstream timeout after 30s"])
        try await waitUntil { model.results.count == 2 && !model.isReadingHistory }
        // Content hits list in tab order once both are in.
        #expect(model.results.map(\.candidate.id) == [first.id, second.id])
    }

    @Test func panesOnOneHostAreReadOneAtATimeWhileHostsReadInParallel() async throws {
        let a1 = RemoteTmuxFindWindowSearchTests.pane(window: 1, name: "a1", order: 0, host: "alpha")
        let a2 = RemoteTmuxFindWindowSearchTests.pane(window: 2, name: "a2", order: 1, host: "alpha")
        let b1 = RemoteTmuxFindWindowSearchTests.pane(window: 3, name: "b1", order: 2, host: "beta")
        let reads = ReadGate()
        let model = RemoteTmuxFindWindowModel(environment: .init(
            candidates: { [a1, a2, b1] },
            readText: { candidate in await reads.wait(for: candidate.id) },
            jump: { _ in }
        ))

        model.open()
        try await waitUntil { reads.waiting.count == 2 }
        #expect(reads.waiting == [a1.id, b1.id])

        reads.release(a1.id, lines: [])
        try await waitUntil { reads.waiting.contains(a2.id) }
        #expect(reads.waiting == [b1.id, a2.id])
        reads.release(b1.id, lines: [])
        reads.release(a2.id, lines: [])
        model.close()
    }

    @Test func returnJumpsToTheSelectedResultAndStopsReading() async throws {
        let first = RemoteTmuxFindWindowSearchTests.pane(window: 1, name: "build", order: 0)
        let second = RemoteTmuxFindWindowSearchTests.pane(window: 2, name: "builder", order: 1)
        var jumped: [RemoteTmuxFindWindowResult] = []
        let model = RemoteTmuxFindWindowModel(environment: .init(
            candidates: { [first, second] },
            readText: { _ in nil },
            jump: { jumped.append($0) }
        ))

        model.open()
        model.query = "build"
        try await waitUntil { model.results.count == 2 }
        model.moveSelection(by: 1)
        model.moveSelection(by: 5)

        #expect(model.activateSelection())
        #expect(jumped.map(\.candidate.windowName) == ["builder"])
    }

    @Test func anInvalidRegexIsReportedAndClearsTheResults() async throws {
        let pane = RemoteTmuxFindWindowSearchTests.pane(window: 1, name: "shell", order: 0)
        let model = RemoteTmuxFindWindowModel(environment: .init(
            candidates: { [pane] },
            readText: { _ in RemoteTmuxPaneText(lines: ["shell output"], paneWidth: 80, isTruncated: false) },
            jump: { _ in }
        ))
        model.open()
        model.options.syntax = .regex

        model.query = "she(ll"
        #expect(model.queryError != nil)
        #expect(model.results.isEmpty)

        model.query = "she(ll)"
        #expect(model.queryError == nil)
        try await waitUntil { !model.results.isEmpty }
    }

    @Test func theSlotClosesItsModelWhenAnotherOverlayTakesOver() {
        let model = RemoteTmuxFindWindowModel(environment: .init(
            candidates: { [] },
            readText: { _ in nil },
            jump: { _ in }
        ))
        var slot = RemoteTmuxFindWindowSlot()
        slot.present(model)
        model.open()
        #expect(slot.activeModel(in: .findTmuxWindow) === model)
        // The palette or the agent inbox opened over find-window must neither render
        // nor route keys to it, before or after the slot hears of the change.
        #expect(slot.activeModel(in: .palette) == nil)
        #expect(slot.activeModel(in: .agentInbox) == nil)

        slot.overlayDidChange(to: .palette)

        #expect(!model.isOpen)
        #expect(slot.activeModel(in: .findTmuxWindow) == nil)
    }

    @Test func presentingAgainClosesTheEarlierModel() {
        let first = RemoteTmuxFindWindowModel(environment: .init(candidates: { [] }, readText: { _ in nil }, jump: { _ in }))
        let second = RemoteTmuxFindWindowModel(environment: .init(candidates: { [] }, readText: { _ in nil }, jump: { _ in }))
        var slot = RemoteTmuxFindWindowSlot()
        slot.present(first)
        first.open()

        slot.present(second)

        #expect(!first.isOpen)
        #expect(slot.activeModel(in: .findTmuxWindow) === second)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition never held")
                throw CancellationError()
            }
            await Task.yield()
        }
    }
}

/// Holds each pane read until the test releases it.
@MainActor
final class ReadGate {
    private(set) var waiting: [RemoteTmuxFindWindowCandidate.ID] = []
    private var continuations: [RemoteTmuxFindWindowCandidate.ID: CheckedContinuation<RemoteTmuxPaneText?, Never>] = [:]

    func wait(for id: RemoteTmuxFindWindowCandidate.ID) async -> RemoteTmuxPaneText? {
        await withCheckedContinuation { continuation in
            waiting.append(id)
            continuations[id] = continuation
        }
    }

    func release(_ id: RemoteTmuxFindWindowCandidate.ID, lines: [String]) {
        waiting.removeAll { $0 == id }
        continuations.removeValue(forKey: id)?.resume(returning: RemoteTmuxPaneText(lines: lines, paneWidth: 80, isTruncated: false))
    }
}
