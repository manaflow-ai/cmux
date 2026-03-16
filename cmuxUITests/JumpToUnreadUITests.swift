import Foundation
import XCTest

final class JumpToUnreadUITests: XCTestCase {
    // MARK: Properties

    private var dataPath = ""

    // MARK: Overridden Functions

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        dataPath = "/tmp/cmux-ui-test-jump-unread-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
    }

    // MARK: Functions

    func testJumpToUnreadFocusesPanelAcrossTabs() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_JUMP_UNREAD_PATH"] = dataPath
        app.launch()
        app.activate()

        XCTAssertTrue(
            waitForJumpUnreadData(keys: ["expectedTabId", "expectedSurfaceId"], timeout: 6.0),
            "Expected test setup data to be written"
        )

        let setupData = try XCTUnwrap(loadJumpUnreadData(), "Missing test setup data")

        let expectedTabId = setupData["expectedTabId"]
        let expectedSurfaceId = setupData["expectedSurfaceId"]
        XCTAssertNotNil(expectedTabId)
        XCTAssertNotNil(expectedSurfaceId)

        app.typeKey("u", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForJumpUnreadData(keys: ["focusedTabId", "focusedSurfaceId"], timeout: 6.0),
            "Expected jump-to-unread focus to be recorded"
        )

        let focusedData = try XCTUnwrap(loadJumpUnreadData(), "Missing jump-to-unread focus data")

        XCTAssertEqual(focusedData["focusedTabId"], expectedTabId)
        XCTAssertEqual(focusedData["focusedSurfaceId"], expectedSurfaceId)
    }

    private func waitForJumpUnreadData(keys: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJumpUnreadData(), keys.allSatisfy({ data[$0] != nil }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadJumpUnreadData(), keys.allSatisfy({ data[$0] != nil }) {
            return true
        }
        return false
    }

    private func loadJumpUnreadData() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
}
