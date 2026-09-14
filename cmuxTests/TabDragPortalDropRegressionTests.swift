import AppKit
import Bonsplit
import WebKit
@_implementationOnly import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
enum TestPaneDropTargetRegistryStore {
    private static var associationKey: UInt8 = 0

    static func registry(for window: NSWindow) -> PaneDropTargetRegistry {
        if let registry = objc_getAssociatedObject(window, &associationKey) as? PaneDropTargetRegistry {
            return registry
        }
        let registry = PaneDropTargetRegistry()
        objc_setAssociatedObject(window, &associationKey, registry, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return registry
    }
}

@MainActor
final class TabDragPortalDropRegressionTests: XCTestCase {
    func testLiveTabDragRoutesTerminalPortalMouseUpWithoutPaneLatch() {
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .leftMouseUp,
                hasActiveDropDrag: false,
                hasLiveTabTransfer: true
            ),
            "A live tab tear-out must reach the pane target even when the target missed drag entry"
        )
    }

    func testLiveFilePreviewRoutesTerminalPortalMouseUpWithoutTabCapability() {
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                pasteboardTypes: [DragOverlayRoutingPolicy.filePreviewTransferType],
                eventType: .leftMouseUp,
                hasActiveDropDrag: false,
                hasLiveTabTransfer: false,
                hasLiveFileDropPayload: true
            ),
            "A live file-preview drop must reach the pane target without a tab capability"
        )
    }

    func testLiveFilePreviewRoutesBrowserPortalMouseUpToPaneDropTarget() {
        XCTAssertTrue(
            WindowBrowserHostView.shouldRoutePointerUpToPaneDropTarget(
                hasActiveDropDrag: false,
                hasLiveTabTransfer: false,
                hasLiveFileDropPayload: true
            )
        )
        XCTAssertFalse(
            WindowBrowserHostView.shouldRoutePointerUpToPaneDropTarget(
                hasActiveDropDrag: false,
                hasLiveTabTransfer: false,
                hasLiveFileDropPayload: false
            )
        )
    }

    func testLiveTabTransferRoutesBrowserPortalMouseUpWithoutPaneLatch() {
        XCTAssertTrue(
            WindowBrowserHostView.shouldRoutePointerUpToPaneDropTarget(
                hasActiveDropDrag: false,
                hasLiveTabTransfer: true,
                hasLiveFileDropPayload: false
            ),
            "A live tab tear-out must reach browser pane targets even when the target missed drag entry"
        )
    }

    func testNativeDragEndObserverResetsRegisteredTargets() throws {
        let registry = TabDragTransferRegistry()
        let coordinator = NativeDragCoordinator(tabDragTransferRegistry: registry)
        let target = ResettableTarget()
        coordinator.paneDropTargetRegistry.register(target) {
            target.resetCount += 1
        }

        let transfer = TabDragTransfer(
            tab: Tab(
                id: TabID(),
                title: "dragged",
                icon: "terminal.fill",
                kind: "terminal"
            ),
            sourcePaneId: PaneID()
        )
        let registration = try XCTUnwrap(registry.register(transfer))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.issue-11156.test"))
        XCTAssertTrue(registration.write(to: pasteboard))

        registry.endNativeDrag(registration)

        XCTAssertEqual(target.resetCount, 1)
        XCTAssertNil(registry.resolve(from: pasteboard))
    }

    func testCoordinatorRetainsLiveRegistryAfterSecondAdoptionAttempt() {
        let liveRegistry = TabDragTransferRegistry()
        let coordinator = NativeDragCoordinator(tabDragTransferRegistry: liveRegistry)

        XCTAssertFalse(coordinator.adopt(tabDragTransferRegistry: TabDragTransferRegistry()))

        XCTAssertTrue(coordinator.tabDragTransferRegistry === liveRegistry)
    }

    func testAcceptedDropDoesNotLookLikeNativeDragEnd() throws {
        let registry = TabDragTransferRegistry()
        var observerCalls = 0
        let observerID = registry.addNativeDragEndObserver {
            observerCalls += 1
        }
        defer { registry.removeNativeDragEndObserver(observerID) }

        let transfer = TabDragTransfer(
            tab: Tab(title: "dragged", icon: "terminal.fill", kind: "terminal"),
            sourcePaneId: PaneID()
        )
        let registration = try XCTUnwrap(registry.register(transfer))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.issue-11156.accepted"))
        XCTAssertTrue(registration.write(to: pasteboard))

        registry.finish(from: pasteboard)

        XCTAssertEqual(observerCalls, 0)
        XCTAssertNil(registry.resolve(from: pasteboard))
    }

    private final class ResettableTarget {
        var resetCount = 0
    }
}

@MainActor
extension GhosttySurfaceScrollView {
    convenience init(surfaceView: GhosttyNSView) {
        self.init(surfaceView: surfaceView, paneDropTargetRegistry: PaneDropTargetRegistry())
    }
}

@MainActor
extension PaneDropTargetView {
    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, paneDropTargetRegistry: PaneDropTargetRegistry())
    }
}

@MainActor
extension WindowBrowserPortal {
    convenience init(window: NSWindow) {
        self.init(
            window: window,
            paneDropTargetRegistry: TestPaneDropTargetRegistryStore.registry(for: window)
        )
    }

    func bind(
        webView: WKWebView,
        to anchorView: NSView,
        visibleInUI: Bool,
        zPriority: Int = 0,
        paneDropContext: BrowserPaneDropContext? = nil
    ) {
        guard let window = anchorView.window else { return }
        bind(
            webView: webView,
            to: anchorView,
            visibleInUI: visibleInUI,
            zPriority: zPriority,
            paneDropContext: paneDropContext,
            paneDropTargetRegistry: TestPaneDropTargetRegistryStore.registry(for: window)
        )
    }
}

@MainActor
extension WindowBrowserSlotView {
    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, paneDropTargetRegistry: PaneDropTargetRegistry())
    }
}

@MainActor
extension BrowserWindowPortalRegistry {
    static func bind(
        webView: WKWebView,
        to anchorView: NSView,
        visibleInUI: Bool,
        zPriority: Int = 0,
        paneDropContext: BrowserPaneDropContext? = nil
    ) {
        guard let window = anchorView.window else { return }
        bind(
            webView: webView,
            to: anchorView,
            visibleInUI: visibleInUI,
            zPriority: zPriority,
            paneDropContext: paneDropContext,
            paneDropTargetRegistry: TestPaneDropTargetRegistryStore.registry(for: window)
        )
    }
}
