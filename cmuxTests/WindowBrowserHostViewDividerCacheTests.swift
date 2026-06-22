import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor
@Suite(.serialized)
struct WindowBrowserHostViewDividerCacheTests {
    @Test func hostViewReusesDividerRegionsForSteadyStatePointerHits() throws {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView, "Expected content view")
        let container = try #require(contentView.superview, "Expected window content container")

        let splitView = NSSplitView(frame: contentView.bounds.insetBy(dx: 0, dy: 20))
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height)))
        splitView.addSubview(NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height)))
        contentView.addSubview(splitView)
        splitView.adjustSubviews()

        let secondarySplitView = NSSplitView(frame: NSRect(x: 240, y: 0, width: 60, height: contentView.bounds.height))
        secondarySplitView.autoresizingMask = [.minXMargin, .height]
        secondarySplitView.isVertical = true
        secondarySplitView.dividerStyle = .thin
        secondarySplitView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 24, height: contentView.bounds.height)))
        secondarySplitView.addSubview(NSView(frame: NSRect(x: 25, y: 0, width: 35, height: contentView.bounds.height)))
        contentView.addSubview(secondarySplitView)
        secondarySplitView.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let (host, child) = installHost(in: contentView, container: container)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        #expect(host.hitTest(dividerPointInHost) == nil)
        let buildCountAfterWarmHit = host.dividerRegionBuildCount
        #expect(buildCountAfterWarmHit > 0)

        #expect(host.hitTest(dividerPointInHost) == nil)
        #expect(
            host.dividerRegionBuildCount == buildCountAfterWarmHit,
            "Steady-state browser divider hit-testing should reuse indexed divider regions instead of rebuilding them for every pointer event"
        )

        let outsideDividerPointInSplit = NSPoint(x: dividerPointInSplit.x, y: -3)
        let outsideDividerPointInWindow = splitView.convert(outsideDividerPointInSplit, to: nil)
        let outsideDividerPointInHost = host.convert(outsideDividerPointInWindow, from: nil)
        #expect(
            host.hitTest(outsideDividerPointInHost) === child,
            "Expanded cached browser divider hits must not leak outside their owning split view"
        )
        #expect(
            host.dividerRegionBuildCount == buildCountAfterWarmHit,
            "Out-of-bounds browser divider probes should reuse the cache without treating the expanded rect as a hit"
        )

        splitView.setPosition(180, ofDividerAt: 0)
        splitView.adjustSubviews()
        NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification, object: splitView)
        contentView.layoutSubtreeIfNeeded()

        let movedDividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let movedDividerPointInWindow = splitView.convert(movedDividerPointInSplit, to: nil)
        let movedDividerPointInHost = host.convert(movedDividerPointInWindow, from: nil)
        #expect(host.hitTest(movedDividerPointInHost) == nil)
        let buildCountAfterInvalidation = host.dividerRegionBuildCount
        #expect(
            buildCountAfterInvalidation > buildCountAfterWarmHit,
            "Split resize notifications should invalidate cached browser divider regions"
        )

        #expect(host.hitTest(movedDividerPointInHost) == nil)
        #expect(
            host.dividerRegionBuildCount == buildCountAfterInvalidation,
            "Browser divider hit-testing should reuse regions again after the invalidation rebuild"
        )

        splitView.isHidden = true
        contentView.layoutSubtreeIfNeeded()
        #expect(
            host.hitTest(movedDividerPointInHost) === child,
            "Hidden app split dividers must not keep stale browser pass-through regions active"
        )
        let buildCountAfterHiddenHit = host.dividerRegionBuildCount
        #expect(
            buildCountAfterHiddenHit > buildCountAfterInvalidation,
            "Hidden split views should invalidate cached browser divider regions on the next pointer hit"
        )

        splitView.isHidden = false
        contentView.layoutSubtreeIfNeeded()
        #expect(
            host.hitTest(movedDividerPointInHost) == nil,
            "Revealed app split dividers should pass through again without waiting for a resize notification"
        )
        #expect(
            host.dividerRegionBuildCount > buildCountAfterHiddenHit,
            "Empty browser divider caches should be rebuilt after hidden split views are revealed"
        )
    }

    @Test func hostViewReusesEmptyDividerRegionCacheForSteadyStatePointerHits() throws {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView, "Expected content view")
        let container = try #require(contentView.superview, "Expected window content container")

        let splitView = NSSplitView(frame: contentView.bounds.insetBy(dx: 20, dy: 20))
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: splitView.bounds.height)))
        contentView.addSubview(splitView)
        splitView.adjustSubviews()

        let (host, child) = installHost(in: contentView, container: container)
        contentView.layoutSubtreeIfNeeded()

        let point = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        #expect(host.hitTest(point) === child, "Browser content should receive hits when no split divider exists")
        let buildCountAfterWarmHit = host.dividerRegionBuildCount
        #expect(buildCountAfterWarmHit > 0)

        #expect(
            host.hitTest(point) === child,
            "Browser content should keep receiving hits when the cached divider list is empty"
        )
        #expect(
            host.dividerRegionBuildCount == buildCountAfterWarmHit,
            "Steady-state browser hit-testing should reuse an empty divider-region cache instead of rescanning every pointer event"
        )

        let second = NSView(frame: NSRect(x: 121, y: 0, width: 139, height: splitView.bounds.height))
        splitView.addSubview(second)
        splitView.setPosition(120, ofDividerAt: 0)
        splitView.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        #expect(
            host.hitTest(dividerPointInHost) == nil,
            "Visible browser split views that gain a divider should invalidate an empty cached scan"
        )
        #expect(
            host.dividerRegionBuildCount > buildCountAfterWarmHit,
            "Regionless browser split views should be tracked so later dividers trigger a cache rebuild"
        )
    }

    @Test func hostViewInvalidatesHostedDividerRegionsWhenSlotHidesAndReveals() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView, "Expected content view")
        let container = try #require(contentView.superview, "Expected window content container")

        let (host, child) = installHost(in: contentView, container: container)

        let slot = WindowBrowserSlotView(frame: host.bounds)
        slot.autoresizingMask = [.width, .height]
        host.addSubview(slot)

        let inspectorSplit = NSSplitView(frame: slot.bounds)
        inspectorSplit.autoresizingMask = [.width, .height]
        inspectorSplit.isVertical = false
        inspectorSplit.dividerStyle = .thin
        let pageView = NSView(frame: NSRect(x: 0, y: 0, width: slot.bounds.width, height: 140))
        let inspectorView = NSView(frame: NSRect(x: 0, y: 141, width: slot.bounds.width, height: 79))
        inspectorSplit.addSubview(pageView)
        inspectorSplit.addSubview(inspectorView)
        slot.addSubview(inspectorSplit)
        inspectorSplit.setPosition(140, ofDividerAt: 0)
        inspectorSplit.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSplit = NSPoint(
            x: inspectorSplit.bounds.midX,
            y: inspectorSplit.arrangedSubviews[0].frame.maxY + (inspectorSplit.dividerThickness * 0.5)
        )
        let dividerPointInWindow = inspectorSplit.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        let warmHit = host.hitTest(dividerPointInHost)
        #expect(warmHit != nil)
        #expect(warmHit !== child)
        let buildCountAfterWarmHit = host.dividerRegionBuildCount
        #expect(buildCountAfterWarmHit > 0)

        slot.isHidden = true
        #expect(
            host.hitTest(dividerPointInHost) === child,
            "Hidden browser slots must not keep stale hosted inspector divider hit regions active"
        )
        let buildCountAfterHide = host.dividerRegionBuildCount
        #expect(
            buildCountAfterHide > buildCountAfterWarmHit,
            "Hiding a browser slot should invalidate hosted divider regions"
        )

        slot.isHidden = false
        let revealedHit = host.hitTest(dividerPointInHost)
        #expect(revealedHit != nil)
        #expect(
            revealedHit !== child,
            "Revealed browser slots should rebuild hosted inspector divider regions without waiting for a resize"
        )
        #expect(
            host.dividerRegionBuildCount > buildCountAfterHide,
            "Revealing a browser slot should invalidate hosted divider regions"
        )
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    private func installHost(
        in contentView: NSView,
        container: NSView
    ) -> (host: WindowBrowserHostView, child: NSView) {
        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        let child = NSView(frame: host.bounds)
        child.autoresizingMask = [.width, .height]
        host.addSubview(child)
        container.addSubview(host, positioned: .above, relativeTo: contentView)
        return (host, child)
    }
}
#endif
