import AppKit
import Quartz
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Panel-owned native view sessions")
struct PanelOwnedNativeViewSessionTests {
    private final class ProbeView: NSView {
        var isClosed = false
        var configureCount = 0
    }

    @Test
    func updateAfterCloseDoesNotReAdoptClosedNativeView() {
        var makeCount = 0
        let session = PanelOwnedNativeViewSession<ProbeView>(
            makeView: {
                makeCount += 1
                return ProbeView(frame: .zero)
            },
            closeView: { view in
                view.isClosed = true
                view.removeFromSuperview()
            }
        )

        let initialView = session.view { view in
            #expect(!view.isClosed)
            view.configureCount += 1
        }

        #expect(makeCount == 1)
        #expect(initialView.configureCount == 1)

        session.close()

        #expect(initialView.isClosed)

        session.update(initialView) { view in
            Issue.record("Closed native views must not be re-adopted or configured after the panel session closes")
            view.configureCount += 1
        }

        #expect(initialView.configureCount == 1)

        let replacementView = session.view { view in
            #expect(!view.isClosed)
            view.configureCount += 1
        }

        #expect(replacementView !== initialView)
        #expect(replacementView.configureCount == 1)
        #expect(makeCount == 2)
    }

    @Test
    func quickLookSessionCreatesFreshViewForEachRepresentableMount() throws {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-4455-quicklook-\(UUID().uuidString).bin")
        try Data([0, 1, 2, 3]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: fileURL.path)
        let session = FilePreviewQuickLookSession()

        let firstView = session.view(
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        )
        let remountedView = session.view(
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        )

        #expect(
            firstView !== remountedView,
            "QuickLook views must be owned by the SwiftUI representable mount, because AppKit can deactivate a QLPreviewView when that mount is removed"
        )

        session.dismantle(firstView)
        session.dismantle(remountedView)
        panel.close()
    }

    @Test
    func quickLookUpdateRetiresPreviewDeactivatedByWindowLoss() throws {
        let firstURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-7311-detach-a-\(UUID().uuidString).txt")
        let secondURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-7311-detach-b-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        try "first".write(to: firstURL, atomically: true, encoding: .utf8)
        try "second".write(to: secondURL, atomically: true, encoding: .utf8)

        let firstPanel = FilePreviewPanel(workspaceId: UUID(), filePath: firstURL.path)
        let secondPanel = FilePreviewPanel(workspaceId: UUID(), filePath: secondURL.path)
        defer {
            firstPanel.close()
            secondPanel.close()
        }
        let session = FilePreviewQuickLookSession()
        let container = try #require(session.view(
            panel: firstPanel,
            revision: firstPanel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        ) as? FilePreviewQuickLookContainerView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            session.dismantle(container)
            window.close()
        }

        window.contentView = container
        let stalePreviewView = try #require(container.livePreviewView())
        #expect(stalePreviewView.previewItem != nil)
        #expect(!stalePreviewView.shouldCloseWithWindow)

        window.contentView = nil
        #expect(stalePreviewView.window == nil)
        #expect(stalePreviewView.superview == nil)
        #expect(stalePreviewView.previewItem == nil)

        session.update(
            container,
            panel: secondPanel,
            revision: secondPanel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        )

        let freshPreviewView = try #require(container.livePreviewView())
        let freshPreviewItem = try #require(freshPreviewView.previewItem)
        #expect(freshPreviewView !== stalePreviewView)
        #expect(freshPreviewItem.previewItemURL == secondURL)
        #expect(stalePreviewView.previewItem == nil)
    }

    @Test
    func quickLookDismantlePermanentlyRetiresOwnedPreview() throws {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-7311-dismantle-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try "preview".write(to: fileURL, atomically: true, encoding: .utf8)

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }
        let session = FilePreviewQuickLookSession()
        let container = try #require(session.view(
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        ) as? FilePreviewQuickLookContainerView)
        let previewView = try #require(container.livePreviewView())
        #expect(previewView.previewItem != nil)

        session.dismantle(container)

        #expect(previewView.previewItem == nil)
        #expect(previewView.superview == nil)
        #expect(container.livePreviewView() == nil)
    }

    @Test
    func quickLookUpdateAfterRetainedWindowCloseReusesAppOwnedPreview() throws {
        let firstURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-7311-window-close-a-\(UUID().uuidString).txt")
        let secondURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-7311-window-close-b-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        try "first".write(to: firstURL, atomically: true, encoding: .utf8)
        try "second".write(to: secondURL, atomically: true, encoding: .utf8)

        let firstPanel = FilePreviewPanel(workspaceId: UUID(), filePath: firstURL.path)
        let secondPanel = FilePreviewPanel(workspaceId: UUID(), filePath: secondURL.path)
        defer {
            firstPanel.close()
            secondPanel.close()
        }
        let session = FilePreviewQuickLookSession()
        let container = try #require(session.view(
            panel: firstPanel,
            revision: firstPanel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        ) as? FilePreviewQuickLookContainerView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            session.dismantle(container)
            window.close()
        }

        window.contentView = container
        let closedPreviewView = try #require(container.livePreviewView())
        #expect(!closedPreviewView.shouldCloseWithWindow)
        #expect(closedPreviewView.previewItem != nil)

        window.close()
        #expect(container.window === window)
        #expect(closedPreviewView.superview === container)

        session.update(
            container,
            panel: secondPanel,
            revision: secondPanel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        )

        let reusedPreviewView = try #require(container.livePreviewView())
        let updatedPreviewItem = try #require(reusedPreviewView.previewItem)
        #expect(reusedPreviewView === closedPreviewView)
        #expect(updatedPreviewItem.previewItemURL == secondURL)
    }
}

@MainActor
@Suite("PDF preview sharing", .serialized)
struct FilePreviewPDFSharingTests {
    private final class SharingPickerProbe: NSSharingServicePicker {
        let sharedItems: [Any]
        let standardItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        private let dispatchedEventType: () -> NSEvent.EventType?
        private(set) weak var presentedView: NSView?
        private(set) var presentedRect: NSRect?
        private(set) var preferredEdge: NSRectEdge?
        private(set) var eventTypeDuringPresentation: NSEvent.EventType?
        private(set) var closeCount = 0

        init(
            items: [Any],
            dispatchedEventType: @escaping () -> NSEvent.EventType? = { nil }
        ) {
            sharedItems = items
            self.dispatchedEventType = dispatchedEventType
            super.init(items: items)
        }

        override func show(
            relativeTo positioningRect: NSRect,
            of positioningView: NSView,
            preferredEdge: NSRectEdge
        ) {
            presentedRect = positioningRect
            presentedView = positioningView
            self.preferredEdge = preferredEdge
            eventTypeDuringPresentation = dispatchedEventType()
        }

        override func close() {
            closeCount += 1
        }

        override var standardShareMenuItem: NSMenuItem {
            standardItem
        }
    }

    @Test
    func mountedPDFChromeRoutesShareOnMouseDown() throws {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-9128-pdf-share-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data("%PDF-1.4".utf8).write(to: fileURL)

        #expect(FilePreviewKindResolver.mode(for: fileURL) == .pdf)

        var dispatchedEventType: NSEvent.EventType?
        var pickers: [SharingPickerProbe] = []
        let presenter = FilePreviewPDFSharingPresenter { items in
            let picker = SharingPickerProbe(
                items: items,
                dispatchedEventType: { dispatchedEventType }
            )
            pickers.append(picker)
            return picker
        }
        let container = FilePreviewPDFContainerView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480),
            sharingPresenter: presenter
        )
        defer { container.close() }
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }
        #expect(panel.previewMode == .pdf)
        container.setPanel(panel)
        container.setURL(fileURL, revision: panel.previewRevision)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()
        defer { window.close() }

        let shareButton = try #require(
            findShareButton(in: container),
            "The mounted PDF chrome must expose its real Share control"
        )
        #expect(
            shareButton.accessibilityLabel()
                == String(localized: "filePreview.share", defaultValue: "Share")
        )

        try dispatchPrimaryClick(to: shareButton, in: window) {
            dispatchedEventType = $0
        }
        dispatchedEventType = nil

        let picker = try #require(pickers.first)
        #expect(pickers.count == 1)
        #expect((picker.sharedItems as? [URL]) == [fileURL])
        #expect(picker.presentedView === shareButton)
        #expect(picker.presentedRect == shareButton.bounds)
        #expect(picker.preferredEdge == .maxY)
        #expect(
            picker.eventTypeDuringPresentation == .leftMouseDown,
            "NSSharingServicePicker presentation must originate synchronously from mouse-down"
        )
    }

    @Test
    func shareActionUsesCurrentPDFAndContainerLifecycle() throws {
        let firstURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-9128-pdf-share-first-\(UUID().uuidString).pdf")
        let secondURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-9128-pdf-share-second-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        try Data("%PDF-1.4".utf8).write(to: firstURL)
        try Data("%PDF-1.4".utf8).write(to: secondURL)

        var pickers: [SharingPickerProbe] = []
        var menuPresentationCount = 0
        let presenter = FilePreviewPDFSharingPresenter(
            presentMenu: { _, _ in
                menuPresentationCount += 1
            },
            makePicker: { items in
                let picker = SharingPickerProbe(items: items)
                pickers.append(picker)
                return picker
            }
        )
        let container = FilePreviewPDFContainerView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480),
            sharingPresenter: presenter
        )
        defer { container.close() }
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: firstURL.path)
        defer { panel.close() }
        container.setPanel(panel)
        container.setURL(firstURL, revision: panel.previewRevision)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()
        defer { window.close() }

        let firstButton = try #require(findShareButton(in: container))
        try dispatchPrimaryClick(to: firstButton, in: window) { _ in }
        let firstPicker = try #require(pickers.first)
        #expect((firstPicker.sharedItems as? [URL]) == [firstURL])
        #expect(firstPicker.presentedView === firstButton)
        #expect(firstPicker.presentedRect == firstButton.bounds)
        #expect(firstPicker.preferredEdge == .maxY)

        container.setURL(secondURL, revision: panel.previewRevision + 1)
        #expect(firstPicker.closeCount == 1)
        container.layoutSubtreeIfNeeded()

        let secondButton = try #require(findShareButton(in: container))
        try dispatchPrimaryClick(to: secondButton, in: window) { _ in }
        let secondPicker = try #require(pickers.last)
        #expect((secondPicker.sharedItems as? [URL]) == [secondURL])

        let pickerCountBeforeDetaching = pickers.count
        window.contentView = nil
        #expect(secondButton.window == nil)
        #expect(secondButton.accessibilityPerformPress())
        #expect(
            pickers.count == pickerCountBeforeDetaching,
            "A detached PDF share control must not create another sharing picker"
        )
        #expect(menuPresentationCount == 0)
        #expect(secondPicker.closeCount == 0)

        container.close()
        #expect(secondPicker.closeCount == 1)
    }

    @Test
    func accessibilityActivationUsesStandardShareMenuItem() throws {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-9128-pdf-share-accessibility-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data("%PDF-1.4".utf8).write(to: fileURL)

        var pickers: [SharingPickerProbe] = []
        var presentedMenu: NSMenu?
        var presentedAnchor: NSView?
        let presenter = FilePreviewPDFSharingPresenter(
            presentMenu: { menu, anchorView in
                presentedMenu = menu
                presentedAnchor = anchorView
            },
            makePicker: { items in
                let picker = SharingPickerProbe(items: items)
                pickers.append(picker)
                return picker
            }
        )
        let container = FilePreviewPDFContainerView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480),
            sharingPresenter: presenter
        )
        defer { container.close() }
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }
        container.setPanel(panel)
        container.setURL(fileURL, revision: panel.previewRevision)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()
        defer { window.close() }

        let shareButton = try #require(findShareButton(in: container))
        #expect(shareButton.accessibilityPerformPress())

        let picker = try #require(pickers.first)
        let menu = try #require(presentedMenu)
        #expect((picker.sharedItems as? [URL]) == [fileURL])
        #expect(presentedAnchor === shareButton)
        #expect(menu.items.count == 1)
        #expect(menu.items.first === picker.standardItem)
        #expect(picker.presentedView == nil)
    }

    private func findShareButton(in view: NSView) -> FilePreviewPDFShareButtonControl? {
        descendants(of: view)
            .compactMap { $0 as? FilePreviewPDFShareButtonControl }
            .first { $0.identifier?.rawValue == "FilePreviewPDFShareButton" }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func dispatchPrimaryClick(
        to button: FilePreviewPDFShareButtonControl,
        in window: NSWindow,
        willDispatch: (NSEvent.EventType) -> Void
    ) throws {
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let pointInWindow = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY),
            to: nil
        )
        let timestamp = ProcessInfo.processInfo.systemUptime
        let mouseDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let mouseUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ))

        #expect(button.window === window)
        NSApp.postEvent(mouseUp, atStart: true)
        willDispatch(.leftMouseDown)
        button.mouseDown(with: mouseDown)
        willDispatch(.leftMouseUp)
    }
}
