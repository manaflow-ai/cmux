import Observation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct MobileHostIrohAuthObserverTests {
    @Observable final class Account {
        var id: String?
    }

    @Test(.timeLimit(.minutes(1)))
    func replacingAStreamKeepsObservingAccountChanges() async {
        let account = Account()
        let observer = MobileHostIrohAuthObserver()
        var old = observer.states { MobileHostIrohAuthState(accountID: account.id) }.makeAsyncIterator()
        #expect(await old.next() == MobileHostIrohAuthState(accountID: nil))
        var current = observer.states { MobileHostIrohAuthState(accountID: account.id) }.makeAsyncIterator()
        #expect(await old.next() == nil)
        #expect(await current.next() == MobileHostIrohAuthState(accountID: nil))
        await Task.yield()
        account.id = "first"
        #expect(await current.next() == MobileHostIrohAuthState(accountID: "first"))
        account.id = "second"
        #expect(await current.next() == MobileHostIrohAuthState(accountID: "second"))
        observer.stop()
        #expect(await current.next() == nil)
    }
}
