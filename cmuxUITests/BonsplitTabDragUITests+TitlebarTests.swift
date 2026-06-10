import XCTest
import Foundation
import CoreGraphics


// MARK: - Titlebar Tests
extension BonsplitTabDragUITests {
    func testTitlebarShortcutHintsDoNotCoverHeaderIcons() {
        let (app, dataPath) = launchConfiguredApp(alwaysShowShortcutHints: true)

        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for titlebar shortcut hint geometry test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(waitForAnyJSON(atPath: dataPath, timeout: setupTimeout), "Expected titlebar geometry data at \(dataPath)")
        guard let ready = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: setupTimeout) else {
            XCTFail("Timed out waiting for ready=1. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }

        if let setupError = ready["setupError"], !setupError.isEmpty {
            XCTFail("Setup failed: \(setupError)")
            return
        }

        let controls = [
            "titlebarControl_toggleSidebar",
            "titlebarControl_showNotifications",
            "titlebarControl_newTab",
            "titlebarControl_focusHistoryBack",
            "titlebarControl_focusHistoryForward",
        ]
        let hints = [
            "titlebarShortcutHint_toggleSidebar",
            "titlebarShortcutHint_showNotifications",
            "titlebarShortcutHint_newTab",
            "titlebarShortcutHint_focusHistoryBack",
            "titlebarShortcutHint_focusHistoryForward",
        ]
        let trafficLights = [
            "titlebarTrafficLightClose",
            "titlebarTrafficLightMinimize",
            "titlebarTrafficLightZoom",
        ]
        let allPrefixes = controls + hints + trafficLights
        let keys = allPrefixes.flatMap { prefix in
            ["\(prefix)X", "\(prefix)Y", "\(prefix)Width", "\(prefix)Height"]
        }
        guard let geometry = waitForJSONNumbers(keys, atPath: dataPath, timeout: 5.0) else {
            XCTFail("Timed out waiting for titlebar control geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }

        func rect(_ prefix: String) -> CGRect {
            CGRect(
                x: Double(geometry["\(prefix)X"] ?? "") ?? 0,
                y: Double(geometry["\(prefix)Y"] ?? "") ?? 0,
                width: Double(geometry["\(prefix)Width"] ?? "") ?? 0,
                height: Double(geometry["\(prefix)Height"] ?? "") ?? 0
            )
        }

        let closeTrafficLight = rect("titlebarTrafficLightClose")
        XCTAssertGreaterThan(closeTrafficLight.width, 0)
        XCTAssertGreaterThan(closeTrafficLight.height, 0)

        for trafficLight in trafficLights.dropFirst() {
            let frame = rect(trafficLight)
            XCTAssertEqual(frame.width, closeTrafficLight.width, accuracy: 0.5, "Expected traffic lights to share width. geometry=\(geometry)")
            XCTAssertEqual(frame.height, closeTrafficLight.height, accuracy: 0.5, "Expected traffic lights to share height. geometry=\(geometry)")
            XCTAssertEqual(frame.midY, closeTrafficLight.midY, accuracy: 0.5, "Expected traffic lights to share vertical center. geometry=\(geometry)")
        }

        let firstControlHeight = rect(controls[0]).height
        for (controlPrefix, hintPrefix) in zip(controls, hints) {
            let control = rect(controlPrefix)
            let hint = rect(hintPrefix)
            XCTAssertEqual(control.height, firstControlHeight, accuracy: 0.5, "Expected titlebar controls to share height. geometry=\(geometry)")
            XCTAssertEqual(control.midY, closeTrafficLight.midY, accuracy: 1.0, "Expected \(controlPrefix) to align to traffic light center. geometry=\(geometry)")
            XCTAssertFalse(
                control.intersects(hint),
                "Expected shortcut hint \(hintPrefix) not to cover titlebar control \(controlPrefix). geometry=\(geometry)"
            )
        }
    }

    func testMinimalModeTitlebarDoubleClickZoomsWindow() {
        let (app, dataPath) = launchConfiguredApp(windowSize: "640x420")

        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: launchTimeout),
            "Expected app to launch for minimal-mode titlebar double-click UI test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(waitForAnyJSON(atPath: dataPath, timeout: setupTimeout), "Expected tab-drag setup data at \(dataPath)")
        guard let ready = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: setupTimeout) else {
            XCTFail("Timed out waiting for ready=1. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }

        if let setupError = ready["setupError"], !setupError.isEmpty {
            XCTFail("Setup failed: \(setupError)")
            return
        }

        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.waitForExistence(timeout: 5.0), "Expected main window to exist")

        let initialFrame = window.frame
        let betaTitle = ready["betaTitle"] ?? "UITest Beta"
        let betaTab = app.buttons[betaTitle]
        XCTAssertTrue(betaTab.waitForExistence(timeout: 5.0), "Expected beta tab to exist")

        let point = CGPoint(
            x: min(initialFrame.maxX - 64, max(betaTab.frame.maxX + 80, initialFrame.midX)),
            y: initialFrame.minY + 16
        )
        doubleClick(in: window, atAccessibilityPoint: point)

        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                let frame = window.frame
                return frame.width > initialFrame.width + 80 || frame.height > initialFrame.height + 80
            },
            "Expected titlebar double-click in minimal mode to zoom the window. initial=\(initialFrame) current=\(window.frame)"
        )
    }

}
