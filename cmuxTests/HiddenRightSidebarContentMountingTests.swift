import AppKit
import CmuxAppKitSupportUI
import CmuxSettings
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Hidden right sidebar content mounting", .serialized)
struct HiddenRightSidebarContentMountingTests {
    @Test func coldHiddenRightSidebarDoesNotMountContent() {
        #expect(
            !RightSidebarContentMountPolicy.shouldMountContent(
                isRightSidebarVisible: false,
                hasMountedContent: false
            )
        )
    }

    @Test func hiddenRightSidebarKeepsContentMountedAfterInitialMount() {
        #expect(
            RightSidebarContentMountPolicy.shouldMountContent(
                isRightSidebarVisible: false,
                hasMountedContent: true
            )
        )
    }

    @Test func hiddenRightSidebarDoesNotMountFileExplorerPanelContent() {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: "rightSidebar.mode")
        let previousVisibility = defaults.object(forKey: "fileExplorer.isVisible")
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: "rightSidebar.mode")
            } else {
                defaults.removeObject(forKey: "rightSidebar.mode")
            }
            if let previousVisibility {
                defaults.set(previousVisibility, forKey: "fileExplorer.isVisible")
            } else {
                defaults.removeObject(forKey: "fileExplorer.isVisible")
            }
        }

        let fileExplorerState = FileExplorerState()
        fileExplorerState.mode = .find
        fileExplorerState.setVisible(false)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 260),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let rootView = RightSidebarPanelView(
            tabManager: TabManager(),
            fileExplorerStore: FileExplorerStore(),
            fileExplorerState: fileExplorerState,
            sessionIndexStore: SessionIndexStore(),
            notesTreeStore: NotesTreeStore(),
            titlebarHeight: 36,
            windowAppearance: .rightSidebarPanelViewTestDefault,
            workspaceId: nil,
            onResumeSession: nil,
            onOpenFilePreview: { _ in },
            onOpenNote: { _, _ in },
            onResumeNoteSession: { _ in },
            onFocusNoteTerminal: { _ in },
            onResolveTerminalNoteTarget: { _ in nil },
            onOpenAsPane: { _ in },
            onClose: {}
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = window.contentRect(forFrameRect: window.frame)
        window.contentView = hostingView
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let mountedContainer = Self.firstSubview(in: hostingView) { $0 is FileExplorerContainerView }
        #expect(
            mountedContainer == nil,
            "Hidden right-sidebar state should preserve the selected mode without mounting FileExplorerPanelView content"
        )
    }

    private static func firstSubview(
        in view: NSView,
        matching predicate: (NSView) -> Bool
    ) -> NSView? {
        if predicate(view) {
            return view
        }

        for subview in view.subviews {
            if let match = firstSubview(in: subview, matching: predicate) {
                return match
            }
        }

        return nil
    }
}
