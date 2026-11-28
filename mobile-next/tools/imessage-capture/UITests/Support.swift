import XCTest

/// Shared helpers for driving the system Messages app (com.apple.MobileSMS).
enum SMS {
    static let bundleID = "com.apple.MobileSMS"
    static var app: XCUIApplication { XCUIApplication(bundleIdentifier: bundleID) }

    /// Writes a marker line to stdout so the recording timeline can be aligned with test steps.
    static func mark(_ name: String) {
        print("CNM-MARK \(String(format: "%.3f", Date().timeIntervalSince1970)) \(name)")
    }

    static func pause(_ seconds: Double) {
        // Test-side pacing between gestures so recorded transitions settle; not app synchronization.
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Dismisses the one-time "slide to type" keyboard onboarding card if visible.
    static func dismissKeyboardOnboarding(_ app: XCUIApplication) {
        let cont = app.buttons["Continue"]
        if cont.waitForExistence(timeout: 1.0) { cont.tap(); pause(0.6) }
    }

    /// Returns to the root conversation list.
    static func goToList(_ app: XCUIApplication) {
        for _ in 0..<4 {
            let back = app.navigationBars.buttons["BackButton"]
            if back.exists { back.tap(); pause(0.8) } else { break }
        }
        for label in ["Cancel", "close"] {
            let b = app.buttons[label]
            if b.exists && b.isHittable { b.tap(); pause(0.8) }
        }
    }

    static func screenCoordinate(_ app: XCUIApplication, x: CGFloat, y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// Types into the composer and taps send.
    static func send(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields["messageBodyField"]
        if !field.hasFocus { field.tap(); pause(0.4); dismissKeyboardOnboarding(app) }
        field.typeText(text)
        pause(0.3)
        let sendButton = app.buttons["sendButton"]
        if sendButton.waitForExistence(timeout: 2) { sendButton.tap() } else { field.typeText("\n") }
        pause(0.8)
    }
}

extension XCUIElement {
    var hasFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
