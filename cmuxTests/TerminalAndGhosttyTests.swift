import XCTest
import Testing
import CmuxControlSocket
import CmuxTerminalCopyMode
import CmuxSocketControl
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import CMUXMobileCore
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class GhosttyPasteboardHelperTests: XCTestCase {
    func make1x1PNG(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func makeHTMLDocument(containing text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<html><body><pre>\(escaped)</pre></body></html>"
    }

}

@MainActor
final class TerminalOffscreenStartupTests: XCTestCase {
#if DEBUG
    final class RecordingMobileTabManager: TabManager {
        private(set) var scheduledMetadataRefreshes: [(workspaceId: UUID, panelId: UUID, reason: String)] = []

        override func didScheduleInitialWorkspaceGitMetadataRefreshForTesting(
            workspaceId: UUID,
            panelId: UUID,
            reason: String
        ) {
            scheduledMetadataRefreshes.append((workspaceId, panelId, reason))
        }

        func clearScheduledMetadataRefreshesForTesting() {
            scheduledMetadataRefreshes.removeAll()
        }
    }
#endif

    func waitForMobileHostRoutesForTesting() async -> Bool {
        for _ in 0..<200 {
            let response = await TerminalController.shared.mobileHostHandleRPC(
                MobileHostRPCRequest(
                    id: "status",
                    method: "mobile.host.status",
                    params: [:],
                    auth: nil
                )
            )
            if case let .ok(rawPayload) = response,
               let payload = rawPayload as? [String: Any],
               let routes = payload["routes"] as? [[String: Any]],
               !routes.isEmpty {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

@MainActor
final class TerminalNotificationDirectInteractionTests: XCTestCase {
    final class FocusProbeView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        return window
    }

    func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    func makeKeyEvent(characters: String, keyCode: UInt16, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to create key event")
        }
        return event
    }

    func surfaceView(in hostedView: GhosttySurfaceScrollView) -> NSView? {
        hostedView.subviews
            .compactMap { $0 as? NSScrollView }
            .first?
            .documentView?
            .subviews
            .first
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    func drainMainQueue(timeout: TimeInterval = 1.0, file: StaticString = #filePath, line: UInt = #line) {
        var drained = false
        DispatchQueue.main.async {
            drained = true
        }
        XCTAssertTrue(waitUntil(timeout: timeout) { drained }, "Expected main queue to drain", file: file, line: line)
    }

    func waitForRuntimeSurface(
        _ surface: TerminalSurface,
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitUntil(timeout: timeout) { surface.surface != nil },
            "Expected runtime surface to be recreated",
            file: file,
            line: line
        )
    }

}


@MainActor
final class GhosttySurfaceOverlayTests: XCTestCase {
    var surfacesToRelease: [TerminalSurface] = []

    final class ScrollProbeSurfaceView: GhosttyNSView {
        private(set) var scrollWheelCallCount = 0

        override func scrollWheel(with event: NSEvent) {
            scrollWheelCallCount += 1
        }
    }

    final class ScrollbarPostingSurfaceView: GhosttyNSView {
        var nextScrollbar: GhosttyScrollbar?

        override func scrollWheel(with event: NSEvent) {
            super.scrollWheel(with: event)
            guard let nextScrollbar else { return }
            NotificationCenter.default.post(
                name: .ghosttyDidUpdateScrollbar,
                object: self,
                userInfo: [GhosttyNotificationKey.scrollbar: nextScrollbar]
            )
        }
    }

    final class KeyStatusTestWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    func makeScrollbar(total: UInt64, offset: UInt64, len: UInt64) -> GhosttyScrollbar {
        GhosttyScrollbar(
            c: ghostty_action_scrollbar_s(
                total: total,
                offset: offset,
                len: len
            )
        )
    }

    override func tearDown() {
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
        for surface in surfacesToRelease.reversed() {
            surface.releaseSurfaceForTesting()
        }
        surfacesToRelease.removeAll()
        super.tearDown()
    }

    func makeTrackedTerminalSurface(
        tabId: UUID = UUID()
    ) -> TerminalSurface {
        let surface = TerminalSurface(
            tabId: tabId,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        surfacesToRelease.append(surface)
        return surface
    }

    func findEditableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = findEditableTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    func firstResponderOwnsTextField(_ firstResponder: NSResponder?, textField: NSTextField) -> Bool {
        if firstResponder === textField {
            return true
        }
        if let editor = firstResponder as? NSTextView,
           editor.isFieldEditor,
           editor.delegate as? NSTextField === textField {
            return true
        }
        return false
    }

    @discardableResult
    func waitUntil(
        timeout: TimeInterval = 1.0,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard condition() else {
            XCTFail("Timed out waiting for \(description)", file: file, line: line)
            return false
        }
        return true
    }

}


@MainActor
final class TerminalWindowPortalLifecycleTests: XCTestCase {
    final class ContentViewCountingWindow: NSWindow {
        var contentViewReadCount = 0

        override var contentView: NSView? {
            get {
                contentViewReadCount += 1
                return super.contentView
            }
            set {
                super.contentView = newValue
            }
        }
    }

    func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func drainMainQueue() {
        let expectation = XCTestExpectation(description: "drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        XCTWaiter().wait(for: [expectation], timeout: 1.0)
    }

}


