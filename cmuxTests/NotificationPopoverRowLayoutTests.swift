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

/// Where a notifications-popover row draws its Cmd-hold shortcut hint, read from rendered pixels.
@MainActor
@Suite("Notification popover row layout", .serialized)
struct NotificationPopoverRowLayoutTests {
    /// The popover's narrowest width.
    private static let rowWidth: CGFloat = 320
    private static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// The time is found as the pixels that change when only the time changes. The pill is found
    /// from its digit, the pixels that change when only the digit changes (the pill sets digits
    /// monospaced, so its size does not change): the same digit drawn in a pill on its own gives
    /// the digit's offset inside the pill, and so where the pill starts in the row.
    @Test("the shortcut hint never covers the timestamp", arguments: ["⌘", "⇧⌘", "⌃⌥⇧⌘"])
    func hintClearsTheTimestamp(prefix: String) throws {
        let base = try Self.renderRow(createdAt: Self.createdAt, hint: prefix + "3")
        let laterTime = try Self.renderRow(createdAt: Self.createdAt + 7 * 3_600 + 37 * 60, hint: prefix + "3")
        let otherDigit = try Self.renderRow(createdAt: Self.createdAt, hint: prefix + "8")
        let time = try #require(Self.differenceBounds(base.bitmap, laterTime.bitmap), "the time drew nothing")
        let digitInRow = try #require(Self.differenceBounds(base.bitmap, otherDigit.bitmap), "the hint drew nothing")

        let pill = try Self.renderPill(prefix + "3")
        let pillOther = try Self.renderPill(prefix + "8")
        let digitInPill = try #require(Self.differenceBounds(pill.bitmap, pillOther.bitmap), "the pill drew nothing")

        let scale = base.scale
        let pillStart = (digitInRow.minX - digitInPill.minX * scale / pill.scale) / scale
        let pillEnd = pillStart + pill.width
        let timeEnd = time.maxX / scale
        #expect(timeEnd <= pillStart, "\(prefix)3: the time ends at \(timeEnd), past the hint's start at \(pillStart)")
        #expect(pillEnd <= Self.rowWidth, "\(prefix)3: the hint ends at \(pillEnd), past the row")
    }

    /// Holding the modifier must not change a row's height, or the whole list jumps on every
    /// press and release of Cmd.
    @Test("showing the shortcut hint keeps the row's height", arguments: ["⌘", "⌃⌥⇧⌘"])
    func hintKeepsTheRowHeight(prefix: String) {
        func height(showsHint: Bool) -> CGFloat {
            _ = NSApplication.shared
            let row = NotificationPopoverRow(
                notification: TerminalNotification(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    tabId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    surfaceId: nil,
                    title: "Agent finished",
                    subtitle: "",
                    body: "Ran the focused tests and pushed the branch",
                    createdAt: Self.createdAt,
                    isRead: false
                ),
                workspaceTitle: "main",
                shortcut: prefix + "3",
                showsShortcutHint: showsHint,
                onOpen: {},
                onClear: {},
                onToggleRead: {}
            )
            return NSHostingView(rootView: row.frame(width: Self.rowWidth)).fittingSize.height
        }
        #expect(height(showsHint: true) == height(showsHint: false))
    }

    private struct Rendered {
        let bitmap: NSBitmapImageRep
        /// Pixels per point.
        let scale: CGFloat
        /// The view's width in points.
        let width: CGFloat
    }

    private static func renderRow(createdAt: Date, hint: String) throws -> Rendered {
        let row = NotificationPopoverRow(
            notification: TerminalNotification(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                tabId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                surfaceId: nil,
                title: "Agent finished",
                subtitle: "",
                body: "",
                createdAt: createdAt,
                isRead: false
            ),
            workspaceTitle: "main",
            shortcut: hint,
            showsShortcutHint: true,
            onOpen: {},
            onClear: {},
            onToggleRead: {}
        )
        return try render(row.frame(width: rowWidth), width: rowWidth)
    }

    private static func renderPill(_ text: String) throws -> Rendered {
        let pill = ShortcutHintPill(text: text, fontSize: 10, emphasis: 1.05)
        let width = NSHostingView(rootView: pill).fittingSize.width
        return try render(pill.frame(width: width), width: width)
    }

    /// Draws `view` at `width` in a window that is never shown.
    private static func render<V: View>(_ view: V, width: CGFloat) throws -> Rendered {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let size = NSSize(width: width, height: max(host.fittingSize.height, 1))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return Rendered(bitmap: bitmap, scale: CGFloat(bitmap.pixelsWide) / width, width: width)
    }

    /// The pixel rectangle where two renderings of the same size differ, or nil where they match.
    private static func differenceBounds(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> CGRect? {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else { return nil }
        var bounds: CGRect?
        for y in 0..<lhs.pixelsHigh {
            for x in 0..<lhs.pixelsWide {
                guard let a = lhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = rhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let delta = abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                    + abs(a.alphaComponent - b.alphaComponent)
                guard delta > 0.18 else { continue }
                let point = CGRect(x: x, y: y, width: 1, height: 1)
                bounds = bounds.map { $0.union(point) } ?? point
            }
        }
        return bounds
    }
}

/// What VoiceOver reads on a notifications-popover row.
@MainActor
@Suite("Notification popover row accessibility", .serialized)
struct NotificationPopoverRowAccessibilityTests {
    /// The digit shortcut is the row button's value whether or not the modifier is held, as
    /// Jump to Latest gives its shortcut, since a VoiceOver user cannot see the hint pill.
    @Test("each row's digit shortcut is its accessibility value", arguments: [false, true])
    func rowShortcutIsTheAccessibilityValue(showsHint: Bool) throws {
        let id = UUID()
        let row = NotificationPopoverRow(
            notification: TerminalNotification(
                id: id,
                tabId: UUID(),
                surfaceId: nil,
                title: "Agent finished",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                isRead: false
            ),
            workspaceTitle: "main",
            shortcut: "⌘3",
            showsShortcutHint: showsHint,
            onOpen: {},
            onClear: {},
            onToggleRead: {}
        )
        _ = NSApplication.shared
        // With no assistive client attached, SwiftUI vends no accessibility tree in the test
        // host unless the environment says one is listening.
        let host = NSHostingView(rootView: row.frame(width: 320).environment(\.accessibilityEnabled, true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        defer { window.close() }
        window.contentView = host
        host.frame = window.contentLayoutRect
        window.orderFront(nil)
        let identifier = "NotificationPopoverRow.\(id.uuidString)"
        var found: NSObject?
        var seen: [String] = []
        for _ in 0..<200 where found == nil {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            (found, seen) = Self.element(in: host, identifier: identifier)
        }
        let button = try #require(found, "no accessibility element \(identifier); saw \(seen)")
        #expect(Self.attribute(.value, getter: "accessibilityValue", of: button) as? String == "⌘3")
    }

    /// The first node under `root` whose accessibility identifier is `identifier`, and every
    /// node's type and identifier seen on the way.
    private static func element(in root: NSView, identifier: String) -> (NSObject?, [String]) {
        var queue: [NSObject] = [root]
        var seen: [String] = []
        while !queue.isEmpty {
            let node = queue.removeFirst()
            let nodeIdentifier = attribute(.identifier, getter: "accessibilityIdentifier", of: node) as? String
            seen.append("\(type(of: node)):\(nodeIdentifier ?? "")")
            if nodeIdentifier == identifier { return (node, seen) }
            let children = attribute(.children, getter: "accessibilityChildren", of: node) as? [Any] ?? []
            queue.append(contentsOf: NSAccessibility.unignoredChildren(from: children).compactMap { $0 as? NSObject })
        }
        return (nil, seen)
    }

    /// Reads an accessibility attribute through either API, since SwiftUI's nodes may answer
    /// only the older `accessibilityAttributeValue:`.
    private static func attribute(_ attribute: NSAccessibility.Attribute, getter: String, of object: NSObject) -> Any? {
        let modern = NSSelectorFromString(getter)
        if object.responds(to: modern), let value = object.perform(modern)?.takeUnretainedValue() {
            return value
        }
        let names = NSSelectorFromString("accessibilityAttributeNames")
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: names), object.responds(to: legacy),
              let attributes = object.perform(names)?.takeUnretainedValue() as? [String],
              attributes.contains(attribute.rawValue) else { return nil }
        return object.perform(legacy, with: attribute.rawValue)?.takeUnretainedValue()
    }
}
