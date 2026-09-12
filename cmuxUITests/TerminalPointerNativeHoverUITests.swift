import AppKit
import Foundation
import XCTest

/// Exercises WindowServer cursor tracking with native XCUITest hover events.
/// Background computer-use clicks do not establish the same mouse-move state.
final class TerminalPointerNativeHoverUITests: XCTestCase {
    private struct CursorReference {
        let hotspot: NSPoint
        let size: NSSize
        let image: Data
    }

    private struct CursorReferences {
        let arrow: CursorReference
        let iBeam: CursorReference
        let dragCopy: CursorReference
        let pointingHand: CursorReference
        let resizeLeftRight: CursorReference
    }

    @MainActor
    func testPointerBatchAndNativePaneFocusRestoration() throws {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "feat-8739-osc22-pointer-shape"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pointer-hover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        let cursorReferences = try loadCursorReferences()
        app.launch()
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 20) else {
            throw failure("Tagged app did not create a window")
        }
        app.activate()
        let framePoint = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 18, dy: 15))
        framePoint.hover()
        let frameCursor = try expectCursor(cursorReferences.arrow, app: app, label: "Window frame reference")
        let initial = window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4))
        initial.click()

        try emit(["text"], app: app, marker: directory.appendingPathComponent("text-ready"))
        framePoint.hover()
        initial.hover()
        try expectCursor(cursorReferences.iBeam, app: app, label: "Before OSC 22")

        try emit(["copy"], app: app, marker: directory.appendingPathComponent("copy-ready"))
        framePoint.hover()
        initial.hover()
        let copy = try expectCursor(cursorReferences.dragCopy, app: app, label: "Explicit copy", forbiddenImage: frameCursor)

        // The last unsupported shape must preserve copy, not the earlier crosshair.
        try emit(["crosshair", "copy", "wait"], app: app,
                 marker: directory.appendingPathComponent("batch-ready"))
        framePoint.hover()
        initial.hover()
        try expectCursor(cursorReferences.dragCopy, app: app, label: "After coalesced batch", expectedImage: copy)

        // Establish the independent focus-restoration fixture before creating another pane.
        try emit(["pointer"], app: app, marker: directory.appendingPathComponent("pointer-ready"))
        framePoint.hover()
        initial.hover()
        try expectCursor(cursorReferences.pointingHand, app: app, label: "Pointer before split")

        app.typeKey("d", modifierFlags: .command)
        try emit(["text"], app: app, marker: directory.appendingPathComponent("right-ready"))
        let panesReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.textViews.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.width > 100 }.count == 2
        }, object: nil)
        guard XCTWaiter.wait(for: [panesReady], timeout: 10) == .completed else {
            throw failure("Split did not expose two terminal text areas")
        }
        let panes = window.textViews.allElementsBoundByIndex
            .filter { $0.isHittable && $0.frame.width > 100 }
            .sorted { $0.frame.minX < $1.frame.minX }
        let left = panes[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let right = panes[1].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        right.hover()
        right.click()
        try expectCursor(cursorReferences.iBeam, app: app, label: "Untouched right pane")
        left.hover()
        left.click()
        try expectCursor(cursorReferences.pointingHand, app: app, label: "Original pane after native focus")
        right.hover()
        right.click()
        try expectCursor(cursorReferences.iBeam, app: app, label: "Right pane remains isolated")
        left.hover()
        left.click()
        try expectCursor(cursorReferences.pointingHand, app: app, label: "Repeated native focus restoration")

        let divider = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: (panes[0].frame.maxX + panes[1].frame.minX) / 2 - window.frame.minX,
            dy: panes[0].frame.midY - window.frame.minY
        ))
        divider.hover()
        try expectCursor(cursorReferences.resizeLeftRight, app: app, label: "Divider cursor overrides OSC 22")
        left.hover()
        try expectCursor(cursorReferences.pointingHand, app: app, label: "Pointer restored after divider hover")

        // Mouse-reporting editors can explicitly request text instead of the
        // implicit arrow. A modifier key must preserve that OSC 22 request too.
        try emit(["text"], app: app, marker: directory.appendingPathComponent("reporting-ready"),
                 enableMouseReporting: true)
        framePoint.hover()
        left.hover()
        try expectCursor(cursorReferences.iBeam, app: app, label: "Explicit text with mouse reporting")
        app.typeKey(XCUIKeyboardKey.command.rawValue, modifierFlags: [])
        try expectCursor(cursorReferences.iBeam, app: app, label: "Mouse-reporting text after Command")
    }

    @MainActor
    private func emit(
        _ shapes: [String], app: XCUIApplication, marker: URL,
        enableMouseReporting: Bool = false
    ) throws {
        let escapes = shapes.map { "\\033]22;\($0)\\007" }.joined()
        let reporting = enableMouseReporting ? "\\033[?1000h" : ""
        let quotedMarker = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Clear welcome links out of the hover region and acknowledge actual PTY output.
        app.typeText("printf '\\033[2J\\033[H\(reporting)\(escapes)Pointer fixture\\n'; : > \(quotedMarker)\n")
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: marker.path) },
            object: nil
        )
        guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed else {
            throw failure("Terminal did not execute pointer command: \(shapes)")
        }
    }

    @MainActor
    @discardableResult
    private func expectCursor(
        _ expected: CursorReference, app: XCUIApplication, label: String,
        expectedImage: Data? = nil, forbiddenImage: Data? = nil
    ) throws -> Data {
        // Never compare factory object identity. Copy and arrow share geometry,
        // so copy additionally excludes the captured frame cursor and the batch
        // must match the live copy reference's PNG bytes. References are captured
        // after initializing AppKit, before launch, without changing the cursor.
        let hotspot = expected.hotspot
        let size = expected.size
        let capture: @Sendable () -> Data? = {
            guard let tiff = NSCursor.currentSystem?.image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.representation(using: .png, properties: [:])
        }
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let cursor = NSCursor.currentSystem,
                      cursor.hotSpot == hotspot, cursor.image.size == size,
                      let data = capture() else { return false }
                guard data == expected.image else { return false }
                if let expectedImage, data != expectedImage { return false }
                if let forbiddenImage, data == forbiddenImage { return false }
                return true
            }, object: nil
        )
        let result = XCTWaiter.wait(for: [ready], timeout: 5)
        XCTContext.runActivity(named: label) { activity in
            let window = XCTAttachment(screenshot: app.screenshot())
            window.lifetime = .keepAlways
            activity.add(window)
            if let cursor = NSCursor.currentSystem {
                let image = XCTAttachment(image: cursor.image)
                image.name = "Actual system cursor"
                image.lifetime = .keepAlways
                activity.add(image)
            }
        }
        guard result == .completed else {
            let actual = NSCursor.currentSystem.map { "hotspot=\($0.hotSpot), size=\($0.image.size)" } ?? "unavailable"
            throw failure("\(label): expected hotspot=\(hotspot), size=\(size); actual \(actual)")
        }
        return try XCTUnwrap(capture(), "System cursor became unavailable")
    }

    @MainActor
    private func loadCursorReferences() throws -> CursorReferences {
        // The UI-test runner can use XCTest without initializing NSApplication.
        // AppKit must initialize before its standard cursor images are loaded.
        _ = NSApplication.shared
        let cursors: [NSCursor] = [.arrow, .iBeam, .dragCopy, .pointingHand, .resizeLeftRight]
        let references = try cursors.map { cursor in
            guard let tiff = cursor.image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let image = bitmap.representation(using: .png, properties: [:]) else {
                throw failure("Standard cursor image is unavailable after AppKit initialization")
            }
            let geometry = CursorReference(hotspot: cursor.hotSpot, size: cursor.image.size, image: image)
            guard geometry.size.width > 0, geometry.size.height > 0 else {
                throw failure("Standard cursor has empty geometry: \(geometry.size)")
            }
            return geometry
        }
        guard Set(references.map(\.image)).count == references.count else {
            throw failure("Standard cursor references contain duplicate images")
        }
        return CursorReferences(
            arrow: references[0],
            iBeam: references[1],
            dragCopy: references[2],
            pointingHand: references[3],
            resizeLeftRight: references[4]
        )
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "TerminalPointerNativeHoverUITests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
