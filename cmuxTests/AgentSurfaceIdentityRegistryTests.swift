import Foundation
import Testing

// The app module is renamed per tagged build, so resolve whichever is present.
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers the identity binding that lets agent hooks address a surface when the
/// environment cannot name one -- inside tmux, where shell integration clears
/// `CMUX_SURFACE_ID`, and across SSH, where it never existed.
@Suite struct AgentSurfaceIdentityRegistryTests {
    /// Each test uses a unique token so cases stay independent despite the
    /// shared registry instance.
    private func uniqueToken(_ label: String) -> String {
        "test-\(label)-\(UUID().uuidString)"
    }

    @Test func announcedTokenResolvesToTheSurfaceThatCarriedIt() {
        let registry = AgentSurfaceIdentityRegistry.shared
        let token = uniqueToken("resolve")
        let tabId = UUID()
        let surfaceId = UUID()

        registry.record(token: token, tabId: tabId, surfaceId: surfaceId)

        let binding = registry.binding(for: token)
        #expect(binding?.surfaceId == surfaceId)
        #expect(binding?.tabId == tabId)
    }

    /// The whole point of the registry: an unknown token must fail rather than
    /// fall back to some other surface. A guess would deliver a background
    /// agent's turn onto whatever pane the user happens to be looking at.
    @Test func unknownTokenFailsClosed() {
        #expect(AgentSurfaceIdentityRegistry.shared.binding(for: uniqueToken("missing")) == nil)
    }

    @Test func emptyOrWhitespaceTokenIsNeverBound() {
        let registry = AgentSurfaceIdentityRegistry.shared
        registry.record(token: "   ", tabId: UUID(), surfaceId: UUID())
        #expect(registry.binding(for: "   ") == nil)
        #expect(registry.binding(for: "") == nil)
    }

    /// Surrounding whitespace comes from the shell round-trip through the OSC
    /// payload; it must not produce a second, unreachable binding.
    @Test func tokenLookupIgnoresSurroundingWhitespace() {
        let registry = AgentSurfaceIdentityRegistry.shared
        let token = uniqueToken("trim")
        let surfaceId = UUID()

        registry.record(token: "  \(token)  ", tabId: UUID(), surfaceId: surfaceId)

        #expect(registry.binding(for: token)?.surfaceId == surfaceId)
    }

    /// A relaunch in the same pane re-announces; the newest stream must win.
    @Test func reannouncingATokenRebindsItToTheNewerSurface() {
        let registry = AgentSurfaceIdentityRegistry.shared
        let token = uniqueToken("rebind")
        let newerSurfaceId = UUID()

        registry.record(token: token, tabId: UUID(), surfaceId: UUID())
        registry.record(token: token, tabId: UUID(), surfaceId: newerSurfaceId)

        #expect(registry.binding(for: token)?.surfaceId == newerSurfaceId)
    }

    /// Nothing tells the registry when a surface closes, so a binding older
    /// than its lifetime must stop resolving rather than point at a dead pane.
    @Test func bindingOlderThanItsLifetimeStopsResolving() {
        let registry = AgentSurfaceIdentityRegistry.shared
        let token = uniqueToken("expiry")
        let announcedAt = Date()

        registry.record(token: token, tabId: UUID(), surfaceId: UUID(), now: announcedAt)

        let withinLifetime = announcedAt.addingTimeInterval(23 * 60 * 60)
        #expect(registry.binding(for: token, now: withinLifetime) != nil)

        let pastLifetime = announcedAt.addingTimeInterval(25 * 60 * 60)
        #expect(registry.binding(for: token, now: pastLifetime) == nil)
    }
}
