import AppKit
import SwiftUI
import Testing
@testable import CmuxAppKitSupportUI

@MainActor
@Suite
struct CmuxPopoverGroupTests {
    @Test func groupedRootUsesNativeOpeningAnimation() {
        let coordinator = ArrowlessPopoverAnchor<EmptyView>.Coordinator(
            isPresented: .constant(true), group: CmuxPopoverGroup()
        )
        #expect(coordinator.shouldAnimatePresentation(
            reduceMotion: false, isSubmenu: false
        ))
    }

    @Test func groupedSubmenuRemainsImmediate() {
        let coordinator = ArrowlessPopoverAnchor<EmptyView>.Coordinator(
            isPresented: .constant(true), group: CmuxPopoverGroup()
        )
        #expect(!coordinator.shouldAnimatePresentation(
            reduceMotion: false, isSubmenu: true
        ))
    }

    @Test(arguments: [false, true])
    func reduceMotionDisablesOpeningAnimationForRootAndSubmenu(isSubmenu: Bool) {
        let coordinator = ArrowlessPopoverAnchor<EmptyView>.Coordinator(
            isPresented: .constant(true), group: CmuxPopoverGroup()
        )
        #expect(!coordinator.shouldAnimatePresentation(
            reduceMotion: true, isSubmenu: isSubmenu
        ))
    }

    @Test func clicksInsideEitherMenuKeepBothOpen() {
        let group = CmuxPopoverGroup()
        let parent = UUID()
        let child = UUID()
        var closed: [UUID] = []
        group.register(id: parent, parent: nil, contains: { _, point in
            CGRect(x: 0, y: 0, width: 220, height: 240).contains(point)
        }, close: { closed.append(parent) })
        group.register(id: child, parent: parent, contains: { _, point in
            CGRect(x: 224, y: 50, width: 220, height: 180).contains(point)
        }, close: { closed.append(child) })

        group.handleClick(windowNumber: nil, point: CGPoint(x: 40, y: 80))
        group.handleClick(windowNumber: nil, point: CGPoint(x: 250, y: 80))
        #expect(closed.isEmpty)

        group.handleClick(windowNumber: nil, point: CGPoint(x: 600, y: 80))
        #expect(closed == [child, parent])
        group.dismissAll()
        #expect(closed == [child, parent])
    }

    @Test func closingParentAlsoClosesItsSubmenu() {
        let group = CmuxPopoverGroup()
        let parent = UUID()
        let child = UUID()
        let grandchild = UUID()
        var closed: [UUID] = []
        for (id, owner) in [(parent, nil), (child, parent), (grandchild, child)] as [(UUID, UUID?)] {
            group.register(id: id, parent: owner, contains: { _, _ in true }, close: {
                closed.append(id)
                group.unregister(id)
            })
        }
        group.unregister(parent)
        #expect(closed == [grandchild, child])
        group.dismissAll()
        #expect(closed == [grandchild, child])
    }

    @Test func closingOnlySubmenuLeavesParentUntilOutsideClick() {
        let group = CmuxPopoverGroup()
        let parent = UUID()
        let child = UUID()
        var closed: [UUID] = []
        group.register(id: parent, parent: nil, contains: { _, point in point.x < 220 }, close: {
            closed.append(parent)
        })
        group.register(id: child, parent: parent, contains: { _, _ in true }, close: {
            closed.append(child)
        })
        group.unregister(child)
        group.handleClick(windowNumber: nil, point: CGPoint(x: 40, y: 80))
        #expect(closed.isEmpty)
        group.handleClick(windowNumber: nil, point: CGPoint(x: 250, y: 80))
        #expect(closed == [parent])
    }

    @Test func hoverKeepsSourceAndSubmenuOpenThenClosesOnlySubmenu() {
        let group = CmuxPopoverGroup()
        let parent = UUID()
        let child = UUID()
        var closed: [UUID] = []
        let region = CmuxSubmenuHoverRegion(
            source: CGRect(x: 12, y: 100, width: 196, height: 26),
            submenu: CGRect(x: 224, y: 50, width: 220, height: 180)
        )
        group.register(
            id: parent,
            parent: nil,
            contains: { _, point in CGRect(x: 0, y: 0, width: 220, height: 240).contains(point) },
            close: { closed.append(parent) }
        )
        group.register(
            id: child,
            parent: parent,
            contains: { _, point in CGRect(x: 224, y: 50, width: 220, height: 180).contains(point) },
            containsPointer: { _, point in region.contains(point) },
            close: {
                closed.append(child)
                group.unregister(child)
            }
        )
        group.handleMove(windowNumber: 1, point: CGPoint(x: 80, y: 113))
        group.handleMove(windowNumber: 2, point: CGPoint(x: 250, y: 80))
        group.handleMove(windowNumber: 1, point: CGPoint(x: 216, y: 90))
        #expect(closed.isEmpty)
        // Settings is inside the account popover, outside the team row.
        group.handleMove(windowNumber: 1, point: CGPoint(x: 80, y: 160))
        #expect(closed == [child])
        group.handleMove(windowNumber: nil, point: CGPoint(x: 700, y: 500))
        #expect(closed == [child])
        group.handleClick(windowNumber: nil, point: CGPoint(x: 700, y: 500))
        #expect(closed == [child, parent])
    }

    @Test func hoverRegionSupportsLeftAndRightSubmenusWithoutExtraPadding() {
        let row = CGRect(x: 230, y: 100, width: 196, height: 26)
        let right = CmuxSubmenuHoverRegion(source: row, submenu: CGRect(x: 442, y: 50, width: 220, height: 180))
        let left = CmuxSubmenuHoverRegion(source: row, submenu: CGRect(x: -6, y: 50, width: 220, height: 180))
        #expect(right.contains(CGPoint(x: 434, y: 90)))
        #expect(left.contains(CGPoint(x: 222, y: 90)))
        #expect(!right.contains(CGPoint(x: 300, y: 160)))
        #expect(!left.contains(CGPoint(x: 300, y: 160)))
        #expect(!right.contains(CGPoint(x: 670, y: 160)))
        #expect(!left.contains(CGPoint(x: -10, y: 160)))
        #expect(!right.contains(CGPoint(x: 434, y: 240)))
    }

    @Test func mouseMovementSubscriptionRestoresTheWindowSetting() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let anchor = NSView(frame: CGRect(x: 10, y: 10, width: 100, height: 26))
        window.contentView?.addSubview(anchor)
        window.acceptsMouseMovedEvents = false
        let group = CmuxPopoverGroup()
        let popover = NSPopover()
        let member = group.register(popover: popover, anchor: anchor)
        #expect(window.acceptsMouseMovedEvents)
        group.unregister(member)
        #expect(!window.acceptsMouseMovedEvents)
    }

    @Test func reopenedMenuDoesNotKeepStaleMemberWindows() {
        let group = CmuxPopoverGroup()
        let first = UUID()
        var closed: [UUID] = []
        group.register(id: first, parent: nil, contains: { _, _ in true }, close: {
            closed.append(first)
            group.unregister(first)
        })
        group.dismissAll()

        let second = UUID()
        group.register(id: second, parent: nil, contains: { _, _ in false }, close: {
            closed.append(second)
        })
        group.handleClick(windowNumber: nil, point: .zero)
        #expect(closed == [first, second])
    }
}
