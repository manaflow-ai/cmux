import AppKit
import QuartzCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Canvas pane content mount")
struct CanvasPaneContentMountTests {
    @Test func terminalAttachesToContainerBeforeBecomingVisible() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let hostedView = NSView(frame: .zero)
        var visibilityWasRequested = false

        CanvasPaneContentMount.attachTerminalView(hostedView, to: container) { attachedView in
            visibilityWasRequested = true
            #expect(attachedView.superview === container)
        }

        #expect(visibilityWasRequested)
        #expect(hostedView.superview === container)
    }

    @Test func terminalMountAppliesAttentionColorInitiallyAndOnUpdate() {
        let panel = TerminalPanel(workspaceId: UUID())
        let size = NSSize(width: 640, height: 480)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        window.orderFront(nil)
        let initialColor = WorkspaceAttentionColor(configuredHex: "#FF69B4")
        let mount = CanvasPaneContentMount(
            content: .terminal(panel, .disabled),
            panelId: panel.id,
            container: container,
            workspaceAttentionColor: initialColor,
            onFocusPanel: { _ in },
            makeTerminalVisible: { _ in }
        )
        defer {
            mount.unmount()
            window.contentView = nil
            window.close()
            panel.surface.teardownSurface()
        }

        window.displayIfNeeded()
        container.layoutSubtreeIfNeeded()
        #expect(attentionStrokeHexes(in: panel.hostedView).filter { $0 == "#FF69B4" }.count >= 2)

        mount.updatePresentation(
            isFocused: false,
            allowsPointerInput: true,
            showsInactiveOverlay: false,
            inactiveOverlayColor: .clear,
            inactiveOverlayOpacity: 0,
            sessionContentWidthPresentation: .disabled,
            workspaceAttentionColor: WorkspaceAttentionColor(configuredHex: "#33AA55")
        )

        window.displayIfNeeded()
        container.layoutSubtreeIfNeeded()
        #expect(attentionStrokeHexes(in: panel.hostedView).filter { $0 == "#33AA55" }.count >= 2)
    }

    private func attentionStrokeHexes(in view: NSView) -> [String] {
        shapeLayers(in: view.layer).compactMap { layer in
            guard let strokeColor = layer.strokeColor,
                  let color = NSColor(cgColor: strokeColor) else { return nil }
            return color.hexString()
        }
    }

    private func shapeLayers(in layer: CALayer?) -> [CAShapeLayer] {
        guard let layer else { return [] }
        return ((layer as? CAShapeLayer).map { [$0] } ?? [])
            + (layer.sublayers ?? []).flatMap { shapeLayers(in: $0) }
    }
}
