import AppKit
import Testing
@testable import CmuxAppKitSupportUI

@MainActor
@Suite
struct CmuxPopoverGroupTests {
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

    @Test func pointerLeavingBothMenusClosesTheGroup() {
        let group = CmuxPopoverGroup()
        let parent = UUID()
        let child = UUID()
        var closed: [UUID] = []
        group.register(
            id: parent,
            parent: nil,
            contains: { _, point in CGRect(x: 0, y: 0, width: 220, height: 240).contains(point) },
            containsPointer: { _, point in CGRect(x: -14, y: -14, width: 248, height: 268).contains(point) },
            close: { closed.append(parent) }
        )
        group.register(
            id: child,
            parent: parent,
            contains: { _, point in CGRect(x: 224, y: 50, width: 220, height: 180).contains(point) },
            containsPointer: { _, point in CGRect(x: 210, y: 36, width: 248, height: 208).contains(point) },
            close: { closed.append(child) }
        )
        group.handleMove(windowNumber: nil, point: CGPoint(x: 220, y: 50))
        #expect(closed.isEmpty)
        group.handleMove(windowNumber: nil, point: CGPoint(x: 700, y: 500))
        #expect(closed == [child, parent])
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
