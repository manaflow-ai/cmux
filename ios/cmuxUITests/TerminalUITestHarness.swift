import XCTest

enum TerminalUITestHarness {
    static func focusTerminal(in app: XCUIApplication, fallback detail: XCUIElement) {
        let surface = app.otherElements["terminal.surface"].firstMatch
        if surface.waitForExistence(timeout: 3), surface.isHittable {
            surface.tap()
        } else {
            detail.tap()
        }

        dismissKeyboardOnboardingIfNeeded(in: app)

        if surface.exists, surface.isHittable {
            surface.tap()
        } else {
            detail.tap()
        }
    }

    static func typeText(_ text: String, in app: XCUIApplication) {
        if text.count == 1 {
            let key = app.keys[text].firstMatch
            if key.waitForExistence(timeout: 2), key.isHittable {
                key.tap()
                return
            }
        }
        app.typeText(text)
    }

    static func dismissKeyboardIfNeeded(in app: XCUIApplication) {
        dismissKeyboardOnboardingIfNeeded(in: app)

        let hideAccessory = app.buttons["terminal.inputAccessory.hideKeyboard"]
        if hideAccessory.waitForExistence(timeout: 1), hideAccessory.isHittable {
            hideAccessory.tap()
            return
        }

        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }

        let hideKeyboard = keyboard.buttons["Hide keyboard"]
        if hideKeyboard.exists {
            hideKeyboard.tap()
            return
        }

        let dismissKeyboard = keyboard.buttons["Dismiss keyboard"]
        if dismissKeyboard.exists {
            dismissKeyboard.tap()
            return
        }

        let returnKey = keyboard.buttons["Return"]
        if returnKey.exists {
            returnKey.tap()
        }
    }

    static func dismissKeyboardOnboardingIfNeeded(in app: XCUIApplication) {
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 1), continueButton.isHittable {
            continueButton.tap()
        }
    }
}
