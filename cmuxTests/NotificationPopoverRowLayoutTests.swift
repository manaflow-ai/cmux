import AppKit
import CmuxTerminal
import CmuxTerminalCore
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Where a notifications-popover row draws its Cmd-hold shortcut hint.
@MainActor
@Suite("Notification popover row layout", .serialized)
struct NotificationPopoverRowLayoutTests {
    /// The popover's narrowest width.
    private static let rowWidth: CGFloat = 320

    @Test("the shortcut hint never covers the timestamp", arguments: ["⌘3", "⇧⌘3", "⌃⌥⇧⌘9"])
    func hintClearsTheTimestamp(hint: String) throws {
        let frames = RowFrames()
        let row = NotificationPopoverRow(
            notification: TerminalNotification(
                id: UUID(),
                tabId: UUID(),
                surfaceId: nil,
                title: "Agent finished",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                isRead: false
            ),
            workspaceTitle: "main",
            shortcutHint: hint,
            onOpen: {},
            onClear: {},
            onToggleRead: {}
        )
        let window = Self.layOut(RowFrameRecorder(content: row, frames: frames))
        defer { window.close() }

        let timestamp = try #require(frames.frames[NotificationPopoverRowFrames.timestamp], "no timestamp")
        let pill = try #require(frames.frames[NotificationPopoverRowFrames.shortcutHint], "no hint")
        #expect(!pill.intersects(timestamp), "\(hint): hint \(pill) covers timestamp \(timestamp)")
        #expect(pill.maxX <= Self.rowWidth, "\(hint): hint \(pill) runs past the row")
    }

    /// Lays the view out at the popover's width in a window that is never shown.
    private static func layOut<V: View>(_ view: V) -> NSWindow {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.frame(width: rowWidth))
        let size = NSSize(width: rowWidth, height: max(host.fittingSize.height, 1))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        return window
    }
}

@MainActor
private final class RowFrames {
    var frames: [String: CGRect] = [:]

    func record(_ frames: [String: CGRect]) {
        self.frames = frames
    }
}

private struct RowFrameRecorder<Content: View>: View {
    let content: Content
    let frames: RowFrames

    var body: some View {
        content.overlayPreferenceValue(NotificationPopoverRowFrames.self) { anchors in
            GeometryReader { proxy in
                let _ = frames.record(anchors.mapValues { proxy[$0] })
                Color.clear
            }
        }
    }
}
