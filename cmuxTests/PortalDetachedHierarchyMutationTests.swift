import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private func makeRegisteredPortalHierarchy() throws -> (
    window: NSWindow,
    rootView: NSView,
    splitView: NSSplitView,
    panes: [NSView],
    siblingView: NSView,
    invalidator: PortalSplitDividerCacheInvalidator
) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    let rootView = try #require(window.contentView)
    let splitView = NSSplitView(frame: rootView.bounds)
    splitView.isVertical = true
    let panes = [
        NSView(frame: NSRect(x: 0, y: 0, width: 120, height: rootView.bounds.height)),
        NSView(frame: NSRect(x: 121, y: 0, width: 199, height: rootView.bounds.height)),
    ]
    for pane in panes {
        splitView.addSubview(pane)
    }
    let siblingView = NSView(frame: NSRect(x: 1, y: 0, width: 1, height: 1))
    rootView.addSubview(splitView)
    rootView.addSubview(siblingView)

    let invalidator = PortalSplitDividerCacheInvalidator()
    let collected = PortalSplitDividerRegion.collect(in: rootView)
    invalidator.observe(
        rootView: rootView,
        geometryViews: collected.geometryObservedViews,
        hierarchyNodes: collected.hierarchyNodes
    ) {}
    #expect(invalidator.isHierarchyCurrent(for: rootView))
    return (window, rootView, splitView, panes, siblingView, invalidator)
}

@MainActor
@Suite(.serialized)
struct PortalDetachedArrangedSubviewBoundaryTests {
    @Test
    func detachingRegisteredRootRevokesCacheBeforeArrangedSubviewReorder() throws {
        let fixture = try makeRegisteredPortalHierarchy()
        defer { fixture.window.orderOut(nil) }
        defer { fixture.invalidator.invalidate() }

        fixture.window.contentView = NSView(frame: fixture.rootView.frame)
        #expect(fixture.splitView.window == nil)
        #expect(
            !fixture.invalidator.isHierarchyCurrent(for: fixture.rootView),
            "Removing a registered split-bearing root must revoke its cache before detached mutations."
        )

        fixture.splitView.removeArrangedSubview(fixture.panes[1])
        fixture.splitView.insertArrangedSubview(fixture.panes[1], at: 0)
        #expect(fixture.splitView.arrangedSubviews.first === fixture.panes[1])

        fixture.window.contentView = fixture.rootView
        #expect(!fixture.invalidator.isHierarchyCurrent(for: fixture.rootView))
    }
}

@MainActor
@Suite(.serialized)
struct PortalDetachedSubviewSortBoundaryTests {
    @Test
    func detachingRegisteredRootRevokesCacheBeforeSubviewSort() throws {
        let fixture = try makeRegisteredPortalHierarchy()
        defer { fixture.window.orderOut(nil) }
        defer { fixture.invalidator.invalidate() }

        fixture.window.contentView = NSView(frame: fixture.rootView.frame)
        #expect(fixture.rootView.window == nil)
        #expect(
            !fixture.invalidator.isHierarchyCurrent(for: fixture.rootView),
            "Removing a registered split-bearing root must revoke its cache before detached mutations."
        )

        fixture.rootView.sortSubviews({ lhs, rhs, _ in
            if lhs.frame.minX == rhs.frame.minX { return .orderedSame }
            return lhs.frame.minX < rhs.frame.minX ? .orderedDescending : .orderedAscending
        }, context: nil)
        #expect(fixture.rootView.subviews.first === fixture.siblingView)

        fixture.window.contentView = fixture.rootView
        #expect(!fixture.invalidator.isHierarchyCurrent(for: fixture.rootView))
    }
}
