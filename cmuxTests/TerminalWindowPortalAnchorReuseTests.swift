import AppKit
import Bonsplit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TerminalWindowPortalAnchorReuseTests {
    @Test
    func reusingAnchorRetiresDisplacedSurfaceAuthority() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        let contentView = try #require(window.contentView)
        let reusedAnchor = NSView(frame: NSRect(x: 20, y: 20, width: 220, height: 240))
        let replacementAnchor = NSView(frame: NSRect(x: 260, y: 20, width: 220, height: 240))
        contentView.addSubview(reusedAnchor)
        contentView.addSubview(replacementAnchor)
        let displacedSurface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let incomingSurface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let ownershipGeneration: UInt64 = 31
        let displacedPane = PaneID()
        let reusedAnchorId = ObjectIdentifier(reusedAnchor)

        TerminalWindowPortalRegistry.bind(
            hostedView: displacedSurface.hostedView,
            to: reusedAnchor,
            visibleInUI: true
        )
        #expect(displacedSurface.claimPortalHost(
            hostId: reusedAnchorId,
            paneId: displacedPane,
            ownershipGeneration: ownershipGeneration,
            inWindow: true,
            bounds: reusedAnchor.bounds,
            reason: "test.anchorReuse.displaced"
        ))

        TerminalWindowPortalRegistry.bind(
            hostedView: incomingSurface.hostedView,
            to: reusedAnchor,
            visibleInUI: true
        )

        #expect(!displacedSurface.isPortalHostOwner(hostId: reusedAnchorId))
        #expect(displacedSurface.claimPortalHost(
            hostId: ObjectIdentifier(replacementAnchor),
            paneId: displacedPane,
            ownershipGeneration: ownershipGeneration,
            inWindow: true,
            bounds: replacementAnchor.bounds,
            reason: "test.anchorReuse.rebind"
        ))
    }
}
