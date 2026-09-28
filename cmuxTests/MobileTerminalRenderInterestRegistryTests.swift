import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct MobileTerminalRenderInterestRegistryTests {
    private let phone = UUID()
    private let olderPhone = UUID()
    private let visible = UUID()
    private let hidden = UUID()

    @Test func undeclaredSubscriberKeepsEverySurfaceInScope() {
        let registry = MobileTerminalRenderInterestRegistry()
        let change = registry.registerSubscriber(connectionID: olderPhone)
        #expect(change.previous == .surfaces([]))
        #expect(change.current == .all)
        #expect(registry.wants(connectionID: olderPhone, surfaceID: hidden))
    }

    @Test func declarationNarrowsScopeAndDelivery() {
        let registry = MobileTerminalRenderInterestRegistry()
        registry.registerSubscriber(connectionID: phone)
        let change = registry.setViewSet([visible], connectionID: phone)
        #expect(change.previous == .all)
        #expect(change.current == .surfaces([visible]))
        #expect(registry.wants(connectionID: phone, surfaceID: visible))
        #expect(!registry.wants(connectionID: phone, surfaceID: hidden))
    }

    @Test func anUndeclaredPeerWidensScopeButNotTheDeclaredPhonesDelivery() {
        let registry = MobileTerminalRenderInterestRegistry()
        registry.setViewSet([visible], connectionID: phone)
        registry.registerSubscriber(connectionID: olderPhone)
        #expect(registry.scope == .all)
        #expect(!registry.wants(connectionID: phone, surfaceID: hidden))
        let change = registry.remove(connectionID: olderPhone)
        #expect(change.current == .surfaces([visible]))
    }

    @Test func resubscribeKeepsAnExistingDeclaration() {
        let registry = MobileTerminalRenderInterestRegistry()
        registry.setViewSet([visible], connectionID: phone)
        let change = registry.registerSubscriber(connectionID: phone)
        #expect(change.previous == change.current)
        #expect(registry.scope == .surfaces([visible]))
    }
}
