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
}
