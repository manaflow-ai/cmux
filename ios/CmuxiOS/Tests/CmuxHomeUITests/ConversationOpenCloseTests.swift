@testable import CmuxHomeCore
import Testing
@testable import CmuxHomeUI

/// The conversation screen's binding owns the open/close pair (round-5
/// review, major 2): going back before the first page is in, or before
/// the account is known, leaves the conversation closed.
@MainActor
@Suite struct ConversationOpenCloseTests {
    let id = ConversationID("conv_infra")

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    @Test func backBeforeTheFirstPageLeavesTheConversationClosed() async {
        let source = GatedHomeSource(MockHomeSource(options: .immediate))
        let store = HomeStore(source: source)
        store.start()
        await until { store.me != nil && store.isOnline }
        source.hold()
        let screen = ConversationViewController(store: store, conversation: id)
        screen.loadViewIfNeeded()
        await until { source.waiting == 1 }
        // What viewDidDisappear runs when the screen leaves the stack.
        screen.close()
        source.release()
        for _ in 0..<500 { await Task.yield() }
        #expect(store.viewers[id] == nil)
        #expect(source.closes == [id])
        #expect(store.mirror.windows[id] == nil)
        store.stop()
    }

    @Test func noAccountYetOpensNothingAndBackClosesNothing() async {
        let source = GatedHomeSource(MockHomeSource(options: .immediate))
        let store = HomeStore(source: source)
        let screen = ConversationViewController(store: store, conversation: id)
        screen.loadViewIfNeeded()
        #expect(store.me == nil)
        #expect(store.viewers[id] == nil)
        screen.close()
        #expect(store.viewers[id] == nil)
        #expect(source.closes.isEmpty)
        #expect(source.snapshots.isEmpty)
    }
}
