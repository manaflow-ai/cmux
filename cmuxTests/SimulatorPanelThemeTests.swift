import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxSimulator
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Simulator panel visibility", .serialized)
struct SimulatorPanelVisibilityTests {
    @Test("A surviving Simulator host keeps framebuffer publication active")
    func survivingHostKeepsFramebufferActive() async throws {
        let device = SimulatorDevice(
            id: "ipad",
            name: "iPad",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "type",
            family: .iPad,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = SimulatorThemePaneClient(devices: [device])
        let panel = SimulatorPanel(client: client)
        defer { panel.close() }

        let size = NSSize(width: 640, height: 480)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        var firstHost: NSHostingView<PanelContentView>? = NSHostingView(
            rootView: content(panel: panel, background: .black)
        )
        let secondHost = NSHostingView(
            rootView: content(panel: panel, background: .black)
        )
        firstHost?.frame = root.bounds
        secondHost.frame = root.bounds
        root.addSubview(firstHost!)
        root.addSubview(secondHost)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        settle(root)

        for _ in 0..<100 {
            if await client.discoveryCount > 0 { break }
            await Task.yield()
        }
        #expect(await client.discoveryCount == 1)
        await client.emit(.status(.streaming))
        await client.emit(.frameTransport(SimulatorFrameTransportDescriptor(
            sharedMemoryName: "/cmux-test-frame",
            width: 4,
            height: 4,
            bytesPerRow: 16,
            slotCount: 2,
            sharedMemoryByteCount: 256
        )))
        for _ in 0..<100 {
            if panel.coordinator.frameTransport != nil { break }
            await Task.yield()
        }
        #expect(panel.coordinator.frameTransport != nil)

        firstHost?.removeFromSuperview()
        firstHost = nil
        settle(root)

        #expect(panel.coordinator.frameTransport != nil)
        #expect(!(await client.messages).contains(.setFramebufferPublishing(false)))
    }

    private func content(panel: SimulatorPanel, background: NSColor) -> PanelContentView {
        PanelContentView(
            panel: panel,
            workspaceId: UUID(),
            paneId: PaneID(),
            isFocused: true,
            isSelectedInPane: true,
            isVisibleInUI: true,
            allowsPointerInput: true,
            portalPriority: 0,
            isSplit: false,
            appearance: PanelAppearance(
                backgroundColor: background,
                foregroundColor: cmuxReadableForegroundNSColor(on: background, opacity: 1),
                dividerColor: Color(nsColor: .separatorColor),
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0,
                usesClearContentBackground: false
            ),
            windowAppearance: .rightSidebarPanelViewTestDefault,
            customSidebarTabManager: nil,
            hasUnreadNotification: false,
            terminalAgentContext: "",
            onFocus: {},
            onRequestPanelFocus: {},
            onResumeAgentHibernation: {},
            onAutoResumeAgentHibernation: {},
            onTriggerFlash: {}
        )
    }

    private func settle(_ view: NSView) {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

@MainActor
@Suite("Simulator panel theme", .serialized)
struct SimulatorPanelThemeTests {
    @Test("Simulator pane renders the live Ghostty background")
    func rendersGhosttyBackground() throws {
        let monokai = try #require(NSColor(hex: "#272822"))
        let lightTheme = try #require(NSColor(hex: "#F8F8F2"))
        let panel = SimulatorPanel(client: SimulatorThemePaneClient())
        defer { panel.close() }

        let size = NSSize(width: 360, height: 260)
        let hostingView = NSHostingView(rootView: content(panel: panel, background: monokai))
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hostingView
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        #expect(renderedCornerHex(hostingView) == "#272822")

        hostingView.rootView = content(panel: panel, background: lightTheme)
        #expect(renderedCornerHex(hostingView) == "#F8F8F2")
    }

    private func content(panel: SimulatorPanel, background: NSColor) -> PanelContentView {
        PanelContentView(
            panel: panel,
            workspaceId: UUID(),
            paneId: PaneID(),
            isFocused: true,
            isSelectedInPane: true,
            isVisibleInUI: true,
            allowsPointerInput: true,
            portalPriority: 0,
            isSplit: false,
            appearance: PanelAppearance(
                backgroundColor: background,
                foregroundColor: cmuxReadableForegroundNSColor(on: background, opacity: 1),
                dividerColor: Color(nsColor: .separatorColor),
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0,
                usesClearContentBackground: false
            ),
            windowAppearance: .rightSidebarPanelViewTestDefault,
            customSidebarTabManager: nil,
            hasUnreadNotification: false,
            terminalAgentContext: "",
            onFocus: {},
            onRequestPanelFocus: {},
            onResumeAgentHibernation: {},
            onAutoResumeAgentHibernation: {},
            onTriggerFlash: {}
        )
    }

    private func renderedCornerHex(_ view: NSView) -> String? {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let bounds = view.bounds.integral
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        return bitmap.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB)?.hexString()
    }

}

@MainActor
@Suite("Canvas Simulator pointer ownership")
struct CanvasSimulatorPointerOwnershipTests {
    @Test("Hosted canvas presentation carries focus changes")
    func hostedPresentationCarriesFocus() {
        let owner = NSView(frame: .zero)
        let presentation = CanvasHostedPanelPresentation(
            isFocused: false,
            allowsPointerInput: true,
            pointerInputOwner: owner
        )

        #expect(!presentation.isFocused)
        presentation.setFocused(true)
        #expect(presentation.isFocused)
    }

    @Test("An overlapping pointer entry belongs only to the frontmost pane")
    func frontmostPaneOwnsPointerEntry() throws {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: bounds)
        let obscuredOwner = NSView(frame: bounds)
        let frontmostOwner = NSView(frame: bounds)
        root.addSubview(obscuredOwner)
        root.addSubview(frontmostOwner)
        window.contentView = root
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let obscured = CanvasHostedPanelPresentation(
            isFocused: false,
            allowsPointerInput: true,
            pointerInputOwner: obscuredOwner
        )
        let frontmost = CanvasHostedPanelPresentation(
            isFocused: true,
            allowsPointerInput: true,
            pointerInputOwner: frontmostOwner
        )
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 150, y: 150),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        #expect(frontmost.acceptsPointerEntryEvent(event))
        #expect(!obscured.acceptsPointerEntryEvent(event))
    }
}

private actor SimulatorThemePaneClient: SimulatorPaneClient {
    private let events = SimulatorWorkerEventStreamSource(
        maximumBufferedBytes: 1_024,
        maximumBufferedEvents: 4,
        onTermination: {}
    )
    private let devices: [SimulatorDevice]
    private(set) var discoveryCount = 0
    private(set) var messages: [SimulatorWorkerInbound] = []

    init(devices: [SimulatorDevice] = []) {
        self.devices = devices
    }

    func discoverDevices() async throws -> [SimulatorDevice] {
        discoveryCount += 1
        return devices
    }
    func synchronizeOrientation(
        _ orientation: SimulatorOrientation
    ) async throws -> SimulatorDisplayMetadata? { nil }
    func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {}
    func shutdownDevice(id: String) async throws {}
    func subscribe() async -> SimulatorWorkerEventStream { events.stream }
    func send(_ message: SimulatorWorkerInbound) async { messages.append(message) }
    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult { .none }
    func invalidateWorker() async {}
    func stop() async {}

    func emit(_ message: SimulatorWorkerOutbound) async {
        _ = await events.continuation.yield(.message(message))
    }
}
