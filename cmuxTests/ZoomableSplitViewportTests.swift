import AppKit
import Bonsplit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Zoomable split viewport")
struct ZoomableSplitViewportTests {
    @Test func zoomableSplitsUseDirectTerminalHosting() {
        #expect(WorkspaceLayoutMode.zoomableSplits.usesDirectTerminalHosting)
        #expect(WorkspaceLayoutMode.canvas.usesDirectTerminalHosting)
        #expect(!WorkspaceLayoutMode.splits.usesDirectTerminalHosting)
    }

    @Test func zoomOutClampsAtExactFit() {
        let root = makeRoot()
        defer { root.teardown() }

        root.setViewport(center: CGPoint(x: 400, y: 250), magnification: 0.25)

        #expect(abs(root.currentMagnification - 1.0) < 0.0001)
        root.zoom(by: 0.5)
        #expect(abs(root.currentMagnification - 1.0) < 0.0001)
    }

    @Test func zoomInRemainsAvailableBeyondFit() {
        let root = makeRoot()
        defer { root.teardown() }

        root.zoom(by: 1.25)

        #expect(abs(root.currentMagnification - 1.25) < 0.0001)
    }

    @Test func outerViewportSuppressesPlainDocumentScrollOnly() throws {
        let scrollView = ZoomableSplitScrollView()
        var documentScrollChecks = 0
        scrollView.shouldSuppressPlainDocumentScroll = { _ in
            documentScrollChecks += 1
            return true
        }

        #expect(scrollView.shouldSuppressOuterScroll(for: try makeScrollEvent()) == true)
        #expect(documentScrollChecks == 1)
        #expect(scrollView.shouldSuppressOuterScroll(for: try makeScrollEvent(flags: .maskCommand)) == false)
        #expect(documentScrollChecks == 1)
        #expect(scrollView.shouldSuppressOuterScroll(for: try makeScrollEvent(flags: .maskAlternate)) == false)
        #expect(documentScrollChecks == 1)
    }

    @Test func pointerFocusResolvesPanelFromSplitSnapshot() {
        let leftTab = UUID()
        let rightTab = UUID()
        let leftPanel = UUID()
        let rightPanel = UUID()
        let snapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 20, y: 40, width: 300, height: 120),
            panes: [
                PaneGeometry(
                    paneId: UUID().uuidString,
                    frame: PixelRect(x: 20, y: 40, width: 100, height: 120),
                    selectedTabId: leftTab.uuidString,
                    tabIds: [leftTab.uuidString]
                ),
                PaneGeometry(
                    paneId: UUID().uuidString,
                    frame: PixelRect(x: 120, y: 40, width: 200, height: 120),
                    selectedTabId: rightTab.uuidString,
                    tabIds: [rightTab.uuidString]
                ),
            ],
            focusedPaneId: nil,
            timestamp: 0
        )
        let panelsByTab = [
            TabID(uuid: leftTab): leftPanel,
            TabID(uuid: rightTab): rightPanel,
        ]

        let resolved = ZoomableSplitRootView.selectedPanelId(
            atDocumentPoint: CGPoint(x: 140, y: 60),
            in: snapshot,
            panelIdFromSurfaceId: { panelsByTab[$0] }
        )

        #expect(resolved == rightPanel)
        #expect(ZoomableSplitRootView.selectedPanelId(
            atDocumentPoint: CGPoint(x: 310, y: 60),
            in: snapshot,
            panelIdFromSurfaceId: { panelsByTab[$0] }
        ) == nil)
    }

    @Test func splitDividerHitIsDetectedInsideMagnifiedDocument() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView)

        let scrollView = NSScrollView(frame: contentView.bounds)
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 3.0
        scrollView.magnification = 2.0
        contentView.addSubview(scrollView)

        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 260))
        scrollView.documentView = documentView

        let splitView = NSSplitView(frame: documentView.bounds)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        documentView.addSubview(splitView)

        let left = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 260))
        let right = NSView(frame: NSRect(x: 250, y: 0, width: 250, height: 260))
        splitView.addArrangedSubview(left)
        splitView.addArrangedSubview(right)
        splitView.setPosition(250, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()

        let dividerPoint = NSPoint(
            x: left.frame.maxX + splitView.dividerThickness * 0.5,
            y: splitView.bounds.midY
        )
        let dividerWindowPoint = splitView.convert(dividerPoint, to: nil)
        let contentWindowPoint = splitView.convert(
            NSPoint(x: left.frame.maxX + splitView.dividerThickness + 24, y: splitView.bounds.midY),
            to: nil
        )

        #expect(ZoomableSplitRootView.containsSplitDivider(
            atWindowPoint: dividerWindowPoint,
            in: documentView
        ))
        #expect(!ZoomableSplitRootView.containsSplitDivider(
            atWindowPoint: contentWindowPoint,
            in: documentView
        ))
    }

    @Test func paneChromeHitIsDetectedFromSplitSnapshot() {
        let snapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 40, y: 80, width: 320, height: 200),
            panes: [
                PaneGeometry(
                    paneId: UUID().uuidString,
                    frame: PixelRect(x: 40, y: 80, width: 160, height: 200),
                    selectedTabId: UUID().uuidString,
                    tabIds: []
                ),
                PaneGeometry(
                    paneId: UUID().uuidString,
                    frame: PixelRect(x: 200, y: 80, width: 160, height: 200),
                    selectedTabId: UUID().uuidString,
                    tabIds: []
                ),
            ],
            focusedPaneId: nil,
            timestamp: 0
        )

        #expect(ZoomableSplitRootView.pointTargetsPaneChrome(
            atDocumentPoint: CGPoint(x: 20, y: WindowChromeMetrics.bonsplitTabBarHeight - 1),
            in: snapshot
        ))
        #expect(!ZoomableSplitRootView.pointTargetsPaneChrome(
            atDocumentPoint: CGPoint(x: 20, y: WindowChromeMetrics.bonsplitTabBarHeight + 20),
            in: snapshot
        ))
    }

    @Test func splitActionButtonHitResolvesTrailingPaneChromeButton() throws {
        let paneId = UUID()
        let snapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 0, y: 0, width: 220, height: 160),
            panes: [
                PaneGeometry(
                    paneId: paneId.uuidString,
                    frame: PixelRect(x: 0, y: 0, width: 220, height: 160),
                    selectedTabId: UUID().uuidString,
                    tabIds: []
                ),
            ],
            focusedPaneId: nil,
            timestamp: 0
        )
        let appearance = BonsplitConfiguration.default.appearance

        let hit = try #require(ZoomableSplitRootView.splitActionButtonHit(
            atDocumentPoint: CGPoint(x: 123, y: appearance.tabBarHeight / 2),
            in: snapshot,
            appearance: appearance
        ))

        #expect(hit.paneId == PaneID(id: paneId))
        #expect(hit.button.id == BonsplitConfiguration.SplitActionButton.newTerminal.id)
        #expect(ZoomableSplitRootView.splitActionButtonHit(
            atDocumentPoint: CGPoint(x: 24, y: appearance.tabBarHeight / 2),
            in: snapshot,
            appearance: appearance
        ) == nil)
    }

    private func makeRoot() -> ZoomableSplitRootView {
        let root = ZoomableSplitRootView(
            workspace: Workspace(title: "Zoomable split tests"),
            isWorkspaceInputActive: false,
            content: AnyView(Color.clear)
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        root.frame = host.bounds
        host.addSubview(root)
        host.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        return root
    }

    private func makeScrollEvent(flags: CGEventFlags = []) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: -24,
            wheel3: 0
        ))
        cgEvent.flags = flags
        return try #require(NSEvent(cgEvent: cgEvent))
    }
}
