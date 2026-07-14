import AppKit
import Bonsplit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal portal unusable host authority")
struct TerminalPortalUnusableHostAuthorityTests {
    @MainActor
    private func makeSurface() -> TerminalSurface {
        TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
    }

    @MainActor
    @Test
    func queuedReplacementClaimsBeforeDetachedHostReturns() {
        let surface = makeSurface()
        let host = NSView(), replacementHost = NSView()
        let pane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        var retryCount = 0
        var retryClaimedReplacement = false

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(host), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.current.visible"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(replacementHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds,
            retryWhenAvailable: {
                retryCount += 1
                retryClaimedReplacement = surface.claimPortalHost(
                    hostId: ObjectIdentifier(replacementHost), paneId: pane, ownershipGeneration: 1,
                    inWindow: true, bounds: bounds, reason: "test.replacement.retry"
                )
            },
            reason: "test.replacement.queued"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(host), paneId: pane, ownershipGeneration: 1,
            inWindow: false, bounds: bounds, reason: "test.current.detached"
        ))
        #expect(retryCount == 1)
        #expect(retryClaimedReplacement)
        #expect(
            surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(replacementHost))
        )
    }

    @MainActor
    @Test
    func detachedHostClaimFailsWhileAwaitingReplacement() {
        let surface = makeSurface()
        let host = NSView(), replacementHost = NSView()
        let pane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(host), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.current.visible"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(host), paneId: pane, ownershipGeneration: 1,
            inWindow: false, bounds: bounds, reason: "test.current.detached"
        ))
        #expect(surface.isPortalHostReplacementPending(ownershipGeneration: 1))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(replacementHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.replacement.visible"
        ))
    }
}
