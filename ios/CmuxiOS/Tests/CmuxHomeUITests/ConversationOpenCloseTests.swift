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
        // The close, and again once the read returned.
        #expect(source.closes == [id, id])
        #expect(store.mirror.windows[id] == nil)
        store.stop()
    }

    /// A screen loaded but never shown (`debugTapback`, a replaced
    /// navigation root) gets no `viewDidDisappear`: freeing it still closes
    /// its conversation, once.
    @Test func aScreenFreedWithoutEverShowingClosesItsConversation() async {
        let source = GatedHomeSource(MockHomeSource(options: .immediate))
        let store = HomeStore(source: source)
        store.start()
        await until { store.me != nil && store.isOnline }
        var screen: ConversationViewController?
        autoreleasepool {
            screen = ConversationViewController(store: store, conversation: id)
            screen?.loadViewIfNeeded()
        }
        weak var freed = screen
        await until { !store.transcript(for: id).isEmpty }
        #expect(store.viewers[id] == 1)
        autoreleasepool { screen = nil }
        await until { freed == nil && store.viewers[id] == nil }
        #expect(freed == nil, "the screen outlived its last reference")
        #expect(store.viewers[id] == nil, "a freed screen left its conversation open")
        #expect(store.registeredHookCount == 0, "a freed screen left its binding's hook in the store")
        #expect(source.closes == [id])
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
