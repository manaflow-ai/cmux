import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Titlebar interactive controls")
struct TitlebarInteractiveControlTests {
    @Test func dragHandleYieldsToSwiftUITitlebarControlButton() {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 48),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))
        window.contentView = container

        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let config = TitlebarControlsStyle.classic.config
        let button = TitlebarControlButton(
            config: config,
            foregroundColor: .primary,
            accessibilityIdentifier: "titlebarControl.test",
            accessibilityLabel: "Test",
            action: {}
        ) {
            Image(systemName: "sidebar.leading")
        }
        let buttonHost = NSHostingView(rootView: button)
        buttonHost.frame = NSRect(x: 12, y: 14, width: config.buttonSize, height: config.buttonSize)
        container.addSubview(buttonHost)
        buttonHost.layoutSubtreeIfNeeded()

        let buttonPoint = NSPoint(x: buttonHost.frame.midX, y: buttonHost.frame.midY)
        #expect(
            !windowDragHandleShouldCaptureHit(
                dragHandle.convert(buttonPoint, from: nil),
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "SwiftUI titlebar controls must block explicit titlebar dragging at their button hit region."
        )

        #expect(
            windowDragHandleShouldCaptureHit(
                NSPoint(x: 220, y: 24),
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Empty titlebar chrome outside the interactive button should remain draggable."
        )
    }

    @Test func interactiveControlSuppressesSyntheticTitlebarDoubleClick() {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 48),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))
        window.contentView = container

        // Mirror how `titlebarInteractiveControl()` hosts a control: the host must
        // register itself as a titlebar control hit region so the synthetic
        // double-click monitors skip it instead of zooming/minimizing the window.
        let host = TitlebarInteractiveHostingView(rootView: AnyView(Color.clear))
        host.identifier = TitlebarInteractiveHostingView<AnyView>.viewIdentifier
        host.frame = NSRect(x: 12, y: 14, width: 24, height: 24)
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()

        let insideControl = NSPoint(x: host.frame.midX, y: host.frame.midY)
        #expect(
            isMinimalModeTitlebarControlHit(window: window, locationInWindow: insideControl),
            "A double-click on a titlebarInteractiveControl must register as a control hit so the synthetic titlebar double-click (zoom/minimize) is suppressed."
        )

        let emptyTitlebar = NSPoint(x: 220, y: 24)
        #expect(
            !isMinimalModeTitlebarControlHit(window: window, locationInWindow: emptyTitlebar),
            "Empty titlebar chrome away from any interactive control must still trigger the standard titlebar double-click action."
        )
    }
}

@Suite("Titlebar folder title layout")
struct TitlebarFolderTitleLayoutTests {
    // Representative traffic-light + sidebar-control inset: where the folder
    // icon/title lands when the sidebar is collapsed and wider than the minimum.
    private let collapsedInset: CGFloat = 96
    private let defaultMinimum: CGFloat = 216

    @Test("At minimum sidebar width the folder title does not move when toggling the sidebar")
    func stableAtMinimumWidth() {
        let open = TitlebarFolderTitleLayout.leadingInset(
            isFullScreen: false,
            sidebarVisible: true,
            sidebarWidth: defaultMinimum,
            minimumSidebarWidth: defaultMinimum,
            collapsedInset: collapsedInset
        )
        let collapsed = TitlebarFolderTitleLayout.leadingInset(
            isFullScreen: false,
            sidebarVisible: false,
            sidebarWidth: defaultMinimum,
            minimumSidebarWidth: defaultMinimum,
            collapsedInset: collapsedInset
        )
        #expect(
            open == collapsed,
            "At minimum sidebar width, the folder icon/title must hold its x-position when the sidebar is toggled."
        )
    }

    @Test("Collapsing at minimum width keeps the folder title at the open (content) position")
    func collapsedAtMinimumUsesOpenAnchor() {
        let collapsed = TitlebarFolderTitleLayout.leadingInset(
            isFullScreen: false,
            sidebarVisible: false,
            sidebarWidth: defaultMinimum,
            minimumSidebarWidth: defaultMinimum,
            collapsedInset: collapsedInset
        )
        #expect(collapsed == defaultMinimum + TitlebarFolderTitleLayout.openSidebarGap)
    }

    @Test("Above minimum width collapsing the sidebar still moves the folder title")
    func movesAboveMinimumWidth() {
        let width = defaultMinimum + 140
        let open = TitlebarFolderTitleLayout.leadingInset(
            isFullScreen: false,
            sidebarVisible: true,
            sidebarWidth: width,
            minimumSidebarWidth: defaultMinimum,
            collapsedInset: collapsedInset
        )
        let collapsed = TitlebarFolderTitleLayout.leadingInset(
            isFullScreen: false,
            sidebarVisible: false,
            sidebarWidth: width,
            minimumSidebarWidth: defaultMinimum,
            collapsedInset: collapsedInset
        )
        #expect(open != collapsed)
        #expect(
            collapsed == collapsedInset,
            "Above minimum width, a collapsed sidebar returns the title to the traffic-light inset."
        )
    }

    @Test(
        "Configured minimum widths still pin the collapsed title",
        arguments: [120.0, 180.0, 216.0, 260.0] as [CGFloat]
    )
    func stableAtConfiguredMinimum(_ minimum: CGFloat) {
        let open = TitlebarFolderTitleLayout.leadingInset(
            isFullScreen: false,
            sidebarVisible: true,
            sidebarWidth: minimum,
            minimumSidebarWidth: minimum,
            collapsedInset: collapsedInset
        )
        let collapsed = TitlebarFolderTitleLayout.leadingInset(
            isFullScreen: false,
            sidebarVisible: false,
            sidebarWidth: minimum,
            minimumSidebarWidth: minimum,
            collapsedInset: collapsedInset
        )
        #expect(open == collapsed)
    }

    @Test("A width within tolerance of the minimum is treated as minimum")
    func toleranceTreatedAsMinimum() {
        let width = defaultMinimum + TitlebarFolderTitleLayout.minimumWidthTolerance / 2
        let open = TitlebarFolderTitleLayout.leadingInset(
            isFullScreen: false,
            sidebarVisible: true,
            sidebarWidth: width,
            minimumSidebarWidth: defaultMinimum,
            collapsedInset: collapsedInset
        )
        let collapsed = TitlebarFolderTitleLayout.leadingInset(
            isFullScreen: false,
            sidebarVisible: false,
            sidebarWidth: width,
            minimumSidebarWidth: defaultMinimum,
            collapsedInset: collapsedInset
        )
        #expect(open == collapsed)
    }

    @Test("Fullscreen with the sidebar collapsed uses the inline fullscreen inset")
    func fullscreenCollapsedUsesInlineInset() {
        let inset = TitlebarFolderTitleLayout.leadingInset(
            isFullScreen: true,
            sidebarVisible: false,
            sidebarWidth: defaultMinimum,
            minimumSidebarWidth: defaultMinimum,
            collapsedInset: collapsedInset
        )
        #expect(inset == TitlebarFolderTitleLayout.fullscreenCollapsedInset)
    }
}
