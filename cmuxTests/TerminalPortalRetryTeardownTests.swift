import AppKit
import Bonsplit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal portal retry teardown")
struct TerminalPortalRetryTeardownTests {
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
    private func enqueueRetry(
        on surface: TerminalSurface,
        owner: NSView,
        candidate: NSView,
        pane: PaneID,
        retryCount: @escaping @MainActor () -> Void
    ) {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(owner), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.retry.owner"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(candidate), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds,
            retryWhenAvailable: retryCount,
            reason: "test.retry.candidate"
        ))
    }

    @MainActor
    @Test
    func teardownCancelsPendingPortalHostRetries() {
        let surface = makeSurface()
        let owner = NSView(), candidate = NSView()
        let pane = PaneID()
        var retryCount = 0
        enqueueRetry(
            on: surface,
            owner: owner,
            candidate: candidate,
            pane: pane,
            retryCount: { retryCount += 1 }
        )

        surface.teardownSurface()
        surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(owner),
            reason: "test.teardown.release"
        )

        #expect(retryCount == 0)
    }

    @MainActor
    @Test
    func hibernationCancelsPendingPortalHostRetries() {
        let surface = makeSurface()
        let owner = NSView(), candidate = NSView()
        let pane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        var retryCount = 0
        defer { surface.teardownSurface() }
        enqueueRetry(
            on: surface,
            owner: owner,
            candidate: candidate,
            pane: pane,
            retryCount: { retryCount += 1 }
        )

        surface.suspendRuntimeSurfaceForAgentHibernation(reason: "test.hibernate")
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(owner), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.hibernate.reclaim"
        ))
        surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(owner),
            reason: "test.hibernate.release"
        )

        #expect(retryCount == 0)
    }
}
