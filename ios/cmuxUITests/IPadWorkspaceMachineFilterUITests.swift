import UIKit
import XCTest

final class IPadWorkspaceMachineFilterUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAllComputersFilterRemainsReachableAfterRotation() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The regression requires the iPad workspace sidebar layout.")
        }

        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US",
            "-dev.cmux.mobile.onboarding.redesign.progress.v1",
            "complete",
        ]
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTOCONNECT_MIGRATION"] = "ineligible"
        app.launchEnvironment["CMUX_UITEST_AUTOCONNECT_MIGRATION_ID"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }

        assertAllComputersFilterReachable(in: app, layout: "portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.width > app.frame.height },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        assertAllComputersFilterReachable(in: app, layout: "landscape")
    }

    @MainActor
    private func assertAllComputersFilterReachable(
        in app: XCUIApplication,
        layout: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let picker = app.buttons["MobileWorkspaceMacPicker"]
        let pickerIsHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in picker.exists && picker.isHittable },
            object: picker
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [pickerIsHittable], timeout: 10),
            .completed,
            "The All Computers filter is not reachable in the \(layout) workspace layout.",
            file: file,
            line: line
        )
        XCTAssertEqual(picker.label, "All Computers", file: file, line: line)

        picker.tap()
        let allComputers = app.buttons["MobileWorkspaceMacPickerAll"]
        XCTAssertTrue(
            allComputers.waitForExistence(timeout: 3),
            "The machine menu does not expose All Computers in the \(layout) layout.",
            file: file,
            line: line
        )
        allComputers.tap()

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "ipad-workspace-machine-filter-\(layout)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
