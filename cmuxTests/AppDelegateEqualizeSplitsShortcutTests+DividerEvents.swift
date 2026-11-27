import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AppDelegateEqualizeSplitsShortcutTests {
    @Test
    func testDividerDoubleClickEventEqualizesContainingRunAndConsumesRelease() async throws {
        try await exerciseDividerEvents(enabled: true, drag: false)
    }

    @Test
    func testDividerDoubleClickEventWithSettingOffLeavesReleaseForNativeTracking() async throws {
        try await exerciseDividerEvents(enabled: false, drag: false)
    }

    @Test
    func testDividerDoubleClickDragEventResizesWithoutEqualizing() async throws {
        try await exerciseDividerEvents(enabled: true, drag: true)
    }

    private func exerciseDividerEvents(enabled: Bool, drag: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let appDelegate = try #require(AppDelegate.shared)
            let defaults = UserDefaults.standard
            let key = "equalizeSplitsOnDividerDoubleClick"
            let saved = defaults.object(forKey: key)
            defaults.set(enabled, forKey: key)
            defer {
                if let saved { defaults.set(saved, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            for orientation in [SplitOrientation.horizontal, .vertical] {
                let windowId = appDelegate.createMainWindow()
                defer { self.closeWindow(withId: windowId) }
                let window = try #require(self.window(withId: windowId))
                let workspace = try #require(appDelegate.tabManagerFor(windowId: windowId)?.selectedWorkspace)
                Self.prepareSplitFixture(window: window, workspace: workspace)
                let first = try #require(workspace.focusedPanelId)
                let cross: SplitOrientation = orientation == .horizontal ? .vertical : .horizontal
                let other = try #require(workspace.newTerminalSplit(from: first, orientation: cross))
                let second = try #require(workspace.newTerminalSplit(from: first, orientation: orientation))
                _ = try #require(workspace.newTerminalSplit(from: second.id, orientation: orientation))
                let controller = workspace.bonsplitController
                let nodes = self.shortcutRoutingSplitNodes(in: controller.treeSnapshot())
                let axis = orientation == .horizontal ? "horizontal" : "vertical"
                let run = nodes.filter { $0.orientation == axis }
                #expect(run.count == 2)
                let clicked = try #require(run.last)
                let splitId = try #require(UUID(uuidString: clicked.id))
                let content = try #require(window.contentView)
                let rendered = await AppKitTestEventPump().waitUntil(timeout: .seconds(3)) {
                    content.layoutSubtreeIfNeeded()
                    return self.managedDivider(in: content, controller: controller, splitId: splitId) != nil
                }
                try #require(rendered, "Expected the workspace's managed split view to render")
                for node in nodes {
                    let position = node.orientation == axis ? 0.25 : 0.7
                    #expect(controller.setDividerPosition(position, forSplit: try #require(UUID(uuidString: node.id))))
                }
                let focusPane = try #require(workspace.paneId(forPanelId: other.id))
                controller.focusPane(focusPane)
                let splitView = try #require(self.managedDivider(in: content, controller: controller, splitId: splitId))
                try await self.awaitStableDivider(splitView, in: content)
                let before = self.shortcutRoutingSplitNodes(in: controller.treeSnapshot())
                let clickedBefore = try #require(before.first { $0.id == clicked.id })
                #expect(abs(clickedBefore.dividerPosition - 0.25) < 0.0001)
                let panes = controller.allPaneIds
                let tabs = controller.allTabIds
                let focusedPanel = workspace.focusedPanelId
                let focusedPane = controller.focusedPaneId
                let responder = window.firstResponder

                let rect = try #require(PortalSplitDividerRegion.dividerRect(in: splitView, dividerIndex: 0))
                try #require(rect.width > 0 && rect.height > 0)
                let point = NSPoint(x: rect.midX, y: rect.midY)
                let location = splitView.convert(point, to: nil)
                let grabRegion = try #require(PortalSplitDividerRegion.dividerHitRectInWindow(
                    in: splitView, dividerIndex: 0
                ))
                try #require(grabRegion.contains(location), "The divider center must be in the app's grab region")
                let timestamp = ProcessInfo.processInfo.systemUptime
                let down = try self.dividerMouseEvent(.leftMouseDown, at: location, window: window, timestamp: timestamp)
                let destination = NSPoint(
                    x: location.x + (splitView.isVertical && drag ? 40 : 0),
                    y: location.y + (!splitView.isVertical && drag ? 40 : 0)
                )
                let up = try self.dividerMouseEvent(.leftMouseUp, at: destination, window: window, timestamp: timestamp + 0.02)
                try #require(NSApp.nextEvent(
                    matching: [.leftMouseDragged, .leftMouseUp], until: .now, inMode: .default, dequeue: false
                ) == nil, "Fixture requires an empty pointer tracking queue")
                defer {
                    // Bounded cleanup even if a require below fails.
                    for _ in 0..<8 {
                        if NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .now,
                                           inMode: .default, dequeue: true) == nil { break }
                    }
                }
                // Post in reverse order at the front, before synchronous down
                // dispatch. The real tracking-mode peek can never wait for input.
                NSApp.postEvent(up, atStart: true)
                if drag {
                    let dragged = try self.dividerMouseEvent(
                        .leftMouseDragged, at: destination, window: window, timestamp: timestamp + 0.01
                    )
                    NSApp.postEvent(dragged, atStart: true)
                }
                let queued = try #require(window.nextEvent(
                    matching: [.leftMouseDragged, .leftMouseUp], until: .now, inMode: .eventTracking, dequeue: false
                ))
                #expect(queued.type == (drag ? .leftMouseDragged : .leftMouseUp))
                #expect(queued.windowNumber == window.windowNumber)
                #expect(queued.clickCount == 2)
                let probe = DividerTrackingEventProbe()
                try probe.dispatch(down, release: up, splitView: splitView, window: window)

                // Check immediately, before an event pump could hide a leaked up.
                #expect(NSApp.nextEvent(matching: .leftMouseUp, until: .now,
                                        inMode: .default, dequeue: true) == nil)
                #expect(NSApp.nextEvent(matching: .leftMouseDragged, until: .now,
                                        inMode: .default, dequeue: true) == nil)
                if enabled && !drag {
                    #expect(probe.nativeTrackingCount == 0)
                } else {
                    #expect(probe.nativeTrackingCount == 1)
                    let nativeQueued = try #require(probe.firstNativeQueuedEvent)
                    #expect(nativeQueued.type == (drag ? .leftMouseDragged : .leftMouseUp))
                    #expect(nativeQueued.windowNumber == up.windowNumber)
                    #expect(nativeQueued.clickCount == 2)
                    #expect(abs(nativeQueued.timestamp - (drag ? timestamp + 0.01 : up.timestamp)) < 0.000_001)
                }
                if drag {
                    let resized = await AppKitTestEventPump().waitUntil(timeout: .seconds(3)) {
                        self.shortcutRoutingSplitNodes(in: controller.treeSnapshot()).contains {
                            $0.id == clicked.id && abs($0.dividerPosition - clickedBefore.dividerPosition) > 0.01
                        }
                    }
                    #expect(resized, "The queued drag must resize the clicked divider")
                }
                let result = self.shortcutRoutingSplitNodes(in: controller.treeSnapshot())
                #expect(result.map(\.id) == before.map(\.id))
                for node in result {
                    let original = try #require(before.first { $0.id == node.id })
                    if enabled && !drag && node.orientation == axis {
                        let expected = node.id == run.first?.id ? 1.0 / 3.0 : 0.5
                        #expect(abs(node.dividerPosition - expected) < 0.0001)
                    } else if drag && node.id == clicked.id {
                        #expect(abs(node.dividerPosition - original.dividerPosition) > 0.01)
                        #expect(abs(node.dividerPosition - 0.5) > 0.01)
                    } else {
                        #expect(abs(node.dividerPosition - original.dividerPosition) < 0.0001)
                    }
                }
                #expect(controller.allPaneIds == panes)
                #expect(controller.allTabIds == tabs)
                #expect(controller.focusedPaneId == focusedPane)
                #expect(controller.focusedPaneId == focusPane)
                #expect(workspace.focusedPanelId == focusedPanel)
                #expect(window.firstResponder === responder)
            }
        }
    }

    private func managedDivider(in root: NSView, controller: BonsplitController, splitId: UUID) -> NSSplitView? {
        if let split = root as? NSSplitView,
           let managed = split as? any BonsplitManagedSplitView,
           managed.bonsplitController === controller, managed.bonsplitSplitId == splitId {
            return split
        }
        for child in root.subviews {
            if let match = managedDivider(in: child, controller: controller, splitId: splitId) { return match }
        }
        return nil
    }

    private func awaitStableDivider(_ split: NSSplitView, in content: NSView) async throws {
        var previous: [NSRect] = []
        var stableTurns = 0
        let settled = await AppKitTestEventPump().waitUntil(timeout: .seconds(3)) {
            content.layoutSubtreeIfNeeded()
            split.layoutSubtreeIfNeeded()
            let frames = split.arrangedSubviews.map(\.frame)
            if frames.count == 2, frames.allSatisfy({ $0.width > 1 && $0.height > 1 }), frames == previous {
                stableTurns += 1
            } else { stableTurns = 0 }
            previous = frames
            return stableTurns >= 2
        }
        try #require(settled, "Divider frames did not settle")
    }

    private func dividerMouseEvent(
        _ type: NSEvent.EventType, at location: NSPoint, window: NSWindow, timestamp: TimeInterval
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: timestamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: 2, pressure: type == .leftMouseUp ? 0 : 1
        ))
    }
}
