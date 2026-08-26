import Foundation
import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TmuxWorkspacePaneOverlayRenderState {
    /// Preserves legacy overlay fixtures inside the test target while keeping
    /// every production construction explicit about the configured color.
    init(
        workspaceId: UUID,
        unreadRects: [CGRect],
        flashRect: CGRect?,
        activePaneBorderRect: CGRect? = nil,
        activePaneBorderColorHex: String? = nil,
        flashToken: UInt64,
        flashReason: WorkspaceAttentionFlashReason?
    ) {
        self.init(
            workspaceId: workspaceId,
            unreadRects: unreadRects,
            flashRect: flashRect,
            activePaneBorderRect: activePaneBorderRect,
            activePaneBorderColorHex: activePaneBorderColorHex,
            flashToken: flashToken,
            flashReason: flashReason,
            workspaceAttentionColor: WorkspaceAttentionColor(configuredHex: nil)
        )
    }
}

@Suite("tmux workspace pane overlay model")
struct TmuxWorkspacePaneOverlayModelTests {
    @Test @MainActor
    func tracksActivePaneBorder() {
        let model = TmuxWorkspacePaneOverlayModel()
        let borderRect = CGRect(x: 8, y: 12, width: 320, height: 180)
        let attentionColor = WorkspaceAttentionColor(configuredHex: "#FF69B4")

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: UUID(),
            unreadRects: [],
            flashRect: nil,
            activePaneBorderRect: borderRect,
            activePaneBorderColorHex: "#33AAFF",
            flashToken: 0,
            flashReason: nil,
            workspaceAttentionColor: attentionColor
        ))

        #expect(model.activePaneBorderRect == borderRect)
        #expect(model.activePaneBorderColorHex == "#33AAFF")
        #expect(model.workspaceAttentionColor == attentionColor)

        model.clear()

        #expect(model.activePaneBorderRect == nil)
        #expect(model.activePaneBorderColorHex == nil)
        #expect(model.workspaceAttentionColor == WorkspaceAttentionColor(configuredHex: nil))
    }

    @Test
    @MainActor
    func geometryRefreshBurstUsesNewestStateProvider() async {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        let controller = WindowTmuxWorkspacePaneOverlayController(window: window)
        let deliveredProviders = AsyncStream<Int>.makeStream()
        var deliveredProviderIterator = deliveredProviders.stream.makeAsyncIterator()

        // A full-screen transition can enqueue an intermediate geometry update
        // immediately before didEnter/didExit delivers the settled update. The
        // pending refresh must evaluate the newest provider, not the one that
        // happened to arrive first.
        controller.scheduleGeometryRefresh {
            deliveredProviders.continuation.yield(1)
            return nil
        }
        controller.scheduleGeometryRefresh {
            deliveredProviders.continuation.yield(2)
            return nil
        }

        let deliveredProvider = await deliveredProviderIterator.next()
        #expect(deliveredProvider == 2)
        deliveredProviders.continuation.finish()
    }
}
