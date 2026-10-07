import XCTest

/// Diagnostics (c16-platform.md): Settings > Diagnostics shows the log,
/// copies support info and clears after confirmation; the terminal bench
/// (`CMUX_IOS_TERMINAL_BENCH`) runs and reports.
@MainActor
final class NextDiagnosticsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func openDiagnostics() -> XCUIApplication {
        let app = NextUITest.launchShell(tab: "settings")
        NextUITest.assertTabRoot(app, "settings")
        NextUITest.tap(app, "shell.settings.diagnostics", scroll: true)
        XCTAssertTrue(NextUITest.element(app, "platform.diagnostics.lines").waitForExistence(timeout: 10))
        return app
    }

    func testDiagnosticsPageRows() {
        let app = openDiagnostics()
        XCTAssertTrue(NextUITest.element(app, "platform.diagnostics.crashReports").exists)
        XCTAssertTrue(NextUITest.element(app, "platform.diagnostics.share").exists)
    }

    func testCopySupportInfo() {
        let app = openDiagnostics()
        let copy = NextUITest.element(app, "platform.diagnostics.copy")
        XCTAssertTrue(NextUITest.waitHittable(copy))
        copy.tap()
        XCTAssertTrue(NextUITest.wait(copy, "label CONTAINS 'Copied'"), "copy did not confirm")
    }

    func testClearLogAsksFirst() {
        let app = openDiagnostics()
        NextUITest.tap(app, "platform.diagnostics.clear", scroll: true)
        let confirm = app.sheets.buttons["Clear Log"].firstMatch.exists
            ? app.sheets.buttons["Clear Log"].firstMatch
            : app.buttons.matching(NSPredicate(format: "label == 'Clear Log' AND NOT (identifier == 'platform.diagnostics.clear')")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation before clearing")
        confirm.tap()
        XCTAssertTrue(NextUITest.element(app, "platform.diagnostics.lines").waitForExistence(timeout: 5))
    }

    /// The renderer bench on the flood workload shows its summary.
    func testTerminalBenchReports() {
        let app = NextUITest.launch(["CMUX_IOS_HOME_PREVIEW": "1", "CMUX_IOS_TERMINAL_BENCH": "flood"])
        let summary = NextUITest.element(app, "terminal.bench.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 20), "bench did not show")
        XCTAssertTrue(NextUITest.wait(summary, "label != ''", timeout: 60), "bench never reported")
    }
}
