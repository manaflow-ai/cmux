import AppKit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor
@Suite(.serialized)
struct WindowTerminalHostViewDividerCacheTests {
    @Test func hostViewReusesDividerRegionsForSteadyStatePointerHits() throws {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView, "Expected content view")

        let splitView = NSSplitView(frame: contentView.bounds.insetBy(dx: 0, dy: 20))
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height)))
        splitView.addSubview(NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height)))
        contentView.addSubview(splitView)
        splitView.adjustSubviews()

        let secondarySplitView = NSSplitView(frame: NSRect(x: 220, y: 0, width: 80, height: contentView.bounds.height))
        secondarySplitView.autoresizingMask = [.minXMargin, .height]
        secondarySplitView.isVertical = true
        secondarySplitView.dividerStyle = .thin
        secondarySplitView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 30, height: contentView.bounds.height)))
        secondarySplitView.addSubview(NSView(frame: NSRect(x: 31, y: 0, width: 49, height: contentView.bounds.height)))
        contentView.addSubview(secondarySplitView)
        secondarySplitView.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.autoresizingMask = [.width, .height]
        let hostedView = makeHostedTerminalView(frame: host.bounds)
        host.addSubview(hostedView)
        contentView.addSubview(host)

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
            "Steady-state terminal divider hit-testing should reuse indexed divider regions instead of rebuilding them for every pointer event"
        )

        let outsideDividerPointInSplit = NSPoint(x: dividerPointInSplit.x, y: -3)
        let outsideDividerPointInWindow = splitView.convert(outsideDividerPointInSplit, to: nil)
        let outsideDividerPointInHost = host.convert(outsideDividerPointInWindow, from: nil)
        #expect(
            hitFallsInsideHostedTerminal(host.hitTest(outsideDividerPointInHost), hostedView: hostedView),
            "Expanded cached terminal divider hits must not leak outside their owning split view"
        )
        #expect(
            host.dividerRegionBuildCount == buildCountAfterWarmHit,
            "Out-of-bounds terminal divider probes should reuse the cache without treating the expanded rect as a hit"
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
            "Split resize notifications should invalidate cached terminal divider regions"
        )

        #expect(host.hitTest(movedDividerPointInHost) == nil)
        #expect(
            host.dividerRegionBuildCount == buildCountAfterInvalidation,
            "Terminal divider hit-testing should reuse regions again after the invalidation rebuild"
        )
    }

    @Test func hostViewReusesEmptyDividerRegionCacheForSteadyStatePointerHits() throws {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView, "Expected content view")

        let splitView = NSSplitView(frame: contentView.bounds.insetBy(dx: 20, dy: 20))
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: splitView.bounds.height)))
        contentView.addSubview(splitView)
        splitView.adjustSubviews()

        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.autoresizingMask = [.width, .height]
        let hostedView = makeHostedTerminalView(frame: host.bounds)
        host.addSubview(hostedView)
        contentView.addSubview(host)
        contentView.layoutSubtreeIfNeeded()

        let point = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        #expect(
            hitFallsInsideHostedTerminal(host.hitTest(point), hostedView: hostedView),
            "Terminal content should receive hits when no split divider exists"
        )
        let buildCountAfterWarmHit = host.dividerRegionBuildCount
        #expect(buildCountAfterWarmHit > 0)

        #expect(
            hitFallsInsideHostedTerminal(host.hitTest(point), hostedView: hostedView),
            "Terminal content should keep receiving hits when the cached divider list is empty"
        )
        #expect(
            host.dividerRegionBuildCount == buildCountAfterWarmHit,
            "Steady-state terminal hit-testing should reuse an empty divider-region cache instead of rescanning every pointer event"
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
            "Visible terminal split views that gain a divider should invalidate an empty cached scan"
        )
        #expect(
            host.dividerRegionBuildCount > buildCountAfterWarmHit,
            "Regionless terminal split views should be tracked so later dividers trigger a cache rebuild"
        )
    }

    @Test func hostViewRebuildsEmptyCacheWhenNewNestedSplitIsInserted() throws {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView, "Expected content view")

        let container = NSView(frame: contentView.bounds.insetBy(dx: 20, dy: 20))
        container.autoresizingMask = [.width, .height]
        contentView.addSubview(container)

        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.autoresizingMask = [.width, .height]
        let hostedView = makeHostedTerminalView(frame: host.bounds)
        host.addSubview(hostedView)
        contentView.addSubview(host)
        contentView.layoutSubtreeIfNeeded()

        let point = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        #expect(hitFallsInsideHostedTerminal(host.hitTest(point), hostedView: hostedView))
        let buildCountAfterWarmHit = host.dividerRegionBuildCount
        #expect(buildCountAfterWarmHit > 0)

        #expect(hitFallsInsideHostedTerminal(host.hitTest(point), hostedView: hostedView))
        #expect(host.dividerRegionBuildCount == buildCountAfterWarmHit)

        let splitView = NSSplitView(frame: container.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: container.bounds.height)))
        splitView.addSubview(NSView(frame: NSRect(x: 121, y: 0, width: 139, height: container.bounds.height)))
        container.addSubview(splitView)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        #expect(
            host.hitTest(dividerPointInHost) == nil,
            "Newly inserted nested terminal split dividers should invalidate an empty cached scan"
        )
        #expect(
            host.dividerRegionBuildCount > buildCountAfterWarmHit,
            "Terminal divider cache should rebuild when the previously scanned subtree gains a new split branch"
        )
    }

    @Test func hostViewInvalidatesCachedDividerRegionsWhenSplitBecomesHidden() throws {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView, "Expected content view")

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height)))
        splitView.addSubview(NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height)))
        contentView.addSubview(splitView)
        splitView.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.autoresizingMask = [.width, .height]
        let hostedView = makeHostedTerminalView(frame: host.bounds)
        host.addSubview(hostedView)
        contentView.addSubview(host)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        #expect(host.hitTest(dividerPointInHost) == nil)
        let buildCountAfterWarmHit = host.dividerRegionBuildCount
        #expect(buildCountAfterWarmHit > 0)

        splitView.isHidden = true
        contentView.layoutSubtreeIfNeeded()

        #expect(
            hitFallsInsideHostedTerminal(host.hitTest(dividerPointInHost), hostedView: hostedView),
            "Hidden cached split dividers must not keep stealing terminal hits"
        )
        #expect(
            host.dividerRegionBuildCount > buildCountAfterWarmHit,
            "Hidden split views should invalidate cached terminal divider regions on the next pointer hit"
        )
        let buildCountAfterHiddenHit = host.dividerRegionBuildCount

        splitView.isHidden = false
        contentView.layoutSubtreeIfNeeded()

        #expect(
            host.hitTest(dividerPointInHost) == nil,
            "Revealed split dividers should become interactive again without waiting for a resize notification"
        )
        #expect(
            host.dividerRegionBuildCount > buildCountAfterHiddenHit,
            "Empty terminal divider caches should be rebuilt after hidden split views are revealed"
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

    private func makeHostedTerminalView(frame: NSRect) -> GhosttySurfaceScrollView {
        let surfaceView = GhosttyNSView(frame: frame)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = frame
        hostedView.autoresizingMask = [.width, .height]
        return hostedView
    }

    private func hitFallsInsideHostedTerminal(_ hitView: NSView?, hostedView: GhosttySurfaceScrollView) -> Bool {
        guard let hitView else { return false }
        return hitView === hostedView || hitView.isDescendant(of: hostedView)
    }
}
#endif
