import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The queue of panes waiting for a session priority restart: one entry per pane, oldest first.
struct SessionPriorityApplyQueueTests {
    private let workspaceId = UUID()

    /// Empties `queue` and returns its panes in the order `next()` gave them.
    private func drain(_ queue: inout SessionPriorityApplyQueue) -> [SessionPriorityApplyQueue.Entry] {
        var entries: [SessionPriorityApplyQueue.Entry] = []
        while let entry = queue.next() { entries.append(entry) }
        return entries
    }

    @Test
    func enqueueReplacesThePendingTarget() {
        var queue = SessionPriorityApplyQueue()
        let pane = UUID()
        queue.enqueue(panelId: pane, workspaceId: workspaceId, target: .init(effort: .low))
        queue.enqueue(panelId: pane, workspaceId: workspaceId, target: .init(effort: .xhigh, model: "opus"))

        let entries = drain(&queue)

        #expect(entries == [.init(panelId: pane, workspaceId: workspaceId, target: .init(effort: .xhigh, model: "opus"))])
        #expect(queue.isEmpty)
    }

    @Test
    func nextIsFIFOAcrossPanes() {
        var queue = SessionPriorityApplyQueue()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        queue.enqueue(panelId: first, workspaceId: workspaceId, target: .init(effort: .low))
        queue.enqueue(panelId: second, workspaceId: workspaceId, target: .init(effort: .medium))
        queue.enqueue(panelId: third, workspaceId: workspaceId, target: .init(effort: .high))
        // A pane queued again keeps its turn; a removed pane gives up its turn.
        queue.enqueue(panelId: first, workspaceId: workspaceId, target: .init(effort: .max))
        queue.remove(panelId: second)

        let entries = drain(&queue)

        #expect(entries.map(\.panelId) == [first, third])
        #expect(entries.first?.target == .init(effort: .max))
    }

    @Test
    func removeAllEmpties() {
        var queue = SessionPriorityApplyQueue()
        queue.enqueue(panelId: UUID(), workspaceId: workspaceId, target: .init(effort: .low))
        queue.enqueue(panelId: UUID(), workspaceId: workspaceId, target: .init(effort: .high))
        #expect(!queue.isEmpty)

        queue.removeAll()

        let entries = drain(&queue)
        #expect(queue.isEmpty)
        #expect(entries.isEmpty)
    }

    @Test
    func removedPaneQueuedAgainWaitsAtTheBack() {
        var queue = SessionPriorityApplyQueue()
        let first = UUID()
        let second = UUID()
        queue.enqueue(panelId: first, workspaceId: workspaceId, target: .init(effort: .low))
        queue.enqueue(panelId: second, workspaceId: workspaceId, target: .init(effort: .medium))
        queue.remove(panelId: first)
        queue.enqueue(panelId: first, workspaceId: workspaceId, target: .init(effort: .high))

        let entries = drain(&queue)

        #expect(entries.map(\.panelId) == [second, first])
        #expect(entries.last?.target == .init(effort: .high))
    }

    @Test
    func queueingWhileDrainingKeepsEachPanesTurn() {
        var queue = SessionPriorityApplyQueue()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        queue.enqueue(panelId: first, workspaceId: workspaceId, target: .init(effort: .low))
        queue.enqueue(panelId: second, workspaceId: workspaceId, target: .init(effort: .medium))
        #expect(queue.next()?.panelId == first)
        queue.enqueue(panelId: third, workspaceId: workspaceId, target: .init(effort: .high))
        // `second` still waits, so it keeps its turn; `first` was taken, so it queues at the back.
        queue.enqueue(panelId: second, workspaceId: workspaceId, target: .init(effort: .xhigh))
        queue.enqueue(panelId: first, workspaceId: workspaceId, target: .init(effort: .max))

        let entries = drain(&queue)

        #expect(entries.map(\.panelId) == [second, third, first])
        #expect(entries.map(\.target) == [SessionPriorityTarget(effort: .xhigh), SessionPriorityTarget(effort: .high), SessionPriorityTarget(effort: .max)])
    }

    /// A thousand panes, as many as one Mac's workspaces may hold: replacing and removing panes
    /// throughout keeps the survivors in their first order, each with its newest target.
    @Test
    func aThousandPanesDrainInTheirFirstOrder() {
        var queue = SessionPriorityApplyQueue()
        let panes = (0..<1_000).map { _ in UUID() }
        for pane in panes {
            queue.enqueue(panelId: pane, workspaceId: workspaceId, target: .init(effort: .low))
        }
        for (index, pane) in panes.enumerated() {
            if index % 3 == 0 {
                queue.remove(panelId: pane)
            } else if index % 2 == 0 {
                queue.enqueue(panelId: pane, workspaceId: workspaceId, target: .init(effort: .high))
            }
        }

        let entries = drain(&queue)

        let survivors = panes.enumerated().filter { $0.offset % 3 != 0 }
        #expect(entries.map(\.panelId) == survivors.map(\.element))
        #expect(entries.map(\.target) == survivors.map { SessionPriorityTarget(effort: $0.offset % 2 == 0 ? .high : .low) })
        #expect(queue.isEmpty)
    }

    /// Queues compare by the panes waiting in them, in order, however they got there.
    @Test
    func queuesWithTheSameWaitingPanesAreEqual() {
        let first = UUID()
        let second = UUID()
        var drained = SessionPriorityApplyQueue()
        drained.enqueue(panelId: first, workspaceId: workspaceId, target: .init(effort: .low))
        drained.enqueue(panelId: second, workspaceId: workspaceId, target: .init(effort: .medium))
        _ = drained.next()
        var fresh = SessionPriorityApplyQueue()
        fresh.enqueue(panelId: second, workspaceId: workspaceId, target: .init(effort: .medium))

        #expect(drained == fresh)
        fresh.enqueue(panelId: first, workspaceId: workspaceId, target: .init(effort: .low))
        #expect(drained != fresh)
    }
}
