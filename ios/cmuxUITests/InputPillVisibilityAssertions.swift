import XCTest

struct InputPillVisibilityBaseline {
    let pillFrame: CGRect
}

extension XCTestCase {
    func captureInputPillBaseline(
        app: XCUIApplication,
        pill: XCUIElement,
        context: String,
        tolerance: CGFloat = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> InputPillVisibilityBaseline {
        let pillFrame = waitForStableElementFrame(element: pill, timeout: 1.5)
        XCTAssertGreaterThan(
            pillFrame.height,
            1,
            "Expected input pill frame height > 1 for \(context)",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            pillFrame.width,
            1,
            "Expected input pill frame width > 1 for \(context)",
            file: file,
            line: line
        )
        let windowFrame = resolveWindowFrame(app: app)
        assertInputPillVisible(
            pillFrame: pillFrame,
            windowFrame: windowFrame,
            context: "\(context) baseline",
            tolerance: tolerance,
            file: file,
            line: line
        )
        return InputPillVisibilityBaseline(pillFrame: pillFrame)
    }

    func assertInputPillVisibleAndNotBelowBaseline(
        app: XCUIApplication,
        pill: XCUIElement,
        baseline: InputPillVisibilityBaseline,
        context: String,
        tolerance: CGFloat = 1.0,
        duration: TimeInterval = 0.35,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let baselineMaxY = baseline.pillFrame.maxY
        var maxObserved = baselineMaxY
        var visibilityError: String?
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            let windowFrame = resolveWindowFrame(app: app)
            let pillFrame = pill.frame
            if pillFrame.height > 1, pillFrame.width > 1 {
                if visibilityError == nil,
                   let error = inputPillVisibilityError(
                    pillFrame: pillFrame,
                    windowFrame: windowFrame,
                    tolerance: tolerance
                   ) {
                    visibilityError = error
                }
                maxObserved = max(maxObserved, pillFrame.maxY)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.016))
        }
        if let visibilityError {
            XCTFail(
                "Input pill not fully visible during \(context): \(visibilityError)",
                file: file,
                line: line
            )
        }
        XCTAssertLessThanOrEqual(
            maxObserved,
            baselineMaxY + tolerance,
            "Input pill moved below baseline during \(context): baselineMaxY=\(baselineMaxY) observedMaxY=\(maxObserved)",
            file: file,
            line: line
        )
    }
}

private func resolveWindowFrame(app: XCUIApplication) -> CGRect {
    let window = app.windows.firstMatch
    if window.exists, window.frame.height > 1, window.frame.width > 1 {
        return window.frame
    }
    let fallback = app.windows.element(boundBy: 0)
    if fallback.exists, fallback.frame.height > 1, fallback.frame.width > 1 {
        return fallback.frame
    }
    return app.frame
}

private func waitForStableElementFrame(element: XCUIElement, timeout: TimeInterval) -> CGRect {
    let deadline = Date().addingTimeInterval(timeout)
    var lastFrame = element.frame
    var stableCount = 0
    while Date() < deadline {
        let frame = element.frame
        if frame.height > 1, frame.width > 1 {
            if abs(frame.midY - lastFrame.midY) <= 0.5,
               abs(frame.height - lastFrame.height) <= 0.5 {
                stableCount += 1
                if stableCount >= 2 {
                    return frame
                }
            } else {
                stableCount = 0
                lastFrame = frame
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return element.frame
}

private func assertInputPillVisible(
    pillFrame: CGRect,
    windowFrame: CGRect,
    context: String,
    tolerance: CGFloat,
    file: StaticString,
    line: UInt
) {
    if let error = inputPillVisibilityError(
        pillFrame: pillFrame,
        windowFrame: windowFrame,
        tolerance: tolerance
    ) {
        XCTFail("Input pill not fully visible during \(context): \(error)", file: file, line: line)
    }
}

private func inputPillVisibilityError(
    pillFrame: CGRect,
    windowFrame: CGRect,
    tolerance: CGFloat
) -> String? {
    let minY = pillFrame.minY
    let maxY = pillFrame.maxY
    let minX = pillFrame.minX
    let maxX = pillFrame.maxX
    if minY < windowFrame.minY - tolerance {
        return "minY \(minY) < window minY \(windowFrame.minY)"
    }
    if maxY > windowFrame.maxY + tolerance {
        return "maxY \(maxY) > window maxY \(windowFrame.maxY)"
    }
    if minX < windowFrame.minX - tolerance {
        return "minX \(minX) < window minX \(windowFrame.minX)"
    }
    if maxX > windowFrame.maxX + tolerance {
        return "maxX \(maxX) > window maxX \(windowFrame.maxX)"
    }
    return nil
}
